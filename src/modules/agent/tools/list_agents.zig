//! Agent-callable tool: `list_agents` — list the configured agents with
//! their full specs.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const config_mod = pabrikcore.config;

/// Input for `list_agents`. Empty struct — no params.
pub const ListAgentsInput = struct {};

/// Top-level tool definition for the LLM.
pub const list_agents_tool_system_prompt =
    \\## List Agents Tool — Behavior
    \\Use `list_agents` to list the ENABLED agents configured in this workspace.
    \\- No parameters. Returns full specs (model, tuning, system prompt) for each agent.
    \\- Disabled agents never appear here and cannot be spawned; the user switches them on in Settings.
    \\- Call this before `spawn_sub_agent` when you are unsure which `agent_name` values exist or which one fits the job.
    \\- Absent optional tags mean 'inherits the default'. Read-only, no side effects.
    \\
;

pub const list_agents_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_agents",
        .description =
        \\List the ENABLED agents configured in this workspace, with their full specs (model, tuning, system prompt). Disabled agents are never listed and cannot be spawned. Call this before spawn_sub_agent when unsure which agent_name values exist or which fits the job. Absent optional tags mean 'inherits the default'. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = list_agents_tool_system_prompt,
    },
};

/// Execute list_agents. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeListAgents(
    allocator: std.mem.Allocator,
    config: *const config_mod.LlmConfig,
) ![]const u8 {
    const AgentJSON = struct {
        name: []const u8,
        model: []const u8,
        url_style: []const u8,
        thinking: []const u8,
        temperature: []const u8,
        max_capacity_tokens: ?u32 = null,
        compaction_threshold_percent: ?u8 = null,
        thinking_budget_tokens: ?u32 = null,
        reasoning_effort: ?[]const u8 = null,
        system_prompt: []const u8,
    };
    const OutJSON = struct {
        count: usize,
        agents: []AgentJSON,
    };

    var rows = std.ArrayList(AgentJSON).empty;
    defer rows.deinit(allocator);

    var it = config.agents.iterator();
    while (it.next()) |entry| {
        const cfg = entry.value_ptr.*;
        if (entry.key_ptr.*.len == 0) continue;
        if (!cfg.enabled) continue;
        try rows.append(allocator, .{
            .name = entry.key_ptr.*,
            .model = cfg.model,
            .url_style = cfg.url_style,
            .thinking = cfg.thinking,
            .temperature = cfg.temperature,
            .max_capacity_tokens = cfg.max_capacity_tokens,
            .compaction_threshold_percent = cfg.compaction_threshold_percent,
            .thinking_budget_tokens = cfg.thinking_budget_tokens,
            .reasoning_effort = cfg.reasoning_effort,
            .system_prompt = cfg.system_prompt,
        });
    }

    return try std.json.Stringify.valueAlloc(allocator, OutJSON{
        .count = rows.items.len,
        .agents = rows.items,
    }, .{});
}

