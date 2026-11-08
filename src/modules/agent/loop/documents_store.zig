//! Storage layer for workspace-scoped markdown documents.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const helpers = @import("helpers");
const folders_store = @import("document_folders_store.zig");
const object_store = @import("pabrikcore").storage.storage;

/// The only document format MVP writes. The column exists so the table is
/// not markdown-shaped by accident; a future pdf/plain-text writer fills
/// this in without a table rewrite.
pub const FORMAT_MARKDOWN = "markdown";

/// Bound where a query compares "this level" and it can be the root. `#` is not
/// a folder-id character, and "" is unusable: `Backend.exec` binds it as SQL
/// NULL, so `COALESCE(folder_id, '') = ''` would never match a row.
const ROOT_LEVEL = "#root";

/// Hard cap on a single document's body. 4 MiB is generous for a markdown
/// note and stops a runaway agent from filling the disk. The agent tool
/// surfaces it as a tool error; the HTTP handler as 413.
pub const MAX_CONTENT_BYTES: usize = 4 << 20; // 4 MiB

/// How much of the body the `preview` column keeps. Bounded so a 4 MiB note
/// costs 512 bytes in every list read, and so the sidebar never needs the
/// object store.
pub const PREVIEW_MAX_BYTES: usize = 512;

/// The first `PREVIEW_MAX_BYTES` of `body`, cut on a UTF-8 boundary.
pub fn previewOf(body: []const u8) []const u8 {
    if (body.len <= PREVIEW_MAX_BYTES) return body;
    var end = PREVIEW_MAX_BYTES;
    while (end > 0 and (body[end] & 0xC0) == 0x80) end -= 1;
    return body[0..end];
}

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
    position: i64,
    /// The folder this document sits in, or `null` at the root.
    folder_id: ?[]const u8,
    /// Object-store key for the body. Null means the body is only in `content`.
    content_key: ?[]const u8 = null,
    /// Lowercase hex SHA-256 of the body, when the body is in the object store.
    content_sha256: ?[]const u8 = null,
    /// Body length in bytes. 0 for a row written before Migration 143.
    content_bytes: i64 = 0,
    /// The first `PREVIEW_MAX_BYTES` of the body, kept in SQL for the sidebar.
    preview: []const u8 = "",
};

/// Fields for a new document. `workspace_id` is required and has no
/// default: a document with no owner is not a document.
pub const CreateDocumentArgs = struct {
    workspace_id: []const u8,
    title: []const u8 = "",
    content: []const u8 = "",
    /// Defaults to `FORMAT_MARKDOWN` when empty.
    format: []const u8 = FORMAT_MARKDOWN,
    /// `null` creates the document at the root.
    folder_id: ?[]const u8 = null,
};

/// Patch shape. Every field is optional; an absent field keeps its current
/// value (the `effective_*` pattern from the routine update handler).
pub const UpdateDocumentArgs = struct {
    title: ?[]const u8 = null,
    content: ?[]const u8 = null,
    /// Set `move_folder` to move, so `folder_id = null` means "to the root"
    /// rather than "keep the current folder".
    folder_id: ?[]const u8 = null,
    move_folder: bool = false,
};

pub const CreateDocumentError = error{
    WorkspaceIdRequired,
    TitleRequired,
    ContentTooLarge,
    FolderNotFound,
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
    FolderNotFound,
    UpdateFailed,
    QueryFailed,
    OutOfMemory,
};

pub const DeleteDocumentError = error{
    IdsRequired,
    NotFound,
    DeleteFailed,
};

pub const ReorderDocumentsError = error{
    WorkspaceIdRequired,
    EmptyOrder,
    DocumentNotFound,
    DuplicateDocumentId,
    QueryFailed,
    TransactionFailed,
    UpdateFailed,
    OutOfMemory,
};

pub const BackfillOptions = struct {
    /// Only this workspace. Null means every workspace.
    workspace_id: ?[]const u8 = null,
    /// Stop after this many rows. 0 means no cap, so a run is resumable by
    /// repeating it with a limit.
    limit: usize = 0,
    /// Report what would move without writing anything.
    dry_run: bool = false,
};

pub const BackfillReport = struct {
    /// Rows with `content_key IS NULL` that this run looked at.
    scanned: usize = 0,
    /// Bodies written to the object store and pointed at.
    moved: usize = 0,
    /// Rows whose body is empty, so there is nothing to move.
    skipped_empty: usize = 0,
    /// Rows the object store refused. The row is left untouched.
    failed: usize = 0,
};

pub const BackfillError = error{
    /// No object store is configured, so there is nowhere to move a body to.
    NoStorage,
    QueryFailed,
    ObjectStoreFailed,
    OutOfMemory,
};

/// One row the backfill is about to move. Owns its strings.
const Candidate = struct {
    id: []u8,
    workspace_id: []u8,
    body: []u8,
};

fn freeCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_id);
        allocator.free(c.body);
    }
    allocator.free(candidates);
}

