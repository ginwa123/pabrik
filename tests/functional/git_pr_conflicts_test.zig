// GET /api/git/pr/conflicts against a real conflicting work tree. Zig port of
// `tests/functional/git_pr_conflicts_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The PR under test. Never fetched — the computation is purely local;
/// the URL only proves it round-trips through the query string.
const PR_URL = "https://github.com/acme/app/pull/4242";

// ============================================================================
// Helpers
// ============================================================================

/// Run `git` in `cwd` with the fixture identity baked in, so the repo never
/// depends on the machine's global git config (which CI does not set).
fn git(cwd: []const u8, args: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{
        "git",
        "-c",
        "user.email=t@t",
        "-c",
        "user.name=t",
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


/// Build the `conflict-proj` fixture: two branches that conflict in two
/// different ways, plus two files that do not.
fn buildConflictingRepo(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "conflict-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    try writeFileAt(dir, "shared.txt", "a\nb\nc\n");
    try writeFileAt(dir, "doomed.txt", "one\n");
    try writeFileAt(dir, "clean.txt", "same\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "base" });

    try git(repo, &.{ "checkout", "--quiet", "-b", "feature" });
    try writeFileAt(dir, "shared.txt", "a\nFEATURE\nc\n");
    try writeFileAt(dir, "doomed.txt", "two\n");
    try writeFileAt(dir, "feature_added.txt", "only on the feature branch\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "feature change" });

    try git(repo, &.{ "checkout", "--quiet", "main" });
    try writeFileAt(dir, "shared.txt", "a\nMAIN\nc\n");
    try git(repo, &.{ "rm", "--quiet", "doomed.txt" });
    try writeFileAt(dir, "clean.txt", "moved\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "main change" });

    try git(repo, &.{ "checkout", "--quiet", "feature" });
    return repo;
}

/// Build a repo at `<scratch>/a repo with spaces` whose two branches
/// genuinely conflict on the same line.
fn buildSpacedRepo(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "a repo with spaces" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    try writeFileAt(dir, "f.txt", "base\n");
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "base" });

    try git(repo, &.{ "checkout", "--quiet", "-b", "feature" });
    try writeFileAt(dir, "f.txt", "feature\n");
    try git(repo, &.{ "commit", "--quiet", "-am", "feature change" });

    try git(repo, &.{ "checkout", "--quiet", "main" });
    try writeFileAt(dir, "f.txt", "main\n");
    try git(repo, &.{ "commit", "--quiet", "-am", "main change" });

    try git(repo, &.{ "checkout", "--quiet", "feature" });
    return repo;
}

/// Boot a harness + a scratch dir; `*h` and `*scratch` are for the
/// caller's `defer`s.
fn bootWithScratch(h: *Harness, scratch: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});
    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
}

/// Is `name` among the response's `conflicting_files`?
fn namesConflict(doc: *const harness.Json, name: []const u8) !bool {
    const files = doc.array("conflicting_files") orelse {
        std.debug.print("response has no `conflicting_files` array\n", .{});
        return error.TestUnexpectedResult;
    };
    for (files.items) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, name)) return true;
        },
        else => {},
    };
    return false;
}

/// The number of entries in `conflicting_files`.
fn conflictCount(doc: *const harness.Json) !usize {
    const files = doc.array("conflicting_files") orelse return error.TestUnexpectedResult;
    return files.items.len;
}

// ============================================================================
// Test 1: the conflicting files are named on the wire
// ============================================================================

