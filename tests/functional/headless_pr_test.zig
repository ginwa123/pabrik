//! Functional tests for `pabrik headless pr …` — the change-request backend
//! with no server and no port. The forge CLI is a fixture script, so every
//! answer here is deterministic and no network is touched.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",                  "-c",          "user.email=t@t",
        "-c",                   "user.name=t", "-c",
        "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    const term = child.wait(io) catch |err| {
        std.debug.print("git {s} did not wait: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} exited {d}\n", .{ args[0], code });
            return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-headless-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try git(s.root, &.{ "init", "--initial-branch=main", "--quiet", cwd });

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
        defer gpa.free(p);
        var f = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hi\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

    return cwd;
}

fn writeExecScript(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// A `gh` stub in its own bindir, so prepending it to PATH cannot shadow `git`.
fn installFakeGh(s: *Scratch, dir_name: []const u8, body: []const u8) ![]u8 {
    const bindir = try s.path(&.{dir_name});
    errdefer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    const gh_path = try std.fs.path.join(gpa, &.{ bindir, "gh" });
    defer gpa.free(gh_path);
    try writeExecScript(gh_path, body);

    return bindir;
}

const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
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

/// Two green rows. `gh pr checks` prints this and exits 0.
const GREEN_ROWS =
    \\[{"bucket":"pass","name":"path filter","state":"SUCCESS","link":"https://github.com/acme/app/actions/runs/1/job/1","workflow":"ci","startedAt":"2026-10-03T19:11:04Z","completedAt":"2026-10-03T19:11:11Z"},{"bucket":"pass","name":"zig build test","state":"SUCCESS","link":"https://github.com/acme/app/actions/runs/1/job/2","workflow":"ci","startedAt":"2026-10-03T19:11:04Z","completedAt":"2026-10-03T19:31:11Z"}]
;

/// One red row whose link is NOT an Actions run, so no `gh run view` lookup is
/// attempted and the fixture stays a single script.
const RED_ROWS =
    \\[{"bucket":"fail","name":"backend (Windows X64) / build","state":"FAILURE","link":"https://circleci.com/x","workflow":"","startedAt":"2026-10-03T19:14:22Z","completedAt":"2026-10-03T19:31:22Z"}]
;

const PENDING_ROWS =
    \\[{"bucket":"pending","name":"backend (Linux X64) / build","state":"IN_PROGRESS","link":"https://circleci.com/y","workflow":"","startedAt":"2026-10-03T19:14:22Z","completedAt":"0001-01-01T00:00:00Z"}]
;

fn ghPrinting(rows: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "#!/bin/sh\ncat <<'JSON'\n{s}\nJSON\nexit 0\n", .{rows});
}

const Run = struct {
    result: harness.RunResult,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn json(self: *Run) !*const std.json.Value {
        if (self.parsed == null) {
            self.parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.result.stdout, .{});
        }
        return &self.parsed.?.value;
    }

    fn deinit(self: *Run) void {
        if (self.parsed) |*p| p.deinit();
        self.result.deinit(gpa);
    }
};

fn pr(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "pr" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);
    return .{ .result = result };
}

test "headless pr checks: a directory that is not a repository is refused, not guessed" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{ "checks", "--path", "/pabrik/no/such/repo/xyzzy" });
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    const doc = try run.json();
    try testing.expectEqualStrings("not a git repository", doc.object.get("error").?.string);
}

test "headless pr checks: prints the forge's rollup as one JSON object" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const body = try ghPrinting(GREEN_ROWS);
    defer gpa.free(body);
    const bindir = try installFakeGh(&s, "bin-green", body);
    defer gpa.free(bindir);
    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{
        "checks", "--path", repo, "--pr", "https://github.com/acme/app/pull/42",
    });
    defer run.deinit();

    if (run.result.exit_code == null or run.result.exit_code.? != 0) {
        std.debug.print("pr checks failed ({?d})\n{s}\n{s}\n", .{
            run.result.exit_code, run.result.stdout, run.result.stderr,
        });
        return error.TestUnexpectedResult;
    }

    const doc = try run.json();
    try testing.expectEqualStrings("github", doc.object.get("provider").?.string);
    const summary = doc.object.get("summary").?.object;
    try testing.expectEqual(@as(i64, 2), summary.get("total").?.integer);
    try testing.expectEqual(@as(i64, 2), summary.get("passed").?.integer);
    try testing.expectEqual(@as(i64, 0), summary.get("failed").?.integer);
    try testing.expectEqual(@as(usize, 2), doc.object.get("checks").?.array.items.len);
}

test "headless pr wait: a green run exits 0 on the first poll" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const body = try ghPrinting(GREEN_ROWS);
    defer gpa.free(body);
    const bindir = try installFakeGh(&s, "bin-wait-green", body);
    defer gpa.free(bindir);
    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{
        "wait", "--path", repo, "--pr", "https://github.com/acme/app/pull/42",
    });
    defer run.deinit();

    if (run.result.exit_code == null or run.result.exit_code.? != 0) {
        std.debug.print("pr wait failed ({?d})\n{s}\n{s}\n", .{
            run.result.exit_code, run.result.stdout, run.result.stderr,
        });
        return error.TestUnexpectedResult;
    }

    const doc = try run.json();
    try testing.expectEqualStrings("pass", doc.object.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 1), doc.object.get("polls").?.integer);
    try testing.expectEqual(@as(i64, 2), doc.object.get("summary").?.object.get("passed").?.integer);
}

test "headless pr wait: a red run exits non-zero and names the failure" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const body = try ghPrinting(RED_ROWS);
    defer gpa.free(body);
    const bindir = try installFakeGh(&s, "bin-wait-red", body);
    defer gpa.free(bindir);
    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{
        "wait", "--path", repo, "--pr", "https://github.com/acme/app/pull/42",
    });
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    const doc = try run.json();
    try testing.expectEqualStrings("fail", doc.object.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 1), doc.object.get("summary").?.object.get("failed").?.integer);
}

test "headless pr wait: a run that never finishes times out instead of hanging" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const body = try ghPrinting(PENDING_ROWS);
    defer gpa.free(body);
    const bindir = try installFakeGh(&s, "bin-wait-pending", body);
    defer gpa.free(bindir);
    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{
        "wait",          "--path", repo,           "--pr", "https://github.com/acme/app/pull/42",
        "--interval-ms", "1000",   "--timeout-ms", "1",
    });
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    const doc = try run.json();
    try testing.expectEqualStrings("timeout", doc.object.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 1), doc.object.get("polls").?.integer);
    try testing.expectEqual(@as(i64, 1), doc.object.get("summary").?.object.get("pending").?.integer);
}

test "headless pr merge: a missing method is refused before any forge call" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{ "merge", "--path", "/tmp" });
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    try testing.expectEqualStrings("", run.result.stdout);
}

test "headless pr: an unknown op is refused by name, with nothing on stdout" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try pr(&h, &.{ "explode", "--path", "/tmp" });
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    try testing.expectEqualStrings("", run.result.stdout);
}
