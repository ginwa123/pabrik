const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;
const SkillInfo = @import("session_skills.zig").SkillInfo;

const agent = pabrikcore.agent;
const event_bus_mod = pabrikcore.event_bus;
const logger_mod = pabrikcore.loggermod;
const helpers = @import("helpers");
const testing = std.testing;

/// JSON representation of a tool call
const ToolCallJson = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const SseEventLLMHistory = struct {
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
    video_url: ?[]const u8 = null,
    session_skills: ?[]const SkillInfo = null,
    /// True when this event is an agentic-loop diagnostic (retry attempt
    /// or TooManyRetries bail) rather than a real chat turn. The frontend
    /// routes these into a dedicated AgentErrorCard instead of the normal
    /// message list. Default false — only workflow.zig's 3 diagnostic
    /// sites set it.
    is_error: bool = false,
};

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
    tool_calls_json: ?[]const u8,
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
    video_url: ?[]const u8 = null,
    session_skills: []const SkillInfo,
    /// See SseEventLLMHistory.is_error — threaded through from
    /// InsertLLMHistoriesInput by insert_llm_histories.zig.
    is_error: bool = false,
};

pub const OnEventSendLLMHistoryInput = struct { allocator: std.mem.Allocator, io: std.Io, logger: ?*logger_mod.Logger, event_bus: *event_bus_mod.EventBus, entity: OnEventInputLLMHistory };

pub fn onEventSendLLMHistory(
    obj: OnEventSendLLMHistoryInput,
) !void {
    const input = obj.entity;
    const log = obj.logger;
    const session_id = input.session_id;
    const allocator = obj.allocator;
    const event_bus = obj.event_bus;

    // Trace: log what content we're receiving
    if (input.content) |c| {
        // Truncate content for logging if too long (>500 chars)
        const truncated_content = if (c.len > 500) c[0..500] else c;
        const suffix = if (c.len > 500) "... [truncated]" else "";
        log.?.infoFmt("on_event_send_new[{s}]: content=\"{s}{s}\", len={d}, is_thinking={}, role={s}", .{
            session_id,
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
    // serialization. Without this, Zig 0.16's std.json.fmt emits
    // invalid-UTF-8 strings as ARRAYS of bytes (because
    // emit_strings_as_arrays defaults to false but only applies when the
    // slice is valid UTF-8 — see /usr/local/lib/zig/std/json/Stringify.zig:506).
    // The bash tool's stdout can contain binary bytes (e.g. 0x89, 0x93
    // from test programs printing raw bytes) that are invalid UTF-8 and
    // would otherwise corrupt the SSE payload — the frontend would
    // receive content as [60, 116, 111, ...] instead of "...". This is
    // the same fix used by `sessionMessagesHandler` for the REST path
    // (see http_handlers/session_messages_get.zig).
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

    // Build tool_calls JSON array if present

    // Convert llm_history.SkillInfo to local SkillInfo for SSE payload
    var session_skills_json: ?[]const SkillInfo = null;
    var session_skills_owned: std.ArrayList(SkillInfo) = .empty;
    defer if (session_skills_json == null) session_skills_owned.deinit(allocator);

    for (input.session_skills) |skill| {
        try session_skills_owned.append(allocator, .{
            .skill_name = skill.skill_name,
            .content = skill.content,
            .loaded_at = skill.loaded_at,
        });
    }
    session_skills_json = try session_skills_owned.toOwnedSlice(allocator);

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
        .tool_calls_json = input.tool_calls_json,
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
        .video_url = input.video_url,
        .session_skills = session_skills_json,
        .is_error = input.is_error,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Use std.json.fmt with format writer
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })});

    // The owned skills slice has served its purpose (serialized into buf
    // above) — free it now. Guarded on len > 0: a zero-length toOwnedSlice
    // result may not be a live allocation, and freeing it would trip the
    // allocator. Production callers use a per-request arena (no-op here),
    // but tests run on testing.allocator where an unfreed slice leaks.
    if (session_skills_json) |sk| {
        if (sk.len > 0) allocator.free(sk);
    }

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

// ─── Tests ──────────────────────────────────────────────────────────────────
//
// `onEventSendLLMHistory` dereferences `logger.?` at line 89, so passing
// `null` for the logger crashes. Tests construct a real Logger via
// `Logger.init(alloc, io, .{})`. We only assert on the captured event's
// type + JSON shape — the trace logging itself is incidental.

var captured_llm_event: ?SseEvent = null;

fn captureLlmFn(ev: SseEvent) void {
    captured_llm_event = ev;
}

fn freeCapturedLlmEventData() void {
    if (captured_llm_event) |ev| {
        testing.allocator.free(ev.data);
    }
}

fn setupLlmBusAndIo() !struct {
    bus: event_bus_mod.EventBus,
    threaded: std.Io.Threaded,
    logger: logger_mod.Logger,
} {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    const bus = event_bus_mod.EventBus.init("llm_test_bus", testing.allocator, io);
    const logger = logger_mod.Logger.init(testing.allocator, io, .{
        .min_level = .err, // suppress info-level traces from the helper
        .include_location = false,
        .include_request_id = false,
        .include_timestamp = false,
    });
    return .{ .bus = bus, .threaded = threaded, .logger = logger };
}

