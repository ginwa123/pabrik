// SPDX-License-Identifier: TBD
// shell.zig — shared shell-execution core used by `bash.zig` and `pwsh.zig`.
//
// This module owns the parts of the shell-tool pipeline that are SHELL-NEUTRAL:
//   * the wire schema (`ShellInput` / `ShellOutput`) — `BashInput` / `BashOutput`
//     and `PwshInput` / `PwshOutput` are type aliases so the LLM-facing JSON
//     schema cannot drift between shells
//   * the spawn + reader-thread + byte-truncation + line-count pipeline
//   * the mandatory-timeout enforcement
//   * the background-detach path (currently bash's `nohup` idiom)
//   * the URL-encoding step (swaps `"…"` → `'…'` around URLs to keep both
//     bash and PowerShell from interpreting `?` / `&` as wildcards)
//   * the JSON serialisation of `ShellOutput` to the LLM-facing envelope
//
// Shell-SPECIFIC code (executable name, argv-prefix, Windows availability)
// lives in the per-shell wrappers (bash.zig, pwsh.zig). The two wrappers
// are ~80 lines each and supply ONLY:
//   * `ShellInput` is the input type — already aliased to bash / pwsh
//   * the argv-prefix (e.g. `&.{ "bash", "-c" }` or
//     `&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command" }`)
//   * the bash/pwsh-specific `AgentTool` schema (tool name, description,
//     example commands)
//
// Cross-platform: shell.zig is POSIX-only because the process-group SIGKILL
// `std.posix.kill(-pgid, .KILL)` + `.pgid = 0` field on `std.process.Child`
// are POSIX-only primitives. The Windows guard for `bash` lives in the
// bash.zig wrapper (`if (builtin.os.tag == .windows) return error.UnsupportedOS;`).
// pwsh is NOT guarded at the wrapper — PowerShell Core ships preinstalled on
// Windows and pwsh on macOS / Linux via Homebrew / Microsoft's tarball. If
// pwsh is not on `$PATH`, the spawn fails with FileNotFound (the same shape
// of error bash gives on Windows today).

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const schemas = @import("schemas.zig");

const sanitizeControlChars = helpers.sanitize_control_chars;

/// Canonical wire schema. Per-shell wrappers (bash.zig, pwsh.zig) re-export
/// this as `BashInput` / `PwshInput` so the JSON contract is identical.
pub const ShellInput = struct {
    command: []const u8,
    mandatory_timeout: ?u32 = null,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 20 * 1024,
    stdin_data: ?[]const u8 = null,
    background: bool = false,
    max_lines: ?usize = 1000,
    do_encoding: bool = false,
};

pub const ShellOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
    stdout_lines: usize = 0,
    stderr_lines: usize = 0,
};

/// Returned by `execute_shell` when the caller omits `mandatory_timeout`.
/// Same semantics as the bash.zig version; shell-neutral.
pub const MandatoryTimeoutMissing = error{MandatoryTimeoutMissing};

/// Returned by `execute_shell` when the caller passes a `mandatory_timeout`
/// above `MAX_MANDATORY_TIMEOUT_SEC`. A huge deadline is the same as no
/// deadline — it lets a runaway command hang the agent until the outer
/// harness gives up. Reject explicitly so the caller splits the work
/// (smaller steps, `background=true`, or the functional harness).
pub const MandatoryTimeoutTooLarge = error{MandatoryTimeoutTooLarge};

/// Reasonable upper bound for a single foreground command: 10 minutes.
/// Covers the prompt's own guidance (a few seconds for ls/cat, 30–60 s
/// for builds, 300+ s for long compilations) with headroom, while turning
/// absurd values like 120000 (33 h) into an instant learnable error.
/// Background mode is exempt (it detaches and ignores the timeout by design).
pub const MAX_MANDATORY_TIMEOUT_SEC: u32 = 600;

// POSIX `nanosleep(req, rem)` — declared as `extern "c"` so the call
// doesn't go through Zig 0.16's Io runtime. We deliberately avoid
// `std.Io.sleep` here because shell.zig is invoked from the AI
// workflow, which itself runs as an `Io.Group` concurrent task. Blocking
// on `std.Io.sleep` inside that context would dead-lock the group.
// Plain `nanosleep` parks the OS thread without involving the Io runtime,
// so the rest of the group keeps making progress.
//
// Field names differ between libc implementations: glibc uses `tv_sec`/
// `tv_nsec`, Darwin and most BSDs use `sec`/`nsec`. We mirror the local
// `PosixTimespec` shape from helpers/mod.zig (sec/nsec) so this works
// on macOS too.
const NanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const NanoSleepTimespec, rem: ?*NanoSleepTimespec) c_int;

/// Sleep ~10ms between deadline polls.
///
/// Windows: Win32 Sleep via helpers.sleepMillis. Raw nanosleep's
/// timespec is LLP64-broken here — c_long is 32-bit while MinGW reads
/// 64-bit time_t, so {0, 10ms} is misread as a ~millions-of-years sleep
/// (same hang as search.zig's deadline poll hung `zig build test`).
/// POSIX: raw nanosleep, unchanged.
fn pollSleep10ms() void {
    if (builtin.os.tag == .windows) {
        helpers.sleepMillis(10);
    } else {
        const ts = NanoSleepTimespec{
            .sec = 0,
            .nsec = 10 * std.time.ns_per_ms,
        };
        _ = nanosleep(&ts, null);
    }
}

// Win32 GetExitCodeProcess — declared locally because std.os.windows
// 0.16 doesn't expose it (only the imports the stdlib's own files
// need). kernel32.dll is always linked on Windows.
extern "kernel32" fn GetExitCodeProcess(
    hProcess: std.os.windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) std.os.windows.BOOL;

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the spawned process group. 2 seconds is enough for
/// normal process groups to die and be reaped; D-state descendants
/// (uninterruptible sleep) cannot be killed by SIGKILL and will block
/// forever — the grace period caps the wait so we can return anyway.
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

// Sentinel stub — Task 1.1 only lands the SKELETON. Subsequent tasks
// (1.2–1.7) progressively move helpers and the spawn pipeline from
// bash.zig into this module. The execute_shell body is intentionally
// a NotImplemented error until Task 1.5 lands the foreground spawn.
/// Result of the bounded `waitpid` polling helper.
const WaitResult = struct {
    /// Outcome category.
    outcome: enum {
        /// Process was reaped within the grace period. The `status` field
        /// contains the raw waitpid status word.
        reaped,
        /// The grace period expired before the process became a zombie.
        /// The kernel could not reap the process — most commonly because
        /// a descendant is stuck in D state (uninterruptible sleep on
        /// Linux, e.g. broken NFS, hung FUSE, stuck disk I/O) and SIGKILL
        /// cannot interrupt it. The parent-side pipe FDs MUST be closed
        /// manually before returning so the reader threads can exit.
        grace_period_expired,
        /// `waitpid` returned ECHILD — no such process. Either the PID
        /// never existed or was already reaped by a different waiter
        /// (e.g. SIGCHLD handler). Treat as "successfully reaped".
        no_child,
        /// `waitpid` returned an unexpected error. Caller should log and
        /// proceed as if the grace period expired.
        unexpected_error,
    },
    /// Raw waitpid status word (only valid when `outcome == .reaped`).
    status: c_int = 0,
};

