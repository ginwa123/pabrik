const std = @import("std");
const tree1_mod = @import("pabrikcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;
const loggermod = @import("pabrikcore").loggermod;
const models = @import("models.zig");
const gserverz = tree1_mod.gserverz;
const llm_history = @import("llm_history.zig");
const helpers = @import("helpers");

// ============================================================================
// Session-to-Client ID mapping for SSE event bus integration
// ============================================================================

// ============================================================================
// JSON Protocol Constants
// ============================================================================

// ============================================================================
// Unified Response Types
// ============================================================================

/// Input parameters for sending SSE events
/// Used by TUI workflow to broadcast messages to connected clients
pub const OnEventInputLLMHistory = struct {
    id: ?[]const u8 = null,
    index: usize = 0,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls_json: ?[]agent.ToolCall,
    tool_call_id: ?[]const u8,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    total_tokens: ?u32 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    session_skills: ?[]const llm_history.SkillInfo = null,
};

/// JSON event payload structure for SSE
pub const SseEventLLMHistory = struct {
    id: ?[]const u8 = null,
    index: ?usize = null,
    content: []const u8,
    type: []const u8 = "full",
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    reasoning_content: ?[]const u8 = null,
    role: []const u8 = "assistant",
    finish_reason: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool,
    is_output: bool,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    total_tokens: ?u32 = null,
    diffview_before: ?[]const u8 = null,
    diffview_after: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    session_skills: ?[]const SkillInfo = null,
};

/// Skill info for SSE payload
pub const SkillInfo = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded_at: ?i64 = null,
};

/// JSON representation of a tool call 2026-08-24 wire-shape fix: no longer
/// used by the SSE payload (tool_calls_json is now serialized to a string via
/// llm_history.serializeToolCalls before std.json.fmt).
pub const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Input parameters for sending SSE session events Reflects the sessions
/// table columns: id, name, status, cwd, created_at, updated_at,
/// selected_profile_model, git_worktree_cwd, pr_url, pr_provider,
pub const OnEventInputSessions = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    selected_profile_model: []const u8 = "",
    git_worktree_cwd: []const u8 = "",
    /// Migration 086 — attached PR URL / effective provider. Empty
    /// defaults keep older callers compiling (same rationale as 063).
    pr_url: []const u8 = "",
    pr_provider: []const u8 = "",
    /// Migration 063 — opt-in flag for unattended mode. Empty default =
    /// "off" (matches the production SQL default of `'0'` via COALESCE).
    is_auto_retry_until_stop: []const u8 = "",
    /// Migration 063 — most recent finish_reason observed by the workflow.
    last_finish_reason: []const u8 = "",
    /// Migration 082 - unix-ms of the last human touch, surfaced on the SSE
    /// session_updated/created events so the ChatsList badge and stale-dot
    /// update without a refetch.
    last_human_touched_at: []const u8 = "",
};

/// JSON event payload for SSE session events
pub const SseEventSessionsPayload = struct {
    action: []const u8,
    session_id: ?[]const u8 = null,
};

pub const SseEvent = struct {
    session_id: []const u8,
    data: []const u8,
    event_type: ?[]const u8 = null,
};

/// Input parameters for sending SSE worker events
/// Reflects the worker table columns: id, session_id, working_directory, last_activity, last_activity_description, created_at
pub const OnEventInputWorkers = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    last_activity: i64,
    last_activity_description: []const u8,
    created_at: []const u8,
};

/// Send worker events to all subscribed clients via SSE Broadcasts worker
/// list updates (created, updated, deleted) SSE event name (the value of
/// `event:` in the wire format): - workers: worker_created | worker_updated |
pub fn onEventSendWorkers(allocator: std.mem.Allocator, input: OnEventInputWorkers) !void {
    const di = try tree1_mod.getSingleton();
    const event_bus = di.event_bus;

    // Build the payload with action and all worker columns
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = input.action,
        .id = input.id,
        .session_id = input.session_id,
        .working_directory = input.working_directory,
        .last_activity = input.last_activity,
        .last_activity_description = input.last_activity_description,
        .created_at = input.created_at,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    // Granular event name drives the SSE wire format `event:` line — the
    // frontend's EventSource dispatches each named event to its registered
    // listener without any JSON parsing (see project memory
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "worker_created"
    else if (std.mem.eql(u8, input.action, "updated"))
        "worker_updated"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "worker_deleted"
    else
        "worker_unknown"; // future-proofing for new actions

    // Use "workers" as routing key for worker events
    const event = SseEvent{
        .session_id = "workers",
        .data = data_copy,
        .event_type = event_type_name,
    };

    event_bus.emit(SseEvent, "workers", event);
}

