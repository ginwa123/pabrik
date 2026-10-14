const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

pub const Migration087CreateAgentRoutines = struct {
    pub const version: u32 = 87;
    pub const name = "create_agent_routines_mirror";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routines (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routines_workspace_item_id ON agent_routines(workspace_item_id)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_knowledges (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    label TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_knowledges_routine_id ON agent_routine_knowledges(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_knowledges_routine_position ON agent_routine_knowledges(routine_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_system_prompt_routine_id ON agent_routine_system_prompt(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_system_prompt_routine_position ON agent_routine_system_prompt(routine_id, position DESC)",
            &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routine_tools (
            \\    id TEXT PRIMARY KEY,
            \\    routine_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_tools_routine_id ON agent_routine_tools(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_routine_tools_routine_tool ON agent_routine_tools(routine_id, tool_name)",
            &[_][]const u8{});

        // Backfill parent rows for routines predating this migration.
        {
            var q = try db.query(allocator,
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'workspace_items'",
                &[_][]const u8{});
            defer q.deinit();
            const has_items_table = try q.next();
            if (has_items_table) |r| r.deinit(allocator);
            if (has_items_table != null) {
                try db.exec(allocator,
                    "INSERT OR IGNORE INTO agent_routines (id, workspace_item_id) SELECT id, id FROM workspace_items WHERE item_type = 'routine'",
                    &[_][]const u8{});
            }
        }
    }
};