/// Poll `waitpid(pid, &status, WNOHANG)` until the process is reaped OR
/// the grace period expires. Uses raw libc (`waitpid` + `nanosleep`)
/// instead of the Io runtime to avoid the deadlock that
/// `std.Io.Threaded.childWait` causes when this function is called from
/// an `Io.Group` worker context (the workflow task blocks the group).
///
/// Does NOT close pipe FDs — the caller is responsible for that AFTER
/// this function returns, so the reader threads can exit cleanly.
///
/// Cross-platform: uses `std.os.linux.waitpid` directly on POSIX (Linux
/// + macOS via the Darwin kernel-call wrappers), and `WaitForSingleObject`
/// via `std.os.windows` on Windows. The `pid` argument is whatever
/// `child.id.?` produces (`std.posix.pid_t` on POSIX, `HANDLE` on
/// Windows) — we pass it through to the right syscall for each host.
pub fn wait_pid_bounded(
    io: std.Io,
    child: *const std.process.Child,
    grace_period_ns: u64,
) WaitResult {
    const start_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const deadline_ns: u64 = start_ns + grace_period_ns;
    return switch (builtin.os.tag) {
        .linux, .macos => wait_pid_boundedPosix(child, deadline_ns),
        .windows => wait_pid_boundedWindows(io, child, deadline_ns),
        else => .{ .outcome = .grace_period_expired, .status = 0 },
    };
}

fn wait_pid_boundedPosix(child: *const std.process.Child, deadline_ns: u64) WaitResult {
    // `posix.pid_t` is `void` on Windows — Zig 0.16 resolves the
    // type on every host even inside a body that's only called from
    // POSIX-gated callers, so we can't reference `posix.pid_t`
    // here at all. Cast through `c_int` (the POSIX `pid_t` is a
    // 32-bit signed integer on every supported POSIX host), and
    // cast `child.id.?` (Windows HANDLE / POSIX pid_t) back to
    // `c_int` via the `Id` switch — `Id = std.posix.pid_t` on POSIX
    // (`c_int` on Linux x86_64 / aarch64 / macOS), so the cast is
    // a no-op at runtime.
    const pid: c_int = blk: {
        const id_opt: std.process.Child.Id = child.id.?;
        const T = @TypeOf(id_opt);
        if (@typeInfo(T) == .int) {
            break :blk @as(c_int, @intCast(id_opt));
        }
        // Non-int Id is `HANDLE` (Windows). Unreachable at runtime
        // because callers gate this fn on `.linux, .macos =>`,
        // but emit a clear compile-time error if someone ever
        // removes that gate.
        @compileError("wait_pid_boundedPosix called on a non-POSIX host");
    };
    while (true) {
        var status: c_int = 0;
        // WNOHANG = 1: don't block; return 0 if not exited yet.
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            return .{ .outcome = .reaped, .status = status };
        }
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .CHILD) return .{ .outcome = .no_child, .status = 0 };
            std.log.warn(
                "shell.zig: waitpid(pid={d}) returned unexpected errno {t}; abandoning wait",
                .{ pid, err },
            );
            return .{ .outcome = .unexpected_error, .status = 0 };
        }
        // rc == 0 → child not yet exited. Check the deadline.
        if (helpers.monotonicTimestampNanos() >= deadline_ns) {
            return .{ .outcome = .grace_period_expired, .status = 0 };
        }
        pollSleep10ms();
    }
}

fn wait_pid_boundedWindows(
    io: std.Io,
    child: *const std.process.Child,
    deadline_ns: u64,
) WaitResult {
    const handle: std.os.windows.HANDLE = child.id.?;
    // Poll NtWaitForSingleObject with a short timeout until the
    // deadline. The `STATUS_TIMEOUT` constant is at 0x00000102;
    // compare the returned NTSTATUS by value because Zig 0.16 doesn't
    // expose kernel32's WaitForSingleObject via std.os.windows on
    // this platform — ntdll is the wrapper layer that exposes it.
    while (true) {
        // 100ms relative timeout (NT's LARGE_INTEGER is `i64` — for
        // relative waits, the convention is a NEGATIVE 100-ns interval;
        // positive values are interpreted as an absolute wakeup time,
        // which we'd rather avoid in a poll loop). Zig 0.16 typed
        // `LARGE_INTEGER` as a plain `i64` alias (`pub const
        // LARGE_INTEGER = i64` in `std/os/windows.zig:4040`), so we
        // just use the value directly.
        const timeout_100ms: std.os.windows.LARGE_INTEGER =
            -100 * @as(i64, @intCast(std.time.ns_per_ms));
        const status = std.os.windows.ntdll.NtWaitForSingleObject(
            handle,
            std.os.windows.BOOLEAN.fromBool(false), // Alertable = FALSE
            &timeout_100ms,
        );
        if (status == .SUCCESS) {
            // Process signalled; harvest the exit code via
            // GetExitCodeProcess (declared above; not in Zig 0.16
            // std) so the .status slot has the same shape the POSIX
            // path produces.
            var exit_code: u32 = 0;
            _ = GetExitCodeProcess(handle, &exit_code);
            // Match std.process.Child.Term's `exited: u8` slot:
            // (status << 8) | exit_code mimics WIFEXITED.
            const shifted_status: c_int = @intCast(@as(c_int, 0) << 8);
            const low_byte: c_int = @intCast(@as(c_int, @intCast(exit_code & 0xff)));
            return .{ .outcome = .reaped, .status = shifted_status | low_byte };
        }
        if (status != .TIMEOUT) {
            std.log.warn(
                "shell.zig: NtWaitForSingleObject(handle={*}) returned unexpected NTSTATUS {x}; abandoning wait",
                .{ handle, @intFromEnum(status) },
            );
            return .{ .outcome = .unexpected_error, .status = 0 };
        }
        if (helpers.monotonicTimestampNanos() >= deadline_ns) {
            return .{ .outcome = .grace_period_expired, .status = 0 };
        }
        _ = io;
    }
}

/// Convert a `WaitResult` to a `std.process.Child.Term`. Cross-platform:
/// on POSIX, `status_to_term` decodes the waitpid status word via
/// `std.c.W.*` macros (all `-= std.c.IFEXITED/EXITSTATUS/IFSIGNALED/...`
/// on Windows since `std.c.W = void` there). On Windows, the helper
/// just pops the low byte of the synthesized status word (matches the
/// `WaitForSingleObject + GetExitCodeProcess` flow in
/// `wait_pid_boundedWindows`).
fn term_from_wait(wait_result: WaitResult) std.process.Child.Term {
    return switch (builtin.os.tag) {
        .windows => term_from_wait_windows(wait_result),
        else => term_from_wait_posix(wait_result),
    };
}

