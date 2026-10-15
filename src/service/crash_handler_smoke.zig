// src/service/crash_handler_smoke.zig Tiny standalone binary that exercises
// src/service/crash_handler.zig end-to-end.

const std = @import("std");
const builtin = @import("builtin");
const pabrikcore = @import("pabrikcore");
const helpers = @import("helpers");

/// This file is the ROOT of the standalone smoke build, so it is also the
/// only place in the test suite where `pub const debug` is actually
/// *compiled* rather than grepped for.
pub const debug = pabrikcore.crash_handler.root_debug;

/// Runtime-opaque base so the compiler cannot prove the load is safe and fold
/// it to `undefined` (a comptime-known address turns the "crash" into a no-op
/// — see the 2026-09-30 iteration where the first attempt at this file exited
var wild_base: usize = 0xdead_0000;

/// The function that must appear in the captured stack trace. Its name
/// is the assertion: the report is only useful if it names the frame
/// that actually faulted, not the frame that wrote the report.
fn crashSiteTarget() void {
    const addr = wild_base + 0x1000;
    const p: *volatile u8 = @ptrFromInt(addr);
    std.debug.print("[smoke] about to read *0x{x}\n", .{addr});
    _ = p.*;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // skip argv[0]
    const log_path_arg: []const u8 = args_iter.next() orelse "/tmp/crash_handler_smoke.log";
    const signal_arg: []const u8 = args_iter.next() orelse "SEGV";

    // Use the production crash_handler module — this is what we're verifying.
    pabrikcore.crash_handler.setCrashLogPath(log_path_arg);
    pabrikcore.crash_handler.installCrashHandlers();

    // Give the signal handler a moment to be installed before we trip it. On
    // POSIX, `helpers.nanosleep` (libc `nanosleep` exposed via `extern "c"`)
    // is the standard async-safe delay.
    if (builtin.os.tag != .windows) {
        var ts: helpers.PosixTimespec = .{ .sec = 0, .nsec = 50_000_000 };
        _ = helpers.nanosleep(&ts, null);
    }

    std.debug.print("[smoke] crash_handler installed for log='{s}'; triggering {s}\n", .{ log_path_arg, signal_arg });

    // A real hardware fault through a known call chain.
    if (std.mem.eql(u8, signal_arg, "FAULT")) {
        std.debug.print("[smoke] dereferencing a wild pointer in crashSiteTarget\n", .{});
        crashSiteTarget();
        std.debug.print("[smoke] FAIL: wild load returned (address was mapped?)\n", .{});
        return error.NoFault;
    }

    // Trigger the requested signal via raise() so the kernel delivers
    // it to our handler. BUS is not defined on Windows (no SIGBUS in
    // MSVC's libc); the test runner skips BUS on Windows.
    if (std.mem.eql(u8, signal_arg, "SEGV")) {
        _ = std.c.raise(std.c.SIG.SEGV);
    } else if (std.mem.eql(u8, signal_arg, "ABRT")) {
        _ = std.c.raise(std.c.SIG.ABRT);
    } else if (std.mem.eql(u8, signal_arg, "BUS")) {
        if (builtin.os.tag == .windows) {
            std.debug.print("[smoke] BUS skipped on Windows (no SIGBUS)\n", .{});
            return;
        }
        _ = std.c.raise(std.c.SIG.BUS);
    } else if (std.mem.eql(u8, signal_arg, "ILL")) {
        _ = std.c.raise(std.c.SIG.ILL);
    } else if (std.mem.eql(u8, signal_arg, "FPE")) {
        _ = std.c.raise(std.c.SIG.FPE);
    } else {
        std.debug.print("[smoke] unknown signal '{s}'\n", .{signal_arg});
        return error.UnknownSignal;
    }

    // raise() returned. If we reach this line, the handler swallowed
    // the signal instead of re-raising — that's a regression.
    std.debug.print("[smoke] FAIL: signal handler swallowed the signal — handler must re-raise\n", .{});
    return error.SignalSwallowed;
}