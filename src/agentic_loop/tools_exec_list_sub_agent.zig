// Exec wrapper for the `list_sub_agent` agent tool.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const migration = @import("../migrations/migration.zig");

const sqlite = pabrikcore.sqlite;
const config_mod = pabrikcore.config;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const list_sub_agent_mod = pabrikcore.list_sub_agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execListSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `parameters`
    // field verbatim (the LLM is expected to send `{}`).
    const inner = list_sub_agent_mod.executeListSubAgent(ctx.allocator, ctx.config, ctx.selected_profile_model) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_sub_agent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "list_sub_agent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
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

/// Build a `ToolExecContext` carrying a live `LlmConfig` with one profile
/// ("dev") holding a single sub-agent. `profile_name` selects what
/// `ctx.selected_profile_model` points at.
fn makeTestCtx(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cfg: *const config_mod.LlmConfig,
    profile_name: []const u8,
) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_list_sub",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = cfg,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .selected_profile_model = profile_name,
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
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    const agents = try allocator.alloc(config_mod.LlmConfig.SubAgentConfig, 1);
    agents[0] = .{
        .name = try allocator.dupe(u8, "coder"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://secret.example"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "0.2"),
        .url_style = try allocator.dupe(u8, "openai"),
        .api_key = try allocator.dupe(u8, "sk-secret"),
        .system_prompt = try allocator.dupe(u8, "You are a strict code reviewer."),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    };
    try cfg.profiles_models.put(try allocator.dupe(u8, "dev"), .{
        .model = try allocator.dupe(u8, "dev-model"),
        .base_url = try allocator.dupe(u8, "https://dev"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "dev-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .sub_agents = agents,
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

fn fakeToolCall(name: []const u8) agent.ToolCall {
    // list_sub_agent takes no params — `{}` is the canonical empty-args input.
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = "{}" },
    };
}

// ─── Test 1: populated profile returns wrapped envelope with the row ─────────

test "execListSubAgent: populated profile returns wrapped envelope with sub_agent row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, &cfg, "dev");
    const tc = fakeToolCall("list_sub_agent");

    const result = try execListSubAgent(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"tool\":\"list_sub_agent\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"data\":{") != null);

    // Inner payload carries the row.
    try testing.expect(std.mem.indexOf(u8, result.output, "\"profile\":\"dev\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"coder\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "strict code reviewer") != null);

    // Secrets never reach the wire, even through the adapter.
    try testing.expect(std.mem.indexOf(u8, result.output, "sk-secret") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "api_key") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "base_url") == null);

    // No error on the populated branch.
    try testing.expect(std.mem.indexOf(u8, result.output, "\"error\":null") != null);
}

// ─── Test 2: unknown profile returns wrapped empty list ─────────────────────

test "execListSubAgent: unknown profile returns wrapped envelope with empty list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, &cfg, "ghost-profile");
    const tc = fakeToolCall("list_sub_agent");

    const result = try execListSubAgent(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"tool\":\"list_sub_agent\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);

    // The inner payload is the empty-list signal.
    try testing.expect(std.mem.indexOf(u8, result.output, "\"profile\":\"ghost-profile\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"sub_agents\":[]") != null);

    // No error on the happy absent path.
    try testing.expect(std.mem.indexOf(u8, result.output, "\"error\":null") != null);
}

// ─── Test 3: empty args object tolerated (missing/empty {} args) ─────────────

test "execListSubAgent: empty-string args still return the wrapped envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, &cfg, "dev");
    const tc: agent.ToolCall = .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "list_sub_agent", .arguments = "" },
    };

    const result = try execListSubAgent(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    // The adapter never parses args — empty input is tolerated.
    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "\"count\":1") != null);
}

// ─── Registration: the tool is actually offered to the model ────────────────

test "list_sub_agent is offered to the model and resolves to a dispatchable registry entry" {
    const tools_equipped = @import("tools_equipped.zig");

    // `equips()` is the list the workflow hands the LLM; dropping the entry
    // there makes the tool unreachable without any other test noticing.
    const equip = tools_equipped.equips(testing.allocator);
    defer testing.allocator.free(equip);

    var in_equips = false;
    for (equip) |t| {
        if (std.mem.eql(u8, t.function.name, "list_sub_agent")) in_equips = true;
    }
    try testing.expect(in_equips);

    // Advertised AND dispatchable, carrying the SAME tool def — a registry
    // entry under a different def means the model sees one schema and the
    // dispatcher answers with another.
    var entries: usize = 0;
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
        if (!std.mem.eql(u8, entry.name, "list_sub_agent")) continue;
        entries += 1;
        try testing.expectEqualStrings("list_sub_agent", entry.tool_def.function.name);
    }
    try testing.expectEqual(@as(usize, 1), entries);
    try testing.expect(tools_equipped.isDispatchableToolName("list_sub_agent"));
}