fn term_from_wait_windows(wait_result: WaitResult) std.process.Child.Term {
    // The Windows path synthesizes a status with the low 8 bits
    // holding the exit code (no `posix.SIG.KILL` representation — the
    // historical `.signal = .KILL` doesn't apply on Windows). Wrap
    // a synthetic "signal value" by stuffing the exit code into a
    // u8 and assigning to .exited; if the high bit indicates
    // abnormal termination by an enum-from-int cast we still surface
    // it via `.unknown` (callers can introspect via `child.wait()`
    // separately).
    const u: u32 = @bitCast(@as(u32, @intCast(wait_result.status)));
    _ = u;
    return switch (wait_result.outcome) {
        .reaped, .no_child => .{ .exited = @intCast(wait_result.status & 0xff) },
        .grace_period_expired, .unexpected_error => .{
            // Forced kill via TerminateProcess. There's no POSIX
            // signal mapping on Windows; surface as
            // `exited = STATUS_TIMEOUT` (0xC000_FFFF magic trimmed)
            // or, more conservatively, as 255 (typical bash "$?")
            // so downstream tools see "killed" but don't trip the
            // "exited cleanly" path in callers.
            .exited = 137, // 128 + SIGKILL = 128+9, the bash
            // convention for "killed by SIGKILL". Portable across
            // POSIX callers that recognize this magic.
        },
    };
}

fn term_from_wait_posix(wait_result: WaitResult) std.process.Child.Term {
    return switch (wait_result.outcome) {
        .reaped => status_to_term(wait_result.status),
        .no_child => .{ .exited = 0 },
        .grace_period_expired, .unexpected_error => if (comptime builtin.os.tag != .windows)
            // POSIX path: surface the kill via `posix.SIG.KILL`. The
            // `.signal = ...` arm isn't reachable on Windows (where
            // `posix.SIG` is `void`), but Zig 0.16 resolves the arm
            // anyway — we guard with `comptime` so the resolve arm
            // is elided on Windows.
            .{ .signal = .KILL }
        else
            // Windows path (this `else` arm is unreachable at
            // runtime because `term_from_wait` dispatches on
            // `builtin.os.tag` first); included only so the
            // function compiles on every host.
            .{ .exited = 137 },
    };
}

/// Convert a raw `waitpid` status word to a Zig `std.process.Child.Term`.
/// Mirrors `childWaitPosix` in `std/Io/Threaded.zig:15309`.
///
/// POSIX-only: `std.c.W = void` on Windows (Zig 0.16 — `posix.SIG`
/// resolves to `void` there, and the `WAIT_OBJECT_0` / `WNOHANG` /
/// `IFEXITED` / `W.IFEXITED` macros aren't reachable). The Windows
/// wait path goes through `term_from_wait_windows` directly.
/// Marked `pub` so callers in the POSIX-only shell tests can use it.
pub fn status_to_term(status: c_int) std.process.Child.Term {
    if (comptime builtin.os.tag == .windows) {
        // Unreachable at runtime — emitted as a no-op so the
        // package compiles on every host. The Windows path
        // extracts the exit code directly via GetExitCodeProcess
        // (see `term_from_wait_windows`).
        return .{ .unknown = 0 };
    }
    const u: u32 = @bitCast(@as(u32, @intCast(status)));
    if (std.c.W.IFEXITED(u)) return .{ .exited = std.c.W.EXITSTATUS(u) };
    if (std.c.W.IFSIGNALED(u)) return .{ .signal = @enumFromInt(@intFromEnum(std.c.W.TERMSIG(u))) };
    if (std.c.W.IFSTOPPED(u)) return .{ .stopped = std.c.W.STOPSIG(u) };
    return .{ .unknown = u };
}

pub fn execute_shell(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: ShellInput,
) !ShellOutput {
    return run_shell_command(allocator, io, argv_prefix, input);
}

