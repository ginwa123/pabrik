const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;
const addColumnIfMissing = common.addColumnIfMissing;

pub const Migration126AddMigrationAppliedAt = struct {
    pub const version: u32 = 126;
    pub const name = "add_migration_applied_at";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "schema_migrations",
            "applied_at",
            "applied_at TIMESTAMP",
        );

        try db.exec(allocator,
            \\UPDATE schema_migrations SET applied_at = CURRENT_TIMESTAMP WHERE applied_at IS NULL
        , &[_][]const u8{});
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
        \\CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn count(alloc: std.mem.Allocator, db: *Backend, sql: []const u8) !u64 {
    var row = try db.queryRow(alloc, sql, &[_][]const u8{});
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10) catch 0;
}

fn appliedAtOf(alloc: std.mem.Allocator, db: *Backend, version: u32) ![]u8 {
    var version_buf: [16]u8 = undefined;
    const version_str = std.fmt.bufPrint(&version_buf, "{d}", .{version}) catch return error.BufferTooSmall;
    var row = try db.queryRow(alloc, "SELECT applied_at FROM schema_migrations WHERE version = ?", &[_][]const u8{version_str});
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "Migration126 stamps every migration a database already applied" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(
        alloc,
        "INSERT INTO schema_migrations (version, name) VALUES (1, 'first'), (124, 'latest')",
        &[_][]const u8{},
    );

    try Migration126AddMigrationAppliedAt.up(db, alloc);

    for ([_]u32{ 1, 124 }) |version| {
        const stamp = try appliedAtOf(alloc, db, version);
        defer alloc.free(stamp);
        try testing.expect(stamp.len > 0);
    }

    try testing.expectEqual(@as(u64, 2), try count(alloc, db, "SELECT COUNT(*) FROM schema_migrations"));
    const names = try count(alloc, db, "SELECT COUNT(*) FROM schema_migrations WHERE name IN ('first', 'latest')");
    try testing.expectEqual(@as(u64, 2), names);
}

test "Migration126 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO schema_migrations (version, name) VALUES (7, 'seven')", &[_][]const u8{});

    try Migration126AddMigrationAppliedAt.up(db, alloc);
    try Migration126AddMigrationAppliedAt.up(db, alloc);

    const columns = try count(alloc, db, "SELECT COUNT(*) FROM " ++
        comptime dialect.tableColumns("schema_migrations") ++ " WHERE name = 'applied_at'");
    try testing.expectEqual(@as(u64, 1), columns);
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM schema_migrations"));
}

test "Migration126 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration126AddMigrationAppliedAt.version) return;
    }
    return error.Migration126NotRegistered;
}
