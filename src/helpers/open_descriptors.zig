//! open_descriptors — descriptors (POSIX) / handles (Windows) held by THIS
//! process. `/proc/self/fd` exists on Linux alone, so the leak tests that
//! used it skipped everywhere else; this names each host's own mechanism.

const std = @import("std");
const builtin = @import("builtin");

pub const CountError = error{
    /// No descriptor-counting mechanism is wired up for this host.
    UnsupportedHost,
    /// The host's own counting call refused to answer.
    CountFailed,
};

/// How far the POSIX sweep walks the descriptor table: the soft limit is
/// 1024 on Linux and 256 on macOS, so this is slack for a raised limit, not
/// a claim about the maximum. Only the delta between two counts matters.
const probe_limit_fd: std.posix.fd_t = 4096;

/// Open descriptors (POSIX) / handles (Windows) held by this process right
/// now. A host nothing here handles gets an ERROR, which fails the caller's
/// test instead of letting it pass with nothing asserted.
pub fn count() CountError!usize {
    return switch (builtin.os.tag) {
        .windows => windowsHandleCount(),
        .linux,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        .illumos,
        .haiku,
        .serenity,
        .emscripten,
        => posixDescriptorCount(),
        else => error.UnsupportedHost,
    };
}

/// `GetProcessHandleCount` on this process: a pipe, a process and a thread
/// are one handle each, so a handle count is Windows' spelling of an
/// open-descriptor count. Documented since Windows Vista.
fn windowsHandleCount() CountError!usize {
    var n: u32 = 0;
    if (!win32.GetProcessHandleCount(std.os.windows.GetCurrentProcess(), &n).toBool()) {
        return error.CountFailed;
    }
    return n;
}

/// The kernel's own answer: `poll` reports POLLNVAL for a slot this process
/// does not hold and leaves the flags at 0 for one it does, so a sweep to
/// `probe_limit_fd` counts exactly the open descriptors. No `/proc` needed.
fn posixDescriptorCount() CountError!usize {
    var n: usize = 0;
    var fd: std.posix.fd_t = 0;
    while (fd < probe_limit_fd) : (fd += 1) {
        var one = [_]std.posix.pollfd{.{ .fd = fd, .events = 0, .revents = 0 }};
        _ = std.posix.poll(&one, 0) catch return error.CountFailed;
        if (one[0].revents & std.posix.POLL.NVAL == 0) n += 1;
    }
    return n;
}

/// Windows only. `struct {}` elsewhere keeps the Win32 symbol out of the
/// build on every other host, and out of the way of a cross-compile.
const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetProcessHandleCount(
        hProcess: std.os.windows.HANDLE,
        pdwHandleCount: *u32,
    ) callconv(.winapi) std.os.windows.BOOL;
} else struct {};

// ─── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "count: this host's mechanism sees a descriptor the test opens" {
    // The guard against a mechanism that answers 0 — or the whole table —
    // for everything: a leak test reading such a number passes vacuously on
    // every host, which is the skip this file exists to replace.
    const before = try count();
    try testing.expect(before > 0); // stdin/stdout/stderr at the very least

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "probe", .{});
    defer file.close(testing.io);

    const during = try count();
    try testing.expect(during > before);
}
