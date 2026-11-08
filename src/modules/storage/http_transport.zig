//! The real transport: kabelweb's libcurl-backed client behind the
//! `Transport` seam. libcurl returns typed errors instead of printing, so a
//! failed request never lands in the log.

const std = @import("std");
const transport = @import("transport.zig");
const kabelweb = @import("kabelweb").client;

pub const HttpTransport = struct {
    client: kabelweb.Client,
    io: std.Io,
    /// kabelweb's client is thread-unsafe by design (one libcurl handle per
    /// worker) and the store is shared by the server's worker pool.
    lock: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpTransport {
        return .{ .client = kabelweb.Client.init(allocator), .io = io };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn asTransport(self: *HttpTransport) transport.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = transport.Transport.VTable{ .send = send };

    fn method(m: transport.Method) kabelweb.Method {
        return switch (m) {
            .get => .GET,
            .put => .PUT,
            .delete => .DELETE,
            .head => .HEAD,
        };
    }

    fn send(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        req: transport.Request,
    ) transport.Error!transport.Response {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        var headers: std.ArrayList(kabelweb.Header) = .empty;
        defer headers.deinit(allocator);
        for (req.headers) |h| {
            headers.append(allocator, .{ .name = h.name, .value = h.value }) catch
                return error.OutOfMemory;
        }

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        const resp = self.client.perform(.{
            .method = method(req.method),
            .url = req.url,
            .headers = headers.items,
            // `null` means "no body": a bodiless PUT (bucket create) must not
            // grow a Content-Length of its own.
            .body = if (req.body.len > 0) req.body else null,
        }, .{ .timeout_ms = 30_000 }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NetworkFailed,
        };
        defer resp.deinit(allocator);

        const body = allocator.dupe(u8, resp.body) catch return error.OutOfMemory;
        return .{
            .status = resp.status_code,
            .body = body,
            .content_length = contentLength(resp.headers),
        };
    }
};

/// The `Content-Length` the server reported. A HEAD response carries the
/// object size here and an empty body.
fn contentLength(headers: []const kabelweb.Header) ?u64 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
        }
    }
    return null;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A one-shot HTTP stub: accept, read whatever the client sent, write
/// `response`, close. Every failure here is a *protocol* failure, never a
/// socket-level one — Windows prints a stack trace for those in Debug builds.
fn serveOnce(io: std.Io, server: *std.Io.net.Server, response: []const u8) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var request: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    _ = reader.interface.readSliceShort(&request) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch return;
}

/// Send one request to a stub that answers with `response`, and return the
/// status the transport reports.
fn statusFromStub(method: transport.Method, body: []const u8, response: []const u8) !u16 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .mode = .stream });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const stub = try std.Thread.spawn(.{}, serveOnce, .{ io, &server, response });
    defer stub.join();

    var t = HttpTransport.init(testing.allocator, io);
    defer t.deinit();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/x", .{port});
    defer testing.allocator.free(url);

    const resp = try t.asTransport().send(testing.allocator, .{
        .method = method,
        .url = url,
        .body = body,
    });
    defer resp.deinit(testing.allocator);
    return resp.status;
}

test "http transport: a bodiless PUT is sent, not asserted away" {
    const status = try statusFromStub(.put, "", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), status);
}

test "http transport: a non-HTTP response is NetworkFailed" {
    try testing.expectError(error.NetworkFailed, statusFromStub(.get, "", "not http\r\n\r\n"));
}

test "http transport: an unparseable URL is NetworkFailed" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var t = HttpTransport.init(testing.allocator, threaded.io());
    defer t.deinit();

    try testing.expectError(error.NetworkFailed, t.asTransport().send(testing.allocator, .{
        .method = .get,
        .url = "not a url",
    }));
}
