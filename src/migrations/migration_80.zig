const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration080AddAgentSystemPrompt = struct {
    pub const version: u32 = 80;
    pub const name = "add_agent_system_prompt";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id ON agent_system_prompt(agent_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_system_prompt_agent_id_position ON agent_system_prompt(agent_id, position DESC)",
            &[_][]const u8{});
    }
};
