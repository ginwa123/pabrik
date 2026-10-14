//! Storage layer for workspace-scoped markdown documents.
//!
//! One table (Migration 098's `documents`), six public functions, and ONE
//! rule that every one of them obeys: `workspace_id` is a function
//! parameter that appears in the `WHERE` clause, never a value the caller
//! can choose to omit. That is the whole isolation story — a document in
//! workspace A is unreadable, uneditable and undeletable from workspace B,
//! and the guard is in SQL rather than in a caller-side check somebody can
//! forget.
//!
//! Shared by the HTTP handlers (`src/http_handlers/documents_*.zig`) and
//! the `add_document` / `edit_document` agent tools
//! (`src/modules/agent/tools/document.zig`). Both must agree on the scope
//! rule, so both call these functions instead of each writing their own
//! SQL — a second hand-written `SELECT ... FROM documents` is exactly how
//! a scope check drifts out of sync with its siblings.
//!
//! The agent tools additionally resolve `workspace_id` SERVER-SIDE from
//! `ctx.session_id` via `workspace_scope.resolveWorkspaceId` and pass it
//! in here as a plain argument. It is deliberately absent from the tool
//! schema, so `ignore_unknown_fields` parsing cannot be used to smuggle a
//! foreign workspace id past the guard.
//!
//! Ownership: every string in a returned `DocumentRow` is allocator-owned.
//! Free a single row with `freeDocumentRow`, a slice with
//! `freeDocumentRows`.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const helpers = @import("helpers");

/// The only document format MVP writes. The column exists so the table is
/// not markdown-shaped by accident; a future pdf/plain-text writer fills
/// this in without a table rewrite.
pub const FORMAT_MARKDOWN = "markdown";

/// Hard cap on a single document's body. 4 MiB is generous for a markdown
/// note and stops a runaway agent from filling the disk. The agent tool
/// surfaces it as a tool error; the HTTP handler as 413.
pub const MAX_CONTENT_BYTES: usize = 4 << 20; // 4 MiB

/// Process-local monotonic counter for `document_id` generation.
///
/// The wall clock alone is not a source of uniqueness here. On Windows
/// `helpers.unixTimestampNanos` reads `GetSystemTimeAsFileTime`, which is
/// quantised to the system clock tick, so two documents created inside
/// one tick produced the SAME `doc_<nanos>` id and the second INSERT died
/// on `UNIQUE constraint failed: documents.id` — 500 to the client. Same
/// failure shape (and same remedy) as the workspace_id collision recorded
/// in `workspace_provisioning.zig`.
var document_id_counter: std.atomic.Value(u64) = .init(0);

fn documentIdSeq() u64 {
    return document_id_counter.fetchAdd(1, .monotonic);
}

/// One row in `documents`. All string fields are allocator-owned and must
/// be freed by the caller.
pub const DocumentRow = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    content: []const u8,
    format: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Fields for a new document. `workspace_id` is required and has no
/// default: a document with no owner is not a document.
pub const CreateDocumentArgs = struct {
    workspace_id: []const u8,
    title: []const u8 = "",
    content: []const u8 = "",
    /// Defaults to `FORMAT_MARKDOWN` when empty.
    format: []const u8 = FORMAT_MARKDOWN,
};

/// Patch shape. Every field is optional; an absent field keeps its current
/// value (the `effective_*` pattern from the routine update handler).
pub const UpdateDocumentArgs = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const CreateDocumentError = error{
    WorkspaceIdRequired,
    TitleRequired,
    ContentTooLarge,
    InsertFailed,
    RowNotFoundAfterInsert,
    OutOfMemory,
};

pub const ListDocumentsError = error{
    WorkspaceIdRequired,
    QueryFailed,
    OutOfMemory,
};

/// Same error set as `ListDocumentsError`; `searchDocuments` reuses it so a
/// caller that handles "the list failed" already handles "the search
/// failed" and cannot accidentally drop one arm.
pub const SearchDocumentsError = ListDocumentsError;

pub const GetDocumentError = error{
    IdsRequired,
    NotFound,
    QueryFailed,
    OutOfMemory,
};

pub const UpdateDocumentError = error{
    IdsRequired,
    NotFound,
    ContentTooLarge,
    UpdateFailed,
    QueryFailed,
    OutOfMemory,
};

pub const DeleteDocumentError = error{
    IdsRequired,
    NotFound,
    DeleteFailed,
};

