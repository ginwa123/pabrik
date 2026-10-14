// Starting pabrik on an already-occupied port must fail cleanly. Zig port of
// `tests/functional/server_port_bind_test.py` (same test name).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");

const gpa = testing.allocator;
const io = testing.io;

/// `subprocess.run(timeout=90)`'s budget, in ms. Mirrors the Python
/// original's `timeout=90`.
const SPAWN_TIMEOUT_MS: u32 = 90_000;

/// Python sliced `stderr[-2000:]` into every assertion message. Same
/// here, so a failure shows the tail of the binary's own diagnostics
/// rather than a 40 KiB stack dump.
const STDERR_TAIL: usize = 2000;

/// Allocate a fresh `pabrik-func-<random>` tempdir and return its absolute
/// path, owned by the caller.
fn makeTempDir() ![]u8 {
    const base = try harness.tmpRoot(gpa);
    defer gpa.free(base);

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const ts: u64 = @bitCast(@as(i64, std.Io.Timestamp.now(io, .awake).toMilliseconds()));
        const seed = ts ^ @as(u64, @intCast(attempt));

        const leaf = try std.fmt.allocPrint(gpa, "{s}{x}", .{ harness.REQUIRED_TMP_SUBSTR, seed });
        defer gpa.free(leaf);

        // No `defer gpa.free(name)` below: that slice IS the return
        // value and would be freed before the caller ever read it.
        const name = try harness.harnessPath(gpa, base, &.{leaf});
        std.Io.Dir.cwd().createDirPath(io, name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => {
                gpa.free(name);
                return err;
            },
        };
        return name;
    }
    return error.BootFailed;
}

/// Delete `temp_dir` through the SAME safety gate every harness
/// teardown uses. Refuses (rather than deleting) if `isSafeTmp` fails.
fn removeTempDir(temp_dir: []const u8, orig_home: []const u8) void {
    const safe = harness.isSafeTmp(io, gpa, temp_dir, orig_home) catch false;
    if (!safe) {
        std.debug.print(
            "REFUSING to rmtree unsafe path: {s}\n",
            .{temp_dir},
        );
        return;
    }
    std.Io.Dir.cwd().deleteTree(io, temp_dir) catch |err| {
        std.debug.print("could not delete {s}: {s}\n", .{ temp_dir, @errorName(err) });
    };
}

/// The last `STDERR_TAIL` bytes of `s` — borrowed, never allocated.
fn tail(s: []const u8) []const u8 {
    return if (s.len > STDERR_TAIL) s[s.len - STDERR_TAIL ..] else s;
}

// A taken port ⇒ rc > 0, never a negative (signal) code.
test "occupied_port_exits_nonzero_not_by_signal" {
    try harness.requirePabrikBin(io, gpa);

    const orig_home = testing.environ.getAlloc(gpa, "HOME") catch try gpa.dupe(u8, "");
    defer gpa.free(orig_home);

    const port = try harness.findFreePortRandom(gpa);

    const temp_dir = try makeTempDir();
    defer gpa.free(temp_dir);
    if (!try harness.isSafeTmp(io, gpa, temp_dir, orig_home)) {
        std.debug.print("mkdtemp produced {s}\n", .{temp_dir});
        return error.TestUnexpectedResult;
    }
    defer removeTempDir(temp_dir, orig_home);

    // The binary writes config into these before it ever reaches
    // `Address.init`.
    const xdg_dirs = [_][]const []const u8{
        &.{".config"},
        &.{ ".local", "state" },
        &.{ ".local", "share" },
        &.{".cache"},
    };
    for (xdg_dirs) |parts| {
        const dir = try harness.harnessPath(gpa, temp_dir, parts);
        defer gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    // Squat the port: bind + listen so the child's bind() must fail.
    // `Io.net`'s `reuse_address` sets SO_REUSEADDR (and SO_REUSEPORT on
    // POSIX) — a superset of the Python socket's SO_REUSEADDR-only setup.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var squatter = try addr.listen(io, .{ .reuse_address = true });
    defer squatter.deinit(io);

    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);

    var run = try harness.runPabrikCommand(io, gpa, temp_dir, &.{
        "--port", port_str,
    }, SPAWN_TIMEOUT_MS);
    defer run.deinit(gpa);

    const stderr = tail(run.stderr);

    // Python: `assert proc.returncode > 0`.
    const rc = run.exit_code orelse {
        std.debug.print(
            "expected a plain non-zero exit on a taken port, but the " ++
                "child died from a signal\n--- stderr ---\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    };
    if (rc == 0) {
        std.debug.print(
            "expected a plain non-zero exit on a taken port, got 0\n" ++
                "--- stderr ---\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    // Python: `assert proc.returncode == 1`.
    try testing.expectEqual(@as(u8, 1), rc);

    if (std.mem.indexOf(u8, stderr, "already in use") == null) {
        std.debug.print(
            "stderr should tell the operator the port is taken, got:\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    if (std.mem.indexOf(u8, stderr, port_str) == null) {
        std.debug.print("stderr should name the port {s}:\n{s}\n", .{ port_str, stderr });
        return error.TestUnexpectedResult;
    }

    // The stack trace is what made this read as a crash; the operator
    // message should have replaced it.
    if (std.mem.indexOf(u8, stderr, "BindFailed") != null) {
        std.debug.print(
            "BindFailed stack trace should be replaced by an operator message:\n{s}\n",
            .{stderr},
        );
        return error.TestUnexpectedResult;
    }

    // Python's closing sanity check — `time.monotonic() - started < 90` — is
    // NOT reproduced as a wall-clock measurement here, and the reason is
    // worth recording: `runPabrikCommand` joins a watchdog thread that sleeps
}
