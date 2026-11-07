//! The `skill_evals` SSE channel: the backend telling the UI that an eval
//! finished, so the Evals tab can refresh without polling.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;

/// The central routing key. The frontend subscribes with the `skill_evals`
/// channel token, which `parseChannels` maps to this key.
pub const RoutingKey = "skill_evals";

pub const SkillEvalEventInput = struct {
    /// `run_started` | `run_finished` | `result_applied`.
    action: []const u8,
    /// The run this concerns, when there is one.
    run_id: []const u8 = "",
    /// The session that triggered it, so a listener can filter.
    session_id: []const u8 = "",
    /// How many results the run produced (0 for the other actions).
    evaluated: u32 = 0,
    /// The result that was applied, for `result_applied`.
    result_id: []const u8 = "",
};

/// Emit one skill-eval lifecycle event. No-op when `event_bus` is null (unit
/// tests, and any caller that has no bus).
pub fn emitSkillEvalEvent(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    input: SkillEvalEventInput,
) void {
    const bus = event_bus orelse return;
    const payload = .{
        .action = input.action,
        .run_id = input.run_id,
        .session_id = input.session_id,
        .evaluated = input.evaluated,
        .result_id = input.result_id,
    };
    const data = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;

    // The granular wire name.
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "run_started"))
        "skill_evals_run_started"
    else if (std.mem.eql(u8, input.action, "run_finished"))
        "skill_evals_run_finished"
    else if (std.mem.eql(u8, input.action, "result_applied"))
        "skill_evals_result_applied"
    else
        "skill_evals_unknown";

    bus.emit(SseEvent, RoutingKey, .{
        .session_id = input.session_id,
        .data = data,
        .event_type = event_type_name,
    });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

var captured: ?SseEvent = null;

fn capture(ev: SseEvent) void {
    captured = ev;
}

test "each action maps to its own granular wire name" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    const cases = [_]struct { action: []const u8, want: []const u8 }{
        .{ .action = "run_started", .want = "skill_evals_run_started" },
        .{ .action = "run_finished", .want = "skill_evals_run_finished" },
        .{ .action = "result_applied", .want = "skill_evals_result_applied" },
        // An unrecognised action must NOT silently become a registered name.
        .{ .action = "something_new", .want = "skill_evals_unknown" },
    };

    try bus.subscribe(SseEvent, RoutingKey, capture);
    for (cases) |c| {
        captured = null;
        emitSkillEvalEvent(alloc, &bus, .{ .action = c.action, .session_id = "sess_1" });
        const ev = captured orelse return error.NoEvent;
        captured = null;
        defer alloc.free(ev.data);
        try testing.expectEqualStrings(c.want, ev.event_type orelse "");
        // The event carries the SESSION id (so a listener can filter), while
        // the routing key is the central `skill_evals` one — that is what
        // `bus.subscribe(SseEvent, RoutingKey, ...)` above proves.
        try testing.expectEqualStrings("sess_1", ev.session_id);
    }
}

test "the payload carries the run, session and count" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    captured = null;
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitSkillEvalEvent(alloc, &bus, .{
        .action = "run_finished",
        .run_id = "run_7",
        .session_id = "sess_9",
        .evaluated = 3,
    });

    try testing.expect(captured != null);
    const data = captured.?.data;
    // `parsed` borrows slices into `data`, so it must be deinit'd BEFORE the
    // buffer is freed — the other order is a use-after-free.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("run_finished", parsed.value.object.get("action").?.string);
        try testing.expectEqualStrings("run_7", parsed.value.object.get("run_id").?.string);
        try testing.expectEqualStrings("sess_9", parsed.value.object.get("session_id").?.string);
        try testing.expectEqual(@as(i64, 3), parsed.value.object.get("evaluated").?.integer);
    }
    alloc.free(data);
    captured = null;
}
