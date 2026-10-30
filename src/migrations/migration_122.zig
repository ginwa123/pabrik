const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration122AddDocumentPosition = struct {
    pub const version: u32 = 122;
    pub const name = "add_document_position";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "position",
            "position INTEGER NOT NULL DEFAULT 0",
        );
    }
};

const testing = std.testing;

fn setupDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
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
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration122 leaves a pre-existing document at position 0 so the sidebar keeps its order" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        "INSERT INTO documents (id, workspace_id, title) VALUES ('doc_old', 'ws_1', 'Old')",
        &[_][]const u8{},
    );

    try Migration122AddDocumentPosition.up(db, alloc);

    var row = try db.queryRow(alloc, "SELECT position FROM documents WHERE id = 'doc_old'", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration122 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration122AddDocumentPosition.up(db, alloc);
    try Migration122AddDocumentPosition.up(db, alloc);

    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("documents") ++ " WHERE name = 'position'",
        &[_][]const u8{},
    );
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration122 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration122AddDocumentPosition.version) return;
    }
    return error.Migration122NotRegistered;
}
