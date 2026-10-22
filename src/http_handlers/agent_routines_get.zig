//! `GET /api/workspaces/:workspace_id/items/:item_id/agent_routine`. Returns
//! `{agent_routine, knowledges, tools, system_prompts}` for the
//! agent-routines config bound to this routine workspace_item.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_routine_db = @import("../models/agent_routine.db.zig");

/// Wire shape for a knowledge row in the GET response.
pub const AgentRoutineKnowledgeRow = agent_routine_db.KnowledgeRow;

/// Wire shape for a system-prompt row in the GET response.
pub const AgentRoutineSystemPromptRow = agent_routine_db.SystemPromptRow;

/// Wire shape for the agent-routines config row in the GET response.
pub const AgentRoutineRow = agent_routine_db.AgentRoutineRow;

/// Domain-level error set for `useCase`. The handler maps each variant to an
/// HTTP status code + message via two exhaustive switches (intentional —
/// adding a new variant fails to compile until both are updated).
pub const AgentRoutinesGetError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'routine'`.
    ItemNotRoutine,
    /// The workspace_item is a routine but has no `agent_routines` row yet.
    NotConfigured,
    /// A `db.query` failed.
    DatabaseError,
    /// `allocator.dupe` failed while copying slice fields.
    OutOfMemory,
};

/// Inputs to the agent-routines-get use-case.
pub const AgentRoutinesGetInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

/// Output of the agent-routines-get use-case. All slices are owned by
/// the caller (lifetime = request arena in production).
pub const AgentRoutinesGetOutput = struct {
    agent_routine: AgentRoutineRow,
    knowledges: []const AgentRoutineKnowledgeRow,
    tools: []const []const u8,
    system_prompts: []const AgentRoutineSystemPromptRow,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the agent-routines config row + children for a workspace_item.
/// Validates the workspace_item exists + is of type `'routine'`, then loads
/// the config row and its 3 sub-collections.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: AgentRoutinesGetInput,
) AgentRoutinesGetError!AgentRoutinesGetOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    // Validate item exists + is a routine.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "routine")) return error.ItemNotRoutine;

    const handle: agent_routine_db.DbOrTx = .{ .db = db };

    // Load config row (spec D3: agent_routines.id == workspace_item_id).
    const config = (agent_routine_db.getByWorkspaceItemId(allocator, handle, input.item_id) catch
        return error.DatabaseError) orelse return error.NotConfigured;

    // Load knowledge rows (position DESC).
    const knowledges = agent_routine_db.listKnowledge(allocator, handle, input.item_id) catch
        return error.DatabaseError;

    // Load enabled tool names (tool_name ASC).
    const tools = agent_routine_db.listEnabledToolNames(allocator, handle, input.item_id) catch
        return error.DatabaseError;

    // Load system-prompt rows (position DESC).
    const system_prompts = agent_routine_db.listSystemPrompts(allocator, handle, input.item_id) catch
        return error.DatabaseError;

    return .{
        .agent_routine = config,
        .knowledges = knowledges,
        .tools = tools,
        .system_prompts = system_prompts,
    };
}

/// Free every slice field on a single knowledge row.
fn freeKnowledgeRow(allocator: std.mem.Allocator, k: AgentRoutineKnowledgeRow) void {
    allocator.free(k.id);
    allocator.free(k.routine_id);
    allocator.free(k.file_path);
    if (k.label.len > 0) allocator.free(k.label);
    if (k.content.len > 0) allocator.free(k.content);
    if (k.created_at.len > 0) allocator.free(k.created_at);
    if (k.updated_at.len > 0) allocator.free(k.updated_at);
}

/// Free every slice field on a single system-prompt row.
fn freeSystemPromptRow(allocator: std.mem.Allocator, p: AgentRoutineSystemPromptRow) void {
    allocator.free(p.id);
    allocator.free(p.routine_id);
    if (p.title.len > 0) allocator.free(p.title);
    if (p.content.len > 0) allocator.free(p.content);
    if (p.created_at.len > 0) allocator.free(p.created_at);
    if (p.updated_at.len > 0) allocator.free(p.updated_at);
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Resolves the singleton DB handle,
/// delegates, marshals the output to JSON, maps errors to status codes.
pub fn agentRoutinesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";

    const output = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.ItemNotFound => 404,
            error.ItemNotRoutine => 400,
            error.NotConfigured => 404,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotRoutine => "workspace_item is not a routine",
            error.NotConfigured => "agent_routines not configured for this routine",
            error.DatabaseError => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .agent_routine = output.agent_routine,
        .knowledges = output.knowledges,
        .tools = output.tools,
        .system_prompts = output.system_prompts,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention). Behavioural coverage: 1.

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

    // Full-shape workspace_items (see agents_get.zig setupDb comment).
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: 1 routine with a configured agent_routines row + children.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'My Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'routine', 'routine desc')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_1', 'ws_item_1', '/tmp/a.md', 'A', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('kn_2', 'ws_item_1', '', 'Notes', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "UPDATE agent_config_knowledge SET content = 'inline body' WHERE id = 'kn_2'",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_1', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_2', 'ws_item_1', 'read_file', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('kt_3', 'ws_item_1', 'write_file', 0)",
        &[_][]const u8{},
    );

    // A second routine WITHOUT an agent_routines row → NotConfigured path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_bare', 'ws_1', 'routine', 'Bare Routine')",
        &[_][]const u8{},
    );

    // An agent-type item to verify the ItemNotRoutine path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_agent', 'ws_1', 'agent', 'An agent')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Free everything the use-case allocated for the output.
fn freeOutput(allocator: std.mem.Allocator, output: AgentRoutinesGetOutput) void {
    allocator.free(output.agent_routine.id);
    allocator.free(output.agent_routine.workspace_item_id);
    allocator.free(output.agent_routine.description);
    allocator.free(output.agent_routine.created_at);
    allocator.free(output.agent_routine.updated_at);
    for (output.knowledges) |k| freeKnowledgeRow(allocator, k);
    allocator.free(output.knowledges);
    for (output.tools) |nm| allocator.free(nm);
    allocator.free(output.tools);
    for (output.system_prompts) |p| freeSystemPromptRow(allocator, p);
    allocator.free(output.system_prompts);
}

test "useCase: empty workspace_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "", .item_id = "ws_item_1" }),
    );
}

test "useCase: empty item_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "" }),
    );
}

test "useCase: non-existent workspace_item returns ItemNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_404" }),
    );
}

test "useCase: workspace_item of type agent returns ItemNotRoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotRoutine,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_agent" }),
    );
}

test "useCase: routine without agent_routines row returns NotConfigured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotConfigured,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_bare" }),
    );
}

test "useCase: happy path returns config + knowledges DESC + tools enabled ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    // Config row.
    try testing.expectEqualStrings("ws_item_1", output.agent_routine.id);
    try testing.expectEqualStrings("routine desc", output.agent_routine.description);

    // Knowledges: 2 rows, position DESC. kn_2 (position 1) first.
    try testing.expectEqual(@as(usize, 2), output.knowledges.len);
    try testing.expectEqualStrings("kn_2", output.knowledges[0].id);
    try testing.expectEqualStrings("inline body", output.knowledges[0].content);
    try testing.expectEqualStrings("kn_1", output.knowledges[1].id);

    // Tools: 2 enabled, alphabetical. write_file excluded (enabled=0).
    try testing.expectEqual(@as(usize, 2), output.tools.len);
    try testing.expectEqualStrings("bash", output.tools[0]);
    try testing.expectEqualStrings("read_file", output.tools[1]);
}

test "useCase: returns system_prompts ordered position DESC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES ('sp_low', 'ws_item_1', 'Low', 'low body', 0)",
        &[_][]const u8{},
    );
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_config_system_prompt (id, config_id, title, content, position) VALUES ('sp_high', 'ws_item_1', 'High', 'high body', 3)",
        &[_][]const u8{},
    );

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    try testing.expectEqual(@as(usize, 2), output.system_prompts.len);
    try testing.expectEqualStrings("sp_high", output.system_prompts[0].id);
    try testing.expectEqualStrings("high body", output.system_prompts[0].content);
    try testing.expectEqualStrings("sp_low", output.system_prompts[1].id);
}