/// The SELECT list, shared by every read so no call site can accidentally
/// return a different shape.
const SELECT_COLUMNS =
    "SELECT id, workspace_id, title, content, format, " ++
    "COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), ''), " ++
    "COALESCE(CAST(position AS TEXT), '0'), COALESCE(folder_id, ''), " ++
    "COALESCE(content_key, ''), COALESCE(content_sha256, ''), " ++
    "COALESCE(CAST(content_bytes AS TEXT), '0'), COALESCE(preview, '') " ++
    "FROM documents";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) !DocumentRow {
    const folder: ?[]const u8 = if (values[8].len == 0) null else try allocator.dupe(u8, values[8]);
    const content_key: ?[]const u8 = if (values[9].len == 0) null else try allocator.dupe(u8, values[9]);
    const content_sha256: ?[]const u8 = if (values[10].len == 0) null else try allocator.dupe(u8, values[10]);
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .title = try allocator.dupe(u8, values[2]),
        .content = try allocator.dupe(u8, values[3]),
        .format = try allocator.dupe(u8, values[4]),
        .created_at = try allocator.dupe(u8, values[5]),
        .updated_at = try allocator.dupe(u8, values[6]),
        .position = std.fmt.parseInt(i64, values[7], 10) catch 0,
        .folder_id = folder,
        .content_key = content_key,
        .content_sha256 = content_sha256,
        .content_bytes = std.fmt.parseInt(i64, values[11], 10) catch 0,
        .preview = try allocator.dupe(u8, values[12]),
    };
}

fn listDocumentsRaw(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) ListDocumentsError![]DocumentRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY position ASC, updated_at DESC, id DESC",
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

