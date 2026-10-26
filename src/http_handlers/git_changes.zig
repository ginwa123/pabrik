const std = @import("std");
const pabrik_core = @import("pabrikcore");
const mod = @import("mod.zig");
const http_response = mod.http_response;
const gserverz = pabrik_core.gserverz;
const git_route = @import("git_route.zig");

/// Git file change structure
pub const GitFileChange = struct {
    index_status: []const u8, // Status in staging area (1 char: 'M', 'A', 'D', '?', ' ', etc.)
    worktree_status: []const u8, // Status in working tree (1 char: 'M', 'D', '?', ' ', etc.)
    path: []const u8,
};

/// Git changes response with staged and unstaged files
pub const GitChangesResponse = struct { is_git_repo: bool, branch: ?[]const u8 = null, has_changes: bool = false, staged_files: []const GitFileChange = &.{}, modified_files: []const GitFileChange = &.{}, untracked_files: []const GitFileChange = &.{} };

/// Parse git status --porcelain output and separate staged/unstaged files
/// Note: This function allocates copies of status chars and paths
fn parseGitStatus(allocator: std.mem.Allocator, output: []const u8) GitChangesResponse {
    var staged_files = std.ArrayList(GitFileChange).empty;
    var modified_files = std.ArrayList(GitFileChange).empty;
    var untracked_files = std.ArrayList(GitFileChange).empty;

    var start: usize = 0;
    while (start < output.len) {
        // Find end of line
        const end = std.mem.indexOfScalar(u8, output[start..], '\n') orelse output.len;
        const line = output[start .. start + end];

        if (line.len >= 4) {
            // Git porcelain format: XY<space><path> X = index status (1 char
            // at position 0) Y = worktree status (1 char at position 1) space
            // at position 2 path starts at position 3
            const indexStatus = line[0..1];
            const worktreeStatus = line[1..2];
            const path = line[3..];

            // Allocate copies since output buffer will be freed
            const indexStatusCopy = allocator.dupe(u8, indexStatus) catch continue;
            const worktreeStatusCopy = allocator.dupe(u8, worktreeStatus) catch {
                allocator.free(indexStatusCopy);
                continue;
            };
            const pathCopy = allocator.dupe(u8, path) catch {
                allocator.free(indexStatusCopy);
                allocator.free(worktreeStatusCopy);
                continue;
            };

            const change = GitFileChange{ .index_status = indexStatusCopy, .worktree_status = worktreeStatusCopy, .path = pathCopy };

            // Untracked files have "??" as their status (both X and Y are '?')
            if (std.mem.eql(u8, indexStatus, "?") and std.mem.eql(u8, worktreeStatus, "?")) {
                untracked_files.append(allocator, change) catch {};
            }
            // Staged changes have non-space in index position (X != ' ')
            else if (!std.mem.eql(u8, indexStatus, " ")) {
                staged_files.append(allocator, change) catch {};
            }
            // Modified files in worktree (Y != ' ' and not untracked)
            if (!std.mem.eql(u8, worktreeStatus, " ") and
                !(std.mem.eql(u8, indexStatus, "?") and std.mem.eql(u8, worktreeStatus, "?")))
            {
                modified_files.append(allocator, change) catch {};
            }
        }

        start += end + 1;
    }

    return GitChangesResponse{ .is_git_repo = true, .staged_files = staged_files.toOwnedSlice(allocator) catch &.{}, .modified_files = modified_files.toOwnedSlice(allocator) catch &.{}, .untracked_files = untracked_files.toOwnedSlice(allocator) catch &.{}, .has_changes = staged_files.items.len > 0 or modified_files.items.len > 0 or untracked_files.items.len > 0 };
}

/// Expand untracked directories to show individual files inside them
/// Like VS Code Git, lazygit, or fzf-lua git
fn expandUntrackedDirectories(allocator: std.mem.Allocator, io: std.Io, untracked_dirs: []const []const u8, path_param: []const u8) ![][]const u8 {
    var all_files = std.ArrayList([]const u8).empty;
    defer {
        for (all_files.items) |item| allocator.free(item);
        all_files.deinit(allocator);
    }

    for (untracked_dirs) |dir| {
        // Skip if not a directory (doesn't end with /)
        if (dir.len == 0 or dir[dir.len - 1] != '/') {
            const copy = try allocator.dupe(u8, dir);
            try all_files.append(allocator, copy);
            continue;
        }

        // Get files inside this untracked directory
        // Use git ls-files --others --exclude-standard <dir>
        const result = git_route.run(allocator, io, path_param, &.{ "ls-files", "--others", "--exclude-standard", dir }, .{}) catch continue;

        if (result.term.exited != 0) continue;

        // Parse the output - each line is a file path
        var file_start: usize = 0;
        const stdout = std.mem.trim(u8, result.stdout, " \n\r");

        while (file_start < stdout.len) {
            const remaining = stdout.len - file_start;
            const line_end = std.mem.indexOfScalar(u8, stdout[file_start..], '\n') orelse remaining;
            const actual_end = file_start + line_end;

            if (actual_end > stdout.len) break;

            const file_path = stdout[file_start..actual_end];

            if (file_path.len > 0) {
                const copy = try allocator.dupe(u8, file_path);
                try all_files.append(allocator, copy);
            }

            file_start = actual_end + 1;
        }
    }

    return try all_files.toOwnedSlice(allocator);
}

