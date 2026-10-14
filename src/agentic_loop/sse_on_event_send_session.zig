const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;

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
};

pub fn onEventSendSessions(
    allocator: std.mem.Allocator,
    event_bus: *event_bus_mod.EventBus,
    input: OnEventInputSessions
    ) !void {
    if (std.mem.indexOf(u8, input.id, "subagent")) |_| {
        return;
    }

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

// ─── Tests
// ───────────────────────────────────────────────────────────────────
// Behavioural tests for the wire-format `event_type_name` mapping (see the

const testing = std.testing;

var captured_session_event: ?SseEvent = null;

fn captureSessionEvent(ev: SseEvent) void {
    captured_session_event = ev;
}

fn setupSessionBus() !struct {
    bus: event_bus_mod.EventBus,
    threaded: std.Io.Threaded,
} {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const bus = event_bus_mod.EventBus.init("session_test_bus", testing.allocator, threaded.io());
    return .{ .bus = bus, .threaded = threaded };
}

fn teardownSessionBus(s: *@TypeOf(setupSessionBus() catch @panic("setupSessionBus failed in the sse_on_event_send_session test fixture"))) void {
    s.bus.deinit();
    s.threaded.deinit();
}

fn freeCapturedSessionEventData() void {
    if (captured_session_event) |ev| {
        testing.allocator.free(ev.data);
    }
}

test "onEventSendSessions: action='created' emits event_type 'session_created'" {
    var s = try setupSessionBus();
    defer teardownSessionBus(&s);
    defer freeCapturedSessionEventData();
    captured_session_event = null;
    try s.bus.subscribe(SseEvent, "sessions", captureSessionEvent);

    try onEventSendSessions(testing.allocator, &s.bus, .{
        .action = "created",
        .id = "session_xyz",
        .name = "Auto-name",
        .status = "active",
        .cwd = "/tmp",
        .created_at = "2026-08-12T10:00:00Z",
        .updated_at = "2026-08-12T10:00:00Z",
    });

    const ev = captured_session_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("session_created", ev.event_type.?);
    try testing.expectEqualStrings("session_xyz", ev.session_id);
}

test "onEventSendSessions: action='updated' emits event_type 'session_updated' (the fix — task_1786507100896)" {
    // This is the actual user-reported bug: the auto-rename-on-first-message
    // cascade calls updateSessionName() → onEventSendSessions(.action =
    // "updated").
    var s = try setupSessionBus();
    defer teardownSessionBus(&s);
    defer freeCapturedSessionEventData();
    captured_session_event = null;
    try s.bus.subscribe(SseEvent, "sessions", captureSessionEvent);

    try onEventSendSessions(testing.allocator, &s.bus, .{
        .action = "updated",
        .id = "session_abc",
        .name = "Auto-generated name",
        .status = "idle",
        .cwd = "/tmp",
        .created_at = "2026-08-12T10:00:00Z",
        .updated_at = "2026-08-12T10:00:05Z",
    });

    const ev = captured_session_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("session_updated", ev.event_type.?);
    try testing.expectEqualStrings("session_abc", ev.session_id);
    // The data is the JSON-serialized payload; spot-check that the new
    // name is present (full JSON shape is covered by the frontend's
    // SessionEvent interface in apps/desktop/src/api/index.ts).
    try testing.expect(std.mem.indexOf(u8, ev.data, "Auto-generated name") != null);
}

test "onEventSendSessions: action='deleted' emits event_type 'session_deleted'" {
    var s = try setupSessionBus();
    defer teardownSessionBus(&s);
    defer freeCapturedSessionEventData();
    captured_session_event = null;
    try s.bus.subscribe(SseEvent, "sessions", captureSessionEvent);

    try onEventSendSessions(testing.allocator, &s.bus, .{
        .action = "deleted",
        .id = "session_old",
        .name = "",
        .status = "deleted",
        .cwd = "/tmp",
        .created_at = "",
        .updated_at = "2026-08-12T11:00:00Z",
    });

    const ev = captured_session_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("session_deleted", ev.event_type.?);
}

test "onEventSendSessions: unknown action falls through to 'session_unknown' (future-proofing default)" {
    // The 'session_unknown' branch is intentional: a NEW action that hasn't
    // been wired into the if/else yet (e.g. a future 'reordered') lands here
    // instead of crashing.
    var s = try setupSessionBus();
    defer teardownSessionBus(&s);
    defer freeCapturedSessionEventData();
    captured_session_event = null;
    try s.bus.subscribe(SseEvent, "sessions", captureSessionEvent);

    try onEventSendSessions(testing.allocator, &s.bus, .{
        .action = "some-future-action",
        .id = "session_x",
        .name = "",
        .status = "active",
        .cwd = "/tmp",
        .created_at = "",
        .updated_at = "2026-08-12T11:00:00Z",
    });

    const ev = captured_session_event orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("session_unknown", ev.event_type.?);
}

test "onEventSendSessions: 'subagent' in id is filtered out (no event emitted)" {
    // The function returns early on 'subagent' ids — subagent sessions
    // share the parent's client surface and shouldn't generate their own
    // client-visible SSE events.
    var s = try setupSessionBus();
    defer teardownSessionBus(&s);
    defer freeCapturedSessionEventData();
    captured_session_event = null;
    try s.bus.subscribe(SseEvent, "sessions", captureSessionEvent);

    try onEventSendSessions(testing.allocator, &s.bus, .{
        .action = "updated",
        .id = "subagent-12345",
        .name = "Auto-name",
        .status = "active",
        .cwd = "/tmp",
        .created_at = "",
        .updated_at = "2026-08-12T10:00:00Z",
    });

    try testing.expect(captured_session_event == null);
}
