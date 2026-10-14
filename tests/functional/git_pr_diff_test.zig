// Functional wire tests for GET /api/git/pr/diff (generic provider). Zig port
// of `tests/functional/git_pr_diff_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixtures
// ============================================================================

/// The suite's own scratch directory, outside the harness's tempdir
/// namespace.
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

/// Python's `_git`: `git` in `cwd` with the fixture identity baked in.
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

fn writeFile(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Python's `pr_cwd` fixture: base commit on main, feature branch
/// modifying base.txt and adding added.txt.
fn buildPrCwd(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-diff-proj"});
    errdefer gpa.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, cwd);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "init", "--initial-branch=main", "--quiet", cwd },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    }

    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "base.txt" });
        defer gpa.free(p);
        try writeFile(p, "keep\nold\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });
    try git(cwd, &.{ "checkout", "--quiet", "-b", "feature" });
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "base.txt" });
        defer gpa.free(p);
        try writeFile(p, "keep\nnew\n");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ cwd, "added.txt" });
        defer gpa.free(p);
        try writeFile(p, "hello\n");
    }
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "feature work" });
    return cwd;
}

/// Python's `ForgeRepo`: the clone under test, the bare `origin` that
/// publishes the PR ref, and the seed that pushes to it.
const ForgeRepo = struct {
    work: []u8,
    origin: []u8,
    seed: []u8,

    fn deinit(self: *ForgeRepo) void {
        gpa.free(self.work);
        gpa.free(self.origin);
        gpa.free(self.seed);
    }
};

/// Python's `_build_forge_repo`. `pr_files`/`lines_per_file` inflate the
/// PR diff past the 1MB response cap.
fn buildForgeRepo(s: *Scratch, dir_name: []const u8, pr_files: usize, lines_per_file: usize) !ForgeRepo {
    const root = try s.path(&.{dir_name});
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const origin = try std.fs.path.join(gpa, &.{ root, "origin.git" });
    errdefer gpa.free(origin);
    const seed = try std.fs.path.join(gpa, &.{ root, "seed" });
    errdefer gpa.free(seed);
    const work = try std.fs.path.join(gpa, &.{ root, "work" });
    errdefer gpa.free(work);

    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "init", "--quiet", "--bare", origin },
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        }
    }
    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "init", "--quiet", "--initial-branch=main", seed },
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        }
    }

    {
        const p = try std.fs.path.join(gpa, &.{ seed, "base.txt" });
        defer gpa.free(p);
        try writeFile(p, "keep\nold\n");
    }
    try git(seed, &.{ "add", "-A" });
    try git(seed, &.{ "commit", "--quiet", "-m", "base" });
    try git(seed, &.{ "checkout", "--quiet", "-b", "feature" });
    {
        const p = try std.fs.path.join(gpa, &.{ seed, "base.txt" });
        defer gpa.free(p);
        try writeFile(p, "keep\nnew\n");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ seed, "added.txt" });
        defer gpa.free(p);
        try writeFile(p, "hello\n");
    }
    if (pr_files > 0) {
        const line = "payload line with some length to it\n";
        var filler: std.Io.Writer.Allocating = .init(gpa);
        defer filler.deinit();
        var i: usize = 0;
        while (i < lines_per_file) : (i += 1) {
            try filler.writer.writeAll(line);
        }
        const filler_text = filler.written();
        var n: usize = 0;
        while (n < pr_files) : (n += 1) {
            const name = try std.fmt.allocPrint(gpa, "bulk_{d:0>4}.txt", .{n});
            defer gpa.free(name);
            const p = try std.fs.path.join(gpa, &.{ seed, name });
            defer gpa.free(p);
            try writeFile(p, filler_text);
        }
    }
    try git(seed, &.{ "add", "-A" });
    try git(seed, &.{ "commit", "--quiet", "-m", "feature work" });
    try git(seed, &.{ "remote", "add", "origin", origin });
    try git(seed, &.{ "push", "--quiet", "origin", "main", "feature" });
    try git(seed, &.{ "push", "--quiet", "origin", "feature:refs/pull/1/head" });

    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "clone", "--quiet", "-b", "main", origin, work },
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        }
    }

    return .{ .work = work, .origin = origin, .seed = seed };
}

