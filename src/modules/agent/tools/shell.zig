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
/// How the command relates to the caller's turn.
///
/// The three categories the product asks for, in the order a user meets them:
///
///   * `foreground`      — the call blocks, the result is returned inline, and
///                         a `timeout` is REQUIRED (1–60 s).
///   * `background`      — the command detaches and a QUEUE MESSAGE is written
///                         when it exits. For a long build, test run or
///                         migration — bounded work whose outcome the agent
///                         needs. Consumed by `background_watcher` and the
///                         per-minute cron.
///   * `background_persistence` — the command detaches and NO queue message is
///                         ever written. For a dev server or a watcher that
///                         runs for the life of the session. The agent polls
///                         it when it wants to know something, and the only
///                         thing that ends it is an explicit stop or pabrik
///                         itself shutting down.
///
/// `background` (the boolean) is the LEGACY spelling of `background`; the
/// parser resolves it, and `resolvedMode` keeps direct constructors working.
pub const RunMode = enum {
    foreground,
    background,
    background_persistence,

    pub fn isDetached(self: RunMode) bool {
        return self != .foreground;
    }

    /// Wire spelling. `background` is the value the parser accepts; the enum
    /// field is `background_persistence` so a `switch` cannot confuse the two.
    pub fn fromWire(w: []const u8) ?RunMode {
        if (std.mem.eql(u8, w, "foreground")) return .foreground;
        if (std.mem.eql(u8, w, "background")) return .background;
        if (std.mem.eql(u8, w, "background_persistence")) return .background_persistence;
        return null;
    }

    pub fn toWire(self: RunMode) []const u8 {
        return switch (self) {
            .foreground => "foreground",
            .background => "background",
            .background_persistence => "background_persistence",
        };
    }

    /// The kind column value a detached command of this mode is recorded
    /// under. `service` is what makes "no queue message" enforceable in TWO
    /// places (the watcher is not scheduled, and the cron skips the row) —
    /// see `session_background_process.kind`.
    pub fn kindFor(self: RunMode) []const u8 {
        return switch (self) {
            .foreground => "job",
            .background => "job",
            .background_persistence => "service",
        };
    }
};

pub const ShellInput = struct {
    command: []const u8,
    timeout: ?u32 = null,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 20 * 1024,
    stdin_data: ?[]const u8 = null,
    /// LEGACY alias for `mode == .background`. The parser resolves the two into
    /// `mode` (and rejects a contradiction), but this stays because an
    /// in-tree constructor, a test or a transcript written before `mode`
    /// existed sets only this. `resolvedMode` is the single reader.
    background: bool = false,
    /// See `RunMode`. Additive: everything that does not set it keeps
    /// running in the foreground, which is the behaviour it had.
    mode: RunMode = .foreground,
    max_lines: ?usize = 1000,
    do_encoding: bool = false,
    /// ASK THE AGENTIC LOOP TO END THIS TURN after the current tool batch.
    ///
    /// Not a shell concern, and `shell.zig` never reads it — the field rides
    /// in this struct only because `ShellInput` is the parsed-arguments type
    /// for the `command` tool (the retired `bash` / `pwsh` shims alias it).
    /// `tools_exec_command` copies it onto `ToolExecResult.stop_loop`, which
    /// `handle_tool` returns to the workflow loop.
    ///
    /// Nothing is killed: a detached command started by the same call keeps
    /// running. See `docs/plans/2026-10-14-command-is-stop-persistence.md`.
    is_stop: bool = false,
};

/// The mode a spawn should actually use, after folding in the legacy
/// `background` alias.
///
/// `mode` wins whenever it says anything other than `foreground`: a caller
/// that sets `.mode = .background_persistence` and leaves `background` at its
/// false default gets what it asked for. `background = true` only promotes a
/// defaulted `.foreground` — which is the pre-`mode` behaviour, preserved for
/// the direct constructors and tests that still rely on it.
///
/// The `background=true` + explicit `mode="foreground"` CONTRADICTION is NOT
/// resolved here: nothing can, since this function cannot tell an explicit
/// `foreground` from a defaulted one. `parseShellArgs` catches it on the
/// LLM-facing path and returns a structured error naming both fields.
pub fn resolvedMode(input: ShellInput) RunMode {
    if (input.background and input.mode == .foreground) return .background;
    return input.mode;
}

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

/// Returned by `execute_shell` when the caller omits `timeout`.
/// Same semantics as the bash.zig version; shell-neutral.
pub const TimeoutMissing = error{TimeoutMissing};

/// Returned by `execute_shell` when the caller passes a `timeout`
/// above `MAX_TIMEOUT_SEC`. A huge deadline is the same as no
/// deadline — it lets a runaway command hang the agent until the outer
/// harness gives up. Reject explicitly so the caller splits the work
/// (smaller steps, `background=true`, or the functional harness).
pub const TimeoutTooLarge = error{TimeoutTooLarge};

/// Returned by `execute_shell` when the caller omits `cwd`.
///
/// Without `cwd` the child inherits the SERVER process's working directory —
/// for an agent session that is the project root, never the session's bound
/// worktree. A `background=true` build launched that way compiles the wrong
/// checkout, and a relative `zig-out` installs into it. Requiring the field
/// turns that silent wrong-tree run into a learnable error.
pub const MandatoryCwdMissing = error{MandatoryCwdMissing};

/// Returned by `execute_shell` when `cwd` is not an absolute path.
///
/// A relative path is resolved against the server's working directory, which
/// is the same wrong-tree bug spelled differently — and invisible, because
/// the caller believes it named a location.
pub const CwdNotAbsolute = error{CwdNotAbsolute};

/// Upper bound for a single foreground command: 1 minute.
///
/// A foreground deadline longer than a minute is indistinguishable from a
/// hung agent — the user watches a spinner while nothing reports progress —
/// so anything longer is refused BEFORE a child is spawned and the caller is
/// steered to `background=true` (which detaches and is exempt from this cap)
/// or to splitting the work into smaller steps. It also turns absurd values
/// like 120000 (33 h) into an instant, learnable error.
pub const MAX_TIMEOUT_SEC: u32 = 60;

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

// ============================================================================
// Foreground deadline enforcement
//
// The deadline has to mean two things, and the old code only delivered the
// first:
//
//   1. the child is terminated when the deadline passes — on EVERY platform.
//      Both kill sites used to be `if (comptime builtin.os.tag != .windows)`,
//      so on Windows the deadline only recorded `timeout_hit` while the child
//      — and any dialog it had put on screen — kept running.
//   2. the CALL returns when the deadline says it does. That is the hard part:
//      stdout/stderr are read by two threads that finish only on pipe EOF, and
//      a process that survived the kill still holds the write ends (POSIX: a
//      `setsid`/`nohup` descendant that escaped the process group; Windows: a
//      `start /b` grandchild of the direct child). The old code then did a
//      plain `std.Thread.join()`, which has no timeout — so the tool never
//      returned and the agent workflow loop hung with it: "the deadline fired
//      and nothing came back". `Reader` + `settleReader` below bound that join.
// ============================================================================

