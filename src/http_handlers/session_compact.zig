const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;
const config = pabrikcore.config;
const tool_models = pabrikcore.tool_models;
const http_response = pabrikcore.http_response;
const workflow = pabrikcore.ai_mod.ai_workflow;
const compact_target = @import("../modules/agent/loop/session_compact_target.zig");
const compact_mod = @import("../modules/agent/loop/workflow_compact_message.zig");
const skill_evals_config = @import("../modules/agent/loop/skill_evals_config.zig");

/// Compact a session on demand: the same `maybeCompactMessagesNew` the agentic
/// loop calls, against the same target the loop would use.
pub fn sessionCompactHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };
    const di = try pabrikcore.getSingleton();

    const llm_config = compact_target.sessionConfig(allocator, di, di.db, session_id);
    const target = compact_target.resolve(allocator, llm_config, di.db, session_id) catch |err| switch (err) {
        error.UnknownSession => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unknown session" }) });
        },
        else => {
            di.logger.errFmt("[COMPACTION] resolve target failed for {s}: {s}", .{ session_id, @errorName(err) });
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "resolve target failed" }) });
        },
    };

    const tools = resolveSessionTools(allocator, di, llm_config, session_id) catch |err| {
        di.logger.errFmt("[COMPACTION] resolving tools failed for {s}: {s}", .{ session_id, @errorName(err) });
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "resolving tools failed" }) });
    };

    const outcome = compact_target.compactSession(
        compact_mod.defaultCompactDeps,
        allocator,
        target,
        session_id,
        tools,
        di.db,
        di.io,
        di.logger,
        di.event_bus,
    ) catch |err| {
        di.logger.errFmt("[COMPACTION] manual compaction failed for {s}: {s}", .{ session_id, @errorName(err) });
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "compaction failed" }) });
    };

    di.logger.infoFmt("[COMPACTION] manual compaction for {s}: compacted={}", .{ session_id, outcome.compacted });
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .success = true,
        .compacted = outcome.compacted,
        .message = outcome.message,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

/// The tool list the loop would hand `buildMessages` for this session: the
/// session's allowlist (Agent binding first, kanban second), the progressive
/// tools it has equipped, and the cached MCP tools.
fn resolveSessionTools(
    allocator: std.mem.Allocator,
    di: *pabrikcore.App,
    llm_config: *const config.LlmConfig,
    session_id: []const u8,
) ![]tool_models.AgentTool {
    var allowed_tools: []const u8 = "";
    if (!try workflow.maybeOverrideAllowedToolsForAgent(allocator, di.db, session_id, &allowed_tools)) {
        _ = try workflow.maybeOverrideAllowedToolsForKanban(allocator, di.db, session_id, &allowed_tools);
    }

    const progressive_rows = try llm_history.getProgressiveTools(allocator, di.db, session_id);
    const progressive_names = try allocator.alloc([]const u8, progressive_rows.len);
    for (progressive_rows, 0..) |row, i| progressive_names[i] = row.tool_name;

    return workflow.filterAndMergeTools(
        allocator,
        di.getMcpToolsCached(allocator),
        allowed_tools,
        false,
        progressive_names,
        (skill_evals_config.resolve(allocator, di.db, session_id) orelse llm_config.skill_evals).enabled,
    );
}
