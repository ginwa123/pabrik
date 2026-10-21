//! The manager this process started, and the stop that takes it down with us.
//! The manager is forked into its own session, so it is not in our process
//! group: only its pid reaches it, and a graceful stop is the only way out.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// How long the manager gets to leave on its own before it is killed.
pub const default_stop_timeout_ms: u32 = 5_000;

pub const sig_term: u8 = 15;
pub const sig_kill: u8 = 9;

pub const Outcome = enum {
    nothing_to_stop,
    stopped,
    killed,
    survived,
};

/// The system calls the stop needs, so the order of the calls can be
/// asserted without a process.
pub const Env = struct {
    ctx: *anyopaque = undefined,
    nowMs: *const fn (ctx: *anyopaque) i64,
    alive: *const fn (ctx: *anyopaque, pid: i32) bool,
    signal: *const fn (ctx: *anyopaque, pid: i32, sig: u8) void,
    gone: *const fn (ctx: *anyopaque, pid: i32) bool,
    sleepMs: *const fn (ctx: *anyopaque, ms: u32) void,
};

/// The manager THIS process forked. Null when we adopted one that was
/// already running.
var spawned: ?i32 = null;

pub fn rememberSpawned(pid: i32) void {
    spawned = pid;
}

pub fn spawnedPid() ?i32 {
    return spawned;
}

/// SIGTERM first, so the manager stops the VMs it owns, then SIGKILL for a
/// manager that will not go.
pub fn stop(env: Env, pid: ?i32, timeout_ms: u32) Outcome {
    const target = pid orelse return .nothing_to_stop;
    env.signal(env.ctx, target, sig_term);
    if (waitGone(env, target, timeout_ms)) return .stopped;
    env.signal(env.ctx, target, sig_kill);
    if (waitGone(env, target, timeout_ms)) return .killed;
    return .survived;
}

/// Stop the manager this process started, and forget it.
pub fn stopSpawned(timeout_ms: u32) Outcome {
    const pid = spawned orelse return .nothing_to_stop;
    spawned = null;
    if (comptime builtin.os.tag != .linux) return .nothing_to_stop;
    return stop(real, pid, timeout_ms);
}

fn waitGone(env: Env, pid: i32, timeout_ms: u32) bool {
    const deadline = env.nowMs(env.ctx) + timeout_ms;
    while (env.nowMs(env.ctx) <= deadline) {
        if (env.gone(env.ctx, pid)) return true;
        env.sleepMs(env.ctx, 10);
    }
    return env.gone(env.ctx, pid);
}

pub const real: Env = .{
    .ctx = undefined,
    .nowMs = realNowMs,
    .alive = realAlive,
    .signal = realSignal,
    .gone = realGone,
    .sleepMs = realSleepMs,
};

fn realNowMs(_: *anyopaque) i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn realAlive(_: *anyopaque, pid: i32) bool {
    const err = linux.errno(linux.syscall2(.kill, @intCast(pid), 0));
    return err == .SUCCESS or err == .PERM;
}

fn realSignal(_: *anyopaque, pid: i32, sig: u8) void {
    _ = linux.syscall2(.kill, @intCast(pid), sig);
}

/// A child we forked stays a zombie until it is reaped, and a zombie still
/// answers `kill(pid, 0)`, so the reap is part of the liveness answer.
fn realGone(_: *anyopaque, pid: i32) bool {
    var status: u32 = 0;
    const rc = linux.wait4(pid, &status, 1, null);
    if (linux.errno(rc) == .SUCCESS and rc != 0) return true;
    return !realAlive(undefined, pid);
}

