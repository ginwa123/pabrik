const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration073AddSessionActivity = struct {
    pub const version: u32 = 73;
    pub const name = "add_session_activity";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_activity (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    description TEXT NOT NULL,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            \\)
        , &[_][]const u8{});

        // 2.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_activity_session_created " ++
                "ON session_activity(session_id, created_at DESC)",
            &[_][]const u8{},
        );
    }
};
