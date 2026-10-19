//! `GET
//! /api/files/download?session_id=<id>&path=<abs>&disposition=<inline|attachment>`
//! Serves workspace file bytes for the `present_files` agent tool card

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
// The one containment rule, shared with the `present_files` agent tool.
const file_sandbox = @import("../modules/agent/tools/file_sandbox.zig");

/// Cap mirrors `present_files.zig:MAX_FILE_BYTES` so every presented
/// file is downloadable. Must stay in sync (see the sync test below).
pub const MAX_DOWNLOAD_BYTES: usize = 50 * 1024 * 1024;

pub const Disposition = enum {
    inline_preview,
    attachment,
};

/// Parse the `?disposition=` query value. Absent → attachment (the safe
/// default: browsers download rather than render).
pub fn parseDisposition(raw: ?[]const u8) !Disposition {
    const s = raw orelse return .attachment;
    if (std.mem.eql(u8, s, "attachment")) return .attachment;
    if (std.mem.eql(u8, s, "inline")) return .inline_preview;
    return error.InvalidDisposition;
}

/// The only media types a browser may render from the app origin. A tenant's
/// `.html` or `.svg` is an active document, so neither is ever in here; the
/// list is raster images, pdf and media.
const inline_allowlist = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/x-icon",
    "application/pdf",
    "audio/mpeg",
    "video/mp4",
};

/// Whether a media type may be rendered inline, ignoring any `; charset=…`.
pub fn inlineAllowed(mime: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, mime, ';') orelse mime.len;
    const media_type = std.mem.trim(u8, mime[0..semi], " ");
    for (inline_allowlist) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, media_type)) return true;
    }
    return false;
}

/// Inline is a REQUEST, never a right: a type outside the allowlist is served
/// as an attachment whatever the caller asked for.
pub fn effectiveDisposition(requested: Disposition, mime: []const u8) Disposition {
    if (requested == .attachment) return .attachment;
    return if (inlineAllowed(mime)) .inline_preview else .attachment;
}

const MimeEntry = struct {
    ext: []const u8,
    mime: []const u8,
};

const mime_table = [_]MimeEntry{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".htm", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".css", .mime = "text/css; charset=utf-8" },
    .{ .ext = ".js", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".mjs", .mime = "application/javascript; charset=utf-8" },
    .{ .ext = ".json", .mime = "application/json; charset=utf-8" },
    .{ .ext = ".md", .mime = "text/markdown; charset=utf-8" },
    .{ .ext = ".txt", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".csv", .mime = "text/csv; charset=utf-8" },
    .{ .ext = ".log", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".zig", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".ts", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".py", .mime = "text/plain; charset=utf-8" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".gif", .mime = "image/gif" },
    .{ .ext = ".webp", .mime = "image/webp" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".pdf", .mime = "application/pdf" },
    .{ .ext = ".zip", .mime = "application/zip" },
    .{ .ext = ".mp3", .mime = "audio/mpeg" },
    .{ .ext = ".mp4", .mime = "video/mp4" },
};

