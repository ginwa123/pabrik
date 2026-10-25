//! A loop that answers a socket must never trade a failed syscall for a spin:
//! `poll` re-arms the instant a readable socket it could not `accept` stays
//! readable, which pins a vCPU at 100%. Both guest loops share this policy.

const std = @import("std");

/// The first wait: one poll tick, short enough that a transient failure (a
/// connection reset between `poll` and `accept`) costs 50 ms and not a second.
pub const first_ms: u32 = 50;
/// The ceiling: a listener broken for good still wakes twice a second, so it
/// stays visible in `top` without owning the core.
pub const max_ms: u32 = 500;

/// How long to wait after one turn of a listener loop. `accepted` is whether
/// that turn took a connection; `failures` is the run of turns that did not.
pub fn afterTurn(accepted: bool, failures: u32) u32 {
    if (accepted) return 0;
    const doublings = @min(failures, 8);
    const wait = first_ms << @intCast(doublings);
    return @min(wait, max_ms);
}

test "a listener that accepted nothing waits, and the wait grows to a cap" {
    // A successful turn never waits: the connection it took is the progress.
    try std.testing.expectEqual(@as(u32, 0), afterTurn(true, 0));
    try std.testing.expectEqual(@as(u32, 0), afterTurn(true, 7));

    // A run of failures backs off, so a persistent error cannot spin.
    try std.testing.expectEqual(first_ms, afterTurn(false, 0));
    try std.testing.expectEqual(first_ms * 2, afterTurn(false, 1));
    try std.testing.expectEqual(first_ms * 4, afterTurn(false, 2));

    // ...and the backoff is capped, so the listener keeps being retried.
    try std.testing.expectEqual(max_ms, afterTurn(false, 4));
    try std.testing.expectEqual(max_ms, afterTurn(false, std.math.maxInt(u32)));
}
