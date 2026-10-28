const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

/// Migration 116 — ONE agent-config table set for the three item families.
/// The twelve old per-item-type tables collapse into four; `item_type` on
/// the parent row tells the families apart. See the plan doc for the why.
pub const Migration116UnifyAgentConfigTables = struct {
    pub const version: u32 = 116;
    pub const name = "unify_agent_config_tables";

    /// The old table -> the legacy name it keeps after the move.
    const legacy_tables = [_][2][]const u8{
        .{ "agents", "agents_legacy_v116" },
        .{ "agent_knowledge", "agent_knowledge_legacy_v116" },
        .{ "agent_tools", "agent_tools_legacy_v116" },
        .{ "agent_system_prompt", "agent_system_prompt_legacy_v116" },
        .{ "agent_kanbans", "agent_kanbans_legacy_v116" },
        .{ "agent_kanban_knowledges", "agent_kanban_knowledges_legacy_v116" },
        .{ "agent_kanban_tools", "agent_kanban_tools_legacy_v116" },
        .{ "agent_kanban_system_prompt", "agent_kanban_system_prompt_legacy_v116" },
        .{ "agent_routines", "agent_routines_legacy_v116" },
        .{ "agent_routine_knowledges", "agent_routine_knowledges_legacy_v116" },
        .{ "agent_routine_tools", "agent_routine_tools_legacy_v116" },
        .{ "agent_routine_system_prompt", "agent_routine_system_prompt_legacy_v116" },
    };

    /// Does a table with this name exist in the schema?
    fn tableExists(db: *Backend, allocator: std.mem.Allocator, table_name: []const u8) bool {
        return dialect.tableExists(.{ .db = db }, allocator, table_name) catch false;
    }

    /// Run `copy_sql` only when `source_table` exists — a fresh install has
    /// none of the old tables. The dialect supplies the verb and the end:
    /// `INSERT OR IGNORE`, or `INSERT ... ON CONFLICT DO NOTHING`.
    fn copyFrom(db: *Backend, allocator: std.mem.Allocator, source_table: []const u8, copy_sql: []const u8) !void {
        if (!tableExists(db, allocator, source_table)) return;
        const sql = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dialect.insert_ignore_prefix, copy_sql, dialect.conflict_ignore });
        defer allocator.free(sql);
        try db.exec(allocator, sql, &[_][]const u8{});
    }

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        // ─── The four unified tables ───────────────────────────────────
        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_configs (
            \\    id TEXT PRIMARY KEY,
            \\    workspace_item_id TEXT NOT NULL UNIQUE,
            \\    item_type TEXT NOT NULL,
            \\    description TEXT NOT NULL DEFAULT '',
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_configs_workspace_item_id ON agent_configs(workspace_item_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_configs_item_type ON agent_configs(item_type)", &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_config_knowledge (
            \\    id TEXT PRIMARY KEY,
            \\    config_id TEXT NOT NULL,
            \\    file_path TEXT NOT NULL DEFAULT '',
            \\    label TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_config_knowledge_config_id ON agent_config_knowledge(config_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_config_knowledge_config_position ON agent_config_knowledge(config_id, position DESC)", &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_config_tools (
            \\    id TEXT PRIMARY KEY,
            \\    config_id TEXT NOT NULL,
            \\    tool_name TEXT NOT NULL,
            \\    enabled INTEGER NOT NULL DEFAULT 1,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_config_tools_config_id ON agent_config_tools(config_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_config_tools_config_tool ON agent_config_tools(config_id, tool_name)", &[_][]const u8{});

        try db.exec(allocator,
            \\CREATE TABLE IF NOT EXISTS agent_config_system_prompt (
            \\    id TEXT PRIMARY KEY,
            \\    config_id TEXT NOT NULL,
            \\    title TEXT NOT NULL DEFAULT '',
            \\    content TEXT NOT NULL DEFAULT '',
            \\    position INTEGER NOT NULL DEFAULT 0,
            \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            ++ comptime dialect.foreignKey("FOREIGN KEY (config_id) REFERENCES agent_configs(id) ON DELETE CASCADE") ++
            \\)
        , &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_config_system_prompt_config_id ON agent_config_system_prompt(config_id)", &[_][]const u8{});
        try db.exec(allocator, "CREATE INDEX IF NOT EXISTS idx_agent_config_system_prompt_config_position ON agent_config_system_prompt(config_id, position DESC)", &[_][]const u8{});

        // ─── Backfill: the three parents ──────────────────────────────
        // `id` and `workspace_item_id` are copied verbatim (spec D3: they
        // are the same string); the UNIQUE on `workspace_item_id` stays.
        try copyFrom(db, allocator, "agents",
            \\ INTO agent_configs (id, workspace_item_id, item_type, description, created_at, updated_at)
            \\SELECT id, workspace_item_id, 'agent', description, created_at, updated_at FROM agents
        );
        try copyFrom(db, allocator, "agent_kanbans",
            \\ INTO agent_configs (id, workspace_item_id, item_type, description, created_at, updated_at)
            \\SELECT id, workspace_item_id, 'kanban', description, created_at, updated_at FROM agent_kanbans
        );
        try copyFrom(db, allocator, "agent_routines",
            \\ INTO agent_configs (id, workspace_item_id, item_type, description, created_at, updated_at)
            \\SELECT id, workspace_item_id, 'routine', description, created_at, updated_at FROM agent_routines
        );

        // ─── Backfill: the children ──────────────────────────────────
        // The old owner column (`agent_id` / `kanban_id` / `routine_id`)
        // becomes `config_id`.
        try copyFrom(db, allocator, "agent_knowledge",
            \\ INTO agent_config_knowledge (id, config_id, file_path, label, content, position, created_at, updated_at)
            \\SELECT id, agent_id, file_path, label, content, position, created_at, updated_at FROM agent_knowledge
        );
        try copyFrom(db, allocator, "agent_kanban_knowledges",
            \\ INTO agent_config_knowledge (id, config_id, file_path, label, content, position, created_at, updated_at)
            \\SELECT id, kanban_id, file_path, label, content, position, created_at, updated_at FROM agent_kanban_knowledges
        );
        try copyFrom(db, allocator, "agent_routine_knowledges",
            \\ INTO agent_config_knowledge (id, config_id, file_path, label, content, position, created_at, updated_at)
            \\SELECT id, routine_id, file_path, label, content, position, created_at, updated_at FROM agent_routine_knowledges
        );

        try copyFrom(db, allocator, "agent_tools",
            \\ INTO agent_config_tools (id, config_id, tool_name, enabled, created_at)
            \\SELECT id, agent_id, tool_name, enabled, created_at FROM agent_tools
        );
        try copyFrom(db, allocator, "agent_kanban_tools",
            \\ INTO agent_config_tools (id, config_id, tool_name, enabled, created_at)
            \\SELECT id, kanban_id, tool_name, enabled, created_at FROM agent_kanban_tools
        );
        try copyFrom(db, allocator, "agent_routine_tools",
            \\ INTO agent_config_tools (id, config_id, tool_name, enabled, created_at)
            \\SELECT id, routine_id, tool_name, enabled, created_at FROM agent_routine_tools
        );

        try copyFrom(db, allocator, "agent_system_prompt",
            \\ INTO agent_config_system_prompt (id, config_id, title, content, position, created_at, updated_at)
            \\SELECT id, agent_id, title, content, position, created_at, updated_at FROM agent_system_prompt
        );
        try copyFrom(db, allocator, "agent_kanban_system_prompt",
            \\ INTO agent_config_system_prompt (id, config_id, title, content, position, created_at, updated_at)
            \\SELECT id, kanban_id, title, content, position, created_at, updated_at FROM agent_kanban_system_prompt
        );
        try copyFrom(db, allocator, "agent_routine_system_prompt",
            \\ INTO agent_config_system_prompt (id, config_id, title, content, position, created_at, updated_at)
            \\SELECT id, routine_id, title, content, position, created_at, updated_at FROM agent_routine_system_prompt
        );

        // ─── Park the old tables under a `_legacy_v116` name ──────────
        // Not dropped: a rollback is a rename back, and the data stays
        // there while the new set proves itself.
        for (legacy_tables) |pair| {
            const source = pair[0];
            const legacy = pair[1];
            if (!tableExists(db, allocator, source)) continue;
            if (tableExists(db, allocator, legacy)) continue;

            var buf: [256]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "ALTER TABLE {s} RENAME TO {s}", .{ source, legacy }) catch
                return error.RenameFailed;
            try db.exec(allocator, sql, &[_][]const u8{});
        }
    }
};

const testing = std.testing;

const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn countRows(alloc: std.mem.Allocator, db: *Backend, sql: []const u8) !i64 {
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch -1;
}

test "Migration116 creates the four unified tables with the expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration116UnifyAgentConfigTables.up(db, alloc);

    var q = try db.query(alloc, "SELECT name FROM " ++ comptime dialect.tableColumns("agent_configs"), &[_][]const u8{});
    defer q.deinit();
    var cols: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        cols += 1;
    }
    try testing.expectEqual(@as(usize, 6), cols);

    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_config_knowledge'"),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_config_tools'"),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_config_system_prompt'"),
    );
}