/// Documents in one workspace whose TITLE, PREVIEW or CONTENT contains
/// `needle`, case-insensitively — newest-updated first. `preview` is in the
/// predicate so search survives the body leaving the column.
pub fn searchDocumentsRaw(
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
            " AND (LOWER(title) LIKE LOWER(?) ESCAPE '\\'" ++
            " OR LOWER(preview) LIKE LOWER(?) ESCAPE '\\'" ++
            " OR LOWER(content) LIKE LOWER(?) ESCAPE '\\')" ++
            " ORDER BY updated_at DESC, id DESC"
    else
        SELECT_COLUMNS ++ " WHERE workspace_id = ? ORDER BY updated_at DESC, id DESC";

    var q = db.query(
        allocator,
        sql,
        if (pattern) |p|
            &[_][]const u8{ workspace_id, p, p, p }
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

/// A document store: the database, plus the object store the bodies may live
/// in. `storage = null` keeps every body in the `content` column, which is
/// what the free functions below do.
pub const Store = struct {
    db: *database.Db,
    storage: ?object_store.Storage = null,

    /// One document, scoped to `workspace_id`, with its body hydrated from the
    /// object store when the row points at one.
    pub fn getDocument(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        document_id: []const u8,
    ) GetDocumentError!DocumentRow {
        var row = try self.readRow(allocator, workspace_id, document_id);
        errdefer freeDocumentRow(allocator, row);
        self.hydrate(allocator, &row);
        return row;
    }

    /// Every document in one workspace, in saved sidebar order. Reads the
    /// `content` column, so a list costs no object-store round-trip.
    pub fn listDocuments(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
    ) ListDocumentsError![]DocumentRow {
        return listDocumentsRaw(allocator, self.db, workspace_id);
    }

    /// Documents whose title or body contains `needle`. Reads the `content`
    /// column for the same reason as `listDocuments`.
    pub fn searchDocuments(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        needle: ?[]const u8,
    ) SearchDocumentsError![]DocumentRow {
        return searchDocumentsRaw(allocator, self.db, workspace_id, needle);
    }

    /// The row as SQL has it, without touching the object store. The write
    /// paths use this because they already hold the body they are storing.
    fn readRow(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        document_id: []const u8,
    ) GetDocumentError!DocumentRow {
        if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

        var q = self.db.query(
            allocator,
            SELECT_COLUMNS ++ " WHERE id = ? AND workspace_id = ?",
            &[_][]const u8{ document_id, workspace_id },
        ) catch return error.QueryFailed;
        defer q.deinit();

        const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
        defer r.deinit(allocator);
        return rowFromValues(allocator, r.values) catch return error.OutOfMemory;
    }

    /// Replace `row.content` with the object's bytes. A missing object leaves
    /// the column's copy in place: during the transition the column is
    /// authoritative, so a fallback is correct rather than an error.
    fn hydrate(self: Store, allocator: std.mem.Allocator, row: *DocumentRow) void {
        const key = row.content_key orelse return;
        const s = self.storage orelse return;
        const body = s.get(allocator, key) catch return;
        allocator.free(row.content);
        row.content = body;
    }

    /// Insert a document and return it with its canonical id + timestamps.
    /// The body goes to the object FIRST, so a failed row write leaves a
    /// harmless orphan rather than a row pointing at nothing.
    pub fn createDocument(
        self: Store,
        allocator: std.mem.Allocator,
        args: CreateDocumentArgs,
    ) CreateDocumentError!DocumentRow {
        if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;

        const title = std.mem.trim(u8, args.title, " \t\n\r");
        if (title.len == 0) return error.TitleRequired;
        if (args.content.len > MAX_CONTENT_BYTES) return error.ContentTooLarge;

        // A folder id from another workspace must not become a dangling pointer.
        if (args.folder_id) |folder_id| {
            if (folder_id.len > 0 and !folders_store.folderExists(allocator, self.db, args.workspace_id, folder_id)) {
                return error.FolderNotFound;
            }
        }

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

        const placed = self.placeBody(allocator, args.workspace_id, document_id, args.content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ObjectStoreFailed => return error.InsertFailed,
        };
        defer placed.deinit(allocator);

        // COALESCE(NULLIF(?, ''), '') on every NOT NULL text column:
        // `Backend.exec` binds a zero-length slice as SQL NULL, which would
        // violate the constraint outright.
        const folder = args.folder_id orelse "";
        const level = if (folder.len == 0) ROOT_LEVEL else folder;
        self.db.exec(allocator,
            \\INSERT INTO documents (id, workspace_id, title, content, format, folder_id, position,
            \\                       content_key, content_sha256, content_bytes, preview,
            \\                       created_at, updated_at)
            \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), 'markdown'), NULLIF(?, ''),
            \\        COALESCE((SELECT MIN(position) FROM documents WHERE workspace_id = ? AND COALESCE(folder_id, '#root') = ?), 0) - 1,
            \\        NULLIF(?, ''), NULLIF(?, ''), ?, COALESCE(NULLIF(?, ''), ''),
            \\        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        , &[_][]const u8{
            document_id,
            args.workspace_id,
            title,
            args.content,
            format,
            folder,
            args.workspace_id,
            level,
            placed.key orelse "",
            placed.sha256 orelse "",
            placed.bytesText(),
            placed.preview,
        }) catch
            return error.InsertFailed;

        // The re-read uses a wider error set than this function declares, so map
        // it: a genuine "row is gone" is the consistency error, and anything else
        // (query failure, OOM) is a failed insert from the caller's
        return self.getDocument(allocator, args.workspace_id, document_id) catch |err| switch (err) {
            error.NotFound, error.IdsRequired, error.QueryFailed => error.RowNotFoundAfterInsert,
            error.OutOfMemory => error.InsertFailed,
        };
    }

    /// Patch a document. Absent fields keep their current value and `updated_at`
    /// always advances.
    pub fn updateDocument(
        self: Store,
        allocator: std.mem.Allocator,
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
        const existing = self.readRow(allocator, workspace_id, document_id) catch
            return error.NotFound;
        defer freeDocumentRow(allocator, existing);

        const title = if (patch.title) |t| blk: {
            const trimmed = std.mem.trim(u8, t, " \t\n\r");
            if (trimmed.len == 0) return error.NotFound;
            break :blk trimmed;
        } else existing.title;
        const content = patch.content orelse existing.content;

        const placed = self.placeBody(allocator, workspace_id, document_id, content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ObjectStoreFailed => return error.UpdateFailed,
        };
        defer placed.deinit(allocator);

        if (patch.move_folder) {
            const folder = patch.folder_id orelse "";
            if (folder.len > 0 and !folders_store.folderExists(allocator, self.db, workspace_id, folder)) {
                return error.FolderNotFound;
            }
            self.db.exec(allocator,
                \\UPDATE documents
                \\SET title = COALESCE(NULLIF(?, ''), ''), content = COALESCE(NULLIF(?, ''), ''), folder_id = NULLIF(?, ''),
                \\    content_key = NULLIF(?, ''), content_sha256 = NULLIF(?, ''), content_bytes = ?, preview = COALESCE(NULLIF(?, ''), ''),
                \\    updated_at = CURRENT_TIMESTAMP
                \\WHERE id = ? AND workspace_id = ?
            , &[_][]const u8{
                title,
                content,
                folder,
                placed.key orelse "",
                placed.sha256 orelse "",
                placed.bytesText(),
                placed.preview,
                document_id,
                workspace_id,
            }) catch
                return error.UpdateFailed;
        } else {
            self.db.exec(allocator,
                \\UPDATE documents
                \\SET title = COALESCE(NULLIF(?, ''), ''), content = COALESCE(NULLIF(?, ''), ''),
                \\    content_key = NULLIF(?, ''), content_sha256 = NULLIF(?, ''), content_bytes = ?, preview = COALESCE(NULLIF(?, ''), ''),
                \\    updated_at = CURRENT_TIMESTAMP
                \\WHERE id = ? AND workspace_id = ?
            , &[_][]const u8{
                title,
                content,
                placed.key orelse "",
                placed.sha256 orelse "",
                placed.bytesText(),
                placed.preview,
                document_id,
                workspace_id,
            }) catch
                return error.UpdateFailed;
        }

        return self.getDocument(allocator, workspace_id, document_id) catch
            return error.UpdateFailed;
    }

    /// Delete a document. Scoped like every other read: a foreign id reports
    /// `error.NotFound` and deletes nothing. The object goes AFTER the row, so
    /// a failure leaves an orphan rather than a row pointing at nothing.
    pub fn deleteDocument(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        document_id: []const u8,
    ) DeleteDocumentError!void {
        if (workspace_id.len == 0 or document_id.len == 0) return error.IdsRequired;

        // Check-then-delete in one statement: a DELETE that affects 0 rows is the
        // same "not found" the guard would have reported, so a second round-trip
        // is only needed to distinguish the two cases.
        var q = self.db.query(
            allocator,
            "SELECT id, COALESCE(content_key, '') FROM documents WHERE id = ? AND workspace_id = ?",
            &[_][]const u8{ document_id, workspace_id },
        ) catch return error.DeleteFailed;
        defer q.deinit();
        const r = (q.next() catch return error.DeleteFailed) orelse return error.NotFound;
        const content_key = allocator.dupe(u8, r.values[1]) catch {
            r.deinit(allocator);
            return error.DeleteFailed;
        };
        defer allocator.free(content_key);
        r.deinit(allocator);

        self.db.exec(
            allocator,
            "DELETE FROM documents WHERE id = ? AND workspace_id = ?",
            &[_][]const u8{ document_id, workspace_id },
        ) catch return error.DeleteFailed;

        if (content_key.len > 0) {
            if (self.storage) |s| s.delete(content_key) catch {};
        }
    }

    /// Move every body that is still only in the `content` column into the
    /// object store. Idempotent: a second run finds nothing to move. The body
    /// stays in the column — clearing it is a later phase.
    pub fn backfill(
        self: Store,
        allocator: std.mem.Allocator,
        opts: BackfillOptions,
    ) BackfillError!BackfillReport {
        const s = self.storage orelse return error.NoStorage;

        const candidates = try self.backfillCandidates(allocator, opts);
        defer freeCandidates(allocator, candidates);

        var report = BackfillReport{ .scanned = candidates.len };
        for (candidates) |candidate| {
            if (candidate.body.len == 0) {
                report.skipped_empty += 1;
                continue;
            }
            if (opts.dry_run) {
                report.moved += 1;
                continue;
            }
            if (self.backfillOne(allocator, s, candidate)) |_| {
                report.moved += 1;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => report.failed += 1,
            }
        }
        return report;
    }

    /// Rows whose body is still only in the column, oldest id first so a
    /// `--limit` run resumes where the last one stopped.
    fn backfillCandidates(
        self: Store,
        allocator: std.mem.Allocator,
        opts: BackfillOptions,
    ) BackfillError![]Candidate {
        const sql = if (opts.workspace_id != null)
            "SELECT id, workspace_id, content FROM documents WHERE content_key IS NULL AND workspace_id = ? ORDER BY id"
        else
            "SELECT id, workspace_id, content FROM documents WHERE content_key IS NULL ORDER BY id";

        var q = self.db.query(
            allocator,
            sql,
            if (opts.workspace_id) |ws| &[_][]const u8{ws} else &[_][]const u8{},
        ) catch return error.QueryFailed;
        defer q.deinit();

        var list: std.ArrayList(Candidate) = .empty;
        errdefer freeCandidates(allocator, list.items);

        while (q.next() catch return error.QueryFailed) |r| {
            defer r.deinit(allocator);
            if (opts.limit != 0 and list.items.len >= opts.limit) break;
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, r.values[0]),
                .workspace_id = try allocator.dupe(u8, r.values[1]),
                .body = try allocator.dupe(u8, r.values[2]),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Write one body and point its row at it. The object goes first, so a
    /// failed row update leaves an orphan rather than a dangling pointer.
    fn backfillOne(
        self: Store,
        allocator: std.mem.Allocator,
        s: object_store.Storage,
        candidate: Candidate,
    ) BackfillError!void {
        var digest: [object_store.SHA256_HEX_BYTES]u8 = undefined;
        object_store.sha256Hex(candidate.body, &digest);

        const key = object_store.documentKey(allocator, candidate.workspace_id, candidate.id, &digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ObjectStoreFailed,
        };
        defer allocator.free(key);

        s.put(key, candidate.body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ObjectStoreFailed,
        };

        var bytes_buf: [24]u8 = undefined;
        const bytes_text = std.fmt.bufPrint(&bytes_buf, "{d}", .{candidate.body.len}) catch "0";

        self.db.exec(allocator,
            \\UPDATE documents
            \\SET content_key = ?, content_sha256 = ?, content_bytes = ?, preview = ?
            \\WHERE id = ? AND workspace_id = ?
        , &[_][]const u8{
            key,
            &digest,
            bytes_text,
            previewOf(candidate.body),
            candidate.id,
            candidate.workspace_id,
        }) catch return error.ObjectStoreFailed;
    }

    /// The object-store half of a write: the key, digest, byte count and
    /// preview for `body`, with the object already stored when a store is
    /// configured.
    fn placeBody(
        self: Store,
        allocator: std.mem.Allocator,
        workspace_id: []const u8,
        document_id: []const u8,
        body: []const u8,
    ) PlaceError!Placed {
        var placed = Placed{ .preview = previewOf(body) };
        const text = std.fmt.bufPrint(&placed.bytes_buf, "{d}", .{body.len}) catch "0";
        placed.bytes_len = text.len;

        const s = self.storage orelse return placed;

        var digest: [object_store.SHA256_HEX_BYTES]u8 = undefined;
        object_store.sha256Hex(body, &digest);

        const key = object_store.documentKey(allocator, workspace_id, document_id, &digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ObjectStoreFailed,
        };
        errdefer allocator.free(key);

        s.put(key, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ObjectStoreFailed,
        };

        placed.key = key;
        placed.sha256 = allocator.dupe(u8, &digest) catch return error.OutOfMemory;
        return placed;
    }
};

pub const PlaceError = error{ ObjectStoreFailed, OutOfMemory };

/// What `placeBody` produced. `key` and `sha256` are owned when non-null; the
/// byte count lives in `bytes_buf` so the struct stays copyable.
const Placed = struct {
    key: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    preview: []const u8 = "",
    bytes_buf: [24]u8 = undefined,
    bytes_len: usize = 1,

    fn bytesText(self: *const Placed) []const u8 {
        return self.bytes_buf[0..self.bytes_len];
    }

    fn deinit(self: Placed, allocator: std.mem.Allocator) void {
        if (self.key) |k| allocator.free(k);
        if (self.sha256) |d| allocator.free(d);
    }
};

/// One document, scoped to `workspace_id`, with no object store configured.
pub fn getDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    document_id: []const u8,
) GetDocumentError!DocumentRow {
    return (Store{ .db = db }).getDocument(allocator, workspace_id, document_id);
}

