//! run_captured — the ONE safe way to spawn a child process and capture its
//! stdout + stderr from inside a long-lived, multithreaded server.

const std = @import("std");
const builtin = @import("builtin");
const open_descriptors = @import("open_descriptors.zig");

/// Default per-stream capture cap. Matches the 64 KiB every hand-rolled
/// caller had hardcoded, and is comfortably larger than any `gh pr view`
/// payload.
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 64 * 1024;

/// Default wall-clock budget for a child process. Long enough for a
/// slow `gh` over a bad connection, short enough that a wedged worker
/// thread recovers.
pub const DEFAULT_TIMEOUT_MS: u32 = 30_000;

/// How long to keep waiting for the drain threads AFTER killing the child's
/// process group.
const POST_KILL_GRACE_MS: u32 = 500;

/// POSIX process groups (`setpgid` / `kill(-pgid)`) are meaningless on
/// Windows, which has no such concept in the POSIX sense.
const posix_process_groups = switch (builtin.os.tag) {
    .windows => false,
    else => true,
};

/// "This pipe does not exist" for a [`std.Io.File.Handle`].
const no_handle: std.Io.File.Handle = switch (builtin.os.tag) {
    .windows => std.os.windows.INVALID_HANDLE_VALUE,
    else => -1,
};

/// Stand-in for a pipe `spawn` declined to hand us (`.stdout = .pipe` always
/// yields one, so this is unreachable in practice).
const absent_pipe: std.Io.File = .{ .handle = no_handle, .flags = .{ .nonblocking = false } };

/// Output + exit status of a finished child. Both buffers are owned by
/// the caller; release them with [`Result.deinit`].
pub const Result = struct {
    /// How the child terminated.
    term: std.process.Child.Term,
    /// Captured stdout, at most `Options.max_output_bytes` long.
    stdout: []u8,
    /// Captured stderr, at most `Options.max_output_bytes` long.
    stderr: []u8,
    /// True when the child had to be killed because it outlived
    /// `Options.timeout_ms`. Callers should treat the output as partial.
    timed_out: bool,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }
};

pub const Options = struct {
    /// Working directory for the child. `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// Per-stream capture cap. Output beyond this is discarded (but
    /// still drained, so the child is never blocked by a full pipe).
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
    /// Wall-clock budget. `null` disables the deadline — only pass that
    /// for children you control the lifetime of.
    timeout_ms: ?u32 = DEFAULT_TIMEOUT_MS,
    /// Put the child in its own process group and, on timeout, kill the whole
    /// group.
    kill_process_group: bool = true,
};

pub const RunError = std.mem.Allocator.Error ||
    std.process.SpawnError ||
    std.process.Child.WaitError;

/// Close a descriptor without letting Zig abort the process.
fn closeTolerant(handle: std.Io.File.Handle) void {
    if (handle == no_handle) return;
    // `builtin.os.tag` is comptime-known, so only the taken branch is
    // ever analysed: the POSIX body never has to typecheck on Windows
    // and the Windows body never has to link on POSIX.
    switch (builtin.os.tag) {
        .windows => {
            // Same call `Io.Threaded.fileClose` makes on Windows, and already
            // void/tolerant there.
            std.os.windows.CloseHandle(handle);
        },
        else => {
            switch (std.posix.errno(std.posix.system.close(handle))) {
                // A signal arrived mid-close; POSIX says the descriptor may
                // or may not have been released, so retrying is the only way
                // to be sure.
                .INTR => {},
                else => {},
            }
        },
    }
}

