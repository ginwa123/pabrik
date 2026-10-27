//! Returns the enabled tool names for the agent-kanbans config bound to a
//! kanban workspace_item.

const std = @import("std");
const sqlite = @import("pabrikcore").sqlite;
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// Resolve the enabled tool names for the agent-kanbans config bound to
/// `workspace_item_id`.
pub fn agentKanbanToolsAllowed(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_item_id: []const u8,
) ![]const []const u8 {
    // 1. Require an agent_kanbans row (spec D3: id == workspace_item_id).
    if (!agent_kanban_db.exists(allocator, .{ .db = db }, workspace_item_id)) return &.{};

    // 2. Fetch the enabled tool names ordered by tool_name ASC.
    return agent_kanban_db.listEnabledToolNames(allocator, .{ .db = db }, workspace_item_id) catch &.{};
}

// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;
// Use a fresh alias for the test section to avoid duplicate-struct-
// member shadowing (file-level `const sqlite` already exists).
const test_sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{});
    try Migration116.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

fn insertWorkspaceItem(ctx: *TestCtx, id: []const u8, item_type: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES (?, 'ws_1', ?, 'Test', '/tmp', 0)",
        &[_][]const u8{ id, item_type },
    );
}

fn insertConfig(ctx: *TestCtx, config_id: []const u8, workspace_item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, 'kanban')",
        &[_][]const u8{ config_id, workspace_item_id },
    );
}

fn insertTool(ctx: *TestCtx, tool_id: []const u8, kanban_id: []const u8, tool_name: []const u8, enabled: u8) !void {
    const alloc = testing.allocator;
    var sql_buf: [512]u8 = undefined;
    const enabled_str: []const u8 = if (enabled == 1) "1" else "0";
    const sql = try std.fmt.bufPrint(
        &sql_buf,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('{s}', '{s}', '{s}', {s})",
        .{ tool_id, kanban_id, tool_name, enabled_str },
    );
    try ctx.db.exec(alloc, sql, &[_][]const u8{});
}

test "agentKanbanToolsAllowed: returns empty slice when no agent_kanbans row exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_bare", "kanban");

    const result = try agentKanbanToolsAllowed(alloc, &ctx.db, "ws_item_bare");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentKanbanToolsAllowed: returns empty slice when workspace_item doesn't exist at all" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try agentKanbanToolsAllowed(alloc, &ctx.db, "non_existent_item");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentKanbanToolsAllowed: returns empty slice when configured but zero tools rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");

    const result = try agentKanbanToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "agentKanbanToolsAllowed: returns enabled tool_name list sorted ASC when configured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertTool(&ctx, "kt_bash", "ws_item_1", "bash", 1);
    try insertTool(&ctx, "kt_read", "ws_item_1", "read_file", 1);
    try insertTool(&ctx, "kt_write", "ws_item_1", "write_file", 1);

    const result = try agentKanbanToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer {
        for (result) |n| alloc.free(n);
        alloc.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("bash", result[0]);
    try testing.expectEqualStrings("read_file", result[1]);
    try testing.expectEqualStrings("write_file", result[2]);
}

test "agentKanbanToolsAllowed: skips rows where enabled = 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertWorkspaceItem(&ctx, "ws_item_1", "kanban");
    try insertConfig(&ctx, "ws_item_1", "ws_item_1");
    try insertTool(&ctx, "kt_bash", "ws_item_1", "bash", 1);
    try insertTool(&ctx, "kt_read", "ws_item_1", "read_file", 0);

    const result = try agentKanbanToolsAllowed(alloc, &ctx.db, "ws_item_1");
    defer {
        for (result) |n| alloc.free(n);
        alloc.free(result);
    }
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("bash", result[0]);
}