fn realSleepMs(_: *anyopaque, ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const Fake = struct {
    now: i64 = 0,
    alive: bool = true,
    deaf_to_term: bool = false,
    terms: u32 = 0,
    kills: u32 = 0,

    fn me(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn nowMs(ctx: *anyopaque) i64 {
        return me(ctx).now;
    }
    fn aliveFn(ctx: *anyopaque, _: i32) bool {
        return me(ctx).alive;
    }
    fn signal(ctx: *anyopaque, _: i32, sig: u8) void {
        const fake = me(ctx);
        switch (sig) {
            sig_term => {
                fake.terms += 1;
                if (!fake.deaf_to_term) fake.alive = false;
            },
            sig_kill => {
                fake.kills += 1;
                fake.alive = false;
            },
            else => {},
        }
    }
    fn gone(ctx: *anyopaque, _: i32) bool {
        return !me(ctx).alive;
    }
    fn sleepMs(ctx: *anyopaque, ms: u32) void {
        me(ctx).now += ms;
    }
};

fn fakeEnv(fake: *Fake) Env {
    return .{
        .ctx = @ptrCast(fake),
        .nowMs = Fake.nowMs,
        .alive = Fake.aliveFn,
        .signal = Fake.signal,
        .gone = Fake.gone,
        .sleepMs = Fake.sleepMs,
    };
}

/// A child that waits to be signalled. `deaf_to_term` is a wedged manager:
/// it never leaves on SIGTERM. The pipe is the handshake, so the parent
/// never signals a child that has not armed its disposition yet.
fn forkWaiter(deaf_to_term: bool) !i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return error.ForkFailed;
    if (child == 0) {
        _ = linux.close(fds[0]);
        if (deaf_to_term) {
            var sa: linux.Sigaction = .{
                .handler = .{ .handler = @as(?linux.Sigaction.handler_fn, @ptrFromInt(1)) },
                .mask = std.mem.zeroes(linux.sigset_t),
                .flags = 0,
            };
            _ = linux.sigaction(linux.SIG.TERM, &sa, null);
        }
        _ = linux.write(fds[1], "x", 1);
        _ = linux.close(fds[1]);
        const ts = linux.timespec{ .sec = 120, .nsec = 0 };
        _ = linux.nanosleep(&ts, null);
        linux.exit(0);
    }
    _ = linux.close(fds[1]);
    var ready: [1]u8 = undefined;
    const n = linux.read(fds[0], &ready, 1);
    _ = linux.close(fds[0]);
    if (n != 1) return error.HandshakeFailed;
    return @intCast(child);
}

fn goneForReal(pid: i32) bool {
    const err = linux.errno(linux.syscall2(.kill, @intCast(pid), 0));
    return err == .SUCCESS or err == .PERM;
}

test "a manager that leaves on SIGTERM is not killed" {
    var fake = Fake{};
    const env = fakeEnv(&fake);
    try testing.expectEqual(Outcome.stopped, stop(env, 4242, 1000));
    try testing.expectEqual(@as(u32, 1), fake.terms);
    try testing.expectEqual(@as(u32, 0), fake.kills);
}

test "a manager that ignores SIGTERM is killed" {
    var fake = Fake{ .deaf_to_term = true };
    const env = fakeEnv(&fake);
    try testing.expectEqual(Outcome.killed, stop(env, 4242, 1000));
    try testing.expectEqual(@as(u32, 1), fake.terms);
    try testing.expectEqual(@as(u32, 1), fake.kills);
}

test "no manager means nothing is signalled" {
    var fake = Fake{};
    const env = fakeEnv(&fake);
    try testing.expectEqual(Outcome.nothing_to_stop, stop(env, null, 1000));
    try testing.expectEqual(@as(u32, 0), fake.terms);
    try testing.expectEqual(@as(u32, 0), fake.kills);
}

test "the manager this process started is stopped when the service closes" {
    const pid = try forkWaiter(false);
    rememberSpawned(pid);
    try testing.expectEqual(@as(?i32, pid), spawnedPid());

    try testing.expectEqual(Outcome.stopped, stopSpawned(5_000));
    try testing.expectEqual(@as(?i32, null), spawnedPid());
    try testing.expect(!goneForReal(pid));
}

test "a manager that ignores SIGTERM does not outlive the service" {
    const pid = try forkWaiter(true);
    rememberSpawned(pid);

    try testing.expectEqual(Outcome.killed, stopSpawned(200));
    try testing.expectEqual(@as(?i32, null), spawnedPid());
    try testing.expect(!goneForReal(pid));
}