/// Run a shell command with the supplied argv-prefix (e.g. `&.{ "bash", "-c" }`
/// or `&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command" }`). The user's
/// `command` string is appended as the last argv element. This is the
/// SHELL-NEUTRAL spawn pipeline — moved verbatim from bash.zig (Tasks
/// 1.5–1.7 of the 2026-08-14-pwsh-tool plan). Background mode is split
/// into a separate `spawn_background` helper for the nohup-vs-Start-Process
/// divergence (D8 in the plan).
pub fn run_shell_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: ShellInput,
) !ShellOutput {
    // --- URL encoding if requested ---
    // cmd.exe treats single quotes literally (no quoting semantics), so the
    // `"…"` → `'…'` swap would corrupt URLs on the cmd fallback path — skip
    // it when the resolved shell is cmd. Detected via argv_prefix so the
    // kill/reader logic stays shared (no fork).
    const is_cmd_shell = argv_prefix.len > 0 and std.mem.eql(u8, argv_prefix[0], "cmd.exe");
    const command = if (input.do_encoding and !is_cmd_shell)
        try encode_command_urls(allocator, input.command)
    else
        try allocator.dupe(u8, input.command);
    defer allocator.free(command);

    // --- Forbidden pattern check ---
    if (is_forbidden_command(command)) {
        return error.CommandForbidden;
    }

    // --- Mandatory-timeout check (foreground only) ---
    // The background path does not use the timeout (the process detaches
    // and runs forever), so we skip the check there. But the foreground
    // path MUST have an explicit deadline — the previous design defaulted
    // to 30 s which silently masked runaway commands.
    if (!input.background and input.mandatory_timeout == null) {
        return error.MandatoryTimeoutMissing;
    }
    if (input.mandatory_timeout) |t| {
        if (t == 0) return error.MandatoryTimeoutMissing;
        // Foreground only: the background path detaches and ignores the
        // timeout by design, so an over-max deadline there is harmless.
        // In foreground a huge deadline is the same as no deadline.
        if (!input.background and t > MAX_MANDATORY_TIMEOUT_SEC) {
            return error.MandatoryTimeoutTooLarge;
        }
    }

    // --- Background mode ---
    if (input.background) {
        return try spawn_background(allocator, io, argv_prefix, command);
    }

    // --- Foreground mode ---
    // `input.max_output` defaults to 20 KiB in the schema (see schemas.zig),
    // so the `orelse` fallback here is a defense-in-depth — it would only
    // fire if someone constructs ShellInput programmatically without going
    // through the JSON schema (e.g. tests, internal callers).
    const max_output = input.max_output orelse 20 * 1024;
    const max_lines = input.max_lines orelse 1000;
    const timeout_sec = input.mandatory_timeout.?;

    // Build the full argv: argv_prefix ++ [command]
    var argv_buf: [16][]const u8 = undefined;
    if (argv_prefix.len + 1 > argv_buf.len) {
        return error.TooManyArgvPrefix;
    }
    @memcpy(argv_buf[0..argv_prefix.len], argv_prefix);
    argv_buf[argv_prefix.len] = command;
    const argv = argv_buf[0 .. argv_prefix.len + 1];

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (input.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        // Zig 0.16: `?posix.pid_t = null`. On Windows, `posix.pid_t`
        // resolves to `void`, so the ternary `null / @as(?pid_t, 0)`
        // can't infer a unified type (the Windows branch is
        // `?*anyopaque` from the void-typed pid_t). Use comptime
        // branches so Zig 0.16 emits only the relevant arm:
        //   POSIX: place the child in a new pgroup whose pgid equals
        //          its own pid (preserves the historical "kill the
        //          whole group" semantics below).
        //   Windows: pass null (no pgid concept; group-kill branch
        //          below is gated anyway).
        .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
    });
    // On Windows, `posix.pid_t` is `void` (Windows has no POSIX pid
    // concept), so the historical `kill(-child_pgid, .KILL)` group-
    // kill pattern compiles only on POSIX. Gate the group-kill path
    // by host OS: Windows children use the .id HANDLE directly via
    // `child.kill(io)` (in the cleanup branches below — no group-kill
    // because Windows has no `setpgid(0)` equivalent). `wait_pid_bounded`
    // is now OS-dispatched (see its `switch (builtin.os.tag)` body).
    const child_pgid: c_int = blk: {
        if (comptime builtin.os.tag == .windows) break :blk 0;
        const id_opt: std.process.Child.Id = child.id.?;
        const T = @TypeOf(id_opt);
        if (@typeInfo(T) == .int) break :blk @as(c_int, @intCast(id_opt));
        @compileError("child.id is not a POSIX pid_t on a POSIX host");
    };
    errdefer {
        if (builtin.os.tag != .windows) {
            _ = std.posix.kill(-child_pgid, .KILL) catch {};
        }
        _ = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
        if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
        if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
        if (child.stdin) |stdin_pipe| stdin_pipe.close(io);
    }

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            var write_buf: [1024]u8 = undefined;
            var stdin_writer = std.Io.File.writer(stdin, io, &write_buf);
            try stdin_writer.interface.writeAll(data);
            stdin.close(io);
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;

    var stdout_data: std.ArrayList(u8) = .empty;
    var stderr_data: std.ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    var stdout_truncated = false;
    var stderr_truncated = false;
    var stdout_eof = std.atomic.Value(bool).init(false);
    var stderr_eof = std.atomic.Value(bool).init(false);
    var stdout_mutex: std.atomic.Mutex = .unlocked;
    var stderr_mutex: std.atomic.Mutex = .unlocked;

    const ReadContext = struct {
        stream: std.Io.File,
        io: std.Io,
        buf: *[4096]u8,
        data: *std.ArrayList(u8),
        line_count: *usize,
        truncated: *bool,
        max_output: usize,
        max_lines: usize,
        eof_flag: *std.atomic.Value(bool),
        mutex: *std.atomic.Mutex,
        allocator: std.mem.Allocator,
    };

    const readLoopFn = struct {
        fn run(ctx: ReadContext) void {
            defer ctx.eof_flag.store(true, .release);
            while (true) {
                const n = std.Io.File.readStreaming(ctx.stream, ctx.io, &.{ctx.buf}) catch return;
                if (n == 0) return;
                for (ctx.buf[0..n]) |byte| {
                    if (byte == '\n') ctx.line_count.* += 1;
                }
                if (!ctx.truncated.*) {
                    while (!ctx.mutex.tryLock()) {
                        std.atomic.spinLoopHint();
                    }
                    defer ctx.mutex.unlock();
                    ctx.data.appendSlice(ctx.allocator, ctx.buf[0..n]) catch return;
                    if (ctx.data.items.len >= ctx.max_output or ctx.line_count.* >= ctx.max_lines) {
                        ctx.truncated.* = true;
                        var trim_pos: usize = ctx.data.items.len;
                        if (ctx.line_count.* >= ctx.max_lines) {
                            var count: usize = 0;
                            for (ctx.data.items, 0..) |b, i| {
                                if (b == '\n') {
                                    count += 1;
                                    if (count == ctx.max_lines) {
                                        trim_pos = i + 1;
                                        break;
                                    }
                                }
                            }
                        } else if (ctx.data.items.len > ctx.max_output) {
                            trim_pos = ctx.max_output;
                        }
                        if (ctx.data.items.len > trim_pos) {
                            ctx.data.shrinkAndFree(ctx.allocator, trim_pos);
                        }
                    }
                }
            }
        }
    }.run;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    const stdout_ctx = ReadContext{
        .stream = child.stdout.?,
        .io = io,
        .buf = &stdout_buf,
        .data = &stdout_data,
        .line_count = &stdout_line_count,
        .truncated = &stdout_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stdout_eof,
        .mutex = &stdout_mutex,
        .allocator = allocator,
    };
    const stderr_ctx = ReadContext{
        .stream = child.stderr.?,
        .io = io,
        .buf = &stderr_buf,
        .data = &stderr_data,
        .line_count = &stderr_line_count,
        .truncated = &stderr_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stderr_eof,
        .mutex = &stderr_mutex,
        .allocator = allocator,
    };

    const stdout_thread = try std.Thread.spawn(.{}, readLoopFn, .{stdout_ctx});
    const stderr_thread = try std.Thread.spawn(.{}, readLoopFn, .{stderr_ctx});
    // Join-gate (same as search.zig): explicit joins below run on the
    // happy path; any later `return error.X` fires this errdefer.
    // Double-join is UB — SIGABRT on macOS — so the flag makes the
    // errdefer a no-op once the explicit joins have run.
    var threads_joined = false;
    errdefer {
        if (!threads_joined) {
            if (comptime builtin.os.tag != .windows) _ = std.posix.kill(-child_pgid, .KILL) catch {};
            _ = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
            if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
            if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
            stdout_thread.join();
            stderr_thread.join();
        }
    }

    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    const deadline_ns = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i64, @intCast(timeout_ns));
    // `std.process.Child.Term` is `.{ exited: u8, signal: std.posix.SIG,
    // … }` — `posix.SIG` is `void` on Windows in Zig 0.16, so neither
    // `.signal = .KILL` nor `status_to_term` (which uses `std.c.W.*` —
    // also `void` on Windows) compile there. Gate the inner switch by
    // OS: the POSIX path produces the historical WIFEXITED /
    // WIFSIGNALED-style term, the Windows path just takes the DWORD
    // exit code we harvested in `wait_pid_boundedWindows`.
    child_term = blk: {
        while (true) {
            if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                if (comptime builtin.os.tag != .windows) _ = std.posix.kill(-child_pgid, .KILL) catch {};
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            pollSleep10ms();
        }
    };

    if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
    if (child.stderr) |stderr_pipe| stderr_pipe.close(io);

    stdout_thread.join();
    stderr_thread.join();
    threads_joined = true;
    if (child_term == null) {
        const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
        child_term = term_from_wait(wait_result);
    }

    const exit_code: i32 = switch (child_term.?) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
        .unknown => -1,
    };

    const stdout_truncation_needed = stdout_data.items.len > max_output;
    const stderr_truncation_needed = stderr_data.items.len > max_output;
    const was_truncated = stdout_truncated or stderr_truncated;

    const command_copy = try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else if (stdout_truncation_needed)
        try allocator.dupe(u8, stdout_data.items[0..max_output])
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else if (stderr_truncation_needed)
        try allocator.dupe(u8, stderr_data.items[0..max_output])
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);

    return ShellOutput{
        .command = command_copy,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
        .stdout_lines = stdout_line_count,
        .stderr_lines = stderr_line_count,
    };
}

