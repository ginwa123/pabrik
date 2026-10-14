//! Agent-callable tool: `list_sub_agent` — list the subagents configured on
//! the agent's current profile, with full specs.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const config_mod = pabrikcore.config;

/// Input for `list_sub_agent`. Empty struct — no params, profile_name is implicit.
pub const ListSubAgentInput = struct {};

/// Top-level tool definition for the LLM.
pub const list_sub_agent_tool_system_prompt =
    \\## List Sub Agent Tool — Behavior
    \\Use `list_sub_agent` to list the subagents configured on your current profile.
    \\- No parameters. Returns full specs (model, tuning, system prompt) for each sub-agent.
    \\- Call this before `spawn_sub_agent` when you are unsure which `agent_name` values exist or which one fits the job.
    \\- Absent optional tags mean 'inherits the profile default'. Read-only, no side effects.
    \\
;

pub const list_sub_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_sub_agent",
        .description =
        \\List the subagents configured on your current profile, with their full specs (model, tuning, system prompt). Call this before spawn_sub_agent when unsure which agent_name values exist or which fits the job. Absent optional tags mean 'inherits the profile default'. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = list_sub_agent_tool_system_prompt,
    },
};

/// Execute list_sub_agent. Returns a JSON string for the LLM. Caller owns the
/// returned slice and must free it with `allocator.free()`.
pub fn executeListSubAgent(
    allocator: std.mem.Allocator,
    config: *const config_mod.LlmConfig,
    profile_name: []const u8,
) ![]const u8 {
    const SubAgentJSON = struct {
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
        profile: []const u8,
        count: usize,
        sub_agents: []SubAgentJSON,
    };

    var rows = std.ArrayList(SubAgentJSON).empty;
    defer rows.deinit(allocator);

    if (profile_name.len > 0) {
        if (config.getProfile(profile_name)) |profile| {
            for (profile.sub_agents) |sa| {
                if (sa.name.len == 0) continue;
                try rows.append(allocator, .{
                    .name = sa.name,
                    .model = sa.model,
                    .url_style = sa.url_style,
                    .thinking = sa.thinking,
                    .temperature = sa.temperature,
                    .max_capacity_tokens = sa.max_capacity_tokens,
                    .compaction_threshold_percent = sa.compaction_threshold_percent,
                    .thinking_budget_tokens = sa.thinking_budget_tokens,
                    .reasoning_effort = sa.reasoning_effort,
                    .system_prompt = sa.system_prompt,
                });
            }
        }
    }

    return try std.json.Stringify.valueAlloc(allocator, OutJSON{
        .profile = profile_name,
        .count = rows.items.len,
        .sub_agents = rows.items,
    }, .{});
}

