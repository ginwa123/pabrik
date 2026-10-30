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
    position: i64,
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

/// The SELECT list, shared by every read so no call site can accidentally
/// return a different shape.
const SELECT_COLUMNS =
    "SELECT id, workspace_id, title, content, format, " ++
    "COALESCE(CAST(created_at AS TEXT), ''), COALESCE(CAST(updated_at AS TEXT), ''), " ++
    "COALESCE(CAST(position AS TEXT), '0') " ++
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
        .position = std.fmt.parseInt(i64, values[7], 10) catch 0,
    };
}

pub fn listDocuments(
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
            " AND (LOWER(title) LIKE LOWER(?) ESCAPE '\\' OR LOWER(content) LIKE LOWER(?) ESCAPE '\\')" ++
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
        \\INSERT INTO documents (id, workspace_id, title, content, format, position, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), 'markdown'), COALESCE((SELECT MIN(position) FROM documents WHERE workspace_id = ?), 0) - 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    , &[_][]const u8{ document_id, args.workspace_id, title, args.content, format, args.workspace_id }) catch
        return error.InsertFailed;

    // The re-read uses a wider error set than this function declares, so map
    // it: a genuine "row is gone" is the consistency error, and anything else
    // (query failure, OOM) is a failed insert from the caller's point of
    return getDocument(allocator, db, args.workspace_id, document_id) catch |err| switch (err) {
        error.NotFound, error.IdsRequired, error.QueryFailed => error.RowNotFoundAfterInsert,
        error.OutOfMemory => error.InsertFailed,
    };
}

/// Patch a document. Absent fields keep their current value and `updated_at`
/// always advances.
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
    ordered_ids: []const []const u8,
) ReorderDocumentsError!void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (ordered_ids.len == 0) return error.EmptyOrder;

    var q = db.query(
        allocator,
        "SELECT id FROM documents WHERE workspace_id = ?",
        &[_][]const u8{workspace_id},
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
            "UPDATE documents SET position = ? WHERE id = ? AND workspace_id = ?",
            &[_][]const u8{ position, id, workspace_id },
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
}

/// Free a slice of rows. The slice header is freed last.
pub fn freeDocumentRows(allocator: std.mem.Allocator, rows: []DocumentRow) void {
    for (rows) |row| freeDocumentRow(allocator, row);
    allocator.free(rows);
}

const testing = std.testing;
const test_db = @import("pabrikcore").test_db;
const migration = @import("../migrations/migration.zig");

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

    try reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{ "doc_c", "doc_a", "doc_b" });

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

    try reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{ "doc_b", "doc_a" });

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
        reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{ "doc_b", "doc_x" }),
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
        reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{"doc_missing"}),
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
        reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{ "doc_a", "doc_a", "doc_b" }),
    );
}

test "reorderDocuments: an empty order and an empty workspace are rejected" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyOrder,
        reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{}),
    );
    try testing.expectError(
        error.WorkspaceIdRequired,
        reorderDocuments(alloc, &ctx.db, "", &[_][]const u8{"doc_a"}),
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

    try reorderDocuments(alloc, &ctx.db, "ws_1", &[_][]const u8{ first.id, second.id });

    const third = try createDocument(alloc, &ctx.db, .{ .workspace_id = "ws_1", .title = "Third" });
    defer freeDocumentRow(alloc, third);

    const rows = try listDocuments(alloc, &ctx.db, "ws_1");
    defer freeDocumentRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("Third", rows[0].title);
    try testing.expectEqualStrings("First", rows[1].title);
    try testing.expectEqualStrings("Second", rows[2].title);
}
