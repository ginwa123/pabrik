const std = @import("std");
const test_db = @import("../testing/test_db.zig");
const common = @import("common.zig");

const Backend = common.Backend;
const dialect = common.dialect;

pub const Migration129DeleteDanglingWorkspaceSubtree = struct {
    pub const version: u32 = 129;
    pub const name = "delete_dangling_workspace_subtree";

    const live_items = "SELECT id FROM workspace_items WHERE workspace_id IS NOT NULL AND workspace_id IN (SELECT id FROM workspaces)";
    const live_tasks = "SELECT id FROM workspace_item_tasks WHERE workspace_item_id IN (" ++ live_items ++ ")";
    const live_configs = "SELECT id FROM agent_configs WHERE workspace_item_id IN (" ++ live_items ++ ")";
    const live_pages = "SELECT id FROM design_pages WHERE workspace_item_id IN (" ++ live_items ++ ")";

    const statements = [_][]const u8{
        "DELETE FROM agent_config_tools WHERE config_id IS NULL OR config_id NOT IN (" ++ live_configs ++ ")",
        "DELETE FROM agent_config_knowledge WHERE config_id IS NULL OR config_id NOT IN (" ++ live_configs ++ ")",
        "DELETE FROM agent_config_system_prompt WHERE config_id IS NULL OR config_id NOT IN (" ++ live_configs ++ ")",
        "DELETE FROM design_page_elements WHERE page_id IS NULL OR page_id NOT IN (" ++ live_pages ++ ")",
        "DELETE FROM kanban WHERE workspace_item_task_id IS NULL OR workspace_item_task_id NOT IN (" ++ live_tasks ++ ")",
        "DELETE FROM agent_configs WHERE workspace_item_id NOT IN (" ++ live_items ++ ")",
        "DELETE FROM workspace_routines WHERE workspace_item_id NOT IN (" ++ live_items ++ ")",
        "DELETE FROM design_pages WHERE workspace_item_id NOT IN (" ++ live_items ++ ")",
        "DELETE FROM kanban_columns WHERE workspace_item_id NOT IN (" ++ live_items ++ ")",
        "DELETE FROM workspace_item_tasks WHERE workspace_item_id NOT IN (" ++ live_items ++ ")",
        "DELETE FROM workspace_items WHERE workspace_id IS NULL OR workspace_id NOT IN (SELECT id FROM workspaces)",
        "DELETE FROM workspace_settings WHERE workspace_id IS NULL OR workspace_id NOT IN (SELECT id FROM workspaces)",
        "DELETE FROM workspace_members WHERE workspace_id IS NULL OR workspace_id NOT IN (SELECT id FROM workspaces)",
    };

    pub fn up(db: *Backend, allocator: std.mem.Allocator) anyerror!void {
        var tx = try db.begin();
        defer tx.commitOrRollback() catch {};
        errdefer tx.rollback() catch {};

        for (statements) |sql| {
            try tx.exec(allocator, sql, &[_][]const u8{});
        }

        try tx.commit();
    }
};

const testing = std.testing;

const schema = [_][]const u8{
    "CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '')",
    "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL DEFAULT 'agent', name TEXT)",
    "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', workspace_item_id TEXT NOT NULL)",
    "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', position INTEGER NOT NULL DEFAULT 0)",
    "CREATE TABLE kanban (workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL, kanban_position INTEGER NOT NULL DEFAULT 0)",
    "CREATE TABLE design_pages (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '')",
    "CREATE TABLE design_page_elements (id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '')",
    "CREATE TABLE agent_configs (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT 'agent')",
    "CREATE TABLE agent_config_tools (id TEXT PRIMARY KEY, config_id TEXT NOT NULL, tool_name TEXT NOT NULL)",
    "CREATE TABLE agent_config_knowledge (id TEXT PRIMARY KEY, config_id TEXT NOT NULL)",
    "CREATE TABLE agent_config_system_prompt (id TEXT PRIMARY KEY, config_id TEXT NOT NULL)",
    "CREATE TABLE workspace_routines (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL)",
    "CREATE TABLE workspace_settings (owner TEXT NOT NULL DEFAULT '', workspace_id TEXT NOT NULL, config_json TEXT)",
    "CREATE TABLE workspace_members (workspace_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'viewer')",
};