/// Send an SSE event to all clients connected to the given session JSON
/// Protocol: - Response events contain all message fields as JSON object -
/// Tool result events include tool_call_id and tool_name SSE event name (the
pub fn onEventSendLLMHistory(allocator: std.mem.Allocator, input: OnEventInputLLMHistory) !void {

    // todo dirty code
    const di = try tree1_mod.getSingleton();
    const event_bus = di.event_bus;

    const log = loggermod.getGlobal();
    const session_id = input.session_id;

    // Trace: log what content we're receiving
    if (input.content) |c| {
        // Truncate content for logging if too long (>500 chars)
        const truncated_content = if (c.len > 500) c[0..500] else c;
        const suffix = if (c.len > 500) "... [truncated]" else "";
        log.?.infoFmt("on_event_send_new[{s}]: content=\"{s}{s}\", len={d}, is_thinking={}, role={s}", .{ session_id,
            truncated_content,
            suffix,
            c.len,
            input.is_thinking,
            input.role orelse "assistant",
        });
    } else {
        log.?.warnFmt("on_event_send_new[{s}]: NO CONTENT!", .{session_id});
    }

    // Sanitize content + reasoning_content to valid UTF-8 before JSON
    // serialization.
    const sanitized_content: ?[]u8 = blk: {
        const c = input.content orelse break :blk null;
        break :blk try helpers.sanitize.sanitizeUtf8(allocator, c);
    };
    defer if (sanitized_content) |s| allocator.free(s);

    const sanitized_reasoning: ?[]u8 = blk: {
        const r = input.reasoning_content orelse break :blk null;
        break :blk try helpers.sanitize.sanitizeUtf8(allocator, r);
    };
    defer if (sanitized_reasoning) |s| allocator.free(s);

    // 2026-08-24 wire-shape fix (task_1787590621966_10): tool_calls_json MUST
    // be a JSON STRING on the wire, not an array.
    const serialized_tool_calls_json: ?[]u8 = blk: {
        const calls = input.tool_calls_json orelse break :blk null;
        break :blk try llm_history.serializeToolCalls(allocator, calls);
    };
    defer if (serialized_tool_calls_json) |s| allocator.free(s);

    // Convert llm_history.SkillInfo to local SkillInfo for SSE payload
    var session_skills_json: ?[]const SkillInfo = null;
    var session_skills_owned: std.ArrayList(SkillInfo) = .empty;
    defer if (session_skills_json == null) session_skills_owned.deinit(allocator);

    if (input.session_skills) |skills| {
        for (skills) |skill| {
            try session_skills_owned.append(allocator, .{
                .skill_name = skill.skill_name,
                .content = skill.content,
                .loaded_at = skill.loaded_at,
            });
        }
        session_skills_json = try session_skills_owned.toOwnedSlice(allocator);
    }

    const payload = SseEventLLMHistory{
        .id = input.id,
        .index = input.index,
        .content = if (sanitized_content) |s| s else (input.content orelse ""),
        .session_id = input.session_id,
        .model = input.model,
        .cwd = input.cwd,
        .reasoning_content = if (sanitized_reasoning) |s| s else input.reasoning_content,
        .role = input.role orelse "assistant",
        .finish_reason = input.finish_reason,
        .tool_calls_json = serialized_tool_calls_json,
        .tool_call_id = input.tool_call_id,
        .tool_name = input.tool_name,
        .agent_name = input.agent_name,
        .loop_index = input.loop_index,
        .temperature = input.temperature,
        .is_thinking = input.is_thinking,
        .is_input = input.is_input,
        .is_output = input.is_output,
        .parent_session_id = input.parent_session_id,
        .parent_id = input.parent_id,
        .total_tokens = input.total_tokens,
        .diffview_before = input.diffview_before,
        .diffview_after = input.diffview_after,
        .image_url = input.image_url,
        .session_skills = session_skills_json,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Use std.json.fmt with format writer
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    const event = SseEvent{
        .session_id = input.session_id,
        .data = data_copy,
        .event_type = "llm_full",
    };
    // Per-session emit (kept for any future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, input.session_id, event);
    // Central broadcast: subscribers to bare "llm" receive ALL sessions'
    // LLM events. The frontend listener filter narrows to the current
    // session_id on the JS side.
    event_bus.emit(SseEvent, "llm", event);
}

/// Send session events to all subscribed clients via SSE Broadcasts session
/// list updates (created, updated, deleted, list actions) SSE event name (the
/// value of `event:` in the wire format): - sessions: session_created |
pub fn onEventSendSessions(allocator: std.mem.Allocator, input: OnEventInputSessions) !void {
    if (std.mem.indexOf(u8, input.id, "subagent")) |_| {
        return;
    }

    const di = try tree1_mod.getSingleton();
    const event_bus = di.event_bus;

    // Build the payload with action and all session columns
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const payload = .{
        .action = input.action,
        .id = input.id,
        .name = input.name,
        .status = input.status,
        .cwd = input.cwd,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .selected_profile_model = input.selected_profile_model,
        // Migration 063 — propagate the new columns via SSE so the
        // ChatsList badge updates without a refetch.
        .git_worktree_cwd = input.git_worktree_cwd,
        .pr_url = input.pr_url,
        .pr_provider = input.pr_provider,
        .is_auto_retry_until_stop = input.is_auto_retry_until_stop,
        .last_finish_reason = input.last_finish_reason,
        // Migration 082 - propagate the chat-side stamp so the SSE
        // session_updated event drives the sidebar's time pill + stale-dot
        // without a refetch.
        .last_human_touched_at = input.last_human_touched_at,
    };
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // Duplicate the data so event owns its own copy (buf will be deallocated below)
    const data_copy = try allocator.dupe(u8, buf.items);

    // Granular event name drives the SSE wire format `event:` line.
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "created"))
        "session_created"
    else if (std.mem.eql(u8, input.action, "updated"))
        "session_updated"
    else if (std.mem.eql(u8, input.action, "deleted"))
        "session_deleted"
    else
        "session_unknown"; // future-proofing for new actions

    // Use actual session_id as routing key and in event
    const event = SseEvent{
        .session_id = input.id,
        .data = data_copy,
        .event_type = event_type_name,
    };

    event_bus.emit(SseEvent, "sessions", event);
}

