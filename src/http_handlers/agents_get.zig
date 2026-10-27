//! `GET /api/workspaces/:workspace_id/items/:item_id/agent`. Returns `{agent,
//! knowledge, tools}` for the agent bound to this workspace_item.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_db = @import("../models/agent.db.zig");

/// Wire shape for a knowledge row in the GET response.
pub const AgentKnowledgeRow = agent_db.KnowledgeRow;

/// Wire shape for a system-prompt row in the GET response (Migration 080).
pub const AgentSystemPromptRow = agent_db.SystemPromptRow;

/// Wire shape for the agent row in the GET response.
pub const AgentRow = agent_db.AgentRow;

/// Domain-level error set for `useCase`.
pub const AgentGetError = error{
    /// `workspace_id` or `item_id` path param was missing or empty.
    IdsRequired,
    /// The workspace_item row did not exist.
    ItemNotFound,
    /// The workspace_item exists but its `item_type` is not `'agent'`.
    ItemNotAgent,
    /// A `db.query` failed.
    DatabaseError,
    /// `allocator.dupe` failed while copying slice fields. Unreachable
    /// under arena allocator but the type system requires the
    /// variant so `try` propagates.
    OutOfMemory,
};

/// Inputs to the agent-get use-case.
pub const AgentGetInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
};

/// Output of the agent-get use-case. All slices are owned by the
/// caller (lifetime = request arena in production).
pub const AgentGetOutput = struct {
    agent: AgentRow,
    knowledge: []const AgentKnowledgeRow,
    tools: []const []const u8,
    /// Per-agent named system-prompt blocks (Migration 080), ordered
    /// position DESC — same ordering convention as knowledge.
    system_prompts: []const AgentSystemPromptRow,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the agent row + knowledge + tools for a workspace_item. Validates
/// the workspace_item exists + is of type `'agent'`, then loads the 3
/// sub-collections.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: AgentGetInput,
) AgentGetError!AgentGetOutput {
    if (input.workspace_id.len == 0 or input.item_id.len == 0) {
        return error.IdsRequired;
    }

    const handle: agent_db.DbOrTx = .{ .db = db };

    // Validate item exists + is an agent.
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{input.item_id},
    ) catch return error.DatabaseError;
    defer q.deinit();
    const row = (q.next() catch null) orelse return error.ItemNotFound;
    defer row.deinit(allocator);
    if (!std.mem.eql(u8, row.values[0], "agent")) return error.ItemNotAgent;

    // Load agent row.
    const agent = (agent_db.getById(allocator, handle, input.item_id) catch return error.DatabaseError) orelse
        return error.ItemNotFound;

    // Load knowledge rows (position DESC).
    const knowledge = agent_db.listKnowledge(allocator, handle, input.item_id) catch return error.DatabaseError;

    // Load enabled tool names (tool_name ASC).
    const tools = agent_db.listEnabledToolNames(allocator, handle, input.item_id) catch return error.DatabaseError;

    // Load system-prompt rows (Migration 080), position DESC.
    const system_prompts = agent_db.listSystemPrompts(allocator, handle, input.item_id) catch return error.DatabaseError;

    return .{
        .agent = agent,
        .knowledge = knowledge,
        .tools = tools,
        .system_prompts = system_prompts,
    };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Resolves the singleton DB
/// handle, delegates to `useCase`, and maps the use-case outcome
/// to an HTTP response.
pub fn agentsGetHandler(
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
            error.ItemNotAgent => 400,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "workspace_id and item_id required",
            error.ItemNotFound => "workspace_item not found",
            error.ItemNotAgent => "workspace_item is not an agent",
            error.DatabaseError => "DB error",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .agent = output.agent,
        .knowledge = output.knowledge,
        .tools = output.tools,
        .system_prompts = output.system_prompts,
    }, .{});
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
    try test_db.openMemory(&db, io);

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);
    // mirror that, or the `content` column (Migration 079) is missing.
    // Same for the agent_system_prompt table (Migration 080).

    // Seed: 1 agent + 2 knowledge rows + 2 enabled tools + 1 disabled tool.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', 'desc')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('know_1', 'ws_item_1', '/tmp/a.md', 'A', 0)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, position) VALUES ('know_2', 'ws_item_1', '/tmp/b.md', '', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('at_1', 'ws_item_1', 'bash', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('at_2', 'ws_item_1', 'read_file', 1)",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_config_tools (id, config_id, tool_name, enabled) VALUES ('at_3', 'ws_item_1', 'write_file', 0)",
        &[_][]const u8{},
    );

    // Add a kanban-type workspace_item to verify the ItemNotAgent path.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_kanban', 'ws_1', 'kanban', 'A kanban')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Free everything the use-case allocated for the output.
fn freeOutput(allocator: std.mem.Allocator, output: AgentGetOutput) void {
    agent_db.freeAgentRow(allocator, output.agent);
    for (output.knowledge) |k| agent_db.freeKnowledgeRow(allocator, k);
    allocator.free(output.knowledge);
    for (output.tools) |n| allocator.free(n);
    allocator.free(output.tools);
    for (output.system_prompts) |p| agent_db.freeSystemPromptRow(allocator, p);
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

test "useCase: workspace_item of type kanban returns ItemNotAgent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ItemNotAgent,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_kanban" }),
    );
}

test "useCase: happy path returns agent + knowledge DESC + tools enabled ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    // Agent.
    try testing.expectEqualStrings("ws_item_1", output.agent.id);
    try testing.expectEqualStrings("desc", output.agent.description);

    // Knowledge: 2 rows, position DESC. know_2 (position 1) first, know_1 (position 0) second.
    try testing.expectEqual(@as(usize, 2), output.knowledge.len);
    try testing.expectEqualStrings("know_2", output.knowledge[0].id);
    try testing.expectEqualStrings("know_1", output.knowledge[1].id);

    // Tools: 2 enabled, alphabetical. write_file excluded (enabled=0).
    try testing.expectEqual(@as(usize, 2), output.tools.len);
    try testing.expectEqualStrings("bash", output.tools[0]);
    try testing.expectEqualStrings("read_file", output.tools[1]);
}

test "useCase: returns content field for knowledge rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed one inline-content row (position 5 → sorts first under DESC).
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_config_knowledge (id, config_id, file_path, label, content, position) VALUES ('know_inline', 'ws_item_1', '', 'Notes', 'inline body', 5)",
        &[_][]const u8{},
    );

    const output = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1", .item_id = "ws_item_1" });
    defer freeOutput(alloc, output);

    try testing.expectEqual(@as(usize, 3), output.knowledge.len);
    // know_inline first (position 5 DESC), then know_2 (1), then know_1 (0).
    try testing.expectEqualStrings("know_inline", output.knowledge[0].id);
    try testing.expectEqualStrings("inline body", output.knowledge[0].content);
    // File-backed rows round-trip with empty content.
    try testing.expectEqualStrings("", output.knowledge[1].content);
    try testing.expectEqualStrings("", output.knowledge[2].content);
}

test "useCase: returns system_prompts ordered position DESC (Migration 080)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed two prompt rows: sp_low at position 0, sp_high at position 3.
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
    // position DESC: sp_high (3) first, sp_low (0) second.
    try testing.expectEqualStrings("sp_high", output.system_prompts[0].id);
    try testing.expectEqualStrings("high body", output.system_prompts[0].content);
    try testing.expectEqualStrings("sp_low", output.system_prompts[1].id);
}