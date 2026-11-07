//! The `git_file_stage` SSE channel: the backend telling the UI that a file
//! moved between the index and the worktree, so the Files tab can move ONE
//! row instead of re-fetching the whole git-status list.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const SseEvent = @import("sse.zig").SseEvent;

const event_bus_mod = pabrikcore.event_bus;

/// The central routing key. The frontend subscribes with the
/// `git_file_stage` channel token, which `parseChannels` maps to this key.
pub const RoutingKey = "git_file_stage";

pub const EventStaged = "git_file_staged";
pub const EventUnstaged = "git_file_unstaged";

pub const GitFileStageEventInput = struct {
    /// `staged` | `unstaged`.
    action: []const u8,
    /// The repo-relative path that moved.
    path: []const u8,
    /// The worktree the git command ran in. The frontend filters on this:
    /// one browser tab can show several worktrees, and only the panel bound
    /// to THIS cwd may move a row.
    cwd: []const u8,
    /// True when the git command failed for this path. The frontend then
    /// leaves the row where it is rather than moving a file that did not
    /// move.
    failed: bool = false,
};

/// Emit one file-stage lifecycle event. No-op when `event_bus` is null (unit
/// tests, and any caller that has no bus).
pub fn emitGitFileStageEvent(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    input: GitFileStageEventInput,
) void {
    const bus = event_bus orelse return;
    const payload = .{
        .action = input.action,
        .path = input.path,
        .cwd = input.cwd,
        .failed = input.failed,
    };
    const data = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;

    // The granular wire name.
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "staged"))
        EventStaged
    else if (std.mem.eql(u8, input.action, "unstaged"))
        EventUnstaged
    else
        "git_file_stage_unknown";

    bus.emit(SseEvent, RoutingKey, .{
        // The routing-key literal, not a session id: this channel is not
        // session-scoped (see the module docstring).
        .session_id = RoutingKey,
        .data = data,
        .event_type = event_type_name,
    });
}

/// Convenience: emit `staged` for one path.
pub fn emitStaged(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    path: []const u8,
    failed: bool,
) void {
    emitGitFileStageEvent(allocator, event_bus, .{
        .action = "staged",
        .path = path,
        .cwd = cwd,
        .failed = failed,
    });
}

/// Convenience: emit `unstaged` for one path.
pub fn emitUnstaged(
    allocator: std.mem.Allocator,
    event_bus: ?*event_bus_mod.EventBus,
    cwd: []const u8,
    path: []const u8,
    failed: bool,
) void {
    emitGitFileStageEvent(allocator, event_bus, .{
        .action = "unstaged",
        .path = path,
        .cwd = cwd,
        .failed = failed,
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
        .{ .action = "staged", .want = EventStaged },
        .{ .action = "unstaged", .want = EventUnstaged },
        // An unrecognised action must NOT silently become a registered name.
        .{ .action = "something_new", .want = "git_file_stage_unknown" },
    };

    try bus.subscribe(SseEvent, RoutingKey, capture);
    for (cases) |c| {
        captured = null;
        emitGitFileStageEvent(alloc, &bus, .{
            .action = c.action,
            .path = "src/a.ts",
            .cwd = "/repo",
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

test "the payload carries the path, cwd and failure flag" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    captured = null;
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitGitFileStageEvent(alloc, &bus, .{
        .action = "unstaged",
        .path = "src/b.ts",
        .cwd = "/repo",
        .failed = true,
    });

    try testing.expect(captured != null);
    const data = captured.?.data;
    // `parsed` borrows slices into `data`, so it must be deinit'd BEFORE the
    // buffer is freed — the other order is a use-after-free.
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("unstaged", parsed.value.object.get("action").?.string);
        try testing.expectEqualStrings("src/b.ts", parsed.value.object.get("path").?.string);
        try testing.expectEqualStrings("/repo", parsed.value.object.get("cwd").?.string);
        try testing.expect(parsed.value.object.get("failed").?.bool);
    }
    alloc.free(data);
    captured = null;
}

test "a successful stage reports failed=false" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var bus = event_bus_mod.EventBus.init("test", alloc, threaded.io());
    defer bus.deinit();

    captured = null;
    try bus.subscribe(SseEvent, RoutingKey, capture);
    emitStaged(alloc, &bus, "/repo", "src/c.ts", false);

    const data = captured.?.data;
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("staged", parsed.value.object.get("action").?.string);
        try testing.expect(!parsed.value.object.get("failed").?.bool);
    }
    alloc.free(data);
    captured = null;
}

test "emitGitFileStageEvent is a no-op with null event_bus" {
    emitStaged(testing.allocator, null, "/repo", "a.ts", false);
    emitUnstaged(testing.allocator, null, "/repo", "a.ts", false);
}