test "Migration116 backfills all three families into one table set" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // The old shape, as an install from before this migration looks.
    try db.exec(alloc,
        \\CREATE TABLE agents (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_kanbans (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_kanban_knowledges (id TEXT PRIMARY KEY, kanban_id TEXT NOT NULL, file_path TEXT NOT NULL DEFAULT '', label TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_routines (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_routine_system_prompt (id TEXT PRIMARY KEY, routine_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});

    try db.exec(alloc, "INSERT INTO agents (id, workspace_item_id, description) VALUES ('a1', 'a1', 'agent desc')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('t1', 'a1', 'bash', 1)", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_kanbans (id, workspace_item_id, description) VALUES ('k1', 'k1', 'board desc')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_kanban_knowledges (id, kanban_id, file_path, label, content, position) VALUES ('kn1', 'k1', '/tmp/x.md', 'L', 'body', 0)", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_routines (id, workspace_item_id, description) VALUES ('r1', 'r1', 'routine desc')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_routine_system_prompt (id, routine_id, title, content, position) VALUES ('sp1', 'r1', 'T', 'body', 0)", &[_][]const u8{});

    try Migration116UnifyAgentConfigTables.up(db, alloc);

    // One table, three families, told apart by item_type.
    try testing.expectEqual(@as(i64, 3), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs WHERE item_type='agent'"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs WHERE item_type='kanban'"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs WHERE item_type='routine'"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_config_tools"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_config_knowledge"));
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_config_system_prompt"));

    // The description survives the move.
    var q = try db.query(alloc, "SELECT description FROM agent_configs WHERE id='k1'", &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("board desc", row.values[0]);
}

test "Migration116 parks the old tables under a _legacy_v116 name instead of dropping them" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\CREATE TABLE agents (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents (id, workspace_item_id) VALUES ('a1', 'a1')", &[_][]const u8{});

    try Migration116UnifyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(
        @as(i64, 0),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agents'"),
    );
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agents_legacy_v116'"),
    );
    // The legacy table still holds the rows.
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM agents_legacy_v116"),
    );
}

test "Migration116 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\CREATE TABLE agents (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT NOT NULL DEFAULT '', created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents (id, workspace_item_id) VALUES ('a1', 'a1')", &[_][]const u8{});

    try Migration116UnifyAgentConfigTables.up(db, alloc);
    try Migration116UnifyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs"));
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agents_legacy_v116'"),
    );
}

test "Migration116 on a fresh install creates the tables and copies nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration116UnifyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(@as(i64, 0), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs"));
    try testing.expectEqual(
        @as(i64, 0),
        try countRows(alloc, db, "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name LIKE '%_legacy_v116'"),
    );
}

test "Migration116 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration116UnifyAgentConfigTables.version) return;
    }
    return error.Migration116NotRegistered;
}
