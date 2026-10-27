//! `DELETE /api/agent-routines/:routine_id/knowledge/:knowledge_id`. Removes
//! a knowledge entry. Returns `{ok: true}` on success.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_routine_db = @import("../models/agent_routine.db.zig");

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeDeleteError = error{
    /// `routine_id` or `knowledge_id` path param was missing or empty.
    IdsRequired,
    /// `db.exec` failed on the DELETE.
    DeleteFailed,
};

/// Inputs to the delete-knowledge use-case.
pub const KnowledgeDeleteInput = struct {
    routine_id: []const u8,
    knowledge_id: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a knowledge row for the given agent-routines config. The
/// use-case is transport-agnostic: it works for both the per-request
/// arena (production HTTP handler) and `testing.allocator` (unit tests).
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KnowledgeDeleteInput,
) KnowledgeDeleteError!void {
    if (input.routine_id.len == 0 or input.knowledge_id.len == 0) {
        return error.IdsRequired;
    }

    agent_routine_db.deleteKnowledge(allocator, .{ .db = db }, input.knowledge_id, input.routine_id) catch
        return error.DeleteFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentRoutineKnowledgeDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const routine_id = req.params.get("routine_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";

    useCase(allocator, sqlite_db, .{
        .routine_id = routine_id,
        .knowledge_id = knowledge_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "routine_id and knowledge_id required",
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
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: configured routine + 1 knowledge row.
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

    return .{ .db = db, .threaded = threaded };
}

fn countKnowledge(
    db: *database.Db,
    allocator: std.mem.Allocator,
    routine_id: []const u8,
) !u32 {
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM agent_config_knowledge WHERE config_id = ?",
        &[_][]const u8{routine_id},
    );
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty routine_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "", .knowledge_id = "kn_1" }),
    );
}

test "useCase: empty knowledge_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .knowledge_id = "" }),
    );
}

test "useCase: matches scoped by both id AND routine_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countKnowledge(&ctx.db, alloc, "ws_item_1"));

    try useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .knowledge_id = "kn_1" });

    try testing.expectEqual(@as(u32, 0), try countKnowledge(&ctx.db, alloc, "ws_item_1"));
}

test "useCase: non-matching knowledge_id is a no-op (no error)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countKnowledge(&ctx.db, alloc, "ws_item_1"));

    // Non-existent id — DELETE affects 0 rows, exec returns success.
    try useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .knowledge_id = "kn_404" });

    try testing.expectEqual(@as(u32, 1), try countKnowledge(&ctx.db, alloc, "ws_item_1"));
}
