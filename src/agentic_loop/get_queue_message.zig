const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;

pub const QueuedMessage = struct {
    id: []const u8,
    message: []const u8,
    image_url: []const u8,
    video_url: []const u8 = "",
    file_attachments: []const u8 = "",
};

pub const GetQueueMessageInput = struct {
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
};

/// Returns null if no messages queued
/// Caller must free the returned slice
pub fn getQueueMessages(
    obj: GetQueueMessageInput,
) !?std.ArrayList(QueuedMessage) {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    const select_sql =
        \\SELECT
        \\    id,
        \\    message,
        \\    image_url,
        \\    COALESCE(video_url, ''),
        \\    COALESCE(file_attachments, '')
        \\FROM session_queue_messages
        \\WHERE session_id = ?
        \\ORDER BY created_at ASC;
    ;
    var rows = try db.query(allocator, select_sql, &.{session_id});
    defer rows.deinit();

    var messages = std.ArrayList(QueuedMessage).empty;
    errdefer {
        for (messages.items) |msg| {
            allocator.free(msg.id);
            allocator.free(msg.message);
            allocator.free(msg.image_url);
            allocator.free(msg.video_url);
            allocator.free(msg.file_attachments);
        }
        messages.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const id = try allocator.dupe(u8, row.values[0]);
        const msg = try allocator.dupe(u8, row.values[1]);
        const image_url = try allocator.dupe(u8, row.values[2]);
        const video_url = try allocator.dupe(u8, row.values[3]);
        const file_attachments = try allocator.dupe(u8, row.values[4]);
        try messages.append(allocator, .{ .id = id, .message = msg, .image_url = image_url, .video_url = video_url, .file_attachments = file_attachments });
    }

    if (messages.items.len == 0) {
        messages.deinit(allocator);
        return null;
    }

    return messages;
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
    // The real schema also has `created_at DEFAULT (datetime('now'))`,
    // which gives the ORDER BY something stable to sort on.
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    message TEXT NOT NULL,
        \\    image_url TEXT,
        \\    video_url TEXT,
        \\    file_attachments TEXT,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Insert one queued message at a fixed created_at so the ORDER BY is
/// deterministic regardless of how fast the tests run.
fn seedMsg(
    db: *database.Db,
    session: []const u8,
    id: []const u8,
    msg: []const u8,
    image: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url, created_at) VALUES (?, ?, ?, ?, ?)",
        &.{ id, session, msg, image, created_at });
}

test "getQueueMessages returns null when the queue is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const result = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    try testing.expect(result == null);
}

test "getQueueMessages returns null for a session with no queued messages" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "other_session", "m1", "hello", "", "2025-01-01 00:00:00");
    const result = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    try testing.expect(result == null);
}

test "getQueueMessages returns a single message with both fields populated" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "s1", "m1", "first", "img1", "2025-01-01 00:00:00");
    const maybe = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    var msgs = maybe orelse return error.ExpectedMessages;
    defer {
        for (msgs.items) |m| {
            testing.allocator.free(m.id);
            testing.allocator.free(m.message);
            testing.allocator.free(m.image_url);
            testing.allocator.free(m.video_url);
            testing.allocator.free(m.file_attachments);
        }
        msgs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), msgs.items.len);
    try testing.expectEqualStrings("first", msgs.items[0].message);
    try testing.expectEqualStrings("img1", msgs.items[0].image_url);
}

test "getQueueMessages returns multiple messages in created_at ASC order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "s1", "m1", "older", "", "2024-01-01 00:00:00");
    try seedMsg(&s.db, "s1", "m2", "newer", "", "2025-01-01 00:00:00");
    try seedMsg(&s.db, "s1", "m3", "middle", "", "2024-06-01 00:00:00");

    const maybe = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    var msgs = maybe orelse return error.ExpectedMessages;
    defer {
        for (msgs.items) |m| {
            testing.allocator.free(m.id);
            testing.allocator.free(m.message);
            testing.allocator.free(m.image_url);
            testing.allocator.free(m.video_url);
            testing.allocator.free(m.file_attachments);
        }
        msgs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 3), msgs.items.len);
    try testing.expectEqualStrings("older", msgs.items[0].message);
    try testing.expectEqualStrings("middle", msgs.items[1].message);
    try testing.expectEqualStrings("newer", msgs.items[2].message);
}

test "getQueueMessages returns heap-owned slices that survive after the Rows cursor is gone" {
    // The contract says "Caller must free the returned slice". Verify the
    // returned message/image bytes are independent of the underlying row
    // buffer — they must remain valid after the Rows cursor is deinitialized.
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "s1", "m1", "stable content", "stable image", "2025-01-01 00:00:00");

    const maybe = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    var msgs = maybe orelse return error.ExpectedMessages;
    defer {
        for (msgs.items) |m| {
            testing.allocator.free(m.id);
            testing.allocator.free(m.message);
            testing.allocator.free(m.image_url);
            testing.allocator.free(m.video_url);
            testing.allocator.free(m.file_attachments);
        }
        msgs.deinit(testing.allocator);
    }
    // The internal `rows` went out of scope at the end of the helper
    // call — the messages we got back must still be readable now.
    try testing.expectEqualStrings("stable content", msgs.items[0].message);
    try testing.expectEqualStrings("stable image", msgs.items[0].image_url);
}

test "getQueueMessages handles empty image_url column" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "s1", "m1", "no image", "", "2025-01-01 00:00:00");

    const maybe = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    var msgs = maybe orelse return error.ExpectedMessages;
    defer {
        for (msgs.items) |m| {
            testing.allocator.free(m.id);
            testing.allocator.free(m.message);
            testing.allocator.free(m.image_url);
            testing.allocator.free(m.video_url);
            testing.allocator.free(m.file_attachments);
        }
        msgs.deinit(testing.allocator);
    }
    try testing.expectEqualStrings("", msgs.items[0].image_url);
}

test "getQueueMessages filters by session_id (does not leak rows across sessions)" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try seedMsg(&s.db, "s1", "m1", "for s1", "", "2025-01-01 00:00:00");
    try seedMsg(&s.db, "s2", "m2", "for s2", "", "2025-01-01 00:00:00");

    const maybe = try getQueueMessages(.{ .allocator = testing.allocator, .db = &s.db, .session_id = "s1" });
    var msgs = maybe orelse return error.ExpectedMessages;
    defer {
        for (msgs.items) |m| {
            testing.allocator.free(m.id);
            testing.allocator.free(m.message);
            testing.allocator.free(m.image_url);
            testing.allocator.free(m.video_url);
            testing.allocator.free(m.file_attachments);
        }
        msgs.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), msgs.items.len);
    try testing.expectEqualStrings("for s1", msgs.items[0].message);
}
