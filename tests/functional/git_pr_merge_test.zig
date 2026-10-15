// Functional wire tests for POST /api/git/pr/merge. This is the endpoint the
// PR tab's merge box calls.

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

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is
    /// registered first.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// `git` in `cwd` with the fixture identity baked in, so the fixture never
/// depends on the machine's global git config.
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

/// `git init` plus one commit, so `path` is a real worktree: the merge
/// handler's status re-read gates on `git rev-parse --git-dir`.
fn buildRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-merge-proj"});
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
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// Put an executable stub named `bin_name` in its OWN bindir inside `s`,
/// so prepending that directory to PATH cannot shadow another command the
/// server needs (`git` in particular — the repo gate runs it).
fn installFakeCli(s: *Scratch, dir_name: []const u8, bin_name: []const u8, body: []const u8) ![]u8 {
    const bindir = try s.path(&.{dir_name});
    errdefer gpa.free(bindir);
    try std.Io.Dir.cwd().createDirPath(io, bindir);

    const bin_path = try std.fs.path.join(gpa, &.{ bindir, bin_name });
    defer gpa.free(bin_path);
    try writeExecScript(bin_path, body);

    return bindir;
}

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env. Scoped by `restore`, or every
/// later suite in the same process would spawn the fake CLI.
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

// ============================================================================
// The fake forge CLIs
// ============================================================================

/// The head commit every test promises to be merging. Mirrored in the
/// payloads below, so the `--match-head-commit` / `--sha` assertion is
/// checking the value the status endpoint handed the UI.
const HEAD_SHA = "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e";
const TITLE = "fix(chatview): land where the reader left it (#891)";

/// `gh` as the merge box uses it: `pr view` answers `view_json`, and
/// `pr merge` records its argv (one arg per line) and exits 0.
fn ghScript(argv_path: []const u8, view_json: []const u8) ![]u8 {
    // `for a in "$@"; do echo "$a"; done`, NOT `printf '%s\\n'`: a Zig `\\`
    // multiline literal does not process escape sequences, so the printf
    // format reaches /bin/sh as a literal backslash-n and the dump stops
    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\case "$1-$2" in
        \\  pr-view|mr-view)
        \\    for a in "$@"; do echo "$a"; done > '{s}.view'
        \\    cat <<'EOF'
        \\{s}
        \\EOF
        \\    ;;
        \\  pr-merge|mr-merge)
        \\    for a in "$@"; do echo "$a"; done > '{s}'
        \\    exit 0
        \\    ;;
        \\  *)
        \\    echo "unexpected argv: $@" >&2
        \\    exit 7
        \\    ;;
        \\esac
    , .{ argv_path, view_json, argv_path });
}

/// A `gh` whose merge is REFUSED: exit 1 with the forge's own words on
/// stderr, which the 502 body must carry through verbatim.
fn ghRefusingScript(view_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\#!/bin/sh
        \\case "$1-$2" in
        \\  pr-merge|mr-merge)
        \\    echo 'Pull request is not mergeable: the base branch requires approvals' >&2
        \\    exit 1
        \\    ;;
        \\  *)
        \\    cat <<'EOF'
        \\{s}
        \\EOF
        \\    ;;
        \\esac
    , .{view_json});
}

