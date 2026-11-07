//! SSE push for background processes (`command background=true` rows).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const event_bus_mod = pabrikcore.event_bus;
const on_event_sent = @import("on_event_sent.zig");
const testing = std.testing;

pub const RoutingKey = "background_process";
pub const EventCreated = "background_process_created";
pub const EventCompleted = "background_process_completed";

pub const EmitArgs = struct {
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    action: []const u8, // "created" | "completed"
};

/// Emit one background-process lifecycle event. No-op when `event_bus`
/// is null (unit tests). Never fails the caller — OOM / emit errors are
/// swallowed (the frontend falls back to manual refresh + resync refetch).
pub fn emitBackgroundProcessEvent(args: EmitArgs) void {
    const ev = args.event_bus orelse return;
    const event_type_name: []const u8 = if (std.mem.eql(u8, args.action, "created"))
        EventCreated
    else if (std.mem.eql(u8, args.action, "completed"))
        EventCompleted
    else
        return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(args.allocator);

    const payload = .{
        .action = args.action,
        .session_id = args.session_id,
        .pid = args.pid,
        .command = args.command,
    };
    buf.print(args.allocator, "{f}", .{std.json.fmt(payload, .{
        .whitespace = .indent_4,
    })}) catch return;

    // Arena rule: the caller-owned allocator outlives the synchronous
    // `emit` (forwardToClients copies into the SSE frame before return),
    // so no free here — same as onEventSendWorkers / insertQueueMessage.
    const data_copy = args.allocator.dupe(u8, buf.items) catch return;
    const event = on_event_sent.SseEvent{
        .session_id = args.session_id,
        .data = data_copy,
        .event_type = event_type_name,
    };
    ev.emit(on_event_sent.SseEvent, RoutingKey, event);
}

/// Convenience: emit `created` after a successful `save`.
pub fn emitCreated(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
) void {
    emitBackgroundProcessEvent(.{
        .allocator = allocator,
        .event_bus = event_bus,
        .session_id = session_id,
        .pid = pid,
        .command = command,
        .action = "created",
    });
}

/// Convenience: emit `completed` after a successful notify (+ delete).
pub fn emitCompleted(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
) void {
    emitBackgroundProcessEvent(.{
        .allocator = allocator,
        .event_bus = event_bus,
        .session_id = session_id,
        .pid = pid,
        .command = command,
        .action = "completed",
    });
}

test "emitBackgroundProcessEvent is a no-op with null event_bus" {
    emitCreated(testing.allocator, null, "s1", 42, "sleep 60");
    emitCompleted(testing.allocator, null, "s1", 42, "sleep 60");
}
