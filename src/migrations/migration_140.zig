const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Folders for workspace documents: one new table plus one nullable column on
/// `documents`. A folder's parent is another folder; `parent_id IS NULL` is the
/// root, so "top level" needs no sentinel row.
pub const Migration140AddDocumentFolders = struct {
    pub const version: u32 = 140;
    pub const name = "add_document_folders";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS document_folders (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_id TEXT NOT NULL,
            \\    parent_id TEXT DEFAULT NULL,
            \\    name TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});

        // One level is one ordered read: the list route fetches every folder of
        // the workspace and the client assembles the tree.
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_document_folders_workspace_parent ON document_folders(workspace_id, parent_id, position)", &[_][]const u8{});

        // Nullable on purpose: every document that already exists stays at the
        // root, and a document whose folder disappears lands back there rather
        // than being deleted with it.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "folder_id",
            "folder_id TEXT DEFAULT NULL",
        );
    }
};

const testing = std.testing;

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE documents (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  title TEXT NOT NULL DEFAULT '',
        \\  content TEXT NOT NULL DEFAULT '',
        \\  format TEXT NOT NULL DEFAULT 'markdown',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title) VALUES ('doc_old', 'ws_1', 'Old')
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn folderColumnCount(alloc: std.mem.Allocator, db: *Backend) !usize {
    var rows = try db.query(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("document_folders") ++
            " WHERE name = 'parent_id'",
        &[_][]const u8{},
    );
    var row = (try rows.next()) orelse return error.NoRow;
    const n = try std.fmt.parseInt(usize, row.values[0], 10);
    row.deinit(alloc);
    rows.deinit();
    return n;
}

test "Migration140 creates document_folders with a nullable parent" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration140AddDocumentFolders.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO document_folders (id, workspace_id, name) VALUES ('f_root', 'ws_1', 'Root')
    , &[_][]const u8{});
    try ctx.db.exec(alloc,
        \\INSERT INTO document_folders (id, workspace_id, parent_id, name) VALUES ('f_child', 'ws_1', 'f_root', 'Child')
    , &[_][]const u8{});

    var q = try ctx.db.query(
        alloc,
        "SELECT COUNT(*) FROM document_folders WHERE workspace_id = 'ws_1'",
        &[_][]const u8{},
    );
    const row = (try q.next()) orelse return error.NoRow;
    try testing.expectEqualStrings("2", row.values[0]);
    row.deinit(alloc);
    q.deinit();
}

test "Migration140 leaves every existing document at the root" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration140AddDocumentFolders.up(&ctx.db, alloc);

    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(folder_id, '') FROM documents WHERE id = 'doc_old'",
        &[_][]const u8{},
    );
    const row = (try q.next()) orelse return error.NoRow;
    try testing.expectEqualStrings("", row.values[0]);
    row.deinit(alloc);
    q.deinit();
}

test "Migration140 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration140AddDocumentFolders.up(&ctx.db, alloc);
    try Migration140AddDocumentFolders.up(&ctx.db, alloc);

    try testing.expectEqual(@as(usize, 1), try folderColumnCount(alloc, &ctx.db));
}

test "Migration140 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration140AddDocumentFolders.version) return;
    }
    return error.Migration140NotRegistered;
}
