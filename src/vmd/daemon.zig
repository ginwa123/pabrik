//! `pabrik-vmd`'s socket front end: it authenticates each caller by the
//! credential the kernel reports, then runs the requested action against the
//! workspace's VM. The VM's pid is on disk, so a restarted daemon adopts it.

const std = @import("std");
const linux = std.os.linux;
const rpc = @import("rpc.zig");
const policy = @import("policy.zig");
const vm_client = @import("vm_client.zig");

pub const Error = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    PeerUnavailable,
} || rpc.Error;

const unix_af: u32 = 1;
const sock_stream: u32 = 1;
const backlog: u32 = 16;

const lock_ex: i32 = 2;

pub const Config = struct {
    socket_path: []const u8,
    base_image: []const u8,
    kernel: []const u8,
    root: []const u8,
    fc_bin: []const u8 = "firecracker",
    mem_mib: u32 = vm_client.default_mem_mib,
    /// The uid allowed to call this daemon. Null means "the daemon's own uid",
    /// which is the single-user case; a daemon started as root sets it to the
    /// server's uid.
    allowed_uid: ?u32 = null,
};

pub const State = struct {
    label: []const u8,
    pid: i64,
};

// ─── the manager: workspace id in, derived paths out ────────────────────

pub const Manager = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Manager {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn expectedUid(self: *const Manager) u32 {
        return self.config.allowed_uid orelse linux.getuid();
    }

    /// The only place this daemon decides a path, and it only takes the id.
    pub fn layoutFor(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !vm_client.Layout {
        return vm_client.layoutFor(allocator, self.spec(workspace_id));
    }

    fn spec(self: *const Manager, workspace_id: []const u8) vm_client.Spec {
        return .{
            .workspace_id = workspace_id,
            .base_image = self.config.base_image,
            .kernel = self.config.kernel,
            .fc_bin = self.config.fc_bin,
            .root = self.config.root,
            .mem_mib = self.config.mem_mib,
        };
    }

    /// The layout of a workspace whose VM is up, booting it when it is not.
    /// The caller owns the returned layout.
    pub fn ensure(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !vm_client.Layout {
        const layout = try self.layoutFor(allocator, workspace_id);
        errdefer layout.deinit(allocator);
        try vm_client.ensureWorkspaceDir(layout);

        if (!vm_client.vmmAlive(layout)) {
            // Two callers can arrive for a workspace nobody has booted. The
            // lock serialises them; without it both would bind one disk.
            const lock = try lockWorkspace(layout.dir);
            defer _ = linux.close(lock);
            if (!vm_client.vmmAlive(layout)) {
                var vm = try vm_client.boot(allocator, self.spec(workspace_id));
                vm.deinit();
            }
        }

        try vm_client.waitReady(layout, vm_client.boot_timeout_ms);
        return layout;
    }

    pub fn state(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !State {
        const layout = try self.layoutFor(allocator, workspace_id);
        defer layout.deinit(allocator);
        if (!vm_client.vmmAlive(layout)) return .{ .label = "absent", .pid = 0 };
        return .{ .label = "ready", .pid = @intCast(vm_client.readPid(layout) orelse 0) };
    }

    /// Ends the workspace's VM. `false` means there was nothing running, which
    /// is an answer, not a failure.
    pub fn stopWorkspace(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) bool {
        const layout = self.layoutFor(allocator, workspace_id) catch return false;
        defer layout.deinit(allocator);
        return vm_client.stopRecorded(layout);
    }
};

/// An exclusive `flock` on the workspace directory itself — no lock file to
/// create, and the kernel hands it back when the fd closes.
fn lockWorkspace(dir: []const u8) !linux.fd_t {
    var buf: [4096]u8 = undefined;
    if (dir.len >= buf.len) return Error.BindFailed;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    const rc = linux.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return Error.BindFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.flock(fd, lock_ex)) != .SUCCESS) return Error.BindFailed;
    return fd;
}

// ─── peer credentials ───────────────────────────────────────────────────

const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

pub fn peerOf(fd: linux.fd_t) !policy.Peer {
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    if (linux.errno(rc) != .SUCCESS) return Error.PeerUnavailable;
    if (len != @sizeOf(Ucred)) return Error.PeerUnavailable;
    return .{ .pid = cred.pid, .uid = cred.uid, .gid = cred.gid };
}

// ─── shutdown ────────────────────────────────────────────────────────────

var stopping = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .seq_cst);
}

/// Without SA_RESTART, a signal makes the blocked `accept` return EINTR, which
/// is how the loop notices. The flag is set from the handler, never cleared.
pub fn installSignalHandlers() void {
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
}

