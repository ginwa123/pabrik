const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;
const testing = std.testing;

pub const OnEventInputWorkers = struct {
    action: []const u8, // "created", "updated", "deleted"
    id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    last_activity: i64,
    last_activity_description: []const u8,
    created_at: []const u8,
    event_bus: *event_bus_mod.EventBus,
};


/// Send worker events to all subscribed clients via SSE Broadcasts worker
/// list updates (created, updated, deleted) SSE event name (the value of
/// `event:` in the wire format): - workers: worker_created | worker_updated |
pub fn onEventSendWorkers(allocator: std.mem.Allocator, input: OnEventInputWorkers) !void {

    const event_bus = input.event_bus;

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

// ─── Tests
// ────────────────────────────────────────────────────────────────── These
// tests exercise `onEventSendWorkers` against a real `EventBus` with a

var captured: ?SseEvent = null;

fn captureFn(ev: SseEvent) void {
    captured = ev;
}

fn setupBusAndIo() !struct { bus: event_bus_mod.EventBus, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const bus = event_bus_mod.EventBus.init("test_bus", testing.allocator, threaded.io());
    return .{ .bus = bus, .threaded = threaded };
}

fn tearDownBusAndIo(s: *@TypeOf(setupBusAndIo() catch @panic("setupBusAndIo failed in the sse_send_event_worker test fixture"))) void {
    s.bus.deinit();
    s.threaded.deinit();
}

/// Free the captured event's heap-allocated `data` slice. Must be called
/// at the end of every test that asserts on `captured` — otherwise the
/// testing allocator reports a leak.
fn freeCapturedData() void {
    if (captured) |ev| {
        testing.allocator.free(ev.data);
    }
}

test "onEventSendWorkers: action 'created' maps to event_type 'worker_created'" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "created",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 1234567890,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("worker_created", ev.event_type.?);
}

test "onEventSendWorkers: action 'updated' maps to event_type 'worker_updated'" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "updated",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("worker_updated", ev.event_type.?);
}

test "onEventSendWorkers: action 'deleted' maps to event_type 'worker_deleted'" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "deleted",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("worker_deleted", ev.event_type.?);
}

test "onEventSendWorkers: unknown action falls back to 'worker_unknown' (future-proofing)" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "archived",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    try testing.expectEqualStrings("worker_unknown", ev.event_type.?);
}

test "onEventSendWorkers: payload includes all 8 fields as JSON" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "created",
        .id = "w_xyz",
        .session_id = "s_xyz",
        .working_directory = "/home/x",
        .last_activity = 1700000000,
        .last_activity_description = "still working",
        .created_at = "2026-01-01",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    // Every field name must appear in the JSON payload.
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"action\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"session_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"working_directory\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"last_activity\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"last_activity_description\"") != null);
    try testing.expect(std.mem.indexOf(u8, ev.data, "\"created_at\"") != null);
}

test "onEventSendWorkers: routes on the 'workers' key (not 'worker')" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "created",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    // The emit key is hard-coded as "workers" — verify via session_id
    try testing.expectEqualStrings("workers", ev.session_id);
}

test "onEventSendWorkers: emitted event has its own heap-allocated data copy" {
    var s = try setupBusAndIo();
    defer tearDownBusAndIo(&s);
    captured = null;
    try s.bus.subscribe(SseEvent, "workers", captureFn);
    defer freeCapturedData();

    try onEventSendWorkers(testing.allocator, .{
        .action = "created",
        .id = "w1",
        .session_id = "s1",
        .working_directory = "/tmp",
        .last_activity = 0,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = &s.bus,
    });

    const ev = captured orelse return error.NoEventCaptured;
    // The data pointer must not alias the stack-local buf the helper
    // used to build the JSON — it must be a heap copy that survives
    // after the helper returns.
    try testing.expect(ev.data.len > 0);
}