/// Every document in one workspace, in saved sidebar order.
pub fn listDocuments(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) ListDocumentsError![]DocumentRow {
    return (Store{ .db = db }).listDocuments(allocator, workspace_id);
}

/// Documents whose title or body contains `needle`.
pub fn searchDocuments(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    needle: ?[]const u8,
) SearchDocumentsError![]DocumentRow {
    return (Store{ .db = db }).searchDocuments(allocator, workspace_id, needle);
}

/// Insert a document with no object store configured.
pub fn createDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: CreateDocumentArgs,
) CreateDocumentError!DocumentRow {
    return (Store{ .db = db }).createDocument(allocator, args);
}

/// Patch a document with no object store configured.
pub fn updateDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    document_id: []const u8,
    patch: UpdateDocumentArgs,
) UpdateDocumentError!DocumentRow {
    return (Store{ .db = db }).updateDocument(allocator, workspace_id, document_id, patch);
}

/// Delete a document with no object store configured.
pub fn deleteDocument(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    document_id: []const u8,
) DeleteDocumentError!void {
    return (Store{ .db = db }).deleteDocument(allocator, workspace_id, document_id);
}

fn containsDocumentId(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}

pub fn reorderDocuments(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    folder_id: ?[]const u8,
    ordered_ids: []const []const u8,
) ReorderDocumentsError!void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (ordered_ids.len == 0) return error.EmptyOrder;
    const folder = folder_id orelse "";
    const level = if (folder.len == 0) ROOT_LEVEL else folder;

    // Sibling order is per level: an id in another folder is not "known" here,
    // so a reorder cannot silently renumber a list the caller is not looking at.
    var q = db.query(
        allocator,
        "SELECT id FROM documents WHERE workspace_id = ? AND COALESCE(folder_id, '#root') = ?",
        &[_][]const u8{ workspace_id, level },
    ) catch return error.QueryFailed;
    defer q.deinit();

    var known: std.ArrayList([]const u8) = .empty;
    defer {
        for (known.items) |id| allocator.free(id);
        known.deinit(allocator);
    }
    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        known.append(allocator, allocator.dupe(u8, r.values[0]) catch return error.OutOfMemory) catch
            return error.OutOfMemory;
    }

    for (ordered_ids, 0..) |id, i| {
        if (!containsDocumentId(known.items, id)) return error.DocumentNotFound;
        if (containsDocumentId(ordered_ids[0..i], id)) return error.DuplicateDocumentId;
    }

    var tx = db.begin() catch return error.TransactionFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    var pos_buf: [32]u8 = undefined;
    for (ordered_ids, 0..) |id, i| {
        const position = std.fmt.bufPrint(&pos_buf, "{d}", .{i}) catch return error.UpdateFailed;
        tx.exec(
            allocator,
            "UPDATE documents SET position = ? WHERE id = ? AND workspace_id = ? AND COALESCE(folder_id, '#root') = ?",
            &[_][]const u8{ position, id, workspace_id, level },
        ) catch return error.UpdateFailed;
    }
    tx.commit() catch return error.UpdateFailed;
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
    if (row.folder_id) |folder| allocator.free(folder);
    if (row.content_key) |key| allocator.free(key);
    if (row.content_sha256) |digest| allocator.free(digest);
    allocator.free(row.preview);
}

