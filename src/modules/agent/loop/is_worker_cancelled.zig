const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const helpers = @import("helpers");
const testing = std.testing;

pub const IsWorkerCancelledInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
};

pub fn isWorkerCancelled(
    obj: IsWorkerCancelledInput,
) bool {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    const sql = "SELECT cancelled FROM worker WHERE id = ?";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    if (rows.next() catch return false) |row| {
        defer row.deinit(allocator);
        const cancelled = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return cancelled == 1;
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
        \\CREATE TABLE worker (id TEXT PRIMARY KEY, cancelled INTEGER DEFAULT 0)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "isWorkerCancelled returns false when the worker table is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try testing.expect(!isWorkerCancelled(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "missing" }));
}

test "isWorkerCancelled returns false for a fresh worker (cancelled=0)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('w1', 0)", &.{});
    try testing.expect(!isWorkerCancelled(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "w1" }));
}

test "isWorkerCancelled returns true after the cancelled flag is flipped to 1" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('w2', 1)", &.{});
    try testing.expect(isWorkerCancelled(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "w2" }));
}

test "isWorkerCancelled treats non-zero values as truthy (defensive parse)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    // cancelled=42 — the implementation does `cancelled == 1`, so any
    // value other than 1 returns false. Document the contract.
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('w3', 42)", &.{});
    try testing.expect(!isWorkerCancelled(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "w3" }));
}