/// #891 as the forge reports it AFTER the merge landed.
const GH_MERGED_JSON =
    \\{"number": 891, "title": "Scroll restore", "url": "https://github.com/ginwa123/pabrik/pull/891", "state": "MERGED", "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "headRefName": "worktree/add-a-button", "baseRefName": "main", "createdAt": "2026-10-11T00:00:00Z", "updatedAt": "2026-10-11T01:00:00Z", "mergedAt": "2026-10-11T01:00:00Z", "closedAt": null, "author": {"login": "ginwa123"}, "additions": 97, "deletions": 77, "changedFiles": 5, "headRefOid": "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e"}
;

/// #891 still OPEN — the merge-queue / armed-auto-merge shape. The command
/// was accepted; the change request has not merged.
const GH_OPEN_JSON =
    \\{"number": 891, "title": "Scroll restore", "url": "https://github.com/ginwa123/pabrik/pull/891", "state": "OPEN", "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefName": "worktree/add-a-button", "baseRefName": "main", "createdAt": "2026-10-11T00:00:00Z", "updatedAt": "2026-10-11T00:30:00Z", "mergedAt": null, "closedAt": null, "author": {"login": "ginwa123"}, "additions": 97, "deletions": 77, "changedFiles": 5, "headRefOid": "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e"}
;

/// !7 as GitLab reports it after a merge.
const GLAB_MERGED_JSON =
    \\{"iid": 7, "title": "GitLab MR", "web_url": "https://gitlab.com/g/r/-/merge_requests/7", "state": "merged", "source_branch": "worktree/gl", "target_branch": "main", "detailed_merge_status": "mergeable", "merge_status": "can_be_merged", "sha": "4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e", "merged_at": "2026-10-11T01:00:00Z", "closed_at": null, "created_at": "2026-10-11T00:00:00Z", "updated_at": "2026-10-11T01:00:00Z", "author": {"username": "ginwa123"}, "changes_count": "5"}
;

/// The body the merge box sends — built the same way, so a field rename on
/// either side fails here rather than in the browser.
fn mergeBody(repo: []const u8, provider: []const u8, method: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"{s}\",\"pr\":\"{s}\",\"provider\":\"{s}\",\"method\":\"{s}\",\"title\":\"{s}\",\"body\":\"\",\"delete_branch\":false,\"head_sha\":\"{s}\"}}",
        .{
            repo,
            if (std.mem.eql(u8, provider, "gitlab")) "7" else "891",
            provider,
            method,
            TITLE,
            HEAD_SHA,
        },
    );
}

/// The argv the fixture recorded, or "" when it never ran. The fixture
/// dumps it on EVERY invocation (before it branches), so this doubles as
/// "did the CLI run at all?".
fn recordedArgv(argv_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, argv_path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
}

// ============================================================================
// Tests
// ============================================================================