/// The SELECT list, shared by every read so no call site can accidentally
/// return a different shape. `COALESCE` guards a row written before a
/// column existed; `IFNULL` flattens SQL NULL to "" so the JS side never
/// sees a null where it typed a string.
const SELECT_COLUMNS =
    "SELECT id, workspace_id, title, content, format, " ++
    "COALESCE(created_at, ''), COALESCE(updated_at, '') " ++
    "FROM documents";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) !DocumentRow {
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .title = try allocator.dupe(u8, values[2]),
        .content = try allocator.dupe(u8, values[3]),
        .format = try allocator.dupe(u8, values[4]),
        .created_at = try allocator.dupe(u8, values[5]),
        .updated_at = try allocator.dupe(u8, values[6]),
    };
}

/// Every document in one workspace, most-recently-updated first. The
/// ordering matches `idx_documents_workspace_updated` and the sidebar's
/// `DocumentsList` render order.
pub fn listDocuments(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
) ListDocumentsError![]DocumentRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY updated_at DESC, id DESC",
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(DocumentRow) = .empty;
    // On a mid-iteration OOM the already-built rows would leak; unwind
    // them here rather than at each `try`.
    errdefer freeDocumentRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// The LIKE escape character used by `searchDocuments`. Named so the SQL and
/// the escaper below can never disagree — a mismatch here is a wrong answer,
/// not a compile error.
const LIKE_ESCAPE = '\\';

/// Escape `needle` into a SQLite `LIKE ... ESCAPE '\'` pattern that matches
/// any string CONTAINING it verbatim.
///
/// SQLite's LIKE treats `%` and `_` as wildcards and has no other escape, so
/// a bare needle containing them would widen the match instead of narrowing
/// it. Both are escaped here — and so is the escape character itself, which
/// is the arm that is easy to forget and turns `C:\src` into a pattern whose
/// `\` swallows the next character.
fn likeContainsPattern(allocator: std.mem.Allocator, needle: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '%');
    for (needle) |c| {
        if (c == '%' or c == '_' or c == LIKE_ESCAPE) try out.append(allocator, LIKE_ESCAPE);
        try out.append(allocator, c);
    }
    try out.append(allocator, '%');
    return out.toOwnedSlice(allocator);
}

/// Documents in one workspace whose TITLE or CONTENT contains `needle`,
/// case-insensitively — newest-updated first.
///
/// `needle` is a LITERAL substring, never a pattern. This is the cheap
/// prefilter the `search_documents` tool runs BEFORE the regex engine, and
/// the caller is responsible for passing `null` unless the model asked for
/// literal text: a LIKE test is a SUPERSET of a regex's matches only when
/// the regex contains no metacharacters, so prefiltering `foo.bar` with
/// `LIKE '%foo.bar%'` would silently drop every document whose title matched
/// the regex but not the literal. `documents_search.literalPrefilter` is the
/// one place that decides this, and it errs toward `null`.
///
/// `null` or `""` means "no narrowing" — return the whole workspace, the
/// same rows `listDocuments` would.
pub fn searchDocuments(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    needle: ?[]const u8,
) SearchDocumentsError![]DocumentRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    const pattern: ?[]u8 = blk: {
        const raw = needle orelse break :blk null;
        if (raw.len == 0) break :blk null;
        break :blk try likeContainsPattern(allocator, raw);
    };
    defer if (pattern) |p| allocator.free(p);

    const sql = if (pattern != null)
        SELECT_COLUMNS ++
            " WHERE workspace_id = ?" ++
            " AND (title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')" ++
            " ORDER BY updated_at DESC, id DESC"
    else
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY updated_at DESC, id DESC";

    var q = db.query(
        allocator,
        sql,
        if (pattern) |p|
            &[_][]const u8{ workspace_id, p, p }
        else
            &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(DocumentRow) = .empty;
    errdefer freeDocumentRows(allocator, list.items);

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// One document, scoped to `workspace_id`.
///
/// A document that exists but belongs to another workspace is reported as
/// `error.NotFound`, NOT as a distinct "wrong workspace" error: telling a
/// caller that an id exists but is foreign leaks the existence of another
/// workspace's row, which is the exact thing the scoping exists to hide.
pub fn getDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    document_id: []const u8,
) GetDocumentError!DocumentRow {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ document_id, workspace_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values) catch return error.OutOfMemory;
}