// ============================================================================
// Structured Chunk Types for Streaming
// ============================================================================

/// Structured representation of a content chunk
pub const ContentChunk = struct {
    index: usize,
    content: []const u8,
    /// Session this chunk belongs to.
    session_id: []const u8 = "",
};

/// Structured representation of a reasoning chunk
pub const ReasoningChunk = struct {
    index: usize,
    reasoning: []const u8,
    /// See ContentChunk.session_id — required for the frontend gate.
    session_id: []const u8 = "",
};

/// Structured representation of usage information
pub const ChunkUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Structured representation of a final chunk with usage
pub const FinalChunk = struct {
    index: usize,
    usage: ?ChunkUsage,
    /// See ContentChunk.session_id — required for the frontend gate.
    session_id: []const u8 = "",
};

/// Structured representation of a tool call delta
pub const ToolCallDeltaChunk = struct {
    index: usize,
    deltas: []const agent.ToolCallDelta,
    /// See ContentChunk.session_id — required for the frontend gate.
    session_id: []const u8 = "",
};

// ============================================================================
// Structured Serialization Functions (JSON)
// ============================================================================

/// JSON structure for content chunk
const ContentChunkJson = struct {
    index: usize,
    content: []const u8,
    type: []const u8 = "chunk",
    session_id: []const u8 = "",
};

/// JSON structure for reasoning chunk
const ReasoningChunkJson = struct {
    index: usize,
    reasoning_content: []const u8,
    type: []const u8 = "chunk",
    session_id: []const u8 = "",
};

/// JSON structure for final chunk with usage
const FinalChunkJson = struct {
    index: usize,
    type: []const u8 = "chunk_final",
    finish_reason: []const u8 = "stop",
    usage: ?ChunkUsage = null,
    session_id: []const u8 = "",
};

/// JSON structure for tool call delta chunk
const ToolCallDeltaChunkJson = struct {
    index: usize,
    type: []const u8 = "tool_call_delta",
    deltas: []const agent.ToolCallDelta,
    session_id: []const u8 = "",
};

/// Serialize a content chunk to JSON format
pub fn serializeContentChunk(allocator: std.mem.Allocator, chunk: ContentChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ContentChunkJson{
        .index = chunk.index,
        .content = chunk.content,
        .session_id = chunk.session_id,
    };

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a reasoning chunk to JSON format
pub fn serializeReasoningChunk(allocator: std.mem.Allocator, chunk: ReasoningChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ReasoningChunkJson{
        .index = chunk.index,
        .reasoning_content = chunk.reasoning,
        .session_id = chunk.session_id,
    };

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize a final chunk with usage information
pub fn serializeFinalChunk(allocator: std.mem.Allocator, chunk: FinalChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = FinalChunkJson{
        .index = chunk.index,
        .usage = chunk.usage,
        .session_id = chunk.session_id,
    };

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
    })});

    return try buf.toOwnedSlice(allocator);
}

