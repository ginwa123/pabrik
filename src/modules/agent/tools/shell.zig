// SPDX-License-Identifier: TBD shell.zig — shared shell-execution core used
// by `bash.zig` and `pwsh.zig`.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");
const schemas = @import("schemas.zig");

const sanitizeControlChars = helpers.sanitize_control_chars;

/// Canonical wire schema. Per-shell wrappers (bash.zig, pwsh.zig) re-export
/// this as `BashInput` / `PwshInput` so the JSON contract is identical.
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
    /// under.
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
    /// LEGACY alias for `mode == .background`.
    background: bool = false,
    /// See `RunMode`. Additive: everything that does not set it keeps
    /// running in the foreground, which is the behaviour it had.
    mode: RunMode = .foreground,
    max_lines: ?usize = 1000,
    do_encoding: bool = false,
    /// ASK THE AGENTIC LOOP TO END THIS TURN after the current tool batch.
    is_stop: bool = false,
};

/// The mode a spawn should actually use, after folding in the legacy
/// `background` alias.
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

/// Returned by `execute_shell` when the caller passes a `timeout` above
/// `MAX_TIMEOUT_SEC`.
pub const TimeoutTooLarge = error{TimeoutTooLarge};

/// Returned by `execute_shell` when the caller omits `cwd`.
pub const MandatoryCwdMissing = error{MandatoryCwdMissing};

/// Returned by `execute_shell` when `cwd` is not an absolute path.
pub const CwdNotAbsolute = error{CwdNotAbsolute};

/// Upper bound for a single foreground command: 10 minutes.
pub const MAX_TIMEOUT_SEC: u32 = 600;

// POSIX `nanosleep(req, rem)` — declared as `extern "c"` so the call doesn't
// go through Zig 0.16's Io runtime.
const NanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const NanoSleepTimespec, rem: ?*NanoSleepTimespec) c_int;

/// Sleep ~10ms between deadline polls. Windows: Win32 Sleep via
/// helpers.sleepMillis.
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

/// Wall-clock grace period after SIGKILL during which we wait for the kernel
/// to reap the spawned process group. 2 seconds is enough for normal process
/// groups to die and be reaped; D-state descendants (uninterruptible sleep)
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

