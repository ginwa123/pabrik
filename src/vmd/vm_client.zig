//! `VmClient` — pabrik's own side of the guest protocol: boot a Firecracker VM
//! for a workspace, run commands in it over hybrid vsock, stop it. Every path
//! is derived from the workspace id; no caller ever passes one.

const std = @import("std");
const linux = std.os.linux;

pub const agent_port: u32 = 5000;
pub const max_frame: usize = 64 * 1024;
pub const default_mem_mib: u32 = 512;
pub const default_vcpus: u32 = 1;
pub const boot_timeout_ms: u32 = 20_000;
/// A hello probe against a wedged guest must fail, not hang the caller: the
/// daemon's sweeper holds a workspace lock while it probes.
pub const hello_probe_ms: u32 = 2_000;
pub const poll_slice_ms: i32 = 200;

const unix_af: u32 = 1;
const sock_stream: u32 = 1;

pub const Error = error{
    SocketFailed,
    ConnectFailed,
    HandshakeRejected,
    HttpFailed,
    SpawnFailed,
    DiskCloneFailed,
    MkdirFailed,
    FrameTooLarge,
    ProtocolViolation,
    ReplyTooLarge,
    Timeout,
    OutOfMemory,
};

// ─── layout: the only place a path is decided ────────────────────────────

pub const Spec = struct {
    workspace_id: []const u8,
    base_image: []const u8,
    kernel: []const u8,
    fc_bin: []const u8,
    root: []const u8,
    mem_mib: u32 = default_mem_mib,
    vcpus: u32 = default_vcpus,
};

pub const Layout = struct {
    dir: []u8,
    disk: []u8,
    api_sock: []u8,
    vsock_sock: []u8,
    serial_log: []u8,
    fc_log: []u8,
    /// The pid of the VMM this workspace is running, if any. It is how a fresh
    /// manager tells a live VMM from the sockets a hard kill left behind.
    fc_pid: []u8,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.disk);
        allocator.free(self.api_sock);
        allocator.free(self.vsock_sock);
        allocator.free(self.serial_log);
        allocator.free(self.fc_log);
        allocator.free(self.fc_pid);
    }
};

/// `<root>/workspaces/<id>/{disk.ext4,api.sock,vsock.sock,serial.log,fc.log}`.
/// The manager's RPC will take a workspace id and nothing else, and this is the
/// rule that makes that possible.
pub fn layoutFor(allocator: std.mem.Allocator, spec: Spec) !Layout {
    const dir = try std.fmt.allocPrint(allocator, "{s}/workspaces/{s}", .{ spec.root, spec.workspace_id });
    errdefer allocator.free(dir);
    const disk = try std.fmt.allocPrint(allocator, "{s}/disk.ext4", .{dir});
    errdefer allocator.free(disk);
    const api_sock = try std.fmt.allocPrint(allocator, "{s}/api.sock", .{dir});
    errdefer allocator.free(api_sock);
    const vsock_sock = try std.fmt.allocPrint(allocator, "{s}/vsock.sock", .{dir});
    errdefer allocator.free(vsock_sock);
    const serial_log = try std.fmt.allocPrint(allocator, "{s}/serial.log", .{dir});
    errdefer allocator.free(serial_log);
    const fc_log = try std.fmt.allocPrint(allocator, "{s}/fc.log", .{dir});
    errdefer allocator.free(fc_log);
    const fc_pid = try std.fmt.allocPrint(allocator, "{s}/fc.pid", .{dir});
    return .{
        .dir = dir,
        .disk = disk,
        .api_sock = api_sock,
        .vsock_sock = vsock_sock,
        .serial_log = serial_log,
        .fc_log = fc_log,
        .fc_pid = fc_pid,
    };
}

/// `mkdir -p`: every component, EEXIST tolerated.
fn ensureDir(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return Error.MkdirFailed;
    @memcpy(buf[0..path.len], path);
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        buf[i] = 0;
        const rc = linux.mkdir(@ptrCast(&buf), 0o755);
        errno_blk: {
            if (linux.errno(rc) == .SUCCESS) break :errno_blk;
            if (linux.errno(rc) == .EXIST) break :errno_blk;
            return Error.MkdirFailed;
        }
        if (i != path.len) buf[i] = '/';
    }
}

// ─── raw sockets ─────────────────────────────────────────────────────────

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

