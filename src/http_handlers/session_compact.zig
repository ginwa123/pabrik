const std = @import("std");
const pabrikcore = @import("pabrikcore");
const session_llm_config = @import("../agentic_loop/session_llm_config.zig");
const gserverz = pabrikcore.gserverz;
const llm_history = pabrikcore.llm_history;
const config = pabrikcore.config;
const agent = pabrikcore.agent;
const tool_models = pabrikcore.tool_models;
const http_response = pabrikcore.http_response;
const workflow = pabrikcore.ai_mod.ai_workflow;
const buildMessages = @import("../agentic_loop/prompts_build_messages_for_agent_prompt.zig").buildMessages;


/// Trigger session compaction directly (synchronous - blocks until done)
/// Path param: session_id
/// Returns JSON with result
pub fn sessionCompactHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;
    const logger = di.logger;

    // Recover the working directory from the session row. A missing row is
    // non-fatal — fall back to "." so the compact agent can still attempt a
    // compaction.
    const cwd = blk: {
        const session_row_opt = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
        if (session_row_opt) |session| {
            if (session.cwd.len > 0) {
                break :blk try allocator.dupe(u8, session.cwd);
            }
        }
        break :blk try allocator.dupe(u8, ".");
    };

    // Pull the LLM credentials from the session's config (read-only
    // borrows): the session OWNER's stored config under `--auth`, the
    // process-global one otherwise (`session_llm_config.zig`).
    const live_cfg = session_llm_config.forSession(allocator, di.db, session_id) orelse
        pabrikcore.getLlmConfig(di);
    const api_key = live_cfg.api_key;
    const model = live_cfg.model;
    const base_url = live_cfg.base_url;
    // url_style must be propagated to `maybeCompactMessagesNew` so the
    // CompactionAgent sends the SAME wire format as the calling session —
    // otherwise an `url_style: "anthropic"` profile sends an OpenAI-shaped
    const url_style = live_cfg.url_style;

    // 2026-08-21-fix-ui-context-window — resolve the session's selected
    // profile so the compaction decision honors the profile's
    // `max_capacity_tokens` / `compaction_threshold_percent` overrides,
    const compact_profile: ?config.LlmConfig.LlmProfile = blk: {
        const profile_name = llm_history.getSessionProfileName(allocator, sqlite_db, session_id) catch "";
        break :blk llm_history.resolveSessionProfile(live_cfg, profile_name);
    };

    // Load the DB-stored message history and turn it into the in-memory
    // agent-message form that the compact agent operates on.
    const db_messages = llm_history.getMessages(allocator, sqlite_db, session_id) catch |err| {
        logger.errFmt("[COMPACTION] getMessages failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "getMessages failed" }) });
    };

    var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;

    const merged_tools: []tool_models.AgentTool = &.{};
    const initialMessages = buildMessages(allocator, io, sqlite_db, cwd, session_id, "", db_messages, merged_tools, "") catch |err| {
        logger.errFmt("[COMPACTION] buildMessages failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages failed" }) });
    };
    try messagesLists.appendSlice(allocator, initialMessages);

    // Compute the max total_tokens across the loaded messages.
    var total_tokens: u32 = 0;
    for (db_messages) |msg| {
        if (msg.total_tokens > total_tokens) total_tokens = msg.total_tokens;
    }

    // Manual endpoint: force compaction regardless of the auto-threshold.
    messagesLists = workflow.maybeCompactMessagesNew(
        workflow.defaultCompactDeps,
        allocator,
        total_tokens,
        model,
        true,
        messagesLists,
        api_key,
        base_url,
        url_style,
        cwd,
        session_id,
        sqlite_db,
        io,
        logger,
        // Manual endpoint — pass the singleton's event_bus when one is
        // reachable; the DB write happens regardless, and `null` would just
        // skip the SSE fanout to subscribers of this manual compact action.
        di.event_bus,
        live_cfg,
        if (compact_profile) |*p| p else null,
    ) catch |err| {
        logger.errFmt("[COMPACTION] manual compaction failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "compaction failed" }) });
    };

    logger.infoFmt("[COMPACTION] manual compaction completed for session {s}", .{session_id});
    const success_data = try std.json.Stringify.valueAlloc(allocator, .{ .success = true, .message = "Compaction completed" }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = success_data });
}



fn useCase() !void {

}
