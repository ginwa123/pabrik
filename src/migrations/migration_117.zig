const std = @import("std");
const common = @import("common.zig");
const loggermod = @import("../modules/logger/Logger.zig");

const SqliteBackend = common.SqliteBackend;

/// Migration 117 — drop the twelve `*_legacy_v116` agent-config tables.
/// The drop is GUARDED: the legacy tables survive unless the unified set
/// holds at least as many rows as the legacy copy did.
pub const Migration117DropLegacyAgentConfigTables = struct {
    pub const version: u32 = 117;
    pub const name = "drop_legacy_agent_config_tables";

    /// The legacy table -> the unified table that replaced it.
    const legacy_tables = [_][2][]const u8{
        .{ "agents_legacy_v116", "agent_configs" },
        .{ "agent_knowledge_legacy_v116", "agent_config_knowledge" },
        .{ "agent_tools_legacy_v116", "agent_config_tools" },
        .{ "agent_system_prompt_legacy_v116", "agent_config_system_prompt" },
        .{ "agent_kanbans_legacy_v116", "agent_configs" },
        .{ "agent_kanban_knowledges_legacy_v116", "agent_config_knowledge" },
        .{ "agent_kanban_tools_legacy_v116", "agent_config_tools" },
        .{ "agent_kanban_system_prompt_legacy_v116", "agent_config_system_prompt" },
        .{ "agent_routines_legacy_v116", "agent_configs" },
        .{ "agent_routine_knowledges_legacy_v116", "agent_config_knowledge" },
        .{ "agent_routine_tools_legacy_v116", "agent_config_tools" },
        .{ "agent_routine_system_prompt_legacy_v116", "agent_config_system_prompt" },
    };

    fn tableExists(db: *SqliteBackend, allocator: std.mem.Allocator, table_name: []const u8) bool {
        var q = db.query(
            allocator,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            &[_][]const u8{table_name},
        ) catch return false;
        defer q.deinit();
        const row = (q.next() catch null) orelse return false;
        row.deinit(allocator);
        return true;
    }

    /// How many rows does `table_name` hold? -1 when the table is absent.
    fn rowCount(db: *SqliteBackend, allocator: std.mem.Allocator, table_name: []const u8) i64 {
        if (!tableExists(db, allocator, table_name)) return -1;
        var buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM {s}", .{table_name}) catch return -1;
        var q = db.query(allocator, sql, &[_][]const u8{}) catch return -1;
        defer q.deinit();
        const row = (q.next() catch null) orelse return -1;
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch -1;
    }

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Guard: the unified set must hold at least as many rows as the
        // legacy copy did. Otherwise the backfill was partial and the
        // legacy tables are the only copy — keep them.
        for (legacy_tables) |pair| {
            const legacy = pair[0];
            const unified = pair[1];
            const legacy_rows = rowCount(db, allocator, legacy);
            if (legacy_rows < 0) continue;
            const unified_rows = rowCount(db, allocator, unified);
            if (unified_rows < legacy_rows) {
                if (loggermod.getGlobal()) |logger| {
                    logger.warnFmt("Migration117: keeping {s} — {s} holds {d} rows but {s} holds only {d}", .{
                        legacy, unified, legacy_rows, legacy, unified_rows,
                    });
                }
                return;
            }
        }

        for (legacy_tables) |pair| {
            const legacy = pair[0];
            if (!tableExists(db, allocator, legacy)) continue;
            var buf: [256]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "DROP TABLE IF EXISTS {s}", .{legacy}) catch
                return error.DropFailed;
            try db.exec(allocator, sql, &[_][]const u8{});
        }
    }
};

const testing = std.testing;

const TestCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb(alloc: std.mem.Allocator) !TestCtx {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn countRows(alloc: std.mem.Allocator, db: *SqliteBackend, sql: []const u8) !i64 {
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch -1;
}

test "Migration117 drops the twelve legacy tables once the unified set is complete" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    // The shape a boot leaves behind: the four unified tables plus the
    // twelve parked legacy copies.
    try db.exec(alloc,
        \\CREATE TABLE agent_configs (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, item_type TEXT NOT NULL, description TEXT NOT NULL DEFAULT '')
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_config_knowledge (id TEXT PRIMARY KEY, config_id TEXT NOT NULL, file_path TEXT NOT NULL DEFAULT '', label TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_config_tools (id TEXT PRIMARY KEY, config_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE agent_config_system_prompt (id TEXT PRIMARY KEY, config_id TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0)
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agents_legacy_v116 (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_knowledge_legacy_v116 (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_tools_legacy_v116 (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_system_prompt_legacy_v116 (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_kanbans_legacy_v116 (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_kanban_knowledges_legacy_v116 (id TEXT PRIMARY KEY, kanban_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_kanban_tools_legacy_v116 (id TEXT PRIMARY KEY, kanban_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_kanban_system_prompt_legacy_v116 (id TEXT PRIMARY KEY, kanban_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_routines_legacy_v116 (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_routine_knowledges_legacy_v116 (id TEXT PRIMARY KEY, routine_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_routine_tools_legacy_v116 (id TEXT PRIMARY KEY, routine_id TEXT NOT NULL)", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agent_routine_system_prompt_legacy_v116 (id TEXT PRIMARY KEY, routine_id TEXT NOT NULL)", &[_][]const u8{});

    // The unified set already holds the moved rows.
    try db.exec(alloc, "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('a1', 'a1', 'agent')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents_legacy_v116 (id, workspace_item_id) VALUES ('a1', 'a1')", &[_][]const u8{});

    try Migration117DropLegacyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(
        @as(i64, 0),
        try countRows(alloc, db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE '%_legacy_v116'"),
    );
    // The unified tables survive.
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_configs'"),
    );
    try testing.expectEqual(@as(i64, 1), try countRows(alloc, db, "SELECT COUNT(*) FROM agent_configs"));
}

test "Migration117 keeps the legacy tables when the unified set is short a row" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\CREATE TABLE agent_configs (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, item_type TEXT NOT NULL, description TEXT NOT NULL DEFAULT '')
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agents_legacy_v116 (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE)", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents_legacy_v116 (id, workspace_item_id) VALUES ('a1', 'a1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents_legacy_v116 (id, workspace_item_id) VALUES ('a2', 'a2')", &[_][]const u8{});

    // The unified table has ONE of the two rows — a partial backfill.
    try db.exec(alloc, "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('a1', 'a1', 'agent')", &[_][]const u8{});

    try Migration117DropLegacyAgentConfigTables.up(db, alloc);

    // The legacy copy is the only full copy — it must survive.
    try testing.expectEqual(
        @as(i64, 1),
        try countRows(alloc, db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agents_legacy_v116'"),
    );
    try testing.expectEqual(@as(i64, 2), try countRows(alloc, db, "SELECT COUNT(*) FROM agents_legacy_v116"));
}

test "Migration117 on a fresh install drops nothing and does not fail" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try Migration117DropLegacyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(
        @as(i64, 0),
        try countRows(alloc, db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE '%_legacy_v116'"),
    );
}

test "Migration117 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try setupDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc,
        \\CREATE TABLE agent_configs (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, item_type TEXT NOT NULL, description TEXT NOT NULL DEFAULT '')
    , &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE agents_legacy_v116 (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE)", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agents_legacy_v116 (id, workspace_item_id) VALUES ('a1', 'a1')", &[_][]const u8{});
    try db.exec(alloc, "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('a1', 'a1', 'agent')", &[_][]const u8{});

    try Migration117DropLegacyAgentConfigTables.up(db, alloc);
    try Migration117DropLegacyAgentConfigTables.up(db, alloc);

    try testing.expectEqual(
        @as(i64, 0),
        try countRows(alloc, db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE '%_legacy_v116'"),
    );
}

test "Migration117 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration117DropLegacyAgentConfigTables.version) return;
    }
    return error.Migration117NotRegistered;
}
