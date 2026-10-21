const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const inherited_context_helper = @import("../../../agentic_loop/inherited_context.zig");
// The main-agent-only tool list lives with `ask_user` (the tool that made a
// second entry necessary) so the parse-time validation here and
// `tool_eligibility.zig`'s strip can never disagree about membership.
const main_agent_only = @import("ask_user.zig");

pub const SubAgentInput = struct {
    instruction: []const u8,
    tools: []const []const u8, // REQUIRED explicit allowlist — no omit, no "all", no empty
    timeout_seconds: ?u32 = null, // optional timeout for this sub-agent (0 = no timeout)
    inherited_context: ?[]const u8 = null, // optional mode string for parent history inheritance
    agent_name: []const u8,
};

pub const SubAgentsInput = struct {
    sub_agents: []const SubAgentInput,

    pub fn deinit(self: *const SubAgentsInput, allocator: std.mem.Allocator) void {
        for (self.sub_agents) |sa| {
            allocator.free(sa.instruction);
            for (sa.tools) |tool_name| {
                allocator.free(tool_name);
            }
            allocator.free(sa.tools);
            // Note: timeout_seconds doesn't need freeing (it's an optional primitive)
            if (sa.inherited_context) |ctx| allocator.free(ctx);
            allocator.free(sa.agent_name);
        }
        allocator.free(self.sub_agents);
    }
};

pub const spawn_sub_agent_tool_system_prompt =
    \\## Spawn Sub Agent Tool — Behavior
    \\Use `spawn_sub_agent` to delegate independent sub-tasks in parallel.
    \\- Provide `instruction` (full task details), `agent_name` (a configured agent, from `list_agents`), and `tools` (REQUIRED explicit allowlist — never omit, never "all"). The sub-agent runs isolated and returns a result.
    \\- `ask_user` and `spawn_sub_agent` are main-agent-only: never list them for a sub-agent (rejected at parse time). A sub-agent cannot reach the human — if you need a decision, ask it yourself with `ask_user` before spawning, or bake the answer into the `instruction`.
    \\- Use for parallel research or multi-file work, not for trivial single-step tasks. Up to 20 sub-agents in parallel.
    \\- Explorer-code sub-agents (read-only: read_file, glob, search) share your cwd — NO new worktree needed.
    \\- Writer sub-agents (write_file, text_replace, remove_file, shell commands via `command`) MUST be told explicitly in `instruction` to call `set_git_worktree` first (path `.worktree/worktrees_agent_<randomname>`), do the work there, then return a summary of changed files and optionally push. Include `set_git_worktree` in their `tools`.
    \\
;