/// Extension-based mime (case-insensitive ASCII, last `.` after the final
/// `/`).
pub fn mimeForPath(path: []const u8) []const u8 {
    var dot_idx: ?usize = null;
    for (path, 0..) |c, i| {
        if (c == '/') {
            dot_idx = null;
        } else if (c == '.') {
            dot_idx = i;
        }
    }
    const ext_start = dot_idx orelse return "application/octet-stream";
    const ext = path[ext_start..];
    for (mime_table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return "application/octet-stream";
}

// =====================================================================
// Handler
// =====================================================================

pub fn filesDownloadHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    _ = res;

    const session_id = req.query.get("session_id") orelse {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id query parameter" }),
        );
    };
    const path_param = req.query.get("path") orelse {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path query parameter" }),
        );
    };

    const disposition = parseDisposition(req.query.get("disposition")) catch {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid disposition (want \"inline\" or \"attachment\")" }),
        );
    };

    // Empty path is the PR #291 trap (`""` binds as NULL / fails
    // `isAbsolute`) — reject before touching the filesystem.
    if (path_param.len == 0) {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Empty path" }),
        );
    }
    if (!std.fs.path.isAbsolute(path_param)) {
        return gserverz.HttpResponse.init(400, "Bad Request", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path must be absolute" }),
        );
    }
    // Defense in depth (mirrors `static_files.resolve`): the canonicalization
    // below is the real protection.
    if (file_sandbox.hasParentSegment(path_param)) {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path traversal rejected" }),
        );
    }

    const di = try pabrikcore.getSingleton();
    const root = file_sandbox.resolveSessionRoot(allocator, di.db, session_id) catch |err| switch (err) {
        error.SessionNotFound => return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        ),
        else => return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session has no working directory" }),
        ),
    };
    defer allocator.free(root);

    // Canonicalize the target (resolves symlinks + `.` segments). A
    // file-level symlink pointing outside the root resolves outside
    // and is rejected by the prefix check below.
    const canon_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, path_param, allocator) catch {
        return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        );
    };
    defer allocator.free(canon_z);
    const canon: []const u8 = canon_z;

    // Canonicalize the root the same way so the prefix comparison is
    // canonical-vs-canonical (a symlinked cwd would otherwise false-
    // reject every file inside it).
    const root_canon_z = std.Io.Dir.realPathFileAbsoluteAlloc(io, root, allocator) catch {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session working directory is not accessible" }),
        );
    };
    defer allocator.free(root_canon_z);
    const root_canon: []const u8 = root_canon_z;

    if (!file_sandbox.isInsideRoot(root_canon, canon, file_sandbox.nativeStyle())) {
        return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path escapes the session working directory" }),
        );
    }

    // Open with directories rejected deterministically, then size-cap.
    const file = std.Io.Dir.cwd().openFile(io, canon, .{ .allow_directory = false }) catch |err| switch (err) {
        error.IsDir => return gserverz.HttpResponse.init(403, "Forbidden", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Path is a directory" }),
        ),
        else => return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        ),
    };
    defer std.Io.File.close(file, io);

    const stat = std.Io.File.stat(file, io) catch {
        return gserverz.HttpResponse.init(404, "Not Found", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File not found" }),
        );
    };
    if (stat.size > MAX_DOWNLOAD_BYTES) {
        return gserverz.HttpResponse.init(413, "Content Too Large", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "File exceeds the 50 MiB download limit" }),
        );
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, canon, allocator, .limited(MAX_DOWNLOAD_BYTES + 1)) catch {
        return gserverz.HttpResponse.init(500, "Internal Server Error", allocator).withJson(
            try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read file" }),
        );
    };

    const mime = mimeForPath(canon);
    const basename = std.fs.path.basename(canon);
    const effective = effectiveDisposition(disposition, mime);
    // `withHeader` stores the slice by reference (same as `setContentType`
    // and every `makeErrorResponse` payload in this codebase) — do NOT free
    // it; it lives in the per-request allocator like all other handler
    const disp_value = switch (effective) {
        .attachment => try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{basename}),
        .inline_preview => try std.fmt.allocPrint(allocator, "inline; filename=\"{s}\"", .{basename}),
    };

    // `withBody` sets Content-Length; `setContentType` sets Content-Type.
    // `nosniff` is unconditional: the extension-derived type must never be
    // re-interpreted by the browser into something renderable.
    var resp = gserverz.HttpResponse.init(200, "OK", allocator).withBody(bytes).setContentType(mime).withHeader(
        "Content-Disposition",
        disp_value,
    ).withHeader("X-Content-Type-Options", "nosniff");
    if (effective == .inline_preview) {
        resp = resp.withHeader("Cache-Control", "private, max-age=3600");
    } else {
        resp = resp.withHeader("Cache-Control", "no-store");
    }
    return resp;
}

const testing = std.testing;

