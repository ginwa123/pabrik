//! Cross-platform process management helpers. Provides portable wrappers
//! around the platform-specific APIs for checking process existence, sending
//! signals, and terminating processes.

const std = @import("std");
const builtin = @import("builtin");

/// Returns true if a process with the given PID exists and is accessible.
pub fn isProcessRunning(pid: i32) bool {
    if (pid <= 0) return false;

    return switch (builtin.os.tag) {
        .linux, .macos => isProcessRunningPosix(pid),
        .windows => isProcessRunningWindows(pid),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn isProcessRunningPosix(pid: i32) bool {
    // kill(pid, 0) is a no-op signal that just checks if we can signal the
    // process.
    const result = std.c.kill(@intCast(pid), @as(std.c.SIG, @enumFromInt(0)));
    if (result == 0) return true;
    // EPERM: process exists but we can't signal it. Still "running".
    const err = std.c.errno(result);
    return err == .PERM;
}

fn isProcessRunningWindows(pid: i32) bool {
    // PROCESS_QUERY_LIMITED_INFORMATION (0x1000) is the minimum access needed
    // to check if a process exists and read a few properties.
    // bInheritHandle=FALSE (0).
    const handle = OpenProcess(WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION, 0, @intCast(pid));
    if (handle == null) return false;
    _ = CloseHandle(handle.?);
    return true;
}

/// Forcefully terminates a process with the given PID. On Linux/macOS, sends
/// SIGKILL (signal 9) which cannot be caught or ignored by the target
/// process.
pub fn killProcess(pid: i32) bool {
    if (pid <= 0) return false;

    return switch (builtin.os.tag) {
        .linux, .macos => killProcessPosix(pid),
        .windows => killProcessWindows(pid),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

fn killProcessPosix(pid: i32) bool {
    // SIGKILL = 9. Cannot be caught/ignored/blocked.
    const result = std.c.kill(@intCast(pid), @as(std.c.SIG, @enumFromInt(9)));
    return result == 0;
}

fn killProcessWindows(pid: i32) bool {
    // OpenProcess returns NULL if PID doesn't exist or we don't have access.
    const handle = OpenProcess(WINDOWS_PROCESS_TERMINATE, 0, @intCast(pid));
    if (handle == null) return false;
    // TerminateProcess returns nonzero on success, 0 on failure.
    const ok = TerminateProcess(handle.?, 1) != 0;
    _ = CloseHandle(handle.?);
    return ok;
}

/// Returns the current process's PID as an `i32`. On POSIX, returns
/// `getpid()`.
pub fn getCurrentProcessIdInt() i32 {
    return switch (builtin.os.tag) {
        // POSIX: std.c.getpid returns pid_t = i32. The cast is a no-op.
        .linux, .macos => @intCast(std.c.getpid()),
        // Windows: std.c.pid_t is *anyopaque (Windows libc has no real pid_t).
        // Use the Win32 GetCurrentProcessId() which returns DWORD = u32.
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @compileError("process_status: unsupported platform " ++ @tagName(builtin.os.tag)),
    };
}

// === Windows-only API declarations === These live in kernel32.dll which is
// part of the default Windows API set — Zig auto-links it.

const WINDOWS_PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const WINDOWS_PROCESS_TERMINATE: u32 = 0x0001;

extern "c" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: u32, dwProcessId: u32) ?*anyopaque;
extern "c" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) i32;
extern "c" fn CloseHandle(hObject: *anyopaque) i32;

// === Tests ===

test "isProcessRunning: current process is always running" {
    const self_pid = getCurrentProcessIdInt();
    try std.testing.expect(isProcessRunning(self_pid));
}

test "isProcessRunning: pid 0 is invalid" {
    try std.testing.expect(!isProcessRunning(0));
}

test "isProcessRunning: negative pid is invalid" {
    try std.testing.expect(!isProcessRunning(-1));
}

test "isProcessRunning: extremely high pid doesn't exist" {
    // Real PIDs rarely exceed 2^22. Use 2^30 to be safe on all platforms.
    try std.testing.expect(!isProcessRunning(1 << 30));
}

test "killProcess: pid 0 is invalid" {
    try std.testing.expect(!killProcess(0));
}

test "killProcess: negative pid is invalid" {
    try std.testing.expect(!killProcess(-1));
}

test "killProcess: extremely high pid doesn't exist" {
    try std.testing.expect(!killProcess(1 << 30));
}

test "getCurrentProcessIdInt returns positive int" {
    const pid = getCurrentProcessIdInt();
    try std.testing.expect(pid > 0);
}
