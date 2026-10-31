// Functional wire tests for GET /api/git/pr/status. Zig port of
// `tests/functional/git_pr_status_test.py` (same test names, same order).

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
    const cwd = try s.path(&.{"pr-status-proj"});
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

/// PR #42, MERGED, with every date populated. `json.dumps(payload)` on
/// one line inside a heredoc, exactly as the Python original wrote it.
const GH_MERGED_SCRIPT =
    \\#!/bin/sh
    \\cat <<'EOF'
    \\{"number": 42, "title": "Fix login", "url": "https://github.com/acme/app/pull/42", "state": "MERGED", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefName": "feature", "baseRefName": "main", "createdAt": "2026-09-01T00:00:00Z", "updatedAt": "2026-09-02T00:00:00Z", "mergedAt": "2026-09-03T00:00:00Z", "closedAt": "", "author": {"login": "alice"}, "additions": 10, "deletions": 5, "changedFiles": 3}
    \\EOF
;

/// PR #584, OPEN. `mergedAt` / `closedAt` are JSON `null` — the shape
/// the backend's optional-string struct used to reject, turning every
/// open PR into a 502.
const GH_OPEN_SCRIPT =
    \\#!/bin/sh
    \\cat <<'EOF'
    \\{"number": 584, "title": "SyncEngine Phase 2", "url": "https://github.com/acme/app/pull/584", "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE", "headRefName": "worktree/sync-engine-phase2-cached-delta", "baseRefName": "main", "createdAt": "2026-09-21T08:51:37Z", "updatedAt": "2026-09-21T08:51:37Z", "mergedAt": null, "closedAt": null, "author": {"login": "ginwa123"}, "additions": 286, "deletions": 103, "changedFiles": 4}
    \\EOF
;

/// A `gh` that fails the way an expired login does — the message the
/// 502 body must surface.
const GH_FAIL_SCRIPT =
    \\#!/bin/sh
    \\echo 'gh: To authenticate, run: gh auth login' >&2
    \\exit 1
;

/// A `gh` for a branch nobody opened a change request for: the stderr and
/// exit code `gh pr view` itself produces.
const GH_NO_PR_SCRIPT =
    \\#!/bin/sh
    \\echo 'no pull requests found for branch "worktree/no-pr-here"' >&2
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

    var r = try h.http(io, .GET, "/api/git/pr/status", .{ .expect = &.{400} });
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

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
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

// 3. `provider=gitlab` reaches the glab path instead of a hard 400.
// `provider=gitlab` used to be a hard 400 before any lookup.
test "gitlab_provider_is_not_rejected_up_front" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "gitlab" },
        },
        .expect = &.{ 200, 422, 502 },
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Python: `assert "only the github provider" not in r.get("error","")`.
    const message = doc.str("error") orelse "";
    if (std.mem.indexOf(u8, message, "only the github provider") != null) {
        std.debug.print("gitlab was rejected up front with a GitHub-flavoured error: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    if (message.len > 0) {
        // Whichever way it failed, the message must be about GitLab.
        if (hasGlabOnPath()) {
            std.debug.print(
                "skipping: `glab` is installed, so the handler takes the " ++
                    "FetchFailed arm and the message names neither literal; " ++
                    "the up-front-rejection assertion above still ran\n",
                .{},
            );
            return error.SkipZigTest;
        }
        const mentions_glab = std.mem.indexOf(u8, message, "glab") != null;
        const lower_mentions_gitlab = containsIgnoreCase(message, "gitlab");
        if (!mentions_glab and !lower_mentions_gitlab) {
            std.debug.print("error does not name glab/gitlab: {s}\n", .{message});
            return error.TestUnexpectedResult;
        }
    } else {
        // Success path: the provider is echoed back.
        const provider = doc.str("provider") orelse {
            std.debug.print("200 body carries no `provider`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, provider, "gitlab")) {
            std.debug.print("provider = \"{s}\", expected \"gitlab\": {s}\n", .{ provider, r.body });
            return error.TestUnexpectedResult;
        }
    }
}

// 4. Non-repo path → 404 (a real handler answer, not route shadowing).
test "non_repo_path_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    // Python: `plain = tmp_path / "not-a-repo"` — a plain directory
    // inside the suite's own scratch dir, never a git worktree.
    const plain = try s.path(&.{"not-a-repo"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
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

// 5. A fake `gh` on PATH proves the 200 wire shape end-to-end.
test "happy_path_via_fake_gh" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin", GH_MERGED_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualInt(&doc, "number", 42);
    try expectEqualStr(&doc, "state", "MERGED");
    try expectEqualStr(&doc, "status", "merged");
    try expectEqualStr(&doc, "title", "Fix login");
    try expectEqualStr(&doc, "head_ref", "feature");
    try expectEqualStr(&doc, "base_ref", "main");
    try expectEqualBool(&doc, "has_pr", true);
    try expectEqualStr(&doc, "reason", "");
}

// 6. An OPEN PR's `gh` payload carries `"mergedAt":null,"closedAt":null`.
test "open_pr_with_null_dates_is_200" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-open", GH_OPEN_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            // The kanban card sends `pr=<git_branch>`, so the value
            // carries slashes. The harness percent-encodes it; the
            // server has to decode it back.
            .{ .name = "pr", .value = "worktree/sync-engine-phase2-cached-delta" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualInt(&doc, "number", 584);
    try expectEqualStr(&doc, "state", "OPEN");
    try expectEqualStr(&doc, "status", "open");
    try expectEqualStr(&doc, "head_ref", "worktree/sync-engine-phase2-cached-delta");
    try expectEqualStr(&doc, "merged_at", "");
    try expectEqualStr(&doc, "closed_at", "");
}

// 7. A failing `gh` must surface its stderr in the 502 body.
test "fetch_failure_surfaces_gh_stderr" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-fail", GH_FAIL_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "42" },
        },
        .expect = &.{502},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "gh auth login") == null) {
        std.debug.print("502 error swallowed the gh stderr: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
    // The prefix names the forge's own noun ("pull request" on GitHub,
    // "merge request" on GitLab) instead of a hardcoded "PR", so the
    // message matches whichever CLI actually ran.
    const prefix = "failed to fetch pull request status: ";
    if (!std.mem.startsWith(u8, message, prefix)) {
        std.debug.print("502 error does not start with \"{s}\": {s}\n", .{ prefix, message });
        return error.TestUnexpectedResult;
    }
    if (doc.get("has_pr") != null) {
        std.debug.print("a failed fetch must not answer a `has_pr` flag: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

test "no_pr_for_branch_is_200_with_has_pr_false" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const bindir = try installFakeGh(&s, "fakebin-no-pr", GH_NO_PR_SCRIPT);
    defer gpa.free(bindir);

    var shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "worktree/no-pr-here" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualBool(&doc, "has_pr", false);
    try expectEqualStr(&doc, "reason", "no_pr");
    try expectEqualStr(&doc, "status", "");
    try expectEqualStr(&doc, "state", "");
}

// ============================================================================
// Assertion helpers
// ============================================================================

/// Is a `glab` binary resolvable on PATH? Probed with `std.process.run` so it
/// is the same PATH the server's own `execLookPath` will see.
fn hasGlabOnPath() bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "command -v glab >/dev/null 2>&1" },
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle_lower.len], needle_lower)) return true;
    }
    return false;
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

fn expectEqualInt(doc: *const harness.Json, key: []const u8, want: i64) !void {
    const got = doc.int(key) orelse {
        std.debug.print("response has no integer `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {d}, expected {d}\n", .{ key, got, want });
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

comptime {
    // Body-analysis barrier: an unreferenced helper is never
    // type-checked, so a stdlib rename inside one is invisible until a
    // caller appears.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = buildRepo;
    _ = installFakeGh;
    _ = PathShadow.install;
    _ = PathShadow.restore;
    _ = containsIgnoreCase;
    _ = expectEqualStr;
    _ = expectEqualInt;
    _ = expectEqualBool;
    _ = git;
}
