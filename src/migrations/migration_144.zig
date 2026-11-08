const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const dropColumnIfExists = common.dropColumnIfExists;

/// Migration 144 — the body lives in the object store, so the column that used
/// to hold it goes. IRREVERSIBLE: run `pabrik headless documents backfill`
/// first, and only after every row reports `content_key` set.
pub const Migration144DropDocumentContent = struct {
    pub const version: u32 = 144;
    pub const name = "drop_document_content";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try dropColumnIfExists(.{ .db = db }, allocator, "documents", "content");
    }
};

const testing = std.testing;
const migration = @import("migration.zig");

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
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
        \\  position INTEGER NOT NULL DEFAULT 0,
        \\  content_key TEXT DEFAULT NULL,
        \\  content_sha256 TEXT DEFAULT NULL,
        \\  content_bytes INTEGER NOT NULL DEFAULT 0,
        \\  preview TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content, content_key, preview)
        \\VALUES ('doc_a', 'ws_1', 'Plan', 'the body', 'ws/ws_1/documents/doc_a/abc.md', 'the body')
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn hasColumn(ctx: *TestCtx, wanted: []const u8) !bool {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("documents"), &[_][]const u8{});
    defer q.deinit();
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], wanted)) return true;
    }
    return false;
}

test "Migration144 drops the content column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try testing.expect(try hasColumn(&ctx, "content"));

    try Migration144DropDocumentContent.up(&ctx.db, testing.allocator);

    try testing.expect(!try hasColumn(&ctx, "content"));
}

test "Migration144 leaves the pointer and the preview in place" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration144DropDocumentContent.up(&ctx.db, testing.allocator);

    try testing.expect(try hasColumn(&ctx, "content_key"));
    try testing.expect(try hasColumn(&ctx, "preview"));
    try testing.expect(try hasColumn(&ctx, "content_bytes"));

    var row = try ctx.db.queryRow(
        testing.allocator,
        "SELECT COALESCE(content_key, ''), COALESCE(preview, '') FROM documents WHERE id = 'doc_a'",
        &[_][]const u8{},
    );
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("ws/ws_1/documents/doc_a/abc.md", row.values[0]);
    try testing.expectEqualStrings("the body", row.values[1]);
}

test "Migration144 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration144DropDocumentContent.up(&ctx.db, testing.allocator);
    try Migration144DropDocumentContent.up(&ctx.db, testing.allocator);

    try testing.expect(!try hasColumn(&ctx, "content"));
}

test "Migration144 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration144DropDocumentContent.version) return;
    }
    return error.Migration144NotRegistered;
}
