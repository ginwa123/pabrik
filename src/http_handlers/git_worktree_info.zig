const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");

/// Domain error set for the worktree-info use case. The handler maps
/// `NotARepository` to HTTP 404; other failures propagate as 500.
const WorktreeInfoError = error{ NotARepository };

/// Result of gathering worktree info. Mirrors the `GitWorktreeInfoResponse`
/// shape but with the HTTP layer stripped out (no status codes, no response
/// struct).
const WorktreeInfoResult = struct {
    branch: []const u8,
    last_commit_sha: []const u8,
    last_commit_msg: []const u8,
    default_base: []const u8,
    commits_ahead: i64,
    diff_summary: []const u8,
};

/// Use case — run all the git CLI commands to gather worktree metadata. Takes
/// primitive inputs (worktree path + optional base override), returns a
/// domain struct.
fn getWorktreeInfoUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    base: ?[]const u8,
) WorktreeInfoError!WorktreeInfoResult {
    // 1) Confirm it's a git repo.
    const git_dir_check = git_route.run(allocator, io, path, &.{ "rev-parse", "--git-dir" }, .{}) catch return error.NotARepository;
    if (git_dir_check.term.exited != 0) return error.NotARepository;

    // 2) Current branch.
    const branch_result = git_route.run(allocator, io, path, &.{ "branch", "--show-current" }, .{}) catch return error.NotARepository;
    const branch = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // 3) Last commit (short SHA + subject).
    const log_result = git_route.run(allocator, io, path, &.{ "log", "-1", "--format=%h %s" }, .{}) catch return error.NotARepository;
    const log_line = std.mem.trim(u8, log_result.stdout, " \n\r");
    var last_sha: []const u8 = "";
    var last_msg: []const u8 = "";
    if (std.mem.indexOf(u8, log_line, " ")) |space_idx| {
        last_sha = log_line[0..space_idx];
        last_msg = log_line[space_idx + 1 ..];
    }

    // 4) Base branch — use `base` override if provided, else auto-detect
    // (origin/main → origin/master → origin/develop → "main" fallback).
    var default_base: []const u8 = "main";
    if (base) |eb| {
        if (eb.len > 0) default_base = eb;
    } else {
        const bases = [_][]const u8{ "main", "master", "develop" };
        for (bases) |b| {
            // Build "origin/<b>" at runtime — the `++` operator on string
            // slices in Zig 0.16 requires comptime-known slices, and `b` is a
            // loop variable.
            var origin_b_buf: [64]u8 = undefined;
            const origin_b = std.fmt.bufPrint(origin_b_buf[0..], "origin/{s}", .{b}) catch continue;
            const probe = git_route.run(allocator, io, path, &.{ "rev-parse", "--verify", origin_b }, .{}) catch continue;
            if (probe.term.exited == 0) {
                default_base = b;
                break;
            }
        }
    }

    // 5) Commits ahead of `origin/<default_base>`.
    var commits_ahead: i64 = 0;
    {
        var range_buf: [128]u8 = undefined;
        const range = std.fmt.bufPrint(range_buf[0..], "origin/{s}..HEAD", .{default_base}) catch "";
        if (git_route.run(allocator, io, path, &.{ "rev-list", "--count", range }, .{})) |ahead_result| {
            if (ahead_result.term.exited == 0) {
                const trimmed = std.mem.trim(u8, ahead_result.stdout, " \n\r");
                commits_ahead = std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        } else |_| {
            // rev-list failed (e.g. base ref doesn't exist) — leave at 0.
        }
    }

    // 6) Diff shortstat against `origin/<default_base>`.
    var diff_summary: []const u8 = "";
    {
        var range_buf: [128]u8 = undefined;
        const range = std.fmt.bufPrint(range_buf[0..], "origin/{s}..HEAD", .{default_base}) catch "";
        if (git_route.run(allocator, io, path, &.{ "diff", "--shortstat", range }, .{})) |diff_result| {
            if (diff_result.term.exited == 0) {
                diff_summary = std.mem.trim(u8, diff_result.stdout, " \n\r");
            }
        } else |_| {
            // Same rationale as rev-list.
        }
    }

    return WorktreeInfoResult{
        .branch = branch,
        .last_commit_sha = last_sha,
        .last_commit_msg = last_msg,
        .default_base = default_base,
        .commits_ahead = commits_ahead,
        .diff_summary = diff_summary,
    };
}

/// HTTP handler for `GET /api/git/worktree/info`. Query params: - `path`
/// (required) — absolute worktree path - `base` (optional) — override the
/// auto-detected base branch.
pub fn gitWorktreeInfoHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };

    // Optional ?base=<branch> override. Forwarded verbatim to the use case.
    const explicit_base_param = req.query.get("base");

    const info = getWorktreeInfoUseCase(allocator, io, path_param, explicit_base_param) catch |err| switch (err) {
        // NotARepository → 404 with a clear message. Other errors propagate
        // to the GinwaServer which returns a generic 500.
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
        },
    };

    // Build the response. draft_title and draft_body are derived from the
    // use-case result; the title is the last commit subject, the body is
    // a short markdown summary with the diff stat and commit count.
    const response = http_response.GitWorktreeInfoResponse{
        .is_git_repo = true,
        .branch = info.branch,
        .last_commit_sha = info.last_commit_sha,
        .last_commit_msg = info.last_commit_msg,
        .default_base = info.default_base,
        .commits_ahead = info.commits_ahead,
        .diff_summary = info.diff_summary,
        .draft_title = info.last_commit_msg,
        .draft_body = std.fmt.allocPrint(allocator, "## Summary\n\n{s}\n\nCommits ahead: {d}\n", .{ info.diff_summary, info.commits_ahead }) catch "",
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitWorktreeInfoResponse(allocator, response) });
}
