//! HTTP client wrapper around kabelweb's client module.

const std = @import("std");
const custom_http_client = @import("kabelweb").client;

pub const Response = custom_http_client.Response;

pub const Error = custom_http_client.Error || error{
    /// Server returned a non-2xx status (the response body is kept
    /// alongside the error so the CLI can print the server's error
    /// message verbatim).
    HttpRequestFailed,
};

/// Build a URL from `server` + `path` (which must start with `/`).
/// Caller owns the returned slice.
pub fn buildUrl(
    allocator: std.mem.Allocator,
    server: []const u8,
    path: []const u8,
) (Error || std.mem.Allocator.Error)![]u8 {
    if (path.len == 0 or path[0] != '/') return Error.HttpRequestFailed;
    const base = if (server.len > 0 and server[server.len - 1] == '/')
        server[0 .. server.len - 1]
    else
        server;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
}

const JSON_HEADER = [_]custom_http_client.Header{
    .{ .name = "Content-Type", .value = "application/json" },
};

/// GET that joins `server + path` and returns the parsed body.
/// Non-2xx responses become `Error.HttpRequestFailed`.
pub fn getJson(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    path: []const u8,
) Error![]u8 {
    const url = try buildUrl(allocator, server, path);
    defer allocator.free(url);
    const response = try custom_http_client.get(
        client,
        url,
        .{ .timeout_ms = 30_000 },
    );
    // The Response owns its body AND its headers/url_effective/primary_ip;
    // `Response.deinit` walks all of them. Always run it on the error path
    // so a 404 doesn't leak the parsed headers / effective URL.
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        std.log.warn(
            "GET {s} returned status {d}: {s}",
            .{ url, response.status_code, response.body },
        );
        return Error.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

/// POST with a JSON body. Returns the parsed body or
/// `Error.HttpRequestFailed` on a non-2xx status.
pub fn postJson(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    path: []const u8,
    body: []const u8,
) Error![]u8 {
    const url = try buildUrl(allocator, server, path);
    defer allocator.free(url);
    const response = try custom_http_client.post(
        client,
        url,
        body,
        &JSON_HEADER,
        .{ .timeout_ms = 30_000 },
    );
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        std.log.warn(
            "POST {s} returned status {d}: {s}",
            .{ url, response.status_code, response.body },
        );
        return Error.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "buildUrl: simple join" {
    const u = try buildUrl(testing.allocator, "http://x:8081", "/api/llm/session");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/llm/session", u);
}

test "buildUrl: strips trailing slash from server" {
    const u = try buildUrl(testing.allocator, "http://x:8081/", "/api/x");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/x", u);
}

test "buildUrl: rejects path without leading slash" {
    try testing.expectError(
        @as(anyerror, Error.HttpRequestFailed),
        buildUrl(testing.allocator, "http://x:8081", "api/x"),
    );
}

const testing = std.testing;

// ===== Tests merged from client_test.zig (2026-09-29 flatten) ===== Tests
// for src/client.zig (HTTP transport + JSON helpers).

/// Per-spawn context. Heap-allocated by `ClientTestEchoServer.start`, freed by
/// `ClientTestEchoServer.stop` after the thread joins.
const ClientTestServerCtx = struct {
    /// Raw HTTP response to write verbatim (status line + headers + body).
    /// This is what lets the 404 test assert that the client surfaces
    /// the status as `Error.HttpRequestFailed`.
    raw_response: []const u8,
};

const ClientTestEchoServer = struct {
    thread: ?std.Thread,
    port: u16,
    ctx_ptr: *ClientTestServerCtx,

    fn start(allocator: std.mem.Allocator, raw_response: []const u8) !ClientTestEchoServer {
        // Eagerly bring up the listener on the main thread so we can read
        // back the kernel-assigned ephemeral port (port=0 in `parseIp4(...,
        // 0)` means "OS picks"; the resolved port only lands in
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = address.listen(io, .{}) catch return error.AddressInUse;
        const port = server.socket.address.getPort();

        const ctx_ptr = try allocator.create(ClientTestServerCtx);
        ctx_ptr.* = .{ .raw_response = raw_response };
        // Hand the server fd over to the worker. We pass by-pointer
        // because std.Thread.spawn only copies the args tuple once.
        const srv_ptr = try allocator.create(@TypeOf(server));
        srv_ptr.* = server;

        const thread = try std.Thread.spawn(.{}, run, .{ ctx_ptr, srv_ptr, allocator });
        return .{ .thread = thread, .port = port, .ctx_ptr = ctx_ptr };
    }

    fn run(
        ctx_ptr: *ClientTestServerCtx,
        srv_ptr: *@TypeOf(@as(std.Io.net.Server, undefined)),
        parent_alloc: std.mem.Allocator,
    ) void {
        var threaded = std.Io.Threaded.init(parent_alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var server = srv_ptr.*;
        defer server.deinit(io);
        // Free the heap-allocated server we got from `start`.
        parent_alloc.destroy(srv_ptr);

        const conn = server.accept(io) catch return;
        defer conn.socket.close(io);

        var buf: [4096]u8 = undefined;
        var reader = conn.reader(io, &buf);
        // Drain the request: the test sends a small body (or no body at all
        // for GETs).
        _ = reader.interface.discard(std.Io.Limit.limited(8 * 1024)) catch {};

        var writer = conn.writer(io, &.{});
        writer.interface.writeAll(ctx_ptr.raw_response) catch return;
        writer.interface.flush() catch {};
    }

    fn stop(self: *ClientTestEchoServer, allocator: std.mem.Allocator) void {
        if (self.thread) |t| t.join();
        allocator.destroy(self.ctx_ptr);
    }
};

test "getJson: returns parsed body for a canned 200 OK" {
    const body = "{\"ok\":true,\"name\":\"smoke\"}";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try ClientTestEchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    const body_out = try getJson(testing.allocator, &client_inst, url, "/api/x");
    defer testing.allocator.free(body_out);

    try testing.expectEqualStrings(body, body_out);
}

test "getJson: returns Error.HttpRequestFailed for a 404" {
    const response_body = "404 page not found";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try ClientTestEchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    try testing.expectError(
        @as(anyerror, Error.HttpRequestFailed),
        getJson(testing.allocator, &client_inst, url, "/missing"),
    );
}

test "postJson: round-trips a JSON body" {
    const response_body = "{\"ok\":true}";
    const response_msg = try std.fmt.allocPrint(
        testing.allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    );
    defer testing.allocator.free(response_msg);

    var echo = try ClientTestEchoServer.start(testing.allocator, response_msg);
    defer echo.stop(testing.allocator);

    const url = try std.fmt.allocPrint(
        testing.allocator,
        "http://127.0.0.1:{d}",
        .{echo.port},
    );
    defer testing.allocator.free(url);

    var client_inst = custom_http_client.Client.init(testing.allocator);
    defer client_inst.deinit();

    const out = try postJson(
        testing.allocator,
        &client_inst,
        url,
        "/api/x",
        "{\"hello\":\"world\"}",
    );
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(response_body, out);
}