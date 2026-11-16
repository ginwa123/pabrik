//! Process-related helper functions

const std = @import("std");
const builtin = @import("builtin");

/// Hex digits for ID generation
pub const hex_digits = "0123456789abcdef";

/// Cross-platform process ID getter.
pub fn getCurrentProcessId() i32 {
    return switch (builtin.os.tag) {
        // POSIX: std.c.getpid returns pid_t = i32. The cast is a no-op.
        .linux, .macos => @intCast(std.c.getpid()),
        // Windows: std.c.pid_t is *anyopaque (Windows libc has no real pid_t).
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError("process: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}