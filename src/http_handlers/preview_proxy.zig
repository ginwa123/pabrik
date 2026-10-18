//! The preview proxy: one host request for a workspace's dev server, with the
//! app's credentials stripped on the way in and a tenant document rendered only
//! on the workspace's own preview domain.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

const http_response = @import("http_response.zig");
const preview_origin = @import("preview_origin.zig");
const files_download = @import("files_download.zig");
const auth_common = @import("auth_common.zig");
const workspace_fs = @import("../agentic_loop/workspace_fs.zig");
const proxy_rpc = @import("../vmd/proxy_rpc.zig");

/// The guest path when the caller does not name one.
pub const default_guest_path = "/";
/// Headers the proxy sets itself, so an incoming one is never relayed.
const own_request_headers = [_][]const u8{ "host", "content-length", "connection", "proxy-connection" };

/// The request the guest dev server sees: the caller's method and path, the
/// caller's headers minus every credential, and one connection that closes.
pub fn guestRequestBytes(
    allocator: std.mem.Allocator,
    method: []const u8,
    guest_path: []const u8,
    port: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendFmt(&out, allocator, "{s} {s} HTTP/1.1\r\n", .{ method, guest_path });
    try appendFmt(&out, allocator, "Host: 127.0.0.1:{d}\r\n", .{port});
    try out.appendSlice(allocator, "X-Forwarded-Proto: http\r\n");
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (!preview_origin.requestHeaderForwarded(entry.key_ptr.*)) continue;
        if (inList(&own_request_headers, entry.key_ptr.*)) continue;
        // A value may not end the line it rides on, whatever the caller sent.
        if (!headerSafe(entry.key_ptr.*) or !headerSafe(entry.value_ptr.*)) continue;
        try appendFmt(&out, allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try out.appendSlice(allocator, "Connection: close\r\n");
    if (body.len > 0) try appendFmt(&out, allocator, "Content-Length: {d}\r\n", .{body.len});
    try out.appendSlice(allocator, "\r\n");
    if (body.len > 0) try out.appendSlice(allocator, body);
    if (out.items.len > proxy_rpc.max_request_bytes) return error.RequestTooLarge;
    return out.toOwnedSlice(allocator);
}

/// A guest path the proxy will send: absolute, and free of the bytes that
/// would end the request line or inject a header of their own.
pub fn guestPathValid(path: []const u8) bool {
    if (path.len == 0 or path.len > 2048 or path[0] != '/') return false;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f or c == ' ') return false;
    }
    return true;
}

pub const GuestResponse = struct {
    status: u16,
    status_text: []const u8,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
};

/// The parts of a guest HTTP answer the proxy relays. Slices point into
/// `bytes`, which the caller owns. Response headers are rebuilt rather than
/// relayed: a tenant `Set-Cookie` must never cross back to the app origin.
pub fn parseGuestResponse(bytes: []const u8) ?GuestResponse {
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        if (std.mem.indexOf(u8, bytes, "\n\n")) |at| return parseGuestHead(bytes, at + 2, bytes[at + 2 ..]);
        return null;
    };
    return parseGuestHead(bytes, head_end + 4, bytes[head_end + 4 ..]);
}

fn parseGuestHead(bytes: []const u8, body_at: usize, body: []const u8) ?GuestResponse {
    const line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
    const status_line = std.mem.trim(u8, bytes[0..line_end], "\r");
    const after_version = std.mem.indexOfScalar(u8, status_line, ' ') orelse return null;
    const rest = std.mem.trim(u8, status_line[after_version + 1 ..], " ");
    const code_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const status = std.fmt.parseInt(u16, rest[0..code_end], 10) catch return null;
    if (status < 100 or status > 599) return null;
    const text = if (code_end == rest.len) "OK" else std.mem.trim(u8, rest[code_end + 1 ..], " ");
    // The status text lands in OUR status line, so a control byte in it is a
    // response-header injection against whatever sits in front of this server.
    if (!headerSafe(text)) return null;
    var content_type: []const u8 = "";
    var content_encoding: []const u8 = "";
    var header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse body_at;
    if (std.mem.indexOf(u8, bytes, "\n\n")) |at| {
        if (at < header_end) header_end = at;
    }
    var lines = std.mem.splitScalar(u8, bytes[line_end + 1 .. header_end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!preview_origin.responseHeaderForwarded(name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!headerSafe(value)) continue;
        if (std.ascii.eqlIgnoreCase(name, "content-type")) content_type = value;
        if (std.ascii.eqlIgnoreCase(name, "content-encoding")) content_encoding = value;
    }
    return .{
        .status = status,
        .status_text = if (text.len > 0) text else "OK",
        .content_type = content_type,
        .content_encoding = content_encoding,
        .body = body,
    };
}

/// `attachment` when a document must not render where it arrived. A guest
/// `.html` or `.svg` is an active document: on the app origin it downloads,
/// and only on the workspace's own preview domain does it render at all.
pub fn previewDisposition(content_type: []const u8, on_preview_origin: bool) ?[]const u8 {
    if (on_preview_origin) return null;
    if (files_download.inlineAllowed(content_type)) return null;
    return "attachment";
}

/// The preview domain for a workspace, when the deployment named one.
pub fn previewHostFor(
    allocator: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    workspace_id: []const u8,
) ?[]const u8 {
    const map = env orelse return null;
    const base = map.get("PABRIK_PREVIEW_BASE") orelse return null;
    if (base.len == 0) return null;
    return preview_origin.previewHost(allocator, workspace_id, base) catch null;
}

/// The origins a mutation may carry, in the scheme-qualified form
/// `originVerdict` compares: the engine's own list, so the handler can never
/// be more permissive than the gate that runs before it.
fn allowedOrigins(allocator: std.mem.Allocator, hosts: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (hosts) |host| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "http://{s}", .{host}));
        try out.append(allocator, try std.fmt.allocPrint(allocator, "https://{s}", .{host}));
    }
    return out.toOwnedSlice(allocator);
}