/// Background-mode spawn (the `nohup` bash idiom). Returns the
/// structured ShellOutput with `command`, `stdout = "PID: X\nLog: …"`,
/// `exit_code = 0`. The detached process keeps running; the caller is
/// responsible for killing it later.
///
/// TODO (D8): PowerShell has no `nohup`. The follow-up PR replaces this
/// with `Start-Process -NoNewWindow -RedirectStandardOutput` for pwsh.
/// Platform-correct way to detach a command and capture its PID.
///
/// `nohup <cmd> > <log> 2>&1 & echo $!` is a POSIX shell idiom with no
/// PowerShell equivalent: handed to `pwsh -Command` it is a syntax error,
/// and its redirect target `/tmp/bg_*.log` does not exist on Windows
/// either. The old code sent it unconditionally, so every
/// `background: true` call on Windows failed.
///
/// `os_tag` is a parameter rather than a direct `builtin.os.tag` read, and
/// `tmp_dir` is passed in, so BOTH shapes are testable from any host — the
/// Windows command is otherwise the one that can never be exercised on a
/// Linux runner.
pub const OsTag = @TypeOf(@import("builtin").os.tag);

pub fn backgroundSpec(
    allocator: std.mem.Allocator,
    os_tag: OsTag,
    tmp_dir: []const u8,
    command: []const u8,
    unique: i64,
) !BackgroundSpec {
    const sep: u8 = if (os_tag == .windows) '\\' else '/';
    const log_path = try std.fmt.allocPrint(allocator, "{s}{c}bg_{d}.log", .{ tmp_dir, sep, unique });

    const bg_command = switch (os_tag) {
        .windows => blk: {
            const q_cmd = try quotePwsh(allocator, command);
            defer allocator.free(q_cmd);
            const q_log = try quotePwsh(allocator, log_path);
            defer allocator.free(q_log);
            break :blk try std.fmt.allocPrint(
                allocator,
                "Start-Process -NoNewWindow -FilePath pwsh " ++
                    "-ArgumentList '-NoProfile','-Command',{s} " ++
                    "-RedirectStandardOutput {s} -RedirectStandardError {s} " ++
                    "-PassThru | Select-Object -ExpandProperty Id",
                .{ q_cmd, q_log, q_log },
            );
        },
        else => try std.fmt.allocPrint(
            allocator,
            "nohup {s} > {s} 2>&1 & echo $!",
            .{ command, log_path },
        ),
    };

    return .{ .log_path = log_path, .command = bg_command };
}

pub const BackgroundSpec = struct {
    log_path: []u8,
    command: []u8,

    pub fn deinit(self: BackgroundSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.log_path);
        allocator.free(self.command);
    }
};