// 1. THE HAPPY PATH — and the argv it implies.
test "merge: gh pr merge --squash with the head guard, and the status re-read" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const argv_path = try s.path(&.{"gh-argv"});
    defer gpa.free(argv_path);
    const script = try ghScript(argv_path, GH_MERGED_JSON);
    defer gpa.free(script);
    const bindir = try installFakeCli(&s, "bin-ok", "gh", script);
    defer gpa.free(bindir);

    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try mergeBody(repo, "github", "squash");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("success") != true) {
        std.debug.print("success is not true: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (doc.boolean("pending") != false) {
        std.debug.print("pending is not false: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    try expectStr(&doc, "method", "squash");

    const status = doc.object("status") orelse {
        std.debug.print("no `status` object: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const got_status = status.get("status") orelse return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, got_status.string, "merged")) {
        std.debug.print("status.status = {s}, expected merged\n", .{got_status.string});
        return error.TestUnexpectedResult;
    }
    // The re-read is the SAME parser the poll uses, so head_sha proves the
    // payload grew the field the merge guard needs.
    const got_sha = status.get("head_sha") orelse return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, got_sha.string, HEAD_SHA)) {
        std.debug.print("status.head_sha = {s}, expected {s}\n", .{ got_sha.string, HEAD_SHA });
        return error.TestUnexpectedResult;
    }

    const argv = try recordedArgv(argv_path);
    defer gpa.free(argv);

    // Exactly one strategy flag, the head guard, and the message. All four
    // in one contiguous block: a flag that moved, vanished or gained a
    // sibling fails here.
    const wanted = try std.fmt.allocPrint(gpa, "pr\nmerge\n891\n--squash\n--match-head-commit\n{s}\n--subject\n{s}\n", .{ HEAD_SHA, TITLE });
    defer gpa.free(wanted);
    if (std.mem.indexOf(u8, argv, wanted) == null) {
        std.debug.print("merge argv does not contain the expected flags:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
    // Delete-branch is OFF by default (it deletes the session's own worktree
    // branch), and auto-merge does not exist in this app at all.
    if (std.mem.indexOf(u8, argv, "--delete-branch") != null) {
        std.debug.print("delete-branch was passed without being asked for:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, argv, "--auto") != null) {
        std.debug.print("an auto-merge flag reached the CLI:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
}

// 2. THE HONESTY TEST — exit 0 is not "merged".
test "merge: a CLI that exits 0 while the PR is still open reports pending, not success" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const argv_path = try s.path(&.{"gh-argv"});
    defer gpa.free(argv_path);
    const script = try ghScript(argv_path, GH_OPEN_JSON);
    defer gpa.free(script);
    const bindir = try installFakeCli(&s, "bin-open", "gh", script);
    defer gpa.free(bindir);

    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try mergeBody(repo, "github", "squash");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("success") != false) {
        std.debug.print("a still-open PR reported success: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (doc.boolean("pending") != true) {
        std.debug.print("a still-open PR did not report pending: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const status = doc.object("status") orelse return error.TestUnexpectedResult;
    const got_status = status.get("status") orelse return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, got_status.string, "open")) {
        std.debug.print("status.status = {s}, expected open\n", .{got_status.string});
        return error.TestUnexpectedResult;
    }
}

// 3. A refusal is a 502 carrying the forge's own words.
test "merge: a refusing CLI becomes a 502 with its stderr in the body" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const script = try ghRefusingScript(GH_OPEN_JSON);
    defer gpa.free(script);
    const bindir = try installFakeCli(&s, "bin-refuse", "gh", script);
    defer gpa.free(bindir);

    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try mergeBody(repo, "github", "squash");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{502} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("502 body carries no `error`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "not mergeable") == null) {
        std.debug.print("502 swallowed the CLI stderr: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// 4. An unknown or missing method is refused BEFORE anything is spawned.
test "merge: a missing or unknown method is a 400 and spawns nothing" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const argv_path = try s.path(&.{"gh-argv"});
    defer gpa.free(argv_path);
    const script = try ghScript(argv_path, GH_MERGED_JSON);
    defer gpa.free(script);
    const bindir = try installFakeCli(&s, "bin-nomethod", "gh", script);
    defer gpa.free(bindir);

    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const empty = try mergeBody(repo, "github", "");
    defer gpa.free(empty);
    {
        var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = empty, .expect = &.{400} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectStr(&doc, "error", "method must be \"merge\", \"squash\", or \"rebase\"");
    }

    const bogus = try mergeBody(repo, "github", "auto");
    defer gpa.free(bogus);
    {
        var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = bogus, .expect = &.{400} });
        defer r.deinit();
    }

    // The real assertion: the CLI never ran. `gh pr merge` with no strategy
    // flag prompts for the method, so a 400 that still spawned would be a
    // hang dressed up as a validation error.
    const argv = try recordedArgv(argv_path);
    defer gpa.free(argv);
    if (argv.len != 0) {
        std.debug.print("a refused method still spawned gh:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
}

// 5. GitLab goes through the same route, and its two mandatory flags are on
//    the wire.
test "merge: gitlab forces --yes and --auto-merge=false over the wire" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const repo = try buildRepo(&s);
    defer gpa.free(repo);

    const argv_path = try s.path(&.{"glab-argv"});
    defer gpa.free(argv_path);
    const script = try ghScript(argv_path, GLAB_MERGED_JSON);
    defer gpa.free(script);
    const bindir = try installFakeCli(&s, "bin-gl", "glab", script);
    defer gpa.free(bindir);

    const shadow = try PathShadow.install(gpa, bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try mergeBody(repo, "gitlab", "squash");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr/merge", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("success") != true) {
        std.debug.print("gitlab merge did not succeed: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }

    const argv = try recordedArgv(argv_path);
    defer gpa.free(argv);

    // -y/--yes: without it `glab mr merge` waits on a confirmation prompt
    // that a non-tty child can never answer. --auto-merge=false: glab
    // defaults auto-merge to TRUE when a pipeline is running, so without this
    const wanted = try std.fmt.allocPrint(gpa, "mr\nmerge\n7\n--squash\n--sha\n{s}\n", .{HEAD_SHA});
    defer gpa.free(wanted);
    if (std.mem.indexOf(u8, argv, wanted) == null) {
        std.debug.print("glab merge argv is missing the strategy/guard:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, argv, "--yes\n") == null) {
        std.debug.print("glab merge argv has no --yes:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, argv, "--auto-merge=false\n") == null) {
        std.debug.print("glab merge argv does not force auto-merge off:\n{s}\n", .{argv});
        return error.TestUnexpectedResult;
    }
}

// 6. `path` is required, and the route is on the authed group.
test "merge: a missing path is a 400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .POST, "/api/git/pr/merge", .{
        .json_body = "{\"method\":\"squash\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try expectStr(&doc, "error", "path is required");
}

// ============================================================================
// Assertion helpers
// ============================================================================

fn expectStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never type-checked.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = buildRepo;
    _ = installFakeCli;
    _ = PathShadow.install;
    _ = PathShadow.restore;
    _ = ghScript;
    _ = ghRefusingScript;
    _ = mergeBody;
    _ = recordedArgv;
    _ = expectStr;
    _ = git;
}
