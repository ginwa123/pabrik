const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;

/// Migration 114 — the chat's file attachments. `file_attachments` holds the full payload for the
/// model-facing path; `file_attachments_meta` holds only the metadata, so the read path never
/// drags the bytes across.
pub const Migration114AddFileAttachments = struct {
    pub const version: u32 = 114;
    pub const name = "add_file_attachments";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "file_attachments",
            "file_attachments TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "llm_history",
            "file_attachments_meta",
            "file_attachments_meta TEXT",
        );
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "session_queue_messages",
            "file_attachments",
            "file_attachments TEXT",
        );
    }
};

const testing = std.testing;

test "Migration114 adds the attachment columns and leaves existing rows empty" {
    const alloc = testing.allocator;

    var db: Backend = .{};
    defer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY, session_id TEXT, model TEXT, response_content TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (
        \\  id TEXT PRIMARY KEY, session_id TEXT, message TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content)
        \\VALUES ('h1', 's1', 'm', 'hi')
    , &[_][]const u8{});

    try Migration114AddFileAttachments.up(&db, alloc);

    var rows = try db.query(alloc,
        \\SELECT file_attachments, file_attachments_meta FROM llm_history WHERE id = 'h1'
    , &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // The pre-existing row carries no attachment.
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
}

test "Migration114 replaying is a no-op" {
    const alloc = testing.allocator;

    var db: Backend = .{};
    defer db.deinit();
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE llm_history (id TEXT PRIMARY KEY)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE session_queue_messages (id TEXT PRIMARY KEY)
    , &[_][]const u8{});

    try Migration114AddFileAttachments.up(&db, alloc);
    try Migration114AddFileAttachments.up(&db, alloc);

    var rows = try db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('llm_history')
        \\WHERE name IN ('file_attachments', 'file_attachments_meta')
    , &[_][]const u8{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration114 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration114AddFileAttachments.version) return;
    }
    return error.Migration114NotRegistered;
}