// Exec adapter — the tool definition above and its executor below live in
// ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const migration = @import("../../../migrations/migration.zig");
const sqlite = exec_pabrikcore.sqlite;
const database = exec_pabrikcore.database;
const exec_config_mod = exec_pabrikcore.config;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execListAgents(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // No input to parse — the schema declares zero required params.
    // Use `tc.function.arguments` for the envelope's `parameters`
    // field verbatim (the LLM is expected to send `{}`).
    const inner = executeListAgents(ctx.allocator, ctx.config) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "list_agents", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

/// A live `LlmConfig` holding two configured agents.
fn testConfig(allocator: std.mem.Allocator) !exec_config_mod.LlmConfig {
    var cfg: exec_config_mod.LlmConfig = .{
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
        .mcp_servers = exec_config_mod.LlmConfig.McpServersMap.init(allocator),
        .agents = exec_config_mod.LlmConfig.AgentsMap.init(allocator),
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    try cfg.agents.put(try allocator.dupe(u8, "coder"), .{
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://secret.example"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "0.2"),
        .api_key = try allocator.dupe(u8, "sk-secret"),
        .url_style = try allocator.dupe(u8, "openai"),
        .system_prompt = try allocator.dupe(u8, "You are a strict code reviewer."),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    try cfg.agents.put(try allocator.dupe(u8, "writer"), .{
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://secret.example"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "sk-secret"),
        .url_style = try allocator.dupe(u8, "openai"),
        .system_prompt = try allocator.dupe(u8, "You write docs."),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

fn fakeToolCall(name: []const u8) agent.ToolCall {
    // list_agents takes no params — `{}` is the canonical empty-args input.
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = "{}" },
    };
}

test "list_agents lists every configured agent with its specs" {
    const alloc = exec_testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const out = try executeListAgents(alloc, &cfg);
    defer alloc.free(out);

    try exec_testing.expect(std.mem.indexOf(u8, out, "\"count\":2") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"coder\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"writer\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "strict code reviewer") != null);
}

test "list_agents reports zero agents when none are configured" {
    const alloc = exec_testing.allocator;
    var cfg: exec_config_mod.LlmConfig = .{
        .allocator = alloc,
        .api_key = try alloc.dupe(u8, "k"),
        .model = try alloc.dupe(u8, "m"),
        .base_url = try alloc.dupe(u8, "https://top"),
        .url_style = try alloc.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_agent = null,
        .mcpServers_parsed = null,
        .mcp_servers = exec_config_mod.LlmConfig.McpServersMap.init(alloc),
        .agents = exec_config_mod.LlmConfig.AgentsMap.init(alloc),
        .random_names = &.{},
    };
    defer cfg.deinit();

    const out = try executeListAgents(alloc, &cfg);
    defer alloc.free(out);
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"count\":0") != null);
}

test "list_agents never puts an api_key on the wire" {
    const alloc = exec_testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    const out = try executeListAgents(alloc, &cfg);
    defer alloc.free(out);
    try exec_testing.expect(std.mem.indexOf(u8, out, "sk-secret") == null);
}

test "execListAgents returns a wrapped envelope naming the tool" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    var cfg = try testConfig(alloc);
    defer cfg.deinit();

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const exec_ctx: ToolExecContext = .{
        .allocator = alloc,
        .io = std.testing.io,
        .db = &ctx.db,
        .logger = undefined,
        .session_id = "sess_list_agents",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = &cfg,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .selected_profile_model = "",
    };

    const result = try execListAgents(exec_ctx, fakeToolCall("list_agents"));
    defer alloc.free(result.output);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"tool\":\"list_agents\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, result.output, "\"name\":\"coder\"") != null);
}

/// A live `LlmConfig` whose agents are (name, enabled) pairs — the disabled
/// half is what `list_agents` must never show.
fn configWithFlags(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    flags: []const bool,
) !exec_config_mod.LlmConfig {
    var cfg: exec_config_mod.LlmConfig = .{
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
        .mcp_servers = exec_config_mod.LlmConfig.McpServersMap.init(allocator),
        .agents = exec_config_mod.LlmConfig.AgentsMap.init(allocator),
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    for (names, flags) |name, enabled| {
        try cfg.agents.put(try allocator.dupe(u8, name), .{
            .model = try allocator.dupe(u8, "gpt-4o"),
            .base_url = try allocator.dupe(u8, "https://example"),
            .thinking = try allocator.dupe(u8, "auto"),
            .temperature = try allocator.dupe(u8, "auto"),
            .api_key = try allocator.dupe(u8, "sk-secret"),
            .url_style = try allocator.dupe(u8, "openai"),
            .system_prompt = try allocator.dupe(u8, "a persona"),
            .enabled = enabled,
        });
    }
    return cfg;
}

test "list_agents leaves a disabled agent out of the list" {
    const alloc = exec_testing.allocator;
    var cfg = try configWithFlags(alloc, &.{ "coder", "retired" }, &.{ true, false });
    defer cfg.deinit();

    const out = try executeListAgents(alloc, &cfg);
    defer alloc.free(out);

    try exec_testing.expect(std.mem.indexOf(u8, out, "\"count\":1") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "\"name\":\"coder\"") != null);
    try exec_testing.expect(std.mem.indexOf(u8, out, "retired") == null);
}

test "list_agents reports zero when every configured agent is disabled" {
    const alloc = exec_testing.allocator;
    var cfg = try configWithFlags(alloc, &.{ "a", "b" }, &.{ false, false });
    defer cfg.deinit();

    const out = try executeListAgents(alloc, &cfg);
    defer alloc.free(out);

    try exec_testing.expect(std.mem.indexOf(u8, out, "\"count\":0") != null);
}