/// Win32 TerminateProcess — declared locally for the same reason as
/// `GetExitCodeProcess` above: Zig 0.16's `std.os.windows` does not export it.
/// `child.kill(io)` is NOT a substitute: on Windows it waits on the process
/// handle without a bound, and it clears `child.id`, which `wait_pid_bounded`
/// needs for the exit-code harvest.
extern "kernel32" fn TerminateProcess(
    hProcess: std.os.windows.HANDLE,
    uExitCode: u32,
) callconv(.winapi) std.os.windows.BOOL;

/// Grace the reader threads get to observe EOF once the deadline kill has been
/// issued. In the common case — the whole process group dies — EOF arrives in
/// milliseconds; the grace exists for the case where a descendant SURVIVED the
/// kill and therefore never closes the pipe. When it expires the call returns
/// anyway; see `settleReader`.
const READER_JOIN_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Reader threads that were handed off instead of joined (see `settleReader`).
///
/// Non-zero means a process that outlived the deadline kill is still holding a
/// pipe. Each such reader releases its own state and decrements this once the
/// pipe finally closes — it is the observable form of "we returned a timeout
/// result without waiting for a stray descendant", and it returns to zero even
/// though nobody joined that thread.
pub var abandoned_reader_count: std.atomic.Value(usize) = .init(0);

/// How the deadline terminates the child. Pure data, with the OS tag as a
/// PARAMETER rather than a read of `builtin.os.tag`, so the Windows arm is
/// assertable from a Linux runner — the same reason `backgroundSpec` takes the
/// tag instead of reading the host.
const TimeoutKill = enum {
    /// `kill(-pgid, SIGKILL)`: the child leads its own process group
    /// (`.pgid = 0` at spawn), so one syscall reaches the whole tree.
    process_group,
    /// `TerminateProcess(handle)`: Windows has no process groups, so the direct
    /// child is the only handle we own.
    child_handle,
};

fn timeoutKillPlan(comptime os_tag: std.Target.Os.Tag) []const TimeoutKill {
    return switch (os_tag) {
        .windows => &.{.child_handle},
        else => &.{.process_group},
    };
}

/// Terminate the child — and on POSIX its whole process group — when the
/// deadline passes. Best-effort by nature: a descendant that escaped the group
/// cannot be reached from here, which is exactly why the caller must not depend
/// on the pipes closing (see `Reader`).
fn terminateTimedOutChild(child: *const std.process.Child, child_pgid: c_int) void {
    for (timeoutKillPlan(builtin.os.tag)) |kill| {
        switch (kill) {
            .process_group => {
                if (comptime builtin.os.tag != .windows) {
                    _ = std.posix.kill(-child_pgid, .KILL) catch {};
                }
            },
            .child_handle => {
                if (comptime builtin.os.tag == .windows) {
                    if (child.id) |handle| _ = TerminateProcess(handle, 1);
                }
            },
        }
    }
}

/// One foreground output stream: the pipe, what has been captured from it, and
/// the ownership protocol that lets the reader thread OUTLIVE the call that
/// spawned it.
///
/// It is heap-allocated and self-contained on purpose. When a pipe holder
/// survives the deadline kill the reader can still be parked in
/// `readStreaming` long after `run_shell_command` has to return, so it cannot
/// be left pointing at that frame — and it cannot use the caller's allocator
/// either, because the caller's allocator may be an arena that dies with the
/// tool call. The state and the captured bytes therefore come from
/// `std.heap.smp_allocator` (thread-safe, process-lifetime), and the caller
/// copies what it returns into its own allocator.
const Reader = struct {
    stream: std.Io.File,
    io: std.Io,
    buf: [4096]u8 = undefined,
    data: std.ArrayList(u8) = .empty,
    line_count: usize = 0,
    truncated: bool = false,
    max_output: usize,
    max_lines: usize,
    /// Published under `mutex` when the read loop is done; every field above is
    /// frozen from that point on.
    eof: std.atomic.Value(bool) = .init(false),
    /// Set under `mutex` by the caller when it stops waiting for `eof`: the
    /// reader stops capturing and takes ownership of this state.
    handed_off: bool = false,
    /// Lock-free mirror of `handed_off` for the capture path.
    abandoned: std.atomic.Value(bool) = .init(false),
    mutex: std.atomic.Mutex = .unlocked,

    fn create(io: std.Io, stream: std.Io.File, max_output: usize, max_lines: usize) !*Reader {
        const self = try std.heap.smp_allocator.create(Reader);
        self.* = .{
            .stream = stream,
            .io = io,
            .max_output = max_output,
            .max_lines = max_lines,
        };
        return self;
    }

    /// Close the read end and release the state. Exactly one side calls this —
    /// see `settleReader`.
    fn destroy(self: *Reader) void {
        self.stream.close(self.io);
        self.data.deinit(std.heap.smp_allocator);
        std.heap.smp_allocator.destroy(self);
    }

    fn lock(self: *Reader) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Reader) void {
        self.mutex.unlock();
    }

    fn run(self: *Reader) void {
        self.readLoop();
        self.publishEof();
    }

    /// Exit path. `eof` and the ownership decision are published in ONE critical
    /// section, and the caller decides under the same `mutex`, so the two cannot
    /// interleave: either the caller sees `eof` and releases the state, or it
    /// leaves `handed_off` set and this thread releases it. Never both
    /// (use-after-free), never neither (leak).
    fn publishEof(self: *Reader) void {
        self.lock();
        const orphan = self.handed_off;
        self.eof.store(true, .release);
        self.unlock();
        if (orphan) {
            _ = abandoned_reader_count.fetchSub(1, .monotonic);
            self.destroy();
        }
    }

    fn readLoop(self: *Reader) void {
        while (true) {
            const n = std.Io.File.readStreaming(self.stream, self.io, &.{self.buf[0..]}) catch return;
            if (n == 0) return;
            for (self.buf[0..n]) |byte| {
                if (byte == '\n') self.line_count += 1;
            }
            if (self.abandoned.load(.acquire)) {
                // The caller has already built its answer from the snapshot.
                // Keep draining — a detached writer must not block on a full
                // pipe — but stop capturing, so nothing here grows after the
                // call returned.
                continue;
            }
            self.lock();
            defer self.unlock();
            if (self.abandoned.load(.acquire)) continue;
            if (!self.truncated) {
                self.data.appendSlice(std.heap.smp_allocator, self.buf[0..n]) catch return;
                if (self.data.items.len >= self.max_output or self.line_count >= self.max_lines) {
                    self.truncated = true;
                    var trim_pos: usize = self.data.items.len;
                    if (self.line_count >= self.max_lines) {
                        var count: usize = 0;
                        for (self.data.items, 0..) |b, i| {
                            if (b == '\n') {
                                count += 1;
                                if (count == self.max_lines) {
                                    trim_pos = i + 1;
                                    break;
                                }
                            }
                        }
                    } else if (self.data.items.len > self.max_output) {
                        trim_pos = self.max_output;
                    }
                    if (self.data.items.len > trim_pos) {
                        self.data.shrinkAndFree(std.heap.smp_allocator, trim_pos);
                    }
                }
            }
        }
    }
};

