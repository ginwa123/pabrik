const std = @import("std");
const builtin = @import("builtin");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;
const run_captured = @import("helpers").run_captured;

// ── What this is for ──────────────────────────────────────────────────────
// The PR tab knows a PR is `mergeable=CONFLICTING` but nothing about *which*
// files stop it merging, so the user gets a red badge and a link to the

/// Cap on the returned conflict list. A pathological history (two branches
/// that both rewrote the whole tree) can produce thousands of paths; the
/// payload is a UI list, not a report.
pub const MAX_CONFLICT_FILES: usize = 500;

/// Wall-clock budget per git invocation.
pub const GIT_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. The conflicted-file section is bounded by
/// MAX_CONFLICT_FILES; the informational section is the only unbounded part
/// and is discarded during parsing.
const MAX_OUTPUT_BYTES: usize = 256 * 1024;

/// How much of git's stderr rides along in the HTTP 502 `error` field. The
/// real causes are one line (`unknown option --write-tree` on git < 2.38,
/// `fatal: Not a valid object name …`), but a hook stack trace is not.
const MAX_DETAIL_BYTES: usize = 300;

const PrConflictsError = error{
    NotARepository,
    BaseRefNotFound,
    MergeTreeFailed,
};

/// The parseable answer: every path git refused to merge cleanly.
pub const ConflictPaths = struct {
    /// Owned slices into the caller's allocator; safe to free individually.
    files: [][]const u8,
    /// True when git named more than [`MAX_CONFLICT_FILES`] paths.
    truncated: bool,
};

/// Outcome of one git invocation: exit code + both streams. `stdout`/`stderr`
/// stay owned by the caller. Free every buffer [`parseConflictPaths`]
/// allocated.
pub fn deinitConflictPaths(allocator: std.mem.Allocator, parsed: ConflictPaths) void {
    for (parsed.files) |f| allocator.free(f);
    allocator.free(parsed.files);
}

const GitRun = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: GitRun, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    fn trimmedStderr(self: GitRun) []const u8 {
        return std.mem.trim(u8, self.stderr, " \n\r\t");
    }
};

/// Run one `git -C <path> …` and hand back its streams.
fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    args: []const []const u8,
) !GitRun {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", path });
    try argv.appendSlice(allocator, args);

    var res = run_captured.run(allocator, io, argv.items, .{
        .cwd = path,
        .max_output_bytes = MAX_OUTPUT_BYTES,
        .timeout_ms = GIT_TIMEOUT_MS,
    }) catch return error.MergeTreeFailed;

    if (res.timed_out) {
        res.deinit(allocator);
        return error.MergeTreeFailed;
    }

    // A child killed by a signal reports as `.exited` on some platforms and
    // as a signal term on others; only a self-reported exit code 0/1/other
    // is meaningful to us.
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => {
            res.deinit(allocator);
            return error.MergeTreeFailed;
        },
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Does `<ref>^{commit}` resolve in this repo? `rev-parse --verify --quiet`
/// exits 1 (printing nothing) for a missing ref, so the stderr is irrelevant.
fn refExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8, ref: []const u8) bool {
    const commitish = std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref}) catch return false;
    defer allocator.free(commitish);
    const run = runGit(allocator, io, path, &.{ "rev-parse", "--verify", "--quiet", commitish }) catch return false;
    defer run.deinit(allocator);
    return run.code == 0;
}

/// First candidate base ref that resolves, else `error.BaseRefNotFound`.
fn resolveBaseRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    requested: ?[]const u8,
) ![]u8 {
    var buf: [512]u8 = undefined;

    if (requested) |b| {
        if (b.len == 0) return error.BaseRefNotFound;
        const remote = std.fmt.bufPrint(&buf, "refs/remotes/origin/{s}", .{b}) catch return error.BaseRefNotFound;
        if (refExists(allocator, io, path, remote)) return allocator.dupe(u8, remote) catch error.MergeTreeFailed;
        if (refExists(allocator, io, path, b)) return allocator.dupe(u8, b) catch error.MergeTreeFailed;
        return error.BaseRefNotFound;
    }

    const names = [_][]const u8{ "main", "master", "develop" };
    for (names) |n| {
        const remote = std.fmt.bufPrint(&buf, "refs/remotes/origin/{s}", .{n}) catch continue;
        if (refExists(allocator, io, path, remote)) return allocator.dupe(u8, remote) catch error.MergeTreeFailed;
        if (refExists(allocator, io, path, n)) return allocator.dupe(u8, n) catch error.MergeTreeFailed;
    }
    return error.BaseRefNotFound;
}