pub const spawn_sub_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "spawn_sub_agent",
        .description =
        \\Spawn 1 to 20 parallel sub-agents to complete independent tasks concurrently.
        \\
        \\- Sub-agents run in parallel and return results separately. Each one is a fresh context: put ALL necessary context, background and instructions directly in its "instruction" field.
        \\- Use it when work splits into independent parallel workloads (research several topics at once, process many files / URLs / data sources).
        \\
        \\TOOLS (REQUIRED, explicit allowlist):
        \\- Every sub-agent MUST list its own "tools": a non-empty array of exact tool names. Missing, empty, or ["all"] is rejected at parse time. There is no omit-means-all — pick the minimal set the task needs. Explorer-code (read-only research) e.g. ["read_file", "glob", "search"]. Writer e.g. ["read_file", "write_file", "text_replace", "set_git_worktree", "command"].
        \\- MAIN-AGENT-ONLY: "ask_user" and "spawn_sub_agent" can never be given to a sub-agent and listing either is rejected at parse time. A sub-agent cannot reach the human, so put any question in YOUR "instruction" instead, or ask the human yourself before spawning.
        \\- Unknown names are ignored (the child never receives them), so double-check spelling against the tool list.
        \\
        \\WORKTREE RULE (explorer shares, writer isolates):
        \\- Explorer-code sub-agent (read-only: read_file, glob, search, semantic_search, web_search): NO new worktree — it shares your cwd.
        \\- Writer/editor sub-agent (anything that creates or modifies files): you MUST tell it explicitly in "instruction" to call `set_git_worktree` FIRST with a path under `.worktree/worktrees_agent_<randomname>`, do all file work inside that worktree, then return a summary of changed files and whether it pushed. Its "tools" MUST include "set_git_worktree" plus the write tools it needs.
        \\
        \\AGENT_NAME (REQUIRED): the name of a configured agent, from the list `list_agents` shows. Call `list_agents` first if you are unsure which names exist or which fits; absent optional tags there mean "inherits the default". The spawned sub-agent takes that agent's model, base_url, api_key, url_style, thinking, temperature and system_prompt (injected as its "## Your Active Agent Configuration" block). The name is also the label on the result XML's <agent name="...">. If the name is NOT found, a random "agent-{16 hex chars}" name is used with the orchestrator's default model / api_key / base_url / url_style and no specialized system prompt, and the affected <agent> tag carries random_fallback="true".
        \\
        \\Optional per sub-agent:
        \\- "timeout_seconds": on expiry the sub-agent is terminated and returns an error. Default: no timeout (runs until completion).
        \\- "inherited_context": whether the parent's recent conversation history is injected into the sub-agent's system prompt as a labelled read-only block ("## Conversation History From Parent Agent"). Values: "none" (default when omitted), "last:N" (N: 1-50, default 10), "all" (capped at 50), "since_last_user". Only user and assistant text turns are inherited — the parent's tool calls and tool results are NOT, because the sub-agent has its own tool set.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "json_input",
                    .type = "string",
                    .description =
                    \\A JSON string defining the sub-agents to  Maximum 20.
                    \\{
                    \\  "sub_agents": [
                    \\    {
                    \\      "instruction": "Full task details", // Required. Self-contained: include ALL context the agent needs.
                    \\      "agent_name": "code-reviewer",      // Required. A configured agent, from list_agents.
                    \\      "tools": ["read_file", "glob", "search"], // REQUIRED non-empty explicit allowlist. Never omit, never "all".
                    \\      "timeout_seconds": 300,             // Optional. Seconds (0 = no limit).
                    \\      "inherited_context": "last:5"       // Optional. Parent-history inheritance mode.
                    \\    }
                    \\  ]
                    \\}
                    \\Rejected at parse time: a missing "tools", [], ["all"], and a main-agent-only name. A writer instruction must open by telling the sub-agent to call set_git_worktree.
                    ,
                },
            },
            .required = &.{"json_input"},
        },
        .system_prompt = spawn_sub_agent_tool_system_prompt,
    },
};

/// Parse JSON input to extract sub-agents
/// Returns error if JSON is invalid or more than max_agents
/// Handles both correct format (json_input as string) and LLM mistake (json_input as object)
pub fn parse_sub_agents(
    allocator: std.mem.Allocator,
    input_json: []const u8,
    max_agents: usize,
) !SubAgentsInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value;
    const root_obj = root.object;

    // Try to get sub_agents - either directly from root or from json_input field
    if (root_obj.get("sub_agents")) |_| {
        return parseSubAgentsFromValue(allocator, root_obj, max_agents);
    } else {
        // Check if json_input is present
        if (root_obj.get("json_input")) |json_input_val| {
            // Case 1: json_input is an object (LLM mistake) containing sub_agents
            if (json_input_val == .object) {
                return parseSubAgentsFromValue(allocator, json_input_val.object, max_agents);
            }
            // Case 2: json_input is a string (correct format) - parse it recursively
            if (json_input_val == .string) {
                // Recursively parse the string content
                return parse_sub_agents(allocator, json_input_val.string, max_agents);
            }
        }
        return error.MissingSubAgentsField;
    }
}