/// Whose job it is to release a settled reader state.
const Ownership = enum {
    /// The reader is done. Its fields are frozen, so the caller may read them
    /// and must release the state (which closes the read end).
    caller,
    /// The reader never saw EOF: it was handed the state, stops capturing, and
    /// releases it itself once the pipe finally closes.
    reader,
};

/// Bounded join for one reader: wait until `deadline_ns` for EOF, then decide who
/// releases the state.
///
/// This is the fix for the hang. `std.Thread.join` has no timeout, and a reader
/// blocked on a pipe whose write end is held elsewhere never returns — so the
/// wait has to be a poll, and the "join or hand off" decision has to be taken
/// under the reader's own `mutex` to stay single-valued.
///
/// The deadline is ABSOLUTE and shared by both readers (`readersDeadline`), so
/// the grace is a budget for the call, not two budgets spent back to back.
fn settleReader(state: *Reader, thread: ?std.Thread, deadline_ns: u64, label: []const u8) Ownership {
    if (thread == null) return .caller; // Spawn failed: it never ran, nothing to wait for.
    while (true) {
        state.lock();
        if (state.eof.load(.acquire)) {
            state.unlock();
            thread.?.join(); // Already past its last statement.
            return .caller;
        }
        if (helpers.monotonicTimestampNanos() >= deadline_ns) {
            state.handed_off = true;
            state.abandoned.store(true, .release);
            state.unlock();
            _ = abandoned_reader_count.fetchAdd(1, .monotonic);
            std.log.warn(
                "shell: a process that outlived the deadline kill still holds the {s} pipe; returning the timeout result without waiting for it",
                .{label},
            );
            return .reader;
        }
        state.unlock();
        pollSleep10ms();
    }
}

/// Settle every reader that has not been taken over yet, and clear its slot so a
/// later error cannot settle (and release) the same state twice.
fn settlePendingReaders(pending: []?*Reader, threads: []const ?std.Thread, deadline_ns: u64) void {
    const labels = [_][]const u8{ "stdout", "stderr" };
    for (pending, 0..) |*slot, i| {
        const state = slot.* orelse continue;
        if (settleReader(state, threads[i], deadline_ns, labels[i]) == .caller) state.destroy();
        slot.* = null;
    }
}

/// When the readers have to be settled by: one grace period for the CALL, spent
/// across both streams rather than two graces spent back to back.
fn readersDeadline() u64 {
    return helpers.monotonicTimestampNanos() + READER_JOIN_GRACE_PERIOD_NS;
}

/// What the caller gets back from one stream.
const Captured = struct {
    /// The bytes to return: the empty-capture placeholder, or the capture cut to
    /// `max_output`. Owned by the caller's allocator.
    bytes: []u8,
    line_count: usize,
    truncated: bool,
    /// The reader was handed off — a pipe holder outlived the kill — so this is
    /// whatever had arrived by the deadline.
    abandoned: bool,
};

/// Settle one reader and copy what it captured, into `alloc`. The copy happens
/// while this side still owns the state, which is what makes it safe even when
/// the reader is handed off (an abandoned reader stops appending under its own
/// lock, and we read under that same lock).
///
/// The state is released on EVERY path out of here — success, error, and
/// handoff — so the caller must clear its pending slot before calling.
fn captureStream(
    alloc: std.mem.Allocator,
    state: *Reader,
    thread: ?std.Thread,
    deadline_ns: u64,
    label: []const u8,
    max_output: usize,
    empty_placeholder: []const u8,
) !Captured {
    const ownership = settleReader(state, thread, deadline_ns, label);
    if (ownership == .reader) {
        state.lock();
        defer state.unlock();
        return .{
            .bytes = try shapeCapture(alloc, state.data.items, max_output, empty_placeholder),
            .line_count = state.line_count,
            .truncated = state.truncated,
            .abandoned = true,
        };
    }
    defer state.destroy();
    return .{
        .bytes = try shapeCapture(alloc, state.data.items, max_output, empty_placeholder),
        .line_count = state.line_count,
        .truncated = state.truncated,
        .abandoned = false,
    };
}