pub fn connectUnix(path: []const u8) !linux.fd_t {
    if (path.len + 1 > 108) return Error.ConnectFailed;
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) != .SUCCESS) {
        _ = linux.close(fd);
        return Error.ConnectFailed;
    }
    return fd;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
        if (rc == 0) return;
        off += rc;
    }
}

fn readExact(fd: linux.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
        if (rc == 0) return Error.ProtocolViolation;
        off += rc;
    }
}

fn setReceiveTimeout(fd: linux.fd_t, ms: u32) void {
    const tv = linux.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
}

fn sleepMs(ms: u64) void {
    const ts = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&ts, null);
}

/// NUL-terminated copies for execve, which cannot take Zig slices.
pub fn cstr(src: []const u8, dst: []u8) ?[*:0]const u8 {
    if (src.len + 1 > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @ptrCast(dst.ptr);
}

// ─── firecracker control plane ───────────────────────────────────────────

/// One `PUT` over the VMM's unix socket. Hand-rolled HTTP/1.1: the API answers
/// 204 with no body, so there is nothing to parse past the status line.
fn apiPut(api_sock: []const u8, endpoint: []const u8, body: []const u8) !void {
    const fd = try connectUnix(api_sock);
    defer _ = linux.close(fd);
    var request: [8 * 1024]u8 = undefined;
    const text = std.fmt.bufPrint(
        &request,
        "PUT {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ endpoint, body.len, body },
    ) catch return Error.HttpFailed;
    try writeAll(fd, text);
    var response: [512]u8 = undefined;
    const n = linux.read(fd, &response, response.len);
    if (linux.errno(n) != .SUCCESS) return Error.HttpFailed;
    if (n < 12 or !std.mem.startsWith(u8, response[0..n], "HTTP/1.1 204")) return Error.HttpFailed;
}

fn spawnFirecracker(spec: Spec, layout: Layout) !linux.pid_t {
    var fc_buf: [4096]u8 = undefined;
    var sock_buf: [4096]u8 = undefined;
    const fc = cstr(spec.fc_bin, &fc_buf) orelse return Error.SpawnFailed;
    const sock = cstr(layout.api_sock, &sock_buf) orelse return Error.SpawnFailed;
    const argv = [_:null]?[*:0]const u8{ fc, "--api-sock", sock, "--enable-pci", null };
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", null };

    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return Error.SpawnFailed;
    if (child == 0) {
        // The VMM must not write to our stdout: a manager's stdout is its own
        // output stream. Early Firecracker lines belong in the workspace's log.
        var log_buf: [4096]u8 = undefined;
        if (cstr(layout.fc_log, &log_buf)) |log_z| {
            const rc = linux.open(log_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
            if (linux.errno(rc) == .SUCCESS) {
                const log_fd: linux.fd_t = @intCast(rc);
                _ = linux.dup2(log_fd, 1);
                _ = linux.dup2(log_fd, 2);
                if (log_fd > 2) _ = linux.close(log_fd);
            }
        }
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.execve(fc, @ptrCast(&argv), @ptrCast(&envp));
        linux.exit(127);
    }
    return @intCast(child);
}

fn waitForApiSocket(api_sock: []const u8, timeout_ms: u32) !void {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 50) {
        if (connectUnix(api_sock)) |fd| {
            _ = linux.close(fd);
            return;
        } else |_| {}
        sleepMs(50);
    }
    return Error.ConnectFailed;
}

/// `<root>/workspaces/<id>` exists. The manager takes its boot lock on that
/// directory, so it has to exist before the lock, not inside `boot`.
pub fn ensureWorkspaceDir(layout: Layout) !void {
    try ensureDir(layout.dir);
}

/// Record the VMM's pid so a later manager can adopt it instead of guessing
/// from a socket that a hard kill also leaves behind.
pub fn writePid(layout: Layout, pid: linux.pid_t) void {
    var buf: [4096]u8 = undefined;
    const path = cstr(layout.fc_pid, &buf) orelse return;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var text: [24]u8 = undefined;
    const written = std.fmt.bufPrint(&text, "{d}\n", .{pid}) catch return;
    writeAll(fd, written) catch {};
}

pub fn clearPid(layout: Layout) void {
    var buf: [4096]u8 = undefined;
    const path = cstr(layout.fc_pid, &buf) orelse return;
    _ = linux.unlink(path);
}

pub fn readPid(layout: Layout) ?linux.pid_t {
    var buf: [4096]u8 = undefined;
    const path = cstr(layout.fc_pid, &buf) orelse return null;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var text: [24]u8 = undefined;
    const n = linux.read(fd, &text, text.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    const trimmed = std.mem.trim(u8, text[0..n], " \n\r\t");
    const pid = std.fmt.parseInt(i32, trimmed, 10) catch return null;
    if (pid <= 0) return null;
    return @intCast(pid);
}

/// Signal 0 is the "does this process exist" probe. It goes through the raw
/// syscall because `std.os.linux`'s `SIG` is an enum with no zero member.
fn pidAlive(pid: linux.pid_t) bool {
    const err = linux.errno(linux.syscall2(.kill, @intCast(pid), 0));
    return err == .SUCCESS or err == .PERM;
}

/// `wait_pid(2)`'s WNOHANG. A VMM we forked becomes a zombie that `kill(pid,
/// 0)` still reports as alive, so the reap has to happen inside the poll.
const wno_hang: u32 = 1;

pub fn waitGone(pid: linux.pid_t, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        var status: u32 = 0;
        const rc = linux.wait4(pid, &status, wno_hang, null);
        if (linux.errno(rc) == .SUCCESS and rc != 0) return true;
        if (!pidAlive(pid)) return true;
        sleepMs(10);
    }
    return false;
}

pub const Vm = struct {
    pid: linux.pid_t,
    layout: Layout,
    spec: Spec,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Vm) void {
        self.layout.deinit(self.allocator);
    }
};

