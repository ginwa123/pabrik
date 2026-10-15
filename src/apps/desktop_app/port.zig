// src/apps/desktop_app/port.zig Free-port allocator. Binds to 127.0.0.1:0,
// lets the kernel pick an ephemeral port, reads it back, and returns the
// port.

const std = @import("std");

pub const FreePort = struct {
    port: u16,
    /// For debugging only; the OS may recycle the port after we close our probe
    /// socket. Currently always null — reserved for future use (e.g. logging
    /// the full path to a probe socket or a Unix-domain-socket path).
    path: ?[]u8 = null,
};

/// Find a free TCP port on the loopback interface. Returns the port number
/// the OS assigned.
pub fn findFree(allocator: std.mem.Allocator, io: std.Io) !FreePort {
    _ = allocator;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    // The listen() call resolved the ephemeral port into server.socket.address.
    const port = server.socket.address.getPort();
    return .{ .port = port, .path = null };
}

/// Best-effort "nothing is listening on 127.0.0.1:`port`" check. The probe
/// socket is closed before returning, so this is a *hint* — a TOCTOU race
/// with another process is possible.
pub fn isFree(allocator: std.mem.Allocator, io: std.Io, port: u16) bool {
    _ = allocator;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    var server = address.listen(io, .{}) catch return false;
    server.deinit(io);
    return true;
}

// ===== Tests merged from port_test.zig (2026-09-29 flatten) =====
// src/apps/desktop_app/port_test.zig Tests for the free-port allocator.

const testing = std.testing;

test "findFree returns a port we can bind to" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p = try findFree(allocator, io);
    defer if (p.path) |path| allocator.free(path);

    // Verify the port is actually bindable (we should be able to listen on it
    // a second time — well, after a small delay since we just closed the
    // probe). The exact port from findFree should be a valid, non-zero port.
    try testing.expect(p.port != 0);

    // Sanity-check that the address parses cleanly at the returned port.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", p.port);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
}

test "findFree returns different ports on consecutive calls" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p1 = try findFree(allocator, io);
    const p2 = try findFree(allocator, io);
    defer if (p1.path) |path| allocator.free(path);
    defer if (p2.path) |path| allocator.free(path);

    // Ephemeral port reuse: on a busy system, the OS may give the same port
    // back twice in a row. This is a heuristic test, not a strict guarantee.
    try testing.expect(p1.port != p2.port);
}
