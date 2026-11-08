//! The real transport: `std.http.Client` behind the `Transport` seam. `std.http`
//! rather than kabelweb because S3 needs HEAD and kabelweb's `Method` has none.

const std = @import("std");
const transport = @import("transport.zig");
const storage = @import("storage.zig");

pub const HttpTransport = struct {
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpTransport {
        return .{ .client = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn asTransport(self: *HttpTransport) transport.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = transport.Transport.VTable{ .send = send };

    fn httpMethod(method: transport.Method) std.http.Method {
        return switch (method) {
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

        const uri = std.Uri.parse(req.url) catch return error.NetworkFailed;

        var extra: std.ArrayList(std.http.Header) = .empty;
        defer extra.deinit(allocator);
        for (req.headers) |h| {
            extra.append(allocator, .{ .name = h.name, .value = h.value }) catch
                return error.OutOfMemory;
        }

        var request = self.client.request(httpMethod(req.method), uri, .{
            .extra_headers = extra.items,
            .redirect_behavior = .not_allowed,
        }) catch return error.NetworkFailed;
        defer request.deinit();

        // PUT always carries a body, even an empty one: `sendBodiless` asserts
        // the method has none, and a bucket-create is a bodiless PUT.
        if (req.body.len > 0 or httpMethod(req.method).requestHasBody()) {
            request.sendBodyComplete(@constCast(req.body)) catch return error.NetworkFailed;
        } else {
            request.sendBodiless() catch return error.NetworkFailed;
        }

        var redirect_buf: [1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buf) catch return error.NetworkFailed;

        const content_length = response.head.content_length;

        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(allocator, .limited(storage.MAX_OBJECT_BYTES)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NetworkFailed,
        };

        return .{
            .status = @intCast(@intFromEnum(response.head.status)),
            .body = body,
            .content_length = content_length,
        };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Accept one connection and close it, so the client's connect succeeds and
/// the request fails at the handshake. A refused connect would do the same
/// job, but Windows prints a stack trace for it in Debug builds.
fn acceptOnceAndClose(io: std.Io, server: *std.Io.net.Server) void {
    const stream = server.accept(io) catch return;
    stream.close(io);
}

/// Send one request to a listener that hangs up immediately and assert the
/// transport reports NetworkFailed.
fn expectNetworkFailed(method: transport.Method, body: []const u8) !void {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{ .mode = .stream });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const acceptor = try std.Thread.spawn(.{}, acceptOnceAndClose, .{ io, &server });
    defer acceptor.join();

    var t = HttpTransport.init(testing.allocator, io);
    defer t.deinit();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/x", .{port});
    defer testing.allocator.free(url);

    try testing.expectError(error.NetworkFailed, t.asTransport().send(testing.allocator, .{
        .method = method,
        .url = url,
        .body = body,
    }));
}

test "http transport: a connection that dies is NetworkFailed, not a panic" {
    try expectNetworkFailed(.get, "");
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

test "http transport: a bodiless PUT is sent, not asserted away" {
    try expectNetworkFailed(.put, "");
}
