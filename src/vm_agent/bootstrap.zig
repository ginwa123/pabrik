//! The guest's bootstrap: the `/init` that asks the host for the current agent
//! (so a workspace's disk never carries one) and execs it, falling back to the
//! agent on the disk (`/init.agent`).

const std = @import("std");
const linux = std.os.linux;
const vsock = @import("vsock.zig");
const wire = @import("vm_wire");

/// Where the fetched agent is written, and the name it is exec'd under. The
/// DISK's root, not /tmp: a guest may mount /tmp noexec.
const agent_path = "/pabrik-vm-agent";

/// The agent that the image also carries, used when the host does not answer.
const on_disk_agent = "/init.agent";

/// How long the hand-off may take before the disk's agent is used instead.
const handoff_timeout_ms: u64 = 20_000;

const max_head_bytes: usize = 64;
const max_agent_bytes: usize = 64 * 1024 * 1024;

pub fn main() !void {
    // The host first: the current agent, with every action it knows.
    if (fetchAndExec()) return;
    say("bootstrap: the host has no agent for me; running the one on this disk", .{});
    // The disk's agent: the one the image carried when this disk was made.
    execOnDisk();
}

/// One line to the guest's console — the operator's only window into it.
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, text.ptr, text.len);
    _ = linux.write(1, "\n".ptr, 1);
}

fn fetchAndExec() bool {
    const fd = connectVsock(wire.agent_service_port) orelse return false;
    defer _ = linux.close(fd);
    say("bootstrap: connected to the host", .{});
    if (!writeAll(fd, "AGENT\n")) {
        say("bootstrap: cannot ask for the agent", .{});
        return false;
    }

    var head: [max_head_bytes]u8 = undefined;
    var have: usize = 0;
    const deadline = now_ms() + handoff_timeout_ms;
    while (have < head.len) {
        if (now_ms() > deadline) return false;
        const n = linux.read(fd, head[have..].ptr, head.len - have);
        if (linux.errno(n) != .SUCCESS) return false;
        const got: usize = @intCast(n);
        if (got == 0) return false;
        have += got;
        if (std.mem.indexOfScalar(u8, head[0..have], '\n') != null) break;
    }
    // The head ends at its newline: the bytes after it are the agent.
    const end = std.mem.indexOfScalar(u8, head[0..have], '\n') orelse {
        say("bootstrap: the host sent no head", .{});
        return false;
    };
    const len = parseHead(head[0..end]) orelse {
        say("bootstrap: the host's head is '{s}'", .{head[0..end]});
        return false;
    };
    say("bootstrap: the host has the agent", .{});

    const out = linux.open(agent_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o755);
    if (linux.errno(out) != .SUCCESS) return false;
    const out_fd: linux.fd_t = @intCast(out);

    var left: usize = len;
    var buf: [64 * 1024]u8 = undefined;
    // Whatever came with the head is the start of the agent.
    const carried = have - (end + 1);
    var written: usize = 0;
    if (carried > 0) {
        const take = @min(carried, left);
        if (!writeAll(out_fd, head[end + 1 ..][0..take])) return false;
        left -= take;
        written += take;
    }
    while (left > 0) {
        if (now_ms() > deadline) return false;
        const want = @min(left, buf.len);
        const n = linux.read(fd, buf[0..want].ptr, want);
        if (linux.errno(n) != .SUCCESS) return false;
        const got: usize = @intCast(n);
        if (got == 0) return false;
        if (!writeAll(out_fd, buf[0..got])) return false;
        left -= got;
        written += got;
    }
    say("bootstrap: wrote {d} bytes of the agent", .{written});
    // The file must be closed before it is exec'd: a file still open for
    // writing is ETXTBSY.
    _ = linux.close(out_fd);
    exec(agent_path);
    return true;
}

/// The length the host's head carries, or null when it is not one we accept.
pub fn parseHead(line: []const u8) ?usize {
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, trimmed, "OK ")) return null;
    const digits = std.mem.trim(u8, trimmed[3..], " ");
    if (digits.len == 0) return null;
    const len = std.fmt.parseInt(usize, digits, 10) catch return null;
    if (len == 0 or len > max_agent_bytes) return null;
    return len;
}

fn connectVsock(port: u32) ?linux.fd_t {
    var attempt: usize = 0;
    var last_errno: linux.E = .SUCCESS;
    while (attempt < vsock.dial_attempts) : (attempt += 1) {
        const err = switch (vsock.connect(port, wire.cid_host)) {
            .fd => |fd| return fd,
            .errno => |e| e,
        };
        last_errno = err;
        _ = linux.nanosleep(&.{ .sec = 0, .nsec = vsock.dial_retry_ms * std.time.ns_per_ms }, null);
    }
    say("bootstrap: no agent from the host (errno {d})", .{@intFromEnum(last_errno)});
    return null;
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

/// Replace this process with the agent. Never returns.
fn exec(path: []const u8) noreturn {
    var path_buf: [256]u8 = undefined;
    if (path.len + 1 > path_buf.len) spin();
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const argv = [_:null]?[*:0]const u8{ @ptrCast(path_buf[0..].ptr) };
    const envp = [_:null]?[*:0]const u8{
        "PATH=/bin:/usr/bin:/sbin:/usr/sbin",
        "HOME=/root",
        "LANG=C",
    };
    const exec_rc = linux.execve(@ptrCast(path_buf[0..].ptr), &argv, &envp);
    say("bootstrap: the agent did not start (errno {d})", .{@intFromEnum(linux.errno(exec_rc))});
    spin();
}

fn execOnDisk() noreturn {
    exec(on_disk_agent);
}

/// Nothing left to try: the guest must not exit (the kernel would panic).
fn spin() noreturn {
    while (true) {
        _ = linux.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
    }
}

fn now_ms() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "the host's head carries a length we accept" {
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096\n"));
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096"));
    try testing.expect(parseHead("OK 0\n") == null);
    try testing.expect(parseHead("nope\n") == null);
}