/// The empty / over-long policy the tool has always applied to a captured
/// stream: no output at all reads as `empty_placeholder`, anything past
/// `max_output` is cut.
fn shapeCapture(
    alloc: std.mem.Allocator,
    raw: []const u8,
    max_output: usize,
    empty_placeholder: []const u8,
) ![]u8 {
    if (raw.len == 0) return alloc.dupe(u8, empty_placeholder);
    if (raw.len > max_output) return alloc.dupe(u8, raw[0..max_output]);
    return alloc.dupe(u8, raw);
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

    // --- Mandatory-cwd check (BOTH modes) ---
    //
    // Checked before the timeout guard so a call missing both fields is told
    // about the more dangerous omission first — the one that runs work in the
    // wrong directory.
    //
    // `cwd` used to be documented as mandatory while a missing value quietly
    // fell back to `.inherit`, i.e. the SERVER's working directory. That is
    // the silent wrong-tree bug: `background=true` ignored `cwd` outright, so
    // a detached build compiled the main checkout (and installed into its
    // `zig-out`) while the operator watched a worktree. Absolute-only for the
    // same reason: a relative path resolves against the server's cwd, so it
    // lands somewhere the caller never named.
    const cwd = input.cwd orelse return error.MandatoryCwdMissing;
    if (cwd.len == 0) return error.MandatoryCwdMissing;
    if (!std.fs.path.isAbsolute(cwd)) return error.CwdNotAbsolute;

    // --- Mandatory-timeout check (foreground only) ---
    // Neither detached mode uses the timeout (the process outlives the call
    // by definition), so the check is skipped for both. But the foreground
    // path MUST have an explicit deadline — the previous design defaulted
    // to 30 s which silently masked runaway commands.
    //
    // Keyed on the RESOLVED mode, so `background=true` and
    // `mode="background"` take exactly the same branch.
    const mode = resolvedMode(input);
    if (!mode.isDetached() and input.timeout == null) {
        return error.TimeoutMissing;
    }
    if (input.timeout) |t| {
        if (t == 0) return error.TimeoutMissing;
        // Foreground only: a detached call ignores the timeout by design, so
        // an over-max deadline there is harmless. In foreground a huge
        // deadline is the same as no deadline.
        if (!mode.isDetached() and t > MAX_TIMEOUT_SEC) {
            return error.TimeoutTooLarge;
        }
    }

    // --- Detached modes ---
    //
    // Two different detach mechanisms, deliberately, for one release:
    //   * `background`      keeps the `nohup` shell idiom it has always used,
    //                       so the path every existing caller and test
    //                       depends on cannot regress while the new one is
    //                       proven.
    //   * `background_persistence` gets the native spawn (`.pgid = 0` +
    //                       stdout/stderr straight to the log file), which is
    //                       what makes `pid == pgid` — and therefore a tree
    //                       kill that actually frees the port.
    if (mode == .background_persistence) {
        return try spawn_detached_native(allocator, io, argv_prefix, command, cwd);
    }
    if (mode == .background) {
        return try spawn_background(allocator, io, argv_prefix, command, cwd);
    }

    // --- Foreground mode ---
    // `input.max_output` defaults to 20 KiB in the schema (see schemas.zig),
    // so the `orelse` fallback here is a defense-in-depth — it would only
    // fire if someone constructs ShellInput programmatically without going
    // through the JSON schema (e.g. tests, internal callers).
    const max_output = input.max_output orelse 20 * 1024;
    const max_lines = input.max_lines orelse 1000;
    const timeout_sec = input.timeout.?;

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
        .cwd = .{ .path = cwd },
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
        // Terminate on every platform — see `terminateTimedOutChild`. This used
        // to be POSIX-only, so a failed Windows spawn left the child running.
        terminateTimedOutChild(&child, child_pgid);
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

    // The pipes stay attached to `child` until BOTH readers exist, so the
    // spawn-time errdefer still closes them if one of these allocations fails.
    const stdout_reader = try Reader.create(io, child.stdout.?, max_output, max_lines);
    const stderr_reader = try Reader.create(io, child.stderr.?, max_output, max_lines);
    // Ownership of both pipes is in the readers now: nothing below may close
    // them, and the spawn-time errdefer above must not either.
    child.stdout = null;
    child.stderr = null;

    const readers = [2]*Reader{ stdout_reader, stderr_reader };
    // `pending` is the settle ledger: a slot goes null the moment that reader
    // changes hands (`captureStream`), so the errdefer can never settle — and
    // release — the same state twice. A slot whose spawn never happened is still
    // set, and `settleReader` handles that (there is nothing to wait for).
    var pending = [2]?*Reader{ stdout_reader, stderr_reader };
    var threads: [2]?std.Thread = .{ null, null };
    errdefer {
        // The spawn-time errdefer above terminates the child; this one settles
        // the readers — a plain `join()` here would be unbounded, which is the
        // hang this file is fixing.
        settlePendingReaders(pending[0..], threads[0..], readersDeadline());
    }

    for (readers, 0..) |reader, i| {
        threads[i] = try std.Thread.spawn(.{}, Reader.run, .{reader});
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
            if (stdout_reader.eof.load(.acquire) and stderr_reader.eof.load(.acquire)) {
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                // Terminate on EVERY platform. This used to be POSIX-only, so on
                // Windows the deadline recorded `timeout_hit` and then waited on a
                // child nobody had asked to stop — which is how a modal dialog
                // could hold the tool open past its own deadline.
                terminateTimedOutChild(&child, child_pgid);
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            pollSleep10ms();
        }
    };

    // Bounded. A pipe holder that outlived the kill — POSIX: a `setsid` descendant
    // that escaped the process group; Windows: a `start /b` grandchild — must not
    // keep the tool open past its deadline. `captureStream` joins the readers
    // that did see EOF and hands the rest to the reader threads that still own
    // them; the pipes are closed by whichever side releases a reader.
    const readers_deadline = readersDeadline();
    const stdout_state = pending[0].?;
    pending[0] = null; // `captureStream` releases it on every path from here.
    const stdout_cap = try captureStream(allocator, stdout_state, threads[0], readers_deadline, "stdout", max_output, "No output produced.");
    errdefer allocator.free(stdout_cap.bytes);

    const stderr_state = pending[1].?;
    pending[1] = null;
    const stderr_cap = try captureStream(allocator, stderr_state, threads[1], readers_deadline, "stderr", max_output, "No errors.");
    errdefer allocator.free(stderr_cap.bytes);

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

    const was_truncated = stdout_cap.truncated or stderr_cap.truncated;

    const command_copy = try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    // `captureStream` already applied the empty / over-long policy, so the
    // capture IS the payload — no second copy of up to `max_output` bytes.
    return ShellOutput{
        .command = command_copy,
        .stdout = stdout_cap.bytes,
        .stderr = stderr_cap.bytes,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
        .stdout_lines = stdout_cap.line_count,
        .stderr_lines = stderr_cap.line_count,
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
    const log_path = try detachedLogPath(allocator, os_tag, tmp_dir, unique);

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
    cwd: []const u8,
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
        // The `nohup … &` idiom runs in the shell we spawn here, and the
        // detached process inherits THAT shell's cwd — so honoring `cwd` on
        // this spawn is what puts the background job in the caller's
        // directory. Hardcoding `.inherit` here is the bug this replaces: the
        // job silently ran in the server's cwd (the project root), so a
        // detached `zig build` compiled the wrong checkout.
        .cwd = .{ .path = cwd },
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

/// Log path for a detached command. ONE construction, shared by the `nohup`
/// path and the native one, so both mechanisms log to the same place and
/// nothing downstream can tell which started the process.
pub fn detachedLogPath(
    allocator: std.mem.Allocator,
    os_tag: OsTag,
    tmp_dir: []const u8,
    unique: i64,
) ![]u8 {
    const sep: u8 = if (os_tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}bg_{d}.log", .{ tmp_dir, sep, unique });
}

/// Native detached spawn: no shell, and `pid == pgid`.
///
/// Why not the `nohup cmd & echo $!` idiom `spawn_background` uses:
///
///   * `$!` is the PID of the SHELL's child, not of the command, and that
///     child's process group is the group WE were started in. So
///     `kill(-pgid)` could never be used — it would signal our own group —
///     and a single-PID kill orphans everything the command forked.
///     `pnpm run dev` forks again (vite → esbuild), and the survivors keep
///     the port: "stop the dev server" did not stop it.
///   * It needs a shell string to be built and quoted per platform
///     (`backgroundSpec`, `quotePwsh`). A direct spawn has no such string.
///
/// Spawning the command ourselves with `.pgid = 0` makes it a process-group
/// leader, so `kill(-pid)` reaches the whole tree; redirecting stdout/stderr
/// straight at the log FILE (no pipes) means no reader threads are involved —
/// the `Reader` / `settleReader` machinery exists for the foreground deadline
/// problem and has nothing to do here.
///
/// The child is OUR child, so it MUST be reaped — see `reap_pid_nohang`. A
/// zombie answers `kill(pid, 0)` with SUCCESS, so an unreaped native child
/// would report as "running" for the life of the process.
///
/// Note what is deliberately NOT done here: `PR_SET_PDEATHSIG`.
/// `std.process.SpawnOptions` has no such field (and no pre-exec hook) in Zig
/// 0.16 — verified against `/usr/lib/zig/std/process.zig:361-403` — and the
/// flag has to be set by the CHILD before it execs, so it is unreachable from
/// a plain `spawn` without putting a shell wrapper back, which is the thing
/// this function exists to remove. "Dies with pabrik" is therefore carried by
/// the shutdown hook (SIGINT/SIGTERM) plus the boot sweep for the `kill -9`
/// case; see `killServicesForShutdown` / `reapOrKillServicesOnBoot`.
fn spawn_detached_native(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    command: []const u8,
    cwd: []const u8,
) !ShellOutput {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    const tmp_dir = try tempDirFor(allocator, builtin.os.tag);
    defer allocator.free(tmp_dir);
    const log_path = try detachedLogPath(allocator, builtin.os.tag, tmp_dir, ts);
    defer allocator.free(log_path);

    // Create/truncate the log, hand the descriptor to the child, then close OUR
    // copy: the child holds its own dup, so nothing here keeps the file open
    // for the process' lifetime.
    var log_file = try std.Io.Dir.createFileAbsolute(io, log_path, .{ .truncate = true });
    defer log_file.close(io);

    var argv_buf: [16][]const u8 = undefined;
    if (argv_prefix.len + 1 > argv_buf.len) return error.TooManyArgvPrefix;
    @memcpy(argv_buf[0..argv_prefix.len], argv_prefix);
    argv_buf[argv_prefix.len] = command;
    const argv = argv_buf[0 .. argv_prefix.len + 1];

    const child = try std.process.spawn(io, .{
        .argv = argv,
        // `cwd` is what puts the detached command in the caller's directory;
        // `.inherit` here is the wrong-tree bug `spawn_background` was fixed
        // for, and there is no reason to reintroduce it in the new path.
        .cwd = .{ .path = cwd },
        .stdin = .close,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        // A new process group whose id equals the child's pid: this is what
        // makes `kill(-pid)` a tree kill. Windows has no pgid.
        .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
    });

    const pid = childPidForLog(child) orelse return error.SpawnedWithoutPid;

    // NOT `child.wait` — the child outlives this call by design. The reaper in
    // `background_watcher` collects it.
    const stdout_msg = try std.fmt.allocPrint(allocator, "PID: {d}\nLog: {s}", .{ pid, log_path });
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

/// The numeric PID to report for a freshly spawned child, or null on a host
/// where `Child.Id` is not an integer (Windows: a HANDLE, which is not
/// meaningful to the caller and is what `background_watcher` re-resolves).
fn childPidForLog(child: std.process.Child) ?u32 {
    const id_opt = child.id orelse return null;
    const T = @TypeOf(id_opt);
    if (@typeInfo(T) != .int) return null;
    return @intCast(id_opt);
}

/// Outcome of one non-blocking reap attempt on a PID we spawned.
pub const ReapOutcome = union(enum) {
    /// Reaped by this call. `code` is the exit status (negative = killed by
    /// that signal, the bash `$?` convention).
    exited: i32,
    /// Still running.
    running,
    /// `ECHILD`: not (or no longer) our child, so `waitpid` cannot answer.
    /// The caller must fall back to a signal probe. This is the normal answer
    /// on Windows (no `waitpid`) and for a row that predates a restart.
    not_our_child,
};

/// Non-blocking reap. Returns `.running`/`.exited` for a child of this
/// process, `.not_our_child` otherwise.
///
/// This is not housekeeping: `process_status.isProcessRunning` probes with
/// `kill(pid, 0)`, and a ZOMBIE answers that probe with SUCCESS. Without a
/// reaper a native detached child that exited would read as "running"
/// forever — the process list would lie and the boot sweep would try to kill
/// a corpse.
pub fn reap_pid_nohang(pid: u32) ReapOutcome {
    if (comptime builtin.os.tag == .windows) return .not_our_child;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return .not_our_child;

    var status: c_int = 0;
    const rc = std.c.waitpid(@intCast(pid), &status, std.c.W.NOHANG);
    if (rc == @as(c_int, @intCast(pid))) {
        return .{ .exited = switch (status_to_term(status)) {
            .exited => |code| @as(i32, @intCast(code)),
            .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
            .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
            .unknown => -1,
        } };
    }
    if (rc == 0) return .running;
    const err = std.c.errno(rc);
    if (err == .CHILD) return .not_our_child;
    // Any other errno (EINVAL on a bad pid, EINTR) is not something this
    // caller can act on — report "not ours" so the signal probe decides.
    return .not_our_child;
}

/// How a stop reaches a detached process.
///
/// Pure DATA, with the OS tag as a PARAMETER rather than a read of
/// `builtin.os.tag`, so the Windows arm is assertable from a Linux runner —
/// the `timeoutKillPlan` precedent in this file, and what
/// `CODING_STANDARDS.md` §2 requires of a platform-conditional path.
pub const StopKill = enum {
    /// `kill(-pid, SIGKILL)`: `spawn_detached_native` spawns with
    /// `.pgid = 0`, so the child leads its own group and one syscall reaches
    /// the command AND everything it forked.
    process_group,
    /// `taskkill /T /F /PID`: Windows has no process groups, so the tree walk
    /// is taskkill's job.
    taskkill_tree,
};

pub fn stopPlan(comptime os_tag: std.Target.Os.Tag) []const StopKill {
    return switch (os_tag) {
        .windows => &.{.taskkill_tree},
        else => &.{.process_group},
    };
}

/// Stop a process started by `spawn_detached_native`, tree included.
///
/// Returns true when the process was signalled or was already gone. Unlike
/// `background_process.killProcess` (a single PID through
/// `helpers.process_status`), this signals the whole process GROUP — which is
/// the difference between freeing the port and orphaning vite + esbuild.
pub fn stopDetachedProcess(allocator: std.mem.Allocator, io: std.Io, pid: u32) bool {
    var signalled = false;
    for (stopPlan(builtin.os.tag)) |kill| {
        switch (kill) {
            .process_group => {
                if (comptime builtin.os.tag != .windows) {
                    std.posix.kill(-@as(std.posix.pid_t, @intCast(pid)), .KILL) catch |err| switch (err) {
                        // Already gone is the outcome we wanted.
                        error.ProcessNotFound => {
                            signalled = true;
                            continue;
                        },
                        else => continue,
                    };
                    signalled = true;
                }
            },
            .taskkill_tree => {
                if (comptime builtin.os.tag == .windows) {
                    const pid_str = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch continue;
                    defer allocator.free(pid_str);
                    var child = std.process.spawn(io, .{
                        .argv = &.{ "taskkill", "/T", "/F", "/PID", pid_str },
                        .stdin = .close,
                        .stdout = .ignore,
                        .stderr = .ignore,
                    }) catch continue;
                    const term = child.wait(io) catch continue;
                    signalled = switch (term) {
                        .exited => |code| code == 0,
                        else => false,
                    };
                }
            },
        }
    }
    return signalled;
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

/// Detects forbidden command patterns that produce unbounded output.
/// Currently disabled (returns `false` for every input) — the previous
/// guard list (recursive `ls -R`, `find /` without `-maxdepth`, missing
/// `timeout` / `head -n` prefix) is parked here in commented-out form
/// pending a future hardening PR. Kept verbatim in shell.zig because
/// the rule engine is shell-neutral (the same patterns apply to bash
/// and to PowerShell `Get-ChildItem -Recurse`).
pub fn is_forbidden_command(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // temporary disabled forbidden command
    _ = trimmed;

    return false;
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

test "RunMode: wire spellings round-trip and an unknown value is rejected" {
    // The three categories the product asks for. `fromWire` returning null is
    // what lets the parser produce a structured error naming the field instead
    // of coercing a typo into some default mode.
    try testing.expectEqual(RunMode.foreground, RunMode.fromWire("foreground").?);
    try testing.expectEqual(RunMode.background, RunMode.fromWire("background").?);
    try testing.expectEqual(RunMode.background_persistence, RunMode.fromWire("background_persistence").?);
    try testing.expect(RunMode.fromWire("persistent") == null);
    try testing.expect(RunMode.fromWire("") == null);
    try testing.expect(RunMode.fromWire("Background") == null); // case matters

    for ([_]RunMode{ .foreground, .background, .background_persistence }) |m| {
        try testing.expectEqual(m, RunMode.fromWire(m.toWire()).?);
    }
}

test "RunMode: only foreground blocks, and only a service is silent" {
    try testing.expect(!RunMode.foreground.isDetached());
    try testing.expect(RunMode.background.isDetached());
    try testing.expect(RunMode.background_persistence.isDetached());

    // `kindFor` is what the cron filters on and what the popup shows. Getting
    // it wrong is the difference between "told when the build finished" and
    // "told a month later that the dev server died" — see migration 107.
    try testing.expectEqualStrings("job", RunMode.foreground.kindFor());
    try testing.expectEqualStrings("job", RunMode.background.kindFor());
    try testing.expectEqualStrings("service", RunMode.background_persistence.kindFor());
}

test "resolvedMode: the legacy background boolean keeps working, and mode wins when it says something" {
    // The pre-`mode` world, unchanged.
    try testing.expectEqual(RunMode.background, resolvedMode(.{ .command = "x", .background = true }));
    try testing.expectEqual(RunMode.foreground, resolvedMode(.{ .command = "x" }));

    // A caller that sets only `mode` gets it.
    try testing.expectEqual(
        RunMode.background_persistence,
        resolvedMode(.{ .command = "x", .mode = .background_persistence }),
    );

    // Both set and not contradicting: the explicit mode is the answer, so
    // `mode` can be added to a call site that still carries `background`.
    try testing.expectEqual(
        RunMode.background_persistence,
        resolvedMode(.{ .command = "x", .background = true, .mode = .background_persistence }),
    );

    // The CONTRADICTION is deliberately NOT resolved here — nothing can tell
    // an explicit `foreground` from a defaulted one at this layer, so
    // `parseShellArgs` rejects it before a ShellInput is ever built. This
    // assertion documents which side this function lands on if that guard is
    // ever bypassed: the legacy boolean, because that is what the field said.
    try testing.expectEqual(
        RunMode.background,
        resolvedMode(.{ .command = "x", .background = true, .mode = .foreground }),
    );
}

test "detachedLogPath: never the POSIX literal on Windows, and it is the shared shape" {
    const win = try detachedLogPath(testing.allocator, .windows, "C:\\Temp", 42);
    defer testing.allocator.free(win);
    try testing.expectEqualStrings("C:\\Temp\\bg_42.log", win);

    const nix = try detachedLogPath(testing.allocator, .linux, "/tmp", 42);
    defer testing.allocator.free(nix);
    try testing.expectEqualStrings("/tmp/bg_42.log", nix);
}

test "stopPlan: a stop reaches the whole tree on every platform" {
    // Pure data with the OS tag as a parameter, so the Windows arm is
    // assertable from a Linux runner — without that it could only ever be
    // exercised on a Windows CI cell, which is how the `nohup`-on-Windows bug
    // survived. Same pattern as `timeoutKillPlan` above.
    try testing.expectEqualSlices(StopKill, &.{.process_group}, stopPlan(.linux));
    try testing.expectEqualSlices(StopKill, &.{.process_group}, stopPlan(.macos));
    try testing.expectEqualSlices(StopKill, &.{.taskkill_tree}, stopPlan(.windows));
}

test "spawn_detached_native: pid == pgid, the log is the child's own stdout, and the tree kill works" {
    // The behavioural witness for the whole point of the native spawn. Three
    // things have to hold at once, and none of them is visible from the
    // `nohup cmd & echo $!` path this replaces:
    //
    //   1. the reported PID is the COMMAND's, not a shell wrapper's;
    //   2. that PID is its own process-group leader, so `kill(-pid)` is a tree
    //      kill (asserted directly via getpgid);
    //   3. the child's stdout lands in the log file with no pipes and no
    //      reader threads involved.
    //
    // `background_persistence` is also the mode that must NOT go through
    // `spawn_background`, so a regression that rerouted it would fail (1) and
    // (2) here.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const out = try shell.execute_shell(allocator, io, &.{ "bash", "-c" }, .{
        // A grandchild as well, so the tree kill has something to prove.
        .command = "sh -c 'sleep 300 & ' ; echo detached-probe-marker; sleep 300",
        .cwd = dir,
        .mode = .background_persistence,
    });
    defer {
        allocator.free(out.command);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }

    // "PID: <n>\nLog: <path>". Parsed by locating the markers rather than by
    // counting bytes: `readLogTruncated` and the completion path both consume
    // this same string, and a one-byte slip here (a leading space) reads as
    // "log file not found" everywhere downstream.
    try testing.expect(std.mem.startsWith(u8, out.stdout, "PID: "));
    const nl = std.mem.indexOfScalar(u8, out.stdout, '\n') orelse return error.NoNewline;
    const pid = try std.fmt.parseInt(u32, out.stdout[5..nl], 10);
    const log_at = std.mem.indexOf(u8, out.stdout, "Log: ") orelse return error.NoLogLine;
    const log_path = std.mem.trim(u8, out.stdout[log_at + "Log: ".len ..], " \r\n");
    try testing.expect(std.mem.endsWith(u8, log_path, ".log"));
    defer _ = stopDetachedProcess(allocator, io, pid);

    // (2) pid == pgid — the property `kill(-pid)` depends on.
    // `std.posix` has no `getpgid` in Zig 0.16 (only `std.os.linux`'s raw
    // syscall), so libc is called directly — the same approach this file
    // already takes for `nanosleep` and the Win32 pair.
    const pgid = getpgid(@intCast(pid));
    if (pgid < 0) {
        std.debug.print("getpgid({d}) failed\n", .{pid});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(c_int, @intCast(pid)), pgid);

    // (2b) a NEW group, not OUR group: if the child had inherited ours, the
    // tree kill would signal the test runner itself.
    const our_pgid = getpgid(0);
    try testing.expect(our_pgid != pgid);

    // (3) the output reached the log, with no pipes in the way.
    var attempts: usize = 0;
    var saw_marker = false;
    while (attempts < 300) : (attempts += 1) {
        const content = std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .limited(4096)) catch "";
        defer if (content.len > 0) allocator.free(content);
        if (std.mem.indexOf(u8, content, "detached-probe-marker") != null) {
            saw_marker = true;
            break;
        }
        helpers.sleepMillis(10);
    }
    if (!saw_marker) return error.ChildOutputNeverReachedTheLog;

    // (4) the stop really stops it — and this is where the zombie distinction
    // bites, which is why the probe has to be the REAPER and not `kill(pid, 0)`.
    //
    // After SIGKILL the child is a ZOMBIE until someone waits on it, and a
    // zombie answers `kill(pid, 0)` with SUCCESS. This test found that the hard
    // way: asserting `!isProcessRunning(pid)` here FAILED on a process that was
    // already dead. The same fact is why the service reaper exists — without
    // it, a `background_persistence` process that exited would read as running
    // for the life of the server.
    try testing.expect(stopDetachedProcess(allocator, io, pid));
    attempts = 0;
    var reaped = false;
    while (attempts < 300) : (attempts += 1) {
        if (shell.reap_pid_nohang(pid) == .exited) {
            reaped = true;
            break;
        }
        helpers.sleepMillis(10);
    }
    try testing.expect(reaped);

    // ...and once it IS reaped the signal probe finally agrees, so a caller
    // that reaps first reads the truth either way.
    try testing.expect(!processAliveForTest(pid));
}

/// POSIX `getpgid(2)`. Declared here rather than reached through `std`
/// because Zig 0.16's `std.posix` does not expose it (only `std.os.linux`'s
/// raw syscall, which has no macOS arm); libc is linked on every POSIX target
/// this runs on. Used ONLY by the detached-spawn test above.
extern "c" fn getpgid(pid: c_int) c_int;

/// `kill(pid, 0)` probe used only by the detached-spawn test above.
fn processAliveForTest(pid: u32) bool {
    if (comptime builtin.os.tag == .windows) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch return false;
    return true;
}

test "shell.ShellInput JSON schema: same field set as BashInput (alias carries through)" {
    // shell.ShellInput is the canonical type; BashInput and PwshInput are
    // `pub const = ShellInput` aliases in their per-shell wrappers. The
    // JSON-schema parser must accept the same JSON for both names. This
    // is the "same interface" promise on the backend wire.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const json_str =
        \\{"command":"echo hi","cwd":"/tmp","timeout":5}
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
    try testing.expectEqual(@as(u32, 5), a.value.timeout.?);
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
        .timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings("true", out.command);
}

test "shell.execute_shell enforces timeout (returns TimeoutMissing when null)" {
    // Smoke check that the precondition guard at the top of
    // shell.execute_shell is wired up. The plan locks this contract via
    // bash_test.zig's existing TimeoutMissing test (kept unchanged).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "sleep 60",
        .cwd = "/tmp",
        .timeout = null,
    });
    try testing.expectError(error.TimeoutMissing, out);
}

