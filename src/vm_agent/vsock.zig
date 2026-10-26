//! The guest's side of the transport: the `sockaddr_vm` shape and the two
//! socket dances (`bind`+`listen`, `connect`) that the agent, the netd and the
//! bootstrap each used to spell out. Guest-only — the host binds unix sockets.

const std = @import("std");
const linux = std.os.linux;
const wire = @import("vm_wire");

/// `struct sockaddr_vm` as the kernel reads it. std already carries the shape,
/// so nothing in the guest re-declares it.
pub const Addr = linux.sockaddr.vm;

/// The host's side of a port appears on the guest's first dial, so a dial has
/// to wait for it: both guest loops (netd, the bootstrap) use these two.
pub const dial_attempts: usize = 15;
pub const dial_retry_ms: u64 = 200;

/// A socket call's result: the descriptor it produced, or the errno it failed
/// with — the two guest loops report different things about a failed dial.
pub const Outcome = union(enum) {
    fd: linux.fd_t,
    errno: linux.E,
};

pub fn addr(port: u32, cid: u32) Addr {
    return .{ .port = port, .cid = cid, .flags = 0 };
}

/// A listening vsock socket on `port`, closed again if `bind` or `listen` fail.
pub fn listen(port: u32, cid: u32, backlog: u32) Outcome {
    const rc = linux.socket(wire.vsock_af, linux.SOCK.STREAM, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .errno = linux.errno(rc) };
    const fd: linux.fd_t = @intCast(rc);
    var a = addr(port, cid);
    const bound = linux.errno(linux.bind(fd, @ptrCast(&a), @sizeOf(Addr)));
    if (bound != .SUCCESS) {
        _ = linux.close(fd);
        return .{ .errno = bound };
    }
    const listening = linux.errno(linux.listen(fd, backlog));
    if (listening != .SUCCESS) {
        _ = linux.close(fd);
        return .{ .errno = listening };
    }
    return .{ .fd = fd };
}

/// One dial attempt at the host's `port`; the caller owns the retry policy.
pub fn connect(port: u32, cid: u32) Outcome {
    const rc = linux.socket(wire.vsock_af, linux.SOCK.STREAM, 0);
    if (linux.errno(rc) != .SUCCESS) return .{ .errno = linux.errno(rc) };
    const fd: linux.fd_t = @intCast(rc);
    var a = addr(port, cid);
    const connected = linux.errno(linux.connect(fd, @ptrCast(&a), @sizeOf(Addr)));
    if (connected != .SUCCESS) {
        _ = linux.close(fd);
        return .{ .errno = connected };
    }
    return .{ .fd = fd };
}

test "the address is the kernel's 16-byte sockaddr_vm, carrying port and cid" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Addr));
    const a = addr(wire.agent_port, wire.cid_any);
    try std.testing.expectEqual(@as(u32, a.family), wire.vsock_af);
    try std.testing.expectEqual(wire.agent_port, a.port);
    try std.testing.expectEqual(wire.cid_any, a.cid);
}

test "a dial answers with a usable descriptor or the kernel's errno, never both" {
    switch (connect(wire.resolver_port, wire.cid_host)) {
        .fd => |fd| try std.testing.expect(fd >= 0),
        .errno => |e| try std.testing.expect(e != .SUCCESS),
    }
}
