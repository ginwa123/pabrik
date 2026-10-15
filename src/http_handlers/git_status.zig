const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Git status endpoint - returns current branch and status for a directory
pub fn gitStatusHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Check if we're in a git repo by running git rev-parse --git-dir with -C
    const git_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Determine if it's a git repo based on rev-parse exit code
    const is_git_repo = git_check.term.exited == 0;

    // If not a git repo, return early with a 200 + is_git_repo=false body.
    // This is NOT a server error — it's a perfectly valid answer to "what's
    // the git status of <path>?" (answer: not a git repo).
    if (!is_git_repo) {
        const response = http_response.GitStatusResponse{
            .is_git_repo = false,
        };
        return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStatusResponse(allocator, response) });
    }

    // Get current branch using: git -C <path> branch --show-current
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Get status using: git -C <path> status --porcelain
    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "status", "--porcelain" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Parse branch name
    const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // Check if there are changes
    const has_changes = status_result.stdout.len > 0;

    // Build response
    const is_clean = !has_changes;
    const status_text: []const u8 = if (has_changes) "modified" else "clean";

    const response = http_response.GitStatusResponse{
        .is_git_repo = true,
        .branch = branch_name,
        .has_changes = has_changes,
        .is_clean = is_clean,
        .status = status_text,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStatusResponse(allocator, response) });
}