/// Parse sub_agents from an already-parsed object
fn parseSubAgentsFromValue(
    allocator: std.mem.Allocator,
    root_obj: std.json.ObjectMap,
    max_agents: usize,
) !SubAgentsInput {
    const agents_val = root_obj.get("sub_agents") orelse {
        return error.MissingSubAgentsField;
    };
    // Check if sub_agents is an array or a string (handle LLM mistakes)
    const agents_array: std.json.Array = if (agents_val == .array)
        agents_val.array
    else if (agents_val == .string)
        // Parse the string as JSON to get the actual array
        blk: {
            const parsed_str = try std.json.parseFromSlice(std.json.Value, allocator, agents_val.string, .{
                .ignore_unknown_fields = true,
            });
            defer parsed_str.deinit();
            if (parsed_str.value != .array) {
                return error.InvalidSubAgentsFormat;
            }
            break :blk parsed_str.value.array;
        } else return error.InvalidSubAgentsFormat;

    if (agents_array.items.len == 0) {
        return error.NoSubAgents;
    }
    if (agents_array.items.len > max_agents) {
        return error.TooManySubAgents;
    }

    var sub_agents_list = std.ArrayList(SubAgentInput).empty;
    errdefer {
        for (sub_agents_list.items) |sa| {
            allocator.free(sa.instruction);
            for (sa.tools) |t| allocator.free(t);
            allocator.free(sa.tools);
            allocator.free(sa.agent_name);
        }
        sub_agents_list.deinit(allocator);
    }

    for (agents_array.items) |agent_val| {
        const agent_obj = agent_val.object;
        const instr_val = agent_obj.get("instruction") orelse {
            return error.MissingSubAgentInstruction;
        };

        const instruction = try allocator.dupe(u8, instr_val.string);
        errdefer allocator.free(instruction);

        // Parse REQUIRED "tools" field — explicit allowlist, no omit, no
        // "all", no empty.
        const tools_val = agent_obj.get("tools") orelse {
            return error.MissingSubAgentTools;
        };
        if (tools_val != .array) {
            return error.InvalidSubAgentsFormat;
        }
        const tools_array = tools_val.array;
        if (tools_array.items.len == 0) {
            return error.EmptySubAgentTools;
        }
        var tools_list = std.ArrayList([]const u8).empty;
        errdefer {
            for (tools_list.items) |t| allocator.free(t);
            tools_list.deinit(allocator);
        }
        for (tools_array.items) |tool_val| {
            if (tool_val != .string or tool_val.string.len == 0) {
                return error.InvalidSubAgentsFormat;
            }
            const trimmed = std.mem.trim(u8, tool_val.string, " ");
            if (std.mem.eql(u8, trimmed, "all")) {
                return error.AllToolsNotAllowed;
            }
            // Main-agent-only tools are a hard parse error, NOT a silent
            // downstream strip.
            if (main_agent_only.isMainAgentOnly(trimmed)) {
                return error.MainAgentOnlyToolNotAllowed;
            }
            const tool_name = try allocator.dupe(u8, trimmed);
            errdefer allocator.free(tool_name);
            try tools_list.append(allocator, tool_name);
        }
        const tools = try tools_list.toOwnedSlice(allocator);
        errdefer {
            for (tools) |t| allocator.free(t);
            allocator.free(tools);
        }

        // Parse optional "timeout_seconds" field
        var timeout_seconds: ?u32 = null;
        if (agent_obj.get("timeout_seconds")) |timeout_val| {
            timeout_seconds = @intCast(timeout_val.integer);
        }

        // Parse optional "inherited_context" field
        var inherited_context: ?[]const u8 = null;
        errdefer if (inherited_context) |c| allocator.free(c);
        if (agent_obj.get("inherited_context")) |ctx_val| {
            if (ctx_val == .string) {
                // Validate the mode string at parse time so the LLM gets a clear
                // error for typo'd modes (e.g. "last:5x" instead of "last:5").
                // The raw string is still stored; the formatter re-parses it.
                _ = inherited_context_helper.parseMode(ctx_val.string) catch {
                    return error.InvalidInheritedContextMode;
                };
                inherited_context = try allocator.dupe(u8, ctx_val.string);
            }
        }

        // Parse required "agent_name" field — the name of a configured
        // agent, applied as an overlay on the orchestrator's defaults.
        const an_val = agent_obj.get("agent_name") orelse {
            return error.MissingSubAgentAgentName;
        };
        if (an_val != .string or an_val.string.len == 0) {
            return error.MissingSubAgentAgentName;
        }
        if (an_val.string.len > 256) {
            return error.AgentNameTooLong;
        }
        const agent_name = try allocator.dupe(u8, an_val.string);
        errdefer allocator.free(agent_name);

        try sub_agents_list.append(allocator, .{
            .instruction = instruction,
            .tools = tools,
            .timeout_seconds = timeout_seconds,
            .inherited_context = inherited_context,
            .agent_name = agent_name,
        });
    }

    return SubAgentsInput{
        .sub_agents = try sub_agents_list.toOwnedSlice(allocator),
    };
}