/// Minimal lock guarding the shared `gpa` between the two drain threads.
/// `std.atomic.Mutex` only offers `tryLock`, so this spins with a yield
/// fallback.
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        var spins: usize = 0;
        while (!self.state.tryLock()) {
            if (spins < 64) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

/// Per-stream reader state. Lives on `run`'s stack; the drain thread
/// only touches it through `mu` (plus its own `io` / `file` copies,
/// which are immutable).
const Drain = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    cap: usize,
    mu: SpinLock = .{},
    buf: std.ArrayList(u8) = .empty,
    /// Set by the drain thread (or by the inline fallback) once this
    /// stream has hit EOF or an error.
    finished: std.atomic.Value(bool) = .init(false),
    /// `null` when `std.Thread.spawn` failed and we drain inline instead.
    thread: ?std.Thread = null,
    /// Set when we gave up waiting for this stream.
    orphaned: bool = false,

    fn drain(self: *Drain) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            // EndOfStream is how readStreaming reports EOF. Any other
            // error (cancel, EINTR-driven retry exhaustion) ends this
            // stream too — the caller is already on the deadline path.
            const n = std.Io.File.readStreaming(self.file, self.io, &.{&chunk}) catch break;
            if (n == 0) break;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.buf.items.len < self.cap) {
                const take = @min(n, self.cap - self.buf.items.len);
                self.buf.appendSlice(self.gpa, chunk[0..take]) catch break;
            }
            // Past the cap we keep reading and drop the bytes: stopping
            // here would re-fill the pipe and deadlock the child, which
            // is the exact bug this module exists to remove.
        }
        self.finished.store(true, .release);
    }

    fn release(self: *Drain) void {
        self.gpa.free(self.buf.items);
        self.buf = .empty;
    }

    /// Join the drain thread if it reached EOF, otherwise detach it.
    /// Returns the handle to join, or null when we gave up on it.
    fn joinOrAbandon(self: *Drain) ?std.Thread {
        const t = self.thread orelse return null;
        if (!self.finished.load(.acquire)) {
            self.orphaned = true;
            return null;
        }
        return t;
    }
};

/// Windows' process group, as a Job Object: every descendant of an assigned
/// process joins it, so one `TerminateJobObject` takes the whole tree down —
/// what `kill(-pgid)` does for the POSIX path.
const WindowsJob = if (builtin.os.tag == .windows) struct {
    handle: std.os.windows.HANDLE,

    extern "kernel32" fn CreateJobObjectW(
        job_attributes: ?*anyopaque,
        name: ?[*:0]const u16,
    ) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(
        job: std.os.windows.HANDLE,
        process: std.os.windows.HANDLE,
    ) callconv(.winapi) u32;
    extern "kernel32" fn TerminateJobObject(
        job: std.os.windows.HANDLE,
        exit_code: u32,
    ) callconv(.winapi) u32;

    /// Put `process` in a fresh job, or null when Windows refused (an outer
    /// job that forbids nesting). The deadline path then falls back to the
    /// direct-child kill it always had.
    fn attach(process: std.os.windows.HANDLE) ?WindowsJob {
        const handle = CreateJobObjectW(null, null) orelse return null;
        if (AssignProcessToJobObject(handle, process) == 0) {
            std.os.windows.CloseHandle(handle);
            return null;
        }
        return .{ .handle = handle };
    }

    /// `process` itself and every process it spawned.
    fn terminate(self: WindowsJob) void {
        _ = TerminateJobObject(self.handle, 1);
    }

    fn close(self: WindowsJob) void {
        std.os.windows.CloseHandle(self.handle);
    }
} else struct {
    // POSIX has real process groups — `run` kills the whole tree through
    // `kill(-pgid)` — so there is no job to make and nothing to take down.
    fn terminate(self: @This()) void {
        _ = self;
    }

    fn close(self: @This()) void {
        _ = self;
    }
};

