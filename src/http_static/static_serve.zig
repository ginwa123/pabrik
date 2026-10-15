//! Static-file HTTP fallback (`--static-dir`): resolve a request path to a
//! file under the root dir and buffer a complete HTTP response (status +
//! headers + body) for the listen loop to write to the socket.

const std = @import("std");
const gserverz = @import("kabelweb").server;
const static_files = @import("../modules/static_files.zig");

/// Where a generated certificate lives: `$XDG_DATA_HOME/pabrik/tls`,
/// else `~/.local/share/pabrik/tls` (POSIX) or `%LOCALAPPDATA%\pabrik\tls`
/// (Windows). State, not configuration, so never the config dir.
pub fn tlsDataDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const app_name = "pabrik";
    if (comptime @import("builtin").os.tag == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoDataDir;
        return std.fs.path.join(allocator, &.{ base, app_name, "tls" });
    }
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, app_name, "tls" });
    }
    const home = env.get("HOME") orelse return error.NoDataDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", app_name, "tls" });
}

/// Every static response MUST say this, because every static connection is
/// closed right after it (`http_server.zig`, `.hijack_static` arm: "static
/// responses are unframed: never reuse").
const CLOSE_HEADER = "Connection: close\r\n";

/// `GinwaServer` static-dir callback: buffers the response in a per-request
/// arena writer, then writes it to the socket. On internal error, resets to
/// a minimal 500 rather than leaving the connection hanging.
pub fn staticDirHandler(
    cfg: *const anyopaque,
    handler_allocator: std.mem.Allocator,
    handler_io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    stream: gserverz.Stream,
) anyerror!void {
    const typed_cfg: *const static_files.StaticDirConfig = @ptrCast(@alignCast(cfg));

    var aw: std.Io.Writer.Allocating = .init(handler_allocator);
    defer aw.deinit();

    writeStaticFileResponse(typed_cfg, handler_io, request_path, range_header, &aw.writer) catch {
        aw.writer.end = 0;
        const err_body = "Internal Server Error";
        try aw.writer.writeAll("HTTP/1.1 500 Internal Server Error\r\n");
        try aw.writer.print("Content-Length: {d}\r\n", .{err_body.len});
        try aw.writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
        try aw.writer.writeAll(CLOSE_HEADER);
        try aw.writer.writeAll("\r\n");
        try aw.writer.writeAll(err_body);
    };

    const out = aw.writer.buffered();
    if (out.len > 0) {
        stream.writeAll(out) catch {};
    }
}

/// Build the static-file HTTP response into `writer`: resolve, emit headers
/// (Content-Type, Content-Length, ETag, optional Content-Range / 206), then
/// stream the body (full or sliced). 404 / 403 for the matching lookups.
pub fn writeStaticFileResponse(
    cfg: *const static_files.StaticDirConfig,
    io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    const lookup = try static_files.resolve(cfg, io, request_path);
    switch (lookup) {
        .not_found, .not_a_file => {
            const body = "Not Found";
            try writer.writeAll("HTTP/1.1 404 Not Found\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll(CLOSE_HEADER);
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .forbidden => {
            const body = "Forbidden";
            try writer.writeAll("HTTP/1.1 403 Forbidden\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll(CLOSE_HEADER);
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .file => |f| {
            defer cfg.allocator.free(f.abs_path);

            // Content-derived ETag (size + mtime): same-size minified
            // bundles must not share an ETag or browsers cache-poison.
            const etag = try std.fmt.allocPrint(cfg.allocator, "\"x-{x}-{x}\"", .{ f.size, f.mtime.nanoseconds });
            defer cfg.allocator.free(etag);

            if (range_header) |rh| {
                if (try static_files.parseRange(rh, f.size)) |range| {
                    try writer.writeAll("HTTP/1.1 206 Partial Content\r\n");
                    try writer.print("Content-Range: bytes {d}-{d}/{d}\r\n", .{ range.start, range.end, f.size });
                    const content_length: u64 = range.end - range.start + 1;
                    try writer.print("Content-Length: {d}\r\n", .{content_length});
                    try writer.print("Content-Type: {s}\r\n", .{f.mime});
                    try writer.print("ETag: {s}\r\n", .{etag});
                    try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
                    try writer.writeAll(CLOSE_HEADER);
                    try writer.writeAll("\r\n");
                    try writeFileRange(io, f.abs_path, range.start, range.end, writer);
                    return;
                }
            }

            try writer.writeAll("HTTP/1.1 200 OK\r\n");
            try writer.print("Content-Length: {d}\r\n", .{f.size});
            try writer.print("Content-Type: {s}\r\n", .{f.mime});
            try writer.print("ETag: {s}\r\n", .{etag});
            try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
            try writer.writeAll(CLOSE_HEADER);
            try writer.writeAll("\r\n");
            try writeFileFull(io, f.abs_path, writer);
        },
    }
}

/// Stream the whole file at `abs_path` in 64 KB positional reads (the Zig
/// 0.16 idiom safe under `Io.Threaded`'s blocking recv model).
pub fn writeFileFull(io: std.Io, abs_path: []const u8, writer: *std.Io.Writer) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
    }
}

/// Stream `[start, end]` (inclusive) of the file at `abs_path`.
/// Caller ensures `start <= end < file_size`.
pub fn writeFileRange(
    io: std.Io,
    abs_path: []const u8,
    start: u64,
    end: u64,
    writer: *std.Io.Writer,
) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var remaining: u64 = end - start + 1;
    var offset: u64 = start;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buf.len));
        const n = try file.readPositionalAll(io, buf[0..to_read], offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
        remaining -= n;
    }
}

