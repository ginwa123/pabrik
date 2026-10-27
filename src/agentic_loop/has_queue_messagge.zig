const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const testing = std.testing;

pub fn hasQueuedMessages(
    allocator: std.mem.Allocator,
    db: *database.Db,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM session_queue_messages WHERE session_id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();

    if (rows.next() catch return false) |row| {
        defer row.deinit(allocator);
        const queued = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return queued == 1;
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
    try db.init(io, ":memory:");
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

test "hasQueuedMessages returns false when the queue is empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try testing.expect(!hasQueuedMessages(testing.allocator, &s.db, "any_session"));
}

test "hasQueuedMessages returns true after one message is queued" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES ('m1', 's1', 'hello', '')",
        &.{});
    try testing.expect(hasQueuedMessages(testing.allocator, &s.db, "s1"));
}

test "hasQueuedMessages returns false for a different session_id" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES ('m1', 's1', 'hello', '')",
        &.{});
    try testing.expect(!hasQueuedMessages(testing.allocator, &s.db, "s2"));
}

test "hasQueuedMessages returns true even when image_url is non-empty" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    try s.db.exec(testing.allocator,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES ('m1', 's1', 'with image', 'data:image/png;base64,abc')",
        &.{});
    try testing.expect(hasQueuedMessages(testing.allocator, &s.db, "s1"));
}

test "hasQueuedMessages LIMIT 1 returns true after many queued messages" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const id = std.fmt.allocPrint(testing.allocator, "m{d}", .{i}) catch @panic("allocPrint failed for the has_queue_messagge fixture id");
        try s.db.exec(testing.allocator,
            "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES (?, 's1', ?, '')",
            &.{ id, id });
        testing.allocator.free(id);
    }
    try testing.expect(hasQueuedMessages(testing.allocator, &s.db, "s1"));
}
