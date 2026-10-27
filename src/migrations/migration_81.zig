const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration081CreateAgentKanbans = struct {
    pub const version: u32 = 81;
    pub const name = "create_agent_kanbans_mirror";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanbans (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanbans_workspace_item_id ON agent_kanbans(workspace_item_id)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_knowledges (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    label TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_id ON agent_kanban_knowledges(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_knowledges_kanban_position ON agent_kanban_knowledges(kanban_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_id ON agent_kanban_system_prompt(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_system_prompt_kanban_position ON agent_kanban_system_prompt(kanban_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_kanban_tools (
            \\    id TEXT PRIMARY KEY,
            \\    kanban_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (kanban_id) REFERENCES agent_kanbans(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_kanban_tools_kanban_id ON agent_kanban_tools(kanban_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_kanban_tools_kanban_tool ON agent_kanban_tools(kanban_id, tool_name)",
            &[_][]const u8{});
    }
};
