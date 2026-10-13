//! The `git_pr_state` SSE channel: the backend telling every client that a
//! branch's change request moved — merged or closed — so the badges that read
//! the shared PR-status cache re-ask the forge instead of keeping the colour
//! they fetched before the mutation.
//!
//! ## Why this exists
//!
//! `POST /api/git/pr/merge` and `POST /api/git/pr/close` changed a pull/merge
//! request's state and told nobody. The client that made the call could react
//! locally, but:
//!
//!   - a SECOND tab (or a second machine, or the same board in another window)
//!     had no way to learn, and
//!   - the badges do not call the forge on every render: `prStatusCache.ts`
//!     holds a 60 s TTL, so the sidebar's RECENT icon and the kanban card kept
//!     the pre-merge `open` green until something else happened to re-read.
//!
//! The 30 s PR-tab poll and the TTL eventually converge, which is exactly what
//! "eventually" means to a user who just pressed Merge and is looking at a
//! green branch icon.
//!
//! ## Why a central routing key, like `git_file_stage`
//!
//! A change request is not scoped to a session in a way the UI can use: a
//! worktree (`cwd`) is identified by path, and several sessions can share one.
//! So this emits on ONE central key and the frontend filters by `data.cwd`
//! JS-side — the same shape `git_file_stage_events.zig` and
//! `background_process_events.zig` use, and for the same reason.
//!
//! ## The payload is the frontend's cache key
//!
//! `cwd` + `branch` are precisely the two halves of `prStatusCache`'s
//! `cwd::branch::<provider>` key, so the consumer is one call to
//! `invalidatePrStatus(cwd, branch)` — no lookup, no guessing which branch the
//! event is about.
//!
//! ## The four registration places
//!
//! A named SSE event that is not registered in ALL of these is dropped by the
//! browser's `EventSource` before `onEvent` ever fires, which is
//! indistinguishable from a dead stream (the PR #215 / `session_unknown`
//! class). They are:
//!
//!   1. the Zig event-type ladder (this file)
//!   2. `additionalEventTypes` in `src/apps/desktop/src/api/index.ts`
//!   3. an `onEvent` dispatch branch in the same file
//!   4. `SseEventMap` in `helpers/sseBus.ts` + `UnifiedChannels` in `api/index.ts`
//!
//! Miss any one and the event silently vanishes.
//!
//! …and TWO on the backend, before the browser is even reached. Both live in
//! `src/http_handlers/unified_events_sse.zig`:
//!
//!   5. a `?channels=` token in `parseChannels` — without it the handshake is a
//!      400 and the stream never opens;
//!   6. the routing-key → callback branch in the subscribe loop. Missing THIS
//!      one is the quietest failure of the six: the handshake succeeds, the
//!      subscription is created, and no event ever arrives.
//!
//! `tests/functional/git_pr_state_sse_test.zig` is the witness for #6 — it was
//! run, and went red on exactly that omission before the callback branch was
//! added.

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
    /// cache key. The caller already has it: both mutating handlers re-read
    /// `GET /api/git/pr/status` before answering, so this costs no extra
    /// forge call.
    branch: []const u8,
};

/// Emit one change-request state event.
///
/// No-op when `event_bus` is null (unit tests, and any caller that has no bus).
/// Never fails the caller: a successful merge must not be reported as a failure
/// because the UI could not be told about it. The event is bookkeeping — the
/// frontend's local invalidate in `MergeBox` is the path that cannot be lost.
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

    // The granular wire name. An action not in this ladder falls through to
    // `git_pr_state_unknown`, which the frontend deliberately does NOT
    // register — so an unrecognised action cannot leak into the badge's
    // invalidate callback without an explicit contract. (Zig 0.16 cannot
    // `switch` on `[]const u8`.)
    const event_type_name: []const u8 = if (std.mem.eql(u8, input.action, "merged"))
        EventMerged
    else if (std.mem.eql(u8, input.action, "closed"))
        EventClosed
    else
        "git_pr_state_unknown";

    bus.emit(SseEvent, RoutingKey, .{
        // The routing-key literal, not a session id: this channel is not
        // session-scoped (see the module docstring). `forwardToClients`
        // resolves the envelope id against the sessions table, finds no row,
        // and falls back to the payload — which carries no `session_id`
        // either, so the event is delivered to every subscriber. That is
        // correct here: the cwd filter is the frontend's job.
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
