// Tests for the orphan-pabrik-pid reap step in FunctionalHarness.boot(). Zig
// port of `tests/functional/harness_orphan_reap_test.py`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const gpa = testing.allocator;
const io = testing.io;

const Harness = harness.Harness;
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

// ============================================================================
// Helpers
// ============================================================================

/// Spawn a 60-second sleeper in its own process group, like pabrik. The
/// caller must kill or `wait` it; `Child.kill` is idempotent, so registering
/// `defer child.kill(io)` is the safe net either way.
fn spawnLongLivedChild() !std.process.Child {
    // `/bin/sleep` rather than a Python one-liner: the Python version of this
    // fixture spawned `sys.executable`, which made the Zig port depend on an
    // interpreter.
    std.Io.Dir.cwd().access(io, "/bin/sleep", .{ .execute = true }) catch {
        std.debug.print("/bin/sleep missing or not executable\n", .{});
        return error.SkipZigTest;
    };
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "60" },
        // Own process group, exactly like `start_new_session=True`.
        .pgid = if (is_windows) null else 0,
    });
}

/// `kill(pid, 0)` — Python's `_pid_alive`. NOTE: a zombie process reports
/// alive here (`kill -0` succeeds).
fn pidAlive(pid: u32) bool {
    if (is_windows) return true;
    std.posix.kill(@as(std.posix.pid_t, @intCast(pid)), @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    return true;
}

/// Allocate AND create `<tmpRoot>/pabrik-func-<hex>` — the namespace
/// `reapOrphanTestPids` actually scans.
fn freshOrphanDir() ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const sfx = try harness.randomSuffix(gpa);
    defer gpa.free(sfx);
    const dir = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}{s}",
        .{ root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR, sfx },
    );
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        gpa.free(dir);
        return err;
    };
    return dir;
}

/// Write `<dir>/.harness.pid` exactly as `boot()` would.
fn makeOrphanMarker(dir: []const u8, harness_pid: u32, child_pid: u32) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, ".harness.pid" });
    defer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    const text = try std.fmt.allocPrint(gpa, "{d} {d}\n", .{ harness_pid, child_pid });
    defer gpa.free(text);
    try f.writeStreamingAll(io, text);
}

/// Write arbitrary bytes into `<dir>/.harness.pid` — for the malformed
/// and empty pidfile cases.
fn writeRawPidfile(dir: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ dir, ".harness.pid" });
    defer gpa.free(path);
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn pathIsDir(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn pidfilePath(dir: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ dir, ".harness.pid" });
}

/// A `Harness` built WITHOUT `boot`, with `dry_run` set directly. Python
/// reached this state with `monkeypatch.setenv( "PABRIK_FUNCTIONAL_DRY_RUN",
/// "1")`.
fn bareDryRunHarness(temp_dir: []const u8) !Harness {
    return .{
        .allocator = gpa,
        .port = 9999,
        .pabrik_bin = try gpa.dupe(u8, "/nonexistent"),
        .temp_dir = try gpa.dupe(u8, temp_dir),
        .orig_home = try gpa.dupe(u8, "/home/nonexistent"),
        .log_path = try gpa.dupe(u8, "/dev/null"),
        .pid = null,
        .dry_run = true,
        .orig_userprofile = try gpa.dupe(u8, ""),
        .orig_appdata = try gpa.dupe(u8, ""),
        .orig_localappdata = try gpa.dupe(u8, ""),
        .orig_xdg_config_home = try gpa.dupe(u8, ""),
        .orig_xdg_state_home = try gpa.dupe(u8, ""),
        .orig_xdg_data_home = try gpa.dupe(u8, ""),
        .orig_xdg_cache_home = try gpa.dupe(u8, ""),
    };
}

// ============================================================================
// Task 1: reapOrphanTestPids kills an orphan child pid + rmtree's its dir
// ============================================================================