/// Spawn `argv`, capture stdout + stderr, reap the child, never abort.
///
/// `argv[0]` is the program, resolved through `PATH` like any exec.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    opts: Options,
) RunError!Result {
    std.debug.assert(argv.len > 0);

    // `.pgid = 0` makes the child `setpgid(0, 0)` — it becomes the leader of
    // a brand-new process group whose id equals its pid. On timeout we can
    // then `kill(-pid)` and take the whole subtree down.
    const own_pg = opts.kill_process_group and posix_process_groups;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |c| .{ .path = c } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (own_pg) 0 else null,
    });

    // Windows' process group for this child, so the deadline path can take
    // its descendants down with it (`WindowsJob`). Best effort: null when
    // Windows refuses to nest a job.
    var job: ?WindowsJob = null;
    if (builtin.os.tag == .windows) job = WindowsJob.attach(child.id.?);
    defer if (job) |j| j.close();

    // Take ownership of both pipes and detach them from the Child in one
    // step.
    const child_pid = child.id;
    const out_file = child.stdout orelse absent_pipe;
    const out_handle = out_file.handle;
    child.stdout = null;
    const err_file = child.stderr orelse absent_pipe;
    const err_handle = err_file.handle;
    child.stderr = null;
    // `.stdin = .ignore` means no stdin pipe, but be explicit so a
    // future options change cannot resurrect the same hazard.
    child.stdin = null;

    // Heap-allocated, not stack: if a drain thread is still wedged when we
    // give up on it, it must not be writing into a frame that `run` has
    // already returned from.
    const out = gpa.create(Drain) catch return error.OutOfMemory;
    defer gpa.destroy(out);
    const errs = gpa.create(Drain) catch return error.OutOfMemory;
    defer gpa.destroy(errs);
    out.* = .{ .gpa = gpa, .io = io, .file = out_file, .cap = opts.max_output_bytes };
    errs.* = .{ .gpa = gpa, .io = io, .file = err_file, .cap = opts.max_output_bytes };
    defer {
        // Only reached when we DID join the threads (or when the spawn of a
        // thread failed and we drained inline), so this frees the captured
        // bytes exactly once.
        if (!out.orphaned) {
            out.release();
            closeTolerant(out_handle);
        }
        if (!errs.orphaned) {
            errs.release();
            closeTolerant(err_handle);
        }
    }

    // Concurrent drain. Two independent pipes means neither can fill up
    // and block the child while we wait on the other one.
    out.thread = std.Thread.spawn(.{}, Drain.drain, .{out}) catch null;
    errs.thread = std.Thread.spawn(.{}, Drain.drain, .{errs}) catch null;
    // Thread creation can fail (fd/memory limits) — drain inline so the
    // caller still gets a correct answer, just serially.
    if (out.thread == null) out.drain();
    if (errs.thread == null) errs.drain();

    var timed_out = false;
    if (opts.timeout_ms) |budget_ms| {
        const start = std.Io.Timestamp.now(io, .awake);
        const deadline = start.addDuration(.fromMilliseconds(@intCast(budget_ms)));
        while (!bothDone(out, errs)) {
            if (std.Io.Timestamp.now(io, .awake).durationTo(deadline).toNanoseconds() <= 0) {
                timed_out = true;
                break;
            }
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
        }
    }

    if (timed_out) {
        // Kill the whole process group first so a grandchild cannot keep the
        // pipes open, then `kill` (which also reaps, and asserts the pipes
        // are detached — they are).
        if (posix_process_groups) {
            if (own_pg) {
                if (child_pid) |pid| {
                    // Negative pid targets the process group. The pid is
                    // still reserved (the child is unreaped), so there is no
                    // reuse hazard here.
                    std.posix.kill(-pid, .KILL) catch {};
                }
            }
        } else if (job) |j| {
            // Windows' process group, for the same reason: the descendants
            // go too, so the pipes close and no drain thread is left wedged
            // behind an orphan that `TerminateProcess` did not reach.
            j.terminate();
        }
        child.kill(io);

        // Bounded grace period for the readers.
        const grace_deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.fromMilliseconds(@intCast(POST_KILL_GRACE_MS)));
        while (!bothDone(out, errs)) {
            if (std.Io.Timestamp.now(io, .awake).durationTo(grace_deadline).toNanoseconds() <= 0) break;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
        }
    }

    if (out.joinOrAbandon()) |t| t.join();
    if (errs.joinOrAbandon()) |t| t.join();

    const result: Result = .{
        .term = if (timed_out)
            // We chose this term; the child never got to report one.
            termForKill()
        else
            // Safe to call: pipes are detached so `childCleanupPosix`
            // has nothing to close.
            (try child.wait(io)),
        .stdout = try out.buf.toOwnedSlice(gpa),
        .stderr = try errs.buf.toOwnedSlice(gpa),
        .timed_out = timed_out,
    };
    // `toOwnedSlice` empties the ArrayList, so the `defer` above will
    // not double-free; keep `result` immutable from here on.
    return result;
}

fn bothDone(out: *const Drain, errs: *const Drain) bool {
    return out.finished.load(.acquire) and errs.finished.load(.acquire);
}

/// The [`Result.term`] we report when WE killed the child on the
/// deadline path. The child never got to report a termination, so
/// there is no real one to describe.
fn termForKill() std.process.Child.Term {
    return switch (builtin.os.tag) {
        // Windows `Child.kill` is `TerminateProcess`: there is no signal, and
        // `Child.wait` never yields `.signal` there either (it reports
        // `.exited` from the process exit status, or `.unknown` when the
        .windows => .{ .unknown = 0 },
        else => .{ .signal = std.posix.SIG.KILL },
    };
}

// ===== Tests =====

const testing = std.testing;