/// Free a slice of rows. The slice header is freed last.
pub fn freeDocumentRows(allocator: std.mem.Allocator, rows: []DocumentRow) void {
    for (rows) |row| freeDocumentRow(allocator, row);
    allocator.free(rows);
}

const testing = std.testing;
const test_db = @import("pabrikcore").test_db;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try migration.Migration098CreateDocuments.up(&db, testing.allocator);
    try migration.Migration122AddDocumentPosition.up(&db, testing.allocator);
    try migration.Migration140AddDocumentFolders.up(&db, testing.allocator);
    try migration.Migration143AddDocumentContentKey.up(&db, testing.allocator);
    return .{ .db = db, .threaded = threaded };
}

fn seedDocument(alloc: std.mem.Allocator, db: *database.Db, id: []const u8, workspace_id: []const u8, updated_at: []const u8) !void {
    try db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content, updated_at)
        \\VALUES (?, ?, ?, 'body', ?)
    , &[_][]const u8{ id, workspace_id, id, updated_at });
}

fn titlesInOrder(alloc: std.mem.Allocator, rows: []const DocumentRow) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows, 0..) |row, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, row.id);
    }
    return out.toOwnedSlice(alloc);
}

test "listDocuments: never-reordered documents keep the newest-updated-first order" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_oldest", "ws_1", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_middle", "ws_1", "2026-09-02 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_newest", "ws_1", "2026-09-03 10:00:00");

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);

    const order = try titlesInOrder(alloc, rows);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_newest,doc_middle,doc_oldest", order);
}

test "reorderDocuments: the given order becomes the list order and survives a re-read" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_a", "ws_1", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_b", "ws_1", "2026-09-02 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_c", "ws_1", "2026-09-03 10:00:00");

    try reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{ "doc_c", "doc_a", "doc_b" });

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);

    const order = try titlesInOrder(alloc, rows);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_c,doc_a,doc_b", order);
    try testing.expectEqual(@as(i64, 0), rows[0].position);
    try testing.expectEqual(@as(i64, 1), rows[1].position);
    try testing.expectEqual(@as(i64, 2), rows[2].position);
}

test "reorderDocuments: another workspace's order is untouched by a reorder" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_a", "ws_1", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_b", "ws_1", "2026-09-02 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_x", "ws_2", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_y", "ws_2", "2026-09-02 10:00:00");

    try reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{ "doc_b", "doc_a" });

    const theirs = try listDocuments(alloc, &ctx.db, "ws_2");
    defer freeDocumentRows(alloc, theirs);
    const order = try titlesInOrder(alloc, theirs);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_y,doc_x", order);
}

