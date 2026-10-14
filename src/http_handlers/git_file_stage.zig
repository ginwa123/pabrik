const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

const GitStageResponse = http_response.GitStageResponse;

/// Tell the UI one path moved into the index, so the Files tab can move ONE
/// row instead of re-fetching the whole git-status list.
fn emitStageEvent(ctx: gserverz.HttpContext, path_param: []const u8, file: []const u8, failed: bool) void {
    const di = pabrik_core.getSingleton() catch return;
    pabrik_core.git_file_stage_events.emitStaged(ctx.allocator, di.event_bus, path_param, file, failed);
}

/// Tell the UI one path left the index. Same contract as `emitStageEvent`.
fn emitUnstageEvent(ctx: gserverz.HttpContext, path_param: []const u8, file: []const u8, failed: bool) void {
    const di = pabrik_core.getSingleton() catch return;
    pabrik_core.git_file_stage_events.emitUnstaged(ctx.allocator, di.event_bus, path_param, file, failed);
}

/// Stage files (git add)
pub fn gitStageHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Get files from query parameter (comma-separated list of file paths)
    const files_param = query.get("files") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing files parameter") });
    };

    // Split files by comma
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);

    var start: usize = 0;
    while (start < files_param.len) {
        const end = std.mem.indexOfScalar(u8, files_param[start..], ',') orelse files_param.len;
        const file = std.mem.trim(u8, files_param[start..start + end], " ");
        if (file.len > 0) {
            files.append(allocator, file) catch {};
        }
        start += end + 1;
    }

    if (files.items.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "No files to stage") });
    }

    // Stage each file
    var staged_files = std.ArrayList([]const u8).empty;
    var failed_files = std.ArrayList([]const u8).empty;
    defer {
        staged_files.deinit(allocator);
        failed_files.deinit(allocator);
    }

    for (files.items) |file| {
        // Use git add -v for verbose output (shows what's being staged)
        const argv = [_][]const u8{ "git", "-C", path_param, "add", "-v", "--", file };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |result| {
            if (result.term.exited == 0) {
                staged_files.append(allocator, file) catch {};
                emitStageEvent(ctx, path_param, file, false);
            } else {
                failed_files.append(allocator, file) catch {};
                emitStageEvent(ctx, path_param, file, true);
            }
        } else |_| {
            failed_files.append(allocator, file) catch {};
            emitStageEvent(ctx, path_param, file, true);
        }
    }

    const response = GitStageResponse{
        .success = failed_files.items.len == 0,
        .message = if (failed_files.items.len == 0) "All files staged successfully" else "Some files failed to stage",
        .staged_files = staged_files.toOwnedSlice(allocator) catch &.{},
        .failed_files = failed_files.toOwnedSlice(allocator) catch &.{},
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStageResponse(allocator, response) });
}

/// Unstage files (git restore --staged)
pub fn gitUnstageHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Get files from query parameter (comma-separated list of file paths)
    const files_param = query.get("files") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing files parameter") });
    };

    // Split files by comma
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);

    var start: usize = 0;
    while (start < files_param.len) {
        const end = std.mem.indexOfScalar(u8, files_param[start..], ',') orelse files_param.len;
        const file = std.mem.trim(u8, files_param[start..start + end], " ");
        if (file.len > 0) {
            files.append(allocator, file) catch {};
        }
        start += end + 1;
    }

    if (files.items.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "No files to unstage") });
    }

    // Unstage each file using git restore --staged (preferred in modern git)
    var unstaged_files = std.ArrayList([]const u8).empty;
    var failed_files = std.ArrayList([]const u8).empty;
    defer {
        unstaged_files.deinit(allocator);
        failed_files.deinit(allocator);
    }

    for (files.items) |file| {
        // Use git restore --staged -v for verbose output
        const argv = [_][]const u8{ "git", "-C", path_param, "restore", "--staged", "-v", "--", file };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |result| {
            if (result.term.exited == 0) {
                unstaged_files.append(allocator, file) catch {};
                emitUnstageEvent(ctx, path_param, file, false);
            } else {
                // Fallback to git reset HEAD if restore fails
                const reset_argv = [_][]const u8{ "git", "-C", path_param, "reset", "-q", "--", file };
                if (std.process.run(allocator, io, .{ .argv = &reset_argv })) |reset_result| {
                    if (reset_result.term.exited == 0) {
                        unstaged_files.append(allocator, file) catch {};
                        emitUnstageEvent(ctx, path_param, file, false);
                    } else {
                        failed_files.append(allocator, file) catch {};
                        emitUnstageEvent(ctx, path_param, file, true);
                    }
                } else |_| {
                    failed_files.append(allocator, file) catch {};
                    emitUnstageEvent(ctx, path_param, file, true);
                }
            }
        } else |_| {
            // Fallback to git reset HEAD
            const reset_argv = [_][]const u8{ "git", "-C", path_param, "reset", "-q", "--", file };
            if (std.process.run(allocator, io, .{ .argv = &reset_argv })) |reset_result| {
                if (reset_result.term.exited == 0) {
                    unstaged_files.append(allocator, file) catch {};
                    emitUnstageEvent(ctx, path_param, file, false);
                } else {
                    failed_files.append(allocator, file) catch {};
                    emitUnstageEvent(ctx, path_param, file, true);
                }
            } else |_| {
                failed_files.append(allocator, file) catch {};
                emitUnstageEvent(ctx, path_param, file, true);
            }
        }
    }

    const response = GitStageResponse{
        .success = failed_files.items.len == 0,
        .message = if (failed_files.items.len == 0) "All files unstaged successfully" else "Some files failed to unstage",
        .staged_files = unstaged_files.toOwnedSlice(allocator) catch &.{},
        .failed_files = failed_files.toOwnedSlice(allocator) catch &.{},
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStageResponse(allocator, response) });
}
