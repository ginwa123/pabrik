//! The `git_pr_state` SSE channel: the backend telling every client that a
//! branch's change request moved — merged or closed — so the badges that read
//! the shared PR-status cache re-ask the forge instead of keeping the colour

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;

/// The central routing key. The frontend subscribes with the
/// `git_pr_state` channel token, which `parseChannels` maps to this key.
pub const RoutingKey = "git_pr_state";

/// A merge landed. `git pr merge` exiting 0 without merging (an armed
/// auto-merge, a GitHub merge queue) is deliberately NOT this — see
/// `emitMerged`'s caller.
pub const EventMerged = "git_pr_state_merged";
/// The change request was closed without being merged.
pub const EventClosed = "git_pr_state_closed";

pub const GitPrStateEventInput = struct {
    /// `merged` | `closed`.
    action: []const u8,
    /// The repo/worktree the forge command ran in. The frontend filters on
    /// this — and it is also the first half of the cache key it invalidates.
    cwd: []const u8,
    /// The change request's head branch (`head_ref`) — the second half of the
    /// cache key.
    branch: []const u8,
};

/// Emit one change-request state event. No-op when `event_bus` is null (unit
/// tests, and any caller that has no bus).
pub fn emitGitPrStateEvent(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    input: GitPrStateEventInput,
) void {
    const bus = event_bus orelse return;
    const payload = .{
        .action = input.action,
        .cwd = input.cwd,
        .branch = input.branch,
    };
    const data = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;

    // The granular wire name.
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "merged"))
        EventMerged
    else if (std.mem.eql(u8, input.action, "closed"))
        EventClosed
    else
        "git_pr_state_unknown";

    bus.emit(SseEvent, RoutingKey, .{
        // The routing-key literal, not a session id: this channel is not
        // session-scoped (see the module docstring).
        .session_id = RoutingKey,
        .data = data,
        .event_type = event_type_name,
    });
}

/// Convenience: emit `merged` for one branch.
pub fn emitMerged(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    branch: []const u8,
) void {
    emitGitPrStateEvent(allocator, event_bus, .{ .action = "merged", .cwd = cwd, .branch = branch });
}

/// Convenience: emit `closed` for one branch.
pub fn emitClosed(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    branch: []const u8,
) void {
    emitGitPrStateEvent(allocator, event_bus, .{ .action = "closed", .cwd = cwd, .branch = branch });
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
        .{ .action = "merged", .want = EventMerged },
        .{ .action = "closed", .want = EventClosed },
        // An unrecognised action must NOT silently become a registered name.
        .{ .action = "something_new", .want = "git_pr_state_unknown" },
    };

    try bus.subscribe(SseEvent, RoutingKey, capture);
    for (cases) |c| {
        captured = null;
        emitGitPrStateEvent(alloc, &bus, .{
            .action = c.action,
            .cwd = "/repo",
            .branch = "worktree/x",
        });
        const ev = captured orelse return error.NoEvent;
        captured = null;
        defer alloc.free(ev.data);
        try testing.expectEqualStrings(c.want, ev.event_type orelse "");
        // The envelope id is the routing-key literal, NOT a session id —
        // this channel is cwd-scoped, and the frontend filters on the
        // payload's `cwd`.
        try testing.expectEqualStrings(RoutingKey, ev.session_id);
    }
}

test "the payload carries the cwd and branch the cache key is built from" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    captured = null;
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitMerged(alloc, &bus, "/repo/.worktrees/feature-x", "worktree/feature-x");

    try testing.expect(captured != null);
    const data = captured.?.data;
    // `parsed` borrows slices into `data`, so it must be deinit'd BEFORE the
    // buffer is freed — the other order is a use-after-free.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("merged", parsed.value.object.get("action").?.string);
        try testing.expectEqualStrings("/repo/.worktrees/feature-x", parsed.value.object.get("cwd").?.string);
        try testing.expectEqualStrings("worktree/feature-x", parsed.value.object.get("branch").?.string);
    }
    alloc.free(data);
    captured = null;
}

test "emitClosed emits the closed wire name with the same payload shape" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    captured = null;
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitClosed(alloc, &bus, "/repo", "worktree/y");

    const ev = captured orelse return error.NoEvent;
    try testing.expectEqualStrings(EventClosed, ev.event_type orelse "");
    const data = ev.data;
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("closed", parsed.value.object.get("action").?.string);
        try testing.expectEqualStrings("/repo", parsed.value.object.get("cwd").?.string);
        try testing.expectEqualStrings("worktree/y", parsed.value.object.get("branch").?.string);
    }
    alloc.free(data);
    captured = null;
}

test "emitGitPrStateEvent is a no-op with null event_bus" {
    emitMerged(testing.allocator, null, "/repo", "worktree/x");
    emitClosed(testing.allocator, null, "/repo", "worktree/x");
}