test "reorderDocuments: an id from another workspace is rejected and nothing is written" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_a", "ws_1", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_b", "ws_1", "2026-09-02 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_x", "ws_2", "2026-09-01 10:00:00");

    try testing.expectError(
        error.DocumentNotFound,
        reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{ "doc_b", "doc_x" }),
    );

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);
    const order = try titlesInOrder(alloc, rows);
    defer alloc.free(order);
    try testing.expectEqualStrings("doc_b,doc_a", order);
    try testing.expectEqual(@as(i64, 0), rows[0].position);
    try testing.expectEqual(@as(i64, 0), rows[1].position);
}

test "reorderDocuments: an unknown id is rejected" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_a", "ws_1", "2026-09-01 10:00:00");

    try testing.expectError(
        error.DocumentNotFound,
        reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{"doc_missing"}),
    );
}

test "reorderDocuments: a repeated id is rejected" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedDocument(alloc, &ctx.db, "doc_a", "ws_1", "2026-09-01 10:00:00");
    try seedDocument(alloc, &ctx.db, "doc_b", "ws_1", "2026-09-02 10:00:00");

    try testing.expectError(
        error.DuplicateDocumentId,
        reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{ "doc_a", "doc_a", "doc_b" }),
    );
}

test "reorderDocuments: an empty order and an empty workspace are rejected" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyOrder,
        reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{}),
    );
    try testing.expectError(
        error.WorkspaceIdRequired,
        reorderDocuments(alloc, &ctx.db, "", null, &[_][]const u8{"doc_a"}),
    );
}

test "createDocument: a new document lands above every existing one" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const first = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_1", .title = "First" });
    defer freeDocumentRow(alloc, first);
    const second = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_1", .title = "Second" });
    defer freeDocumentRow(alloc, second);

    try reorderDocuments(alloc, &ctx.db, "ws_1", null, &[_][]const u8{ first.id, second.id });

    const third = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_1", .title = "Third" });
    defer freeDocumentRow(alloc, third);

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Third", rows[0].title);
    try testing.expectEqualStrings("First", rows[1].title);
    try testing.expectEqualStrings("Second", rows[2].title);
}

// ─── Object store: dual-write and dual-read ─────────────────────────────

const memory_backend = @import("pabrikcore").storage.memory;

/// A store whose every verb fails, so a test can prove the write path stops
/// before it touches the row.
const FailingStorage = struct {
    fn put(_: *anyopaque, _: []const u8, _: []const u8) object_store.Error!void {
        return error.IoFailed;
    }
    fn get(_: *anyopaque, _: std.mem.Allocator, _: []const u8) object_store.Error![]u8 {
        return error.NotFound;
    }
    fn delete(_: *anyopaque, _: []const u8) object_store.Error!void {
        return error.NotFound;
    }
    fn stat(_: *anyopaque, _: []const u8) object_store.Error!object_store.Stat {
        return error.NotFound;
    }
    const vtable = object_store.Storage.VTable{
        .put = put,
        .get = get,
        .delete = delete,
        .stat = stat,
    };
};

fn failingStorage(marker: *u8) object_store.Storage {
    return .{ .ptr = marker, .vtable = &FailingStorage.vtable };
}

test "previewOf: a short body comes back whole" {
    try testing.expectEqualStrings("# Plan", previewOf("# Plan"));
    try testing.expectEqualStrings("", previewOf(""));
}

test "previewOf: a long body is cut at the cap" {
    const body = "x" ** (PREVIEW_MAX_BYTES + 100);
    const preview = previewOf(body);
    try testing.expectEqual(PREVIEW_MAX_BYTES, preview.len);
}

test "previewOf: the cut never splits a multi-byte codepoint" {
    // "é" is two bytes; repeat it so the cap lands mid-character.
    var body: [PREVIEW_MAX_BYTES + 2]u8 = undefined;
    for (0..(PREVIEW_MAX_BYTES + 2) / 2) |i| {
        body[i * 2] = 0xC3;
        body[i * 2 + 1] = 0xA9;
    }
    const preview = previewOf(&body);
    try testing.expect(std.unicode.utf8ValidateSlice(preview));
    try testing.expect(preview.len <= PREVIEW_MAX_BYTES);
}

test "createDocument with no store keeps the body in the column and no key" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "# Plan\n",
    });
    defer freeDocumentRow(alloc, row);

    try testing.expectEqualStrings("# Plan\n", row.content);
    try testing.expect(row.content_key == null);
    try testing.expect(row.content_sha256 == null);
    // The byte count and the preview are useful with or without a store, so
    // they are filled in either way.
    try testing.expectEqual(@as(i64, 7), row.content_bytes);
    try testing.expectEqualStrings("# Plan\n", row.preview);
}

test "createDocument with a store writes the object and points the row at it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const row = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "# Plan\n",
    });
    defer freeDocumentRow(alloc, row);

    // The pointer is set, and it is the content-addressed key.
    const key = row.content_key orelse return error.KeyMissing;
    try testing.expect(std.mem.startsWith(u8, key, "ws/ws_1/documents/"));
    try testing.expect(std.mem.endsWith(u8, key, ".md"));

    // The digest is the body's, and the byte count is the body's length.
    var expected: [object_store.SHA256_HEX_BYTES]u8 = undefined;
    object_store.sha256Hex("# Plan\n", &expected);
    try testing.expectEqualStrings(&expected, row.content_sha256.?);
    try testing.expectEqual(@as(i64, 7), row.content_bytes);

    // The object really holds the body.
    const stored = try objects.asStorage().get(alloc, key);
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\n", stored);

    // Dual-write: the column still holds it too, so a list read needs no
    // round-trip.
    try testing.expectEqualStrings("# Plan\n", row.content);
    try testing.expectEqualStrings("# Plan\n", row.preview);
}