test {
    // Tests live in spawn_sub_agent_test.zig.
}


test "parse_sub_agents - inherited_context 'last:3' is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file"],"inherited_context":"last:3"}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expect(parsed.sub_agents[0].inherited_context != null);
    try std.testing.expectEqualStrings("last:3", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - omitted inherited_context is null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file"]}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].inherited_context == null);
}

test "parse_sub_agents - inherited_context 'none' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","tools":["read_file"],"inherited_context":"none"}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("none", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context 'all' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","tools":["read_file"],"inherited_context":"all"}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("all", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","tools":["read_file"],"inherited_context":"last:5"}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator will assert.
    // No explicit expect — if it leaks, testing.allocator fails the test on deinit.
}

test "parse_sub_agents - invalid inherited_context mode returns InvalidInheritedContextMode" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","tools":["read_file"],"inherited_context":"last:5x"}]}
    ;
    try std.testing.expectError(error.InvalidInheritedContextMode, parse_sub_agents(alloc, input_json, 20));
}

// -------------------------------------------------------------------------
// parse_sub_agents — agent_name (REQUIRED, label + config-driven selection)
// -------------------------------------------------------------------------

test "parse_sub_agents - agent_name is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x","tools":["read_file"]}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expectEqualStrings("code-reviewer", parsed.sub_agents[0].agent_name);
}

test "parse_sub_agents - missing agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"instruction":"do x","tools":["read_file"]}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - empty string agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"","instruction":"do x","tools":["read_file"]}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name too long (>256 chars) returns AgentNameTooLong" {
    const alloc = std.testing.allocator;
    // 300-char agent_name value
    var long_name_buf: [310]u8 = undefined;
    @memset(&long_name_buf, 'x');
    const long_name = long_name_buf[0..300];

    var input_buf: [512]u8 = undefined;
    const prefix = "{\"sub_agents\":[{\"agent_name\":\"";
    @memcpy(input_buf[0..prefix.len], prefix);
    @memcpy(input_buf[prefix.len..][0..long_name.len], long_name);
    const suffix = "\",\"instruction\":\"do x\",\"tools\":[\"read_file\"]}]}";
    @memcpy(input_buf[prefix.len + long_name.len ..][0..suffix.len], suffix);
    const input_json = input_buf[0 .. prefix.len + long_name.len + suffix.len];

    try std.testing.expectError(error.AgentNameTooLong, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x","tools":["read_file"]}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator fails on deinit if it does.
}

test "parse_sub_agents - multiple sub_agents each carry their own agent_name" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[
        \\  {"agent_name":"reviewer","instruction":"x","tools":["read_file"]},
        \\  {"agent_name":"explorer","instruction":"x","tools":["glob"]},
        \\  {"agent_name":"writer","instruction":"x","tools":["read_file","write_file"]}
        \\]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.sub_agents.len);
    try std.testing.expectEqualStrings("reviewer", parsed.sub_agents[0].agent_name);
    try std.testing.expectEqualStrings("explorer", parsed.sub_agents[1].agent_name);
    try std.testing.expectEqualStrings("writer", parsed.sub_agents[2].agent_name);
}

// -------------------------------------------------------------------------
// parse_sub_agents — tools (REQUIRED, explicit allowlist, no "all")
// -------------------------------------------------------------------------