/// Insert a document and return it with its canonical id + timestamps.
pub fn createDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    args: CreateDocumentArgs,
) CreateDocumentError!DocumentRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const title = std.mem.trim(u8, args.title, " \t\n\r");
    if (title.len == 0) return error.TitleRequired;
    if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

    // `doc_<nanos>_<pid>_<seq>` — the workspace_id scheme from
    // `workspace_provisioning.zig`, for the same reason.
    //
    // `helpers.unixTimestampNanos` is cross-platform (std.c.clock_gettime
    // does not compile on Windows in Zig 0.16) and keeps ids roughly in
    // creation order. What makes them UNIQUE, though, is the pid plus the
    // per-process counter, not the timestamp: on Windows the timestamp is
    // tick-quantised, which is exactly how `doc_<nanos>` alone collided —
    // see `document_id_counter`.
    const document_id = try std.fmt.allocPrint(
        allocator,
        "doc_{d}_{d}_{d}",
        .{
            helpers.unixTimestampNanos(),
            helpers.process.getCurrentProcessId(),
            documentIdSeq(),
        },
    );
    defer allocator.free(document_id);

    const format = if (args.format.len == 0) FORMAT_MARKDOWN else args.format;

    // COALESCE(NULLIF(?, ''), '') on every NOT NULL text column:
    // `SqliteBackend.exec` binds a zero-length slice as SQL NULL, which
    // would violate the constraint outright. An empty body is a legitimate
    // document (a user opens a blank note and types later), so it has to
    // round-trip as "" rather than blowing up.
    db.exec(allocator,
        \\INSERT INTO documents (id, workspace_id, title, content, format, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), 'markdown'), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    , &[_][]const u8{ document_id, args.workspace_id, title, args.content, format }) catch
        return error.InsertFailed;

    // The re-read uses a wider error set than this function declares, so
    // map it: a genuine "row is gone" is the consistency error, and
    // anything else (query failure, OOM) is a failed insert from the
    // caller's point of view.
    return getDocument(allocator, db, args.workspace_id, document_id) catch |err| switch (err) {
        error.NotFound, error.IdsRequired, error.QueryFailed => error.RowNotFoundAfterInsert,
        error.OutOfMemory => error.InsertFailed,
    };
}

/// Patch a document. Absent fields keep their current value; `updated_at`
/// always advances so the sidebar's recency ordering reflects the edit.
pub fn updateDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    document_id: []const u8,
    patch: UpdateDocumentArgs,
) UpdateDocumentError!DocumentRow {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;
    if (patch.content) |c| {
        if (c.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;
    }

    // Load the current values so an absent field is a true no-op rather
    // than a wipe. Without this a PATCH of `{title}` alone would blank the
    // body — the exact class of bug the "effective_*" pattern exists to
    // prevent.
    const existing = getDocument(allocator, db, workspace_id, document_id) catch
        return error.NotFound;
    defer freeDocumentRow(allocator, existing);

    const title = if (patch.title) |t| blk: {
        const trimmed = std.mem.trim(u8, t, " \t\n\r");
        if (trimmed.len == 0) return error.NotFound;
        break :blk trimmed;
    } else existing.title;
    const content = patch.content orelse existing.content;

    db.exec(allocator,
        \\UPDATE documents
        \\SET title = COALESCE(NULLIF(?, ''), ''), content = COALESCE(NULLIF(?, ''), ''), updated_at = CURRENT_TIMESTAMP
        \\WHERE id = ? AND workspace_id = ?
    , &[_][]const u8{ title, content, document_id, workspace_id }) catch
        return error.UpdateFailed;

    return getDocument(allocator, db, workspace_id, document_id) catch
        return error.UpdateFailed;
}

/// Delete a document. Scoped like every other read: a foreign id reports
/// `error.NotFound` and deletes nothing.
pub fn deleteDocument(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_id: []const u8,
    document_id: []const u8,
) DeleteDocumentError!void {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

    // Check-then-delete in one statement: a DELETE that affects 0 rows is
    // the same "not found" the guard would have reported, so a second
    // round-trip is only needed to distinguish the two cases. `total_rows`
    // on the exec result is the count, so do it explicitly.
    var q = db.query(
        allocator,
        "SELECT id FROM documents WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ document_id, workspace_id },
    ) catch return error.DeleteFailed;
    defer q.deinit();
    const r = (q.next() catch return error.DeleteFailed) orelse return error.NotFound;
    defer r.deinit(allocator);

    db.exec(
        allocator,
        "DELETE FROM documents WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ document_id, workspace_id },
    ) catch return error.DeleteFailed;
}

/// Free a single row's owned strings.
pub fn freeDocumentRow(allocator: std.mem.Allocator, row: DocumentRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_id);
    allocator.free(row.title);
    allocator.free(row.content);
    allocator.free(row.format);
    allocator.free(row.created_at);
    allocator.free(row.updated_at);
}

/// Free a slice of rows. The slice header is freed last.
pub fn freeDocumentRows(allocator: std.mem.Allocator, rows: []DocumentRow) void {
    for (rows) |row| freeDocumentRow(allocator, row);
    allocator.free(rows);
}