/// Short (10-hex) commit a ref points at, for the response's provenance line.
/// Best effort: an empty string is cosmetic, never a failure.
fn revParseShort(allocator: std.mem.Allocator, io: std.Io, path: []const u8, ref: []const u8) ?[]u8 {
    const commitish = std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref}) catch return null;
    defer allocator.free(commitish);
    const run = runGit(allocator, io, path, &.{ "rev-parse", "--short=10", commitish }) catch return null;
    defer run.deinit(allocator);
    if (run.code != 0) return null;
    const out = std.mem.trim(u8, run.stdout, " \n\r\t");
    return allocator.dupe(u8, out) catch null;
}

/// Split `git merge-tree -z --write-tree --name-only` stdout into paths.
/// Record 0 is the resulting tree OID and is skipped.
pub fn parseConflictPaths(allocator: std.mem.Allocator, stdout: []const u8) !ConflictPaths {
    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var truncated = false;
    var it = std.mem.splitScalar(u8, stdout, 0);
    _ = it.next() orelse ""; // tree OID
    while (it.next()) |rec| {
        // Empty record ⇒ end of the conflicted-file section.
        if (rec.len == 0) break;
        if (files.items.len == MAX_CONFLICT_FILES) {
            truncated = true;
            break;
        }
        try files.append(allocator, try allocator.dupe(u8, rec));
    }
    return .{ .files = try files.toOwnedSlice(allocator), .truncated = truncated };
}

const PrConflictsResult = struct {
    /// Human-facing base label (the resolved ref, e.g. `refs/remotes/origin/main`).
    base_ref: []const u8,
    /// Commit the merge was computed against, or "" when rev-parse failed.
    base_commit: []const u8,
    head: []const u8,
    conflicting_files: [][]const u8,
    count: usize,
    truncated: bool,
};

/// Release every buffer [`useCase`] allocated. The handler has no arena of
/// its own to lean on (the result escapes into the JSON writer), so the
/// ownership rule is stated once here and mirrored by the inline tests.
pub fn deinitResult(allocator: std.mem.Allocator, result: PrConflictsResult) void {
    for (result.conflicting_files) |f| allocator.free(f);
    allocator.free(result.conflicting_files);
    allocator.free(result.base_ref);
    if (result.base_commit.len > 0) allocator.free(result.base_commit);
}

pub fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    base_override: ?[]const u8,
    head_override: ?[]const u8,
    detail: *?[]u8,
) !PrConflictsResult {
    // 1) Must be a git work tree. Probed first so every later failure can be
    // reported as a ref problem rather than a missing-repo 404.
    {
        const check = runGit(allocator, io, path, &.{ "rev-parse", "--git-dir" }) catch return error.NotARepository;
        defer check.deinit(allocator);
        if (check.code != 0) return error.NotARepository;
    }

    // 2) Resolve the two refs the merge runs over.
    const base_ref = try resolveBaseRef(allocator, io, path, base_override);
    // The panel is bound to the PR's own worktree, so the local HEAD is the
    // actionable answer: "what would conflict if I merged what I have right
    // now", which stays correct while the user is mid-resolution.
    const head: []const u8 = if (head_override) |h| (if (h.len > 0) h else "HEAD") else "HEAD";

    // 3) The three-way merge. This is the whole feature.
    const merge = runGit(allocator, io, path, &.{
        "merge-tree",
        "-z",
        "--write-tree",
        "--name-only",
        base_ref,
        head,
    }) catch {
        setDetail(allocator, detail, "git is not available on PATH");
        return error.MergeTreeFailed;
    };
    defer merge.deinit(allocator);

    // exit 0 → clean merge, exit 1 → conflicts. Anything else is a git error
    // (unknown flag on git < 2.38, bad object, unrelated histories refused);
    // its stderr is the only useful thing we can tell the user.
    if (merge.code != 0 and merge.code != 1) {
        const errtext = merge.trimmedStderr();
        setDetail(allocator, detail, if (errtext.len > 0) errtext else "git merge-tree failed");
        return error.MergeTreeFailed;
    }

    const parsed = try parseConflictPaths(allocator, merge.stdout);
    const base_commit = revParseShort(allocator, io, path, base_ref);

    return .{
        .base_ref = base_ref,
        .base_commit = base_commit orelse "",
        .head = head,
        .conflicting_files = parsed.files,
        .count = parsed.files.len,
        .truncated = parsed.truncated,
    };
}