/// Single-quote a string for PowerShell, doubling any embedded `'`.
/// PowerShell's escape for a single quote inside a single-quoted string is
/// a doubled one, and nothing else may appear raw.
pub fn quotePwsh(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try out.append(allocator, '\'');
        try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

/// The platform's own temp directory.
///
/// The old code interpolated a literal `/tmp` into a path that was then
/// handed to a Windows shell. Reading the OS variable keeps the fallback
/// inside the POSIX arm, where it is actually correct.
pub fn tempDirFor(allocator: std.mem.Allocator, os_tag: OsTag) ![]u8 {
    // `std.c.getenv` is the same accessor the rest of the codebase uses for
    // this (service/state_file.zig reads LOCALAPPDATA through it), and it
    // works on both platforms because the agent process always links libc.
    // `std.c.getenv` takes a C string pointer, so the candidates are typed
    // `[*:0]const u8` rather than slices.
    const names: []const [*:0]const u8 = if (os_tag == .windows) &.{ "TEMP", "TMP" } else &.{"TMPDIR"};
    for (names) |n| {
        if (std.c.getenv(n)) |value| {
            // `[*:0]u8` has no length; span it before measuring/copying.
            const slice = std.mem.span(value);
            if (slice.len > 0) return allocator.dupe(u8, slice);
        }
    }
    return allocator.dupe(u8, defaultTempDir(os_tag));
}

/// Last-resort temp directory when the environment is unreadable. The POSIX
/// literal lives ONLY in the POSIX arm — the original bug was interpolating
/// `/tmp` into a path that was then handed to a Windows shell.
pub fn defaultTempDir(os_tag: OsTag) []const u8 {
    return if (os_tag == .windows) "C:\\Windows\\Temp" else "/tmp";
}

fn spawn_background(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    command: []const u8,
) !ShellOutput {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    const tmp_dir = try tempDirFor(allocator, builtin.os.tag);
    defer allocator.free(tmp_dir);
    const spec = try backgroundSpec(allocator, builtin.os.tag, tmp_dir, command, ts);
    defer spec.deinit(allocator);
    const log_path = spec.log_path;
    const bg_command = spec.command;

    var argv_buf: [16][]const u8 = undefined;
    if (argv_prefix.len + 1 > argv_buf.len) return error.TooManyArgvPrefix;
    @memcpy(argv_buf[0..argv_prefix.len], argv_prefix);
    argv_buf[argv_prefix.len] = bg_command;
    const argv = argv_buf[0 .. argv_prefix.len + 1];

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var pid_buf: [32]u8 = undefined;
    const pid_len = std.Io.File.readStreaming(child.stdout.?, io, &.{&pid_buf}) catch 0;
    const pid_str = std.mem.trimEnd(u8, pid_buf[0..pid_len], "\n\r ");

    _ = child.wait(io) catch {};

    const stdout_msg = try std.fmt.allocPrint(
        allocator,
        "PID: {s}\nLog: {s}",
        .{ pid_str, log_path },
    );
    errdefer allocator.free(stdout_msg);

    const stderr_msg = try allocator.dupe(u8, "No errors.");
    errdefer allocator.free(stderr_msg);

    const command_copy = if (command.len > 50) blk: {
        const cmd = try allocator.alloc(u8, 53);
        @memcpy(cmd[0..50], command[0..50]);
        @memcpy(cmd[50..53], "...");
        break :blk cmd;
    } else try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    return ShellOutput{
        .command = command_copy,
        .stdout = stdout_msg,
        .stderr = stderr_msg,
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
        .stdout_lines = 0,
        .stderr_lines = 0,
    };
}

/// JSON serialiser — same 8-field payload as the old `result_to_xml`
/// (`command/stdout/stderr/exit_code/truncated/timeout/stdout_lines/
/// stderr_lines`), now a JSON object.
///
/// Returned to the LLM as the inner `data` of the standard JSON envelope
/// (`wrapToolOutput` embeds it in `"data"` on the agentic-loop side).
pub fn result_to_json(allocator: std.mem.Allocator, result: ShellOutput) ![]u8 {
    // Strip terminal escape sequences FIRST. MSBuild, PowerShell's
    // Write-Host, cargo, pytest and friends colour their diagnostics even
    // when stdout is a pipe, so a captured log is laced with `ESC[7m` /
    // `ESC[0m`. `sanitizeControlChars` maps ESC (0x1B) to U+FFFD, but the
    // CSI parameters around it are printable ASCII and survive — which is
    // how `ESC[7mwarning ESC[0m` reaches the UI as the literal text
    // `�[7mwarning �[0m`. The flattening is one-way, so the escape has to
    // be recognised and dropped while it is still an escape.
    //
    // Then: binary stdout (e.g. `head $(which qs)` dumping the ELF header)
    // embeds NUL + C0 controls that truncate SQLite TEXT at the first NUL
    // and are illegal in JSON strings. Sanitize everything to U+FFFD;
    // `std.json` then handles the remaining `<>&"'` natively (no escaping
    // layer — markup stays raw so the LLM and frontend read it directly).
    const ansi_stdout = try helpers.ansi.stripAnsi(allocator, result.stdout);
    defer allocator.free(ansi_stdout);
    const ansi_stderr = try helpers.ansi.stripAnsi(allocator, result.stderr);
    defer allocator.free(ansi_stderr);

    const clean_command = try sanitizeControlChars(allocator, result.command);
    defer allocator.free(clean_command);
    const clean_stdout = try sanitizeControlChars(allocator, ansi_stdout);
    defer allocator.free(clean_stdout);
    const clean_stderr = try sanitizeControlChars(allocator, ansi_stderr);
    defer allocator.free(clean_stderr);
    return try std.json.Stringify.valueAlloc(allocator, ShellOutput{
        .command = clean_command,
        .stdout = clean_stdout,
        .stderr = clean_stderr,
        .exit_code = result.exit_code,
        .truncated = result.truncated,
        .timeout = result.timeout,
        .stdout_lines = result.stdout_lines,
        .stderr_lines = result.stderr_lines,
    }, .{});
}

/// Concatenates `argv_prefix` with `[command]` to form the full spawn
/// argv. This is a tiny helper kept separate so callers can audit the
/// prefix without scrolling through the spawn site. Tasks 1.5+ of the
/// 2026-08-14-pwsh-tool plan.
pub fn build_argv(
    allocator: std.mem.Allocator,
    argv_prefix: []const []const u8,
    command: []const u8,
) ![][]const u8 {
    var list = try allocator.alloc([]const u8, argv_prefix.len + 1);
    @memcpy(list[0..argv_prefix.len], argv_prefix);
    list[argv_prefix.len] = command;
    return list;
}

/// Detects commands that must not run.
///
/// WHAT THIS CHECKS TODAY: a command that names the app's own config directory
/// or database file. That file holds the LLM `api_key`, the MCP header values
/// and every workspace secret, so `sqlite3 ~/.config/pabrik/agent.db 'select
/// value from workspace_secrets'` is a one-call exfiltration of every secret in
/// every workspace — and the whole `{{SECRETS:…}}` substitution feature exists
/// to keep those values away from the model. `helpers.db_path` registers the
/// resolved path at boot, so this guard and the `read_file` guard cannot drift
/// apart: they ask the same registry.
///
/// WHY A PATH AND NOT A KEYWORD: refusing any command containing "agent.db" or
/// "workspace_secrets" would also refuse `rg agent.db src/`, which is ordinary
/// work in this repository. A guard that breaks real work gets deleted. See the
/// registry's doc comment for the limitation that remains (a path assembled at
/// runtime is not caught — this raises the cost of the one-liner, it is not a
/// sandbox).
///
/// The unbounded-output guard list (recursive `ls -R`, `find /` without
/// `-maxdepth`, a missing `timeout` / `head -n`) is still parked: it belongs to
/// a separate pass about output size, and reviving it here would silently
/// change which commands the agent may run. The rule engine stays shell-neutral
/// so those patterns apply to bash and to PowerShell alike when they come back.
pub fn is_forbidden_command(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");
    if (trimmed.len == 0) return false;

    return helpers.db_path.mentionsProtectedPath(trimmed);
}

test "is_forbidden_command refuses the app's own credential store, and nothing else" {
    defer helpers.db_path.clearProtectedPaths();
    helpers.db_path.setProtectedPaths("/home/u/.config/pabrik/agent.db");

    // The one-liner this guard exists for: every secret in every workspace.
    try std.testing.expect(is_forbidden_command(
        "sqlite3 /home/u/.config/pabrik/agent.db 'select name, value from workspace_secrets'",
    ));
    // The WAL holds the newest writes, so naming it counts too.
    try std.testing.expect(is_forbidden_command("cat /home/u/.config/pabrik/agent.db-wal"));
    try std.testing.expect(is_forbidden_command("ls -la /home/u/.config/pabrik"));

    // The false positives that would get this guard deleted: naming the file,
    // the table or an unrelated database in ordinary work.
    try std.testing.expect(!is_forbidden_command("rg -n 'agent.db' src/"));
    try std.testing.expect(!is_forbidden_command("grep -rn workspace_secrets src/"));
    try std.testing.expect(!is_forbidden_command("sqlite3 /tmp/scratch.db 'select 1'"));
    try std.testing.expect(!is_forbidden_command(""));
    try std.testing.expect(!is_forbidden_command("   "));

    // With nothing registered the guard is inert — which is what keeps it from
    // refusing commands in unit tests and in any path-less context.
    helpers.db_path.clearProtectedPaths();
    try std.testing.expect(!is_forbidden_command("cat /home/u/.config/pabrik/agent.db"));
}

/// Encode special characters in URLs within double quotes
/// Converts: curl -sI "http://host/path?query=val&sig=xyz"
///      to: curl -sI 'http://host/path?query=val&sig=xyz'
/// This prevents bash from interpreting ?, &, etc.
/// Also helps PowerShell — `?` is a wildcard and `&` is the call
/// operator there too (D6 in the plan).
pub fn encode_command_urls(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < command.len) {
        // Look for " followed by http:// or https://
        if (command[i] == '"' and i + 7 < command.len) {
            const rest = command[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://")) {
                // Found a URL in double quotes - find the closing quote
                try result.append(allocator, '\'');
                i += 1; // skip opening "

                // Copy until closing quote
                while (i < command.len and command[i] != '"') {
                    try result.append(allocator, command[i]);
                    i += 1;
                }

                if (i < command.len and command[i] == '"') {
                    try result.append(allocator, '\'');
                    i += 1; // skip closing "
                }
                continue;
            }
        }
        try result.append(allocator, command[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

const testing = std.testing;
const shell = @import("shell.zig");

test "shell.ShellInput JSON schema: same field set as BashInput (alias carries through)" {
    // shell.ShellInput is the canonical type; BashInput and PwshInput are
    // `pub const = ShellInput` aliases in their per-shell wrappers. The
    // JSON-schema parser must accept the same JSON for both names. This
    // is the "same interface" promise on the backend wire.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const json_str =
        \\{"command":"echo hi","cwd":"/tmp","mandatory_timeout":5}
    ;

    const a = try std.json.parseFromSlice(
        shell.ShellInput,
        testing.allocator,
        json_str,
        .{},
    );
    defer a.deinit();
    try testing.expectEqualStrings("echo hi", a.value.command);
    try testing.expectEqualStrings("/tmp", a.value.cwd.?);
    try testing.expectEqual(@as(u32, 5), a.value.mandatory_timeout.?);
}

test "shell.ShellOutput has all 8 fields the bash JSON payload uses" {
    // The bash_result_to_json payload has: command, stdout, stderr,
    // exit_code, truncated, timeout, stdout_lines, stderr_lines.
    // ShellOutput MUST have the same 8 — pwsh_result_to_json reuses it.
    // We construct a sample instance so the type inference resolves
    // correctly; @hasField works on the inferred type only.
    const sample = shell.ShellOutput{
        .command = "",
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
    };
    const T = @TypeOf(sample);
    try testing.expect(@hasField(T, "command"));
    try testing.expect(@hasField(T, "stdout"));
    try testing.expect(@hasField(T, "stderr"));
    try testing.expect(@hasField(T, "exit_code"));
    try testing.expect(@hasField(T, "truncated"));
    try testing.expect(@hasField(T, "timeout"));
    try testing.expect(@hasField(T, "stdout_lines"));
    try testing.expect(@hasField(T, "stderr_lines"));
}

test "shell.execute_shell runs bash happy path" {
    // After Task 1.5 lands the spawn pipeline, the placeholder is gone.
    // Sanity-check the wrapper: a trivial `true` should exit 0 with empty
    // stdout.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings("true", out.command);
}

test "shell.execute_shell enforces mandatory_timeout (returns MandatoryTimeoutMissing when null)" {
    // Smoke check that the precondition guard at the top of
    // shell.execute_shell is wired up. The plan locks this contract via
    // bash_test.zig's existing MandatoryTimeoutMissing test (kept unchanged).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "sleep 60",
        .cwd = "/tmp",
        .mandatory_timeout = null,
    });
    try testing.expectError(error.MandatoryTimeoutMissing, out);
}

test "shell.execute_shell rejects mandatory_timeout above MAX_MANDATORY_TIMEOUT_SEC" {
    // A huge deadline is the same as no deadline. The over-max guard
    // fires before any child is spawned, so these run on ALL platforms.
    // Boundary: MAX is accepted (validation passes), MAX+1 is rejected.
    try testing.expectEqual(@as(u32, 600), shell.MAX_MANDATORY_TIMEOUT_SEC);

    const over_max = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .mandatory_timeout = shell.MAX_MANDATORY_TIMEOUT_SEC + 1,
    });
    try testing.expectError(error.MandatoryTimeoutTooLarge, over_max);

    // The exact value from the user report that motivated the cap.
    const absurd = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .mandatory_timeout = 120000,
    });
    try testing.expectError(error.MandatoryTimeoutTooLarge, absurd);
}