/// Python's `_rebase_and_force_push`: rewrite the PR head off the base
/// and force it into `refs/pull/1/head`.
fn rebaseAndForcePush(repo: *const ForgeRepo) !void {
    try git(repo.seed, &.{ "reset", "--hard", "HEAD~1" });
    {
        const p = try std.fs.path.join(gpa, &.{ repo.seed, "added.txt" });
        defer gpa.free(p);
        try writeFile(p, "rewritten after force-push\n");
    }
    try git(repo.seed, &.{ "add", "-A" });
    try git(repo.seed, &.{ "commit", "--quiet", "-m", "rewrite the PR head" });
    try git(repo.seed, &.{ "push", "--quiet", "--force", "origin", "feature:refs/pull/1/head" });
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected {s} to contain {s}\n", .{ haystack, needle });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// 1. base...head diff surfaces both the modified and the new file.
test "generic_pr_diff_returns_hunks" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const cwd = try buildPrCwd(&s);
    defer gpa.free(cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = cwd },
            .{ .name = "pr_url", .value = "https://git.example.com/o/r/pull/1" },
            .{ .name = "provider", .value = "generic" },
            .{ .name = "base", .value = "main" },
            .{ .name = "head", .value = "feature" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("truncated") != false) {
        std.debug.print("expected truncated:false: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const base = doc.str("base") orelse {
        std.debug.print("200 body carries no `base`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, base, "main")) return error.TestUnexpectedResult;
    const head = doc.str("head") orelse {
        std.debug.print("200 body carries no `head`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, head, "feature")) return error.TestUnexpectedResult;
    const diff = doc.str("diff_content") orelse {
        std.debug.print("200 body carries no `diff_content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectContains(diff, "diff --git a/base.txt b/base.txt");
    try expectContains(diff, "-old");
    try expectContains(diff, "+new");
    try expectContains(diff, "diff --git a/added.txt b/added.txt");
}

// 2. Unknown head ref → 502 JSON (covers the DiffFailed wire mode).
test "generic_pr_diff_unknown_head_is_clean_502" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const cwd = try buildPrCwd(&s);
    defer gpa.free(cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = cwd },
            .{ .name = "pr_url", .value = "https://git.example.com/o/r/pull/1" },
            .{ .name = "provider", .value = "generic" },
            .{ .name = "base", .value = "main" },
            .{ .name = "head", .value = "no-such-branch" },
        },
        .expect = &.{502},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 3. Missing pr_url → 400 (covers the validator wire mode).
test "pr_diff_missing_pr_url_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const cwd = try buildPrCwd(&s);
    defer gpa.free(cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = cwd },
        },
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 4. Unknown provider → 400 (covers the strict-validator wire mode).
test "pr_diff_unknown_provider_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const cwd = try buildPrCwd(&s);
    defer gpa.free(cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = cwd },
            .{ .name = "pr_url", .value = "https://git.example.com/o/r/pull/1" },
            .{ .name = "provider", .value = "bitbucket" },
        },
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 5. `gh pr diff` unavailable/oversized -> 200 from origin's pull ref.
test "github_pr_diff_falls_back_to_refspec_when_cli_cannot_answer" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    var repo = try buildForgeRepo(&s, "forge", 0, 0);
    defer repo.deinit();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = repo.work },
            .{ .name = "pr_url", .value = "https://github.com/acme/widgets/pull/1" },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Only the refspec path reports base/head — the CLI path leaves them "".
    const head = doc.str("head") orelse {
        std.debug.print("fallback did not run (no head): {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, head, "refs/pabrik-pr/1")) {
        std.debug.print("fallback did not run: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const base = doc.str("base") orelse {
        std.debug.print("fallback did not run (no base): {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, base, "main")) {
        std.debug.print("fallback did not run: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (doc.boolean("truncated") != false) {
        std.debug.print("expected truncated:false: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const diff = doc.str("diff_content") orelse {
        std.debug.print("200 body carries no `diff_content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectContains(diff, "diff --git a/base.txt b/base.txt");
    try expectContains(diff, "-old");
    try expectContains(diff, "+new");
    try expectContains(diff, "diff --git a/added.txt b/added.txt");
}

// 6. A PR past the 1MB response cap truncates instead of erroring.
test "oversized_pr_returns_truncated_diff_not_502" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    var repo = try buildForgeRepo(&s, "big", 60, 2000);
    defer repo.deinit();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = repo.work },
            .{ .name = "pr_url", .value = "https://github.com/acme/widgets/pull/1" },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 60.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("truncated") != true) {
        std.debug.print("expected the 1MB cap to fire: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const diff = doc.str("diff_content") orelse {
        std.debug.print("200 body carries no `diff_content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (diff.len > 1024 * 1024) {
        std.debug.print("diff_content exceeds the 1MB cap: {d} bytes\n", .{diff.len});
        return error.TestUnexpectedResult;
    }
    const head = doc.str("head") orelse {
        std.debug.print("200 body carries no `head`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, head, "refs/pabrik-pr/1")) return error.TestUnexpectedResult;
    try expectContains(diff, "diff --git");
}

// 7. No usable pull ref anywhere -> 502 naming both strategies.
test "github_pr_diff_502_when_both_strategies_fail" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const plain = try s.path(&.{"plain"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "init", "--quiet", "--initial-branch=main", plain },
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const p = try std.fs.path.join(gpa, &.{ plain, "a.txt" });
        defer gpa.free(p);
        try writeFile(p, "x\n");
    }
    try git(plain, &.{ "add", "-A" });
    try git(plain, &.{ "commit", "--quiet", "-m", "base" });

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = plain },
            .{ .name = "pr_url", .value = "https://github.com/acme/widgets/pull/1" },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{502},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "origin") == null) {
        std.debug.print("message should name the fallback: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 8. Two PR reads either side of a force-push: 200, 200 — never 502.
test "force_pushed_pr_head_still_diffs" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    var repo = try buildForgeRepo(&s, "forced", 0, 0);
    defer repo.deinit();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const params = [_]Harness.Param{
        .{ .name = "path", .value = repo.work },
        .{ .name = "pr_url", .value = "https://github.com/acme/widgets/pull/1" },
        .{ .name = "provider", .value = "github" },
    };

    {
        var r = try h.http(io, .GET, "/api/git/pr/diff", .{
            .params = &params,
            .expect = &.{200},
            .timeout_s = 30.0,
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const diff = doc.str("diff_content") orelse {
            std.debug.print("first read carries no `diff_content`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try expectContains(diff, "+hello");
    }

    try rebaseAndForcePush(&repo);

    {
        var r = try h.http(io, .GET, "/api/git/pr/diff", .{
            .params = &params,
            .expect = &.{200},
            .timeout_s = 30.0,
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const diff = doc.str("diff_content") orelse {
            std.debug.print("second read carries no `diff_content`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        try expectContains(diff, "+rewritten after force-push");
        if (std.mem.indexOf(u8, diff, "+hello") != null) {
            std.debug.print("scratch ref was never force-updated: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}