fn setDetail(allocator: std.mem.Allocator, slot: *?[]u8, msg: []const u8) void {
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    if (trimmed.len == 0) return;
    const take = @min(trimmed.len, MAX_DETAIL_BYTES);
    slot.* = allocator.dupe(u8, trimmed[0..take]) catch null;
}

/// `GET
/// /api/git/pr/conflicts?path=<cwd>&pr_url=<url>[&provider=][&base=][&head=]`
/// Returns the paths a three-way merge of `<base>` into `<head>` refuses to
pub fn gitPrConflictsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const pr_url_param = query.get("pr_url") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing pr_url parameter") });
    };
    if (pr_url_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "pr_url cannot be empty") });
    }
    // `pr_url` identifies the PR for the caller but the computation is purely
    // local.
    if (query.get("provider")) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
    }

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = useCase(allocator, io, path_param, query.get("base"), query.get("head"), &detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.BaseRefNotFound => {
            const wanted = query.get("base") orelse "main";
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "could not resolve base branch '{s}' locally — run `git fetch` and retry", .{wanted}) catch "could not resolve the base branch locally — run `git fetch` and retry";
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.MergeTreeFailed => {
            var buf: [MAX_DETAIL_BYTES + 96]u8 = undefined;
            const msg = if (detail) |d|
                std.fmt.bufPrint(&buf, "git merge-tree failed: {s}", .{d}) catch "git merge-tree failed"
            else
                "git merge-tree failed";
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => return err,
    };
    defer deinitResult(allocator, result);

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrConflictsResponse(allocator, .{
        .pr_url = pr_url_param,
        .base_ref = result.base_ref,
        .base_commit = result.base_commit,
        .head = result.head,
        .conflicting_files = result.conflicting_files,
        .count = result.count,
        .truncated = result.truncated,
    }) });
}

const testing = std.testing;
// ===== parseConflictPaths unit tests =====

test "parseConflictPaths: clean merge returns an empty list" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "3fc9bd1eaaea2fa32b201a318655cb2cfcce085e\x00");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
    try testing.expect(!parsed.truncated);
}

test "parseConflictPaths: names before the empty record are the conflicting files" {
    const allocator = testing.allocator;
    // One OID record, two paths, the empty terminator, then git's
    // informational section — which must NOT be read as file names.
    const parsed = try parseConflictPaths(
        allocator,
        "aaa\x00src/a.zig\x00src/b b.py\x00\x00Auto-merging src/a.zig\x00CONFLICT (content): Merge conflict in src/a.zig\x00",
    );
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 2), parsed.files.len);
    try testing.expectEqualStrings("src/a.zig", parsed.files[0]);
    try testing.expectEqualStrings("src/b b.py", parsed.files[1]);
}

test "parseConflictPaths: no terminator still parses (older git / truncated stream)" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "aaa\x00src/only.zig\x00");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
    try testing.expectEqualStrings("src/only.zig", parsed.files[0]);
}

test "parseConflictPaths: caps at MAX_CONFLICT_FILES and flags truncation" {
    const allocator = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "aaa\x00");
    var name_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_CONFLICT_FILES + 25) : (i += 1) {
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&name_buf, "src/f{d}.zig\x00", .{i}));
    }
    try buf.append(allocator, 0);

    const parsed = try parseConflictPaths(allocator, buf.items);
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(MAX_CONFLICT_FILES, parsed.files.len);
    try testing.expect(parsed.truncated);
}

test "parseConflictPaths: empty stdout is clean, not an error" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
    try testing.expect(!parsed.truncated);
}

// ===== Synthetic-repo integration tests =====

/// A throwaway directory for fixture repos, OUTSIDE the pabrik repository.
const FixtureDir = struct {
    path: []const u8,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,

    fn deinit(self: *FixtureDir) void {
        self.dir.close(testing.io);
        self.dir.deleteTree(testing.io, self.path) catch {};
        self.allocator.free(self.path);
    }
};

fn makeFixtureDir(allocator: std.mem.Allocator) !FixtureDir {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const raw_root = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    return makeFixtureDirIn(allocator, raw_root);
}