test "parse_sub_agents - missing tools returns MissingSubAgentTools" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x"}]}
    ;
    try std.testing.expectError(error.MissingSubAgentTools, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - empty tools array returns EmptySubAgentTools" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":[]}]}
    ;
    try std.testing.expectError(error.EmptySubAgentTools, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - tools containing all returns AllToolsNotAllowed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["all"]}]}
    ;
    try std.testing.expectError(error.AllToolsNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - tools containing all among others returns AllToolsNotAllowed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file","all"]}]}
    ;
    try std.testing.expectError(error.AllToolsNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - explicit tools are parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file","glob"]}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), parsed.sub_agents[0].tools.len);
    try std.testing.expectEqualStrings("read_file", parsed.sub_agents[0].tools[0]);
    try std.testing.expectEqualStrings("glob", parsed.sub_agents[0].tools[1]);
}

// -------------------------------------------------------------------------
// parse_sub_agents — main-agent-only tools (ask_user / spawn_sub_agent)
// ------------------------------------------------------------------------- A

test "parse_sub_agents - tools containing ask_user returns MainAgentOnlyToolNotAllowed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["ask_user"]}]}
    ;
    try std.testing.expectError(error.MainAgentOnlyToolNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - ask_user among otherwise-valid tools is still rejected" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["read_file","ask_user","glob"]}]}
    ;
    try std.testing.expectError(error.MainAgentOnlyToolNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - tools containing spawn_sub_agent returns MainAgentOnlyToolNotAllowed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":["spawn_sub_agent"]}]}
    ;
    try std.testing.expectError(error.MainAgentOnlyToolNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - the rejection covers every sub-agent in the batch" {
    const alloc = std.testing.allocator;
    // The FIRST sub-agent is clean; the SECOND asks for ask_user. The whole
    // call must fail (the batch is atomic) rather than spawning a half-set.
    const input_json =
        \\{"sub_agents":[
        \\  {"agent_name":"a","instruction":"x","tools":["read_file"]},
        \\  {"agent_name":"b","instruction":"x","tools":["ask_user"]}
        \\]}
    ;
    try std.testing.expectError(error.MainAgentOnlyToolNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - whitespace-padded ask_user is still rejected" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","tools":[" ask_user "]}]}
    ;
    try std.testing.expectError(error.MainAgentOnlyToolNotAllowed, parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - a normal read-only tool list still parses" {
    const alloc = std.testing.allocator;
    // The negative control: the new rejection must not catch innocent names.
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","tools":["list_agents","read_workspace_session","use_skill"]}]}
    ;
    var parsed = try parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.sub_agents[0].tools.len);
}

test "spawn_sub_agent description teaches the main-agent-only rule" {
    const desc = spawn_sub_agent_tool.function.description;
    try std.testing.expect(std.mem.indexOf(u8, desc, "MAIN-AGENT-ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "\"ask_user\" and \"spawn_sub_agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "rejected at parse time") != null);
    // And the json_input schema block lists it among the rejected shapes
    // (that text lives on the property, which is what the model reads as the
    // parameter documentation).
    const json_input_desc = spawn_sub_agent_tool.function.parameters.properties[0].description;
    try std.testing.expect(std.mem.indexOf(u8, json_input_desc, "main-agent-only") != null);
}

test "spawn_sub_agent system prompt teaches the main-agent-only rule" {
    const sp = spawn_sub_agent_tool_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, sp, "`ask_user` and `spawn_sub_agent` are main-agent-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "cannot reach the human") != null);
}

// -------------------------------------------------------------------------
// Tool description + system prompt — required-tools + worktree wording
// -------------------------------------------------------------------------

test "spawn_sub_agent description teaches REQUIRED explicit tools" {
    const desc = spawn_sub_agent_tool.function.description;
    try std.testing.expect(std.mem.indexOf(u8, desc, "REQUIRED, explicit allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "Missing, empty, or [\"all\"] is rejected") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "There is no omit-means-all") != null);
    // The old omit-means-all sentence must stay dead.
    try std.testing.expect(std.mem.indexOf(u8, desc, "Omit \"tools\" to give the sub-agent access to ALL") == null);
    // Unknown names are ignored (allowlistFilter), never an error.
    try std.testing.expect(std.mem.indexOf(u8, desc, "Unknown names are ignored") != null);
}

test "spawn_sub_agent description teaches explorer-shares writer-isolates" {
    const desc = spawn_sub_agent_tool.function.description;
    try std.testing.expect(std.mem.indexOf(u8, desc, "Explorer-code sub-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "NO new worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "set_git_worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "return a summary of changed files") != null);
}

test "spawn_sub_agent system prompt carries tools-required and worktree rules" {
    const sp = spawn_sub_agent_tool_system_prompt;
    try std.testing.expect(std.mem.indexOf(u8, sp, "`tools` (REQUIRED explicit allowlist") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "Explorer-code sub-agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "Writer sub-agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "set_git_worktree") != null);
}

// Exec adapter — merged from `spawn_sub_agent.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const exec_tools = @import("../../../agentic_loop/tools.zig");
const batch = @import("../../../agentic_loop/sub_agent_batch.zig");
const logger_mod = pabrikcore.loggermod;
const ai_workflow = @import("../../../agentic_loop/workflow.zig");
const subagent_progress = @import("../../../agentic_loop/subagent_progress.zig");
const sanitize = @import("helpers").sanitize_control_chars;
const ToolExecContext = exec_tools.ToolExecContext;
const ToolExecResult = exec_tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = exec_tools.wrapToolOutput;
pub const slugifySubAgentName = batch.slugifySubAgentName;

pub const ThreadResult = batch.ThreadResult;

/// The batch size this tool advertises in its schema and enforces at parse
/// time. The runner has its own `MaxBatch`; passing this keeps the tool's
/// public contract and the runner's ceiling identical.
const MaxBatch = 20;

pub fn execSpawnSubAgent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    ctx.logger.debugFmt("execSpawnSubAgent called, arguments len={}", .{tc.function.arguments.len});
    ctx.logger.debugFmt("arguments: '{s}'", .{tc.function.arguments[0..@min(tc.function.arguments.len, 200)]});

    // 2026-09-04 refresh fix: the snapshot registry (subagent_progress) is
    // the refresh-rehydrate source until the final envelope lands in the DB.
    errdefer subagent_progress.clearSnapshot(ctx.tool_call_id);

    const parsed = parse_sub_agents(ctx.allocator, tc.function.arguments, MaxBatch) catch |err| {
        ctx.logger.errFmt("parse_sub_agents failed: {}", .{err});
        // Propagate the SPECIFIC parse error (e.g.
        return err;
    };
    defer parsed.deinit(ctx.allocator);

    const sub_agent_count = parsed.sub_agents.len;
    ctx.logger.debugFmt("Parsed {} sub-agents", .{sub_agent_count});

    const jobs = try ctx.allocator.alloc(batch.BatchJob, sub_agent_count);
    defer ctx.allocator.free(jobs);
    for (parsed.sub_agents, 0..) |sub_agent, i| {
        ctx.logger.debugFmt("Sub-agent {}: agent_name='{s}', instruction_len={}", .{ i, sub_agent.agent_name, sub_agent.instruction.len });
        jobs[i] = .{
            .name = sub_agent.agent_name,
            .instruction = sub_agent.instruction,
            .tools = sub_agent.tools,
            .inherited_context = sub_agent.inherited_context orelse "",
            .overrides = resolveOverrides(ctx, sub_agent.agent_name),
        };
    }

    var outcome = batch.runBatch(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .parent_sess_id = ctx.session_id,
        .cwd = ctx.cwd,
        .environment = ctx.environment,
        .selected_profile_model = ctx.selected_profile_model,
        .tool_call_id = ctx.tool_call_id,
    }, jobs) catch |err| {
        ctx.logger.errFmt("sub-agent batch failed: {}", .{err});
        return err;
    };
    defer outcome.deinit();

    // The per-agent results below are serialized with
    // `std.json.Stringify.valueAlloc` (never string-concat) — no
    // intermediate writer buffer needed.
    const success_count = outcome.succeeded();

    // Build the result JSON object via `std.json.Stringify.valueAlloc` (never
    // string-concat).
    const JsonAgent = struct {
        name: []const u8,
        success: bool,
        random_fallback: bool,
        session_id: ?[]const u8,
        response: ?[]const u8,
        @"error": ?[]const u8,
    };
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| ctx.allocator.free(s);
        owned.deinit(ctx.allocator);
    }
    var agents = try ctx.allocator.alloc(JsonAgent, outcome.results.len);
    defer ctx.allocator.free(agents);
    for (outcome.results, 0..) |result, i| {
        // Sanitize free text so names/responses carrying control bytes
        // can't break the JSON payload (Stringify handles the rest).
        const name = try sanitize(ctx.allocator, result.name);
        try owned.append(ctx.allocator, name);
        const sid: ?[]u8 = if (result.session_id.len > 0)
            try sanitize(ctx.allocator, result.session_id)
        else
            null;
        if (sid) |s| try owned.append(ctx.allocator, s);
        var resp: ?[]u8 = null;
        var errmsg: ?[]u8 = null;
        if (result.success) {
            if (result.response) |r| {
                resp = try sanitize(ctx.allocator, r);
                try owned.append(ctx.allocator, resp.?);
            }
        } else if (result.error_message) |e| {
            errmsg = try sanitize(ctx.allocator, e);
            try owned.append(ctx.allocator, errmsg.?);
        } else {
            errmsg = try sanitize(ctx.allocator, "unknown error");
            try owned.append(ctx.allocator, errmsg.?);
        }
        agents[i] = .{
            .name = name,
            .success = result.success,
            .random_fallback = result.is_random_fallback,
            .session_id = sid,
            .response = resp,
            .@"error" = errmsg,
        };
    }
    const inner_owned = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .results = agents,
        .summary = .{
            .succeeded = success_count,
            .failed = sub_agent_count - success_count,
        },
    }, .{});
    const output = try wrapToolOutput(ctx.allocator, "spawn_sub_agent", tc.function.arguments, true, null, inner_owned);
    // 2026-09-04 refresh fix: the final results payload is built — the DB row
    // (written by handle_tool's updateAndSendToolResult right after we
    // return) takes over as the source of truth, so the snapshot has served
    subagent_progress.clearSnapshot(ctx.tool_call_id);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Resolve the spawned child's config overlay from the live LlmConfig.