/// Git changes endpoint - returns staged, unstaged, and untracked files
pub fn gitChangesHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Check if we're in a git repo by running git rev-parse --git-dir with -C
    const git_check = git_route.run(allocator, io, path_param, &.{ "rev-parse", "--git-dir" }, .{}) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Determine if it's a git repo based on rev-parse exit code
    const is_git_repo = git_check.term.exited == 0;

    // If not a git repo, return early
    if (!is_git_repo) {
        const response = GitChangesResponse{ .is_git_repo = false, .staged_files = &.{}, .modified_files = &.{}, .untracked_files = &.{} };
        return res.jsonResponse(.{ .status_code = 200, .data = try makeGitChangesResponse(allocator, response) });
    }

    // Get current branch using: git -C <path> branch --show-current
    const branch_result = git_route.run(allocator, io, path_param, &.{ "branch", "--show-current" }, .{}) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // Get status using: git -C <path> status --porcelain
    const status_result = git_route.run(allocator, io, path_param, &.{ "status", "--porcelain" }, .{}) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Parse the status output
    var response = parseGitStatus(allocator, status_result.stdout);
    response.is_git_repo = true;
    response.branch = branch_name;

    // Expand untracked directories to show individual files (like VS Code Git, lazygit)
    if (response.untracked_files.len > 0) {
        // Collect directory paths (those ending with /)
        var dirs = std.ArrayList([]const u8).empty;
        defer {
            for (dirs.items) |d| allocator.free(d);
            dirs.deinit(allocator);
        }

        for (response.untracked_files) |file| {
            if (file.path.len > 0 and file.path[file.path.len - 1] == '/') {
                const copy = try allocator.dupe(u8, file.path);
                try dirs.append(allocator, copy);
            }
        }

        // If we have directories, expand them
        if (dirs.items.len > 0) {
            const expanded_files = try expandUntrackedDirectories(allocator, io, dirs.items, path_param);

            // Free the dir strings (they're no longer needed)
            for (dirs.items) |d| allocator.free(d);

            // Free old untracked files
            for (response.untracked_files) |f| {
                allocator.free(f.index_status);
                allocator.free(f.worktree_status);
                allocator.free(f.path);
            }
            allocator.free(response.untracked_files);

            // Build new untracked files list with expanded files
            var new_untracked = std.ArrayList(GitFileChange).empty;
            defer new_untracked.deinit(allocator);

            for (expanded_files) |file_path| {
                const change = GitFileChange{
                    .index_status = try allocator.dupe(u8, "?"),
                    .worktree_status = try allocator.dupe(u8, "?"),
                    .path = file_path, // already allocated by expandUntrackedDirectories
                };
                try new_untracked.append(allocator, change);
            }

            response.untracked_files = try new_untracked.toOwnedSlice(allocator);

            // Recalculate has_changes
            response.has_changes = response.staged_files.len > 0 or
                response.modified_files.len > 0 or
                response.untracked_files.len > 0;
        }
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitChangesResponse(allocator, response) });
}

/// Custom JSON serialization for GitChangesResponse using std.json
fn makeGitChangesResponse(allocator: std.mem.Allocator, response: GitChangesResponse) ![]u8 {
    // Build JSON manually with proper escaping
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // Helper to escape a string for JSON
    const escapeString = struct {
        fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(a);

            for (s) |c| {
                switch (c) {
                    '"' => try result.appendSlice(a, "\\\""),
                    '\\' => try result.appendSlice(a, "\\\\"),
                    '\n' => try result.appendSlice(a, "\\n"),
                    '\r' => try result.appendSlice(a, "\\r"),
                    '\t' => try result.appendSlice(a, "\\t"),
                    else => try result.append(a, c),
                }
            }
            return try result.toOwnedSlice(a);
        }
    }.escape;

    try buf.appendSlice(allocator, "{\"is_git_repo\":");
    try buf.appendSlice(allocator, if (response.is_git_repo) "true" else "false");

    try buf.appendSlice(allocator, ", \"branch\":");
    if (response.branch) |b| {
        const escaped = try escapeString(allocator, b);
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, escaped);
        try buf.appendSlice(allocator, "\"");
    } else {
        try buf.appendSlice(allocator, "null");
    }

    try buf.appendSlice(allocator, ", \"has_changes\":");
    try buf.appendSlice(allocator, if (response.has_changes) "true" else "false");

    // staged_files
    try buf.appendSlice(allocator, ", \"staged_files\":[");
    for (response.staged_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]");

    // modified_files
    try buf.appendSlice(allocator, ", \"modified_files\":[");
    for (response.modified_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]");

    // untracked_files
    try buf.appendSlice(allocator, ", \"untracked_files\":[");
    for (response.untracked_files, 0..) |file, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "{\"index_status\":\"");
        try buf.appendSlice(allocator, file.index_status);
        try buf.appendSlice(allocator, "\", \"worktree_status\":\"");
        try buf.appendSlice(allocator, file.worktree_status);
        try buf.appendSlice(allocator, "\", \"path\":\"");
        const escaped_path = try escapeString(allocator, file.path);
        try buf.appendSlice(allocator, escaped_path);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]}");

    return try buf.toOwnedSlice(allocator);
}