/// Every fixture below is written by `host_fixture`, which renders a
/// `#!/bin/sh` script on POSIX and a `.cmd` on Windows. Zig 0.16's spawn
/// routes a `.cmd` through `cmd.exe /c`, so nothing here declines a host.
const hf = @import("host_fixture.zig");

/// A throwaway directory plus one fixture program, so a test can spawn a
/// child whose behaviour it controls without `/bin/sh` existing.
const Fixture = struct {
    inner: hf.Fixture,

    fn init(a: std.mem.Allocator) !Fixture {
        return .{ .inner = try hf.Fixture.init(a) };
    }

    fn deinit(self: *Fixture) void {
        self.inner.deinit();
    }

    fn write(self: *Fixture, name: []const u8, payload: hf.Payload) ![]u8 {
        return self.inner.writeProgram(name, payload);
    }
};

/// The shortest child that exists on the host, so the *host's own* pipe
/// plumbing gets exercised on every platform.
const probe_argv: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "cmd.exe", "/C", "echo hello" },
    else => &.{ "/bin/sh", "-c", "printf 'hello'" },
};

test "run: a child's stdout comes back on this host's own pipes" {
    // Windows regression: rebuilding the child's `File` around the bare
    // handle dropped `flags.nonblocking = true`, so std read an
    // `ASYNCHRONOUS` pipe in its synchronous branch, got `STATUS_PENDING`
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, probe_argv, .{ .timeout_ms = 20_000 });
    defer r.deinit(gpa);

    try testing.expect(!r.timed_out);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    // `cmd.exe /C echo` emits CRLF; `printf` emits nothing.
    try testing.expectEqualStrings("hello", std.mem.trimEnd(u8, r.stdout, "\r\n"));
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "run: captures stdout and stderr from a successful child" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("child", .{ .stdout = "hello", .stderr = "oops" });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);

    try testing.expectEqualStrings("hello", r.stdout);
    try testing.expectEqualStrings("oops", r.stderr);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expect(!r.timed_out);
}

test "run: reports a non-zero exit code and still captures stderr" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("child", .{
        .stdout = "partial",
        .stderr = "boom",
        .exit_code = 3,
    });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 3), r.term.exited);
    try testing.expectEqualStrings("partial", r.stdout);
    try testing.expectEqualStrings("boom", r.stderr);
}

test "run: a child that never exits is killed at the deadline" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("sleeper", .{ .sleep_ms = 30_000 });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 250 });
    defer r.deinit(gpa);

    try testing.expect(r.timed_out);
    // `kill` sends SIGKILL *and* reaps, so no zombie survives and the
    // caller must not wait() again. Windows has no signal: `Child.kill`
    // is `TerminateProcess`, so the term is `.unknown` there.
    try testing.expect(r.term == .signal or r.term == .unknown);
}

test "run: large stderr does not deadlock (the runGhPrView regression)" {
    // `gh` printing more than one pipe buffer to stderr used to wedge the
    // worker thread forever: the old code drained stdout to EOF first, so
    // `gh` blocked in write(2) on a full stderr pipe and never closed stdout.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    // 512 x 64 bytes = 32 KiB of stderr, well past one pipe buffer, with a
    // stdout line that must still arrive.
    const prog = try fx.write("noisy", .{
        .stdout = "done",
        .stderr = "0123456789012345678901234567890123456789012345678901234567890123",
        .repeat_stderr = 512,
    });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{
        .timeout_ms = 20_000,
        .max_output_bytes = 8 * 1024,
    });
    defer r.deinit(gpa);

    try testing.expect(!r.timed_out);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqualStrings("done", r.stdout);
    // Capped, not truncated-mid-byte, and the rest was drained.
    try testing.expectEqual(@as(usize, 8 * 1024), r.stderr.len);
}

test "run: large stdout is capped but the child still exits cleanly" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("noisy", .{
        .stdout = "0123456789012345678901234567890123456789012345678901234567890123",
        .repeat = 512,
    });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{
        .timeout_ms = 20_000,
        .max_output_bytes = 4 * 1024,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqual(@as(usize, 4 * 1024), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "run: both streams large at once" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("noisy", .{
        .stdout = "o",
        .stderr = "e",
        .repeat = 256,
        .repeat_stderr = 256,
    });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{
        .timeout_ms = 20_000,
        .max_output_bytes = 64 * 1024,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 256), r.stdout.len);
    try testing.expectEqual(@as(usize, 256), r.stderr.len);
}

test "run: empty output on both streams" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("quiet", .{});
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
}

