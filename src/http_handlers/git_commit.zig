const std = @import("std");
const testing = std.testing;
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");
const run_captured = @import("helpers").run_captured;

/// Wall-clock budget per git invocation.
pub const GIT_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. Commit output is a few lines; the cap only
/// matters for a hook stack trace, which is truncated rather than
/// forwarded whole.
const MAX_OUTPUT_BYTES: usize = 64 * 1024;

/// How much of git's stderr rides along in the HTTP 400 `error` field.
/// The real causes are one line (`nothing to commit, working tree
/// clean`, `Author identity unknown`), but a hook stack trace is not.
const MAX_DETAIL_BYTES: usize = 300;

pub const CommitError = error{
    EmptyMessage,
    NothingToCommit,
    NotARepository,
    GitFailed,
};

/// Outcome of `git -C <path> commit -m <message>`: the new HEAD.
/// Caller owns the returned slice.
pub fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    message: []const u8,
    err_detail: *?[]u8,
) ![]u8 {
    err_detail.* = null;

    if (std.mem.trim(u8, message, " \n\r\t").len == 0) return error.EmptyMessage;

    // `message` travels as the VALUE of `-m`, never as a flag, so a message
    // like `--help` commits literally instead of printing git usage (probed
    // by the functional test). No shell is involved at any point — argv only.
    var commit_res = git_route.run(allocator, io, path, &.{ "commit", "-m", message }, .{
        .max_output_bytes = MAX_OUTPUT_BYTES,
        .timeout_ms = GIT_TIMEOUT_MS,
    }) catch {
        err_detail.* = try allocator.dupe(u8, "failed to run git commit");
        return error.GitFailed;
    };
    defer commit_res.deinit(allocator);
    if (commit_res.timed_out) {
        err_detail.* = try allocator.dupe(u8, "git commit timed out");
        return error.GitFailed;
    }
    const commit_code: u8 = switch (commit_res.term) {
        .exited => |c| c,
        else => {
            err_detail.* = try allocator.dupe(u8, "git commit terminated abnormally");
            return error.GitFailed;
        },
    };
    if (commit_code != 0) {
        const combined = try std.fmt.allocPrint(
            allocator,
            "{s}\n{s}",
            .{
                std.mem.trim(u8, commit_res.stdout, " \n\r\t"),
                std.mem.trim(u8, commit_res.stderr, " \n\r\t"),
            },
        );
        defer allocator.free(combined);
        const trimmed = std.mem.trim(u8, combined, " \n\r\t");
        const detail = if (trimmed.len == 0) "git commit failed" else trimmed;
        const capped = detail[0..@min(detail.len, MAX_DETAIL_BYTES)];
        err_detail.* = try allocator.dupe(u8, capped);
        if (std.mem.indexOf(u8, detail, "nothing to commit") != null) return error.NothingToCommit;
        if (std.mem.indexOf(u8, detail, "not a git repository") != null) return error.NotARepository;
        return error.GitFailed;
    }

    var rev_res = git_route.run(allocator, io, path, &.{ "rev-parse", "HEAD" }, .{
        .max_output_bytes = MAX_OUTPUT_BYTES,
        .timeout_ms = GIT_TIMEOUT_MS,
    }) catch {
        err_detail.* = try allocator.dupe(u8, "commit succeeded but HEAD could not be read");
        return error.GitFailed;
    };
    defer rev_res.deinit(allocator);
    const rev_code: u8 = switch (rev_res.term) {
        .exited => |c| c,
        else => {
            err_detail.* = try allocator.dupe(u8, "commit succeeded but HEAD could not be read");
            return error.GitFailed;
        },
    };
    if (rev_code != 0 or rev_res.timed_out) {
        err_detail.* = try allocator.dupe(u8, "commit succeeded but HEAD could not be read");
        return error.GitFailed;
    }
    const sha = std.mem.trim(u8, rev_res.stdout, " \n\r\t");
    if (sha.len == 0) {
        err_detail.* = try allocator.dupe(u8, "commit succeeded but HEAD is empty");
        return error.GitFailed;
    }
    return allocator.dupe(u8, sha);
}

/// HTTP handler for `POST /api/git/commit/create?path=<repo>&message=<msg>`.
pub fn gitCommitHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const message_param = query.get("message") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing message parameter") });
    };
    if (std.mem.trim(u8, message_param, " \n\r\t").len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Commit message must not be empty") });
    }

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    const sha = useCase(allocator, io, path_param, message_param, &detail) catch |err| {
        const msg: []const u8 = detail orelse switch (err) {
            error.EmptyMessage => "Commit message must not be empty",
            error.NothingToCommit => "Nothing to commit",
            error.NotARepository => "Not a git repository",
            else => "Failed to create commit",
        };
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
    };
    defer allocator.free(sha);

    const response = http_response.GitCommitCreateResponse{
        .success = true,
        .message = "Committed successfully",
        .commit_sha = sha,
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitCommitCreateResponse(allocator, response) });
}

