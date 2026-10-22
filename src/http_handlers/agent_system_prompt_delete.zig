//! `DELETE /api/agents/:agent_id/system_prompt/:prompt_id`. Removes a
//! system-prompt entry. Returns `{ok: true}` on success.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// Domain-level error set for `useCase`.
pub const SystemPromptDeleteError = error{
    /// `agent_id` or `prompt_id` path param was missing or empty.
    IdsRequired,
    /// `db.exec` failed on the DELETE.
    DeleteFailed,
};

/// Inputs to the delete-system-prompt use-case.
pub const SystemPromptDeleteInput = struct {
    agent_id: []const u8,
    prompt_id: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a system-prompt row for the given agent.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SystemPromptDeleteInput,
) SystemPromptDeleteError!void {
    if (input.agent_id.len == 0 or input.prompt_id.len == 0) {
        return error.IdsRequired;
    }

    agent_db.deleteSystemPrompt(allocator, .{ .db = db }, input.prompt_id, input.agent_id) catch
        return error.DeleteFailed;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentSystemPromptDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";
    const prompt_id = req.params.get("prompt_id") orelse "";

    useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .prompt_id = prompt_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.DeleteFailed => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "agent_id and prompt_id required",
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
// impl + tests in one file (project convention for Agent Mode). Behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Migration 076 (Agent Mode) only creates the `agents`,
    // `agent_knowledge`, `agent_tools` tables.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );

    try Migration116.up(&db, testing.allocator);
    // Production DBs run every migration in order — the harness must
    // mirror that, or the agent_system_prompt table (Migration 080) is
    // missing.

    // Seed: 1 workspace_item of type 'agent' + matching agents row +
    // 1 system-prompt row, so the happy-path test has something to delete.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES ('asp_1', 'ws_item_1', 'Persona', 'You are X', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn countPrompts(
    db: *sqlite.SqliteBackend,
    allocator: std.mem.Allocator,
    agent_id: []const u8,
) !u32 {
    var q = try db.query(allocator,
        "SELECT COUNT(*) FROM agent_config_system_prompt WHERE config_id = ?",
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
        useCase(alloc, &ctx.db, .{ .agent_id = "", .prompt_id = "asp_1" }),
    );
}

test "useCase: empty prompt_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "" }),
    );
}

test "useCase: matches scoped by both id AND agent_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: 1 row before
    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));

    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "asp_1" });

    // After: 0 rows
    try testing.expectEqual(@as(u32, 0), try countPrompts(&ctx.db, alloc, "ws_item_1"));
}

test "useCase: non-matching prompt_id is a no-op (no error)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));

    // prompt_id that doesn't exist — DELETE just affects 0 rows,
    // and `exec` returns success. No error.
    try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .prompt_id = "asp_404" });

    try testing.expectEqual(@as(u32, 1), try countPrompts(&ctx.db, alloc, "ws_item_1"));
}