// Exactly the two genuinely-conflicting files — and nothing else.
test "conflicting_files_are_named_on_the_wire" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const repo = try buildConflictingRepo(scratch);
    defer gpa.free(repo);

    const url = PR_URL;

    var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr_url", .value = url },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // git sorts the conflicted-file section; assert on the set plus the
    // count so an added spurious entry fails on content and not ordering.
    if (!try namesConflict(&doc, "shared.txt")) {
        std.debug.print("shared.txt is not named: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (!try namesConflict(&doc, "doomed.txt")) {
        std.debug.print("doomed.txt is not named: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (try namesConflict(&doc, "clean.txt")) {
        std.debug.print("clean.txt merges cleanly and must NOT be named: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (try namesConflict(&doc, "feature_added.txt")) {
        std.debug.print("feature_added.txt merges cleanly and must NOT be named: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 2), try conflictCount(&doc));

    const count = doc.int("count") orelse {
        std.debug.print("response has no integer `count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, @intCast(try conflictCount(&doc))), count);

    const truncated = doc.boolean("truncated") orelse {
        std.debug.print("response has no boolean `truncated`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (truncated) {
        std.debug.print("expected truncated=false: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    // Provenance: the client renders this next to an empty list, so it
    // must be present and must be the ref we actually merged against.
    const base_ref = doc.str("base_ref") orelse {
        std.debug.print("response has no string `base_ref`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("main", base_ref);
    const base_commit = doc.str("base_commit") orelse {
        std.debug.print("response has no string `base_commit`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (base_commit.len < 7) {
        std.debug.print("base_commit is shorter than a short sha: {s}\n", .{base_commit});
        return error.TestUnexpectedResult;
    }
    const got_url = doc.str("pr_url") orelse {
        std.debug.print("response has no string `pr_url`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(PR_URL, got_url);
}

// ============================================================================
// Test 2: repo paths carry spaces
// ============================================================================

// Repo paths carry spaces; `%20` in the query must decode to one path.
test "path_with_spaces_survives_url_encoding" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const repo = try buildSpacedRepo(scratch);
    defer gpa.free(repo);

    const url = PR_URL;

    var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr_url", .value = url },
        },
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), try conflictCount(&doc));
    if (!try namesConflict(&doc, "f.txt")) {
        std.debug.print("expected f.txt to be the conflict: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: a clean merge is an empty list, not an error
// ============================================================================

// A 200 with `conflicting_files: []` is the "clean" answer. The client
// distinguishes it from a failure by the absence of `error`, so this case
// must not degrade into a 4xx/5xx.
test "clean_merge_is_an_empty_list_not_an_error" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const repo = try buildConflictingRepo(scratch);
    defer gpa.free(repo);
    try git(repo, &.{ "checkout", "--quiet", "--detach", "main~1" });

    const url = PR_URL;

    var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr_url", .value = url },
        },
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 0), try conflictCount(&doc));
    const count = doc.int("count") orelse {
        std.debug.print("response has no integer `count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 0), count);
    if (doc.get("error") != null) {
        std.debug.print("clean merge must carry no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: missing parameters and bad provider
// ============================================================================

// Every rejection carries an `error` the client can act on, and the
// unresolvable base ref is 422 ("you can fix this by fetching"), not 502.
test "missing_parameters_and_bad_provider_are_rejected" {
    var h: Harness = undefined;
    var scratch: []u8 = undefined;
    try bootWithScratch(&h, &scratch);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);
    defer h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});

    const repo = try buildConflictingRepo(scratch);
    defer gpa.free(repo);

    const url = PR_URL;

    // Python's `conflicting_repo / ".." / ".."` does NOT normalise: it yields
    // a literal `<repo>/../..`. Reproduced byte for byte — the handler has to
    // see the traversal, and a clean join would hand it a different string.
    const not_a_repo = try std.fmt.allocPrint(
        gpa,
        "{s}{s}..{s}..",
        .{ repo, std.fs.path.sep_str, std.fs.path.sep_str },
    );
    defer gpa.free(not_a_repo);

    var missing_path: []u8 = undefined;
    var missing_url: []u8 = undefined;
    var bad_provider: []u8 = undefined;
    var not_repo: []u8 = undefined;
    var no_such_base: []u8 = undefined;

    {
        var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
            .params = &.{.{ .name = "pr_url", .value = url }},
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        missing_path = try gpa.dupe(u8, r.body);
    }
    {
        var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
            .params = &.{.{ .name = "path", .value = repo }},
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        missing_url = try gpa.dupe(u8, r.body);
    }
    {
        var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
            .params = &.{
                .{ .name = "path", .value = repo },
                .{ .name = "pr_url", .value = url },
                .{ .name = "provider", .value = "bitbucket" },
            },
            .expect = &.{400},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        bad_provider = try gpa.dupe(u8, r.body);
    }
    {
        var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
            .params = &.{
                .{ .name = "path", .value = not_a_repo },
                .{ .name = "pr_url", .value = url },
            },
            .expect = &.{404},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        not_repo = try gpa.dupe(u8, r.body);
    }
    {
        var r = try h.http(io, .GET, "/api/git/pr/conflicts", .{
            .params = &.{
                .{ .name = "path", .value = repo },
                .{ .name = "pr_url", .value = url },
                .{ .name = "base", .value = "no-such-branch" },
            },
            .expect = &.{422},
            .timeout_s = 15.0,
        });
        defer r.deinit();
        no_such_base = try gpa.dupe(u8, r.body);
    }
    defer {
        gpa.free(missing_path);
        gpa.free(missing_url);
        gpa.free(bad_provider);
        gpa.free(not_repo);
        gpa.free(no_such_base);
    }

    // A copied body outlives its Response, so each is re-parsed here
    // rather than borrowing from a `Json` that is already gone.
    try expectErrorMentions(missing_path, "path");
    try expectErrorMentions(missing_url, "pr_url");
    try expectErrorMentions(bad_provider, "provider");

    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, not_repo, .{});
        defer parsed.deinit();
        const err_text = errorField(&parsed) orelse {
            std.debug.print("404 body has no `error`: {s}\n", .{not_repo});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings("not a git repository", err_text);
    }

    // 422, not 502: the caller can fix this by fetching, so say what to do.
    try expectErrorMentions(no_such_base, "git fetch");
}

/// Assert the body is JSON whose `error` string contains `needle`.
fn expectErrorMentions(body: []const u8, needle: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const err_text = errorField(&parsed) orelse {
        std.debug.print("body has no `error` field: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, err_text, needle) == null) {
        std.debug.print("error \"{s}\" should mention \"{s}\"\n", .{ err_text, needle });
        return error.TestUnexpectedResult;
    }
}

/// The `error` string of a parsed JSON object root, or null.
fn errorField(parsed: *const std.json.Parsed(std.json.Value)) ?[]const u8 {
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    return switch (root.get("error") orelse return null) {
        .string => |s| s,
        else => null,
    };
}
