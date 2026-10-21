//! `pabrik-vmd`'s socket front end: it authenticates each caller by the
//! credential the kernel reports, then runs the requested action against the
//! workspace's VM. The VM's pid is on disk, so a restarted daemon adopts it.

const std = @import("std");
const linux = std.os.linux;
const rpc = @import("rpc.zig");
const policy = @import("policy.zig");
const vm_client = @import("vm_client.zig");
const reconciler_mod = @import("reconciler.zig");
const egress_proxy = @import("egress_proxy.zig");
const agent_service = @import("agent_service.zig");
const proxy_rpc = @import("proxy_rpc.zig");

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
    /// 0 turns the background sweep off.
    sweep_interval_ms: u32 = reconciler_mod.default_sweep_interval_ms,
    /// The first retry delay after a failed attempt; doubles up to a minute.
    backoff_base_ms: i64 = reconciler_mod.default_backoff_base_ms,
    /// The host's own TCP ports, refused to every workspace's egress whatever
    /// address is used to reach them.
    host_listeners: []const u16 = &.{8081},
    /// The `pabrik-vm-agent` this host serves to a guest's bootstrap. Null
    /// means the daemon serves none, and every guest runs the agent that is
    /// on its own disk.
    agent_path: ?[]const u8 = null,
};

pub const State = struct {
    label: []const u8,
    pid: i64,
    last_error: []const u8 = "",

    pub fn deinit(self: State, allocator: std.mem.Allocator) void {
        allocator.free(self.last_error);
    }
};

// ─── the manager: workspace id in, derived paths out ────────────────────