/// Whether a header name or value can be written into a request line-safely:
/// no CR, LF, NUL or other control byte, and a tab is not a separator here.
pub fn headerSafe(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// One formatted line into the request being built. A line that does not fit a
/// 8 KiB stack buffer is refused rather than split.
fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    try list.appendSlice(allocator, try std.fmt.bufPrint(&buf, fmt, args));
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    }
    return false;
}

fn refuse(res: gserverz.HttpResponse, allocator: std.mem.Allocator, status: u16, message: []const u8) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = status,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
    });
}

/// `GET|POST /api/preview?workspace_id=..&port=..&path=..`: the one route that
/// reaches a guest port. Anything the guest answers is rebuilt here, so the
/// app's own origin only ever carries inert bytes.
pub fn previewProxyHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const workspace_id = req.query.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return refuse(res, allocator, 400, "workspace_id is required");
    const port_text = req.query.get("port") orelse "";
    const port = std.fmt.parseInt(u16, port_text, 10) catch 0;
    if (port == 0) return refuse(res, allocator, 400, "port is required, and is a port number");
    const guest_path = req.query.get("path") orelse default_guest_path;
    if (!guestPathValid(guest_path)) {
        return refuse(res, allocator, 400, "path must be an absolute request path with no control bytes");
    }

    const di = pabrikcore.getSingleton() catch {
        return refuse(res, allocator, 503, "preview is unavailable: the server is not initialised");
    };
    if (di.auth_enabled) {
        const token = auth_common.parseSessionToken(req.headers) orelse
            return refuse(res, allocator, 401, "Unauthenticated");
        const session = auth_common.lookupSession(allocator, di.db, token) orelse
            return refuse(res, allocator, 401, "Unauthenticated");
        defer auth_common.freeSessionLookup(allocator, session);
        if (!auth_common.canSeeWorkspace(allocator, di.db, workspace_id, session.user_id)) {
            return refuse(res, allocator, 404, "Workspace not found");
        }
    }

    const preview_host = previewHostFor(allocator, di.environment, workspace_id);
    const on_preview_origin = preview_host != null and hostHeaderIs(req.headers, preview_host.?);
    if (preview_origin.isMutatingMethod(req.method)) {
        const allowed = try allowedOrigins(allocator, ctx.allowed_origins);
        const origin = req.headers.get("Origin") orelse req.headers.get("origin");
        if (preview_origin.originVerdict(origin, allowed).refused()) {
            return refuse(res, allocator, 403, "a foreign Origin may not drive this workspace");
        }
    }

    const request_bytes = guestRequestBytes(allocator, req.method, guest_path, port, req.headers, req.body) catch |err| {
        return refuse(res, allocator, 400, @errorName(err));
    };
    const reply = workspace_fs.previewExchange(allocator, workspace_id, port, request_bytes) catch |err| {
        return refuse(res, allocator, 502, @errorName(err));
    };
    defer reply.deinit(allocator);
    if (reply.refused()) return refuse(res, allocator, 502, reply.failure.?);
    const guest = parseGuestResponse(reply.bytes) orelse
        return refuse(res, allocator, 502, "the guest answer is not an HTTP response");

    var out = gserverz.HttpResponse.init(guest.status, guest.status_text, allocator).withBody(guest.body);
    if (guest.content_type.len > 0) out = out.setContentType(guest.content_type);
    if (guest.content_encoding.len > 0) out = out.withHeader("Content-Encoding", guest.content_encoding);
    out = out.withHeader("X-Content-Type-Options", "nosniff");
    out = out.withHeader("Content-Security-Policy", preview_origin.preview_csp);
    out = out.withHeader("Referrer-Policy", "no-referrer");
    if (previewDisposition(guest.content_type, on_preview_origin)) |disposition| {
        out = out.withHeader("Content-Disposition", disposition);
    }
    if (preview_host) |host| out = out.withHeader("X-Preview-Origin", host);
    return out;
}

