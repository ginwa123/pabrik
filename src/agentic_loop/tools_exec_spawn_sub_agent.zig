//! The `spawn_sub_agent` tool: the tool layer over the shared batch runner.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const batch = @import("sub_agent_batch.zig");

const logger_mod = pabrikcore.loggermod;
const ai_workflow = @import("workflow.zig");
const spawn_sub_agent_tool = pabrikcore.spawn_sub_agent;
const subagent_progress = @import("subagent_progress.zig");
const sanitize = @import("helpers").sanitize_control_chars;
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;

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

    const parsed = spawn_sub_agent_tool.parse_sub_agents(ctx.allocator, tc.function.arguments, MaxBatch) catch |err| {
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

/// Resolve one sub-agent's config overlay from the live LlmConfig.
/// `agent_name` is the LLM-provided name.
fn resolveOverrides(ctx: ToolExecContext, an: []const u8) ai_workflow.SubAgentOverrides {
    const resolved = @constCast(ctx.config).resolveSubAgent(ctx.selected_profile_model, an);
    if (resolved.is_random_fallback) {
        ctx.logger.warnFmt("spawn_sub_agent: agent_name '{s}' not found in LlmConfig.sub_agents; using random name '{s}' and orchestrator defaults", .{ an, resolved.name });
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
        // from ResolvedSubAgent so the spawned sub-agent can override its
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
