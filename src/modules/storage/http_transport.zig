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

test "http transport: every seam verb maps to a kabelweb verb" {
    try testing.expectEqual(kabelweb.Method.GET, HttpTransport.method(.get));
    try testing.expectEqual(kabelweb.Method.PUT, HttpTransport.method(.put));
    try testing.expectEqual(kabelweb.Method.DELETE, HttpTransport.method(.delete));
    try testing.expectEqual(kabelweb.Method.HEAD, HttpTransport.method(.head));
}

test "http transport: content-length is read from the response headers" {
    const headers = [_]kabelweb.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Content-Length", .value = " 42 " },
    };
    try testing.expectEqual(@as(?u64, 42), contentLength(&headers));
    try testing.expectEqual(@as(?u64, null), contentLength(&.{}));
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