/// The body of [`makeFixtureDir`], with the temp root passed in rather than
/// read from the environment.
fn makeFixtureDirIn(allocator: std.mem.Allocator, raw_root: []const u8) !FixtureDir {
    // macOS's $TMPDIR is `/var/folders/…/T/` — note the TRAILING SLASH.
    const root = std.mem.trimEnd(u8, raw_root, "/");
    if (root.len == 0) return error.NoTempRoot;

    var random_bytes: [12]u8 = undefined;
    testing.io.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
    const joined = try std.fmt.allocPrint(allocator, "{s}/pabrik-prconflicts-{s}", .{ root, name });
    defer allocator.free(joined);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(testing.io, joined, .{});

    // Canonicalise before anything else.
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = dir.realPath(testing.io, &real_buf) catch {
        dir.close(testing.io);
        return error.FixtureDirUnresolvable;
    };
    const path = try allocator.dupe(u8, real_buf[0..real_len]);
    errdefer allocator.free(path);

    // Re-open on the canonical path so `writeFixture`'s sub_path writes land
    // in the same directory the string names.
    dir.close(testing.io);
    dir = std.Io.Dir.cwd().openDir(testing.io, path, .{}) catch |err| {
        allocator.free(path);
        return err;
    };
    return .{ .path = path, .dir = dir, .allocator = allocator };
}

/// Fail loudly if `<path>` is not a self-contained git repository.
fn toGitSeparators(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const buf = try allocator.dupe(u8, path);
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf;
}

fn requireSelfContainedRepo(path: []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "git", "-C", path, "rev-parse", "--show-toplevel" });
    var res = run_captured.run(testing.allocator, testing.io, argv.items, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    defer res.deinit(testing.allocator);
    if (res.timed_out) return error.GitFailed;
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => return error.GitFailed,
    };
    if (code != 0) return error.GitFailed;
    const toplevel = std.mem.trim(u8, res.stdout, " \n\r\t");
    const want = try toGitSeparators(testing.allocator, path);
    defer testing.allocator.free(want);
    if (!std.mem.eql(u8, toplevel, want)) {
        std.debug.print(
            "\n!! fixture repo at {s} is INSIDE the repository at {s} — git would walk up and rewrite the real one\n",
            .{ path, toplevel },
        );
        return error.FixtureInsideRealRepo;
    }
}

fn writeFixture(dir: *const FixtureDir, name: []const u8, data: []const u8) !void {
    try dir.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
}

fn git(path: []const u8, args: []const []const u8) !void {
    // Fixture git must not run under hook-exported GIT_DIR/GIT_WORK_TREE.
    try @import("helpers").git_env_guard.requireCleanGitEnv();
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "git", "-C", path });
    try argv.appendSlice(testing.allocator, args);
    var res = run_captured.run(testing.allocator, testing.io, argv.items, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    defer res.deinit(testing.allocator);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => return error.GitFailed,
    };
    // Every fixture git step must succeed. Discarding the exit code is how a
    // broken fixture becomes a test that "passes" against whatever repository
    // it happened to land in.
    if (code != 0) {
        std.debug.print(
            "\n!! fixture git step ({d} args) in {s} exited {d}: {s}\n",
            .{ args.len, path, code, res.stderr },
        );
        return error.GitFailed;
    }
}

/// Fresh self-contained repo on `main` with one commit. The temp dir has no
/// user identity, so `commit` fails without the three `config` writes first.
fn makeRepo(fx: *const FixtureDir) ![]const u8 {
    try git(fx.path, &.{ "init", "-q", "-b", "main" });
    try requireSelfContainedRepo(fx.path);
    try git(fx.path, &.{ "config", "user.email", "test@example.invalid" });
    try git(fx.path, &.{ "config", "user.name", "pabrik test" });
    try git(fx.path, &.{ "config", "commit.gpgsign", "false" });
    try writeFixture(fx, "shared.txt", "a\nb\nc\n");
    try writeFixture(fx, "base_only.txt", "base\n");
    try git(fx.path, &.{ "add", "-A" });
    try git(fx.path, &.{ "commit", "-qm", "init" });
    return fx.path;
}

