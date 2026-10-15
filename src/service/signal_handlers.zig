// src/service/signal_handlers.zig Signal handlers for the pabrik service
// daemon. ## POSIX (Linux/macOS) Installs a SIGTERM handler that fires the
// registered shutdown callback.

const std = @import("std");
const builtin = @import("builtin");

/// Type of callback fired by the SIGTERM/console-ctrl handler.
pub const ShutdownCallback = *const fn () void;

// Module-level storage for the registered callback. There's only ever
// one shutdown handler per process, so a single global is sufficient.
var global_callback: ?ShutdownCallback = null;

// Counts received shutdown signals. The first SIGINT/SIGTERM runs the
// graceful callback (close listener, drain, stop workers).
var shutdown_signal_count: std.atomic.Value(u8) = .init(0);

// =============================================================================
// POSIX signal handler
// =============================================================================

// C calling convention is required so the kernel can invoke us as a signal
// handler.
fn handle_shutdown_signal(_: std.c.SIG) callconv(.c) void {
    const count = shutdown_signal_count.fetchAdd(1, .seq_cst);
    if (count >= 1) {
        // Second signal while graceful shutdown is already running:
        // force-exit so a stuck drain can't trap the process.
        std.process.exit(130);
    }
    if (global_callback) |cb| cb();
}

// Kept for the old name — same handler, now shared by SIGTERM+SIGINT.
fn handle_sigterm(sig: std.c.SIG) callconv(.c) void {
    handle_shutdown_signal(sig);
}

// =============================================================================
// Windows console-ctrl handler
// =============================================================================

// Compile-time-gated Win32 bindings. On POSIX this struct is materialised
// as empty (struct {}) so the extern decls are never visible to the
// linker and won't cause "undefined symbol" errors.
const win32_apis = if (builtin.os.tag == .windows) struct {
    const BOOL_TRUE: u32 = 1;
    const BOOL_FALSE: u32 = 0;

    // Console ctrl event types. dwCtrlType parameter to HandlerRoutine.
    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;
    const CTRL_CLOSE_EVENT: u32 = 2;
    const CTRL_LOGOFF_EVENT: u32 = 5;
    const CTRL_SHUTDOWN_EVENT: u32 = 6;

    // SetConsoleCtrlHandler HandlerRoutine callback. Returns BOOL (u32)
    // nonzero = "we handled the signal — do NOT call the default handler".
    const HandlerRoutine = *const fn (dwCtrlType: u32) callconv(.winapi) u32;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handlerRoutine: ?HandlerRoutine,
        add: u32,
    ) callconv(.winapi) u32;
} else struct {};

/// The console-ctrl handler is invoked by the kernel via
/// `SetConsoleCtrlHandler`.
fn handle_console_ctrl(dwCtrlType: u32) callconv(.winapi) u32 {
    _ = dwCtrlType; // we don't differentiate — every ctrl event = "shut down gracefully"
    const count = shutdown_signal_count.fetchAdd(1, .seq_cst);
    if (count >= 1) std.process.exit(130);
    if (global_callback) |cb| cb();
    return win32_apis.BOOL_TRUE;
}

// =============================================================================
// Public cross-platform entry point
// =============================================================================

/// Install a SIGTERM-equivalent handler that invokes `callback`.
pub fn installSigtermHandler(callback: ShutdownCallback) void {
    global_callback = callback;
    // Reset the two-hit counter so reinstalling (tests, restarts)
    // starts from a clean first-signal state.
    shutdown_signal_count.store(0, .seq_cst);
    switch (builtin.os.tag) {
        .linux, .macos => installShutdownHandlersPosix(),
        .windows => installSigtermHandlerWindows(),
        else => @compileError("signal_handlers.installSigtermHandler: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

/// Preferred alias — same as `installSigtermHandler`, named for what it
/// does (graceful shutdown on SIGINT+SIGTERM / console-ctrl).
pub const installShutdownHandlers = installSigtermHandler;

/// Reset test-only state (callback + signal counter) without touching
/// the installed sigactions. Unit tests call this between cases so one
/// test's SIGINT doesn't trip the next test's two-hit force-exit.
pub fn resetForTests() void {
    global_callback = null;
    shutdown_signal_count.store(0, .seq_cst);
}

fn installShutdownHandlersPosix() void {
    // std.posix.sigaction expects std.c.Sigaction (the libc struct).
    var sa: std.c.Sigaction = .{
        .handler = .{ .handler = handle_shutdown_signal },
        .mask = std.mem.zeroes(std.c.sigset_t),
        .flags = std.c.SA.RESTART,
    };
    // std.posix.sigaction returns void in Zig 0.16 — do NOT wrap in try. The
    // 2nd arg is `?*const Sigaction`; we have a mutable pointer.
    std.posix.sigaction(std.c.SIG.TERM, &sa, null);
    std.posix.sigaction(std.c.SIG.INT, &sa, null);
}

fn installSigtermHandlerWindows() void {
    // Register handle_console_ctrl as a console-ctrl-handler. add=TRUE means
    // "install"; the routine will receive CTRL_C_EVENT, CTRL_BREAK_EVENT,
    // CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT.
    _ = win32_apis.SetConsoleCtrlHandler(handle_console_ctrl, 1);
}

// ===== Tests merged from signal_handlers_test.zig (2026-09-29 flatten) =====

// Tests for src/service/signal_handlers.zig. ## POSIX test Installs the
// SIGTERM handler, sends SIGTERM to ourselves, and verifies the callback
// fires. ## Windows test `SetConsoleCtrlHandler` registers a HandlerRoutine

const testing = std.testing;

// Module-level atomic for the test callback to set. Using std.atomic.Value
// ensures the compiler doesn't optimize away the read in the assertion.
var callback_fired: std.atomic.Value(bool) = .init(false);

fn testCallback() void {
    callback_fired.store(true, .release);
}

test "installSigtermHandler is callable cross-platform" {
    // Static contract: just taking the address must compile on every
    // platform. If the function throws @compileError on Windows (or any
    // target), this fails to compile.
    const function_pointer = &installSigtermHandler;
    _ = function_pointer;
    try testing.expect(true);
}

test "POSIX SIGTERM handler triggers callback" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    resetForTests();
    callback_fired.store(false, .release);
    installSigtermHandler(testCallback);

    // Send SIGTERM to ourselves.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.TERM);

    // Give the handler a chance to run. Zig 0.16 removed std.posix.nanosleep;
    // use libc's nanosleep directly via std.c.
    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    resetForTests();
}

test "POSIX SIGINT handler triggers callback (Ctrl+C graceful shutdown)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    resetForTests();
    callback_fired.store(false, .release);
    installShutdownHandlers(testCallback);

    // Send SIGINT to ourselves — the foreground Ctrl+C path.
    _ = std.c.kill(std.c.getpid(), std.c.SIG.INT);

    var ts = std.posix.timespec{ .sec = 0, .nsec = 100_000_000 };
    _ = std.c.nanosleep(&ts, null);

    try testing.expect(callback_fired.load(.acquire));
    resetForTests();
}