/// Firecracker refuses to bind an API socket that already exists, and a killed
/// VM leaves its sockets behind, so the manager removes them before booting.
fn removeIfExists(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = cstr(path, &buf) orelse return;
    _ = linux.unlink(z);
}

fn pathExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const z = cstr(path, &buf) orelse return false;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) == .SUCCESS) {
        _ = linux.close(@intCast(rc));
        return true;
    }
    return false;
}

/// The workspace's disk is its own; the base image is never booted directly,
/// and `--reflink=auto` makes the clone O(1) on this box's btrfs.
fn cloneBaseIfMissing(base: []const u8, disk: []const u8) !void {
    if (pathExists(disk)) return;
    var base_buf: [4096]u8 = undefined;
    var disk_buf: [4096]u8 = undefined;
    const base_z = cstr(base, &base_buf) orelse return Error.DiskCloneFailed;
    const disk_z = cstr(disk, &disk_buf) orelse return Error.DiskCloneFailed;
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/cp", "--reflink=auto", base_z, disk_z, null };
    const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", null };

    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) return Error.DiskCloneFailed;
    if (child == 0) {
        _ = linux.execve("/usr/bin/cp", @ptrCast(&argv), @ptrCast(&envp));
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.wait4(@intCast(child), &status, 0, null);
    if (!linux.W.IFEXITED(status) or linux.W.EXITSTATUS(status) != 0) return Error.DiskCloneFailed;
}

/// Create the workspace's directory, clone the base image if needed, start the
/// VMM, configure it, and start the instance.
pub fn boot(allocator: std.mem.Allocator, spec: Spec) !Vm {
    var layout = try layoutFor(allocator, spec);
    errdefer layout.deinit(allocator);

    try ensureDir(layout.dir);
    removeIfExists(layout.api_sock);
    removeIfExists(layout.vsock_sock);
    try cloneBaseIfMissing(spec.base_image, layout.disk);

    const pid = try spawnFirecracker(spec, layout);
    errdefer _ = linux.kill(pid, linux.SIG.KILL);
    writePid(layout, pid);

    try waitForApiSocket(layout.api_sock, boot_timeout_ms);

    var body: [4096]u8 = undefined;
    try apiPut(layout.api_sock, "/logger", try std.fmt.bufPrint(
        &body,
        "{{\"log_path\":\"{s}\",\"level\":\"Warning\",\"show_level\":true}}",
        .{layout.fc_log},
    ));
    try apiPut(layout.api_sock, "/serial", try std.fmt.bufPrint(
        &body,
        "{{\"serial_out_path\":\"{s}\"}}",
        .{layout.serial_log},
    ));
    try apiPut(layout.api_sock, "/boot-source", try std.fmt.bufPrint(
        &body,
        "{{\"kernel_image_path\":\"{s}\",\"boot_args\":\"console=ttyS0 reboot=k panic=1 root=/dev/vda rw init=/init\"}}",
        .{spec.kernel},
    ));
    try apiPut(layout.api_sock, "/drives/rootfs", try std.fmt.bufPrint(
        &body,
        "{{\"drive_id\":\"rootfs\",\"path_on_host\":\"{s}\",\"is_root_device\":true,\"is_read_only\":false}}",
        .{layout.disk},
    ));
    try apiPut(layout.api_sock, "/vsock", try std.fmt.bufPrint(
        &body,
        "{{\"guest_cid\":3,\"uds_path\":\"{s}\"}}",
        .{layout.vsock_sock},
    ));
    try apiPut(layout.api_sock, "/machine-config", try std.fmt.bufPrint(
        &body,
        "{{\"vcpu_count\":{d},\"mem_size_mib\":{d}}}",
        .{ spec.vcpus, spec.mem_mib },
    ));
    try apiPut(layout.api_sock, "/actions", "{\"action_type\":\"InstanceStart\"}");

    return .{ .pid = pid, .layout = layout, .spec = spec, .allocator = allocator };
}