test "run: a missing program surfaces the spawn error, not a panic" {
    const gpa = testing.allocator;
    const result = run(gpa, testing.io, &.{"pabrik-definitely-not-a-real-binary-xyzzy"}, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "run: a non-existent cwd surfaces the spawn error" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("child", .{});
    defer gpa.free(prog);

    const result = run(gpa, testing.io, &.{prog}, .{
        .cwd = "/pabrik/no/such/directory/xyzzy",
    });
    try testing.expectError(error.FileNotFound, result);
}

test "run: honours cwd" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const repo = try fx.inner.subDir("repo");
    defer gpa.free(repo);
    const prog = try fx.write("pwd", .{ .print_cwd = true });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .cwd = repo, .timeout_ms = 10_000 });
    defer r.deinit(gpa);

    // Assert against the CANONICAL form of the directory we asked for, not
    // the literal string we passed in.
    const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(testing.io, repo, gpa);
    defer gpa.free(canonical);

    try testing.expectEqualStrings(canonical, std.mem.trimEnd(u8, r.stdout, "\r\n"));
}

test "run: non-UTF8 bytes survive capture" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    // A NUL and two high bytes: the pipe must carry them untouched, so the
    // capture path cannot be doing any text decoding.
    const prog = try fx.write("raw", .{ .stdout = "\x00\xff\xferaw" });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);
    try testing.expectEqualStrings(&[_]u8{ 0x00, 0xff, 0xfe, 'r', 'a', 'w' }, r.stdout);
}

test "run: a child killed by a signal is reported as .signal" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("suicide", .{ .kill_self = true });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);
    // POSIX reports the signal; Windows has none, so the child exits with a
    // code instead. Either way it must NOT read as a clean success.
    try testing.expect(r.term == .signal or r.term.exited != 0);
    try testing.expect(!r.timed_out);
}

test "run: timeout_ms = 0 kills immediately without hanging" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("sleeper", .{ .sleep_ms = 30_000 });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 0 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: a grandchild holding the pipes does not survive the deadline" {
    // The fixture sleeps, so killing only the direct child would leave a
    // grandchild holding the pipes: the drain threads would never see EOF
    // and the caller would hang even though "the child" is gone.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("sleeper", .{ .sleep_ms = 300_000 });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 300 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
    try testing.expect(r.term == .signal or r.term == .unknown);
}

test "run: kill_process_group = false still returns on a plain child" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("sleeper", .{ .sleep_ms = 30_000 });
    defer gpa.free(prog);

    var r = try run(gpa, testing.io, &.{prog}, .{
        .timeout_ms = 200,
        .kill_process_group = false,
    });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: no fd leak across many runs" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("chatty", .{ .stdout = "x", .stderr = "y" });
    defer gpa.free(prog);

    // Descriptors on POSIX, handles on Windows, from `open_descriptors` — a
    // leaked one per run is the classic symptom of a double-close "fixed" by
    // not closing at all. Slack is for allocator noise, not 25 leaks.
    const before = try open_descriptors.count();
    for (0..25) |_| {
        var r = try run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 10_000 });
        defer r.deinit(gpa);
    }
    const after = try open_descriptors.count();
    try testing.expect(after <= before + 4);
}

test "run: concurrent callers do not corrupt each other's output" {
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa);
    defer fx.deinit();
    const prog = try fx.write("chatty", .{ .stdout = "o", .stderr = "e", .repeat = 128, .repeat_stderr = 128 });
    defer gpa.free(prog);

    const before = try open_descriptors.count();

    const threads = try gpa.alloc(std.Thread, 8);
    defer gpa.free(threads);
    const oks = try gpa.alloc(bool, 8);
    defer gpa.free(oks);

    for (0..8) |i| {
        oks[i] = false;
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{ gpa, prog, &oks[i] });
    }
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);

    const after = try open_descriptors.count();
    try testing.expect(after <= before + 8);
}

fn concurrentWorker(gpa: std.mem.Allocator, prog: []const u8, ok: *bool) void {
    ok.* = true;
    for (0..10) |_| {
        var r = run(gpa, testing.io, &.{prog}, .{ .timeout_ms = 20_000 }) catch {
            ok.* = false;
            return;
        };
        defer r.deinit(gpa);
        if (r.stdout.len != 128 or r.stderr.len != 128 or r.term.exited != 0) {
            ok.* = false;
            return;
        }
    }
}
