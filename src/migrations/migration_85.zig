const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Per-session record of tools the agent enabled for itself through
/// `use_tool`.
pub const Migration085AddSessionProgressiveTool = struct {
    pub const version: u32 = 85;
    pub const name = "add_session_progressive_tool";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_progressive_tool (
            \\    session_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    server_name TEXT NOT NULL DEFAULT '',
            \\    loaded_at_nano INTEGER NOT NULL DEFAULT 0,
            \\    PRIMARY KEY (session_id, tool_name)
            \\)
        , &[_][]const u8{});

        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_session_progressive_tool_session ON session_progressive_tool(session_id)",
            &[_][]const u8{},
        );
    }
};
