// Functional wire tests for GET /api/git/pr/checks. Zig port of
// `tests/functional/git_pr_checks_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures
// ============================================================================

/// The suite's own scratch directory (the git repo + every fake bin),
/// outside the harness's tempdir namespace.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is registered
    /// first — a defer that freed the slice before the cleaner read it is a
    /// use-after-free that happens to read as a plausible path.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// Python's `_git`: `git` in `cwd` with the fixture identity baked in, so the
/// fixture never depends on the machine's global git config.
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
        else => {
            std.debug.print("git {s} died by signal\n", .{args[0]});
            return error.TestUnexpectedResult;
        },
    }
}

/// Python's `repo` fixture: `git init --initial-branch=main` plus one
/// committed file, so the directory is a real worktree rather than a
/// bare `.git`.
fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-checks-proj"});
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

/// Write an executable `/bin/sh` script at `path`.
fn writeExecScript(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    // `setFilePermissions(..., .executable_file, ...)` is the portable
    // spelling of Python's `chmod(st_mode | stat.S_IEXEC)` and also makes the
    // file READABLE, which OR-ing the exec bit into a fresh file's mode does
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// Put an executable `gh` stub in its OWN bindir inside `s`, so prepending
/// that directory to PATH cannot shadow another command the server needs
/// (`git` in particular — the repo gate runs it).
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
/// `Harness.boot` copies into the child env.
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
// The fake `gh` payloads
// ============================================================================

/// `json.dumps(CHECKS_ROWS)` — two rows, one FAILURE and one SUCCESS.
const CHECKS_ROWS_JSON =
    \\[{"bucket": "fail", "name": "backend (Windows X64) / build", "state": "FAILURE", "link": "https://github.com/acme/app/actions/runs/37146940187/job/111273396968", "workflow": "ci", "startedAt": "2026-10-03T19:14:22Z", "completedAt": "2026-10-03T19:31:22Z"}, {"bucket": "pass", "name": "path filter", "state": "SUCCESS", "link": "https://github.com/acme/app/actions/runs/37146940187/job/111272741668", "workflow": "ci", "startedAt": "2026-10-03T19:11:04Z", "completedAt": "2026-10-03T19:11:11Z"}]
;

/// `json.dumps(RUN_JOBS)` — the failing job's STEPS, plus the passing
/// job's empty step list.
const RUN_JOBS_JSON =
    \\{"jobs": [{"databaseId": 111273396968, "name": "backend (Windows X64) / build", "conclusion": "failure", "steps": [{"name": "Set up job", "number": 1, "conclusion": "success", "status": "completed", "startedAt": "2026-10-03T19:14:23Z", "completedAt": "2026-10-03T19:14:24Z"}, {"name": "zig build test", "number": 3, "conclusion": "failure", "status": "completed", "startedAt": "2026-10-03T19:15:00Z", "completedAt": "2026-10-03T19:31:22Z"}]}, {"databaseId": 111272741668, "name": "path filter", "conclusion": "success", "steps": []}]}
;

/// `json.dumps(rows)` for `test_pending_checks_exit_code_8_is_still_200`:
/// one IN_PROGRESS row whose `completedAt` is git's zero time.
const PENDING_ROWS_JSON =
    \\[{"bucket": "pending", "name": "backend (Linux X64) / build", "state": "IN_PROGRESS", "link": "https://github.com/acme/app/actions/runs/1/job/2", "workflow": "ci", "startedAt": "2026-10-03T19:14:22Z", "completedAt": "0001-01-01T00:00:00Z"}]
;

/// `gh pr checks` exiting 1 with "no checks reported" on stderr — what a
/// PR that never ran CI looks like.
const GH_NO_CHECKS_SCRIPT =
    \\#!/bin/sh
    \\echo "no checks reported on the 'main' branch" >&2
    \\exit 1
;

// ============================================================================
// Tests
// ============================================================================

// 1. Missing path → 400 (the route is registered and the validator runs).
test "missing_path_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{ .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // `assert "error" in r` — an ABSENT key must fail, so `orelse`
    // rather than a defaulted empty string.
    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 2. Unknown provider → 400 (strict validator).
test "unknown_provider_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "bitbucket" },
        },
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 3. Non-repo path → 404 (a real handler answer, not route shadowing).
test "non_repo_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    // Python: `plain = tmp_path / "plain"` — a plain directory inside
    // the suite's own scratch dir, never a git worktree.
    const plain = try s.path(&.{"plain"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = plain },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{404},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("404 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 4. gitlab → 422, NOT a 200 with zero checks. A CI panel that answers
// "0 checks" for an unsupported forge reads as "everything passed",
// which is the one answer it must never invent.
test "gitlab_is_422_not_an_empty_200" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
            .{ .name = "provider", .value = "gitlab" },
        },
        .expect = &.{422},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // `"github" in r["error"].lower()`.
    const message = doc.str("error") orelse {
        std.debug.print("422 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.ascii.indexOfIgnoreCase(message, "github") == null) {
        std.debug.print("422 error does not mention github: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// 5. Happy path via a fake `gh` on PATH → 200, with the failing job's STEPS
// attached.
test "failed_job_carries_its_steps" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const script = try buildStepsScript();
    defer gpa.free(script);

    const bindir = try installFakeGh(&s, "fakebin-steps", script);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{200},
        .timeout_s = 20.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "github");
    {
        const summary = doc.object("summary") orelse {
            std.debug.print("body carries no `summary`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try expectObjInt(summary, "total", 2);
        try expectObjInt(summary, "passed", 1);
        try expectObjInt(summary, "failed", 1);
        try expectObjInt(summary, "pending", 0);
        try expectObjInt(summary, "skipped", 0);
        try expectObjInt(summary, "cancelled", 0);
    }
    try expectEqualBool(&doc, "steps_truncated", false);

    const checks = doc.array("checks") orelse {
        std.debug.print("body carries no `checks` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    const failed = try findCheck(checks, "backend (Windows X64) / build");
    try expectObjStr(failed, "bucket", "fail");
    try expectObjStr(failed, "steps_error", "");

    const steps = objArray(failed, "steps") orelse {
        std.debug.print("failing job carries no `steps` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectStepNames(steps, &.{ "Set up job", "zig build test" });
    // `failed["steps"][1]["conclusion"] == "failure"`.
    if (steps.items.len < 2) {
        std.debug.print("failing job has {d} steps, expected 2\n", .{steps.items.len});
        return error.TestUnexpectedResult;
    }
    {
        const second = try asObject(steps.items[1]);
        try expectObjStr(second, "conclusion", "failure");
    }

    // A passing job is not drilled into — its steps would be noise.
    const passed = try findCheck(checks, "path filter");
    const passed_steps = objArray(passed, "steps") orelse {
        std.debug.print("passing job carries no `steps` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (passed_steps.items.len != 0) {
        std.debug.print("passing job must carry zero steps, got {d}\n", .{passed_steps.items.len});
        return error.TestUnexpectedResult;
    }
}

// 6. `gh pr checks` exits 1 with "no checks reported" on stderr for a PR
// that never ran CI. That is an answer, not a failure — a 502 here would
// paint every brand-new PR red.
test "no_checks_reported_is_200_with_an_empty_list" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-none", GH_NO_CHECKS_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{200},
        .timeout_s = 20.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const checks = doc.array("checks") orelse {
        std.debug.print("body carries no `checks` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (checks.items.len != 0) {
        std.debug.print("expected an empty checks list, got {d} rows: {s}\n", .{ checks.items.len, r.body });
        return error.TestUnexpectedResult;
    }
    const summary = doc.object("summary") orelse {
        std.debug.print("body carries no `summary`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectObjInt(summary, "total", 0);
}

// 7. `gh pr checks` exits 8 ("checks pending") WITH a valid payload on
// stdout. Branching on the exit code would 502 the panel for every
// in-flight PR — which is most of them, most of the time.
test "pending_checks_exit_code_8_is_still_200" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const script = try buildPendingScript();
    defer gpa.free(script);

    const bindir = try installFakeGh(&s, "fakebin-pending", script);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/checks", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{200},
        .timeout_s = 20.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const summary = doc.object("summary") orelse {
        std.debug.print("body carries no `summary`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectObjInt(summary, "pending", 1);

    // gh's zero-time must not reach the wire as year 1.
    const checks = doc.array("checks") orelse {
        std.debug.print("body carries no `checks` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (checks.items.len < 1) {
        std.debug.print("expected one pending check, got none: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const row = try asObject(checks.items[0]);
    try expectObjStr(row, "completed_at", "");
}

// ============================================================================
// Assertion helpers
// ============================================================================

/// One `case` arm of the fake `gh` dispatcher. The heredoc terminator lives
/// HERE, once, rather than in the caller's splice list.
fn ghArm(verb: []const u8, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "  \"{s}\") cat <<'EOF'\n{s}\nEOF\n    ;;\n",
        .{ verb, payload },
    );
}

/// The fake `gh` that dispatches on its first two argv words:
/// `gh pr checks` yields the job rows, `gh run view` the step lists.
/// Owned.
fn buildStepsScript() ![]u8 {
    const head = try gpa.dupe(u8, "#!/bin/sh\ncase \"$1 $2\" in\n");
    defer gpa.free(head);
    const arm1 = try ghArm("pr checks", CHECKS_ROWS_JSON);
    defer gpa.free(arm1);
    const arm2 = try ghArm("run view", RUN_JOBS_JSON);
    defer gpa.free(arm2);
    const tail = try gpa.dupe(u8, "  *) echo \"unexpected argv: $*\" >&2; exit 1 ;;\nesac\n");
    defer gpa.free(tail);
    return std.mem.concat(gpa, u8, &.{ head, arm1, arm2, tail });
}

/// `gh pr checks` exits 8 WITH a valid payload on stdout. Owned.
fn buildPendingScript() ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "#!/bin/sh\ncat <<'EOF'\n{s}\nEOF\nexit 8\n",
        .{PENDING_ROWS_JSON},
    );
}

fn asObject(v: std.json.Value) !std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.TestUnexpectedResult,
    };
}

fn objArray(o: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    return switch (o.get(key) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

/// `next(entry for entry in checks if entry["name"] == name)`.
fn findCheck(checks: std.json.Array, name: []const u8) !std.json.ObjectMap {
    for (checks.items) |item| {
        const o = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return o;
    }
    std.debug.print("no check named \"{s}\" in the response\n", .{name});
    return error.TestUnexpectedResult;
}

/// `[s["name"] for s in steps] == want`.
fn expectStepNames(steps: std.json.Array, want: []const []const u8) !void {
    if (steps.items.len != want.len) {
        std.debug.print("got {d} steps, expected {d}\n", .{ steps.items.len, want.len });
        return error.TestUnexpectedResult;
    }
    for (steps.items, 0..) |item, i| {
        const o = try asObject(item);
        const got = switch (o.get("name") orelse {
            std.debug.print("step {d} has no `name`\n", .{i});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("step {d} name is not a string\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, got, want[i])) {
            std.debug.print("step {d} = \"{s}\", expected \"{s}\"\n", .{ i, got, want[i] });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectEqualStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectEqualBool(doc: *const harness.Json, key: []const u8, want: bool) !void {
    const got = doc.boolean(key) orelse {
        std.debug.print("response has no boolean `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectObjStr(o: std.json.ObjectMap, key: []const u8, want: []const u8) !void {
    const got = switch (o.get(key) orelse {
        std.debug.print("response has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectObjInt(o: std.json.ObjectMap, key: []const u8, want: i64) !void {
    const got = switch (o.get(key) orelse {
        std.debug.print("response has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .integer => |i| i,
        else => {
            std.debug.print("`{s}` is not an integer\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("`{s}` = {d}, expected {d}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never
    // type-checked, so a stdlib rename inside one is invisible until a
    // caller appears.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = buildRepo;
    _ = installFakeGh;
    _ = writeExecScript;
    _ = PathShadow.install;
    _ = PathShadow.restore;
    _ = git;
    _ = asObject;
    _ = objArray;
    _ = findCheck;
    _ = expectStepNames;
    _ = expectEqualStr;
    _ = expectEqualBool;
    _ = expectObjStr;
    _ = expectObjInt;
    _ = ghArm;
    _ = buildStepsScript;
    _ = buildPendingScript;
}