test "shell.execute_shell rejects timeout above MAX_TIMEOUT_SEC" {
    // A huge deadline is the same as no deadline. The over-max guard
    // fires before any child is spawned, so these run on ALL platforms.
    // Boundary: MAX is accepted (validation passes), MAX+1 is rejected.
    try testing.expectEqual(@as(u32, 60), shell.MAX_TIMEOUT_SEC);

    const over_max = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .timeout = shell.MAX_TIMEOUT_SEC + 1,
    });
    try testing.expectError(error.TimeoutTooLarge, over_max);

    // The exact value from the user report that motivated the cap.
    const absurd = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "echo should-never-run",
        .cwd = "/tmp",
        .timeout = 120000,
    });
    try testing.expectError(error.TimeoutTooLarge, absurd);
}

test "shell.execute_shell accepts timeout at exactly MAX_TIMEOUT_SEC" {
    // Positive control: the boundary value itself must pass validation.
    // Runs `true` (instant) so the 60 s deadline never matters.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .timeout = shell.MAX_TIMEOUT_SEC,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
}

test "shell.execute_shell: a pipe holder that escapes the deadline kill cannot hold the call open" {
    // The deadline path kills the child's PROCESS GROUP, so a descendant that
    // stays in the group releases the pipe and the reader threads finally see
    // EOF. The process group is not the whole story: `setsid` — which is what
    // `nohup`, a daemonizing wrapper, or a shell with job control does — puts
    // the descendant in a NEW session, in a process group `kill(-pgid, .KILL)`
    // cannot reach. It still holds the pipe write ends, so both reader threads
    // stay parked in `readStreaming`, and the unconditional
    // `stdout_thread.join()` / `stderr_thread.join()` after the kill blocks the
    // tool for as long as that descendant lives. That is the reported symptom:
    // the deadline fired, the tool never returned, and the agent workflow loop
    // hung with it.
    //
    // The escaped holder here releases the pipe after 6 s, so a regression
    // costs 6 s instead of hanging the suite; the deadline is 1 s. A bounded
    // implementation returns on the deadline's schedule (deadline + kill grace
    // + reader-join grace); the unbounded one returns whenever the holder
    // decides to let go.
    if (builtin.os.tag != .linux) return; // `setsid` ships with util-linux.

    const io = std.testing.io;
    const start = std.Io.Timestamp.now(io, .real).nanoseconds;
    const out = try shell.execute_shell(testing.allocator, io, &.{ "bash", "-c" }, .{
        .command = "setsid bash -c 'sleep 6; exec 1>&- 2>&-' &",
        .cwd = "/tmp",
        .timeout = 1,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    const elapsed_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - start, 1_000_000));

    // Positive control: `timeout` can only be true if the readers were still
    // waiting for EOF when the deadline arrived — i.e. the escaped holder
    // really did survive the group kill. Had it died with the group, the call
    // would have returned before the deadline with `timeout == false`.
    try testing.expect(out.timeout);
    // ...and it returned on OUR schedule, not on the escaped holder's.
    try testing.expect(elapsed_ms < 4500);

    // The other half of the deal: the reader that was left behind is not a leak.
    // The escaped holder releases the pipe at the 6 s mark, the abandoned thread
    // sees EOF, frees its own state and decrements the counter — so nothing stays
    // allocated for the life of the process.
    const handoff_deadline = std.Io.Timestamp.now(io, .real).nanoseconds + 4 * std.time.ns_per_s;
    while (abandoned_reader_count.load(.monotonic) > 0 and
        std.Io.Timestamp.now(io, .real).nanoseconds < handoff_deadline)
    {
        helpers.sleepMillis(10);
    }
    try testing.expectEqual(@as(usize, 0), abandoned_reader_count.load(.monotonic));
}

