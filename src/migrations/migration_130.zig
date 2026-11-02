const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 130 — `logs.message_truncated`, so a row says whether the message
/// it holds is the whole message or the first 8 KB of one.
pub const Migration130AddLogMessageTruncated = struct {
    pub const version: u32 = 130;
    pub const name = "add_log_message_truncated";

    pub const column = "message_truncated";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "logs",
            column,
            "message_truncated INTEGER NOT NULL DEFAULT 0",
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
        \\CREATE TABLE logs (
        \\  id TEXT PRIMARY KEY,
        \\  created_at_nano INTEGER NOT NULL,
        \\  level TEXT NOT NULL,
        \\  kind TEXT NOT NULL,
        \\  message TEXT NOT NULL,
        \\  stack TEXT,
        \\  source TEXT,
        \\  line INTEGER,
        \\  route_path TEXT,
        \\  session_id TEXT,
        \\  count INTEGER NOT NULL DEFAULT 1
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn flagOf(alloc: std.mem.Allocator, db: *Backend, id: []const u8) ![]u8 {
    var row = try db.queryRow(alloc, "SELECT message_truncated FROM logs WHERE id = ?", &[_][]const u8{id});
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

fn columnCount(alloc: std.mem.Allocator, db: *Backend) !u64 {
    var row = try db.queryRow(
        alloc,
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("logs") ++ " WHERE name = ?",
        &[_][]const u8{Migration130AddLogMessageTruncated.column},
    );
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10) catch 0;
}

test "Migration130 leaves a row written before it unmarked, not silently truncated" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message) VALUES ('log_before', 1, 'warn', 'console_warn', 'old')",
        &[_][]const u8{},
    );

    try Migration130AddLogMessageTruncated.up(db, alloc);

    const flag = try flagOf(alloc, db, "log_before");
    defer alloc.free(flag);
    try testing.expectEqualStrings("0", flag);
}

test "Migration130 accepts a row that marks itself truncated" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration130AddLogMessageTruncated.up(db, alloc);
    try db.exec(
        alloc,
        "INSERT INTO logs (id, created_at_nano, level, kind, message, message_truncated) VALUES ('log_after', 1, 'warn', 'console_warn', 'cut', 1)",
        &[_][]const u8{},
    );

    const flag = try flagOf(alloc, db, "log_after");
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);
}

test "Migration130 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration130AddLogMessageTruncated.up(db, alloc);
    try Migration130AddLogMessageTruncated.up(db, alloc);

    try testing.expectEqual(@as(u64, 1), try columnCount(alloc, db));
}

test "Migration130 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration130AddLogMessageTruncated.version) return;
    }
    return error.Migration130NotRegistered;
}
