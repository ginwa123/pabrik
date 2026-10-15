// Functional wire tests for `POST /api/git/commit/create`. The Files tab's
// commit box (SidebarDiffPanel) talks to exactly one endpoint and this file
// proves the exact wire payloads: 1.

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
        "-c",
        "commit.gpgsign=false",
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

/// Percent-encode a query component the way `encodeURIComponent` does
/// for the characters this suite sends (space, quotes, `&`, `=`, `%`).
/// Unreserved bytes pass through untouched.
fn encodeComponent(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(alloc, c);
        } else {
            try out.appendSlice(alloc, &.{ '%', hex[c >> 4], hex[c & 0xF] });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Build the `commit-proj` fixture: one commit ("first") plus one staged
/// (uncommitted) change to `a.txt`. Returns the owned repo path.
fn buildCommitRepo(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "commit-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    // Repo-local identity: the server commits as the repo's configured user
    // (it must not invent one), so the fixture provides it — the same three
    // writes the unit-test fixture in git_commit.zig makes.
    try git(repo, &.{ "config", "user.email", "t@t" });
    try git(repo, &.{ "config", "user.name", "Test Author" });
    try git(repo, &.{ "config", "commit.gpgsign", "false" });

    try writeFileAt(repo_dir, "a.txt", "one\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "first" });

    // Staged but uncommitted: the exact state the commit box commits.
    try writeFileAt(repo_dir, "a.txt", "two\n");
    try git(repo, &.{ "add", "-A" });

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
    repo.* = buildCommitRepo(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// Boot a harness plus a bare scratch dir (no repo). For the
/// param-validation cases.
fn bootWithScratch(h: *Harness, scratch: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});
    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
}

/// POST /api/git/commit/create?path=<repo>&message=<msg>. Caller owns
/// the Response. `expect` selects the accepted status codes.
fn postCommit(h: *Harness, repo: ?[]const u8, message: ?[]const u8, expect: []const u16) !harness.Response {
    var url: []u8 = undefined;
    if (repo) |r| {
        const enc = try encodeComponent(gpa, message orelse "");
        defer gpa.free(enc);
        url = if (message != null)
            try std.fmt.allocPrint(gpa, "/api/git/commit/create?path={s}&message={s}", .{ r, enc })
        else
            try std.fmt.allocPrint(gpa, "/api/git/commit/create?path={s}", .{r});
    } else {
        const enc = try encodeComponent(gpa, message orelse "");
        defer gpa.free(enc);
        url = try std.fmt.allocPrint(gpa, "/api/git/commit/create?message={s}", .{enc});
    }
    defer gpa.free(url);

    return h.http(io, .POST, url, .{
        .expect = expect,
        .timeout_s = 20.0,
    });
}

/// The `subject` of the newest commit in GET /api/git/commits. Owned.
fn newestSubject(h: *Harness, repo: []const u8) ![]u8 {
    var r = try h.http(io, .GET, "/api/git/commits", .{
        .params = &.{.{ .name = "path", .value = repo }},
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const commits = doc.array("commits") orelse {
        std.debug.print("no `commits` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (commits.items.len == 0) {
        std.debug.print("empty history after commit: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const newest = switch (commits.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const subject = switch (newest.get("subject") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, subject);
}

// ============================================================================
// Test 1: happy path — staged change commits, SHA answers, history shows it
// ============================================================================

// POST commits the staged index and the new commit leads history.
test "commit_create_happy_path" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try postCommit(&h, repo, "second via wire", &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const ok = doc.boolean("success") orelse {
        std.debug.print("no boolean `success`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!ok) {
        std.debug.print("success=false on a staged commit: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const sha = doc.str("commit_sha") orelse {
        std.debug.print("no string `commit_sha`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 40), sha.len);

    // The wire round-trip preserved the message through encode/decode.
    const subject = try newestSubject(&h, repo);
    defer gpa.free(subject);
    try testing.expectEqualStrings("second via wire", subject);
}

// ============================================================================
// Test 2: empty message is a 400, never a git subprocess
// ============================================================================

// An empty (or whitespace-only) message is rejected before git spawns.
test "commit_create_empty_message_is_400" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    {
        var r = try postCommit(&h, repo, "", &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
    {
        var r = try postCommit(&h, repo, "   ", &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
    // Nothing was committed: history still leads with "first".
    const subject = try newestSubject(&h, repo);
    defer gpa.free(subject);
    try testing.expectEqualStrings("first", subject);
}

// ============================================================================
// Test 3: missing params are 400s
// ============================================================================

// Missing path / missing message are 400s.
test "commit_create_missing_params_are_400" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    {
        var r = try postCommit(&h, null, "no repo here", &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
    {
        const plain = try std.fs.path.join(gpa, &.{ scratch, "not-a-repo" });
        defer gpa.free(plain);
        try std.Io.Dir.cwd().createDirPath(io, plain);
        var r = try postCommit(&h, plain, null, &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
}

// ============================================================================
// Test 4: clean tree is a 400 carrying git's own words
// ============================================================================

// Nothing staged: the endpoint surfaces git's "nothing to commit"
// instead of a canned string.
test "commit_create_clean_tree_is_400" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    // Commit the staged change first, so the tree is clean.
    {
        var r = try postCommit(&h, repo, "drain the index", &.{200});
        defer r.deinit();
    }
    {
        var r = try postCommit(&h, repo, "nothing left", &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
        if (std.mem.indexOf(u8, r.body, "nothing to commit") == null) {
            std.debug.print("expected git's words in the 400 body: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 5: a flag-shaped message commits literally (no flag injection)
// ============================================================================

// `--help` as the message must commit with subject `--help`, not print
// git usage: the message travels as the VALUE of `-m` over argv.
test "commit_create_flag_like_message_commits_literally" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    var repo: []u8 = undefined;
    try bootWithRepo(&h, &scratch, &repo);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer gpa.free(repo);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    var r = try postCommit(&h, repo, "--help", &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const ok = doc.boolean("success") orelse return error.TestUnexpectedResult;
    if (!ok) {
        std.debug.print("flag-shaped message rejected: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    const subject = try newestSubject(&h, repo);
    defer gpa.free(subject);
    try testing.expectEqualStrings("--help", subject);
}
