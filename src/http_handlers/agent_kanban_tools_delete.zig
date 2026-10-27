//! `DELETE /api/agent-kanbans/:kanban_id/tools/:tool_name`. Removes a tool
//! from the board's allowlist. Returns `{ok: true}` on success.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const ToolDeleteError = error{
    /// `kanban_id` or `tool_name` path param was missing or empty.
    IdsRequired,
    /// `db.exec` failed on the DELETE.
    DeleteFailed,
};

/// Inputs to the delete-tool use-case.
pub const ToolDeleteInput = struct {
    kanban_id: []const u8,
    tool_name: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a tool row for the given agent-kanbans config. The use-case
/// is transport-agnostic: it works for both the per-request arena
/// (production HTTP handler) and `testing.allocator` (unit tests).
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: ToolDeleteInput,
) ToolDeleteError!void {
    if (input.kanban_id.len == 0 or input.tool_name.len == 0) {
        return error.IdsRequired;
    }

    agent_kanban_db.deleteTool(allocator, .{ .db = db }, input.kanban_id, input.tool_name) catch
        return error.DeleteFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanToolsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";
    const tool_name = req.params.get("tool_name") orelse "";

    useCase(allocator, sqlite_db, .{
        .kanban_id = kanban_id,
        .tool_name = tool_name,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "kanban_id and tool_name required",
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
// impl + tests in one file (project convention). Behavioural coverage: 1.

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
    try test_db.openMemory(&db, io);

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: configured kanban + 1 enabled tool.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('ws_item_1', 'ws_item_1', 'kanban')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_1', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn countTools(
    db: *database.Db,
    allocator: std.mem.Allocator,
    kanban_id: []const u8,
) !u32 {
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM agent_config_tools WHERE config_id = ?",
        &[_][]const u8{kanban_id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty kanban_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .tool_name = "bash" }),
    );
}

test "useCase: empty tool_name returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .tool_name = "" }),
    );
}

test "useCase: matches scoped by both tool_name AND kanban_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countTools(&ctx.db, alloc, "ws_item_1"));

    try useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .tool_name = "bash" });

    try testing.expectEqual(@as(u32, 0), try countTools(&ctx.db, alloc, "ws_item_1"));
}

test "useCase: non-matching tool_name is a no-op (no error)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countTools(&ctx.db, alloc, "ws_item_1"));

    // Non-existent tool — DELETE affects 0 rows, exec returns success.
    try useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .tool_name = "nonexistent_tool" });

    try testing.expectEqual(@as(u32, 1), try countTools(&ctx.db, alloc, "ws_item_1"));
}
