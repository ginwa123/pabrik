//! The host-side client for `pabrik-vmd`: connect to its unix socket, send one
//! framed request, decode one framed reply. Every method takes a workspace id
//! and that action's arguments — a path never crosses this boundary.

const std = @import("std");
const linux = std.os.linux;
const rpc = @import("rpc.zig");

pub const Error = error{
    SocketFailed,
    ConnectFailed,
    IoFailed,
    ProtocolViolation,
    Timeout,
    ServerFailure,
} || rpc.Error;

const unix_af: u32 = 1;
const sock_stream: u32 = 1;
const poll_slice_ms: i32 = 200;
/// Extra wall-clock beyond a request's own deadline before the client gives up
/// on a reply the daemon should already have produced.
pub const reply_guard_ms: u32 = 15_000;

pub const failure_message_max = 256;

pub const Failure = struct {
    code: rpc.FailureCode,
    message: [failure_message_max]u8 = [_]u8{0} ** failure_message_max,
    message_len: usize = 0,

    pub fn text(self: *const Failure) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const ExecOutcome = struct {
    code: i64,
    timed_out: bool,
    truncated: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: ExecOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const WorkspaceState = struct {
    state: []u8,
    pid: i64,

    pub fn deinit(self: WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
    }
};

pub const ExecRequest = struct {
    workspace_id: []const u8,
    argv: []const []const u8,
    cwd_rel: []const u8 = "",
    timeout_ms: u32 = rpc.default_timeout_ms,
    max_output_bytes: usize = rpc.default_max_output_bytes,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    next_id: i64 = 1,
    /// How long to wait for a reply beyond the request's own deadline. A
    /// preflight probe sets it low: a wedged daemon must not stall a boot.
    guard_ms: u32 = reply_guard_ms,
    /// The daemon's own reason for refusing the most recent call. Copied, not
    /// borrowed: the response it came from is released before the caller reads
    /// it, and a message that outlives its arena is a dangling read.
    last_failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Client {
        return .{ .allocator = allocator, .socket_path = socket_path };
    }

    pub fn ping(self: *Client) ![]u8 {
        var response = try self.call(.{ .action = .ping, .id = self.takeId() }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .pong => |p| self.allocator.dupe(u8, p.version),
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn status(self: *Client, workspace_id: []const u8) !WorkspaceState {
        var response = try self.call(.{
            .action = .status,
            .id = self.takeId(),
            .workspace_id = workspace_id,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .status => |s| .{
                .state = try self.allocator.dupe(u8, s.state),
                .pid = s.pid,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn stop(self: *Client, workspace_id: []const u8) !void {
        var response = try self.call(.{
            .action = .stop,
            .id = self.takeId(),
            .workspace_id = workspace_id,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn exec(self: *Client, request: ExecRequest) !ExecOutcome {
        const guard_ms = request.timeout_ms + self.guard_ms;
        var response = try self.call(.{
            .action = .exec,
            .id = self.takeId(),
            .workspace_id = request.workspace_id,
            .argv = request.argv,
            .cwd_rel = request.cwd_rel,
            .timeout_ms = request.timeout_ms,
            .max_output_bytes = request.max_output_bytes,
        }, guard_ms);
        defer response.deinit();

        const failure = switch (response.value) {
            .exec_result => |result| {
                const stdout = try self.allocator.dupe(u8, result.stdout);
                errdefer self.allocator.free(stdout);
                const stderr = try self.allocator.dupe(u8, result.stderr);
                return .{
                    .code = result.code,
                    .timed_out = result.timed_out,
                    .truncated = result.truncated,
                    .stdout = stdout,
                    .stderr = stderr,
                };
            },
            .failure => |f| f,
            else => return Error.ProtocolViolation,
        };
        self.record(failure);
        return Error.ServerFailure;
    }

    /// The daemon's reason for the last `ServerFailure`, or null when the last
    /// call did not reach a decision.
    pub fn lastFailure(self: *const Client) ?*const Failure {
        if (self.last_failure) |*f| return f;
        return null;
    }

    fn takeId(self: *Client) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn reportFailure(self: *Client, failure: anytype) Error {
        self.record(failure);
        return Error.ServerFailure;
    }

    fn record(self: *Client, failure: anytype) void {
        var recorded = Failure{ .code = failure.code };
        const len = @min(failure.message.len, failure_message_max);
        @memcpy(recorded.message[0..len], failure.message[0..len]);
        recorded.message_len = len;
        self.last_failure = recorded;
    }

    fn call(self: *Client, request: rpc.Request, guard_ms: u32) !rpc.OwnedResponse {
        const fd = try connectUnix(self.socket_path);
        defer _ = linux.close(fd);

        const payload = try rpc.encodeRequest(self.allocator, request);
        defer self.allocator.free(payload);
        try sendFrame(fd, payload);

        var header: [4]u8 = undefined;
        var waited_ms: u32 = 0;
        while (true) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, pfd.len, poll_slice_ms);
            if (linux.errno(rc) != .SUCCESS) return Error.IoFailed;
            if (rc > 0) break;
            waited_ms += @intCast(poll_slice_ms);
            if (waited_ms >= guard_ms) return Error.Timeout;
        }

        try readExact(fd, &header);
        const len = try rpc.framePayloadLen(header);
        const body = try self.allocator.alloc(u8, len);
        defer self.allocator.free(body);
        try readExact(fd, body);
        return try rpc.decodeResponse(self.allocator, body);
    }
};

// ─── raw unix-socket I/O ─────────────────────────────────────────────────

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn connectUnix(path: []const u8) !linux.fd_t {
    if (path.len + 1 > 108) return Error.ConnectFailed;
    const rc = linux.socket(unix_af, sock_stream, 0);
    if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) != .SUCCESS) {
        return Error.ConnectFailed;
    }
    return fd;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return Error.IoFailed;
        if (rc == 0) return Error.IoFailed;
        off += rc;
    }
}

fn readExact(fd: linux.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS) return Error.IoFailed;
        if (rc == 0) return Error.ProtocolViolation;
        off += rc;
    }
}

pub fn sendFrame(fd: linux.fd_t, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    rpc.frameHeader(payload.len, &header);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}
