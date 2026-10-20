//! Agent-callable tool: `used_tools` — list the tools currently equipped for
//! this session (the "what tools am I using" answer).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `used_tools`. Empty struct — no params, the session is implicit.
pub const UsedToolsInput = struct {};

/// Top-level tool definition for the LLM.
pub const used_tools_tool_system_prompt =
    \\## Used Tools Tool — Behavior
    \\Use `used_tools` to list the tools currently equipped for this session.
    \\- No parameters. Returns each equipped tool's name and description.
    \\- Call this when you need to answer "what tools do I have" or to check whether a tool is available before calling it.
    \\- To discover tools you do NOT have yet, use `search_tool` / `view_tool`, then `use_tool` to equip one. Read-only, no side effects.
    \\
;

pub const used_tools_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "used_tools",
        .description =
        \\List the tools currently equipped for this session with their name and description, so you can check what you have before calling one. To find a tool you lack: search_tool → view_tool → use_tool. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = used_tools_tool_system_prompt,
    },
};

/// One equipped tool as the LLM sees it. The exec adapter builds these
/// from `AgentTool` defs (built-ins) and the MCP cache (equipped MCP tools).
pub const ToolSummary = struct {
    name: []const u8,
    description: []const u8,
};

/// Execute used_tools. Returns a JSON string for the LLM:
/// `{"count":N,"tools":[{"name":...,"description":...}]}`.
pub fn executeUsedTools(
    allocator: std.mem.Allocator,
    equipped: []const ToolSummary,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .count = equipped.len,
        .tools = equipped,
    }, .{});
}

const testing = std.testing;

test "executeUsedTools: empty equipped list yields count 0 and empty tools" {
    const alloc = testing.allocator;
    const out = try executeUsedTools(alloc, &.{});
    defer alloc.free(out);
    try testing.expectEqualStrings("{\"count\":0,\"tools\":[]}", out);
}

test "executeUsedTools: populated list echoes names and descriptions" {
    const alloc = testing.allocator;
    const equipped = [_]ToolSummary{
        .{ .name = "read_file", .description = "Read a file." },
        .{ .name = "mcp_graphify_query_graph", .description = "Ask the graph." },
    };
    const out = try executeUsedTools(alloc, &equipped);
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const tools = obj.get("tools").?.array;
    try testing.expectEqual(@as(usize, 2), tools.items.len);
    try testing.expectEqualStrings("read_file", tools.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Read a file.", tools.items[0].object.get("description").?.string);
    try testing.expectEqualStrings("mcp_graphify_query_graph", tools.items[1].object.get("name").?.string);
}

test "executeUsedTools: preserves input order" {
    const alloc = testing.allocator;
    const equipped = [_]ToolSummary{
        .{ .name = "write_file", .description = "w" },
        .{ .name = "command", .description = "c" },
        .{ .name = "ask_user", .description = "a" },
    };
    const out = try executeUsedTools(alloc, &equipped);
    defer alloc.free(out);
    const write_pos = std.mem.indexOf(u8, out, "\"write_file\"").?;
    const command_pos = std.mem.indexOf(u8, out, "\"command\"").?;
    const ask_pos = std.mem.indexOf(u8, out, "\"ask_user\"").?;
    try testing.expect(write_pos < command_pos);
    try testing.expect(command_pos < ask_pos);
}

// Exec adapter — merged from `used_tools.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const pabrikcore = @import("pabrikcore");
const exec_tools = @import("../../../agentic_loop/tools.zig");
const tools_equipped = @import("../../../agentic_loop/tools_equipped.zig");
const tool_eligibility = @import("../../../agentic_loop/tool_eligibility.zig");
const llm_history = @import("../../../agentic_loop/llm_history.zig");
const migration = @import("../../../migrations/migration.zig");
const sqlite = pabrikcore.sqlite;
const config_mod = pabrikcore.config;
const ToolExecContext = exec_tools.ToolExecContext;
const ToolExecResult = exec_tools.ToolExecResult;
const agent = pabrikcore.agent;
const ask_user_mod = pabrikcore.ask_user;
const wrapToolOutput = exec_tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
/// Resolve the session's effective tool list (mirror of
/// `workflow.filterAndMergeTools`, minus the MCP-null branch which is handled
/// by the live cache lookup below).
fn resolveEquipped(ctx: ToolExecContext) ![]ToolSummary {
    const registered = tools_equipped.equips(ctx.allocator);
    const enabled = try tool_eligibility.allowlistFilter(
        ctx.allocator,
        registered,
        ctx.allowed_tools,
        ctx.is_sub_agent,
    );

    var out: std.ArrayList(ToolSummary) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .{};

    for (enabled) |tool| {
        if (seen.contains(tool.function.name)) continue;
        try seen.put(ctx.allocator, tool.function.name, {});
        try out.append(ctx.allocator, .{
            .name = tool.function.name,
            .description = tool.function.description,
        });
    }

    // Built-ins + MCP exec_tools this session equipped for itself via `use_tool`.
    const equipped_rows = try llm_history.getProgressiveTools(ctx.allocator, ctx.db, ctx.session_id);

    for (equipped_rows) |row| {
        if (seen.contains(row.tool_name)) continue;
        if (ctx.is_sub_agent and ask_user_mod.isMainAgentOnly(row.tool_name)) continue;
        for (registered) |tool| {
            if (std.mem.eql(u8, tool.function.name, row.tool_name)) {
                try seen.put(ctx.allocator, tool.function.name, {});
                try out.append(ctx.allocator, .{
                    .name = tool.function.name,
                    .description = tool.function.description,
                });
                break;
            }
        }
    }

    // MCP exec_tools reach the wire ONLY when this session equipped them.
    const di = pabrikcore.getSingleton() catch null;
    const mcp: ?[]const agent.AgentTool = if (di) |d| d.getMcpToolsCached(ctx.allocator) else null;
    if (mcp) |mcp_tools| {
        for (mcp_tools) |tool| {
            if (seen.contains(tool.function.name)) continue;
            var equipped = false;
            for (equipped_rows) |row| {
                if (std.mem.eql(u8, row.tool_name, tool.function.name)) {
                    equipped = true;
                    break;
                }
            }
            if (!equipped) continue;
            try seen.put(ctx.allocator, tool.function.name, {});
            try out.append(ctx.allocator, .{
                .name = tool.function.name,
                .description = tool.function.description,
            });
        }
    }

    return try out.toOwnedSlice(ctx.allocator);
}

pub fn execUsedTools(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `parameters`
    // field verbatim (the LLM is expected to send `{}`).
    const equipped = resolveEquipped(ctx) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "used_tools", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = executeUsedTools(ctx.allocator, equipped) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "used_tools", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const output = try wrapToolOutput(ctx.allocator, "used_tools", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// Build a `ToolExecContext` for used_tools tests. `allowed_tools` is the
/// already-resolved CSV (what `handle_tool` threads through at dispatch);
/// `is_sub_agent` selects the main-agent-only strip.
fn makeTestCtx(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cfg: *const config_mod.LlmConfig,
    allowed_tools: []const u8,
    is_sub_agent: bool,
) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_used_tools",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = cfg,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .selected_profile_model = "",
        .allowed_tools = allowed_tools,
        .is_sub_agent = is_sub_agent,
    };
}

fn testConfig(allocator: std.mem.Allocator) !config_mod.LlmConfig {
    var cfg: config_mod.LlmConfig = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "top-key"),
        .model = try allocator.dupe(u8, "top-model"),
        .base_url = try allocator.dupe(u8, "https://top"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_agent = null,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .agents = config_mod.LlmConfig.AgentsMap.init(allocator),
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    return cfg;
}

// ─── Test 1: allowlisted subset is exactly what the tool reports ────────────

test "execUsedTools: reports exactly the allowlisted tools" {
    const alloc = exec_testing.allocator;
    // resolveEquipped has intermediate allocs (equips dupe, allowlist
    // filter, summary list) that the per-request arena reaps in
    // production — mirror that here with a per-test arena.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(a, &ctx.db, &cfg, "read_file,glob", false);
    const tc: agent.ToolCall = .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "used_tools", .arguments = "{}" },
    };

    const result = try execUsedTools(tcx, tc);
    // No free: `a` (the arena) owns the output, reaped by arena.deinit.

    try exec_testing.expect(result.output_allocated);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"tool\":\"used_tools\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"count\":2") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"read_file\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"glob\"") != null);
    // Not allowlisted → absent from the listing.
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"write_file\"") == null);
}

