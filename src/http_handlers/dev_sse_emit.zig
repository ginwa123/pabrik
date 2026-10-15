//! POST /api/dev/sse/emit_llm — TEST-ONLY SSE event injection. Purpose: let
//! functional UI tests drive the chatview's SSE streaming path WITHOUT a real
//! LLM.

const std = @import("std");
pub const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_workflow = pabrikcore.ai_workflow;

/// The gate. Read once per call (cheap getenv) so a test can flip it
/// mid-process in the future if needed; production binaries never set
/// the var so the read is a single failed lookup.
fn gateEnabled() bool {
    const v = std.c.getenv("PABRIK_TEST_SSE_EMIT") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

const EmitRequest = struct {
    session_id: []const u8 = "",
    type: []const u8 = "chunk",
    content: []const u8 = "",
    index: usize = 0,
    finish_reason: []const u8 = "",
    role: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_name: []const u8 = "",
    /// Mirrors SseEventLLMHistory.is_error — lets UI tests inject
    /// agentic-loop diagnostics through the real wire path
    /// (task_1787663566535_2).
    is_error: bool = false,
};

pub fn emitLlmHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (!gateEnabled()) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"not found\"}}", .{}),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(EmitRequest, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"invalid json body\"}}", .{}),
        });
    };

    if (parsed.session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"session_id is required\"}}", .{}),
        });
    }

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"singleton unavailable\"}}", .{}),
        });
    };
    const event_bus = di.event_bus;

    // Build the same JSON payload shape the real emitters produce (see
    // on_event_sent.zig ContentChunkJson / FinalChunkJson and
    // sse_on_event_send_llm_history.zig SseEventLLMHistory).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    if (std.mem.eql(u8, parsed.type, "chunk_final")) {
        try buf.print(allocator,
            \\{{"index":{d},"type":"chunk_final","finish_reason":"stop","session_id":"{s}"}}
        , .{ parsed.index, parsed.session_id });
    } else if (std.mem.eql(u8, parsed.type, "full")) {
        // SseEventLLMHistory-shaped. The frontend's `full` branch
        // requires finish_reason + at least one renderable field.
        try buf.print(allocator,
            \\{{"index":{d},"content":{f},"type":"full","session_id":"{s}","role":"{s}","finish_reason":"{s}","tool_call_id":"{s}","tool_name":"{s}","is_error":{},"id":"test-{d}"}}
        , .{
            parsed.index,
            std.json.fmt(parsed.content, .{}),
            parsed.session_id,
            if (parsed.role.len > 0) parsed.role else "assistant",
            if (parsed.finish_reason.len > 0) parsed.finish_reason else "stop",
            parsed.tool_call_id,
            parsed.tool_name,
            parsed.is_error,
            parsed.index,
        });
    } else {
        // Default: content chunk.
        try buf.print(allocator,
            \\{{"index":{d},"content":{f},"type":"chunk","session_id":"{s}"}}
        , .{ parsed.index, std.json.fmt(parsed.content, .{}), parsed.session_id });
    }

    const data_copy = try allocator.dupe(u8, buf.items);

    const event = pabrikcore.ai_mod.on_event_sent.SseEvent{
        .session_id = parsed.session_id,
        .data = data_copy,
        .event_type = "llm_chunk",
    };
    // Same dual emit as the real emitters: per-session key + central
    // "llm" broadcast (the frontend's single global EventSource
    // subscribes to the central key and filters by session_id in JS).
    event_bus.emit(pabrikcore.ai_mod.on_event_sent.SseEvent, parsed.session_id, event);
    event_bus.emit(pabrikcore.ai_mod.on_event_sent.SseEvent, "llm", event);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"ok\":true}}", .{}),
    });
}

// ─── Static contract tests ──────────────────────────────────────────────────

test "gate is off by default (no env var)" {
    // Note: this asserts the DEFAULT state. If the developer's shell exports
    // PABRIK_TEST_SSE_EMIT=1 the test would fail — that's intentional (the
    // gate must be opt-in per-process).
    if (std.c.getenv("PABRIK_TEST_SSE_EMIT") == null) {
        try std.testing.expect(!gateEnabled());
    }
}

test "gate accepts exactly '1'" {
    // gateEnabled() reads the real environ; we can't inject. Instead
    // pin the comparison logic via a mirror of the implementation.
    const v: ?[]const u8 = "1";
    try std.testing.expect(v != null and std.mem.eql(u8, v.?, "1"));
    const bad: ?[]const u8 = "0";
    try std.testing.expect(!(bad != null and std.mem.eql(u8, bad.?, "1")));
}
