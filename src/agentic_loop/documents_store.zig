//! Storage layer for workspace-scoped markdown documents.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const helpers = @import("helpers");

/// The only document format MVP writes. The column exists so the table is
/// not markdown-shaped by accident; a future pdf/plain-text writer fills
/// this in without a table rewrite.
pub const FORMAT_MARKDOWN = "markdown";

/// Hard cap on a single document's body. 4 MiB is generous for a markdown
/// note and stops a runaway agent from filling the disk. The agent tool
/// surfaces it as a tool error; the HTTP handler as 413.
pub const MAX_CONTENT_BYTES: usize = 4 << 20; // 4 MiB

/// Process-local monotonic counter for `document_id` generation. The wall
/// clock alone is not a source of uniqueness here.
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
/// return a different shape.
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
    db: *database.Db,
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
/// case-insensitively — newest-updated first. `needle` is a LITERAL
/// substring, never a pattern.
pub fn searchDocuments(
    allocator: std.mem.Allocator,
    db: *database.Db,
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
pub fn getDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
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
    db: *database.Db,
    args: CreateDocumentArgs,
) CreateDocumentError!DocumentRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const title = std.mem.trim(u8, args.title, " \t\n\r");
    if (title.len == 0) return error.TitleRequired;
    if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

    // `doc_<nanos>_<pid>_<seq>` — the workspace_id scheme from
    // `workspace_provisioning.zig`, for the same reason.
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
    // `Backend.exec` binds a zero-length slice as SQL NULL, which would
    // violate the constraint outright.
    db.exec(allocator,
        \\INSERT INTO documents (id, workspace_id, title, content, format, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), 'markdown'), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    , &[_][]const u8{ document_id, args.workspace_id, title, args.content, format }) catch
        return error.InsertFailed;

    // The re-read uses a wider error set than this function declares, so map
    // it: a genuine "row is gone" is the consistency error, and anything else
    // (query failure, OOM) is a failed insert from the caller's point of
    return getDocument(allocator, db, args.workspace_id, document_id) catch |err| switch (err) {
        error.NotFound, error.IdsRequired, error.QueryFailed => error.RowNotFoundAfterInsert,
        error.OutOfMemory => error.InsertFailed,
    };
}

/// Patch a document. Absent fields keep their current value; `updated_at`
/// always advances so the sidebar's recency ordering reflects the edit.
pub fn updateDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    document_id: []const u8,
    patch: UpdateDocumentArgs,
) UpdateDocumentError!DocumentRow {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;
    if (patch.content) |c| {
        if (c.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;
    }

    // Load the current values so an absent field is a true no-op rather than
    // a wipe. Without this a PATCH of `{title}` alone would blank the body —
    // the exact class of bug the "effective_*" pattern exists to prevent.
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
    db: *database.Db,
    workspace_id: []const u8,
    document_id: []const u8,
) DeleteDocumentError!void {
    if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

    // Check-then-delete in one statement: a DELETE that affects 0 rows is the
    // same "not found" the guard would have reported, so a second round-trip
    // is only needed to distinguish the two cases.
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
