//! The HTTP seam the S3 backend talks through. A test supplies a fake and
//! asserts on the requests it received; production supplies the real client.

const std = @import("std");

pub const Method = enum {
    get,
    put,
    delete,
    head,

    pub fn asString(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .put => "PUT",
            .delete => "DELETE",
            .head => "HEAD",
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    /// Absolute URL, scheme included.
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    /// Owned by the caller; free with `deinit`.
    body: []u8,
    /// The `Content-Length` the server reported, when it reported one. A HEAD
    /// response carries the object size here and an empty body.
    content_length: ?u64 = null,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Error = error{
    NetworkFailed,
    OutOfMemory,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, req: Request) Error!Response,
    };

    pub fn send(self: Transport, allocator: std.mem.Allocator, req: Request) Error!Response {
        return self.vtable.send(self.ptr, allocator, req);
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "method: every verb spells its wire name" {
    try testing.expectEqualStrings("GET", Method.get.asString());
    try testing.expectEqualStrings("PUT", Method.put.asString());
    try testing.expectEqualStrings("DELETE", Method.delete.asString());
    try testing.expectEqualStrings("HEAD", Method.head.asString());
}

test "response deinit releases the body it owns" {
    const alloc = testing.allocator;
    const body = try alloc.dupe(u8, "payload");
    const resp = Response{ .status = 200, .body = body };
    resp.deinit(alloc);
}