// ===== Synthetic-repo unit tests ===== Same fixture discipline as
// git_pr_conflicts.zig: the repo lives in the OS temp dir (never under
// `.zig-cache/tmp/`, which is inside this repository — a `git init` there

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
    const root = std.mem.trimEnd(u8, raw_root, "/");
    if (root.len == 0) return error.NoTempRoot;

    var random_bytes: [12]u8 = undefined;
    testing.io.random(&random_bytes);
    var name_buf: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    const name = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
    const joined = try std.fmt.allocPrint(allocator, "{s}/pabrik-gitcommit-{s}", .{ root, name });
    defer allocator.free(joined);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(testing.io, joined, .{});

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = dir.realPath(testing.io, &real_buf) catch {
        dir.close(testing.io);
        return error.FixtureDirUnresolvable;
    };
    const path = try allocator.dupe(u8, real_buf[0..real_len]);
    errdefer allocator.free(path);

    dir.close(testing.io);
    dir = std.Io.Dir.cwd().openDir(testing.io, path, .{}) catch |err| {
        allocator.free(path);
        return err;
    };
    return .{ .path = path, .dir = dir, .allocator = allocator };
}

fn requireSelfContainedRepo(path: []const u8) !void {
    const argv = [_][]const u8{ "git", "-C", path, "rev-parse", "--show-toplevel" };
    var res = run_captured.run(testing.allocator, testing.io, &argv, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    defer res.deinit(testing.allocator);
    if (res.timed_out) return error.GitFailed;
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => return error.GitFailed,
    };
    if (code != 0) return error.GitFailed;
    const toplevel = std.mem.trim(u8, res.stdout, " \n\r\t");
    // git spells separators `/` on every platform; realPath hands back
    // `\` on Windows. Normalise before comparing so the guard does not
    // fire on identical directories.
    var want_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const want_len = @min(path.len, want_buf.len);
    @memcpy(want_buf[0..want_len], path[0..want_len]);
    for (want_buf[0..want_len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    if (!std.mem.eql(u8, toplevel, want_buf[0..want_len])) {
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
    try @import("helpers").git_env_guard.requireCleanGitEnv();
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "git", "-C", path });
    try argv.appendSlice(testing.allocator, args);
    var res = run_captured.run(testing.allocator, testing.io, argv.items, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    defer res.deinit(testing.allocator);
    if (res.timed_out) return error.GitFailed;
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => return error.GitFailed,
    };
    if (code != 0) return error.GitFailed;
}

/// Fresh repo with one commit plus one staged (uncommitted) change.
/// Returns the repo path; the caller owns nothing (fixture owns it).
fn makeRepoWithStagedChange(fx: *const FixtureDir) ![]const u8 {
    try git(fx.path, &.{ "init", "-q", "-b", "main" });
    try requireSelfContainedRepo(fx.path);
    try git(fx.path, &.{ "config", "user.email", "test@example.invalid" });
    try git(fx.path, &.{ "config", "user.name", "pabrik test" });
    try git(fx.path, &.{ "config", "commit.gpgsign", "false" });
    try writeFixture(fx, "a.txt", "one\n");
    try git(fx.path, &.{ "add", "-A" });
    try git(fx.path, &.{ "commit", "-qm", "first" });
    try writeFixture(fx, "a.txt", "two\n");
    try git(fx.path, &.{ "add", "-A" });
    return fx.path;
}

fn gitLogSubject(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const argv = [_][]const u8{ "git", "-C", path, "log", "--format=%s", "-1" };
    var res = run_captured.run(allocator, testing.io, &argv, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    defer res.deinit(allocator);
    return allocator.dupe(u8, std.mem.trim(u8, res.stdout, " \n\r\t"));
}

test "useCase commits the staged change and returns its SHA" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    const path = try makeRepoWithStagedChange(&fx);

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    const sha = try useCase(allocator, testing.io, path, "second commit", &detail);
    defer allocator.free(sha);

    // Full 40-hex SHA, not a prefix.
    try testing.expectEqual(@as(usize, 40), sha.len);
    for (sha) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    const subject = try gitLogSubject(allocator, path);
    defer allocator.free(subject);
    try testing.expectEqualStrings("second commit", subject);
}

test "useCase rejects an empty message without spawning a commit" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    const path = try makeRepoWithStagedChange(&fx);

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    const err = useCase(allocator, testing.io, path, "   \n  ", &detail) catch |e| e;
    try testing.expectEqual(error.EmptyMessage, err);

    // The staged change is still there — nothing was committed.
    const subject = try gitLogSubject(allocator, path);
    defer allocator.free(subject);
    try testing.expectEqualStrings("first", subject);
}

test "useCase surfaces git's nothing-to-commit message on a clean tree" {
    const allocator = testing.allocator;
    var fx = try makeFixtureDir(allocator);
    defer fx.deinit();
    try git(fx.path, &.{ "init", "-q", "-b", "main" });
    try requireSelfContainedRepo(fx.path);
    try git(fx.path, &.{ "config", "user.email", "test@example.invalid" });
    try git(fx.path, &.{ "config", "user.name", "pabrik test" });
    try git(fx.path, &.{ "config", "commit.gpgsign", "false" });
    try writeFixture(&fx, "a.txt", "one\n");
    try git(fx.path, &.{ "add", "-A" });
    try git(fx.path, &.{ "commit", "-qm", "first" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    const err = useCase(allocator, testing.io, fx.path, "nothing staged", &detail) catch |e| e;
    try testing.expectEqual(error.NothingToCommit, err);
    // The caller-facing detail carries git's own words, not a canned string.
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "nothing to commit") != null);
}
