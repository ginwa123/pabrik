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

        if (req.body.len > 0) {
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

test "http transport: a refused connection is NetworkFailed, not a panic" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var t = HttpTransport.init(testing.allocator, threaded.io());
    defer t.deinit();

    // Port 1 on loopback is never listening, so the connect fails immediately.
    try testing.expectError(error.NetworkFailed, t.asTransport().send(testing.allocator, .{
        .method = .get,
        .url = "http://127.0.0.1:1/nothing",
    }));
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
