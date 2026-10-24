const std = @import("std");
const http_response = @import("http_response.zig");
const photon = @import("pabrikcore");
const gserverz = photon.gserverz;
// The one containment rule, shared with `/api/files/download` and the
// `present_files` tool.
const file_sandbox = @import("../modules/agent/tools/file_sandbox.zig");

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

    // Containment: the request means "a file inside this directory", so
    // canonicalize both sides (the helper also rejects a `..` segment).
    const safe_path = file_sandbox.resolveInsideRoot(io, allocator, path_param, file_path, file_sandbox.nativeStyle()) catch |err| {
        return res.jsonResponse(.{ .status_code = 403, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };
    defer allocator.free(safe_path);

    // `?path=/` made every absolute path "inside the repo" — refuse it.
    const root_canon = std.Io.Dir.realPathFileAbsoluteAlloc(io, path_param, allocator) catch null;
    defer if (root_canon) |p| allocator.free(p);
    if (root_canon) |p| {
        if (isFilesystemRoot(p)) {
            return res.jsonResponse(.{ .status_code = 403, .data = try http_response.makeGitStatusErrorResponse(allocator, "path must be a repository, not a filesystem root") });
        }
    }

    // Open the file using std.Io.Dir
    const file = std.Io.Dir.openFileAbsolute(io, safe_path, .{}) catch |err| {
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

/// `/`, `C:`, `C:\` — a directory that contains everything is not a project
/// root, and treating it as one authorises every path on the box.
fn isFilesystemRoot(p: []const u8) bool {
    if (p.len == 0) return false;
    if (std.mem.eql(u8, p, "/")) return true;
    if (p.len == 2 and p[1] == ':') return true;
    if (p.len == 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return false;
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