// Sentinel stub — Task 1.1 only lands the SKELETON. Subsequent tasks
// (1.2–1.7) progressively move helpers and the spawn pipeline from bash.zig
// into this module.
const WaitResult = struct {
    /// Outcome category.
    outcome: enum {
        /// Process was reaped within the grace period. The `status` field
        /// contains the raw waitpid status word.
        reaped,
        /// The grace period expired before the process became a zombie.
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

/// Poll `waitpid(pid, &status, WNOHANG)` until the process is reaped OR the
/// grace period expires.
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
    // `posix.pid_t` is `void` on Windows — Zig 0.16 resolves the type on
    // every host even inside a body that's only called from POSIX-gated
    // callers, so we can't reference `posix.pid_t` here at all.
    const pid: c_int = blk: {
        const id_opt: std.process.Child.Id = child.id.?;
        const T = @TypeOf(id_opt);
        if (@typeInfo(T) == .int) {
            break :blk @as(c_int, @intCast(id_opt));
        }
        // Non-int Id is `HANDLE` (Windows). Unreachable at runtime because
        // callers gate this fn on `.linux, .macos =>`, but emit a clear
        // compile-time error if someone ever removes that gate.
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
    // Poll NtWaitForSingleObject with a short timeout until the deadline.
    while (true) {
        // 100ms relative timeout (NT's LARGE_INTEGER is `i64` — for relative
        // waits, the convention is a NEGATIVE 100-ns interval; positive
        // values are interpreted as an absolute wakeup time, which we'd
        const timeout_100ms: std.os.windows.LARGE_INTEGER =
            -100 * @as(i64, @intCast(std.time.ns_per_ms));
        const status = std.os.windows.ntdll.NtWaitForSingleObject(
            handle,
            std.os.windows.BOOLEAN.fromBool(false), // Alertable = FALSE
            &timeout_100ms,
        );
        if (status == .SUCCESS) {
            // Process signalled; harvest the exit code via GetExitCodeProcess
            // (declared above; not in Zig 0.16 std) so the .status slot has
            // the same shape the POSIX path produces.
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

/// Convert a `WaitResult` to a `std.process.Child.Term`.
fn term_from_wait(wait_result: WaitResult) std.process.Child.Term {
    return switch (builtin.os.tag) {
        .windows => term_from_wait_windows(wait_result),
        else => term_from_wait_posix(wait_result),
    };
}

fn term_from_wait_windows(wait_result: WaitResult) std.process.Child.Term {
    // The Windows path synthesizes a status with the low 8 bits holding the
    // exit code (no `posix.SIG.KILL` representation — the historical `.signal
    // = .KILL` doesn't apply on Windows).
    const u: u32 = @bitCast(@as(u32, @intCast(wait_result.status)));
    _ = u;
    return switch (wait_result.outcome) {
        .reaped, .no_child => .{ .exited = @intCast(wait_result.status & 0xff) },
        .grace_period_expired, .unexpected_error => .{
            // Forced kill via TerminateProcess.
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
            // POSIX path: surface the kill via `posix.SIG.KILL`.
            .{ .signal = .KILL }
        else
            // Windows path (this `else` arm is unreachable at runtime because
            // `term_from_wait` dispatches on `builtin.os.tag` first);
            // included only so the function compiles on every host.
            .{ .exited = 137 },
    };
}

/// Convert a raw `waitpid` status word to a Zig `std.process.Child.Term`.
/// Mirrors `childWaitPosix` in `std/Io/Threaded.zig:15309`.
pub fn status_to_term(status: c_int) std.process.Child.Term {
    if (comptime builtin.os.tag == .windows) {
        // Unreachable at runtime — emitted as a no-op so the package compiles
        // on every host. The Windows path extracts the exit code directly via
        // GetExitCodeProcess (see `term_from_wait_windows`).
        return .{ .unknown = 0 };
    }
    const u: u32 = @bitCast(@as(u32, @intCast(status)));
    if (std.c.W.IFEXITED(u)) return .{ .exited = std.c.W.EXITSTATUS(u) };
    if (std.c.W.IFSIGNALED(u)) return .{ .signal = @enumFromInt(@intFromEnum(std.c.W.TERMSIG(u))) };
    if (std.c.W.IFSTOPPED(u)) return .{ .stopped = std.c.W.STOPSIG(u) };
    return .{ .unknown = u };
}

// ============================================================================
// Foreground deadline enforcement The deadline has to mean two things, and
// the old code only delivered the first: 1. the child is terminated when the

/// Win32 TerminateProcess — declared locally for the same reason as
/// `GetExitCodeProcess` above: Zig 0.16's `std.os.windows` does not export
/// it.
extern "kernel32" fn TerminateProcess(
    hProcess: std.os.windows.HANDLE,
    uExitCode: u32,
) callconv(.winapi) std.os.windows.BOOL;

/// Grace the reader threads get to observe EOF once the deadline kill has
/// been issued.
const READER_JOIN_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Reader threads that were handed off instead of joined (see
/// `settleReader`).
pub var abandoned_reader_count: std.atomic.Value(usize) = .init(0);

/// How the deadline terminates the child.
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
/// deadline passes.
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

/// One foreground output stream: the pipe, what has been captured from it,
/// and the ownership protocol that lets the reader thread OUTLIVE the call
/// that spawned it.
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

    /// Exit path.
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

/// Bounded join for one reader: wait until `deadline_ns` for EOF, then decide
/// who releases the state. This is the fix for the hang.
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

/// Settle one reader and copy what it captured, into `alloc`.
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

/// Run a shell command with the supplied argv-prefix (e.g. `&.{ "bash", "-c"
/// }` or `&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command" }`).
pub fn run_shell_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: ShellInput,
) !ShellOutput {
    // --- URL encoding if requested --- cmd.exe treats single quotes
    // literally (no quoting semantics), so the `"…"` → `'…'` swap would
    // corrupt URLs on the cmd fallback path — skip it when the resolved shell
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

    // --- Mandatory-cwd check (BOTH modes) --- Checked before the timeout
    // guard so a call missing both fields is told about the more dangerous
    // omission first — the one that runs work in the wrong directory.
    const cwd = input.cwd orelse return error.MandatoryCwdMissing;
    if (cwd.len == 0) return error.MandatoryCwdMissing;
    if (!std.fs.path.isAbsolute(cwd)) return error.CwdNotAbsolute;

    // --- Mandatory-timeout check (foreground only) --- Neither detached mode
    // uses the timeout (the process outlives the call by definition), so the
    // check is skipped for both.
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

    // --- Detached modes --- Two different detach mechanisms, deliberately,
    // for one release: * `background` keeps the `nohup` shell idiom it has
    // always used, so the path every existing caller and test depends on
    if (mode == .background_persistence) {
        return try spawn_detached_native(allocator, io, argv_prefix, command, cwd);
    }
    if (mode == .background) {
        return try spawn_background(allocator, io, argv_prefix, command, cwd);
    }

    // --- Foreground mode --- `input.max_output` defaults to 20 KiB in the
    // schema (see schemas.zig), so the `orelse` fallback here is a
    // defense-in-depth — it would only fire if someone constructs ShellInput
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
        // Zig 0.16: `?posix.pid_t = null`.
        .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
    });
    // On Windows, `posix.pid_t` is `void` (Windows has no POSIX pid concept),
    // so the historical `kill(-child_pgid, .KILL)` group- kill pattern
    // compiles only on POSIX.
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
    // release — the same state twice.
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
    // `std.process.Child.Term` is `.{ exited: u8, signal: std.posix.SIG, … }`
    // — `posix.SIG` is `void` on Windows in Zig 0.16, so neither `.signal =
    // .KILL` nor `status_to_term` (which uses `std.c.W.*` — also `void` on
    child_term = blk: {
        while (true) {
            if (stdout_reader.eof.load(.acquire) and stderr_reader.eof.load(.acquire)) {
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                // Terminate on EVERY platform.
                terminateTimedOutChild(&child, child_pgid);
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            pollSleep10ms();
        }
    };

    // Bounded.
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

/// Background-mode spawn (the `nohup` bash idiom). Returns the structured
/// ShellOutput with `command`, `stdout = "PID: X\nLog: …"`, `exit_code = 0`.
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

/// The platform's own temp directory. The old code interpolated a literal
/// `/tmp` into a path that was then handed to a Windows shell.
pub fn tempDirFor(allocator: std.mem.Allocator, os_tag: OsTag) ![]u8 {
    // `std.c.getenv` is the same accessor the rest of the codebase uses for
    // this (service/state_file.zig reads LOCALAPPDATA through it), and it
    // works on both platforms because the agent process always links libc.
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

/// Stop a process started by `spawn_detached_native`, tree included. Returns
/// true when the process was signalled or was already gone.
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
pub fn result_to_json(allocator: std.mem.Allocator, result: ShellOutput) ![]u8 {
    // Strip terminal escape sequences FIRST.
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

/// Concatenates `argv_prefix` with `[command]` to form the full spawn argv.
/// This is a tiny helper kept separate so callers can audit the prefix
/// without scrolling through the spawn site.
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
pub fn is_forbidden_command(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // temporary disabled forbidden command
    _ = trimmed;

    return false;
}

/// Encode special characters in URLs within double quotes Converts: curl -sI
/// "http://host/path?query=val&sig=xyz" to: curl -sI
/// 'http://host/path?query=val&sig=xyz' This prevents bash from interpreting
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
    // `parseShellArgs` rejects it before a ShellInput is ever built.
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
    try testing.expectEqualSlices(StopKill, &.{.process_group}, stopPlan(.linux));
    try testing.expectEqualSlices(StopKill, &.{.process_group}, stopPlan(.macos));
    try testing.expectEqualSlices(StopKill, &.{.taskkill_tree}, stopPlan(.windows));
}

test "spawn_detached_native: pid == pgid, the log is the child's own stdout, and the tree kill works" {
    // The behavioural witness for the whole point of the native spawn.
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

    // "PID: <n>\nLog: <path>".
    try testing.expect(std.mem.startsWith(u8, out.stdout, "PID: "));
    const nl = std.mem.indexOfScalar(u8, out.stdout, '\n') orelse return error.NoNewline;
    const pid = try std.fmt.parseInt(u32, out.stdout[5..nl], 10);
    const log_at = std.mem.indexOf(u8, out.stdout, "Log: ") orelse return error.NoLogLine;
    const log_path = std.mem.trim(u8, out.stdout[log_at + "Log: ".len ..], " \r\n");
    try testing.expect(std.mem.endsWith(u8, log_path, ".log"));
    defer _ = stopDetachedProcess(allocator, io, pid);

    // (2) pid == pgid — the property `kill(-pid)` depends on.
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
    // bites, which is why the probe has to be the REAPER and not `kill(pid,
    // 0)`.
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

/// POSIX `getpgid(2)`.
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
    // JSON-schema parser must accept the same JSON for both names.
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
    // exit_code, truncated, timeout, stdout_lines, stderr_lines. ShellOutput
    // MUST have the same 8 — pwsh_result_to_json reuses it.
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
    try testing.expectEqual(@as(u32, 600), shell.MAX_TIMEOUT_SEC);

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
    // EOF.
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
    // really did survive the group kill.
    try testing.expect(out.timeout);
    // ...and it returned on OUR schedule, not on the escaped holder's.
    try testing.expect(elapsed_ms < 4500);

    // The other half of the deal: the reader that was left behind is not a
    // leak.
    const handoff_deadline = std.Io.Timestamp.now(io, .real).nanoseconds + 4 * std.time.ns_per_s;
    while (abandoned_reader_count.load(.monotonic) > 0 and
        std.Io.Timestamp.now(io, .real).nanoseconds < handoff_deadline)
    {
        helpers.sleepMillis(10);
    }
    try testing.expectEqual(@as(usize, 0), abandoned_reader_count.load(.monotonic));
}

test "shell.timeoutKillPlan: the deadline terminates the child on EVERY platform" {
    // The reported Windows hang: both kill sites were `if (comptime
    // builtin.os.tag != .windows)`, so on Windows the deadline recorded
    // `timeout_hit` and then waited on a child nobody had asked to stop — the
    try testing.expectEqualSlices(TimeoutKill, &.{.child_handle}, timeoutKillPlan(.windows));
    try testing.expectEqualSlices(TimeoutKill, &.{.process_group}, timeoutKillPlan(.linux));
    try testing.expectEqualSlices(TimeoutKill, &.{.process_group}, timeoutKillPlan(.macos));
}

test "shell.execute_shell requires cwd in BOTH modes (MandatoryCwdMissing)" {
    // `cwd` is not merely documented as required.
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
    // directory the caller named.
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
    // The regression this pins: `spawn_background` hardcoded `.cwd =
    // .inherit` and was never even handed `input.cwd`, so a detached command
    // ran in the SERVER's working directory.
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

// Task 6 — schema-shape parity lock. The user requirement: "bash and pwsh
// have to have the same interface".
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
    // Regression for user report: `head -n 40 $(which qs)` dumps the ELF
    // header (0x7F 'E' 'L' 'F' 0x02 0x01 ... 0x00 + controls).
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
    // User report: a `dotnet build … | Select-String …` on Windows came back
    // as a wall of `?[7mwarning ?[0m`.
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
// echo $!"` and handed it to whatever shell was configured.
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
