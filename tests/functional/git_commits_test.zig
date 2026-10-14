// Functional wire tests for the read-only commits history endpoints. Zig port
// of `tests/functional/git_commits_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Run `git` with a fixed identity so the fixture never depends on the
/// machine's global git config (which CI does not set).
fn git(cwd: []const u8, args: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{
        "git",
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=Test Author",
    });
    try full.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed with rc={d}\n", .{ args[args.len - 1], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[args.len - 1]});
            return error.TestUnexpectedResult;
        },
    }
}

fn writeFileAt(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Build the `commits-proj` fixture inside `scratch`. Returns the owned
/// repo path; the caller frees it and cleans `scratch` itself.
fn buildCommitsCwd(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "commits-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    // `--initial-branch=main` is what makes the fixture deterministic
    // across git versions.
    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    try writeFileAt(repo_dir, "a.txt", "one\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "first" });

    try writeFileAt(repo_dir, "a.txt", "two\n");
    try writeFileAt(repo_dir, "b.txt", "new\n");
    try git(repo, &.{ "add", "-A" });
    // A QUOTED subject plus a multi-line body — the detail endpoint has
    // to hand both back unmodified.
    try git(repo, &.{
        "commit", "--quiet",
        "-m",     "second \"quoted\" subject",
        "-m",     "multi\nline body",
    });

    try writeFileAt(repo_dir, "a.txt", "three\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "third" });

    return repo;
}

/// Boot a harness plus a fixture repo, with both cleaned up on the way
/// out. `*h`, `*scratch` and `*repo` are for the caller's `defer`s.
fn bootWithRepo(h: *Harness, scratch: *[]u8, repo: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});

    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
    repo.* = buildCommitsCwd(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// Boot a harness plus a bare scratch dir (no repo). For the non-repo
/// and param-validation cases.
fn bootWithScratch(h: *Harness, scratch: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});
    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
}


/// `GET /api/git/commits?path=<repo>` (+ optional limit/skip). Caller owns
/// the Response.
fn getCommits(
    h: *Harness,
    repo: []const u8,
    paging: []const harness.Harness.Param,
) !harness.Response {
    const path = repo;

    var params: [4]harness.Harness.Param = undefined;
    params[0] = .{ .name = "path", .value = path };
    @memcpy(params[1 .. 1 + paging.len], paging);

    return h.http(io, .GET, "/api/git/commits", .{
        .params = params[0 .. 1 + paging.len],
        .expect = &.{200},
        .timeout_s = 15.0,
    });
}

/// The `subject` of each commit, in wire order, as owned strings.
fn commitSubjects(doc: *const harness.Json) ![][]u8 {
    const commits = doc.array("commits") orelse return error.TestUnexpectedResult;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (commits.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const s = switch (obj.get("subject") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        try out.append(gpa, try gpa.dupe(u8, s));
    }
    return out.toOwnedSlice(gpa);
}

fn freeSubjects(subjects: [][]u8) void {
    for (subjects) |s| gpa.free(s);
    gpa.free(subjects);
}

/// Assert `[c["subject"] for c in commits] == want`, printing both sides.
fn expectSubjects(doc: *const harness.Json, want: []const []const u8, body: []const u8) !void {
    const got = try commitSubjects(doc);
    defer freeSubjects(got);

    if (got.len != want.len) {
        std.debug.print("expected {d} commits, got {d}: {s}\n", .{ want.len, got.len, body });
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("commit subjects mismatch: got \"{s}\", expected \"{s}\": {s}\n", .{ g, w, body });
            return error.TestUnexpectedResult;
        }
    }
}

/// The `sha` of the commit at `index`. Owned; caller frees.
fn commitSha(doc: *const harness.Json, index: usize) ![]u8 {
    const commits = doc.array("commits") orelse return error.TestUnexpectedResult;
    if (index >= commits.items.len) {
        std.debug.print("no commit at index {d} (have {d})\n", .{ index, commits.items.len });
        return error.TestUnexpectedResult;
    }
    const obj = switch (commits.items[index]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const sha = switch (obj.get("sha") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, sha);
}

// ============================================================================
// Test 1: commits list newest-first
// ============================================================================

// GET /commits returns newest-first rows with sha/author/subject.
test "commits_list_newest_first" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try getCommits(&h, repo, &.{});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const is_repo = doc.boolean("is_git_repo") orelse {
        std.debug.print("no boolean `is_git_repo`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!is_repo) {
        std.debug.print("is_git_repo is false for a real repo: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const branch = doc.str("branch") orelse {
        std.debug.print("no string `branch`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("main", branch);

    const total = doc.int("total_count") orelse {
        std.debug.print("no integer `total_count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 3), total);

    try expectSubjects(&doc, &.{ "third", "second \"quoted\" subject", "first" }, r.body);

    const commits = doc.array("commits") orelse return error.TestUnexpectedResult;
    const newest = switch (commits.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const sha = switch (newest.get("sha") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 40), sha.len);
    const short_sha = switch (newest.get("short_sha") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(sha[0..7], short_sha);
    const author = switch (newest.get("author") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("Test Author", author);
    const ts = switch (newest.get("timestamp") orelse return error.TestUnexpectedResult) {
        .integer => |i| i,
        else => {
            std.debug.print("`timestamp` is not an integer: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    if (ts <= 0) {
        std.debug.print("timestamp must be > 0, got {d}\n", .{ts});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: skip/limit paging
// ============================================================================

// skip/limit pages through history for infinite scroll.
test "commits_pagination" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    {
        var first = try getCommits(&h, repo, &.{
            .{ .name = "limit", .value = "2" },
            .{ .name = "skip", .value = "0" },
        });
        defer first.deinit();
        var doc = try first.json();
        defer doc.deinit();
        try expectSubjects(&doc, &.{ "third", "second \"quoted\" subject" }, first.body);
    }
    {
        var second = try getCommits(&h, repo, &.{
            .{ .name = "limit", .value = "2" },
            .{ .name = "skip", .value = "2" },
        });
        defer second.deinit();
        var doc = try second.json();
        defer doc.deinit();
        try expectSubjects(&doc, &.{"first"}, second.body);
    }
}

// ============================================================================
// Test 3: commit detail
// ============================================================================

// GET /commit returns the full message + touched files for a SHA.
test "commit_detail" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var sha: []u8 = undefined;
    {
        var listed = try getCommits(&h, repo, &.{});
        defer listed.deinit();
        var doc = try listed.json();
        defer doc.deinit();
        sha = try commitSha(&doc, 1);
    }
    defer gpa.free(sha);


    var r = try h.http(io, .GET, "/api/git/commit", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "sha", .value = sha },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got_sha = doc.str("sha") orelse {
        std.debug.print("detail has no string `sha`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(sha, got_sha);
    const subject = doc.str("subject") orelse {
        std.debug.print("detail has no string `subject`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("second \"quoted\" subject", subject);
    const body = doc.str("body") orelse {
        std.debug.print("detail has no string `body`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, body, "multi") == null) {
        std.debug.print("detail body lost the multi-line paragraph: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }

    const files = doc.array("files") orelse {
        std.debug.print("detail has no `files` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    var saw_a = false;
    var saw_b = false;
    for (files.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const p = switch (obj.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, p, "a.txt")) saw_a = true;
        if (std.mem.eql(u8, p, "b.txt")) saw_b = true;
    }
    if (!saw_a or !saw_b) {
        std.debug.print("expected both a.txt and b.txt among the touched files: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: non-repo is 200 + is_git_repo=false
// ============================================================================

// A non-git path returns 200 with is_git_repo=false (changes convention).
test "commits_non_repo_is_200_not_found" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const plain = try std.fs.path.join(gpa, &.{ scratch, "not-a-repo" });
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);


    var r = try h.http(io, .GET, "/api/git/commits", .{
        .params = &.{.{ .name = "path", .value = plain }},
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const is_repo = doc.boolean("is_git_repo") orelse {
        std.debug.print("no boolean `is_git_repo`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (is_repo) {
        std.debug.print("a plain directory reported is_git_repo=true: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const commits = doc.array("commits") orelse {
        std.debug.print("no `commits` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 0), commits.items.len);
}

// ============================================================================
// Test 5: param validation
// ============================================================================

// Missing path and non-hex sha are 400s, never a git subprocess.
test "commits_param_validation" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    {
        var r = try h.http(io, .GET, "/api/git/commits", .{
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
    {
        // `--help` is the flag-injection probe: a handler that forwarded
        // it straight to `git` would print usage and exit 0, not 400.
    const help = "--help";
        var r = try h.http(io, .GET, "/api/git/commit", .{
            .params = &.{
                .{ .name = "path", .value = "/tmp" },
                .{ .name = "sha", .value = help },
            },
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
}

// ============================================================================
// Test 6: per-commit file diff
// ============================================================================

// GET /commit/file returns the unified diff of one file at one commit.
test "commit_file_diff" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var sha: []u8 = undefined;
    {
        var listed = try getCommits(&h, repo, &.{});
        defer listed.deinit();
        var doc = try listed.json();
        defer doc.deinit();
        sha = try commitSha(&doc, 0);
    }
    defer gpa.free(sha);


    var r = try h.http(io, .GET, "/api/git/commit/file", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "sha", .value = sha },
            .{ .name = "file", .value = "a.txt" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got_sha = doc.str("sha") orelse {
        std.debug.print("file diff has no string `sha`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(sha, got_sha);
    const path = doc.str("path") orelse {
        std.debug.print("file diff has no string `path`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("a.txt", path);
    const content = doc.str("diff_content") orelse {
        std.debug.print("file diff has no string `diff_content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{ "-two", "+three", "@@" }) |needle| {
        if (std.mem.indexOf(u8, content, needle) == null) {
            std.debug.print("diff_content is missing \"{s}\": {s}\n", .{ needle, content });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 7: root-commit fallback
// ============================================================================

// The first commit has no parent — the show-fallback still renders.
test "commit_file_diff_root_commit" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var sha: []u8 = undefined;
    {
        var listed = try getCommits(&h, repo, &.{});
        defer listed.deinit();
        var doc = try listed.json();
        defer doc.deinit();
        const commits = doc.array("commits") orelse return error.TestUnexpectedResult;
        sha = try commitSha(&doc, commits.items.len - 1);
    }
    defer gpa.free(sha);


    var r = try h.http(io, .GET, "/api/git/commit/file", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "sha", .value = sha },
            .{ .name = "file", .value = "a.txt" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const content = doc.str("diff_content") orelse {
        std.debug.print("root-commit file diff has no `diff_content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, content, "+one") == null) {
        std.debug.print("root-commit diff should add the first line: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: commit/file param validation
// ============================================================================

// Missing file, flag-like file, and traversal are 400s.
test "commit_file_diff_validation" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const cases = [_][]const u8{ "", "--output=x", "../escape" };
    for (cases) |file| {
        var r = try h.http(io, .GET, "/api/git/commit/file", .{
            .params = &.{
                .{ .name = "path", .value = "/tmp" },
                .{ .name = "sha", .value = "3bc0e389" },
                .{ .name = "file", .value = file },
            },
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
}
