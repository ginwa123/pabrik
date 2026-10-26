//! `VmClient` — pabrik's own side of the guest protocol: boot a Firecracker VM
//! for a workspace, run commands in it over hybrid vsock, stop it. Every path
//! is derived from the workspace id; no caller ever passes one.

const std = @import("std");
const linux = std.os.linux;
const policy = @import("policy.zig");

pub const agent_port: u32 = 5000;
/// Opening a terminal forks a guest process that must bind its own listener, so
/// it gets more than a plain RPC's budget and less than a boot's.
const tty_open_guard_ms: u32 = 10_000;
/// A terminal read/write/resize is answered from a running process, never from
/// a boot: a peer that has not answered by now is not going to.
const tty_call_guard_ms: u32 = 5_000;
pub const max_frame: usize = 64 * 1024;
/// One `fs.write` frame's bytes. The agent refuses more than this, and a
/// 64 KiB frame cannot hold much more once base64 and the envelope are paid
/// for, so the two ends agree on one number.
pub const fs_write_chunk: usize = 32 * 1024;
pub const default_mem_mib: u32 = 512;
pub const default_vcpus: u32 = 1;
pub const boot_timeout_ms: u32 = 20_000;
/// A hello probe against a wedged guest must fail, not hang the caller: the
/// daemon's sweeper holds a workspace lock while it probes.
pub const hello_probe_ms: u32 = 2_000;
pub const poll_slice_ms: i32 = 200;
/// Guards for the single-round-trip job calls: they do no work in the guest,
/// so anything approaching these means the guest is wedged.
pub const job_call_guard_ms: u32 = 10_000;
pub const spawn_guard_ms: u32 = 10_000;

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
    WriteFailed,
    /// The guest was asked to walk something that is not a directory it will
    /// enter. Not the same as an empty one, and not this client's to guess at.
    WalkNotADirectory,
    /// The guest refused to open a terminal, or answered something a terminal
    /// answer cannot be. Distinct from a transport failure.
    TtyFailed,
    /// The terminal's own guest process is gone: the shell exited, or the VM
    /// was restarted under it. Never a reason to boot anything.
    TtyGone,
    /// The image could not be opened or truncated, or `resize2fs` failed on it.
    DiskGrowFailed,
    /// A disk resize asked for a size the image already has, or a smaller one.
    /// The filesystem inside an image cannot give blocks back.
    DiskNotGrowing,
    /// No e2fsprogs on this host, so a grown image cannot be handed to its
    /// filesystem. Named rather than guessed at.
    ResizeToolMissing,
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
pub fn ensureDir(path: []const u8) !void {
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
    // No pabrik-vmd exists off Linux (the VM runtime is Linux-only) and the raw
    // `std.os.linux` syscalls below are meaningless on another kernel: issuing
    // them there is signal SYS, not a failed connect.
    if (comptime @import("builtin").os.tag != .linux) return Error.ConnectFailed;
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

// ─── /proc: the VMM's own numbers, for the idle reaper ───────────────────

/// One tick of `utime`/`stime` is this many milliseconds. USER_HZ is 100 on
/// every Linux ABI — a frozen constant, not a setting — so no sysconf is
/// needed and the reading means the same thing on every host.
pub const user_hz: u64 = 100;

fn readSmallFile(path: []const u8, buf: []u8) ?usize {
    var path_buf: [64]u8 = undefined;
    if (path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&path_buf);
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return n;
}

/// `/proc/<pid>/stat` → utime + stime, in ticks. Counted from the LAST ')' so
/// a comm holding spaces and parentheses cannot be read as numbers; past it,
/// state is index 0, so utime (field 14) is 11 and stime (field 15) is 12.
pub fn parseStatCpuTicks(text: []const u8) ?u64 {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var index: usize = 0;
    var utime: ?u64 = null;
    var stime: ?u64 = null;
    while (it.next()) |token| : (index += 1) {
        if (index == 11) utime = std.fmt.parseInt(u64, token, 10) catch return null;
        if (index == 12) {
            stime = std.fmt.parseInt(u64, token, 10) catch return null;
            break;
        }
    }
    return (utime orelse return null) + (stime orelse return null);
}

/// The VMM's whole-thread-group CPU time. `/proc/<pid>/stat` reports the group
/// total for a thread-group leader, which a forked Firecracker always is.
/// Null means "cannot read it", and the reaper treats that as "cannot tell".
pub fn cpuTicks(pid: linux.pid_t) ?u64 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return null;
    var text: [1024]u8 = undefined;
    const n = readSmallFile(path, &text) orelse return null;
    return parseStatCpuTicks(text[0..n]);
}

