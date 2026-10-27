const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration018CreateSessionQueueMessages = struct {
    pub const version: u32 = 18;
    pub const name = "create_session_queue_messages";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_queue_messages (
            \\    id TEXT NOT NULL,
            \\    session_id TEXT NOT NULL,
            \\    message TEXT NOT NULL,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_queue_messages_session ON session_queue_messages(session_id)", &[_][]const u8{});
    }
};
