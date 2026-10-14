//! `POST /api/agents/:agent_id/tools`. Enables a tool for an agent. Body:
//! `{tool_name}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");

/// HTTP request body for tool-create. Decoupled from the `ToolCreateInput`
/// domain struct so the wire format can evolve independently (e.g. adding `?`
/// optional fields) without touching the use-case.
const CreateToolBody = struct {
    tool_name: []const u8,
};

/// Subset of the agent_tools row returned by the use-case.
pub const ToolRow = agent_db.ToolRow;

/// Domain-level error set for `useCase`.
pub const ToolCreateError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// Body `tool_name` field was missing or empty.
    ToolNameRequired,
    /// `tool_name` is not in the canonical registry.
    UnknownTool,
    /// The agent already has this tool enabled (UNIQUE violation).
    DuplicateTool,
    /// `db.exec` failed on the INSERT (for a reason other than
    /// UNIQUE — surfaced as 500 to differentiate from `DuplicateTool`).
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation. Unreachable
    /// under arena allocator but the type system requires the
    /// variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the tool-create use-case.
pub const ToolCreateInput = struct {
    agent_id: []const u8,
    tool_name: []const u8,
};

/// Output of the tool-create use-case.
pub const ToolCreateOutput = struct {
    tool: ToolRow,
};

/// Validate tool_name exists in UNIFIED_TOOL_REGISTRY. Testable in
/// isolation (no DB needed) — pulled out as a helper so the use-case
/// stays focused on DB work.
fn isKnownTool(tool_name: []const u8) bool {
    const registry = tools_equipped.UNIFIED_TOOL_REGISTRY();
    for (registry) |entry| {
        if (std.mem.eql(u8, entry.name, tool_name)) return true;
    }
    return false;
}

// =====================================================================
// Use case
// =====================================================================

/// Enable a tool for the given agent. Validates the tool_name is in the
/// canonical registry, then INSERTs with `enabled = 1`.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: ToolCreateInput,
) ToolCreateError!ToolCreateOutput {
    if (input.agent_id.len == 0) return error.AgentIdRequired;
    if (input.tool_name.len == 0) return error.ToolNameRequired;
    if (!isKnownTool(input.tool_name)) return error.UnknownTool;

    const handle: agent_db.DbOrTx = .{ .db = db };

    // INSERT. A null return means the UNIQUE(agent_id, tool_name)
    // constraint fired — the agent already has this tool, so the
    // caller answers 409 rather than 500.
    const tool = (agent_db.insertTool(allocator, handle, input.agent_id, input.tool_name) catch
        return error.InsertFailed) orelse return error.DuplicateTool;

    return .{ .tool = tool };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentToolsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(CreateToolBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .tool_name = parsed.tool_name,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.ToolNameRequired => 400,
            error.UnknownTool => 400,
            error.DuplicateTool => 409,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.ToolNameRequired => "tool_name is required",
            error.UnknownTool => "tool_name is not in the registry",
            error.DuplicateTool => "tool already enabled for this agent",
            error.InsertFailed => "Failed to insert tool",
            error.RefetchFailed => "Failed to read row",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.tool, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 4 behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = @import("../migrations/migration.zig").Migration076AddAgentsAndAgentKnowledgeAndAgentTools;

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
    try Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up(&db, testing.allocator);

    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('ws_item_1', 'ws_item_1', '')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns AgentIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentIdRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "", .tool_name = "command" }),
    );
}

test "useCase: empty tool_name returns ToolNameRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ToolNameRequired,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "" }),
    );
}

test "useCase: unknown tool_name returns UnknownTool" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "totally_made_up_tool_xyz" }),
    );

    // Legacy shell names are not equipped anymore (unify 2026-09-04).
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "bash" }),
    );
    try testing.expectError(
        error.UnknownTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "pwsh" }),
    );
}

test "useCase: duplicate insert returns DuplicateTool (UNIQUE violation)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // First insert succeeds.
    {
        const first = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" });
        defer {
            alloc.free(first.tool.id);
            alloc.free(first.tool.agent_id);
            alloc.free(first.tool.tool_name);
        }
    }

    // Second insert with same (agent_id, tool_name) fails with DuplicateTool.
    try testing.expectError(
        error.DuplicateTool,
        useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" }),
    );
}

test "useCase: happy path inserts row with enabled=1" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .agent_id = "ws_item_1", .tool_name = "command" });
    defer {
        agent_db.freeToolRow(alloc, output.tool);
    }
    try testing.expectEqualStrings("ws_item_1", output.tool.agent_id);
    try testing.expectEqualStrings("command", output.tool.tool_name);
    try testing.expectEqual(@as(u8, 1), output.tool.enabled);
    // id should be a fresh "at_<ts>" string
    try testing.expect(output.tool.id.len > 2);
}