/// `ready` means the agent answered `hello`, not that the process exists — the
/// guest needs ~1 s after InstanceStart and the muxer accepts a CONNECT before
/// its listener is up, so the first request must be a retried hello.
pub fn waitReady(layout: Layout, timeout_ms: u32) !void {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 100) {
        if (helloOnce(layout)) return;
        sleepMs(100);
    }
    return Error.Timeout;
}

/// One `hello` on a fresh connection. `false` means the guest's listener is not
/// up yet, which is normal for the first second after InstanceStart.
pub fn helloOnce(layout: Layout) bool {
    var payload: [max_frame]u8 = undefined;
    const fd = connectUnix(layout.vsock_sock) catch return false;
    defer _ = linux.close(fd);
    setReceiveTimeout(fd, hello_probe_ms);
    handshake(fd, agent_port) catch return false;
    sendFrame(fd, "{\"type\":\"hello\"}") catch return false;
    const text = readFrame(fd, &payload) catch return false;
    return std.mem.indexOf(u8, text, "\"hello\"") != null;
}

pub fn stop(vm: *Vm) void {
    clearPid(vm.layout);
    _ = linux.kill(vm.pid, linux.SIG.KILL);
    var status: u32 = 0;
    _ = linux.wait4(vm.pid, &status, 0, null);
}

// ─── guest protocol over hybrid vsock ────────────────────────────────────

pub const ExecRequest = struct {
    argv: []const []const u8,
    cwd: []const u8 = "/workspace",
    timeout_ms: u32 = 10_000,
    max_output_bytes: usize = 256 * 1024,
    id: i64 = 1,
};

pub const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: i64,
    timed_out: bool,
    truncated: bool,

    pub fn deinit(self: ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const ExecFrameState = struct {
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),
    code: i64 = -1,
    timed_out: bool = false,
    truncated: bool = false,
    done: bool = false,
};

fn appendJsonString(out: []u8, off: *usize, value: []const u8) !void {
    if (off.* >= out.len) return Error.ReplyTooLarge;
    out[off.*] = '"';
    off.* += 1;
    for (value) |byte| {
        if (off.* + 2 > out.len and (byte < 0x20 or byte == '"' or byte == '\\')) return Error.ReplyTooLarge;
        switch (byte) {
            '"' => {
                out[off.*] = '\\';
                out[off.* + 1] = '"';
                off.* += 2;
            },
            '\\' => {
                out[off.*] = '\\';
                out[off.* + 1] = '\\';
                off.* += 2;
            },
            else => {
                if (byte < 0x20) {
                    if (off.* + 6 > out.len) return Error.ReplyTooLarge;
                    const hex = std.fmt.bufPrint(out[off.*..], "\\u{x:0>4}", .{byte}) catch return Error.ReplyTooLarge;
                    off.* += hex.len;
                } else {
                    out[off.*] = byte;
                    off.* += 1;
                }
            },
        }
    }
    if (off.* >= out.len) return Error.ReplyTooLarge;
    out[off.*] = '"';
    off.* += 1;
}

fn buildExecFrame(buf: []u8, request: ExecRequest) ![]const u8 {
    var out: [16 * 1024]u8 = undefined;
    var off: usize = 0;
    const head = try std.fmt.bufPrint(
        &out,
        "{{\"type\":\"exec\",\"id\":{d},\"cwd\":\"{s}\",\"timeout_ms\":{d},\"max_output_bytes\":{d},\"argv\":[",
        .{ request.id, request.cwd, request.timeout_ms, request.max_output_bytes },
    );
    @memcpy(buf[0..head.len], head);
    off = head.len;
    for (request.argv, 0..) |arg, i| {
        if (i != 0) {
            buf[off] = ',';
            off += 1;
        }
        try appendJsonString(buf, &off, arg);
    }
    const tail = "]}";
    @memcpy(buf[off..][0..tail.len], tail);
    off += tail.len;
    return buf[0..off];
}