test "shell.timeoutKillPlan: the deadline terminates the child on EVERY platform" {
    // The reported Windows hang: both kill sites were
    // `if (comptime builtin.os.tag != .windows)`, so on Windows the deadline
    // recorded `timeout_hit` and then waited on a child nobody had asked to stop
    // — the dialog stayed on screen and the tool stayed blocked behind it.
    //
    // The plan is pure data with the OS tag as a PARAMETER rather than a read of
    // `builtin.os.tag`, precisely so the Windows arm is assertable from a Linux
    // runner (the `backgroundSpec` precedent in this file). Without that, the
    // arm can only ever be exercised on a Windows CI cell.
    try testing.expectEqualSlices(TimeoutKill, &.{.child_handle}, timeoutKillPlan(.windows));
    try testing.expectEqualSlices(TimeoutKill, &.{.process_group}, timeoutKillPlan(.linux));
    try testing.expectEqualSlices(TimeoutKill, &.{.process_group}, timeoutKillPlan(.macos));
}

test "shell.execute_shell requires cwd in BOTH modes (MandatoryCwdMissing)" {
    // `cwd` is not merely documented as required. Without it the child
    // inherits the SERVER process's working directory — which is how a
    // `background=true` build silently compiled the wrong checkout. The guard
    // fires before any spawn, so this runs on ALL platforms.
    try testing.expectError(
        error.MandatoryCwdMissing,
        shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
            .command = "echo should-never-run",
            .cwd = null,
            .timeout = 5,
        }),
    );

    // The empty string is the same omission, spelled by a caller that sent a
    // blank field.
    try testing.expectError(
        error.MandatoryCwdMissing,
        shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
            .command = "echo should-never-run",
            .cwd = "",
            .timeout = 5,
        }),
    );

    // Background too — this is the mode that made the bug invisible: it
    // accepted `cwd`, discarded it, and still reported success.
    try testing.expectError(
        error.MandatoryCwdMissing,
        shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
            .command = "echo should-never-run",
            .cwd = null,
            .background = true,
        }),
    );
}

