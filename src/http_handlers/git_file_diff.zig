const std = @import("std");
const http_response = @import("http_response.zig");
const photon = @import("pabrikcore");
const gserverz = photon.gserverz;

/// Git file read response. The per-file DIFF endpoint that used to live here
/// (`GET /api/git/file/diff?path=&file=&staged=`) is GONE.
pub const GitFileReadResponse = struct { content: []const u8, encoding: []const u8 };

/// Read a file from git repository (working tree)
pub fn gitFileReadHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path and file from query parameters
    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const file_param = query.get("file") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing file parameter") });
    };

    // Both values come straight from the query string.
    if (!std.fs.path.isAbsolute(path_param)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "path must be an absolute directory") });
    }
    if (std.fs.path.isAbsolute(file_param)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "file must be relative to path") });
    }

    // Build full file path
    const file_path = std.fs.path.join(allocator, &.{ path_param, file_param }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    defer allocator.free(file_path);

    // Open the file using std.Io.Dir
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    const response = GitFileReadResponse{ .content = content, .encoding = "utf-8" };

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitFileReadResponse(allocator, response) });
}

/// Custom JSON serialization for GitFileReadResponse
fn makeGitFileReadResponse(allocator: std.mem.Allocator, response: GitFileReadResponse) ![]u8 {
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

    try buf.appendSlice(allocator, "{\"content\":\"");
    const escaped_content = try escapeString(allocator, response.content);
    defer allocator.free(escaped_content);
    try buf.appendSlice(allocator, escaped_content);
    try buf.appendSlice(allocator, "\", \"encoding\":\"");
    const escaped_encoding = try escapeString(allocator, response.encoding);
    defer allocator.free(escaped_encoding);
    try buf.appendSlice(allocator, escaped_encoding);
    try buf.appendSlice(allocator, "\"}");

    return try buf.toOwnedSlice(allocator);
}