/// Whether the request arrived on a workspace's own preview domain, which is
/// what decides if a tenant document may render.
pub fn hostHeaderIs(headers: std.StringHashMap([]const u8), host: []const u8) bool {
    const value = headers.get("Host") orelse headers.get("host") orelse return false;
    const trimmed = std.mem.trim(u8, value, " ");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    return std.ascii.eqlIgnoreCase(trimmed[0..colon], host);
}

const testing = std.testing;

fn headersWith(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the app's credentials never reach the tenant's dev server" {
    const allocator = testing.allocator;
    var headers = try headersWith(allocator, &.{
        .{ "Cookie", "pabrik_session=secret" },
        .{ "Authorization", "Bearer secret" },
        .{ "Proxy-Authorization", "Basic secret" },
        .{ "X-Api-Key", "secret" },
        .{ "Accept", "text/html" },
        .{ "Host", "127.0.0.1:8081" },
        .{ "Connection", "keep-alive" },
        .{ "Transfer-Encoding", "chunked" },
    });
    defer headers.deinit();
    const bytes = try guestRequestBytes(allocator, "GET", "/index.html", 3000, headers, "");
    defer allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Cookie") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Authorization") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "GET /index.html HTTP/1.1\r\n") == 0);
    try testing.expect(std.mem.indexOf(u8, bytes, "Host: 127.0.0.1:3000\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Connection: close\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Accept: text/html\r\n") != null);
}

test "a request with a body carries exactly that body, once" {
    const allocator = testing.allocator;
    var headers = try headersWith(allocator, &.{.{ "Content-Type", "application/json" }});
    defer headers.deinit();
    const bytes = try guestRequestBytes(allocator, "POST", "/api/thing", 5173, headers, "{\"a\":1}");
    defer allocator.free(bytes);
    try testing.expect(std.mem.endsWith(u8, bytes, "\r\n\r\n{\"a\":1}"));
    try testing.expect(std.mem.indexOf(u8, bytes, "Content-Length: 7\r\n") != null);
}

test "a path that would inject a header or a second request line is refused" {
    try testing.expect(guestPathValid("/index.html"));
    try testing.expect(guestPathValid("/a/b?c=1&d=2"));
    try testing.expect(!guestPathValid(""));
    try testing.expect(!guestPathValid("index.html"));
    try testing.expect(!guestPathValid("/a\r\nX-Evil: 1"));
    try testing.expect(!guestPathValid("/a\nGET /b HTTP/1.1"));
    try testing.expect(!guestPathValid("/a b"));
}

test "the guest's answer is read back as status, type and body" {
    const allocator = testing.allocator;
    const raw = "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "Content-Encoding: gzip\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Set-Cookie: pabrik_session=evil\r\n\r\n<body>";
    _ = allocator;
    const parsed = parseGuestResponse(raw).?;
    try testing.expectEqual(@as(u16, 404), parsed.status);
    try testing.expectEqualStrings("Not Found", parsed.status_text);
    try testing.expectEqualStrings("text/html; charset=utf-8", parsed.content_type);
    try testing.expectEqualStrings("gzip", parsed.content_encoding);
    try testing.expectEqualStrings("<body>", parsed.body);
}

test "an answer that is not an HTTP response is refused, not relayed" {
    try testing.expect(parseGuestResponse("hello there") == null);
    try testing.expect(parseGuestResponse("HTTP/1.1 abc OK\r\n\r\n") == null);
    try testing.expect(parseGuestResponse("HTTP/1.1 9999 Nope\r\n\r\n") == null);
}

test "a tenant document is an attachment on the app origin and renders only on its own" {
    try testing.expectEqualStrings("attachment", previewDisposition("text/html; charset=utf-8", false).?);
    try testing.expectEqualStrings("attachment", previewDisposition("text/html", false).?);
    try testing.expectEqualStrings("attachment", previewDisposition("image/svg+xml", false).?);
    try testing.expectEqualStrings("attachment", previewDisposition("application/javascript", false).?);
    try testing.expectEqualStrings("attachment", previewDisposition("", false).?);
    try testing.expect(previewDisposition("image/png", false) == null);
    try testing.expect(previewDisposition("text/html", true) == null);
}

test "a preview host is only recognised when the request arrived on it" {
    const allocator = testing.allocator;
    var headers = try headersWith(allocator, &.{.{ "Host", "ws_1.preview.example.net:8443" }});
    defer headers.deinit();
    try testing.expect(hostHeaderIs(headers, "ws_1.preview.example.net"));
    try testing.expect(!hostHeaderIs(headers, "example.net"));
    try testing.expect(!hostHeaderIs(headers, "ws_2.preview.example.net"));
}

test "the workspace's preview domain is not a subdomain of the app's" {
    const allocator = testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PABRIK_PREVIEW_BASE", "preview.example.net");
    const host = previewHostFor(allocator, &env, "ws_1").?;
    try testing.expectEqualStrings("ws_1.preview.preview.example.net", host);
    try testing.expect(!preview_origin.isSubdomainOf("pabrik.example.com", host));
    try testing.expect(previewHostFor(allocator, null, "ws_1") == null);
}
