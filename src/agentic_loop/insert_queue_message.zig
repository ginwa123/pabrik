const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const logger_mod = pabrikcore.loggermod;
const event_bus_mod = pabrikcore.event_bus;
const on_event_sent = @import("on_event_sent.zig");
const testing = std.testing;

pub const InsertQueueMessageInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    session_id: []const u8,
    message: []const u8,
    image_url: []const u8,
    video_url: []const u8 = "",
    /// The chat's file attachments, as the JSON payload the model path
    /// reads. Empty when the message carries no file.
    file_attachments: []const u8 = "",
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
};

/// Queue a message for a session and emit SSE event to notify connected clients
pub fn insertQueueMessage(
    obj: InsertQueueMessageInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const event_bus = obj.event_bus;

    const session_id = obj.session_id;
    const message = obj.message;
    const image_url = obj.image_url;
    const video_url = obj.video_url;
    const file_attachments = obj.file_attachments;
    const is_emit_sse = obj.is_emit_sse;

    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(std.Options.debug_io, .real).nanoseconds});
    defer allocator.free(id);

    const sql = "INSERT INTO session_queue_messages (id, session_id, message, image_url, video_url, file_attachments) VALUES (?, ?, ?, ?, ?, ?)";
    const copy_image_url = try allocator.dupe(u8, image_url);
    defer allocator.free(copy_image_url);
    const copy_video_url = try allocator.dupe(u8, video_url);
    defer allocator.free(copy_video_url);
    const copy_file_attachments = try allocator.dupe(u8, file_attachments);
    defer allocator.free(copy_file_attachments);

    try db.exec(allocator, sql, &.{ id, session_id, message, copy_image_url, copy_video_url, copy_file_attachments });

    // Emit SSE event to notify connected clients
    if (is_emit_sse) {
        if (event_bus) |ev| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            const payload = .{
                .action = "queued",
                .id = id,
                .message = message,
                .session_id = session_id,
                .image_url = image_url,
            };
            try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
                .whitespace = .indent_4,
            })});

            const data_copy = try allocator.dupe(u8, buf.items);
            const event = on_event_sent.SseEvent{
                .session_id = session_id,
                .data = data_copy,
                .event_type = "queue_queued",
            };

            // Per-session emit (kept for any future server-side fan-out that
            // needs only this session's queue messages).
            const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
            defer allocator.free(key);
            ev.emit(on_event_sent.SseEvent, key, event);
            // Central broadcast: subscribers to bare "queue" receive ALL sessions'
            // queue messages. The frontend listener filter narrows to the current
            // session_id on the JS side.
            ev.emit(on_event_sent.SseEvent, "queue", event);
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
        \\CREATE TABLE session_queue_messages (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    image_url TEXT,
        \\    video_url TEXT,
        \\    file_attachments TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "insertQueueMessage inserts a row with the given message and image_url" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try insertQueueMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "s1",
        .message = "hello",
        .image_url = "img_data",
        .event_bus = null,
        .is_emit_sse = false,
    });

    var q = try s.db.query(testing.allocator, "SELECT message, image_url FROM session_queue_messages WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", row.values[0]);
    try testing.expectEqualStrings("img_data", row.values[1]);
}

test "insertQueueMessage handles empty image_url without panicking" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try insertQueueMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "s1",
        .message = "no image",
        .image_url = "",
        .event_bus = null,
        .is_emit_sse = false,
    });

    var q = try s.db.query(testing.allocator, "SELECT image_url FROM session_queue_messages WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("", row.values[0]);
}

test "insertQueueMessage inserts each call as a new row (auto-incrementing id)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try insertQueueMessage(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .session_id = "s1", .message = "first", .image_url = "", .event_bus = null, .is_emit_sse = false });
    try insertQueueMessage(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .session_id = "s1", .message = "second", .image_url = "", .event_bus = null, .is_emit_sse = false });
    try insertQueueMessage(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .session_id = "s1", .message = "third", .image_url = "", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT message FROM session_queue_messages WHERE session_id = 's1' ORDER BY rowid", &.{});
    defer q.deinit();
    var msgs: [3]?[]u8 = .{ null, null, null };
    defer for (msgs) |maybe| if (maybe) |m| testing.allocator.free(m);
    var i: usize = 0;
    while (try q.next()) |row| : (i += 1) {
        defer row.deinit(testing.allocator);
        if (i < 3) msgs[i] = try testing.allocator.dupe(u8, row.values[0]);
    }
    try testing.expectEqualStrings("first", msgs[0].?);
    try testing.expectEqualStrings("second", msgs[1].?);
    try testing.expectEqualStrings("third", msgs[2].?);
}

test "insertQueueMessage filters messages by session_id" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try insertQueueMessage(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .session_id = "s1", .message = "s1 msg", .image_url = "", .event_bus = null, .is_emit_sse = false });
    try insertQueueMessage(.{ .allocator = testing.allocator, .db = &s.db, .logger = null, .session_id = "s2", .message = "s2 msg", .image_url = "", .event_bus = null, .is_emit_sse = false });

    var q = try s.db.query(testing.allocator, "SELECT COUNT(*) FROM session_queue_messages WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "insertQueueMessage with is_emit_sse=true and event_bus=null is a safe no-op for the SSE branch" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    // The implementation must check `if (event_bus) |ev|` BEFORE any
    // payload allocation. The DB writes must still complete.
    try insertQueueMessage(.{
        .allocator = testing.allocator,
        .db = &s.db,
        .logger = null,
        .session_id = "s1",
        .message = "skip",
        .image_url = "",
        .event_bus = null,
        .is_emit_sse = true,
    });

    var q = try s.db.query(testing.allocator, "SELECT 1 FROM session_queue_messages WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
}