/// `/proc/<pid>/status` → `VmRSS:   1234 kB`, in KiB. Only ever used to say how
/// much a reap released: RSS is the cost of a VM, never a sign of its idleness.
pub fn parseRssKib(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
        const value = std.mem.trim(u8, line["VmRSS:".len..], " \tkB");
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

pub fn rssMib(pid: linux.pid_t) ?u32 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return null;
    var text: [4096]u8 = undefined;
    const n = readSmallFile(path, &text) orelse return null;
    const kib = parseRssKib(text[0..n]) orelse return null;
    return kib / 1024;
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
pub fn ensureDisk(base: []const u8, disk: []const u8) !void {
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

/// The image's size in MiB, or 0 when there is no image yet — which is a size
/// the console can show, not a failure.
pub fn diskSizeMib(disk: []const u8) u32 {
    var buf: [4096]u8 = undefined;
    const z = cstr(disk, &buf) orelse return 0;
    const rc = linux.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return sizeMibOf(fd);
}

fn sizeMibOf(fd: linux.fd_t) u32 {
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return 0;
    const mib = @as(u64, @intCast(end)) / (1024 * 1024);
    return if (mib > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(mib);
}

/// Repair the image, truncate it up to `target_mib`, then hand the new blocks
/// to the filesystem inside it. All of it needs the VM stopped, so the guest
/// finds the bigger device at boot.
pub fn growDisk(disk: []const u8, target_mib: u32) !void {
    var buf: [4096]u8 = undefined;
    const z = cstr(disk, &buf) orelse return Error.DiskGrowFailed;

    const rc = linux.open(z, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return Error.DiskGrowFailed;
    const fd: linux.fd_t = @intCast(rc);
    if (target_mib <= sizeMibOf(fd)) {
        _ = linux.close(fd);
        return Error.DiskNotGrowing;
    }

    // A guest that was stopped, not shut down, leaves `needs_recovery` on its
    // filesystem, and resize2fs refuses such an image outright.
    const fsck = try runHostTool(&e2fsck_candidates, &.{ "-f", "-y" }, z);
    // 1 is "errors corrected", which is the normal answer for a killed guest.
    if (fsck > 2) {
        _ = linux.close(fd);
        return Error.DiskGrowFailed;
    }

    const trunc = linux.ftruncate(fd, @as(i64, target_mib) * 1024 * 1024);
    _ = linux.close(fd);
    if (linux.errno(trunc) != .SUCCESS) return Error.DiskGrowFailed;

    if (try runHostTool(&resize2fs_candidates, &.{}, z) != 0) return Error.DiskGrowFailed;
}

const e2fsck_candidates = [_][]const u8{
    "/usr/sbin/e2fsck", "/sbin/e2fsck", "/usr/bin/e2fsck", "/bin/e2fsck",
};
const resize2fs_candidates = [_][]const u8{
    "/usr/sbin/resize2fs", "/sbin/resize2fs", "/usr/bin/resize2fs", "/bin/resize2fs",
};

/// e2fsprogs ships its tools in sbin, which is not on every PATH, and `execve`
/// searches none, so the candidates are absolute. A host without them can
/// still boot a VM; it just cannot grow a filesystem.
fn runHostTool(candidates: []const []const u8, args: []const [*:0]const u8, path_z: [*:0]const u8) !u8 {
    var tool_buf: [4096]u8 = undefined;
    for (candidates) |candidate| {
        if (!pathExists(candidate)) continue;
        const tool = cstr(candidate, &tool_buf) orelse return Error.ResizeToolMissing;
        var argv: [8]?[*:0]const u8 = .{null} ** 8;
        if (args.len + 2 > argv.len) return Error.DiskGrowFailed;
        argv[0] = tool;
        for (args, 0..) |arg, i| argv[i + 1] = arg;
        argv[args.len + 1] = path_z;
        const envp = [_:null]?[*:0]const u8{ "PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/bin:/bin", null };
        const child = linux.fork();
        if (linux.errno(child) != .SUCCESS) return Error.DiskGrowFailed;
        if (child == 0) {
            _ = linux.execve(tool, @ptrCast(&argv), @ptrCast(&envp));
            linux.exit(127);
        }
        var status: u32 = 0;
        _ = linux.wait4(@intCast(child), &status, 0, null);
        if (!linux.W.IFEXITED(status)) return Error.DiskGrowFailed;
        return @intCast(linux.W.EXITSTATUS(status));
    }
    return Error.ResizeToolMissing;
}

/// Create the workspace's directory, clone the base image if needed, start the
/// VMM, configure it, and start the instance.
pub fn boot(allocator: std.mem.Allocator, spec: Spec) !Vm {
    var layout = try layoutFor(allocator, spec);
    errdefer layout.deinit(allocator);

    try ensureDir(layout.dir);
    removeIfExists(layout.api_sock);
    removeIfExists(layout.vsock_sock);
    try ensureDisk(spec.base_image, layout.disk);

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

// ─── detached jobs: spawn, probe, signal, read a log ─────────────────────

/// One request frame in, one reply frame out. `exec` is the only multi-frame
/// conversation the guest has; everything here is a single round trip.
fn oneShot(allocator: std.mem.Allocator, layout: Layout, payload: []const u8, guard_ms: u32) ![]const u8 {
    return oneShotPort(allocator, layout, agent_port, payload, guard_ms);
}

/// The same round trip to a port other than the agent's. A terminal answers on
/// its OWN port, so its reads never queue behind a long `exec` on 5000.
fn oneShotPort(
    allocator: std.mem.Allocator,
    layout: Layout,
    port: u32,
    payload: []const u8,
    guard_ms: u32,
) ![]const u8 {
    const fd = try connectUnix(layout.vsock_sock);
    defer _ = linux.close(fd);
    try handshake(fd, port);
    try sendFrame(fd, payload);

    var waited_ms: u32 = 0;
    while (true) {
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, pfd.len, poll_slice_ms);
        if (linux.errno(rc) != .SUCCESS) return Error.SocketFailed;
        if (rc > 0) break;
        waited_ms += @intCast(poll_slice_ms);
        if (waited_ms >= guard_ms) return Error.Timeout;
    }
    var buf: [max_frame]u8 = undefined;
    const text = try readFrame(fd, &buf);
    return allocator.dupe(u8, text);
}

fn parseObject(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return Error.ProtocolViolation;
    switch (parsed.value) {
        .object => return parsed,
        else => {
            parsed.deinit();
            return Error.ProtocolViolation;
        },
    }
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBoolField(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

fn jsonIntField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

pub const SpawnRequest = struct {
    argv: []const []const u8,
    cwd: []const u8 = "/workspace",
    log_path: []const u8,
    uid: u32 = 1000,
    gid: u32 = 1000,
    id: i64 = 1,
};

pub const SpawnResult = struct {
    pid: i64,
};

fn buildSpawnFrame(buf: []u8, request: SpawnRequest) ![]const u8 {
    var head_buf: [1024]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buf,
        "{{\"type\":\"spawn\",\"id\":{d},\"uid\":{d},\"gid\":{d},\"cwd\":",
        .{ request.id, request.uid, request.gid },
    );
    @memcpy(buf[0..head.len], head);
    var off: usize = head.len;
    try appendJsonString(buf, &off, request.cwd);
    const mid = ",\"log_path\":";
    @memcpy(buf[off..][0..mid.len], mid);
    off += mid.len;
    try appendJsonString(buf, &off, request.log_path);
    const argv_head = ",\"argv\":[";
    @memcpy(buf[off..][0..argv_head.len], argv_head);
    off += argv_head.len;
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

/// Fork a detached job in the guest and return the pid it was given. The pid
/// is the guest's, and it leads its own process group there.
pub fn spawn(allocator: std.mem.Allocator, layout: Layout, request: SpawnRequest) !SpawnResult {
    var frame_buf: [16 * 1024]u8 = undefined;
    const frame = try buildSpawnFrame(&frame_buf, request);
    const text = try oneShot(allocator, layout, frame, spawn_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (jsonStringField(obj, "type")) |kind| {
        if (std.mem.eql(u8, kind, "spawn.error")) return Error.SpawnFailed;
    }
    const pid = jsonIntField(obj, "pid") orelse return Error.ProtocolViolation;
    if (pid <= 0) return Error.SpawnFailed;
    return .{ .pid = pid };
}

pub const ProbeResult = struct {
    alive: bool,
};

/// Is the job still there? Asks the guest, so a pid the HOST also happens to
/// have says nothing about this answer.
pub fn probe(allocator: std.mem.Allocator, layout: Layout, pid: i64) !ProbeResult {
    var frame_buf: [256]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"probe\",\"id\":1,\"pid\":{d}}}",
        .{pid},
    );
    const text = try oneShot(allocator, layout, frame, job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    return .{ .alive = jsonBoolField(parsed.value.object, "alive") };
}

/// Signal the job's whole group, then the pid itself. `false` means neither
/// reached anything, which is what a job that already exited reports.
pub fn signal(allocator: std.mem.Allocator, layout: Layout, pid: i64, sig: i64) !bool {
    var frame_buf: [256]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"signal\",\"id\":1,\"pid\":{d},\"signal\":{d}}}",
        .{ pid, sig },
    );
    const text = try oneShot(allocator, layout, frame, job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    return jsonBoolField(parsed.value.object, "sent");
}

pub const LogChunk = struct {
    data: []u8,
    size: i64,
    eof: bool,
    missing: bool,

    pub fn deinit(self: LogChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// One positional read of a job's log, from inside the guest. The host never
/// opens the file: a tenant log is not a host path.
pub fn readLogChunk(
    allocator: std.mem.Allocator,
    layout: Layout,
    log_path: []const u8,
    offset: i64,
    max_bytes: usize,
) !LogChunk {
    var frame_buf: [16 * 1024]u8 = undefined;
    // `bufPrint` writes INTO `frame_buf`, so the cursor starts where it stopped
    // — copying the head onto itself would be an aliased `memcpy`.
    const head = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"read_log\",\"id\":1,\"offset\":{d},\"max_bytes\":{d},\"path\":",
        .{ offset, max_bytes },
    );
    var off: usize = head.len;
    try appendJsonString(&frame_buf, &off, log_path);
    frame_buf[off] = '}';
    off += 1;

    const text = try oneShot(allocator, layout, frame_buf[0..off], job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (jsonBoolField(obj, "missing")) {
        return .{ .data = try allocator.alloc(u8, 0), .size = 0, .eof = true, .missing = true };
    }
    const b64 = jsonStringField(obj, "data_b64") orelse return Error.ProtocolViolation;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(b64) catch return Error.ProtocolViolation;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    decoder.decode(data, b64) catch return Error.ProtocolViolation;
    return .{
        .data = data,
        .size = jsonIntField(obj, "size") orelse @intCast(data.len),
        .eof = jsonBoolField(obj, "eof"),
        .missing = false,
    };
}

pub const FsKind = enum { file, dir };

pub const FsStat = struct {
    kind: FsKind,
    size: i64,
    missing: bool,
};

/// One path's kind and size, asked of the guest. `missing` is the guest saying
/// the path is not there, which is not the same as a size of zero.
pub fn statFile(allocator: std.mem.Allocator, layout: Layout, path: []const u8) !FsStat {
    var frame_buf: [8 * 1024]u8 = undefined;
    const head = try std.fmt.bufPrint(&frame_buf, "{{\"type\":\"fs.stat\",\"id\":1,\"path\":", .{});
    var off: usize = head.len;
    try appendJsonString(&frame_buf, &off, path);
    frame_buf[off] = '}';
    off += 1;

    const text = try oneShot(allocator, layout, frame_buf[0..off], job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (jsonBoolField(obj, "missing")) return .{ .kind = .file, .size = 0, .missing = true };
    const kind_text = jsonStringField(obj, "kind") orelse return Error.ProtocolViolation;
    return .{
        .kind = if (std.mem.eql(u8, kind_text, "dir")) .dir else .file,
        .size = jsonIntField(obj, "size") orelse 0,
        .missing = false,
    };
}

pub const FsChunk = struct {
    data: []u8,
    size: i64,
    eof: bool,
    missing: bool,

    pub fn deinit(self: FsChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// One positional read of a file, from inside the guest. A caller that wants a
/// whole file loops until `eof`; each reply is bounded by `max_bytes`.
pub fn readFile(
    allocator: std.mem.Allocator,
    layout: Layout,
    path: []const u8,
    offset: i64,
    max_bytes: usize,
) !FsChunk {
    var frame_buf: [8 * 1024]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"fs.read\",\"id\":1,\"offset\":{d},\"max_bytes\":{d},\"path\":",
        .{ offset, max_bytes },
    );
    var off: usize = head.len;
    try appendJsonString(&frame_buf, &off, path);
    frame_buf[off] = '}';
    off += 1;

    const text = try oneShot(allocator, layout, frame_buf[0..off], job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (jsonBoolField(obj, "missing")) {
        return .{ .data = try allocator.alloc(u8, 0), .size = 0, .eof = true, .missing = true };
    }
    const b64 = jsonStringField(obj, "data_b64") orelse return Error.ProtocolViolation;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(b64) catch return Error.ProtocolViolation;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    decoder.decode(data, b64) catch return Error.ProtocolViolation;
    return .{
        .data = data,
        .size = jsonIntField(obj, "size") orelse @intCast(data.len),
        .eof = jsonBoolField(obj, "eof"),
        .missing = false,
    };
}

/// Remove one file (or one empty directory) inside the guest. `false` is the
/// guest saying there was nothing there.
pub fn removeFile(allocator: std.mem.Allocator, layout: Layout, path: []const u8) !bool {
    var frame_buf: [8 * 1024]u8 = undefined;
    const head = try std.fmt.bufPrint(&frame_buf, "{{\"type\":\"fs.remove\",\"id\":1,\"path\":", .{});
    var off: usize = head.len;
    try appendJsonString(&frame_buf, &off, path);
    frame_buf[off] = '}';
    off += 1;

    const text = try oneShot(allocator, layout, frame_buf[0..off], job_call_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (jsonBoolField(obj, "missing")) return false;
    const kind = jsonStringField(obj, "type") orelse return Error.ProtocolViolation;
    if (!std.mem.eql(u8, kind, "fs.remove.ok")) return Error.ProtocolViolation;
    return true;
}

pub const WriteOutcome = struct {
    bytes: usize,
};

pub const WalkEntry = struct {
    path: []u8,
    kind: []u8,
};

/// A walk's answer: every entry the guest reported, and whether its own
/// ceilings cut the tree short.
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

fn buildWriteFrame(
    buf: []u8,
    path: []const u8,
    offset: i64,
    data: []const u8,
    create_dirs: bool,
) ![]const u8 {
    var head_buf: [256]u8 = undefined;
    // `truncate` is the first piece's business: the pieces after it extend a
    // file that is already the right length.
    const head = try std.fmt.bufPrint(
        &head_buf,
        "{{\"type\":\"fs.write\",\"id\":1,\"offset\":{d},\"truncate\":{s},\"create_dirs\":{s},\"data_b64\":\"",
        .{
            offset,
            if (offset == 0) "true" else "false",
            if (create_dirs) "true" else "false",
        },
    );
    @memcpy(buf[0..head.len], head);
    var off: usize = head.len;
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(data.len);
    if (off + size + path.len * 6 + 64 > buf.len) return Error.ReplyTooLarge;
    _ = encoder.encode(buf[off .. off + size], data);
    off += size;
    const mid = "\",\"path\":";
    @memcpy(buf[off..][0..mid.len], mid);
    off += mid.len;
    try appendJsonString(buf, &off, path);
    buf[off] = '}';
    off += 1;
    return buf[0..off];
}

/// Write `data` to `path` inside the guest, in frame-sized pieces: the first
/// piece creates the file and the directories it needs, the rest extend it.
/// The host writes nothing — this is the only path a tenant file is created on.
pub fn writeFile(
    allocator: std.mem.Allocator,
    layout: Layout,
    path: []const u8,
    data: []const u8,
    create_dirs: bool,
) !WriteOutcome {
    const fd = try connectUnix(layout.vsock_sock);
    defer _ = linux.close(fd);
    try handshake(fd, agent_port);

    var frame_buf: [64 * 1024]u8 = undefined;
    var reply_buf: [max_frame]u8 = undefined;
    var offset: i64 = 0;
    var sent: usize = 0;
    while (true) {
        const piece = @min(fs_write_chunk, data.len - sent);
        const frame = try buildWriteFrame(&frame_buf, path, offset, data[sent .. sent + piece], create_dirs);
        try sendFrame(fd, frame);

        const text = try readFrame(fd, &reply_buf);
        var parsed = try parseObject(allocator, text);
        defer parsed.deinit();
        const obj = parsed.value.object;
        const kind = jsonStringField(obj, "type") orelse return Error.ProtocolViolation;
        // The guest refused: a path it will not open, or a parent that is not
        // there. Its reason is not this client's to invent.
        if (std.mem.eql(u8, kind, "fs.error")) return Error.WriteFailed;
        if (!std.mem.eql(u8, kind, "fs.write.ok")) return Error.ProtocolViolation;
        // The guest's own count is the only evidence the bytes landed.
        const landed = jsonIntField(obj, "size") orelse return Error.ProtocolViolation;
        if (landed != @as(i64, @intCast(piece))) return Error.ProtocolViolation;

        sent += piece;
        offset += @intCast(piece);
        if (sent >= data.len) break;
    }
    return .{ .bytes = sent };
}

/// A bounded walk of the guest, STREAMED: the agent sends one frame per batch
/// of entries and the last one carries `done`. Nothing outside the guest tree
/// is ever named, because every path in the reply is relative to it.
pub fn walk(
    allocator: std.mem.Allocator,
    layout: Layout,
    path: []const u8,
    max_depth: u32,
    max_entries: usize,
) !WalkResult {
    const fd = try connectUnix(layout.vsock_sock);
    defer _ = linux.close(fd);
    try handshake(fd, agent_port);

    var request_buf: [4096]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &request_buf,
        "{{\"type\":\"fs.walk\",\"id\":1,\"max_depth\":{d},\"max_entries\":{d},\"path\":",
        .{ max_depth, max_entries },
    );
    var off: usize = head.len;
    try appendJsonString(&request_buf, &off, path);
    request_buf[off] = '}';
    off += 1;
    try sendFrame(fd, request_buf[0..off]);

    var out: std.ArrayList(WalkEntry) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.path);
            allocator.free(entry.kind);
        }
        out.deinit(allocator);
    }

    var reply_buf: [max_frame]u8 = undefined;
    var count: usize = 0;
    var truncated = false;
    while (true) {
        const text = try readFrame(fd, &reply_buf);
        var parsed = try parseObject(allocator, text);
        defer parsed.deinit();
        const obj = parsed.value.object;
        const kind = jsonStringField(obj, "type") orelse return Error.ProtocolViolation;
        if (std.mem.eql(u8, kind, "fs.error")) return Error.WalkNotADirectory;
        if (!std.mem.eql(u8, kind, "fs.walk")) return Error.ProtocolViolation;

        if (obj.get("entries")) |value| {
            const items = switch (value) {
                .array => |a| a.items,
                else => return Error.ProtocolViolation,
            };
            for (items) |item| {
                const entry = switch (item) {
                    .object => |o| o,
                    else => return Error.ProtocolViolation,
                };
                const entry_path = jsonStringField(entry, "path") orelse return Error.ProtocolViolation;
                const entry_kind = jsonStringField(entry, "kind") orelse return Error.ProtocolViolation;
                // Entries are bounded by what was asked for: a guest that
                // reports more than its ceiling is not answering this call.
                if (out.items.len >= max_entries) return Error.ProtocolViolation;
                try out.append(allocator, .{
                    .path = try allocator.dupe(u8, entry_path),
                    .kind = try allocator.dupe(u8, entry_kind),
                });
            }
        }

        if (jsonBoolField(obj, "done")) {
            count = @intCast(jsonIntField(obj, "count") orelse @as(i64, @intCast(out.items.len)));
            truncated = jsonBoolField(obj, "truncated");
            break;
        }
    }
    // The guest counted what it sent; a stream that disagrees with its own
    // count was cut somewhere, and half a listing is worse than a refusal.
    if (count != out.items.len) return Error.ProtocolViolation;
    return .{ .entries = try out.toOwnedSlice(allocator), .count = count, .truncated = truncated };
}

// ─── interactive terminals ───────────────────────────────────────────────

/// A terminal the guest created: the id the daemon minted, the pid of the
/// shell it runs, and the vsock port that terminal answers on.
pub const TtyOpen = struct {
    tty_id: i64,
    pid: i64,
    port: u32,
};

pub const TtyRead = struct {
    data: []u8,
    eof: bool,
    exited: bool,
    exit_code: i64,

    pub fn deinit(self: TtyRead, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// The guest's own reason for refusing to open a terminal. Copied, not
/// borrowed: the frame it came from is released before the caller reads it.
pub const TtyRefusal = struct {
    pub const max = 256;
    message: [max]u8 = [_]u8{0} ** max,
    len: usize = 0,

    pub fn text(self: *const TtyRefusal) []const u8 {
        return self.message[0..self.len];
    }
};

/// Open a terminal in the guest. The agent forks the process that will own the
/// pty and answer on `tty_port_base + tty_id`.
pub fn ttyOpen(
    allocator: std.mem.Allocator,
    layout: Layout,
    cols: u16,
    rows: u16,
    cwd: []const u8,
    refusal: ?*TtyRefusal,
) !TtyOpen {
    var frame_buf: [4096]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"tty\",\"op\":\"open\",\"id\":1,\"cols\":{d},\"rows\":{d},\"cwd\":",
        .{ cols, rows },
    );
    var off = head.len;
    try appendJsonString(&frame_buf, &off, cwd);
    frame_buf[off] = '}';
    off += 1;

    const text = try oneShot(allocator, layout, frame_buf[0..off], tty_open_guard_ms);
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const id = jsonIntField(obj, "tty_id") orelse {
        if (refusal) |out| {
            const message = refusalText(obj);
            out.len = @min(message.len, TtyRefusal.max);
            @memcpy(out.message[0..out.len], message[0..out.len]);
        }
        return Error.TtyFailed;
    };
    if (id < 0) return Error.TtyFailed;
    const pid = jsonIntField(obj, "pid") orelse return Error.TtyFailed;
    const port = jsonIntField(obj, "port") orelse return Error.TtyFailed;
    if (port <= 0 or port > std.math.maxInt(u16)) return Error.TtyFailed;
    return .{ .tty_id = id, .pid = pid, .port = @intCast(port) };
}

/// What the guest said, in words an operator can act on. The guest answers
/// "unknown request" when its agent predates the terminal action — the disk
/// was made from an older image — so the fix replaces the symptom.
pub fn refusalText(object: std.json.ObjectMap) []const u8 {
    const message = jsonStringField(object, "message") orelse return "the guest refused the terminal";
    if (std.mem.eql(u8, message, "unknown request")) {
        return "the workspace VM's guest agent is too old for terminals: rebuild the guest image and recreate the VM";
    }
    return message;
}

/// One piece of a terminal's output. An empty `data` with `eof` means "nothing
/// right now", which is what the caller's next poll asks again.
pub fn ttyRead(
    allocator: std.mem.Allocator,
    layout: Layout,
    tty_id: i64,
    max_bytes: usize,
) !TtyRead {
    const port = policy.ttyPort(tty_id) orelse return Error.TtyFailed;
    var frame_buf: [256]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"tty\",\"op\":\"read\",\"id\":1,\"max_bytes\":{d}}}",
        .{@min(max_bytes, policy.max_tty_chunk)},
    );
    // The guest process that owned the pty is what answered that port, so
    // nothing listening there IS the exit report — not a failed read.
    const text = oneShotPort(allocator, layout, port, frame, tty_call_guard_ms) catch |err| switch (err) {
        error.ConnectFailed, error.HandshakeRejected => return .{
            .data = try allocator.alloc(u8, 0),
            .eof = true,
            .exited = true,
            .exit_code = -1,
        },
        else => return err,
    };
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const b64 = jsonStringField(obj, "data_b64") orelse "";
    const data = try decodeTtyBytes(allocator, b64);
    return .{
        .data = data,
        .eof = jsonBoolField(obj, "eof"),
        .exited = jsonBoolField(obj, "exited"),
        .exit_code = jsonIntField(obj, "exit_code") orelse 0,
    };
}

fn decodeTtyBytes(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    if (b64.len == 0) return allocator.alloc(u8, 0);
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(b64) catch return Error.ProtocolViolation;
    if (size > policy.max_tty_chunk) return Error.ReplyTooLarge;
    const out = try allocator.alloc(u8, size);
    decoder.decode(out, b64) catch {
        allocator.free(out);
        return Error.ProtocolViolation;
    };
    return out;
}

/// Keystrokes into the terminal. Returns how many bytes the guest accepted.
pub fn ttyWrite(
    allocator: std.mem.Allocator,
    layout: Layout,
    tty_id: i64,
    data: []const u8,
) !usize {
    const port = policy.ttyPort(tty_id) orelse return Error.TtyFailed;
    if (data.len == 0 or data.len > policy.max_tty_chunk) return Error.WriteFailed;

    var head_buf: [96]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "{{\"type\":\"tty\",\"op\":\"write\",\"id\":1,\"data_b64\":\"", .{});
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const frame = try allocator.alloc(u8, head.len + encoded_len + 2);
    defer allocator.free(frame);
    @memcpy(frame[0..head.len], head);
    _ = std.base64.standard.Encoder.encode(frame[head.len..][0..encoded_len], data);
    const tail_at = head.len + encoded_len;
    frame[tail_at] = '"';
    frame[tail_at + 1] = '}';

    const text = oneShotPort(allocator, layout, port, frame, tty_call_guard_ms) catch |err| switch (err) {
        error.ConnectFailed, error.HandshakeRejected => return Error.TtyGone,
        else => return err,
    };
    defer allocator.free(text);

    var parsed = try parseObject(allocator, text);
    defer parsed.deinit();
    const accepted = jsonIntField(parsed.value.object, "bytes") orelse 0;
    if (accepted < 0) return Error.WriteFailed;
    return @intCast(accepted);
}

pub fn ttyResize(
    allocator: std.mem.Allocator,
    layout: Layout,
    tty_id: i64,
    cols: u16,
    rows: u16,
) !void {
    const port = policy.ttyPort(tty_id) orelse return Error.TtyFailed;
    var frame_buf: [256]u8 = undefined;
    const frame = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"type\":\"tty\",\"op\":\"resize\",\"id\":1,\"cols\":{d},\"rows\":{d}}}",
        .{ cols, rows },
    );
    // A window size for a terminal that is already gone is not a failure the
    // caller can act on.
    const text = oneShotPort(allocator, layout, port, frame, tty_call_guard_ms) catch |err| switch (err) {
        error.ConnectFailed, error.HandshakeRejected => return,
        else => return err,
    };
    allocator.free(text);
}

/// Close the terminal and kill its shell. A tty the guest already forgot has
/// nothing left to ask, so a refused close is success.
pub fn ttyClose(allocator: std.mem.Allocator, layout: Layout, tty_id: i64) !void {
    const port = policy.ttyPort(tty_id) orelse return;
    var frame_buf: [128]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buf, "{{\"type\":\"tty\",\"op\":\"close\",\"id\":1}}", .{});
    const text = oneShotPort(allocator, layout, port, frame, tty_call_guard_ms) catch |err| switch (err) {
        error.ConnectFailed, error.HandshakeRejected => return,
        else => return err,
    };
    allocator.free(text);
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

const testing = std.testing;

test "a guest that does not know the terminal action says what to do about it" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"type\":\"error\",\"message\":\"unknown request\"}", .{});
    defer parsed.deinit();

    const text = refusalText(parsed.value.object);
    try testing.expect(std.mem.indexOf(u8, text, "too old") != null);
    try testing.expect(std.mem.indexOf(u8, text, "recreate the VM") != null);
}

test "a guest that refuses for its own reason keeps its own words" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"type\":\"error\",\"message\":\"the guest is out of terminals\"}", .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("the guest is out of terminals", refusalText(parsed.value.object));
}

test "the CPU clock is read from the fields after the comm, whatever comm holds" {
    // A comm may contain spaces AND parentheses, so the fields are counted from
    // the LAST ')' — splitting on the first one reads the comm as numbers.
    const line = "4242 (fire (cracker) vmm) S 1 4242 4242 0 -1 4194304 1000 0 0 0 120 30 0 0 20 0 4 0 60000 0 0";
    try testing.expectEqual(@as(?u64, 150), parseStatCpuTicks(line));
}

test "a stat line that stops before stime reads as unknown, not as zero" {
    const short = "4242 (fc) S 1 4242 4242 0 -1 4194304 1000 0 0 0 120";
    try testing.expectEqual(@as(?u64, null), parseStatCpuTicks(short));
    try testing.expectEqual(@as(?u64, null), parseStatCpuTicks(""));
    try testing.expectEqual(@as(?u64, null), parseStatCpuTicks("garbage"));
}

test "the VmRSS line is the only one read, and kB survive the parse" {
    const status = "Name:\tfirecracker\nVmPeak:\t 3168812 kB\nVmRSS:\t  79460 kB\nThreads:\t9\n";
    try testing.expectEqual(@as(?u32, 79_460), parseRssKib(status));
    try testing.expectEqual(@as(?u32, null), parseRssKib("Name:\tfirecracker\n"));
}

test "a pid that is not there has no CPU clock and no RSS" {
    // 0 and negative are refused before /proc is touched at all.
    try testing.expectEqual(@as(?u64, null), cpuTicks(0));
    try testing.expectEqual(@as(?u32, null), rssMib(-1));
    // And a pid that cannot exist answers null rather than 0: "cannot tell".
    try testing.expectEqual(@as(?u64, null), cpuTicks(2_147_483_640));
}
