// Functional wire tests for the crash-class regressions in GET
// /api/git/pr/status.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures
// ============================================================================

/// A scratch directory for the suite's OWN fixture (the git repo + the fake
/// `gh`), outside the harness's tempdir namespace.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    /// An absolute path inside the scratch dir.
    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// Write `contents` to `path` (absolute), creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Write an executable `/bin/sh` script at `path`.
fn writeExecScript(path: []const u8, contents: []const u8) !void {
    try writeFileAt(path, contents);
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// Python's `_git`: run `git` in `cwd` with the fixture identity baked in.
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",         "-C",             cwd,
        "-c",          "user.email=t@t", "-c",
        "user.name=t", "-c",             "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    const res = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        std.debug.print("git {s} did not spawn: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.term.exited != 0) {
        std.debug.print("git {s} exited {d}: {s}\n", .{ args[0], res.term.exited, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `git init --initial-branch=main --quiet <path>`.
fn gitInit(path: []const u8) !void {
    var argv: [5][]const u8 = .{ "git", "init", "--initial-branch=main", "--quiet", path };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
        std.debug.print("git init did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    if (res.term.exited != 0) {
        std.debug.print("git init exited {d}: {s}\n", .{ res.term.exited, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Build the `pr-status-crash-proj` fixture: one committed file on `main`.
fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-status-crash-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try gitInit(cwd);

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
        defer gpa.free(p);
        try writeFileAt(p, "hi\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    return cwd;
}

/// Python's `_install_fake_gh`: put an executable `gh` stub at the front of
/// PATH.
fn installFakeGh(s: *Scratch, dir_name: []const u8, body: []const u8) ![]u8 {
    const bindir = try s.path(&.{dir_name});
    errdefer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    const gh_path = try std.fs.path.join(gpa, &.{ bindir, "gh" });
    defer gpa.free(gh_path);
    try writeExecScript(gh_path, body);

    return bindir;
}

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env — so the booted `pabrik` resolves
/// `gh` to the fixture script.
const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
        // `Environ`'s block is a raw `KEY=VALUE` slice on POSIX.
        if (comptime @import("builtin").os.tag != .windows) {
            const saved = std.testing.environ;
            const orig = saved.block.slice;

            const entries = try alloc.allocSentinel(?[*:0]const u8, orig.len, null);
            errdefer alloc.free(entries);

            var owned: std.ArrayList([:0]u8) = .empty;
            defer owned.deinit(alloc);
            errdefer for (owned.items) |o| alloc.free(o);

            for (orig, 0..) |maybe, i| {
                const s = std.mem.span(maybe.?);
                if (std.mem.startsWith(u8, s, "PATH=")) {
                    try owned.append(alloc, try std.fmt.allocPrintSentinel(alloc, "PATH={s}{c}{s}", .{
                        prefix,
                        std.fs.path.delimiter,
                        s["PATH=".len..],
                    }, 0));
                } else {
                    try owned.append(alloc, try alloc.dupeZ(u8, s));
                }
                entries[i] = owned.items[owned.items.len - 1].ptr;
            }

            std.testing.environ = .{ .block = .{ .slice = entries } };
            return .{ .gpa = alloc, .saved = saved, .entries = entries };
        } else {
            return error.SkipZigTest;
        }
    }

    fn restore(self: PathShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| self.gpa.free(std.mem.span(e.?));
        self.gpa.free(self.entries);
    }
};

// ============================================================================
// The three fake `gh` bodies
// ============================================================================

/// 1 MiB of stderr, then a non-zero exit. `dd`/`tr` are coreutils, so
/// this needs nothing on PATH but the bindir itself.
const GH_BIG_STDERR_SCRIPT =
    \\#!/bin/sh
    \\i=0
    \\while [ $i -lt 1024 ]; do
    \\  i=$((i+1))
    \\  dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\0' 'E' 1>&2
    \\done
    \\exit 1
    \\
;

/// A `gh` that never exits. The handler's 20s deadline has to kill it.
const GH_HANG_SCRIPT =
    \\#!/bin/sh
    \\sleep 600
    \\
;

/// A healthy `gh pr view --json` payload plus a one-line stderr warning
/// — the shape every real `gh` prints.
const GH_OK_SCRIPT =
    \\#!/bin/sh
    \\printf '{"number":7,"title":"t","url":"https://github.com/a/b/pull/7","state":"OPEN","author":{"login":"alice"}}'
    \\printf 'a warning\n' 1>&2
    \\
;

// ============================================================================
// Tests
// ============================================================================

// 1 MiB of `gh` stderr must still produce a prompt 502.
test "huge_gh_stderr_does_not_hang_the_request" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-bigstderr", GH_BIG_STDERR_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 30s is well past the backend's 20s gh deadline, and well under
    // "forever" — a regression fails the test instead of hanging the
    // suite.
    const url = try std.fmt.allocPrint(gpa, "/api/git/pr/status?path={s}&pr=42", .{repo});
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{
        .expect = &.{502},
        .timeout_s = 30.0,
    });
    defer r.deinit();

    // The process must still be serving after the failure path.
    if (!h.health(io)) {
        std.debug.print("server died while draining a large gh stderr\n", .{});
        return error.TestUnexpectedResult;
    }

    var doc = try r.json();
    defer doc.deinit();

    // `assert "error" in body` — an ABSENT key must fail, so `orelse`
    // rather than a defaulted empty string.
    const message = doc.str("error") orelse {
        std.debug.print("502 body should carry an `error` field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // The captured stderr is trimmed to MAX_FETCH_DETAIL (500 bytes),
    // all of it `E` bytes from the fake's `tr`.
    if (std.mem.indexOf(u8, message, "E") == null) {
        std.debug.print("502 error should carry the trimmed gh stderr, got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// A `gh` blocked forever must time out, not hold a worker thread. The handler
// has a 20s deadline; the assertion budget is 45s so a loaded CI box does not
// flake, but a pre-fix handler (no deadline) would never answer at all.
test "gh_that_never_exits_is_killed_not_awaited_forever" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-hang", GH_HANG_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const url = try std.fmt.allocPrint(gpa, "/api/git/pr/status?path={s}&pr=42", .{repo});
    defer gpa.free(url);

    {
        var r = try h.http(io, .GET, url, .{
            .expect = &.{502},
            .timeout_s = 45.0,
        });
        r.deinit();
    }

    if (!h.health(io)) {
        std.debug.print("server died after a hung gh\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// How many concurrent callers the burst fans out, and how many
/// requests each issues. 24 total, split 8/3 — the Python original's
/// `ThreadPoolExecutor(max_workers=8)` over `range(24)`.
const burst_workers: usize = 8;
const burst_requests: usize = 24;

/// One thread's share of the burst. A thread cannot `try`, so every failure
/// is recorded as a status the main thread will reject: `0` is not a real
/// HTTP status, so a transport error cannot masquerade as a pass.
const BurstWorker = struct {
    h: *Harness,
    repo: []const u8,
    codes: []u16,
    lo: usize,
    hi: usize,

    fn run(self: *BurstWorker) void {
        var i = self.lo;
        while (i < self.hi) : (i += 1) {
            const url = std.fmt.allocPrint(gpa, "/api/git/pr/status?path={s}&pr={d}", .{
                self.repo,
                1000 + i,
            }) catch {
                self.codes[i] = 0;
                continue;
            };
            defer gpa.free(url);

            const result = self.h.http(io, .GET, url, .{
                .expect = &.{200},
                .timeout_s = 45.0,
            });
            if (result) |ok| {
                var r = ok;
                self.codes[i] = r.status;
                r.deinit();
            } else |_| {
                self.codes[i] = 0;
            }
        }
    }
};

// The reported abort only ever happened under concurrency.
test "concurrent_pr_status_calls_keep_the_process_alive" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-concurrent", GH_OK_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Pre-zeroed: a request whose thread never ran stays 0 and fails.
    const codes = try gpa.alloc(u16, burst_requests);
    defer gpa.free(codes);
    @memset(codes, 0);

    const per_worker = burst_requests / burst_workers;
    var workers: [burst_workers]BurstWorker = undefined;
    var threads: [burst_workers]std.Thread = undefined;
    var spawned: usize = 0;
    // If a later spawn fails, the earlier ones still have to be joined
    // or they outlive the harness (and the tempdir they write into).
    errdefer for (threads[0..spawned]) |t| t.join();

    for (&workers, 0..) |*w, idx| {
        w.* = .{
            .h = &h,
            .repo = repo,
            .codes = codes,
            .lo = idx * per_worker,
            .hi = idx * per_worker + per_worker,
        };
        threads[idx] = try std.Thread.spawn(.{}, BurstWorker.run, .{w});
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    for (codes, 0..) |c, i| {
        if (c != 200) {
            std.debug.print("burst request {d} (pr={d}) returned {d}, expected 200\n", .{ i, 1000 + i, c });
            return error.TestUnexpectedResult;
        }
    }

    if (!h.health(io)) {
        std.debug.print("server aborted during concurrent pr-status calls\n", .{});
        return error.TestUnexpectedResult;
    }
}
