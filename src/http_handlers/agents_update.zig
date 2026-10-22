//! `PATCH /api/workspaces/:workspace_id/items/:item_id/agent`. Body:
//! `{description}`. Updates the description of the agent bound to this
//! workspace_item.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// HTTP request body for agent-update. Decoupled from the `AgentUpdateInput`
/// domain struct so the wire format can evolve independently (e.g. adding `?`
/// optional fields) without touching the use-case.
const UpdateAgentBody = struct {
    description: []const u8 = "",
};

/// Subset of the agents row returned by the use-case. Field strings
/// are owned by the caller (lifetime = request arena).
pub const Agent = agent_db.AgentRow;

/// Domain-level error set for `useCase`.
pub const AgentUpdateError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// `db.query` failed while looking up the workspace_item.
    LookupFailed,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'agent'`.
    NotAnAgent,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed (consistency violation).
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `allocator.dupe` failed while copying slice fields. Unreachable
    /// under arena allocator (test builds can hit it), but the
    /// type system requires the variant so `try` propagates.
    OutOfMemory,
};

/// Inputs to the agent-update use-case.
pub const AgentUpdateInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    description: []const u8,
};

/// Output of the agent-update use-case. `agent` is owned by the
/// caller (lifetime = request arena).
pub const AgentUpdateOutput = struct {
    agent: Agent,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an agent's description. Validates that the workspace_item exists
/// and is of type `'agent'`.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: AgentUpdateInput,
) AgentUpdateError!AgentUpdateOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    const handle: agent_db.DbOrTx = .{ .db = db };

    // Validate item exists + is an agent.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "agent")) return error.NotAnAgent;

    // UPDATE description, then read the row back.
    const agent = (agent_db.updateDescription(allocator, handle, input.item_id, input.description) catch
        return error.UpdateFailed) orelse return error.RowVanished;

    return .{ .agent = agent };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentsUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateAgentBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .description = parsed.description,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.LookupFailed => 500,
            error.ItemNotFound => 404,
            error.NotAnAgent => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.LookupFailed => "Failed to query workspace_item",
            error.ItemNotFound => "workspace_item not found",
            error.NotAnAgent => "workspace_item is not an agent",
            error.UpdateFailed => "Failed to update agent",
            error.RefetchFailed => "Failed to read updated agent",
            error.RowVanished => "Agent row vanished after UPDATE",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{ .agent = output.agent }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 4 behavioural
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

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape instead of relying on
    // Migration 001.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: 1 workspace_item of type 'agent' + matching agents row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', 'old description')",
        &[_][]const u8{},
    );

    // Add a kanban-type workspace_item to verify the NotAnAgent path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_kanban', 'ws_1', 'kanban', 'A kanban')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty workspace_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "",
            .item_id = "ws_item_1",
            .description = "new",
        }),
    );
}

test "useCase: empty item_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "",
            .description = "new",
        }),
    );
}

test "useCase: non-existent workspace_item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "ws_item_404",
            .description = "new",
        }),
    );
}

test "useCase: workspace_item of type kanban returns NotAnAgent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAnAgent,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .item_id = "ws_item_kanban",
            .description = "new",
        }),
    );
}

test "useCase: happy path updates description and returns Agent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .item_id = "ws_item_1",
        .description = "freshly updated",
    });
    defer {
        agent_db.freeAgentRow(alloc, output.agent);
    }
    try testing.expectEqualStrings("ws_item_1", output.agent.id);
    try testing.expectEqualStrings("ws_item_1", output.agent.workspace_item_id);
    try testing.expectEqualStrings("freshly updated", output.agent.description);

    // Verify persistence with a fresh query.
    var q = try ctx.db.query(alloc,
        "SELECT description FROM agent_configs WHERE id = 'ws_item_1'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (q.next() catch null).?;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("freshly updated", row.values[0]);
}