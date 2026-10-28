const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;

/// Check if a session is currently running (exists in worker table)
pub fn isWorkerRunning(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM worker WHERE id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    if (rows.next() catch return false) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT, working_directory TEXT, last_activity_nano BIGINT)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "isWorkerRunning returns false when the worker table is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try testing.expect(!isWorkerRunning(testing.allocator, &s.db, "missing"));
}

test "isWorkerRunning returns false for a session_id not in the worker table" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_nano) VALUES ('other', 's_other', '/tmp', 0)",
        &.{});
    try testing.expect(!isWorkerRunning(testing.allocator, &s.db, "nope"));
}

test "isWorkerRunning returns true after the worker row is inserted" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO worker (id, session_id, working_directory, last_activity_nano) VALUES ('w1', 's1', '/tmp', 0)",
        &.{});
    try testing.expect(isWorkerRunning(testing.allocator, &s.db, "w1"));
}

test "isWorkerRunning tolerates an empty session_id without crashing" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    // Empty string is a valid (zero-length) session_id — the query just
    // returns false because no row matches.
    try testing.expect(!isWorkerRunning(testing.allocator, &s.db, ""));
}
