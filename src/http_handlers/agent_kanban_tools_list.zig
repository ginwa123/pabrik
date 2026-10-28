//! `GET /api/agent-kanbans/:kanban_id/tools`. Returns `{tools: [string]}` —
//! the enabled tool_names for the agent-kanbans config.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const ToolListError = error{
    /// `kanban_id` path param was missing or empty.
    KanbanIdRequired,
    /// `db.query` failed.
    QueryFailed,
    /// `allocator.dupe` / `toOwnedSlice` failed.
    OutOfMemory,
};

/// Inputs to the list-tools use-case.
pub const ToolListInput = struct {
    kanban_id: []const u8,
};

/// Output of the list-tools use-case. `tool_names` is owned by the
/// caller (lifetime = request arena).
pub const ToolListOutput = struct {
    tool_names: []const []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the enabled tool_names for the agent-kanbans config. Returns
/// an owned slice ordered by tool_name ASC. Transport-agnostic.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: ToolListInput,
) ToolListError!ToolListOutput {
    if (input.kanban_id.len == 0) return error.KanbanIdRequired;

    const tool_names = agent_kanban_db.listEnabledToolNames(allocator, .{ .db = db }, input.kanban_id) catch
        return error.QueryFailed;
    return .{ .tool_names = tool_names };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanToolsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{ .kanban_id = kanban_id }) catch |err| {
        const status: u16 = switch (err) {
            error.KanbanIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.KanbanIdRequired => "kanban_id required",
            error.QueryFailed => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .tools = output.tool_names }, .{});
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

    // Seed: configured kanban + 4 tools in mixed enabled states.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('ws_item_1', 'ws_item_1', 'kanban')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_1', 'ws_item_1', 'write_file', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_2', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_3', 'ws_item_1', 'read_file', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_4', 'ws_item_1', 'glob', 1)",
        &[_][]const u8{},
    );

    // A second configured kanban with no tools.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_empty', 'ws_1', 'kanban', 'Empty')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('ws_item_empty', 'ws_item_empty', 'kanban')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty kanban_id returns KanbanIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanIdRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "" }),
    );
}

test "useCase: board with no tools returns empty slice" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_empty" });
    defer alloc.free(output.tool_names);
    try testing.expectEqual(@as(usize, 0), output.tool_names.len);
}

test "useCase: returns only enabled=1 tools, ordered by tool_name ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1" });
    defer {
        for (output.tool_names) |n| alloc.free(n);
        alloc.free(output.tool_names);
    }
    // Seeded: write_file (1), bash (1), read_file (0), glob (1).
    // Expect: bash, glob, write_file (read_file excluded).
    try testing.expectEqual(@as(usize, 3), output.tool_names.len);
    try testing.expectEqualStrings("bash", output.tool_names[0]);
    try testing.expectEqualStrings("glob", output.tool_names[1]);
    try testing.expectEqualStrings("write_file", output.tool_names[2]);
}