test "getDocument reads the body from the object, not the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "column copy",
    });
    defer freeDocumentRow(alloc, created);

    // Overwrite the object behind the row's back. A read that returns this
    // text can only have come from the store.
    try objects.asStorage().put(created.content_key.?, "object copy");

    const row = try store.getDocument(alloc, "ws_1", created.id);
    defer freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("object copy", row.content);
}

test "getDocument falls back to the column when the object is gone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "column copy",
    });
    defer freeDocumentRow(alloc, created);

    try objects.asStorage().delete(created.content_key.?);

    const row = try store.getDocument(alloc, "ws_1", created.id);
    defer freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("column copy", row.content);
}

test "getDocument with no store never touches the object" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "column copy",
    });
    defer freeDocumentRow(alloc, created);

    const row = try getDocument(alloc, &ctx.db, "ws_1", created.id);
    defer freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("column copy", row.content);
}

test "updateDocument with a store points the row at the new body's key" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "first version",
    });
    defer freeDocumentRow(alloc, created);
    const first_key = try alloc.dupe(u8, created.content_key.?);
    defer alloc.free(first_key);

    const updated = try store.updateDocument(alloc, "ws_1", created.id, .{ .content = "second version" });
    defer freeDocumentRow(alloc, updated);

    // A new body means a new digest, so a new key.
    try testing.expect(!std.mem.eql(u8, first_key, updated.content_key.?));
    try testing.expectEqual(@as(i64, 14), updated.content_bytes);

    const stored = try objects.asStorage().get(alloc, updated.content_key.?);
    defer alloc.free(stored);
    try testing.expectEqualStrings("second version", stored);

    // The old object is an orphan, not a dangling pointer: the row moved on.
    const old = try objects.asStorage().get(alloc, first_key);
    defer alloc.free(old);
    try testing.expectEqualStrings("first version", old);
}

test "updateDocument with a store and no content change keeps the same key" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "unchanged body",
    });
    defer freeDocumentRow(alloc, created);
    const first_key = try alloc.dupe(u8, created.content_key.?);
    defer alloc.free(first_key);

    const updated = try store.updateDocument(alloc, "ws_1", created.id, .{ .title = "Renamed" });
    defer freeDocumentRow(alloc, updated);

    try testing.expectEqualStrings("Renamed", updated.title);
    try testing.expectEqualStrings(first_key, updated.content_key.?);
    try testing.expectEqualStrings("unchanged body", updated.content);
}

test "deleteDocument with a store removes the object too" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    });
    const key = try alloc.dupe(u8, created.content_key.?);
    defer alloc.free(key);
    const id = try alloc.dupe(u8, created.id);
    defer alloc.free(id);
    freeDocumentRow(alloc, created);

    try store.deleteDocument(alloc, "ws_1", id);

    try testing.expectError(error.NotFound, objects.asStorage().get(alloc, key));
    try testing.expectError(error.NotFound, store.getDocument(alloc, "ws_1", id));
}

test "createDocument writes no row when the object store refuses the body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var marker: u8 = 0;
    const store = Store{ .db = &ctx.db, .storage = failingStorage(&marker) };

    try testing.expectError(error.InsertFailed, store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    }));

    // Object-first ordering: a failed PUT must leave no row behind, because a
    // row pointing at nothing is a broken read.
    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "updateDocument leaves the row untouched when the object store refuses" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const created = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "original",
    });
    defer freeDocumentRow(alloc, created);

    var marker: u8 = 0;
    const store = Store{ .db = &ctx.db, .storage = failingStorage(&marker) };

    try testing.expectError(error.UpdateFailed, store.updateDocument(alloc, "ws_1", created.id, .{
        .content = "replacement",
    }));

    const row = try getDocument(alloc, &ctx.db, "ws_1", created.id);
    defer freeDocumentRow(alloc, row);
    try testing.expectEqualStrings("original", row.content);
}

test "listDocuments still reads the column, so a list needs no object round-trip" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const created = try store.createDocument(alloc, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    });
    defer freeDocumentRow(alloc, created);

    // Remove the object: a list that needed it would now fail or blank out.
    try objects.asStorage().delete(created.content_key.?);

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("body", rows[0].content);
    try testing.expectEqualStrings("body", rows[0].preview);
}

// ─── Backfill ───────────────────────────────────────────────────────────

test "backfill moves a column-only body into the object store" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Written with no store, so the body is only in the column.
    const seeded = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "# Plan\n- ship it\n",
    });
    defer freeDocumentRow(alloc, seeded);
    try testing.expect(seeded.content_key == null);

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const report = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 1), report.scanned);
    try testing.expectEqual(@as(usize, 1), report.moved);
    try testing.expectEqual(@as(usize, 0), report.failed);

    const row = try store.getDocument(alloc, "ws_1", seeded.id);
    defer freeDocumentRow(alloc, row);

    const key = row.content_key orelse return error.KeyMissing;
    try testing.expect(std.mem.startsWith(u8, key, "ws/ws_1/documents/"));

    var expected: [object_store.SHA256_HEX_BYTES]u8 = undefined;
    object_store.sha256Hex("# Plan\n- ship it\n", &expected);
    try testing.expectEqualStrings(&expected, row.content_sha256.?);
    try testing.expectEqual(@as(i64, 17), row.content_bytes);
    try testing.expectEqualStrings("# Plan\n- ship it\n", row.preview);

    // The object holds the body, and the column still does too.
    const stored = try objects.asStorage().get(alloc, key);
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\n- ship it\n", stored);
    try testing.expectEqualStrings("# Plan\n- ship it\n", row.content);
}

