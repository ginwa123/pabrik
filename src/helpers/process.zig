//! Process-related helper functions

const std = @import("std");
const builtin = @import("builtin");

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

/// Cross-platform process ID getter. **Returns `i32` directly** (not
/// `std.c.pid_t`) so the value can be compared to `i32` parsed from shell
/// commands (e.g.
pub fn getCurrentProcessId() i32 {
    return switch (builtin.os.tag) {
        // POSIX: std.c.getpid returns pid_t = i32. The cast is a no-op.
        .linux, .macos => @intCast(std.c.getpid()),
        // Windows: std.c.pid_t is *anyopaque (Windows libc has no real
        // pid_t). Use the Win32 GetCurrentProcessId() which returns
        // DWORD = u32.
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError("process: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}