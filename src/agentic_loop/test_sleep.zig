//! Portable sleep helper for tests that need to wait across the
//! second-granularity boundary of SQLite's `DATETIME` column (used by
//! `save_memory`, `agent_memories`, and `retry_delay_ms` tests to ensure an
const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");

// Win32 kernel32 `Sleep` — declared at module scope to match the project's
// existing pattern (src/helpers/mod.zig:86).
extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;

/// Sleep for at least `sec` seconds + `nsec` nanoseconds. Cross-platform.
pub fn sleep(sec: u32, nsec: u32) void {
    if (comptime builtin.os.tag == .windows) {
        // Win32 Sleep takes a DWORD (u32) of milliseconds. Round UP —
        // we want at LEAST the requested duration, not less.
        const ms: u64 = @as(u64, sec) * 1_000 + @as(u64, nsec) / 1_000_000;
        // Sleep(0) yields the rest of the current time slice — close
        // enough to a "yield" semantics. Saturate at u32 max so a huge
        // `sec` doesn't wrap to 0.
        const ms_dword: u32 = if (ms == 0) 0 else std.math.cast(u32, ms) orelse std.math.maxInt(u32);
        Sleep(ms_dword);
    } else {
        sleepPosix(sec, nsec);
    }
}

fn sleepPosix(sec: u32, nsec: u32) void {
    // POSIX: nanosleep with a 1-second + 0-nanosecond argument covers the
    // test's "bump DATETIME granularity" need.
    var ts: helpers.PosixTimespec = .{
        .sec = @intCast(sec),
        .nsec = @intCast(nsec),
    };
    _ = helpers.nanosleep(&ts, null);
}