/// Serialize tool call deltas to JSON format
pub fn serializeToolCallDeltas(allocator: std.mem.Allocator, chunk: ToolCallDeltaChunk) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const json_chunk = ToolCallDeltaChunkJson{
        .index = chunk.index,
        .deltas = chunk.deltas,
        .session_id = chunk.session_id,
    };

    try buf.print(allocator, "{f}", .{std.json.fmt(json_chunk, .{
        .whitespace = .indent_4,
    })});

    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// Streaming helpers (using event_bus for SSE)

// ============================================================================

/// Send content chunk during streaming response SSE event name (the value of
/// `event:` in the wire format): - llm: llm_chunk
pub fn sendStreamChunkContent(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ContentChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeContentChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
        .event_type = "llm_chunk",
    };
    // Per-session emit (kept for future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, session_id, event);
    // Central broadcast on "llm" — required for the single global
    // EventSource pattern (the frontend listener filters by
    // session_id on the JS side).
    event_bus.emit(SseEvent, "llm", event);
}

/// Send reasoning chunk during streaming response SSE event name (the value
/// of `event:` in the wire format): - llm: llm_chunk
pub fn sendStreamChunkReasoning(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ReasoningChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeReasoningChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
        .event_type = "llm_chunk",
    };
    // Per-session emit (kept for future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, session_id, event);
    // Central broadcast on "llm" — required for the single global
    // EventSource pattern (the frontend listener filters by
    // session_id on the JS side).
    event_bus.emit(SseEvent, "llm", event);
}

/// Send final chunk with usage information during streaming SSE event name
/// (the value of `event:` in the wire format): - llm: llm_chunk
pub fn sendStreamChunkFinal(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: FinalChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeFinalChunk(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
        .event_type = "llm_chunk",
    };
    // Per-session emit (kept for future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, session_id, event);
    // Central broadcast on "llm" — required for the single global
    // EventSource pattern (the frontend listener filters by
    // session_id on the JS side).
    event_bus.emit(SseEvent, "llm", event);
}

/// Send tool call delta chunk during streaming response SSE event name (the
/// value of `event:` in the wire format): - llm: llm_chunk
pub fn sendStreamToolCallDelta(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    chunk: ToolCallDeltaChunk,
) void {
    const di = tree1_mod.getSingleton() catch return;
    const event_bus = di.event_bus;

    const data = serializeToolCallDeltas(allocator, chunk) catch return;
    defer allocator.free(data);

    const event = SseEvent{
        .session_id = session_id,
        .data = data,
        .event_type = "llm_chunk",
    };
    // Per-session emit (kept for future server-side fan-out that
    // needs only this session's events).
    event_bus.emit(SseEvent, session_id, event);
    // Central broadcast on "llm" — required for the single global
    // EventSource pattern (the frontend listener filters by
    // session_id on the JS side).
    event_bus.emit(SseEvent, "llm", event);
}

// ─── Inline tests (formerly on_event_sent_sanitize_test.zig) ──────────────
// Regression test for the "bash tool returns corrupt value" bug where tool
// result content containing invalid UTF-8 bytes (e.g. \x89, \x93 from a test

const testing_oes = std.testing;
const pabrikcore_oes = tree1_mod;

test "sanitizeUtf8 fixes the exact bytes from the bug" {
    const corrupt_bytes = [_]u8{
        0x33, 0x0a, 0x5e, 0x57, 0x5e, 0x43, 0x5e, 0x43, 0x5e, 0x44,
        0x79, 0x7c, 0x3b,
        0x89, // INVALID UTF-8 (continuation byte without start)
        0x2b,
        0x93, // INVALID UTF-8 (continuation byte without start)
        0x5e, 0x59, 0x49, 0x22, 0x73, 0x0a,
    };

    try testing_oes.expect(!std.unicode.utf8ValidateSlice(&corrupt_bytes));

    const sanitize = @import("helpers").sanitize;
    const sanitized = try sanitize.sanitizeUtf8(testing_oes.allocator, &corrupt_bytes);
    defer testing_oes.allocator.free(sanitized);

    try testing_oes.expect(std.unicode.utf8ValidateSlice(sanitized));
    try testing_oes.expect(std.mem.indexOf(u8, sanitized, &[_]u8{ 0xEF, 0xBF, 0xBD }) != null);
}