test "parseDisposition defaults to attachment and rejects unknown" {
    try testing.expectEqual(Disposition.attachment, try parseDisposition(null));
    try testing.expectEqual(Disposition.attachment, try parseDisposition("attachment"));
    try testing.expectEqual(Disposition.inline_preview, try parseDisposition("inline"));
    try testing.expectError(error.InvalidDisposition, parseDisposition("download"));
    try testing.expectError(error.InvalidDisposition, parseDisposition(""));
}

test "mimeForPath maps common extensions and falls back to octet-stream" {
    try testing.expectEqualStrings("image/jpeg", mimeForPath("/a/photo.JPG"));
    try testing.expectEqualStrings("image/png", mimeForPath("/a/img.png"));
    try testing.expectEqualStrings("text/plain; charset=utf-8", mimeForPath("/a/notes.txt"));
    try testing.expectEqualStrings("application/pdf", mimeForPath("/a/doc.pdf"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/a/noext"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/a/file.unknownext"));
}

test "inlineAllowed: active documents are not renderable types" {
    try testing.expect(inlineAllowed("image/png"));
    try testing.expect(inlineAllowed("image/jpeg"));
    try testing.expect(inlineAllowed("application/pdf"));
    try testing.expect(inlineAllowed("video/mp4"));
    try testing.expect(inlineAllowed("image/png; charset=binary"));

    try testing.expect(!inlineAllowed("text/html; charset=utf-8"));
    try testing.expect(!inlineAllowed("text/html"));
    try testing.expect(!inlineAllowed("image/svg+xml"));
    try testing.expect(!inlineAllowed("text/plain; charset=utf-8"));
    try testing.expect(!inlineAllowed("application/javascript; charset=utf-8"));
    try testing.expect(!inlineAllowed("application/octet-stream"));
}

test "effectiveDisposition: an inline request for an active document downloads" {
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.inline_preview, "text/html; charset=utf-8"));
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.inline_preview, "image/svg+xml"));
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.inline_preview, "application/octet-stream"));
    try testing.expectEqual(Disposition.inline_preview, effectiveDisposition(.inline_preview, "image/png"));
    try testing.expectEqual(Disposition.inline_preview, effectiveDisposition(.inline_preview, "application/pdf"));
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.attachment, "image/png"));
}

test "every mime the table can produce is classified, never left undefined" {
    // An uploaded `.svg` is the stored-XSS case: mimeForPath knows it, and the
    // disposition rule must still refuse to render it.
    try testing.expectEqualStrings("image/svg+xml", mimeForPath("/a/logo.svg"));
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.inline_preview, mimeForPath("/a/logo.svg")));
    try testing.expectEqual(Disposition.attachment, effectiveDisposition(.inline_preview, mimeForPath("/a/x.html")));
    try testing.expectEqual(Disposition.inline_preview, effectiveDisposition(.inline_preview, mimeForPath("/a/x.png")));
}

test "the shared rule is the one this endpoint applies" {
    // The container / sibling / drive-letter cases live in
    // `file_sandbox.zig` (they need the explicit PathStyle to be testable
    // from a posix host). This only pins that the handler reaches for it.
    const style = file_sandbox.nativeStyle();
    try testing.expect(file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abc", style));
    try testing.expect(file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abc/file.txt", style));
    try testing.expect(!file_sandbox.isInsideRoot("/tmp/abc", "/tmp/abcd/file.txt", style));
    try testing.expect(!file_sandbox.isInsideRoot("/tmp/abc", "/etc/passwd", style));
    // `..` is a traversal; a dotted filename is not (the tool agrees).
    try testing.expect(file_sandbox.hasParentSegment("/tmp/abc/../x"));
    try testing.expect(!file_sandbox.hasParentSegment("/tmp/abc/report..html"));
}

test "MAX_DOWNLOAD_BYTES stays in sync with the tool cap" {
    const present_files = @import("../modules/agent/tools/present_files.zig");
    try testing.expectEqual(present_files.MAX_FILE_BYTES, MAX_DOWNLOAD_BYTES);
}