// ─── the socket ──────────────────────────────────────────────────────────

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn unlinkIfExists(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlink(@ptrCast(&buf));
}

fn listenUnix(path: []const u8) !linux.fd_t {
    if (path.len + 1 > 108) return Error.BindFailed;
    const rc = linux.socket(unix_af, sock_stream, 0);
    if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) != .SUCCESS) {
        return Error.BindFailed;
    }
    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) return Error.ListenFailed;
    return fd;
}

/// The accept loop. One thread per connection, so a long build in one
/// workspace cannot stall another's `ls`; the only shared state is on disk.
pub fn serve(allocator: std.mem.Allocator, config: Config) !void {
    installSignalHandlers();
    unlinkIfExists(config.socket_path);
    const fd = try listenUnix(config.socket_path);
    defer {
        _ = linux.close(fd);
        unlinkIfExists(config.socket_path);
    }

    const manager = Manager.init(allocator, config);
    while (!stopping.load(.seq_cst)) {
        const rc = linux.accept(fd, null, null);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return Error.AcceptFailed;
        const conn: linux.fd_t = @intCast(rc);
        const thread = std.Thread.spawn(.{}, serveConnection, .{ manager, conn }) catch {
            _ = linux.close(conn);
            continue;
        };
        thread.detach();
    }
}

fn serveConnection(manager: Manager, conn: linux.fd_t) void {
    defer _ = linux.close(conn);

    const peer = peerOf(conn) catch {
        log("peer credential unavailable; refusing the connection", .{});
        return;
    };
    const expected = manager.expectedUid();
    if (!policy.peerAllowed(peer, expected)) {
        log("refused uid={d} pid={d} (expected uid={d})", .{ peer.uid, peer.pid, expected });
        reply(conn, manager.allocator, rpc.encodeFailure(
            manager.allocator,
            0,
            .forbidden_peer,
            "this daemon only accepts connections from its own uid",
        ) catch return);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(manager.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = readFrame(conn, aa) catch |err| {
        log("could not read a request frame: {s}", .{@errorName(err)});
        return;
    };

    var request = rpc.decodeRequest(aa, body) catch |err| {
        log("refused a malformed request: {s}", .{@errorName(err)});
        reply(conn, aa, rpc.encodeFailure(aa, 0, .bad_request, @errorName(err)) catch return);
        return;
    };
    defer request.deinit();

    const payload = dispatch(manager, aa, request.value) catch |err| blk: {
        log("request failed: {s}", .{@errorName(err)});
        break :blk rpc.encodeFailure(aa, request.value.id, .internal, @errorName(err)) catch return;
    };
    reply(conn, aa, payload);
}

fn dispatch(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    switch (request.action) {
        .ping => return rpc.encodePong(allocator, request.id),
        .status => {
            const state = try manager.state(allocator, request.workspace_id);
            return rpc.encodeStatus(allocator, request.id, state.label, state.pid);
        },
        .stop => {
            _ = manager.stopWorkspace(allocator, request.workspace_id);
            return rpc.encodeAck(allocator, request.id);
        },
        .exec => {
            const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
                log("workspace {s} has no usable VM: {s}", .{ request.workspace_id, @errorName(err) });
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            const cwd = try policy.guestCwd(allocator, policy.guest_root, request.cwd_rel);
            const result = vm_client.exec(allocator, layout, .{
                .argv = request.argv,
                .cwd = cwd,
                .timeout_ms = request.timeout_ms,
                .max_output_bytes = request.max_output_bytes,
            }) catch |err| {
                log("exec in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            return rpc.encodeExecResult(allocator, request.id, .{
                .code = result.code,
                .timed_out = result.timed_out,
                .truncated = result.truncated,
                .stdout = result.stdout,
                .stderr = result.stderr,
            });
        },
    }
}

fn reply(fd: linux.fd_t, allocator: std.mem.Allocator, payload: []u8) void {
    defer allocator.free(payload);
    var header: [4]u8 = undefined;
    rpc.frameHeader(payload.len, &header);
    writeAll(fd, &header);
    writeAll(fd, payload);
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
}

fn readFrame(fd: linux.fd_t, allocator: std.mem.Allocator) ![]u8 {
    var header: [4]u8 = undefined;
    try readExact(fd, &header);
    const len = try rpc.framePayloadLen(header);
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try readExact(fd, body);
    return body;
}

fn readExact(fd: linux.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS) return rpc.Error.BadRequest;
        if (rc == 0) return rpc.Error.BadRequest;
        off += rc;
    }
}

/// The daemon's stderr is a log, never a protocol stream.
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "pabrik-vmd: " ++ fmt ++ "\n", args) catch return;
    writeAll(2, text);
}
