const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = struct {
    pub const version: u32 = 78;
    pub const name = "add_agents_and_agent_knowledge_and_agent_tools";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // 1. `agents` — 1-1 with `workspace_items` (UNIQUE
        // workspace_item_id).
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agents (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agents_workspace_item_id ON agents(workspace_item_id)",
            &[_][]const u8{});

        // 2. `agent_knowledge` — N-1 with `agents`. Position-ordered for
        // drag-reorder UI.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_knowledge (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL,
            \\    label TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id ON agent_knowledge(agent_id)",
            &[_][]const u8{});
        // Composite index for the position DESC ordering used by the
        // `agentKnowledgeListHandler` SELECT.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_knowledge_agent_id_position ON agent_knowledge(agent_id, position DESC)",
            &[_][]const u8{});

        // 3. `agent_tools` — N-1 with `agents`.
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_tools (
            \\    id TEXT PRIMARY KEY,
            \\    agent_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_tools_agent_id ON agent_tools(agent_id)",
            &[_][]const u8{});
        // Named UNIQUE index — checked by name in the migration test,
        // and the handler maps UNIQUE violations to HTTP 409.
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_tools_agent_tool ON agent_tools(agent_id, tool_name)",
            &[_][]const u8{});
    }
};
