//! `DELETE /api/agents/:agent_id/tools/:tool_name`. Removes a tool from the
//! agent's allowlist. Returns `{ok: true}` on success, 404 if not found.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// Domain-level error set for `useCase`.
pub const ToolDeleteError = error{
    /// `agent_id` or `tool_name` path param was missing or empty.
    IdsRequired,
    /// `db.exec` failed on the DELETE.
    DeleteFailed,
};

/// Inputs to the delete-tool use-case.
pub const ToolDeleteInput = struct {
    agent_id: []const u8,
    tool_name: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a tool row for the given agent.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: ToolDeleteInput,
) ToolDeleteError!void {
    if (input.agent_id.len == 0 or input.tool_name.len == 0) {
        return error.IdsRequired;
    }

    agent_db.deleteTool(allocator, .{ .db = db }, input.agent_id, input.tool_name) catch
        return error.DeleteFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const tool_name = req.params.get("tool_name") orelse "";

    useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .tool_name = tool_name,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and tool_name required",
            error.DeleteFailed => "Failed to delete",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .ok = true }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 4 behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape instead of relying on
    // Migration 001.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );

    try Migration116.up(&db, testing.allocator);

    // Seed: 2 agents (so the scoped test can verify cross-agent
    // isolation) + 1 tool on each.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'Agent 1')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_2', 'ws_1', 'agent', 'Agent 2')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_2', 'ws_item_2', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('at_1', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('at_2', 'ws_item_2', 'read_file', 1)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn countToolsForAgent(
    db: *database.Db,
    allocator: std.mem.Allocator,
    agent_id: []const u8,
) !u32 {
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM agent_config_tools WHERE config_id = ?",
        &[_][]const u8{agent_id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty agent_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "", .tool_name = "bash" }),
    );
}

test "useCase: empty tool_name returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "" }),
    );
}

test "useCase: matches scoped by both tool_name AND agent_id (no cross-agent delete)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: each agent has 1 tool. Seed: agent 1 -> 'bash',
    // agent 2 -> 'read_file'.
    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_1"));
    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_2"));

    // Try to delete agent 2's 'read_file' but lie and say agent_id is
    // ws_item_1. Should be a no-op because the WHERE clause requires
    // both tool_name AND agent_id to match.
    useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "read_file" }) catch {};
    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_1"));
    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_2"));

    // Now the legit delete: remove agent 1's 'bash'.
    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "bash" });
    try testing.expectEqual(@as(u32, 0), try countToolsForAgent(&ctx.db, alloc, "ws_item_1"));
    // Other agent's 'read_file' untouched.
    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_2"));
}

test "useCase: non-matching tool_name is a no-op (no error)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_1"));

    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "totally_nonexistent" });

    try testing.expectEqual(@as(u32, 1), try countToolsForAgent(&ctx.db, alloc, "ws_item_1"));
}