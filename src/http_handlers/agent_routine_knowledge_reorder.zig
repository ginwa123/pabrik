//! `PATCH /api/agent-routines/:routine_id/knowledge/reorder`. Body:
//! `{ordered_ids: string[]}`. Reorders the routine's knowledge rows to match
//! the supplied order.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_routine_db = @import("../models/agent_routine.db.zig");

/// HTTP request body for knowledge-reorder.
const ReorderBody = struct {
    ordered_ids: []const []const u8 = &.{},
};

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeReorderError = error{
    /// `routine_id` path param was missing or empty.
    RoutineIdRequired,
    /// Body `ordered_ids` field was empty.
    OrderedIdsRequired,
    /// `begin()` / `commit()` failed.
    TransactionFailed,
    /// One of the per-row `UPDATE` statements failed.
    UpdateFailed,
};

/// Inputs to the reorder use-case.
pub const KnowledgeReorderInput = struct {
    routine_id: []const u8,
    ordered_ids: []const []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Reorder knowledge rows for the given agent-routines config. All updates
/// happen inside a single BEGIN/COMMIT — if any UPDATE fails the whole
/// reorder rolls back.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KnowledgeReorderInput,
) KnowledgeReorderError!void {
    if (input.routine_id.len == 0) return error.RoutineIdRequired;
    if (input.ordered_ids.len == 0) return error.OrderedIdsRequired;

    agent_routine_db.reorderKnowledge(allocator, db, input.routine_id, input.ordered_ids) catch |err| switch (err) {
        error.TransactionFailed => return error.TransactionFailed,
        error.UpdateFailed => return error.UpdateFailed,
        else => return error.TransactionFailed,
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentRoutineKnowledgeReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const routine_id = req.params.get("routine_id") orelse "";
    if (routine_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine_id required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(ReorderBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    useCase(allocator, sqlite_db, .{
        .routine_id = routine_id,
        .ordered_ids = parsed.ordered_ids,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.RoutineIdRequired => 400,
            error.OrderedIdsRequired => 400,
            error.TransactionFailed => 500,
            error.UpdateFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.RoutineIdRequired => "routine_id required",
            error.OrderedIdsRequired => "ordered_ids required",
            error.TransactionFailed => "Failed to begin/commit transaction",
            error.UpdateFailed => "Failed to update position",
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
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: configured routine + 3 knowledge rows (position 0, 1, 2).
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'My Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('ws_item_1', 'ws_item_1', 'routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_1', 'ws_item_1', '/tmp/a.md', '', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_2', 'ws_item_1', '/tmp/b.md', '', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_3', 'ws_item_1', '/tmp/c.md', '', 2)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn readPosition(
    db: *database.Db,
    allocator: std.mem.Allocator,
    id: []const u8,
) !i64 {
    var q = try db.query(allocator,
        "SELECT position FROM agent_config_knowledge WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return -999;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(i64, row.values[0], 10);
}

test "useCase: empty routine_id returns RoutineIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.RoutineIdRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "", .ordered_ids = &.{"kn_1"} }),
    );
}

test "useCase: empty ordered_ids returns OrderedIdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.OrderedIdsRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .ordered_ids = &.{} }),
    );
}

test "useCase: ordered_ids[0] gets highest position (len - 1)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Reverse the order: kn_3 first (position 2), kn_2 (1), kn_1 (0).
    try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .ordered_ids = &.{ "kn_3", "kn_2", "kn_1" },
    });

    try testing.expectEqual(@as(i64, 2), try readPosition(&ctx.db, alloc, "kn_3"));
    try testing.expectEqual(@as(i64, 1), try readPosition(&ctx.db, alloc, "kn_2"));
    try testing.expectEqual(@as(i64, 0), try readPosition(&ctx.db, alloc, "kn_1"));
}

test "useCase: 1-row ordering lands at position 0 (not 1)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .ordered_ids = &.{"kn_2"},
    });
    try testing.expectEqual(@as(i64, 0), try readPosition(&ctx.db, alloc, "kn_2"));
}
