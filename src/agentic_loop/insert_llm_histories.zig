const std = @import("std");
const pabrikcore = @import("pabrikcore");
const LLMHistory = @import("llm_history_row.zig").LLMHistory;
const SkillInfo = @import("session_skills.zig").SkillInfo;
const onEventSendLLMHistory = @import("sse_on_event_send_llm_history.zig").onEventSendLLMHistory;

const sqlite = pabrikcore.sqlite;
const logger_mod = pabrikcore.loggermod;
const agent = pabrikcore.agent;
const helpers = @import("helpers");
const event_bus_mod = pabrikcore.event_bus;
const keyword = "INSERTLLMHISTORIES";
const model_guard = @import("llm_history_model_guard.zig");
const parsing = @import("parsing.zig");

pub const InsertLLMHistoriesInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    is_emit_sse: bool,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    entity: LLMHistory,
    is_skip_db: bool = false,
    /// True when this insert is an agentic-loop diagnostic (retry attempt or
    /// TooManyRetries bail) — forwarded to the SSE payload so the frontend
    /// renders it in a dedicated AgentErrorCard.
    is_error: bool = false,
};

pub fn inserLLMHistories(
    obj: InsertLLMHistoriesInput,
) ![]const u8 {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;
    const io = obj.io;
    const event_bus = obj.event_bus;

    const input = obj.entity;
    const session_id = input.session_id;
    // Guard the model BEFORE it becomes a bind arg.
    const model = model_guard.resolve(input.model);
    const cwd = obj.cwd;
    const temperature = input.temperature;
    const is_thinking = input.is_thinking;
    const is_input = input.is_input;
    const is_output = input.is_output;
    const finish_reason = input.finish_reason;
    const reasoning_content = input.reasoning_content;

    // Sample the timestamp ONCE for both `id` and `created_at`.
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at);

    // Compute `created_iso` for the `since`/`until` filters. Mirrors the
    // conversion in `llm_history.saveMessage`.
    const created_iso = try helpers.currentTimeIsoLocal(allocator, io);
    defer allocator.free(created_iso);

    const contentStr = input.response_content;
    const finishReasonStr = input.finish_reason;
    const roleStr = input.role;
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent;

    // Option A envelopes: user rows always carry {user,name,msg}; non-empty
    // assistant text carries {model,msg} even when tool_calls_json is present
    // (screenshot case).
    var enveloped_owned: ?[]u8 = null;
    defer if (enveloped_owned) |e| allocator.free(e);
    var effective_content: []const u8 = contentStr;
    if (contentStr.len > 0 and !parsing.isChatEnvelope(allocator, contentStr)) {
        if (std.mem.eql(u8, roleStr, "user")) {
            // Logged-in identity when the session has an owner; legacy
            // defaults otherwise (auth off). Lookup failures never block
            // the insert.
            var ident = parsing.resolveChatUser(allocator, db, session_id) catch null;
            defer if (ident) |*ci| ci.deinit(allocator);
            const uid: []const u8 = if (ident) |*ci| ci.user_id else "";
            const nm: []const u8 = if (ident) |*ci| (if (ci.name.len > 0) ci.name else agentStr) else agentStr;
            enveloped_owned = try parsing.encodeUserContent(allocator, uid, nm, contentStr);
            effective_content = enveloped_owned.?;
        } else if (std.mem.eql(u8, roleStr, "assistant")) {
            // Profile name the user picked; raw model id when Default /
            // auth off / lookup fails.
            const profile_owned: ?[]u8 = parsing.resolveProfileName(allocator, db, session_id) catch null;
            defer if (profile_owned) |pr| allocator.free(pr);
            var label: []const u8 = model;
            if (profile_owned) |pr| {
                if (pr.len > 0) label = pr;
            }
            enveloped_owned = try parsing.encodeAssistantContent(allocator, label, contentStr);
            effective_content = enveloped_owned.?;
        }
    }

    const is_emit_sse = obj.is_emit_sse;
    const is_skip_db = obj.is_skip_db;

    // tool_calls_json holds ONLY the serialized tool_calls array (assistant
    // message wire format).
    const toolCallsOwned = input.tool_calls_json;

    const sql =
        \\INSERT INTO llm_history (
        \\    id,
        \\    session_id,
        \\    model,
        \\    response_content,
        \\    finish_reason,
        \\    role,
        \\    tool_calls_json,
        \\    tool_call_id,
        \\    reasoning_content,
        \\    reasoning_id,
        \\    reasoning_encrypted_content,
        \\    is_feed_to_llm,
        \\    agent,
        \\    loop_index,
        \\    temperature,
        \\    is_thinking,
        \\    created_at_nano,
        \\    created_iso,
        \\    parent_session_id,
        \\    parent_id,
        \\    prompt_tokens,
        \\    completion_tokens,
        \\    total_tokens,
        \\    cache_creation_input_tokens,
        \\    cache_read_input_tokens,
        \\    is_input,
        \\    is_output,
        \\    tool_name,
        \\    diffview_before,
        \\    diffview_after,
        \\    image_url,
        \\    video_url,
        \\    file_attachments,
        \\    file_attachments_meta
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?
        \\)
    ;

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    defer allocator.free(copy_session_id);
    const copy_model = try allocator.dupe(u8, input.model);
    defer allocator.free(copy_model);
    const copy_content = try allocator.dupe(u8, effective_content);
    defer allocator.free(copy_content);
    // Wire compat: SSE + HTTP carry plain `.msg` so current frontend bubbles
    // keep rendering. DB keeps the envelope; unwrap here for the live event.
    const sse_content_owned = try parsing.unwrapChatContent(allocator, effective_content);
    defer allocator.free(sse_content_owned);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    defer allocator.free(copy_finish_reason);
    const copy_role = try allocator.dupe(u8, roleStr);
    defer allocator.free(copy_role);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsOwned);
    defer allocator.free(copy_tool_calls);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    defer allocator.free(copy_reasoning);
    const copy_reasoning_id = try allocator.dupe(u8, input.reasoning_id orelse "");
    defer allocator.free(copy_reasoning_id);
    const copy_reasoning_encrypted_content = try allocator.dupe(u8, input.reasoning_encrypted_content orelse "");
    defer allocator.free(copy_reasoning_encrypted_content);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    defer allocator.free(copy_parent_session_id);
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    defer allocator.free(copy_parent_id);
    const copy_tool_name = try allocator.dupe(u8, input.tool_name);
    defer allocator.free(copy_tool_name);
    const copy_tool_call_id = try allocator.dupe(u8, input.tool_call_id orelse "");
    defer allocator.free(copy_tool_call_id);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);
    const cache_creation_input_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_creation_input_tokens});
    defer allocator.free(cache_creation_input_tokens_str);
    const cache_read_input_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.cache_read_input_tokens});
    defer allocator.free(cache_read_input_tokens_str);
    const copy_diffview_before = try allocator.dupe(u8, input.diffview_before orelse "");
    defer allocator.free(copy_diffview_before);
    const copy_diffview_after = try allocator.dupe(u8, input.diffview_after orelse "");
    defer allocator.free(copy_diffview_after);

    const copy_is_feed_to_llm = try allocator.dupe(u8, if (input.is_feed_to_llm) "1" else "0");
    defer allocator.free(copy_is_feed_to_llm);

    // Join multiple image URLs with || delimiter
    var image_urls_str: []const u8 = "";
    var copy_image_urls: ?[]u8 = null;
    if (input.image_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_image_urls = try allocator.dupe(u8, combined.items);
            image_urls_str = copy_image_urls.?;
        }
    }
    defer if (copy_image_urls) |c| allocator.free(c);

    // Join multiple video URLs with || delimiter
    var video_urls_str: []const u8 = "";
    var copy_video_urls: ?[]u8 = null;
    if (input.video_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_video_urls = try allocator.dupe(u8, combined.items);
            video_urls_str = copy_video_urls.?;
        }
    }
    defer if (copy_video_urls) |c| allocator.free(c);

    const file_attachments_str = input.file_attachments orelse "";
    const file_attachments_meta_str = input.file_attachments_meta orelse "";

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_reasoning_id, copy_reasoning_encrypted_content, copy_is_feed_to_llm, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, created_iso, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, cache_creation_input_tokens_str, cache_read_input_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str, video_urls_str, file_attachments_str, file_attachments_meta_str };

    if (!is_skip_db) {
        try db.exec(allocator, sql, sqlArgs);

        // Update the session's cwd in the sessions table
        const copy_cwd = try allocator.dupe(u8, cwd);
        defer allocator.free(copy_cwd);
        try db.exec(allocator, "UPDATE sessions SET cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", &.{ copy_cwd, copy_session_id });
    }

    if (is_emit_sse) {
        if (event_bus) |ev| {
            const session_skills = try getSessionSkills(allocator, db, copy_session_id);

            _ = onEventSendLLMHistory(.{ .allocator = allocator, .io = io, .logger = logger, .event_bus = ev, .entity = .{
                .id = id,
                .session_id = session_id,
                .model = model,
                .cwd = cwd,
                .content = sse_content_owned,
                .reasoning_content = reasoning_content,
                .role = copy_role,
                .finish_reason = finish_reason,
                .tool_calls_json = copy_tool_calls,
                .tool_call_id = copy_tool_call_id,
                .agent_name = copy_agent,
                .loop_index = input.loop_index,
                .temperature = temperature,
                .is_thinking = is_thinking,
                .parent_id = session_id,
                .parent_session_id = session_id,
                .is_input = is_input,
                .is_output = is_output,
                .image_url = copy_image_urls,
                .video_url = copy_video_urls,
                .file_attachments = file_attachments_meta_str,
                .session_skills = session_skills,
                .tool_name = copy_tool_name,
                .total_tokens = input.total_tokens,
                .diffview_before = copy_diffview_before,
                .diffview_after = copy_diffview_after,
                .is_error = obj.is_error,
            } }) catch |on_event_sent_err| {
                logger.?.errFmt("[{s}] failed to sent llm historry: {s}\n", .{ keyword, @errorName(on_event_sent_err) });
            };
        }
    }

    return allocator.dupe(u8, id);
}

/// Get all skills loaded for a session
fn getSessionSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]SkillInfo {
    if (session_id.len == 0) return &.{};

    const sql = "SELECT skill_name, content, loaded_at_nano AS loaded_at FROM session_skills WHERE session_id = ?";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    var skills = std.ArrayList(SkillInfo).empty;
    errdefer {
        for (skills.items) |*s| s.deinit(allocator);
        skills.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const skill_name = row.values[0];
        const content = row.values[1];
        const loaded_at = if (row.values[2].len > 0) std.fmt.parseInt(i64, row.values[2], 10) catch null else null;

        try skills.append(allocator, .{
            .skill_name = try allocator.dupe(u8, skill_name),
            .content = try allocator.dupe(u8, content),
            .loaded_at = loaded_at,
        });
        row.deinit(allocator);
    }

    return try skills.toOwnedSlice(allocator);
}

fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return aw.toOwnedSlice();
}