// ─── Test 2: sub-agent strip applies (main-agent-only exec_tools hidden) ─────────

test "execUsedTools: sub-agent sessions do not list main-agent-only tools" {
    const alloc = exec_testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(a, &ctx.db, &cfg, "all", true);
    const tc: agent.ToolCall = .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "used_tools", .arguments = "{}" },
    };

    const result = try execUsedTools(tcx, tc);
    // No free: arena-owned.

    try exec_testing.expect(result.output_allocated);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"spawn_sub_agent\"") == null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"ask_user\"") == null);
    // used_tools itself is sub-agent-safe → present in its own listing.
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"used_tools\"") != null);
}

// ─── Test 3: none sentinel yields an empty listing ──────────────────────────

test "execUsedTools: none sentinel yields count 0" {
    const alloc = exec_testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(a, &ctx.db, &cfg, "none", false);
    const tc: agent.ToolCall = .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "used_tools", .arguments = "{}" },
    };

    const result = try execUsedTools(tcx, tc);
    // No free: arena-owned.

    try exec_testing.expect(result.output_allocated);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"count\":0") != null);
}

// ─── Registration: the tool is actually offered to the model ────────────────

test "used_tools is offered to the model and resolves to a dispatchable registry entry" {
    // `equips()` is the list the workflow hands the LLM; dropping the entry
    // there makes the tool unreachable without any other test noticing.
    const equip = tools_equipped.equips(exec_testing.allocator);
    defer exec_testing.allocator.free(equip);

    var in_equips = false;
    for (equip) |t| {
        if (std.mem.eql(u8, t.function.name, "used_tools")) in_equips = true;
    }
    try exec_testing.expect(in_equips);

    // Advertised AND dispatchable, carrying the SAME tool def — a registry
    // entry under a different def means the model sees one schema and the
    // dispatcher answers with another.
    var entries: usize = 0;
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
        if (!std.mem.eql(u8, entry.name, "used_tools")) continue;
        entries += 1;
        try exec_testing.expectEqualStrings("used_tools", entry.tool_def.function.name);
    }
    try exec_testing.expectEqual(@as(usize, 1), entries);
    try exec_testing.expect(tools_equipped.isDispatchableToolName("used_tools"));
}