test "shell.execute_shell rejects a relative cwd (CwdNotAbsolute)" {
    // A relative path resolves against the server's cwd — the same
    // wrong-directory bug, harder to notice because the caller believes it
    // named a location.
    try testing.expectError(
        error.CwdNotAbsolute,
        shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
            .command = "echo should-never-run",
            .cwd = "src/modules",
            .timeout = 5,
        }),
    );
}

test "foreground: the child runs IN cwd, not in the harness's cwd" {
    // Behavioural witness for the `cwd` contract: `pwd -P` must print the
    // directory the caller named. Before the guard a missing `cwd` fell back
    // to `.inherit` (the server/test-runner cwd = the repo root), so this
    // compared equal to the wrong tree.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const out = try shell.execute_shell(allocator, io, &.{ "bash", "-c" }, .{
        .command = "pwd -P",
        .cwd = dir,
        .timeout = 20,
    });
    defer {
        allocator.free(out.command);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }

    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings(dir, std.mem.trimEnd(u8, out.stdout, "\n"));
}

test "background: the DETACHED process starts in cwd, not the server's" {
    // The regression this pins: `spawn_background` hardcoded `.cwd = .inherit`
    // and was never even handed `input.cwd`, so a detached command ran in the
    // SERVER's working directory. A `background=true` build therefore compiled
    // the main checkout (and installed into its `zig-out`) while the operator
    // watched a worktree.
    //
    // The witness is a file the detached process creates: the process itself
    // is gone by the time we look, so its working directory has to be observed
    // through what it left behind. `tmp.dir` is scoped to the directory we
    // named, so the marker existing at all PROVES it ran there.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const allocator = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..dir_len];

    const out = try shell.execute_shell(allocator, io, &.{ "bash", "-c" }, .{
        .command = "touch bg_cwd_probe_marker",
        .cwd = dir,
        .background = true,
    });
    defer {
        allocator.free(out.command);
        allocator.free(out.stdout);
        allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);

    // The detach is asynchronous, so poll rather than sleeping a fixed guess —
    // a fixed sleep is the flaky half of this kind of test. The `else` names
    // the failure: the marker never appeared under the cwd we passed.
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        const stat = tmp.dir.access(io, "bg_cwd_probe_marker", .{});
        if (stat) |_| break else |err| switch (err) {
            error.FileNotFound => pollSleep10ms(),
            else => return err,
        }
    } else {
        return error.DetachedProcessDidNotRunInCwd;
    }
}

test "shell.execute_shell background mode is exempt from the max-timeout cap" {
    // Background detaches via nohup and ignores the timeout by design,
    // so an over-max deadline there must NOT return TimeoutTooLarge.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .background = true,
        .timeout = 120000,
    });
    if (out) |r| {
        testing.allocator.free(r.command);
        testing.allocator.free(r.stdout);
        testing.allocator.free(r.stderr);
    } else |err| {
        try testing.expect(err != error.TimeoutTooLarge);
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
        \\{"command":"x","cwd":"/tmp","timeout":3,"max_output":10,
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
    try testing.expect(a.value.timeout.? == b.value.timeout.?);
    try testing.expect(b.value.timeout.? == c.value.timeout.?);
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