test "shell.execute_shell accepts mandatory_timeout at exactly MAX_MANDATORY_TIMEOUT_SEC" {
    // Positive control: the boundary value itself must pass validation.
    // Runs `true` (instant) so the 600 s deadline never matters.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .mandatory_timeout = shell.MAX_MANDATORY_TIMEOUT_SEC,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
}

test "shell.execute_shell background mode is exempt from the max-timeout cap" {
    // Background detaches via nohup and ignores the timeout by design,
    // so an over-max deadline there must NOT return MandatoryTimeoutTooLarge.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .background = true,
        .mandatory_timeout = 120000,
    });
    if (out) |r| {
        testing.allocator.free(r.command);
        testing.allocator.free(r.stdout);
        testing.allocator.free(r.stderr);
    } else |err| {
        try testing.expect(err != error.MandatoryTimeoutTooLarge);
    }
}

// Task 6 — schema-shape parity lock. The user requirement: "bash and
// pwsh have to have the same interface". This test fails closed if a
// future refactor breaks the alias and re-introduces copy-paste (the
// "two separate struct types with the same fields" footgun).
//
// After Task 2, BashInput / PwshInput are `pub const = ShellInput`
// aliases — so `@typeName` returns the same string for all three.
// The test also round-trips the same JSON through all three parsers
// to prove the wire schema is identical (same field order, same field
// types, same default values).
test "ShellInput is structurally identical to BashInput AND PwshInput (alias liveness check)" {
    // We use `@typeName` of a constructed instance to force Zig to
    // resolve the alias — if the alias is broken in a future refactor,
    // the three names diverge and the test fails closed.
    const shell_input = shell.ShellInput{ .command = "" };
    const bash_input = @import("schemas.zig").BashInput{ .command = "" };
    const pwsh_input = @import("pwsh.zig").PwshInput{ .command = "" };

    try testing.expectEqualStrings(@typeName(@TypeOf(shell_input)), @typeName(@TypeOf(bash_input)));
    try testing.expectEqualStrings(@typeName(@TypeOf(shell_input)), @typeName(@TypeOf(pwsh_input)));

    // Wire-schema round-trip: parse the same JSON string through all
    // three aliases and verify every field round-trips identically.
    const json =
        \\{"command":"x","cwd":"/tmp","mandatory_timeout":3,"max_output":10,
        \\"stdin_data":"y","background":true,"max_lines":20,"do_encoding":true}
    ;

    const a = try std.json.parseFromSlice(@TypeOf(shell_input), testing.allocator, json, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(@TypeOf(bash_input), testing.allocator, json, .{});
    defer b.deinit();
    const c = try std.json.parseFromSlice(@TypeOf(pwsh_input), testing.allocator, json, .{});
    defer c.deinit();

    try testing.expectEqualStrings(a.value.command, b.value.command);
    try testing.expectEqualStrings(b.value.command, c.value.command);
    try testing.expect(a.value.mandatory_timeout.? == b.value.mandatory_timeout.?);
    try testing.expect(b.value.mandatory_timeout.? == c.value.mandatory_timeout.?);
}

test "result_to_json sanitizes binary ELF stdout into valid JSON" {
    // Regression for user report: `head -n 40 $(which qs)` dumps the
    // ELF header (0x7F 'E' 'L' 'F' 0x02 0x01 ... 0x00 + controls).
    // The old result_to_xml interpolated raw bytes — NUL truncated SQLite
    // TEXT and illegal chars broke parsers, so the stored history ended
    // at `ELF`. The JSON writer sanitizes to U+FFFD before serializing.
    const elf_stdout = "\x7FELF\x02\x01\x01\x00\x00\x01\x02<a>&\"'\x0B\x0C\x1F\x7Fend";
    const out = shell.ShellOutput{
        .command = "head -n 40 /usr/bin/quickshell",
        .stdout = elf_stdout,
        .stderr = "No errors.",
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
        .stdout_lines = 1,
        .stderr_lines = 0,
    };
    const payload = try shell.result_to_json(testing.allocator, out);
    defer testing.allocator.free(payload);

    // Must parse as a JSON object with all 9 fields.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), obj.get("exit_code").?.integer);
    try testing.expectEqual(@as(i64, 1), obj.get("stdout_lines").?.integer);
    try testing.expect(obj.get("truncated").? == .bool);
    // Markup chars stay raw in JSON (no entity layer).
    try testing.expect(std.mem.indexOf(u8, payload, "<a>") != null);
    // No raw NUL / C0 control / DEL may survive.
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x00) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x01) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x02) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x0B) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x0C) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x1F) == null);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x7F) == null);
    // Replacement char present proves sanitization ran.
    try testing.expect(std.mem.indexOf(u8, payload, "�") != null);
}

