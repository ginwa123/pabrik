//! The host's half of the agent hand-off: it serves the current agent to a
//! guest's bootstrap, so a workspace's disk never carries the agent and a new
//! one reaches every workspace at the next boot.

const std = @import("std");
const linux = std.os.linux;
const vm_client = @import("vm_client.zig");

/// The vsock port the guest's bootstrap dials.
pub const agent_port: u32 = 5003;

/// What the guest asks for.
pub const request_line = "AGENT\n";

/// The most a guest may ask for in one line.
pub const max_request_bytes: usize = 64;

/// The agent's bytes, as one transfer. The agent is ~13 MiB.
pub const max_agent_bytes: usize = 64 * 1024 * 1024;

/// True when the guest's line is the request we answer.
pub fn isAgentRequest(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), std.mem.trimEnd(u8, request_line, "\r\n"));
}

/// The head that carries the length: `OK <bytes>\n`.
pub fn replyHead(buf: []u8, len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "OK {d}\n", .{len});
}

/// The length the head carries, or null when it is not a length we serve.
pub fn parseHead(line: []const u8) ?usize {
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, trimmed, "OK ")) return null;
    const digits = std.mem.trim(u8, trimmed[3..], " ");
    if (digits.len == 0) return null;
    const len = std.fmt.parseInt(usize, digits, 10) catch return null;
    if (len == 0 or len > max_agent_bytes) return null;
    return len;
}

// ─── the listener ────────────────────────────────────────────────────────

const unix_af: u32 = 1;
const sock_stream: u32 = 1;
const backlog: u32 = 16;
const max_path_bytes: usize = 4096;

const Listener = struct {
    fd: linux.fd_t,
    key: []u8,
    allocator: std.mem.Allocator,
    agent: []const u8,
};

/// Bind the hand-off socket for a workspace, once. Safe to call on every
/// dispatch, so the listener exists before the guest's first dial.
pub fn ensure(allocator: std.mem.Allocator, layout: vm_client.Layout, agent: []const u8) void {
    if (agent.len == 0) return;
    // The socket lives in the workspace's directory, which the reconciler
    // creates when it boots the VM — but the listener has to be there
    // BEFORE the guest starts, so the directory is made here.
    vm_client.ensureWorkspaceDir(layout) catch return;
    var key_buf: [max_path_bytes]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}_{d}", .{ layout.vsock_sock, agent_port }) catch return;
    // A separate buffer: the copy must not alias its own source.
    var path_buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(key, &path_buf) orelse return;
    _ = linux.unlink(path_z);
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) {
        log("agent: no socket for {s}", .{key});
        return;
    }
    const fd: linux.fd_t = @intCast(rc);
    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    const name = key[0..@min(key.len, 107)];
    @memcpy(addr.path[0..name.len], name);
    const bind_errno = linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn)));
    if (bind_errno != .SUCCESS) {
        log("agent: cannot bind {s} (errno {d})", .{ key, @intFromEnum(bind_errno) });
        _ = linux.close(fd);
        return;
    }
    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) {
        log("agent: cannot listen on {s}", .{key});
        _ = linux.close(fd);
        return;
    }
    log("agent: serving {s} on {s}", .{ key, key });
    const listener = allocator.create(Listener) catch {
        _ = linux.close(fd);
        return;
    };
    listener.* = .{
        .fd = fd,
        .key = allocator.dupe(u8, key) catch {
            allocator.destroy(listener);
            _ = linux.close(fd);
            return;
        },
        .allocator = allocator,
        .agent = agent,
    };
    const thread = std.Thread.spawn(.{}, acceptLoop, .{listener}) catch {
        allocator.free(listener.key);
        allocator.destroy(listener);
        _ = linux.close(fd);
        return;
    };
    thread.detach();
}

fn acceptLoop(listener: *Listener) void {
    defer {
        _ = linux.close(listener.fd);
        listener.allocator.free(listener.key);
        listener.allocator.destroy(listener);
    }
    while (true) {
        const rc = linux.accept(listener.fd, null, null);
        if (linux.errno(rc) != .SUCCESS) continue;
        const fd: linux.fd_t = @intCast(rc);
        serve(listener, fd);
        _ = linux.close(fd);
    }
}

/// Answer one guest: the request line, then the head and the agent.
fn serve(listener: *Listener, fd: linux.fd_t) void {
    var buf: [max_request_bytes]u8 = undefined;
    var have: usize = 0;
    while (have < buf.len) {
        const n = linux.read(fd, buf[have..].ptr, buf.len - have);
        if (linux.errno(n) != .SUCCESS) return;
        const got: usize = @intCast(n);
        if (got == 0) return;
        have += got;
        if (std.mem.indexOfScalar(u8, buf[0..have], '\n') != null) break;
    }
    const end = std.mem.indexOfScalar(u8, buf[0..have], '\n') orelse return;
    if (!isAgentRequest(buf[0..end])) {
        log("agent: that is not the agent request", .{});
        return;
    }

    var head: [32]u8 = undefined;
    const head_text = replyHead(&head, listener.agent.len) catch return;
    if (!writeAll(fd, head_text)) return;
    if (!writeAll(fd, listener.agent)) return;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (linux.errno(n) != .SUCCESS) return false;
        const wrote: usize = @intCast(n);
        if (wrote == 0) return false;
        sent += wrote;
    }
    return true;
}

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn cstr(text: []const u8, buf: []u8) ?[*:0]const u8 {
    if (text.len + 1 > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return @ptrCast(buf.ptr);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the guest's request is the one we answer" {
    try testing.expect(isAgentRequest("AGENT\n"));
    try testing.expect(isAgentRequest("AGENT\r\n"));
    try testing.expect(!isAgentRequest("AGENTS\n"));
    try testing.expect(!isAgentRequest(""));
}

test "the head carries the length, and only a length we serve" {
    var buf: [32]u8 = undefined;
    const head = try replyHead(&buf, 4096);
    try testing.expectEqualStrings("OK 4096\n", head);
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096\n"));
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096"));
    try testing.expect(parseHead("OK 0\n") == null);
    try testing.expect(parseHead("OK not-a-number\n") == null);
    try testing.expect(parseHead("nope\n") == null);
}
