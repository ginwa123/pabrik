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
/// A write is many guest round-trips and a walk is many frames, so both get a
/// longer deadline than a call that does no work in the guest.
pub const long_call_guard_ms: u32 = 120_000;

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
    last_error: []u8,
    /// The size the VM boots with. 0 when the daemon predates this field.
    vcpus: u32 = 0,
    mem_mib: u32 = 0,

    pub fn deinit(self: WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        allocator.free(self.last_error);
    }
};

pub const ExecRequest = struct {
    workspace_id: []const u8,
    argv: []const []const u8,
    cwd_rel: []const u8 = "",
    timeout_ms: u32 = rpc.default_timeout_ms,
    max_output_bytes: usize = rpc.default_max_output_bytes,
};

pub const SpawnRequest = struct {
    workspace_id: []const u8,
    argv: []const []const u8,
    cwd_rel: []const u8 = "",
    log_name: []const u8,
};

pub const SpawnOutcome = struct {
    pid: i64,
    log_path: []u8,

    pub fn deinit(self: SpawnOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.log_path);
    }
};

pub const JobProbe = struct {
    alive: bool,
    state: []u8,
    boot_pid: i64,

    pub fn deinit(self: JobProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
    }
};

pub const LogChunk = struct {
    bytes: []u8,
    size: i64,
    eof: bool,
    missing: bool,

    pub fn deinit(self: LogChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const FsStat = struct {
    kind: []u8,
    size: i64,
    missing: bool,

    pub fn deinit(self: FsStat, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
    }
};

pub const FsChunk = struct {
    bytes: []u8,
    size: i64,
    eof: bool,
    missing: bool,

    pub fn deinit(self: FsChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const WalkEntry = struct {
    path: []u8,
    kind: []u8,
};

/// A terminal the workspace's VM opened: the id the daemon minted (its position
/// in the guest's tty table) and the pid of the shell it runs there.
pub const TtyOpened = struct {
    tty_id: i64,
    pid: i64,
};

/// One piece of a terminal's output. An empty `data` with `eof` means the
/// terminal had nothing to say right now, which is not the same as an end.
pub const TtyChunk = struct {
    data: []u8,
    eof: bool,
    exited: bool,
    exit_code: i64,

    pub fn deinit(self: TtyChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const WalkResult = struct {
    entries: []WalkEntry,
    count: usize,
    truncated: bool,

    pub fn deinit(self: WalkResult, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.kind);
        }
        allocator.free(self.entries);
    }
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
                .last_error = try self.allocator.dupe(u8, s.last_error),
                .vcpus = s.vcpus,
                .mem_mib = s.mem_mib,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Change the size a workspace's VM runs with. Firecracker fixes vCPUs
    /// and RAM at boot, so the daemon stops the VM and starts it again: this
    /// call returns when the guest is up (or has failed, with its reason).
    pub fn resize(self: *Client, workspace_id: []const u8, vcpus: u32, mem_mib: u32) !WorkspaceState {
        var response = try self.call(.{
            .action = .resize,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .vcpus = vcpus,
            .mem_mib = mem_mib,
        }, long_call_guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .status => |s| .{
                .state = try self.allocator.dupe(u8, s.state),
                .pid = s.pid,
                .last_error = try self.allocator.dupe(u8, s.last_error),
                .vcpus = s.vcpus,
                .mem_mib = s.mem_mib,
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

    pub fn statFile(self: *Client, workspace_id: []const u8, path: []const u8) !FsStat {
        var response = try self.call(.{
            .action = .fs_stat,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .path = path,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .fs_stat => |st| .{
                .kind = try self.allocator.dupe(u8, st.kind),
                .size = st.size,
                .missing = st.missing,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn readFile(
        self: *Client,
        workspace_id: []const u8,
        path: []const u8,
        offset: i64,
        max_bytes: usize,
    ) !FsChunk {
        var response = try self.call(.{
            .action = .fs_read,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .path = path,
            .offset = offset,
            .max_bytes = max_bytes,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .fs_read => |chunk| .{
                .bytes = try self.allocator.dupe(u8, chunk.data),
                .size = chunk.size,
                .eof = chunk.eof,
                .missing = chunk.missing,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn removeFile(self: *Client, workspace_id: []const u8, path: []const u8) !void {
        var response = try self.call(.{
            .action = .fs_remove,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .path = path,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Write a whole file into the guest. The daemon pages it, so the body
    /// this call carries is the only ceiling.
    pub fn writeFile(
        self: *Client,
        workspace_id: []const u8,
        path: []const u8,
        data: []const u8,
        create_dirs: bool,
    ) !void {
        var response = try self.call(.{
            .action = .fs_write,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .path = path,
            .data = data,
            .create_dirs = create_dirs,
        }, long_call_guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// A bounded walk of the workspace, as the guest saw it.
    pub fn walk(
        self: *Client,
        workspace_id: []const u8,
        path: []const u8,
        max_depth: u32,
        max_entries: usize,
    ) !WalkResult {
        var response = try self.call(.{
            .action = .fs_walk,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .path = path,
            .max_depth = max_depth,
            .max_entries = max_entries,
        }, long_call_guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .fs_walk => |walked| blk: {
                const entries = try self.allocator.alloc(WalkEntry, walked.entries.len);
                var filled: usize = 0;
                errdefer {
                    for (entries[0..filled]) |entry| {
                        self.allocator.free(entry.path);
                        self.allocator.free(entry.kind);
                    }
                    self.allocator.free(entries);
                }
                for (walked.entries, 0..) |entry, i| {
                    entries[i] = .{
                        .path = try self.allocator.dupe(u8, entry.path),
                        .kind = try self.allocator.dupe(u8, entry.kind),
                    };
                    filled = i + 1;
                }
                break :blk .{
                    .entries = entries,
                    .count = walked.count,
                    .truncated = walked.truncated,
                };
            },
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

    /// Start a detached command in the workspace's VM. The pid that comes back
    /// is the GUEST's, and `log_path` is a path inside the guest.
    pub fn spawn(self: *Client, request: SpawnRequest) !SpawnOutcome {
        var response = try self.call(.{
            .action = .spawn,
            .id = self.takeId(),
            .workspace_id = request.workspace_id,
            .argv = request.argv,
            .cwd_rel = request.cwd_rel,
            .log_name = request.log_name,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .spawned => |s| .{
                .pid = s.pid,
                .log_path = try self.allocator.dupe(u8, s.log_path),
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Whether a detached job is still there, and which boot of the VM answered.
    pub fn probe(self: *Client, workspace_id: []const u8, pid: i64) !JobProbe {
        var response = try self.call(.{
            .action = .probe,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .pid = pid,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .probe => |p| .{
                .alive = p.alive,
                .state = try self.allocator.dupe(u8, p.state),
                .boot_pid = p.boot_pid,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn signal(self: *Client, workspace_id: []const u8, pid: i64, sig: i64) !void {
        var response = try self.call(.{
            .action = .signal,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .pid = pid,
            .sig = sig,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Bytes of a job's log from `offset`, read through the guest.
    pub fn readLog(
        self: *Client,
        workspace_id: []const u8,
        log_name: []const u8,
        offset: i64,
        max_bytes: usize,
    ) !LogChunk {
        var response = try self.call(.{
            .action = .log,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .log_name = log_name,
            .offset = offset,
            .max_bytes = max_bytes,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .log_chunk => |c| .{
                .bytes = try self.allocator.dupe(u8, c.data),
                .size = c.size,
                .eof = c.eof,
                .missing = c.missing,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Open a terminal inside the workspace's VM. `cwd_rel` is workspace
    /// relative and the daemon joins it under the guest's `/workspace`.
    pub fn ttyOpen(
        self: *Client,
        workspace_id: []const u8,
        cwd_rel: []const u8,
        cols: u16,
        rows: u16,
    ) !TtyOpened {
        var response = try self.call(.{
            .action = .tty,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .tty_op = .open,
            .cwd_rel = cwd_rel,
            .cols = cols,
            .rows = rows,
        }, long_call_guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .tty => |t| blk: {
                if (t.tty_id < 0) break :blk Error.ProtocolViolation;
                break :blk .{ .tty_id = t.tty_id, .pid = t.pid };
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Whatever the terminal has produced since the last read.
    pub fn ttyRead(
        self: *Client,
        workspace_id: []const u8,
        tty_id: i64,
        max_bytes: usize,
    ) !TtyChunk {
        var response = try self.call(.{
            .action = .tty,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .tty_op = .read,
            .tty_id = tty_id,
            .max_bytes = max_bytes,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .tty => |t| .{
                .data = try self.allocator.dupe(u8, t.data),
                .eof = t.eof,
                .exited = t.exited,
                .exit_code = t.exit_code,
            },
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Keystrokes into the terminal. Returns how many bytes the guest took.
    pub fn ttyWrite(
        self: *Client,
        workspace_id: []const u8,
        tty_id: i64,
        data: []const u8,
    ) !usize {
        var response = try self.call(.{
            .action = .tty,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .tty_op = .write,
            .tty_id = tty_id,
            .data = data,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .tty => |t| if (t.bytes < 0) self.reportFailure(.{
                .code = .bad_request,
                .message = "the terminal refused the input",
            }) else @as(usize, @intCast(t.bytes)),
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    pub fn ttyResize(
        self: *Client,
        workspace_id: []const u8,
        tty_id: i64,
        cols: u16,
        rows: u16,
    ) !void {
        var response = try self.call(.{
            .action = .tty,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .tty_op = .resize,
            .tty_id = tty_id,
            .cols = cols,
            .rows = rows,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
    }

    /// Kill the terminal's shell and forget it.
    pub fn ttyClose(self: *Client, workspace_id: []const u8, tty_id: i64) !void {
        var response = try self.call(.{
            .action = .tty,
            .id = self.takeId(),
            .workspace_id = workspace_id,
            .tty_op = .close,
            .tty_id = tty_id,
        }, self.guard_ms);
        defer response.deinit();
        return switch (response.value) {
            .ack => {},
            .failure => |f| self.reportFailure(f),
            else => Error.ProtocolViolation,
        };
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
    // No pabrik-vmd exists off Linux (the VM runtime is Linux-only) and the raw
    // `std.os.linux` syscalls below are meaningless on another kernel: issuing
    // them there is signal SYS, not a failed connect.
    if (comptime @import("builtin").os.tag != .linux) return Error.ConnectFailed;
    if (path.len + 1 > 108) return Error.ConnectFailed;
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
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