const testing = std.testing;

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
    var agents = std.ArrayList(config_mod.LlmConfig.SubAgentConfig).empty;
    errdefer agents.deinit(allocator);
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, "coder"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://secret.example"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "0.2"),
        .url_style = try allocator.dupe(u8, "openai"),
        .api_key = try allocator.dupe(u8, "sk-secret"),
        .system_prompt = try allocator.dupe(u8, "You are a strict code reviewer with deep expertise in systems programming, testing, refactoring, and mentoring junior engineers across many languages."),
        .max_capacity_tokens = 128000,
        .compaction_threshold_percent = 80,
        .thinking_budget_tokens = null,
        .reasoning_effort = try allocator.dupe(u8, "high"),
    });
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, "helper"),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .api_key = try allocator.dupe(u8, ""),
        .system_prompt = try allocator.dupe(u8, "helpful"),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    // Empty-name row must be skipped (never counted, never rendered).
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, "ghost"),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .api_key = try allocator.dupe(u8, ""),
        .system_prompt = try allocator.dupe(u8, "ghost"),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    const owned = try agents.toOwnedSlice(allocator);
    try cfg.profiles_models.put(try allocator.dupe(u8, "dev"), .{
        .model = try allocator.dupe(u8, "dev-model"),
        .base_url = try allocator.dupe(u8, "https://dev"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "dev-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .sub_agents = owned,
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

// ─── Test 1: populated 2-row — full prompt, no truncation, verbatim tuning ──

test "executeListSubAgent: populated profile returns 2 rows with full prompt verbatim" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("dev", obj.get("profile").?.string);
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const rows = obj.get("sub_agents").?.array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    // >80-char prompt must survive in FULL (no truncation).
    try testing.expect(std.mem.indexOf(u8, rows[0].object.get("system_prompt").?.string, "mentoring junior engineers across many languages.") != null);
    // Tuning verbatim.
    try testing.expectEqualStrings("gpt-4o", rows[0].object.get("model").?.string);
    try testing.expectEqualStrings("on", rows[0].object.get("thinking").?.string);
    try testing.expectEqualStrings("0.2", rows[0].object.get("temperature").?.string);
    try testing.expectEqual(@as(i64, 128000), rows[0].object.get("max_capacity_tokens").?.integer);
    try testing.expectEqual(@as(i64, 80), rows[0].object.get("compaction_threshold_percent").?.integer);
    try testing.expectEqualStrings("high", rows[0].object.get("reasoning_effort").?.string);
}

// ─── Test 2: null-omission — absent optional tags on the sparse row ──────────

test "executeListSubAgent: null optionals are null, empty strings emitted verbatim" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("sub_agents").?.array.items;
    // Sparse row keeps empty-string model verbatim, nulls for absent optionals.
    try testing.expectEqualStrings("helper", rows[1].object.get("name").?.string);
    try testing.expectEqualStrings("", rows[1].object.get("model").?.string);
    try testing.expect(rows[0].object.get("max_capacity_tokens").? == .integer);
    try testing.expect(rows[1].object.get("max_capacity_tokens").? == .null);
    try testing.expect(rows[1].object.get("compaction_threshold_percent").? == .null);
    try testing.expect(rows[1].object.get("reasoning_effort").? == .null);
    try testing.expect(rows[1].object.get("thinking_budget_tokens").? == .null);
}

// ─── Test 3: empty-name skip ─────────────────────────────────────────────────

test "executeListSubAgent: empty sa.name rows are skipped" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "ghost") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"count\":2") != null);
}

// ─── Test 4: unknown profile → <empty/> with verbatim echo ───────────────────

test "executeListSubAgent: unknown profile returns empty list with verbatim echo" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "nope");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("nope", obj.get("profile").?.string);
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("sub_agents").?.array.items.len);
}

// ─── Test 5: empty profile name → <empty/> ───────────────────────────────────

test "executeListSubAgent: empty profile name returns empty list" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("", obj.get("profile").?.string);
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
}

// ─── Test 6: secrets absence ─────────────────────────────────────────────────

test "executeListSubAgent: never emits api_key/base_url tags or values" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "sk-secret") == null);
    try testing.expect(std.mem.indexOf(u8, out, "secret.example") == null);
    try testing.expect(std.mem.indexOf(u8, out, "api_key") == null);
    try testing.expect(std.mem.indexOf(u8, out, "base_url") == null);
    try testing.expect(std.mem.indexOf(u8, out, "dev-key") == null);
}

// ─── Test 7: CDATA split on `]]>` inside system_prompt ───────────────────────

test "executeListSubAgent: system_prompt with ]]> stays intact in JSON" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    // Patch the first row's prompt to embed a `]]>` boundary (trivially
    // safe in JSON — no CDATA splitting needed).
    {
        const entry = cfg.profiles_models.getEntry("dev") orelse return error.MissingProfile;
        alloc.free(entry.value_ptr.sub_agents[0].system_prompt);
        entry.value_ptr.sub_agents[0].system_prompt = try alloc.dupe(u8, "before ]]> after");
    }
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("sub_agents").?.array.items;
    try testing.expectEqualStrings("before ]]> after", rows[0].object.get("system_prompt").?.string);
}

// ─── Test 8: JSON schema shape ───────────────────────────────────────────────

test "list_sub_agent_tool JSON schema: name='list_sub_agent', no required params, no properties" {
    const tool = list_sub_agent_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("list_sub_agent", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "spawn_sub_agent") != null);
    try testing.expect(std.mem.indexOf(u8, description, "agent_name") != null);
    try testing.expect(std.mem.indexOf(u8, description, "Read-only, no side effects.") != null);

    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);
}