// ---------------------------------------------------------------------------
// Behaviour tests (wire payloads, not source text)
// ---------------------------------------------------------------------------

fn testRoot(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root_abs: []u8,
    fn deinit(self: *@This(), a: std.mem.Allocator) void {
        a.free(self.root_abs);
        self.tmp.cleanup();
    }
} {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try allocator.dupe(u8, path_buf[0..n]);
    return .{ .tmp = tmp, .root_abs = abs };
}

test "static_serve: missing asset path yields a 404 wire response" {
    const allocator = std.testing.allocator;
    var env = try testRoot(allocator);
    defer env.deinit(allocator);
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeStaticFileResponse(&cfg, std.testing.io, "/missing-bundle.js", null, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 9\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nNot Found"));
}

test "static_serve: path traversal yields a 403 wire response" {
    const allocator = std.testing.allocator;
    var env = try testRoot(allocator);
    defer env.deinit(allocator);
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeStaticFileResponse(&cfg, std.testing.io, "/../../etc/passwd", null, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 403 Forbidden\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nForbidden"));
}

test "static_serve: existing file round-trips its bytes with a 200" {
    const allocator = std.testing.allocator;
    var env = try testRoot(allocator);
    defer env.deinit(allocator);
    {
        const f = try env.tmp.dir.createFile(std.testing.io, "hello.txt", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "hello world");
    }
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeStaticFileResponse(&cfg, std.testing.io, "/hello.txt", null, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 11\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain; charset=utf-8\r\n") != null);
    // The connection is closed right after this response, so the response has
    // to SAY so — HTTP/1.1 is persistent by default and a client that is not
    // told otherwise may reuse the socket for the next asset, which surfaces
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhello world"));
}

test "static_serve: valid range yields a 206 with the requested slice" {
    const allocator = std.testing.allocator;
    var env = try testRoot(allocator);
    defer env.deinit(allocator);
    {
        const f = try env.tmp.dir.createFile(std.testing.io, "hello.txt", .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "hello world");
    }
    const cfg = static_files.StaticDirConfig{ .root_dir = env.root_abs, .allocator = allocator };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeStaticFileResponse(&cfg, std.testing.io, "/hello.txt", "bytes=0-4", &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 206 Partial Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Range: bytes 0-4/11\r\n") != null);
    // The connection is closed right after this response, so the response has
    // to SAY so — HTTP/1.1 is persistent by default and a client that is not
    // told otherwise may reuse the socket for the next asset, which surfaces
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nhello"));
}

test "static_serve: tlsDataDir honors XDG_DATA_HOME" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    // Windows never consults XDG_DATA_HOME (see tlsDataDir): the scope is
    // %LOCALAPPDATA%, joined with native separators.
    if (comptime @import("builtin").os.tag == .windows) {
        try env.put("XDG_DATA_HOME", "C:\\xdg-test");
        try env.put("LOCALAPPDATA", "C:\\Users\\testuser\\AppData\\Local");
        const dir = try tlsDataDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:\\Users\\testuser\\AppData\\Local\\pabrik\\tls", dir);
    } else {
        try env.put("XDG_DATA_HOME", "/tmp/xdg-test");
        const dir = try tlsDataDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/tmp/xdg-test/pabrik/tls", dir);
    }
}

test "static_serve: tlsDataDir falls back to HOME/.local/share" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    // Same platform split as above: HOME is POSIX-only scope, Windows
    // stays on %LOCALAPPDATA% even when HOME is set.
    if (comptime @import("builtin").os.tag == .windows) {
        try env.put("HOME", "C:\\home\\testuser");
        try env.put("LOCALAPPDATA", "C:\\Users\\testuser\\AppData\\Local");
        const dir = try tlsDataDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:\\Users\\testuser\\AppData\\Local\\pabrik\\tls", dir);
    } else {
        try env.put("HOME", "/home/testuser");
        const dir = try tlsDataDir(allocator, &env);
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/home/testuser/.local/share/pabrik/tls", dir);
    }
}

test "static_serve: tlsDataDir errors when the platform scope is absent" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    // Empty scope on either platform: POSIX has neither XDG_DATA_HOME
    // nor HOME, Windows has no LOCALAPPDATA (XDG/HOME must not rescue
    // it — that precedence is pinned by the two tests above).
    if (comptime @import("builtin").os.tag == .windows) {
        try env.put("XDG_DATA_HOME", "C:\\xdg-test");
        try env.put("HOME", "C:\\home\\testuser");
    }
    try std.testing.expectError(error.NoDataDir, tlsDataDir(allocator, &env));
}