pub const Manager = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// The current agent, served to every guest's bootstrap. Empty when the
    /// daemon was started without one.
    agent: []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Manager {
        return .{
            .allocator = allocator,
            .config = config,
            .agent = readAgent(allocator, config.agent_path),
        };
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

    /// Every daemon call goes through this one state machine.
    fn reconciler(self: *const Manager) reconciler_mod.Reconciler {
        return reconciler_mod.Reconciler.init(self.allocator, .{
            .root = self.config.root,
            .base_image = self.config.base_image,
            .kernel = self.config.kernel,
            .fc_bin = self.config.fc_bin,
            .mem_mib = self.config.mem_mib,
            .backoff_base_ms = self.config.backoff_base_ms,
        });
    }

    /// The workspace's layout, booting its VM only when the reconciler says so.
    pub fn ensure(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !vm_client.Layout {
        // The listeners are bound BEFORE the VM boots: a guest's bootstrap
        // dials for the agent the moment the kernel starts, and the request
        // below only returns once the guest is up (or has failed).
        const layout = try self.layoutFor(allocator, workspace_id);
        egress_proxy.ensure(self.allocator, layout, self.config.host_listeners);
        agent_service.ensure(self.allocator, layout, self.agent);
        const record = try self.reconciler().request(allocator, workspace_id);
        defer record.deinit(allocator);
        if (record.state != .ready) {
            log("workspace {s} is {s}: {s}", .{ workspace_id, record.state.name(), record.last_error });
            return error.VmUnavailable;
        }
        return layout;
    }

    pub fn state(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !State {
        const record = try self.reconciler().observe(allocator, workspace_id);
        defer record.deinit(allocator);
        return .{
            .label = record.state.name(),
            .pid = if (record.state == .ready) record.pid else 0,
            .last_error = try allocator.dupe(u8, record.last_error),
        };
    }

    /// Every workspace VM this daemon owns, stopped. A manager that is going
    /// down takes the VMs with it.
    pub fn stopAll(self: *const Manager, allocator: std.mem.Allocator) !u32 {
        return self.reconciler().stopAll(allocator);
    }

    /// `false` means nothing was running, or that a VMM this daemon cannot
    /// account for still owns the workspace.
    pub fn stopWorkspace(self: *const Manager, allocator: std.mem.Allocator, workspace_id: []const u8) bool {
        if (self.layoutFor(allocator, workspace_id)) |layout| {
            egress_proxy.release(layout);
            layout.deinit(allocator);
        } else |_| {}
        const record = self.reconciler().stop(allocator, workspace_id) catch return false;
        defer record.deinit(allocator);
        return record.state == .absent;
    }
};

/// The agent's bytes, or none when there is no agent to serve.
fn readAgent(allocator: std.mem.Allocator, path: ?[]const u8) []const u8 {
    const file = path orelse return &.{};
    const bytes = egress_proxy.readFileAlloc(allocator, file, agent_service.max_agent_bytes) orelse {
        log("agent: cannot read {s}", .{file});
        return &.{};
    };
    log("agent: serving {s} ({d} bytes) to every guest's bootstrap", .{ file, bytes.len });
    return bytes;
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
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
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
    if (config.sweep_interval_ms > 0) {
        const sweeper = std.Thread.spawn(.{}, sweepLoop, .{manager}) catch |err| blk: {
            log("no background sweep: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (sweeper) |thread| thread.detach();
    }
    while (!stopping.load(.seq_cst)) {
        const rc = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
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

    const stopped = manager.stopAll(allocator) catch |err| blk: {
        log("shutdown: could not stop every workspace VM: {s}", .{@errorName(err)});
        break :blk 0;
    };
    if (stopped > 0) log("shutdown: stopped {d} workspace VM(s)", .{stopped});
}

/// The reconciler's clock: one pass over every workspace per interval. It
/// never waits on a workspace somebody is booting, because its lock is a try.
fn sweepLoop(manager: Manager) void {
    var arena = std.heap.ArenaAllocator.init(manager.allocator);
    while (!stopping.load(.seq_cst)) {
        defer _ = arena.reset(.retain_capacity);
        const report = manager.reconciler().sweep(arena.allocator()) catch |err| {
            log("sweep failed: {s}", .{@errorName(err)});
            sleepMs(manager.config.sweep_interval_ms);
            continue;
        };
        if (report.workspaces > 0) {
            log("swept {d} workspace(s): ready={d} starting={d} absent={d} failed={d}", .{
                report.workspaces, report.ready, report.starting, report.absent, report.failed,
            });
        }
        sleepMs(manager.config.sweep_interval_ms);
    }
}

fn sleepMs(ms: u32) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
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

    // The proxy's frames carry their own types, so they are answered before
    // `rpc.decodeRequest` ever sees an action it does not know.
    if (proxy_rpc.isProxyFrame(body)) {
        const payload = proxy_rpc.serve(manager, aa, body) catch |err| blk: {
            log("proxy request failed: {s}", .{@errorName(err)});
            break :blk rpc.encodeFailure(aa, 0, .internal, @errorName(err)) catch return;
        };
        reply(conn, aa, payload);
        return;
    }

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
            defer state.deinit(allocator);
            return rpc.encodeStatus(allocator, request.id, state.label, state.pid, state.last_error);
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
        .spawn => return dispatchSpawn(manager, allocator, request),
        .probe => return dispatchProbe(manager, allocator, request),
        .signal => return dispatchSignal(manager, allocator, request),
        .log => return dispatchLog(manager, allocator, request),
        .fs_stat => return dispatchFsStat(manager, allocator, request),
        .fs_read => return dispatchFsRead(manager, allocator, request),
        .fs_remove => return dispatchFsRemove(manager, allocator, request),
        .fs_write => return dispatchFsWrite(manager, allocator, request),
        .fs_walk => return dispatchFsWalk(manager, allocator, request),
        .tty => return dispatchTty(manager, allocator, request),
    }
}

/// A terminal RPC. `open` asks the AGENT to fork the guest process that will
/// own the pty; every other op talks to that process on the port it bound, so
/// a terminal never queues behind a long `exec` on the agent's own port.
fn dispatchTty(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a terminal: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    switch (request.tty_op) {
        .open => {
            const cwd = policy.guestCwd(allocator, policy.guest_root, request.cwd_rel) catch |err| {
                return rpc.encodeFailure(allocator, request.id, .bad_request, @errorName(err));
            };
            var refusal = vm_client.TtyRefusal{};
            const opened = vm_client.ttyOpen(allocator, layout, request.cols, request.rows, cwd, &refusal) catch |err| {
                if (refusal.len > 0) {
                    log("terminal open in workspace {s} failed: {s} ({s})", .{ request.workspace_id, @errorName(err), refusal.text() });
                } else {
                    log("terminal open in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                }
                if (err == vm_client.Error.TtyFailed) {
                    const reason = if (refusal.len > 0) refusal.text() else "the guest refused to open a terminal";
                    return rpc.encodeFailure(allocator, request.id, .bad_request, reason);
                }
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            return rpc.encodeTtyReply(allocator, request.id, .{
                .op = "open",
                .tty_id = opened.tty_id,
                .pid = opened.pid,
                .data = "",
                .eof = false,
                .exited = false,
                .exit_code = 0,
                .bytes = 0,
                .message = "",
            });
        },
        .read => {
            const chunk = vm_client.ttyRead(allocator, layout, request.tty_id, request.max_bytes) catch |err| {
                log("terminal read in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            defer chunk.deinit(allocator);
            return rpc.encodeTtyReply(allocator, request.id, .{
                .op = "read",
                .tty_id = request.tty_id,
                .pid = 0,
                .data = chunk.data,
                .eof = chunk.eof,
                .exited = chunk.exited,
                .exit_code = chunk.exit_code,
                .bytes = @intCast(chunk.data.len),
                .message = "",
            });
        },
        .write => {
            const written = vm_client.ttyWrite(allocator, layout, request.tty_id, request.data) catch |err| {
                log("terminal write in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                if (err == vm_client.Error.TtyGone) {
                    return rpc.encodeFailure(allocator, request.id, .not_ready, "the terminal has exited");
                }
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            return rpc.encodeTtyReply(allocator, request.id, .{
                .op = "write",
                .tty_id = request.tty_id,
                .pid = 0,
                .data = "",
                .eof = false,
                .exited = false,
                .exit_code = 0,
                .bytes = @intCast(written),
                .message = "",
            });
        },
        .resize => {
            vm_client.ttyResize(allocator, layout, request.tty_id, request.cols, request.rows) catch |err| {
                log("terminal resize in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            return rpc.encodeAck(allocator, request.id);
        },
        .close => {
            vm_client.ttyClose(allocator, layout, request.tty_id) catch |err| {
                log("terminal close in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            };
            return rpc.encodeAck(allocator, request.id);
        },
    }
}

/// A file RPC runs against a READY VM, like `exec`: the caller asked for a
/// tool's worth of work, so a cold workspace boots rather than refuses.
fn dispatchFsStat(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a stat: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const stat = vm_client.statFile(allocator, layout, request.path) catch |err| {
        log("stat in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    return rpc.encodeFsStat(allocator, request.id, .{
        .kind = @tagName(stat.kind),
        .size = stat.size,
        .missing = stat.missing,
    });
}

/// The bytes come from the guest; the host never opens the file. That is the
/// whole point of the op, so there is no host fallback to reach for.
fn dispatchFsRead(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a read: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const chunk = vm_client.readFile(allocator, layout, request.path, request.offset, request.max_bytes) catch |err| {
        log("read in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    defer chunk.deinit(allocator);
    return rpc.encodeFsRead(allocator, request.id, .{
        .data = chunk.data,
        .size = chunk.size,
        .eof = chunk.eof,
        .missing = chunk.missing,
    });
}

fn dispatchFsRemove(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a remove: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const removed = vm_client.removeFile(allocator, layout, request.path) catch |err| {
        log("remove in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    if (!removed) return rpc.encodeFailure(allocator, request.id, .bad_request, "no such file");
    return rpc.encodeAck(allocator, request.id);
}

/// The bytes come from the caller and land in the guest. The daemon opens
/// nothing: it is the guest that creates and extends the file.
fn dispatchFsWrite(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a write: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    _ = vm_client.writeFile(allocator, layout, request.path, request.data, request.create_dirs) catch |err| {
        log("write in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        // A write the GUEST refused is the caller's own request; anything else
        // is the workspace not being usable. They are not the same failure.
        if (err == vm_client.Error.WriteFailed) {
            return rpc.encodeFailure(allocator, request.id, .bad_request, @errorName(err));
        }
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    return rpc.encodeAck(allocator, request.id);
}

/// A walk's entries cross as the guest reported them — relative paths and a
/// kind — and the daemon adds nothing to them.
fn dispatchFsWalk(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a walk: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const walked = vm_client.walk(allocator, layout, request.path, request.max_depth, request.max_entries) catch |err| {
        log("walk in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        if (err == vm_client.Error.WalkNotADirectory) {
            return rpc.encodeFailure(allocator, request.id, .bad_request, @errorName(err));
        }
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    defer walked.deinit(allocator);
    const entries = try allocator.alloc(rpc.WalkEntry, walked.entries.len);
    for (walked.entries, 0..) |entry, i| {
        entries[i] = .{ .path = entry.path, .kind = entry.kind };
    }
    return rpc.encodeFsWalk(allocator, request.id, .{
        .entries = entries,
        .count = walked.count,
        .truncated = walked.truncated,
    });
}

/// A detached job runs in the workspace's VM, so the pid the caller gets back
/// is the guest's — and the log it writes is a guest path.
fn dispatchSpawn(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = manager.ensure(allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no usable VM for a job: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const cwd = try policy.guestCwd(allocator, policy.guest_root, request.cwd_rel);
    const log_path = policy.guestJobLogPath(allocator, request.log_name) catch |err| {
        return rpc.encodeFailure(allocator, request.id, .bad_request, @errorName(err));
    };
    const spawned = vm_client.spawn(allocator, layout, .{
        .argv = request.argv,
        .cwd = cwd,
        .log_path = log_path,
    }) catch |err| {
        log("spawn in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    return rpc.encodeSpawned(allocator, request.id, spawned.pid, log_path);
}

/// `observe`, never `ensure`: a probe must not BOOT the VM it is asking about,
/// or a job from before a stop would be reported as merely exited.
fn dispatchProbe(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const state = try manager.state(allocator, request.workspace_id);
    defer state.deinit(allocator);
    if (!std.mem.eql(u8, state.label, "ready")) {
        return rpc.encodeProbe(allocator, request.id, false, state.label, 0);
    }
    const layout = readyLayout(manager, allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no layout: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeProbe(allocator, request.id, false, "unavailable", 0);
    };
    const probed = vm_client.probe(allocator, layout, request.pid) catch |err| {
        log("probe in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        // A guest that will not answer is not evidence that the job lives.
        return rpc.encodeProbe(allocator, request.id, false, "unresponsive", state.pid);
    };
    return rpc.encodeProbe(allocator, request.id, probed.alive, state.label, state.pid);
}

/// The layout of a VM that is ALREADY running. Booting one to answer a question
/// about a job that VM no longer holds would be a side effect, not an answer.
fn readyLayout(manager: Manager, allocator: std.mem.Allocator, workspace_id: []const u8) !vm_client.Layout {
    const state = try manager.state(allocator, workspace_id);
    defer state.deinit(allocator);
    if (!std.mem.eql(u8, state.label, "ready")) return error.VmNotRunning;
    return manager.layoutFor(allocator, workspace_id);
}

fn dispatchSignal(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = readyLayout(manager, allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no running VM to signal: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    _ = vm_client.signal(allocator, layout, request.pid, request.sig) catch |err| {
        log("signal in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    return rpc.encodeAck(allocator, request.id);
}

/// Read a job's log through the guest, filling the caller's budget from as many
/// guest chunks as it takes. The host never opens the file.
fn dispatchLog(manager: Manager, allocator: std.mem.Allocator, request: rpc.Request) ![]u8 {
    const layout = readyLayout(manager, allocator, request.workspace_id) catch |err| {
        log("workspace {s} has no running VM to read a log from: {s}", .{ request.workspace_id, @errorName(err) });
        return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
    };
    const log_path = policy.guestJobLogPath(allocator, request.log_name) catch |err| {
        return rpc.encodeFailure(allocator, request.id, .bad_request, @errorName(err));
    };

    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    var offset = request.offset;
    var size: i64 = 0;
    var eof = false;
    while (data.items.len < request.max_bytes) {
        const want = request.max_bytes - data.items.len;
        const chunk = vm_client.readLogChunk(allocator, layout, log_path, offset, want) catch |err| {
            log("log read in workspace {s} failed: {s}", .{ request.workspace_id, @errorName(err) });
            if (data.items.len == 0) {
                return rpc.encodeFailure(allocator, request.id, .vm_unavailable, @errorName(err));
            }
            break;
        };
        defer chunk.deinit(allocator);
        if (chunk.missing) {
            if (data.items.len == 0) {
                return rpc.encodeLogChunk(allocator, request.id, .{
                    .data = "",
                    .size = 0,
                    .eof = true,
                    .missing = true,
                });
            }
            break;
        }
        size = chunk.size;
        eof = chunk.eof;
        if (chunk.data.len == 0) break;
        try data.appendSlice(allocator, chunk.data);
        offset += @intCast(chunk.data.len);
        if (eof) break;
    }
    return rpc.encodeLogChunk(allocator, request.id, .{
        .data = data.items,
        .size = size,
        .eof = eof,
        .missing = false,
    });
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
