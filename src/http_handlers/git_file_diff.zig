const std = @import("std");
const http_response = @import("http_response.zig");
const photon = @import("pabrikcore");
const gserverz = photon.gserverz;
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

    // Open `safe_path`, never the joined form: only the canonical path has been
    // proven to be inside the requested directory.
    const safe_path = resolveReadPath(io, allocator, path_param, file_param) catch |err| switch (err) {
        error.TargetUnreachable => return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) }),
        else => return res.jsonResponse(.{ .status_code = 403, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) }),
    };
    defer allocator.free(safe_path);

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

/// The one path this endpoint may open: `file` resolved inside `dir`, or an
/// error. Split out so the rule is testable without an HTTP request.
fn resolveReadPath(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, file: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(dir)) return error.DirNotAbsolute;
    if (std.fs.path.isAbsolute(file)) return error.FileNotRelative;

    const root_canon = std.Io.Dir.realPathFileAbsoluteAlloc(io, dir, allocator) catch return error.RootUnreachable;
    defer allocator.free(root_canon);
    if (isFilesystemRoot(root_canon)) return error.FilesystemRoot;

    const joined = try std.fs.path.join(allocator, &.{ dir, file });
    defer allocator.free(joined);
    return file_sandbox.resolveInsideRoot(io, allocator, dir, joined, file_sandbox.nativeStyle());
}

/// `/` and `C:\` — a directory that contains everything is not a project root,
/// and treating it as one authorises every path on the box.
fn isFilesystemRoot(p: []const u8) bool {
    if (std.mem.eql(u8, p, "/")) return true;
    return p.len == 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
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

// ─────────────────────────────────────────────────────────────────────────
// Behaviour: this endpoint hands out one file inside the directory it was
// given. Every test drives `resolveReadPath`, the handler's only decision.

const testing = std.testing;

/// The absolute path of a `tmpDir`, so a test can pass it to a function that
/// demands an absolute directory.
fn tmpAbs(allocator: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(testing.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn writeAt(dir: std.Io.Dir, rel: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(testing.io, parent);
    var file = try dir.createFile(testing.io, rel, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, contents);
}

test "a file inside the requested directory resolves to a path holding its bytes" {
    const allocator = testing.allocator;
    var repo = testing.tmpDir(.{});
    defer repo.cleanup();
    try writeAt(repo.dir, "src/main.zig", "pub fn main() void {}\n");
    const dir_abs = try tmpAbs(allocator, repo.dir);
    defer allocator.free(dir_abs);

    const got = try resolveReadPath(testing.io, allocator, dir_abs, "src/main.zig");
    defer allocator.free(got);

    const body = try std.Io.Dir.cwd().readFileAlloc(testing.io, got, allocator, .limited(4096));
    defer allocator.free(body);
    try testing.expectEqualStrings("pub fn main() void {}\n", body);
}

test "a relative file that climbs out of the directory is refused" {
    const allocator = testing.allocator;
    var repo = testing.tmpDir(.{});
    defer repo.cleanup();
    var sibling = testing.tmpDir(.{});
    defer sibling.cleanup();
    try writeAt(sibling.dir, "secret.txt", "s\n");
    const dir_abs = try tmpAbs(allocator, repo.dir);
    defer allocator.free(dir_abs);
    const sibling_abs = try tmpAbs(allocator, sibling.dir);
    defer allocator.free(sibling_abs);

    const escape = try std.fmt.allocPrint(
        allocator,
        "../{s}/secret.txt",
        .{std.fs.path.basename(sibling_abs)},
    );
    defer allocator.free(escape);

    try testing.expectError(error.PathTraversal, resolveReadPath(testing.io, allocator, dir_abs, escape));
}

test "a filesystem root is never accepted as the directory to read from" {
    try testing.expectError(error.FilesystemRoot, resolveReadPath(testing.io, testing.allocator, "/", "etc/hostname"));
}

test "an absolute file is refused, because only the directory may choose the tree" {
    try testing.expectError(error.FileNotRelative, resolveReadPath(testing.io, testing.allocator, "/tmp", "/etc/hostname"));
}