test "SseEventLLMHistory with sanitized UTF-8 emits content as JSON string" {
    const payload = SseEventLLMHistory{
        .content = "<total>3</total><stdout>hello</stdout>",
        .session_id = "s1",
        .model = "m1",
        .cwd = "/cwd",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = false,
        .is_output = true,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing_oes.allocator);
    try buf.print(testing_oes.allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    const json = buf.items;
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"content\":\"<total>3</total><stdout>hello</stdout>\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"content\":[") == null);
}

test "SseEventLLMHistory with INVALID UTF-8 emits content as byte ARRAY (demonstrates the bug)" {
    const invalid_content = [_]u8{ '<', 't', 'a', 'g', '>', 0x89, '<', '/', 't', 'a', 'g', '>' };
    const payload = SseEventLLMHistory{
        .content = &invalid_content,
        .session_id = "s1",
        .model = "m1",
        .cwd = "/cwd",
        .loop_index = 0,
        .temperature = 0.0,
        .is_thinking = false,
        .is_input = false,
        .is_output = true,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing_oes.allocator);
    try buf.print(testing_oes.allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    const json = buf.items;
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"content\":[") != null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"content\":\"<tag>") == null);
}

test "SseEventLLMHistory emits is_input/is_output as JSON booleans" {
    const payload = SseEventLLMHistory{
        .content = "hi",
        .session_id = "s1",
        .model = "m1",
        .cwd = "/cwd",
        .loop_index = 0,
        .temperature = 0.2,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing_oes.allocator);
    try buf.print(testing_oes.allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    const json = buf.items;
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_input\":true") != null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_output\":false") != null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_input\":\"1\"") == null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_output\":\"0\"") == null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_input\":\"true\"") == null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_output\":\"false\"") == null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_input\": 1") == null);
    try testing_oes.expect(std.mem.indexOf(u8, json, "\"is_output\": 0") == null);
}

// ============================================================================
// llm_chunk payload tests (2026-08-23 llm-chunk-streaming) The frontend's
// ChatView gate (`event.session_id !== sid`) drops every chunk event whose

test "serializeContentChunk includes session_id + type chunk" {
    const data = try serializeContentChunk(testing_oes.allocator, .{
        .index = 3,
        .content = "Hel",
        .session_id = "sess-abc",
    });
    defer testing_oes.allocator.free(data);

    // indent_4 whitespace puts `"key": value` on its own line — match
    // on the key only (the SseEventLLMHistory tests above use minified,
    // where `"key":"value"` works; here it would false-negative).
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"session_id\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"sess-abc\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"type\": \"chunk\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"content\": \"Hel\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"index\": 3") != null);
}

test "serializeReasoningChunk includes session_id" {
    const data = try serializeReasoningChunk(testing_oes.allocator, .{
        .index = 1,
        .reasoning = "thinking...",
        .session_id = "sess-abc",
    });
    defer testing_oes.allocator.free(data);

    try testing_oes.expect(std.mem.indexOf(u8, data, "\"session_id\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"sess-abc\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"reasoning_content\": \"thinking...\"") != null);
}

test "serializeFinalChunk includes session_id + type chunk_final + usage" {
    const data = try serializeFinalChunk(testing_oes.allocator, .{
        .index = 0,
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 20, .total_tokens = 30 },
        .session_id = "sess-abc",
    });
    defer testing_oes.allocator.free(data);

    try testing_oes.expect(std.mem.indexOf(u8, data, "\"session_id\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"sess-abc\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"type\": \"chunk_final\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"total_tokens\": 30") != null);
}

test "serializeToolCallDeltas includes session_id" {
    const deltas = [_]agent.ToolCallDelta{.{
        .index = 0,
        .id = "call_1",
        .function_name = "bash",
        .function_arguments = "{\"cmd\"",
    }};
    const data = try serializeToolCallDeltas(testing_oes.allocator, .{
        .index = 2,
        .deltas = &deltas,
        .session_id = "sess-abc",
    });
    defer testing_oes.allocator.free(data);

    try testing_oes.expect(std.mem.indexOf(u8, data, "\"session_id\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"sess-abc\"") != null);
    try testing_oes.expect(std.mem.indexOf(u8, data, "\"type\": \"tool_call_delta\"") != null);
}