test "fixture dir survives a symlinked temp root with a trailing slash (macOS shape)" {
    // Regression guard, 2026-10-03. macOS failed every one of these tests
    // with `FixtureInsideRealRepo` because $TMPDIR is BOTH a symlink into
    // /private AND ends in a slash: the constructed path was
    const allocator = testing.allocator;
    // The bug this guards is macOS/Linux-shaped, and on Windows the symlink
    // creates but the mixed `\`+`/` path does not resolve the same way —
    // GitHub's runners also lack SeCreateSymbolicLinkPrivilege by default, so
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const raw = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    const root = std.mem.trimEnd(u8, raw, "/");

    var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var wb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_root = try std.fmt.bufPrint(&rb, "{s}/pabrik-tmpprobe-real", .{root});
    const link_root = try std.fmt.bufPrint(&wb, "{s}/pabrik-tmpprobe-link", .{root});
    const with_slash = try std.fmt.allocPrint(allocator, "{s}/", .{link_root});
    defer allocator.free(with_slash);

    std.Io.Dir.cwd().deleteTree(testing.io, real_root) catch {};
    std.Io.Dir.cwd().deleteTree(testing.io, link_root) catch {};
    var d = try std.Io.Dir.cwd().createDirPathOpen(testing.io, real_root, .{});
    d.close(testing.io);
    // Windows needs SeCreateSymbolicLinkPrivilege, which GitHub's runners do
    // not grant by default — skip rather than fail there. The macOS/Linux
    // runners are the ones that actually regressed.
    std.Io.Dir.cwd().symLink(testing.io, real_root, link_root, .{}) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteTree(testing.io, link_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, real_root) catch {};

    // `with_slash` is exactly macOS's $TMPDIR: a symlinked root ending in "/".
    var fx = try makeFixtureDirIn(allocator, with_slash);
    defer fx.deinit();

    // The fixture must be its OWN git repo, or every `git -C fx.path` walks up
    // and rewrites the enclosing repository.
    try git(fx.path, &.{ "init", "-q" });
    try requireSelfContainedRepo(fx.path);
}

test "requireSelfContainedRepo accepts a path git spells with forward slashes" {
    // Regression guard, 2026-10-03 (Windows). git reports `/` separators on
    // every platform; `Dir.realPath` returns `\` on Windows.
    const want = try toGitSeparators(testing.allocator, "D:\\a\\b");
    defer testing.allocator.free(want);
    try testing.expectEqualStrings("D:/a/b", want);

    const posix = try toGitSeparators(testing.allocator, "/tmp/x");
    defer testing.allocator.free(posix);
    try testing.expectEqualStrings("/tmp/x", posix);
}

test "useCase names the file both sides changed" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    const path = try makeRepo(&fx);

    // main edits line 2 of shared.txt; feature edits the SAME line
    // differently.
    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try writeFixture(&fx, "shared.txt", "a\nFEATURE\nc\n");
    try writeFixture(&fx, "feat.txt", "feature\n");
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });

    try git(path, &.{ "checkout", "-q", "main" });
    try writeFixture(&fx, "shared.txt", "a\nMAIN\nc\n");
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, result);

    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqualStrings("shared.txt", result.conflicting_files[0]);
    try testing.expect(!result.truncated);
    // Provenance: the response must name the ref it merged against.
    try testing.expectEqualStrings("main", result.base_ref);
    try testing.expect(result.base_commit.len >= 7);
}

test "useCase reports a clean merge as zero files" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    const path = try makeRepo(&fx);

    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try writeFixture(&fx, "feat.txt", "feature\n");
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });

    try git(path, &.{ "checkout", "-q", "main" });
    try writeFixture(&fx, "base_only.txt", "moved on\n");
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, result);
    try testing.expectEqual(@as(usize, 0), result.count);
}

test "useCase honours an explicit base ref" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    const path = try makeRepo(&fx);

    // `trunk` is the initial commit — an ancestor of feature, so merging it
    // into feature is clean.
    try git(path, &.{ "branch", "trunk" });
    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try writeFixture(&fx, "shared.txt", "a\nFEATURE\nc\n");
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });
    try git(path, &.{ "checkout", "-q", "main" });
    try writeFixture(&fx, "shared.txt", "a\nMAIN\nc\n");
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const overridden = try useCase(allocator, testing.io, path, "trunk", null, &detail);
    defer deinitResult(allocator, overridden);
    try testing.expectEqual(@as(usize, 0), overridden.count);
    try testing.expectEqualStrings("trunk", overridden.base_ref);

    // Same repo, default ladder → the conflict the override skipped.
    const dflt = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, dflt);
    try testing.expectEqual(@as(usize, 1), dflt.count);
    try testing.expectEqualStrings("shared.txt", dflt.conflicting_files[0]);
}

test "useCase reports NotARepository for a directory that is not a work tree" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();

    // The OS temp dir has no enclosing repository, so a bare directory here
    // is genuinely not a work tree — the case the handler maps to 404.
    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    try testing.expectError(
        error.NotARepository,
        useCase(allocator, testing.io, fx.path, null, null, &detail),
    );
}

test "useCase reports NotARepository for a path that does not exist" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();

    var missing_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const missing = std.fmt.bufPrint(&missing_buf, "{s}/definitely-not-here", .{fx.path}) catch @panic("bufPrint failed formatting the missing-path probe");

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    try testing.expectError(
        error.NotARepository,
        useCase(allocator, testing.io, missing, null, null, &detail),
    );
}