test "backfill is idempotent: a second run moves nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    });
    defer freeDocumentRow(alloc, seeded);

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const first = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 1), first.moved);

    const second = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 0), second.scanned);
    try testing.expectEqual(@as(usize, 0), second.moved);

    // And the object count did not grow.
    try testing.expectEqual(@as(usize, 1), objects.count());
}

test "backfill skips an empty body and leaves its key null" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Blank",
        .content = "",
    });
    defer freeDocumentRow(alloc, seeded);

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const report = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 1), report.scanned);
    try testing.expectEqual(@as(usize, 0), report.moved);
    try testing.expectEqual(@as(usize, 1), report.skipped_empty);
    try testing.expectEqual(@as(usize, 0), objects.count());

    const row = try store.getDocument(alloc, "ws_1", seeded.id);
    defer freeDocumentRow(alloc, row);
    try testing.expect(row.content_key == null);
}

test "backfill dry run reports what would move and writes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    });
    defer freeDocumentRow(alloc, seeded);

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const report = try store.backfill(alloc, .{ .dry_run = true });
    try testing.expectEqual(@as(usize, 1), report.moved);
    try testing.expectEqual(@as(usize, 0), objects.count());

    const row = try store.getDocument(alloc, "ws_1", seeded.id);
    defer freeDocumentRow(alloc, row);
    try testing.expect(row.content_key == null);
}

test "backfill with a limit is resumable: the next run picks up the rest" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for (0..3) |i| {
        const title = try std.fmt.allocPrint(alloc, "Doc {d}", .{i});
        defer alloc.free(title);
        const row = try createDocument(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .title = title,
            .content = "body",
        });
        freeDocumentRow(alloc, row);
    }

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const first = try store.backfill(alloc, .{ .limit = 2 });
    try testing.expectEqual(@as(usize, 2), first.moved);

    const second = try store.backfill(alloc, .{ .limit = 2 });
    try testing.expectEqual(@as(usize, 1), second.moved);

    const third = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 0), third.scanned);
    try testing.expectEqual(@as(usize, 3), objects.count());
}

test "backfill scoped to one workspace leaves the other alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const mine = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_1", .title = "Mine", .content = "a" });
    defer freeDocumentRow(alloc, mine);
    const theirs = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_2", .title = "Theirs", .content = "b" });
    defer freeDocumentRow(alloc, theirs);

    var objects = memory_backend.MemoryStorage.init(alloc);
    defer objects.deinit();
    const store = Store{ .db = &ctx.db, .storage = objects.asStorage() };

    const report = try store.backfill(alloc, .{ .workspace_id = "ws_1" });
    try testing.expectEqual(@as(usize, 1), report.moved);

    const untouched = try store.getDocument(alloc, "ws_2", theirs.id);
    defer freeDocumentRow(alloc, untouched);
    try testing.expect(untouched.content_key == null);
}

test "backfill with no object store is refused" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.NoStorage, (Store{ .db = &ctx.db }).backfill(alloc, .{}));
}

test "backfill counts a refused body as failed and leaves the row alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const seeded = try createDocument(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .title = "Plan",
        .content = "body",
    });
    defer freeDocumentRow(alloc, seeded);

    var marker: u8 = 0;
    const store = Store{ .db = &ctx.db, .storage = failingStorage(&marker) };

    const report = try store.backfill(alloc, .{});
    try testing.expectEqual(@as(usize, 1), report.scanned);
    try testing.expectEqual(@as(usize, 0), report.moved);
    try testing.expectEqual(@as(usize, 1), report.failed);

    const row = try getDocument(alloc, &ctx.db, "ws_1", seeded.id);
    defer freeDocumentRow(alloc, row);
    try testing.expect(row.content_key == null);
    try testing.expectEqualStrings("body", row.content);
}

// ─── Search without the body ────────────────────────────────────────────

test "searchDocuments finds a document by a word in its preview when the body is gone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The shape a row has once its body lives in the object store: `content`
    // is empty and only `preview` is left in SQL.
    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content, preview, content_bytes)
        \\VALUES ('doc_moved', 'ws_1', 'Release plan', '', 'ship the zephyrword turbine', 4096)
    , &[_][]const u8{});

    const rows = try searchDocuments(alloc, &ctx.db, "ws_1", "zephyrword");
    defer freeDocumentRows(alloc, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("doc_moved", rows[0].id);
    // The body is still absent — search found it, it did not resurrect it.
    try testing.expectEqualStrings("", rows[0].content);
    try testing.expectEqualStrings("ship the zephyrword turbine", rows[0].preview);
}

test "searchDocuments still finds a word that is only in the body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A body longer than the preview: the needle sits past the 512-byte cut,
    // so only the `content` column can answer.
    const body = "x" ** (PREVIEW_MAX_BYTES + 10) ++ "quasarterm";
    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content, preview, content_bytes)
        \\VALUES ('doc_long', 'ws_1', 'Long', ?, ?, ?)
    , &[_][]const u8{ body, previewOf(body), "522" });

    const rows = try searchDocuments(alloc, &ctx.db, "ws_1", "quasarterm");
    defer freeDocumentRows(alloc, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("doc_long", rows[0].id);
}

test "searchDocuments does not match a word that is in neither the preview nor the body" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content, preview)
        \\VALUES ('doc_moved', 'ws_1', 'Release plan', '', 'ship it')
    , &[_][]const u8{});

    const rows = try searchDocuments(alloc, &ctx.db, "ws_1", "hippopotamus");
    defer freeDocumentRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}
