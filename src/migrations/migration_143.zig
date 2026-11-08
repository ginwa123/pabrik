const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 143 — the pointer from a `documents` row to its body in the
/// object store. `content_key IS NULL` means the body is still in `content`,
/// which is what every existing row looks like after this runs.
pub const Migration143AddDocumentContentKey = struct {
    pub const version: u32 = 143;
    pub const name = "add_document_content_key";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // Nullable on purpose: NULL is the "body is in the column" state, so
        // the migration needs no backfill and no downtime.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "content_key",
            "content_key TEXT DEFAULT NULL",
        );

        // Integrity and dedupe: the key is content-addressed, so the digest is
        // what the key was built from.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "content_sha256",
            "content_sha256 TEXT DEFAULT NULL",
        );

        // The body length, so a list can report a size without reading the
        // object.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "content_bytes",
            "content_bytes INTEGER NOT NULL DEFAULT 0",
        );

        // The first slice of the body, kept in SQL so the sidebar and the
        // search excerpt never need a round-trip to the object store.
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "documents",
            "preview",
            "preview TEXT NOT NULL DEFAULT ''",
        );
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
        \\  position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content)
        \\VALUES ('doc_old', 'ws_1', 'Old', 'a body that predates the object store')
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn columnNames(ctx: *TestCtx) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("documents"), &[_][]const u8{});
    defer q.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c);
        out.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try out.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return out.toOwnedSlice(alloc);
}

fn freeColumnNames(names: []const []const u8) void {
    for (names) |c| testing.allocator.free(c);
    testing.allocator.free(names);
}

fn hasColumn(names: []const []const u8, wanted: []const u8) bool {
    for (names) |c| {
        if (std.mem.eql(u8, c, wanted)) return true;
    }
    return false;
}

test "Migration143 adds the four object-store columns" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration143AddDocumentContentKey.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);
    try testing.expect(hasColumn(names, "content_key"));
    try testing.expect(hasColumn(names, "content_sha256"));
    try testing.expect(hasColumn(names, "content_bytes"));
    try testing.expect(hasColumn(names, "preview"));
}

test "Migration143 leaves an existing document pointing at its column" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration143AddDocumentContentKey.up(&ctx.db, testing.allocator);

    var row = try ctx.db.queryRow(
        testing.allocator,
        "SELECT COALESCE(content_key, ''), COALESCE(content_sha256, ''), " ++
            "CAST(content_bytes AS TEXT), COALESCE(preview, ''), content " ++
            "FROM documents WHERE id = 'doc_old'",
        &[_][]const u8{},
    );
    defer row.deinit(testing.allocator);

    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
    try testing.expectEqualStrings("0", row.values[2]);
    try testing.expectEqualStrings("", row.values[3]);
    try testing.expectEqualStrings("a body that predates the object store", row.values[4]);
}

test "Migration143 replaying is a no-op" {
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration143AddDocumentContentKey.up(&ctx.db, testing.allocator);
    try Migration143AddDocumentContentKey.up(&ctx.db, testing.allocator);

    const names = try columnNames(&ctx);
    defer freeColumnNames(names);

    var content_key_count: usize = 0;
    for (names) |c| {
        if (std.mem.eql(u8, c, "content_key")) content_key_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), content_key_count);
}

test "Migration143 is registered in allMigrations" {
    for (migration.allMigrations) |m| {
        if (m.version == Migration143AddDocumentContentKey.version) return;
    }
    return error.Migration143NotRegistered;
}
