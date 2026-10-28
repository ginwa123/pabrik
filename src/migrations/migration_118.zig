const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 118 — `worker.run_token`: the per-session run lease, claimed by one
/// compare-and-swap statement (see `session_lock.zig`). Empty means unowned.
pub const Migration118AddWorkerRunToken = struct {
    pub const version: u32 = 118;
    pub const name = "add_worker_run_token";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "worker",
            "run_token",
            "run_token TEXT NOT NULL DEFAULT ''",
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
        \\CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT NOT NULL)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration118 adds run_token and leaves pre-existing worker rows unowned" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('s1', 's1')", &[_][]const u8{});

    try Migration118AddWorkerRunToken.up(db, alloc);

    var row = try db.queryRow(alloc, "SELECT run_token FROM worker WHERE id = 's1'", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration118 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration118AddWorkerRunToken.up(db, alloc);
    try Migration118AddWorkerRunToken.up(db, alloc);

    var row = try db.queryRow(alloc, "SELECT COUNT(*) FROM pragma_table_info('worker') WHERE name = 'run_token'", &[_][]const u8{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration118 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration118AddWorkerRunToken.version) return;
    }
    return error.Migration118NotRegistered;
}