fn sendFrame(fd: linux.fd_t, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

fn readFrame(fd: linux.fd_t, buf: *[max_frame]u8) ![]const u8 {
    var header: [4]u8 = undefined;
    try readExact(fd, &header);
    const len = std.mem.readInt(u32, &header, .big);
    if (len == 0 or len > max_frame) return Error.FrameTooLarge;
    try readExact(fd, buf[0..len]);
    return buf[0..len];
}

/// The muxer answers `CONNECT <port>` with one text line before any frame.
fn handshake(fd: linux.fd_t, port: u32) !void {
    var line: [64]u8 = undefined;
    const request = try std.fmt.bufPrint(&line, "CONNECT {d}\n", .{port});
    try writeAll(fd, request);
    var seen: usize = 0;
    while (seen < line.len) {
        try readExact(fd, line[seen .. seen + 1]);
        seen += 1;
        if (line[seen - 1] == '\n') break;
    }
    if (seen < 2 or !std.mem.startsWith(u8, line[0..seen], "OK")) return Error.HandshakeRejected;
}

/// Connect, handshake, run one command, collect its frames until `exec.exit`.
pub fn exec(allocator: std.mem.Allocator, layout: Layout, request: ExecRequest) !ExecResult {
    const fd = try connectUnix(layout.vsock_sock);
    defer _ = linux.close(fd);
    try handshake(fd, agent_port);

    var request_buf: [16 * 1024]u8 = undefined;
    const frame = try buildExecFrame(&request_buf, request);
    try sendFrame(fd, frame);

    var state = ExecFrameState{
        .stdout = std.ArrayList(u8).empty,
        .stderr = std.ArrayList(u8).empty,
    };
    errdefer {
        state.stdout.deinit(allocator);
        state.stderr.deinit(allocator);
    }

    // The guest enforces the deadline; this is a guard against a wedged peer.
    const guard_ms: u32 = request.timeout_ms + 15_000;
    var waited_ms: u32 = 0;
    var payload: [max_frame]u8 = undefined;
    while (!state.done) {
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, pfd.len, poll_slice_ms);
        if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
        if (rc == 0) {
            waited_ms += @intCast(poll_slice_ms);
            if (waited_ms >= guard_ms) return Error.Timeout;
            continue;
        }
        const text = try readFrame(fd, &payload);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
            return Error.ProtocolViolation;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return Error.ProtocolViolation,
        };
        const kind = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (std.mem.eql(u8, kind, "exec.timeout")) {
            state.timed_out = true;
            continue;
        }
        if (std.mem.eql(u8, kind, "exec.exit")) {
            if (obj.get("code")) |c| state.code = switch (c) {
                .integer => |i| i,
                else => -1,
            };
            if (obj.get("truncated")) |t| state.truncated = (t == .bool and t.bool);
            state.done = true;
            continue;
        }
        const sink = if (std.mem.eql(u8, kind, "exec.stdout"))
            &state.stdout
        else if (std.mem.eql(u8, kind, "exec.stderr"))
            &state.stderr
        else
            continue;
        const b64 = if (obj.get("data_b64")) |d| (if (d == .string) d.string else "") else "";
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(b64) catch return Error.ProtocolViolation;
        var chunk: [max_frame]u8 = undefined;
        if (size > chunk.len) return Error.ReplyTooLarge;
        decoder.decode(chunk[0..size], b64) catch return Error.ProtocolViolation;
        try sink.appendSlice(allocator, chunk[0..size]);
    }

    return .{
        .stdout = try state.stdout.toOwnedSlice(allocator),
        .stderr = try state.stderr.toOwnedSlice(allocator),
        .code = state.code,
        .timed_out = state.timed_out,
        .truncated = state.truncated,
    };
}

pub fn readSerialExcerpt(allocator: std.mem.Allocator, layout: Layout, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    const z = cstr(layout.serial_log, &buf) orelse return Error.OutOfMemory;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return allocator.alloc(u8, 0);
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const out = try allocator.alloc(u8, max_bytes);
    const n = linux.read(fd, out.ptr, out.len);
    if (linux.errno(n) != .SUCCESS) return out[0..0];
    return out[0..n];
}
