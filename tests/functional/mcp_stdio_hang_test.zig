//! End-to-end functional test for the MCP stdio timeout / cancel-callback /
//! markStale self-healing fix (plan 2026-08-28-fix-mcp-stdio-blocking). The
//! fix's three layers: 1.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const builtin = @import("builtin");

/// The hung-server fixture, relative to the REPO ROOT. Python derived this
/// from `Path(__file__).resolve().parent`, which is absolute by construction.
const HUNG_SERVER = "tests/functional/fixtures/hung-server.sh";

/// The canonical MCP stdio `tools/list` frame, plus the extra newline the
/// Python wrote so the fixture's `read -r _discarded` returns.
const TOOLS_LIST_FRAME =
    "Content-Length: 78\r\n\r\n" ++
    "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tools/list\",\"params\":{}}";

/// `_wait_for_timeout(proc, deadline_s=1.0)`'s deadline, in ms.
const DEADLINE_MS: i64 = 1000;

/// `select.select([proc.stdout], [], [], 0.5)`'s poll slice.
const POLL_SLICE_MS: i64 = 500;

/// A hung child plus the scratch file its stdout lands in.
const Hung = struct {
    child: std.process.Child,
    pid: u32,
    stdout_path: []u8,

    /// SIGKILL the child and reap it.
    fn deinit(self: *Hung) void {
        self.child.kill(io);
        gpa.free(self.stdout_path);
    }

    /// The bytes the child has written to stdout so far. Owned. A hung
    /// fixture writes none, so this is normally empty; a non-empty result is
    /// the failure signal.
    fn readStdout(self: *Hung) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.stdout_path, gpa, .limited(1 << 20)) catch
            try gpa.dupe(u8, "");
    }
};

/// Python's `_hung_argv()`: skip unless the fixture is there AND executable.
fn hungArgv() ![]const u8 {
    std.Io.Dir.cwd().access(io, HUNG_SERVER, .{ .execute = true }) catch {
        std.debug.print(
            "hung-server.sh missing or not executable: {s}\n",
            .{HUNG_SERVER},
        );
        return error.SkipZigTest;
    };
    return HUNG_SERVER;
}

/// `kill(pid, 0)` — Python's `proc.poll() is None`, inverted.
fn childAlive(pid: u32) bool {
    if (builtin.os.tag == .windows) return true;
    const p: std.posix.pid_t = @intCast(pid);
    std.posix.kill(p, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    return true;
}

/// Spawn the hung fixture with `stdin_text` already in its stdin file.
fn spawnHung(scratch: []const u8, stdin_text: []const u8) !Hung {
    const argv = try hungArgv();

    const stdin_path = try std.fs.path.join(gpa, &.{ scratch, "hung-stdin" });
    defer gpa.free(stdin_path);
    const stdout_path = try std.fs.path.join(gpa, &.{ scratch, "hung-stdout" });
    errdefer gpa.free(stdout_path);

    // Both handles stay open until the spawn returns: `SpawnOptions
    // .stdin/.stdout = .{ .file = h }` hands the CHILD its own dup of the
    // descriptor, so closing early would leave the fixture reading and
    var in_file = try std.Io.Dir.cwd().createFile(io, stdin_path, .{});
    defer in_file.close(io);
    try in_file.writeStreamingAll(io, stdin_text);

    var out_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
    defer out_file.close(io);

    const child = try std.process.spawn(io, .{
        .argv = &.{argv},
        .stdin = .{ .file = in_file },
        .stdout = .{ .file = out_file },
        // Python: `stderr=subprocess.DEVNULL`. The fixture writes
        // nothing there, and inheriting the test runner's stderr would
        // interleave bash noise into the suite's output.
        .stderr = .ignore,
    });
    return .{ .child = child, .pid = @intCast(child.id.?), .stdout_path = stdout_path };
}

// A hung stdio child does not write a tools/list response within `deadline_s
// + slack`.
test "hung_child_does_not_send_response_within_1s" {
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch); // LAST
    defer harness.cleanupExtraDir(io, gpa, scratch); // before the free

    // Python writes the frame, then an extra newline so the child's
    // `read` returns. Kept as one buffer: the fixture consumes one
    // line either way, and the byte count is not the subject.
    var hung = try spawnHung(scratch, TOOLS_LIST_FRAME ++ "\n");
    defer hung.deinit(); // FIRST — the `sleep 3600` must not outlive us

    // We're proving the NEGATIVE: the hung child does NOT send a tools/list
    // response. The Python helper polled in 0.5s slices and raised
    // TimeoutError when the deadline passed with nothing to read.
    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const deadline = start + DEADLINE_MS;
    var arrived: ?[]u8 = null;
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        const bytes = try hung.readStdout();
        if (bytes.len > 0) {
            arrived = bytes;
            break;
        }
        // Sleep one `select` slice, capped by what is left of the budget.
        const remaining = deadline - std.Io.Timestamp.now(io, .awake).toMilliseconds();
        if (remaining > 0) {
            const nap = @min(remaining, POLL_SLICE_MS);
            std.Io.sleep(io, .fromMilliseconds(nap), .awake) catch {};
        }
    }

    // Python: `with pytest.raises(TimeoutError)`.
    if (arrived) |frame| {
        defer gpa.free(frame);
        const quoted = harness.debugString(gpa, frame) catch frame;
        defer if (quoted.ptr != frame.ptr) gpa.free(quoted);
        std.debug.print(
            "hung child sent a response within {d}ms; the fixture is not hung: {s}\n",
            .{ DEADLINE_MS, quoted },
        );
        return error.TestUnexpectedResult;
    }

    // Python: `assert elapsed >= 1.0` — the timeout fired for the
    // right reason (we waited the whole window) rather than because
    // the poll gave up on the first empty read.
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    if (elapsed < DEADLINE_MS) {
        std.debug.print(
            "wait_for_timeout returned in {d}ms — expected ~{d}ms (the " ++
                "timeout must fire for the right reason)\n",
            .{ elapsed, DEADLINE_MS },
        );
        return error.TestUnexpectedResult;
    }
}

// After killing the hung child, a fresh spawn with the same argv produces a
// NEW PID.
test "hung_child_can_be_replaced_by_fresh_process" {
    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch); // LAST
    defer harness.cleanupExtraDir(io, gpa, scratch); // before the free

    var proc1 = try spawnHung(scratch, "");
    const pid1 = proc1.pid;
    // Scoped block: Python's `try/finally` around the FIRST child. `deinit`
    // kills AND reaps, which is what makes the second spawn's pid comparison
    // meaningful — an unreaped zombie would still be holding its pid.
    {
        defer proc1.deinit();

        if (!childAlive(pid1)) {
            std.debug.print(
                "hung child pid={d} exited prematurely\n",
                .{pid1},
            );
            return error.TestUnexpectedResult;
        }
    }

    // Spawn a fresh one.
    var proc2 = try spawnHung(scratch, "");
    defer proc2.deinit();
    const pid2 = proc2.pid;

    if (!childAlive(pid2)) {
        std.debug.print(
            "second hung child pid={d} exited prematurely\n",
            .{pid2},
        );
        return error.TestUnexpectedResult;
    }
    if (pid1 == pid2) {
        std.debug.print(
            "expected fresh pid after kill, got the same pid ({d}) — " ++
                "the kernel must not have reaped the first process\n",
            .{pid1},
        );
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one would stay invisible
    // until some caller appeared.
    _ = Hung;
    _ = Hung.deinit;
    _ = Hung.readStdout;
    _ = hungArgv;
    _ = childAlive;
    _ = spawnHung;
    _ = Harness.boot;
}
