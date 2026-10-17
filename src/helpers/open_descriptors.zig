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

/// The kernel's own answer: `fcntl(fd, F_GETFD)` answers EBADF for a slot this
/// process does not hold, so a sweep to `probe_limit_fd` counts exactly the
/// open descriptors. No `/proc` needed, and no libc on Linux (see posix_arm).
fn posixDescriptorCount() CountError!usize {
    var n: usize = 0;
    var fd: std.posix.fd_t = 0;
    while (fd < probe_limit_fd) : (fd += 1) {
        if (posix_arm.isOpen(fd)) n += 1;
    }
    return n;
}

/// POSIX only. A `poll`/POLLNVAL sweep was the first version and macOS proved
/// it wrong: Darwin's poll never reported the slot the test had just opened, so
/// the count never moved — the self-check below is what caught it.
const posix_arm = if (builtin.os.tag == .windows) struct {} else struct {
    fn isOpen(fd: std.posix.fd_t) bool {
        return switch (builtin.os.tag) {
            .linux => @as(isize, @bitCast(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0))) >= 0,
            else => std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)) >= 0,
        };
    }
};

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
