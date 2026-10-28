const std = @import("std");
const common = @import("common.zig");

const Backend = common.Backend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");
const dialect = common.dialect;

pub const Migration087CreateAgentRoutines = struct {
    pub const version: u32 = 87;
    pub const name = "create_agent_routines_mirror";

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_routines (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE") ++
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
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE") ++
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
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE") ++
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
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (routine_id) REFERENCES agent_routines(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_agent_routine_tools_routine_id ON agent_routine_tools(routine_id)",
            &[_][]const u8{});
        try db.exec(allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_routine_tools_routine_tool ON agent_routine_tools(routine_id, tool_name)",
            &[_][]const u8{});

        // Backfill parent rows for routines predating this migration.
        if (try dialect.tableExists(.{ .db = db }, allocator, "workspace_items")) {
            try db.exec(allocator,
                dialect.insert_ignore_prefix ++ " INTO agent_routines (id, workspace_item_id) SELECT id, id FROM workspace_items WHERE item_type = 'routine'" ++ dialect.conflict_ignore,
                &[_][]const u8{});
        }
    }
};
