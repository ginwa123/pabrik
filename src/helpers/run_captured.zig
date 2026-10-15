//! run_captured — the ONE safe way to spawn a child process and capture its
//! stdout + stderr from inside a long-lived, multithreaded server.

const std = @import("std");
const builtin = @import("builtin");

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

/// `/bin/sh` is not available on Windows, and the payloads below are
/// POSIX shell snippets. Skip rather than fail there.
const posix_only = if (builtin.os.tag == .windows) true else false;

fn skipOnWindows() bool {
    if (posix_only) return true;
    return false;
}

const SH = "/bin/sh";

/// The shortest child that exists on the host, so the *host's own* pipe
/// plumbing gets exercised on every platform.
const probe_argv: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "cmd.exe", "/C", "echo hello" },
    else => &.{ SH, "-c", "printf 'hello'" },
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
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'hello'; printf 'oops' 1>&2" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);

    try testing.expectEqualStrings("hello", r.stdout);
    try testing.expectEqualStrings("oops", r.stderr);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expect(!r.timed_out);
}

test "run: reports a non-zero exit code and still captures stderr" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'partial' ; printf 'boom' 1>&2; exit 3" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 3), r.term.exited);
    try testing.expectEqualStrings("partial", r.stdout);
    try testing.expectEqualStrings("boom", r.stderr);
}

test "run: a child that never exits is killed at the deadline" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{ .timeout_ms = 250 });
    defer r.deinit(gpa);

    try testing.expect(r.timed_out);
    // `kill` sends SIGKILL *and* reaps, so no zombie survives and the
    // caller must not wait() again.
    try testing.expect(r.term == .signal);
}

test "run: large stderr does not deadlock (the runGhPrView regression)" {
    // `gh` printing more than one pipe buffer to stderr used to wedge the
    // worker thread forever: the old code drained stdout to EOF first, so
    // `gh` blocked in write(2) on a full stderr pipe and never closed stdout.
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{
        SH,
        "-c",
        \\i=0; while [ $i -lt 512 ]; do
        \\  i=$((i+1)); printf '%s' "0123456789012345678901234567890123456789012345678901234567890123"
        \\done 1>&2; printf 'done'
    }, .{ .timeout_ms = 20_000, .max_output_bytes = 8 * 1024 });
    defer r.deinit(gpa);

    try testing.expect(!r.timed_out);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqualStrings("done", r.stdout);
    // Capped, not truncated-mid-byte, and the rest was drained.
    try testing.expectEqual(@as(usize, 8 * 1024), r.stderr.len);
}

test "run: large stdout is capped but the child still exits cleanly" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{
        SH,
        "-c",
        \\i=0; while [ $i -lt 512 ]; do
        \\  i=$((i+1)); printf '%s' "0123456789012345678901234567890123456789012345678901234567890123"
        \\done
    }, .{ .timeout_ms = 20_000, .max_output_bytes = 4 * 1024 });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqual(@as(usize, 4 * 1024), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "run: both streams large at once" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const script =
        \\i=0; while [ $i -lt 256 ]; do
        \\  i=$((i+1)); printf 'o'; printf 'e' 1>&2
        \\done
    ;
    var r = try run(gpa, testing.io, &.{ SH, "-c", script }, .{
        .timeout_ms = 20_000,
        .max_output_bytes = 64 * 1024,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 256), r.stdout.len);
    try testing.expectEqual(@as(usize, 256), r.stderr.len);
}

test "run: empty output on both streams" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "exit 0" }, .{ .timeout_ms = 10_000 });
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
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const result = run(gpa, testing.io, &.{ SH, "-c", "true" }, .{
        .cwd = "/pabrik/no/such/directory/xyzzy",
    });
    try testing.expectError(error.FileNotFound, result);
}

test "run: honours cwd" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "pwd" }, .{ .cwd = "/tmp" });
    defer r.deinit(gpa);

    // Assert against the CANONICAL form of the directory we asked for, not
    // the literal string we passed in.
    const canonical_tmp = try std.Io.Dir.realPathFileAbsoluteAlloc(testing.io, "/tmp", gpa);
    defer gpa.free(canonical_tmp);

    try testing.expectEqualStrings(canonical_tmp, std.mem.trimEnd(u8, r.stdout, "\r\n"));
}

test "run: non-UTF8 bytes survive capture" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf '\\377\\376\\000raw'" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);
    try testing.expectEqualStrings(&[_]u8{ 0xff, 0xfe, 0x00, 'r', 'a', 'w' }, r.stdout);
}

test "run: a child killed by a signal is reported as .signal" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "kill -9 $$" }, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);
    try testing.expect(r.term == .signal);
    try testing.expect(!r.timed_out);
}

test "run: timeout_ms = 0 kills immediately without hanging" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{ .timeout_ms = 0 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: a grandchild holding the pipes does not survive the deadline" {
    // The shell script forks `sleep`, so killing only the direct child leaves
    // `sleep` holding the stdout/stderr write ends open — the drain threads
    // would never see EOF and the caller would hang even though "the child"
    if (skipOnWindows()) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 300" }, .{ .timeout_ms = 300 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
    try testing.expect(r.term == .signal);
    // And nothing is left behind: no orphaned reader, no leaked fd.
    const after = countOpenFds() orelse return error.SkipZigTest;
    try testing.expect(after <= before + 2);
}

test "run: kill_process_group = false still returns on a plain child" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{
        .timeout_ms = 200,
        .kill_process_group = false,
    });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: no fd leak across many runs" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;
    for (0..25) |_| {
        var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'x'; printf 'y' 1>&2" }, .{
            .timeout_ms = 10_000,
        });
        defer r.deinit(gpa);
    }
    const after = countOpenFds() orelse return error.SkipZigTest;
    // A leaked descriptor per run is the classic symptom of a
    // childCleanupPosix double-close being "fixed" by not closing at
    // all. Allow a small slack for the allocator, not 25 fds.
    try testing.expect(after <= before + 4);
}

test "run: concurrent callers do not corrupt each other's output" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;

    const threads = try gpa.alloc(std.Thread, 8);
    defer gpa.free(threads);
    const oks = try gpa.alloc(bool, 8);
    defer gpa.free(oks);

    for (0..8) |i| {
        oks[i] = false;
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{ gpa, &oks[i] });
    }
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);

    const after = countOpenFds() orelse return error.SkipZigTest;
    try testing.expect(after <= before + 8);
}

fn concurrentWorker(gpa: std.mem.Allocator, ok: *bool) void {
    ok.* = true;
    for (0..10) |_| {
        var r = run(gpa, testing.io, &.{
            SH, "-c",
            \\i=0; while [ $i -lt 128 ]; do i=$((i+1)); printf 'o'; printf 'e' 1>&2; done
        }, .{ .timeout_ms = 20_000 }) catch {
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

fn countOpenFds() ?usize {
    var dir = std.Io.Dir.cwd().openDir(testing.io, "/proc/self/fd", .{ .iterate = true }) catch return null;
    defer std.Io.Dir.close(dir, testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(testing.io) catch null) |_| n += 1;
    return n;
}