fn openDb(alloc: std.mem.Allocator) !struct { db: Backend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    for (schema) |ddl| try db.exec(alloc, ddl, &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn seed(alloc: std.mem.Allocator, db: *Backend, workspace: []const u8, prefix: []const u8) !void {
    var bufs: [9][64]u8 = @splat([_]u8{0} ** 64);
    const item = try std.fmt.bufPrint(&bufs[0], "{s}_item", .{prefix});
    const task = try std.fmt.bufPrint(&bufs[1], "{s}_task", .{prefix});
    const column = try std.fmt.bufPrint(&bufs[2], "{s}_col", .{prefix});
    const page = try std.fmt.bufPrint(&bufs[3], "{s}_page", .{prefix});
    const element = try std.fmt.bufPrint(&bufs[4], "{s}_el", .{prefix});
    const config = try std.fmt.bufPrint(&bufs[5], "{s}_cfg", .{prefix});
    const knowledge = try std.fmt.bufPrint(&bufs[6], "{s}_k", .{prefix});
    const prompt = try std.fmt.bufPrint(&bufs[7], "{s}_p", .{prefix});
    const routine = try std.fmt.bufPrint(&bufs[8], "{s}_r", .{prefix});

    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, name) VALUES (?, ?, ?)", &.{ item, workspace, prefix });
    try db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES (?, ?)", &.{ task, item });
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id) VALUES (?, ?)", &.{ column, item });
    try db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id) VALUES (?, ?)", &.{ task, column });
    try db.exec(alloc, "INSERT INTO design_pages (id, workspace_item_id) VALUES (?, ?)", &.{ page, item });
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id) VALUES (?, ?)", &.{ element, page });
    try db.exec(alloc, "INSERT INTO agent_configs (id, workspace_item_id) VALUES (?, ?)", &.{ config, item });
    try db.exec(alloc, "INSERT INTO agent_config_tools (id, config_id, tool_name) VALUES (?, ?, 'read_file')", &.{ knowledge, config });
    try db.exec(alloc, "INSERT INTO agent_config_knowledge (id, config_id) VALUES (?, ?)", &.{ knowledge, config });
    try db.exec(alloc, "INSERT INTO agent_config_system_prompt (id, config_id) VALUES (?, ?)", &.{ prompt, config });
    try db.exec(alloc, "INSERT INTO workspace_routines (id, workspace_item_id) VALUES (?, ?)", &.{ routine, item });
    try db.exec(alloc, "INSERT INTO workspace_settings (owner, workspace_id) VALUES ('user_1', ?)", &.{workspace});
    try db.exec(alloc, "INSERT INTO workspace_members (workspace_id, user_id) VALUES (?, 'user_1')", &.{workspace});
}

fn count(alloc: std.mem.Allocator, db: *Backend, sql: []const u8) !u64 {
    var row = try db.queryRow(alloc, sql, &[_][]const u8{});
    defer row.deinit(alloc);
    return std.fmt.parseInt(u64, row.values[0], 10) catch 0;
}

test "Migration129 removes the subtree whose workspace is gone" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_alive', 'alive')", &[_][]const u8{});
    try seed(alloc, db, "ws_alive", "alive");
    try seed(alloc, db, "ws_gone", "gone");
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id) VALUES ('stray_el', 'page_that_never_existed')", &[_][]const u8{});

    try Migration129DeleteDanglingWorkspaceSubtree.up(db, alloc);

    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM design_page_elements WHERE id = 'stray_el'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_items WHERE workspace_id = 'ws_gone'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_item_tasks WHERE id = 'gone_task'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM kanban_columns WHERE id = 'gone_col'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM kanban WHERE workspace_item_task_id = 'gone_task'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM design_pages WHERE id = 'gone_page'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM design_page_elements WHERE id = 'gone_el'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM agent_configs WHERE id = 'gone_cfg'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM agent_config_knowledge WHERE id = 'gone_k'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM agent_config_system_prompt WHERE id = 'gone_p'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_routines WHERE id = 'gone_r'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_settings WHERE workspace_id = 'ws_gone'"));
    try testing.expectEqual(@as(u64, 0), try count(alloc, db, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_gone'"));
}

test "Migration129 keeps every row that still reaches a workspace" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_alive', 'alive')", &[_][]const u8{});
    try seed(alloc, db, "ws_alive", "alive");
    try seed(alloc, db, "ws_gone", "gone");

    try Migration129DeleteDanglingWorkspaceSubtree.up(db, alloc);

    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_items"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_item_tasks"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM kanban"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM design_page_elements"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM agent_configs"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_settings"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_members"));
    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_items WHERE id = 'alive_item'"));
}

test "Migration129 replaying is a no-op" {
    const alloc = testing.allocator;
    var ctx = try openDb(alloc);
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    const db = &ctx.db;

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_alive', 'alive')", &[_][]const u8{});
    try seed(alloc, db, "ws_alive", "alive");
    try seed(alloc, db, "ws_gone", "gone");

    try Migration129DeleteDanglingWorkspaceSubtree.up(db, alloc);
    try Migration129DeleteDanglingWorkspaceSubtree.up(db, alloc);

    try testing.expectEqual(@as(u64, 1), try count(alloc, db, "SELECT COUNT(*) FROM workspace_items"));
}

test "Migration129 is registered in allMigrations" {
    for (@import("migration.zig").allMigrations) |m| {
        if (m.version == Migration129DeleteDanglingWorkspaceSubtree.version) return;
    }
    return error.Migration129NotRegistered;
}
