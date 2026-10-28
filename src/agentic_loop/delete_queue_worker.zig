const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const SseEvent = @import("sse.zig").SseEvent;

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const event_bus_mod = pabrikcore.event_bus;
const testing = std.testing;

pub const DeleteQueueMessagesInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    is_emit_sse: bool,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    id: []const u8,
};

/// Delete a specific queued message by id and emit SSE event
pub fn deleteQueuedMessage(
    obj: DeleteQueueMessagesInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const event_bus = obj.event_bus;

    const session_id = obj.session_id;
    const id = obj.id;
    const is_emit_sse = obj.is_emit_sse;

    const sql = "DELETE FROM session_queue_messages WHERE session_id = ? AND id = ? ";
    try db.exec(allocator, sql, &.{ session_id, id });

    if (is_emit_sse) {
        if (event_bus) |ev| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            const payload = .{
                .action = "deleted",
                .id = id,
                .session_id = session_id,
            };
            try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
                .whitespace = .indent_4,
            })});

            const data_copy = try allocator.dupe(u8, buf.items);
            const event = SseEvent{
                .session_id = session_id,
                .data = data_copy,
                .event_type = "queue_deleted",
            };

            // Per-session emit (kept for any future server-side fan-out that
            // needs only this session's queue messages).
            const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
            defer allocator.free(key);
            ev.emit(SseEvent, key, event);
            // Central broadcast: subscribers to bare "queue" receive ALL sessions'
            // queue messages (including deletes). The frontend listener filter
            // narrows to the current session_id on the JS side.
            ev.emit(SseEvent, "queue", event);
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
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    image_url TEXT,
        \\    video_url TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "deleteQueuedMessage removes the matching (session_id, id) row" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES ('m1', 's1', 'hello', '')",
        &.{});

    try deleteQueuedMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .is_emit_sse = false,
        .event_bus = null,
        .session_id = "s1",
        .id = "m1",
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM session_queue_messages", &.{});
    defer q.deinit();
    const row = try q.next();
    if (row != null) {
        defer row.?.deinit(testing.allocator);
        return error.DeleteShouldHaveRemovedRow;
    }
}

test "deleteQueuedMessage is a no-op when the row does not exist" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    // No INSERT — DELETE matching zero rows is not an error. Tighten
    // the assertion: after the call, the table is still empty (count=0)
    // — proves the function did not accidentally delete a phantom row.
    try deleteQueuedMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .is_emit_sse = false,
        .event_bus = null,
        .session_id = "s1",
        .id = "m_missing",
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM session_queue_messages", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "deleteQueuedMessage filters by both session_id and id" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        \\INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES
        \\('m1', 's1', 'hello', ''),
        \\('m2', 's2', 'hello', ''),
        \\('m3', 's1', 'goodbye', '')
    , &.{});

    // Delete only the (s1, id=m1) row.
    try deleteQueuedMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .is_emit_sse = false,
        .event_bus = null,
        .session_id = "s1",
        .id = "m1",
    });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM session_queue_messages", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("2", row.values[0]);

    // Confirm (s2, hello) and (s1, goodbye) both survive.
    var q2 = try s.db.query(testing.allocator, "SELECT session_id, message FROM session_queue_messages ORDER BY id", &.{});
    defer q2.deinit();
    var survivors: [2]?struct { s: []u8, m: []u8 } = .{ null, null };
    defer for (survivors) |maybe| if (maybe) |r| {
        testing.allocator.free(r.s);
        testing.allocator.free(r.m);
    };
    var i: usize = 0;
    while (try q2.next()) |r| : (i += 1) {
        defer r.deinit(testing.allocator);
        if (i < 2) survivors[i] = .{
            .s = try testing.allocator.dupe(u8, r.values[0]),
            .m = try testing.allocator.dupe(u8, r.values[1]),
        };
    }
    try testing.expectEqualStrings("s2", survivors[0].?.s);
    try testing.expectEqualStrings("hello", survivors[0].?.m);
    try testing.expectEqualStrings("s1", survivors[1].?.s);
    try testing.expectEqualStrings("goodbye", survivors[1].?.m);
}

test "deleteQueuedMessage with is_emit_sse=true and event_bus=null is a safe no-op for the SSE branch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES ('m1', 's1', 'hello', '')",
        &.{});

    try deleteQueuedMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .is_emit_sse = true,
        .event_bus = null,
        .session_id = "s1",
        .id = "m1",
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM session_queue_messages", &.{});
    defer q.deinit();
    const row = try q.next();
    if (row != null) {
        defer row.?.deinit(testing.allocator);
        return error.DeleteShouldHaveRemovedRow;
    }
}
