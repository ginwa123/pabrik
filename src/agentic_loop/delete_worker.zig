const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
const onEventSendWorkers = @import("sse_send_event_worker.zig").onEventSendWorkers;
const testing = std.testing;

pub const DeleteWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    session_id: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
    /// The run's lease (see `session_lock.zig`): when set, only the row with
    /// THIS token is removed, so a run that lost its slot cannot delete the
    /// winner's row. Empty means "any row for this session" (cancel paths).
    run_token: []const u8 = "",
};

pub fn deleteWorker(
    obj: DeleteWorkerInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;
    const is_emit_sse = obj.is_emit_sse;
    const event_bus = obj.event_bus;
    const logger = obj.logger;

    if (obj.run_token.len > 0) {
        try db.exec(allocator, "DELETE FROM worker WHERE id = ? AND run_token = ?", &.{ session_id, obj.run_token });
    } else {
        try db.exec(allocator, "DELETE FROM worker WHERE id = ?", &.{session_id});
    }

    if (is_emit_sse) {
        if (event_bus) |ev| {
            // Emit worker deleted event so connected SSE clients can drop the entry
            onEventSendWorkers(allocator, .{
                .action = "deleted",
                .id = session_id,
                .session_id = "",
                .working_directory = "",
                .last_activity = 0,
                .last_activity_description = "",
                .created_at = "",
                .event_bus = ev,
            }) catch |err| {
                logger.?.errFmt("[DELETE WORKER] Failed to send worker event: {s}\n", .{@errorName(err)});
            };
        }
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

fn setupDb() !struct { db: database.Db, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT, run_token TEXT NOT NULL DEFAULT '')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "deleteWorker removes the matching worker row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "w1",
        .event_bus = null,
        .is_emit_sse = false,
    });

    // The DELETE removed w1; the query below should return no rows.
    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w1'", &.{});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        return error.DeleteShouldHaveRemovedRow;
    }
}

test "deleteWorker is a no-op when the worker does not exist" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    // DELETE matching zero rows is not an error in SQLite.
    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "ghost",
        .event_bus = null,
        .is_emit_sse = false,
    });
}

test "deleteWorker only removes the matching row, not other rows" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO worker (id, session_id) VALUES ('w1', 's1'), ('w2', 's2'), ('w3', 's3')",
        &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "w2",
        .event_bus = null,
        .is_emit_sse = false,
    });

    // After deleting w2 from {w1, w2, w3}, only w1 and w3 remain (in
    // alphabetical id order).
    var q = try s.db.query(testing.allocator, "SELECT id FROM worker ORDER BY id", &.{});
    defer q.deinit();
    var ids: [2]?[]u8 = .{ null, null };
    defer for (ids) |maybe| if (maybe) |id| testing.allocator.free(id);
    var i: usize = 0;
    while (try q.next()) |row| : (i += 1) {
        defer row.deinit(testing.allocator);
        if (i < 2) ids[i] = try testing.allocator.dupe(u8, row.values[0]);
    }
    try testing.expectEqualStrings("w1", ids[0].?);
    try testing.expectEqualStrings("w3", ids[1].?);
}

test "deleteWorker with is_emit_sse=true and event_bus=null is a safe no-op for the SSE branch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "w1",
        .event_bus = null,
        .is_emit_sse = true,
    });
    // Confirm the row was deleted despite the SSE branch being skipped.
    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 'w1'", &.{});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        return error.DeleteShouldHaveRemovedRow;
    }
}

test "deleteWorker with is_emit_sse=false short-circuits before any event_bus access" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator, "INSERT INTO worker (id, session_id) VALUES ('w1', 's1')", &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "w1",
        .event_bus = null,
        .is_emit_sse = false,
    });
}

test "deleteWorker with a matching run_token removes the row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO worker (id, session_id, run_token) VALUES ('s1', 's1', 'run-a')",
        &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "s1",
        .event_bus = null,
        .is_emit_sse = false,
        .run_token = "run-a",
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM worker WHERE id = 's1'", &.{});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        return error.DeleteShouldHaveRemovedRow;
    }
}

test "deleteWorker with a stale run_token leaves the row a newer run owns" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO worker (id, session_id, run_token) VALUES ('s1', 's1', 'run-b')",
        &.{});

    try deleteWorker(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "s1",
        .event_bus = null,
        .is_emit_sse = false,
        .run_token = "run-a",
    });

    var row = try s.db.queryRow(testing.allocator, "SELECT run_token FROM worker WHERE id = 's1'", &.{});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("run-b", row.values[0]);
}