// A stale pidfile whose harness parent is dead → reap kills the child and
// rmtree's the tempdir.
test "reap_kills_orphan_pabrik_and_removes_dir" {
    var child = try spawnLongLivedChild();
    defer child.kill(io);

    // Capture the pid BEFORE any `wait` — `Child.wait` nulls `id`.
    const child_pid: u32 = @intCast(child.id.?);
    try testing.expect(pidAlive(child_pid)); // child should be alive right after spawn

    // Create a fake orphan tempdir under the OS temp root so the reap
    // scan finds it. Use the safety substring so isSafeTmp accepts.
    const temp_dir = try freshOrphanDir();
    defer gpa.free(temp_dir);
    defer harness.cleanupExtraDir(io, gpa, temp_dir); // no-op if reaped

    // PID 0 is special on Linux (the kernel's idle task / swapper).
    const dead_pid: u32 = blk: {
        if (is_windows) break :blk 99_999_999;
        var quick = try std.process.spawn(io, .{ .argv = &.{"/bin/true"} });
        const q: u32 = @intCast(quick.id.?);
        _ = quick.wait(io) catch {};
        break :blk q;
    };
    try testing.expect(!pidAlive(dead_pid)); // never-assigned/reaped pid must read dead

    // Write the pidfile with the dead PID as the "harness parent".
    try makeOrphanMarker(temp_dir, dead_pid, child_pid);

    // Sanity check: dead_pid is gone, child is alive, dir exists.
    try testing.expect(pathIsDir(temp_dir));

    // Act.
    const reaped = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("reapOrphanTestPids failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };

    // Reap the zombie via the test process — we are the parent, and
    // `Child.wait` is the only thing that clears it.
    _ = child.wait(io) catch {};

    // Assert: child killed, dir removed, count reported.
    if (reaped < 1) {
        std.debug.print("reap should report at least one orphan reaped, got {d}\n", .{reaped});
        return error.TestUnexpectedResult;
    }
    try testing.expect(!pidAlive(child_pid));
    try testing.expect(!pathExists(temp_dir));
}

// ============================================================================
// Task 3: edge cases
// ============================================================================

// Calling reap twice with no orphans is safe; second call is a no-op.
test "reap_idempotent_when_no_orphans" {
    // First call on a clean tree.
    const first = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("first reap failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    // Second call immediately after.
    const second = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("second reap failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    // Python asserted `>= 0` on both, which is the real contract: the
    // scan must never RAISE, whatever it finds. Recorded rather than
    // asserted so a failure report says what was actually reaped.
    std.debug.print("reap idempotency: first={d} second={d}\n", .{ first, second });
}

// A pidfile whose harness parent is alive is NOT reaped. This is the
// cross-xdist safety case: worker A scanning for orphans must NOT kill worker
// B's live test's child.
test "reap_skips_live_harness" {
    var child = try spawnLongLivedChild();
    defer child.kill(io);
    const child_pid: u32 = @intCast(child.id.?);

    const temp_dir = try freshOrphanDir();
    defer gpa.free(temp_dir);
    defer harness.cleanupExtraDir(io, gpa, temp_dir);

    // Mark our own process (the test runner) as the harness parent — we
    // are alive, so reap must skip this entry.
    const self_pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
    try makeOrphanMarker(temp_dir, self_pid, child_pid);

    _ = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("reap failed: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };

    // Child is still alive.
    try testing.expect(pidAlive(child_pid));
    // Tempdir must NOT be rmtree'd.
    try testing.expect(pathIsDir(temp_dir));

    // Drain the zombie ourselves (Python's `_reap_child_zombie`).
    child.kill(io);
}

// A pidfile with garbage content is silently skipped; tempdir untouched.
test "reap_skips_malformed_pidfile" {
    const temp_dir = try freshOrphanDir();
    defer gpa.free(temp_dir);
    defer harness.cleanupExtraDir(io, gpa, temp_dir);

    try writeRawPidfile(temp_dir, "garbage-not-pids\n");
    // Should not raise, should not rmtree.
    _ = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("reap raised on a malformed pidfile: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    try testing.expect(pathIsDir(temp_dir));
}

// An empty pidfile is silently skipped; tempdir untouched.
test "reap_skips_empty_pidfile" {
    const temp_dir = try freshOrphanDir();
    defer gpa.free(temp_dir);
    defer harness.cleanupExtraDir(io, gpa, temp_dir);

    try writeRawPidfile(temp_dir, "");
    _ = harness.reapOrphanTestPids(io, gpa) catch |err| {
        std.debug.print("reap raised on an empty pidfile: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    try testing.expect(pathIsDir(temp_dir));
}

// ============================================================================
// Task 2: boot() writes the pidfile and teardown() removes it
// ============================================================================

// boot() writes `<harness_pid> <pabrik_pid>` to `<tempdir>/.harness.pid`.
test "boot_writes_pidfile_with_both_pids" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // `temp_dir` is read BEFORE teardown, into a local the caller owns.
    const temp_dir = try gpa.dupe(u8, h.temp_dir);
    defer gpa.free(temp_dir);

    const pidfile = try pidfilePath(temp_dir);
    defer gpa.free(pidfile);

    std.Io.Dir.cwd().access(io, pidfile, .{}) catch {
        std.debug.print("boot() must write the pidfile at {s}\n", .{pidfile});
        return error.TestUnexpectedResult;
    };

    const text = std.Io.Dir.cwd().readFileAlloc(io, pidfile, gpa, .limited(256)) catch |err| {
        std.debug.print("could not read {s}: {s}\n", .{ pidfile, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(text);

    var it = std.mem.tokenizeAny(u8, std.mem.trimEnd(u8, text, "\n"), " \t");
    const h_tok = it.next() orelse return error.TestUnexpectedResult;
    const p_tok = it.next() orelse return error.TestUnexpectedResult;
    if (it.next() != null) {
        std.debug.print("pidfile must have 2 tokens, got: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }

    const self_pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
    const got_harness = std.fmt.parseInt(u32, h_tok, 10) catch return error.TestUnexpectedResult;
    const got_child = std.fmt.parseInt(u32, p_tok, 10) catch return error.TestUnexpectedResult;

    // First pid must be the harness process.
    if (got_harness != self_pid) {
        std.debug.print("first pid must be the harness process ({d}), got {d}\n", .{ self_pid, got_harness });
        return error.TestUnexpectedResult;
    }
    // Second pid must be the child.
    if (got_child != h.pid.?) {
        std.debug.print("second pid must be the child ({d}), got {d}\n", .{ h.pid.?, got_child });
        return error.TestUnexpectedResult;
    }
}

// teardown() removes the pidfile before rmtree'ing the tempdir. Without this,
// a dry-run teardown would leave the pidfile behind and a subsequent boot
// would (incorrectly) see the tempdir as orphaned.
test "teardown_removes_pidfile" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});

    const temp_dir = try gpa.dupe(u8, h.temp_dir);
    defer gpa.free(temp_dir);
    const pidfile = try pidfilePath(temp_dir);
    defer gpa.free(pidfile);

    std.Io.Dir.cwd().access(io, pidfile, .{}) catch {
        std.debug.print("pidfile missing before teardown: {s}\n", .{pidfile});
        return error.TestUnexpectedResult;
    };

    try h.deinit(io);

    // After teardown, the tempdir is gone (rmtree'd).
    try testing.expect(!pathExists(temp_dir));
    // No `defer` on `h`: `deinit` freed every string it owns and then
    // did `self.* = undefined`.
}

// Under dry_run, teardown skips rmtree but still removes the pidfile so
// the next boot doesn't reap this entry.
test "teardown_dry_run_removes_pidfile" {
    // `dry_run` is set on the struct rather than through
    // `PABRIK_FUNCTIONAL_DRY_RUN=1`; see `bareDryRunHarness` for why.
    const temp_dir = try freshOrphanDir();
    defer gpa.free(temp_dir);
    defer harness.cleanupExtraDir(io, gpa, temp_dir);

    try makeOrphanMarker(temp_dir, 1, 1);
    const pidfile = try pidfilePath(temp_dir);
    defer gpa.free(pidfile);
    try testing.expect(pathExists(pidfile));

    var h = try bareDryRunHarness(temp_dir);
    try h.deinit(io);

    // Tempdir survives (dry_run) but pidfile is gone.
    try testing.expect(pathIsDir(temp_dir)); // dry_run keeps the tempdir
    try testing.expect(!pathExists(pidfile)); // dry_run teardown must remove the pidfile

    // Manual cleanup since dry_run skipped rmtree — `cleanupExtraDir` is
    // gated by `isSafeTmp`, and this path carries `REQUIRED_TMP_SUBSTR`.
}

// ============================================================================
// Task 4: TIME_WAIT saturation regression (findFreePort uses SO_REUSEADDR)
// ============================================================================

// findFreePort uses SO_REUSEADDR so it can scan past TIME_WAIT.
test "find_free_port_picks_time_wait_port" {
    // Find a port that's currently FREE on this host (avoid the dev's
    // 8081 and don't assume 8080 is free — earlier tests may have left
    // it bound).
    var target_port: ?u16 = null;
    {
        var p: u16 = harness.DEFAULT_PORT;
        while (p <= harness.PORT_SCAN_END) : (p += 1) {
            if (p == 8081) continue;
            if (harness.portIsFreeWithReuse(io, p)) {
                target_port = p;
                break;
            }
        }
    }
    const target = target_port orelse {
        std.debug.print("no free port available to seed TIME_WAIT\n", .{});
        return error.SkipZigTest;
    };

    // Create a server-side TIME_WAIT on target_port: bind a listener,
    // accept a connection, close from the server side (which puts the
    // server's port into TIME_WAIT), then close everything else.
    {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(target) };
        var srv = try addr.listen(io, .{ .reuse_address = true });
        defer srv.deinit(io);
        var cli = try addr.connect(io, .{ .mode = .stream });
        defer cli.close(io);
        var conn = try srv.accept(io);
        conn.close(io); // server-side close → server-side TIME_WAIT
    }
    // let the kernel register the TIME_WAIT
    std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

    // Sanity: without SO_REUSEADDR, bind() should now FAIL on
    // target_port (proves we actually have a TIME_WAIT to test against).
    {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(target) };
        if (addr.listen(io, .{})) |leaked| {
            var s = leaked;
            s.deinit(io);
            std.debug.print(
                "could not seed a TIME_WAIT on {d} (kernel bind succeeded → no TIME_WAIT)\n",
                .{target},
            );
            return error.SkipZigTest;
        } else |_| {
            // expected — TIME_WAIT blocks the bind
        }
    }

    // findFreePort must succeed despite the TIME_WAIT. Use target_port
    // as the start so it's the first candidate.
    const found = harness.findFreePort(target) catch |err| {
        std.debug.print("findFreePort({d}) failed: {s}\n", .{ target, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    if (found != target) {
        std.debug.print(
            "scan must pick {d} despite its TIME_WAIT; got {d} (SO_REUSEADDR not set?)\n",
            .{ target, found },
        );
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked.
    _ = spawnLongLivedChild;
    _ = pidAlive;
    _ = freshOrphanDir;
    _ = makeOrphanMarker;
    _ = writeRawPidfile;
    _ = pathExists;
    _ = pathIsDir;
    _ = pidfilePath;
    _ = bareDryRunHarness;
}
