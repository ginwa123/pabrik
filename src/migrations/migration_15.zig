const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration015AddSessionAgents = struct {
    pub const version: u32 = 15;
    pub const name = "add_session_agents";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS session_agents (
            \\    session_id TEXT PRIMARY KEY,
            \\    agent_name TEXT NOT NULL,
            \\    updated_at INTEGER DEFAULT (strftime('%s', 'now'))
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_session_agents_session ON session_agents(session_id)", &[_][]const u8{});
    }
};
