//! Terminal control: raw mode, alt-screen, size query, key reading.

const std = @import("std");
const key_mod = @import("key.zig");

pub const Size = struct { width: u16, height: u16 };

/// Saved termios state returned by `enterRawMode`. Opaque to callers;
/// hand it back to `leaveRawMode`.
pub const RawMode = struct {
    saved: std.posix.termios,
    fd: std.posix.fd_t,
};

pub fn isTty() bool {
    return std.c.isatty(std.posix.STDIN_FILENO) == 1;
}

/// Switch stdin to raw mode (cbreak, no echo, no signal generation).
/// Returns the saved state — MUST be passed to `leaveRawMode` before
/// process exit or the terminal is left corrupted.
pub fn enterRawMode() !RawMode {
    const fd = std.posix.STDIN_FILENO;
    const saved = try std.posix.tcgetattr(fd);
    var raw = saved;
    // Mirrors `stty raw -echo`:
    raw.lflag.ECHO = false; // no local echo
    raw.lflag.ICANON = false; // char-at-a-time, not line-at-a-time
    raw.lflag.ISIG = false; // don't generate SIGINT on Ctrl-C (we handle it)
    raw.iflag.IXON = false; // don't intercept Ctrl-S/Ctrl-Q flow control
    raw.iflag.ICRNL = false; // don't map CR -> NL
    // VMIN=0/VTIME=1 — "return as soon as a byte is available; otherwise wait
    // at most 0.1 s and return 0".
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    return .{ .saved = saved, .fd = fd };
}

/// Restore the terminal state saved by `enterRawMode`.
pub fn leaveRawMode(rm: RawMode) void {
    std.posix.tcsetattr(rm.fd, .FLUSH, rm.saved) catch {};
}

/// Query the window size via TIOCGWINSZ. Falls back to 80x24 when the
/// ioctl fails (e.g. detached from a tty).
pub fn size() Size {
    var ws: std.posix.winsize = undefined;
    const rc = ioctlWinsize(std.posix.STDIN_FILENO, &ws);
    if (rc) {
        if (ws.col > 0 and ws.row > 0) {
            return .{ .width = ws.col, .height = ws.row };
        }
    }
    return .{ .width = 80, .height = 24 };
}

// --- ioctl plumbing
// --------------------------------------------------------- Zig 0.16 exposes
// no portable posix.ioctl; use the libc varargs extern on every platform that

fn ioctlWinsize(fd: std.posix.fd_t, ws: *std.posix.winsize) bool {
    const TIOCGWINSZ: c_int = switch (@import("builtin").os.tag) {
        .linux => 0x5413, // std.os.linux.T.IOCGWINSZ
        .macos => 0x40087468,
        .freebsd => 0x40087468,
        else => return false,
    };
    const rc = std.c.ioctl(fd, TIOCGWINSZ, @intFromPtr(ws));
    return rc == 0;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "size: falls back to 80x24 without a tty" {
    // In CI/test environments stdin may or may not be a tty; either way
    // this must not crash and must return plausible dimensions.
    const s = size();
    try testing.expect(s.width >= 1);
    try testing.expect(s.height >= 1);
}

test "isTty: does not crash in test env" {
    _ = isTty();
}
