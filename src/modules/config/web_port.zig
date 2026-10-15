//! Random loopback port picker for browser mode (web launch).

const std = @import("std");
const gserverz = @import("kabelweb").server;

/// Inclusive low end of the random range (matches the harness).
pub const web_port_range_start: u16 = 40000;
/// Inclusive high end of the random range (matches the harness).
pub const web_port_range_end: u16 = 60000;
/// Random picks before giving up (matches the harness).
pub const web_port_attempts: usize = 50;

/// Ports the picker MUST skip even if bind() succeeds: the desktop
/// daemon default (8081) and Vite's dev default (5173).
pub const web_port_reserved: [2]u16 = .{ 8081, 5173 };

pub const PickError = error{
    PortExhausted,
};

/// True iff `port` is in the reserved set (never auto-picked).
pub fn isReserved(port: u16) bool {
    for (web_port_reserved) |r| {
        if (port == r) return true;
    }
    return false;
}

/// One xorshift64* step over `*state`. Never call with `state.* == 0`
/// (the generator would stick at 0) — callers substitute a nonzero
/// fallback seed (see `pickFreePortSeeded`).
fn nextU64(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
}

/// Map one generator step into the inclusive port range.
fn nextCandidate(state: *u64) u16 {
    const range: u64 = @as(u64, web_port_range_end) - @as(u64, web_port_range_start) + 1;
    return web_port_range_start + @as(u16, @intCast(nextU64(state) % range));
}

/// Pick a random free loopback port, deterministically seeded (for tests).
/// A zero seed substitutes a fixed nonzero fallback so the generator
/// never sticks at 0.
pub fn pickFreePortSeeded(seed: u64) PickError!u16 {
    var state: u64 = if (seed == 0) 0x9E3779B97F4A7C15 else seed;
    var i: usize = 0;
    while (i < web_port_attempts) : (i += 1) {
        const port = nextCandidate(&state);
        if (isReserved(port)) continue;
        // Probe with the server's own bind path, then close. A taken
        // port surfaces as error (BindFailed / SocketCreationFailed) and
        // we move on to the next candidate.
        const addr = gserverz.Address.init("127.0.0.1", port) catch continue;
        gserverz.closeFd(addr.sock_fd);
        return port;
    }
    return error.PortExhausted;
}

/// Pick a random free loopback port, seeded from the wall clock (ns). This is
/// the production entry point (`--port 0` resolution).
pub fn pickFreePort(io: std.Io) PickError!u16 {
    const nanos: i96 = std.Io.Clock.now(.real, io).toNanoseconds();
    const seed: u64 = @truncate(@as(u96, @bitCast(nanos)));
    return pickFreePortSeeded(seed);
}

test "web_port: range constants match the functional harness" {
    try std.testing.expectEqual(@as(u16, 40000), web_port_range_start);
    try std.testing.expectEqual(@as(u16, 60000), web_port_range_end);
    try std.testing.expectEqual(@as(usize, 50), web_port_attempts);
}

test "web_port: reserved ports are skipped" {
    try std.testing.expect(isReserved(8081));
    try std.testing.expect(isReserved(5173));
    try std.testing.expect(!isReserved(40000));
    try std.testing.expect(!isReserved(60000));
    try std.testing.expect(!isReserved(8080));
}

test "web_port: seeded pick lands in range and avoids reserved" {
    const port = try pickFreePortSeeded(0x12345678ABCDEF01);
    try std.testing.expect(port >= web_port_range_start);
    try std.testing.expect(port <= web_port_range_end);
    try std.testing.expect(!isReserved(port));
}

test "web_port: zero seed still picks (fallback seed, never sticks at 0)" {
    const port = try pickFreePortSeeded(0);
    try std.testing.expect(port >= web_port_range_start);
    try std.testing.expect(port <= web_port_range_end);
    try std.testing.expect(!isReserved(port));
}

test "web_port: different seeds spread across the range" {
    // Two fixed seeds must not collide — guards against a degenerate
    // generator that always yields the same candidate.
    const a = try pickFreePortSeeded(1);
    const b = try pickFreePortSeeded(0xFFFFFFFFFFFFFFFF);
    try std.testing.expect(a != b);
}

// The `--port 0` wiring itself is asserted by the functional harness
// (`tests/functional/`), which boots the real binary and reads the port off
// the boot log — the only place `main.zig`'s argument parsing is actually