test "result_to_json: MSBuild colour codes become plain text, not ?[7m" {
    // User report: a `dotnet build … | Select-String …` on Windows came
    // back as a wall of `?[7mwarning ?[0m`. MSBuild colours its
    // diagnostics; ESC is a C0 control, so sanitizeControlChars turned it
    // into U+FFFD and left the printable CSI parameters (`[7m`) behind as
    // literal text. The words were all there — wrapped in escape soup.
    //
    // This drives the real serialiser end to end and asserts what the UI
    // reads out of the JSON envelope.
    const msbuild_stdout =
        "C:\\src\\Microsoft.Common.CurrentVersion.targets(4919,5): " ++
        "\x1b[7mwarning \x1b[0m\x1b[1mMSB\x1b[0m3026: " ++
        "\x1b[0m\x1b[7m\x1b[0mCould not copy the file";
    const out = shell.ShellOutput{
        .command = "dotnet build PriceCatalog.csproj",
        .stdout = msbuild_stdout,
        .stderr = "No errors.",
        .exit_code = 1,
        .truncated = false,
        .timeout = false,
        .stdout_lines = 1,
        .stderr_lines = 0,
    };
    const payload = try shell.result_to_json(testing.allocator, out);
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const stdout = parsed.value.object.get("stdout").?.string;

    // The diagnostic reads as prose again.
    try testing.expectEqualStrings(
        "C:\\src\\Microsoft.Common.CurrentVersion.targets(4919,5): " ++
            "warning MSB3026: Could not copy the file",
        stdout,
    );
    // No escape residue of any kind.
    try testing.expect(std.mem.indexOfScalar(u8, stdout, 0x1B) == null);
    try testing.expect(std.mem.indexOf(u8, stdout, "[7m") == null);
    try testing.expect(std.mem.indexOf(u8, stdout, "[0m") == null);
    // And no U+FFFD run — the visual signature of the bug report.
    try testing.expect(std.mem.indexOf(u8, stdout, "�") == null);
}

test "result_to_json: stderr escapes are stripped too, binary controls still scrubbed" {
    // The two sanitising passes must not undo each other: an ESC-laden
    // stderr loses its colour codes, while a genuine NUL (binary stdout)
    // still becomes U+FFFD rather than silently vanishing.
    const out = shell.ShellOutput{
        .command = "build.ps1",
        .stdout = "\x1b[31merror CS1002\x1b[0m;",
        .stderr = "\x1b[1mFAILED\x1b[0m \x00 tail",
        .exit_code = 1,
        .truncated = false,
        .timeout = false,
        .stdout_lines = 1,
        .stderr_lines = 1,
    };
    const payload = try shell.result_to_json(testing.allocator, out);
    defer testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("error CS1002;", obj.get("stdout").?.string);
    try testing.expectEqualStrings("FAILED � tail", obj.get("stderr").?.string);
    try testing.expect(std.mem.indexOfScalar(u8, payload, 0x1B) == null);
}

test "xmlEscape replaces NUL and C0 controls with U+FFFD" {
    const xml = try helpers.xml_escape(testing.allocator, "a\x00b\x01c\x08d\x0Ae\x0Df");
    defer testing.allocator.free(xml);
    // \n (0x0A) and \r (0x0D) are legal XML — preserved.
    try testing.expectEqualStrings("a�b�c�d\x0Ae\x0Df", xml);
}

// ─── Background detach (Windows) ──────────────────────────────────────────
// The bug: `spawn_background` built `"nohup {cmd} > /tmp/bg_{n}.log 2>&1 &
// echo $!"` and handed it to whatever shell was configured. On Windows that
// is `pwsh -Command`, where the string is a syntax error — and its redirect
// target does not exist either. Every `background: true` call failed there.
//
// `backgroundSpec` takes the OS tag as a parameter precisely so the Windows
// shape is assertable from a Linux runner; these tests would otherwise only
// ever run on the platform whose CI cell is currently broken.
test "backgroundSpec: Windows uses Start-Process, never nohup, and no /tmp" {
    const spec = try backgroundSpec(
        testing.allocator,
        .windows,
        "C:\\Users\\ginwa\\AppData\\Local\\Temp",
        "sleep 60",
        1234,
    );
    defer spec.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, spec.command, "Start-Process") != null);
    try testing.expect(std.mem.indexOf(u8, spec.command, "nohup") == null);
    try testing.expect(std.mem.indexOf(u8, spec.command, "echo $!") == null);
    try testing.expect(std.mem.indexOf(u8, spec.log_path, "/tmp") == null);
    try testing.expectEqualStrings(
        "C:\\Users\\ginwa\\AppData\\Local\\Temp\\bg_1234.log",
        spec.log_path,
    );
    // The PID is what the old `echo $!` produced. Start-Process must yield
    // it too, or the caller can neither report nor kill the process.
    try testing.expect(std.mem.indexOf(u8, spec.command, "Id") != null);
}

test "backgroundSpec: POSIX keeps the nohup form and its /tmp log" {
    const spec = try backgroundSpec(testing.allocator, .linux, "/tmp", "sleep 60", 1234);
    defer spec.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/bg_1234.log", spec.log_path);
    try testing.expectEqualStrings("nohup sleep 60 > /tmp/bg_1234.log 2>&1 & echo $!", spec.command);
}

test "backgroundSpec: the command is single-quoted for PowerShell" {
    const spec = try backgroundSpec(testing.allocator, .windows, "C:\\Temp", "Write-Host 'hi'", 7);
    defer spec.deinit(testing.allocator);

    // The inner `'` must be doubled or it terminates the quoted argument
    // and the rest of the line is parsed as PowerShell source.
    try testing.expect(std.mem.indexOf(u8, spec.command, "'Write-Host ''hi'''") != null);
}

test "quotePwsh: doubles embedded single quotes and wraps the value" {
    const q = try quotePwsh(testing.allocator, "a'b");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'a''b'", q);

    const plain = try quotePwsh(testing.allocator, "plain");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("'plain'", plain);
}

test "tempDirFor: the Windows fallback is never the POSIX literal" {
    // Shape, not this machine's environment: the point is that the Windows
    // arm cannot reach `/tmp`.
    try testing.expect(!std.mem.eql(u8, defaultTempDir(.windows), "/tmp"));
    try testing.expect(std.mem.indexOf(u8, defaultTempDir(.windows), "\\") != null);
    try testing.expectEqualStrings("/tmp", defaultTempDir(.linux));

    const t = try tempDirFor(testing.allocator, .windows);
    defer testing.allocator.free(t);
    try testing.expect(t.len > 0);
    try testing.expect(!std.mem.eql(u8, t, "/tmp"));
}