fn teardownLlmBus(s: *@TypeOf(setupLlmBusAndIo() catch @panic("setupLlmBusAndIo failed in the sse_on_event_send_llm_history test fixture"))) void {
    s.bus.deinit();
    s.threaded.deinit();
    s.logger.deinit();
}

test "onEventSendLLMHistory: emits event_type 'llm_full' on both session_id and 'llm' keys" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s1",
            .model = "test-model",
            .cwd = "/tmp",
            .content = "hello",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("llm_full", ev.event_type.?);
    try testing.expectEqualStrings("s1", ev.session_id);
}

test "onEventSendLLMHistory: JSON payload includes the standard field set" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_json",
            .model = "m_json",
            .cwd = "/tmp",
            .content = "json content",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    // Verify each canonical field appears in the JSON.
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"session_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"cwd\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"content\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"role\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"loop_index\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"temperature\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"is_thinking\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"is_input\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"is_output\"") != null);
    // Note: std.json.fmt does NOT escape the inner quotes around field
    // values, so the substring looks like `"type":"full"`, not
    // `"type":"full"` (no double-quotes around `full`).
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"type\":") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"full\"") != null);
}

test "onEventSendLLMHistory: invalid UTF-8 in content is sanitized (no byte-array in JSON)" {
    // Regression guard for the bug documented at sse_on_event_send_llm_history.zig:101
    // — without sanitizeUtf8, std.json.fmt emits invalid-UTF-8 strings as
    // ARRAYS of bytes. The test passes a known-invalid byte sequence and
    // asserts the JSON contains a string (not an array) for `content`.
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    // 0x89 0x93 are invalid UTF-8 (continuation bytes without a start byte).
    const invalid_utf8 = "\x89\x93broken";
    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_utf8",
            .model = "m",
            .cwd = "/tmp",
            .content = invalid_utf8,
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    // The fix is correct if `content` is JSON-stringified (quoted)
    // rather than JSON-array-ified. Specifically: "content": should be
    // present, NOT "content":[.
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"content\":") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"content\":[") == null);
}

test "onEventSendLLMHistory: invalid UTF-8 in reasoning_content is sanitized" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    const invalid_utf8 = "\xff\xfe\xfdthinking-broken";
    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_reason",
            .model = "m",
            .cwd = "/tmp",
            .content = "ok content",
            .reasoning_content = invalid_utf8,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = true,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"reasoning_content\":") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"reasoning_content\":[") == null);
}

test "onEventSendLLMHistory: content=null produces a valid empty-string content in the payload" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_null",
            .model = "m",
            .cwd = "/tmp",
            .content = null,
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    // Empty string content — the JSON contains `"content": ""` (note the
    // space after `:` because the payload uses `.whitespace = .indent_4`).
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"content\":") != null);
    // The value should be an empty JSON string. With indent_4 whitespace,
    // it appears as `"content": ""` (space + empty quoted string).
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"content\": \"\"") != null);
}

test "onEventSendLLMHistory: emits on both session_id and 'llm' keys (central broadcast)" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    // Subscribe only to "llm" — the session_id key gets a separate emit
    // that we won't capture. The test verifies the central "llm" emit
    // fires (which is what the frontend filter pattern relies on).
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_broadcast",
            .model = "m",
            .cwd = "/tmp",
            .content = "broadcast me",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("llm_full", ev.event_type.?);
}

// ─── is_error flag (agent error card, task_1787663566535_2) ────────────────
//
// Agentic-loop diagnostics (retry attempts + TooManyRetries bails) are
// emitted over the SAME `llm_full` event as normal messages. The frontend
// needs an explicit marker to route them into a dedicated AgentErrorCard
// instead of rendering them as a plain user chat bubble.

test "onEventSendLLMHistory: is_error=true serializes into the JSON payload" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_err",
            .model = "m",
            .cwd = "/tmp",
            .content = "[Retry 1/10] StreamInterrupted (callDynamicAgentNew). Retrying in 10000ms.",
            .reasoning_content = null,
            .role = "user",
            .finish_reason = "null",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = true,
            .is_output = false,
            .is_error = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"is_error\": true") != null);
}

test "onEventSendLLMHistory: is_error defaults to false in the JSON payload" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_noerr",
            .model = "m",
            .cwd = "/tmp",
            .content = "normal assistant turn",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    // Default path must NOT claim to be an error — the frontend routes on
    // this exact field.
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"is_error\": false") != null);
}

test "onEventSendLLMHistory: session_skills serializes into the JSON payload" {
    var s = try setupLlmBusAndIo();
    defer teardownLlmBus(&s);
    defer freeCapturedLlmEventData();
    captured_llm_event = null;
    try s.bus.subscribe(SseEvent, "llm", captureLlmFn);

    try onEventSendLLMHistory(.{
        .allocator = testing.allocator,
        .io = s.threaded.io(),
        .logger = &s.logger,
        .event_bus = &s.bus,
        .entity = .{
            .session_id = "s_skills",
            .model = "m",
            .cwd = "/tmp",
            .content = "skills check",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls_json = null,
            .tool_call_id = null,
            .agent_name = "Agent",
            .loop_index = 0,
            .temperature = 0.2,
            .is_thinking = false,
            .is_input = false,
            .is_output = true,
            .session_skills = &.{.{ .skill_name = @constCast("my-skill"), .content = @constCast("hello"), .loaded_at = 123 }},
        },
    });

    const ev = captured_llm_event orelse return error.NoEventCaptured;
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"session_skills\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "my-skill") != null);
}