/// `an` is the LLM-provided agent name.
fn resolveOverrides(ctx: ToolExecContext, an: []const u8) ai_workflow.SubAgentOverrides {
    const resolved = @constCast(ctx.config).resolveAgent(an);
    if (resolved.is_random_fallback) {
        ctx.logger.warnFmt("spawn_sub_agent: agent_name '{s}' not found among the configured agents; using random name '{s}' and orchestrator defaults", .{ an, resolved.name });
    } else {
        ctx.logger.infoFmt("spawn_sub_agent: agent_name '{s}' resolved (source='{s}', model='{s}')", .{ an, resolved.source, resolved.model });
    }
    return .{
        .resolved_name = resolved.name,
        .is_random_fallback = resolved.is_random_fallback,
        .model = resolved.model,
        .base_url = resolved.base_url,
        .api_key = resolved.api_key,
        .url_style = resolved.url_style,
        // Transport + its CLI knobs, threaded the same way — without these
        // a CLI sub-agent would inherit backend="http" and POST to an empty
        // base_url.
        .backend = resolved.backend,
        .config_dir = resolved.config_dir,
        .max_turns = resolved.max_turns,
        .opencode_agent = resolved.opencode_agent,
        .opencode_auto = resolved.opencode_auto,
        .is_thinking = resolved.is_thinking,
        .temperature = resolved.temperature,
        // Model-thinking knobs (plan 2026-08-23-model-thinking), threaded
        // from ResolvedAgent so the spawned sub-agent can override its
        // parent profile's thinking budget / reasoning effort without
        .thinking_budget_tokens = resolved.thinking_budget_tokens,
        .reasoning_effort = resolved.reasoning_effort,
        .system_prompt = resolved.system_prompt,
    };
}

const testing = std.testing;

test "slugifySubAgentName keeps URL-safe chars, space->underscore" {
    // 2026-09-04 subagent-peek P0: sid must be a single URL-safe path
    // segment. Would have failed before slugify existed (raw spaces
    // broke the HTTP request line, '/' broke router segment matching).
    const alloc = testing.allocator;
    const s1 = try slugifySubAgentName(alloc, "backend implementer");
    defer alloc.free(s1);
    try testing.expectEqualStrings("backend_implementer", s1);

    const s2 = try slugifySubAgentName(alloc, "code-reviewer");
    defer alloc.free(s2);
    try testing.expectEqualStrings("code-reviewer", s2);

    const s3 = try slugifySubAgentName(alloc, "a/b%c<d>e&f");
    defer alloc.free(s3);
    try testing.expectEqualStrings("abcdef", s3);

    const s4 = try slugifySubAgentName(alloc, "");
    defer alloc.free(s4);
    try testing.expectEqualStrings("agent", s4);

    const s5 = try slugifySubAgentName(alloc, "///");
    defer alloc.free(s5);
    try testing.expectEqualStrings("agent", s5);
}

