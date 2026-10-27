//! `pabrik-vm-agent` — guest PID 1: mount the pseudo filesystems, create the
//! device nodes this kernel lacks, then serve framed JSON over vsock (`hello`,
//! `exec`, `spawn`, `fs.*`, `tty open`, `shutdown`).

const std = @import("std");
const linux = std.os.linux;
const backoff = @import("backoff.zig");
const egress = @import("egress_env.zig");
const vsock = @import("vsock.zig");
const wire = @import("vm_wire");

const af_inet: u32 = 2;
const sock_stream: u32 = 1;
/// The accept loop's poll slice: long enough that an idle workspace sleeps.
const accept_slice_ms: i32 = 1000;
const max_frame = wire.max_frame;
const read_chunk: usize = 4096;
const arena_bytes: usize = 16 * 1024;
const max_argv: usize = 64;
/// The workspace is the tenant's own machine, so inside it they are root — the
/// same bargain a container makes; the host never runs a workload. Without it
/// `dnf install` in the workspace's own terminal demands superuser privileges.
const default_uid: u32 = 0;
const default_gid: u32 = 0;
const max_timeout_ms: u32 = 600_000;
const default_budget: usize = 256 * 1024;
/// `wait4`'s WNOHANG: probe must never block PID 1.
const wno_hang: u32 = 1;
/// Detached jobs log here, and a `read_log` reply carries at most this much of
/// one: 16 KiB of bytes is ~22 KiB of base64, comfortably inside `max_frame`.
const job_log_dir = "/tmp/pabrik";
const log_read_chunk: usize = 16 * 1024;
const reply_buf_bytes: usize = wire.max_frame;

/// The in-guest network forwarder: loopback, the resolver config, and the two
/// proxies the tenant's traffic leaves through.
const netd_path = "/usr/bin/pabrik-vm-netd";
/// `port.forward` carries one HTTP request in and one response out, in pieces.
const port_forward_chunk: usize = 32 * 1024;
const port_forward_cap: usize = 1024 * 1024;
/// A guest dev server that answers nothing must not hold PID 1 for long.
const port_forward_timeout = linux.timeval{ .sec = 5, .usec = 0 };

const hello_json = "{\"type\":\"hello\",\"agent\":\"pabrik-vm-agent\",\"version\":\"0.2\"}";
const bye_json = "{\"type\":\"bye\"}";

// ─── transport ───────────────────────────────────────────────────────────

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    _ = writeBytes(fd, bytes);
}

fn writeBytes(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn sleepMs(ms: u64) void {
    const ts = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&ts, null);
}

fn logLine(bytes: []const u8) void {
    writeAll(1, "[pabrik-vm-agent] ");
    writeAll(1, bytes);
    writeAll(1, "\n");
}

fn readExact(fd: linux.fd_t, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn writeFrame(fd: linux.fd_t, payload: []const u8) void {
    var header: [4]u8 = undefined;
    wire.frameHeader(payload.len, &header);
    writeAll(fd, &header);
    writeAll(fd, payload);
}

/// One reply frame built in a stack buffer, so no reply can outgrow the cap.
fn reply(fd: linux.fd_t, comptime fmt: []const u8, args: anytype) void {
    var buf: [reply_buf_bytes]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch {
        writeFrame(fd, "{\"type\":\"error\",\"message\":\"reply too large\"}");
        return;
    };
    writeFrame(fd, text);
}

// ─── guest setup ─────────────────────────────────────────────────────────

fn mountPseudo(fstype: [*:0]const u8, target: [*:0]const u8) bool {
    const rc = linux.mount("none", target, fstype, 0, 0);
    return linux.errno(rc) == .SUCCESS;
}

/// The stock CI kernel has no devtmpfs, so `/dev` is empty. PID 1 is root in
/// the guest and can create the nodes itself — cheaper than a custom kernel.
fn mknodNode(path: [*:0]const u8, kind: u32, major: u32, minor: u32) bool {
    const dev = (major << 8) | minor;
    const rc = linux.mknod(path, kind, @intCast(dev));
    return linux.errno(rc) == .SUCCESS;
}

fn ensureDev() void {
    _ = linux.mkdir("/dev", 0o755);
    const char_dev: u32 = 0o020000;
    var made: usize = 0;
    if (mknodNode("/dev/null", char_dev, 1, 3)) made += 1;
    if (mknodNode("/dev/zero", char_dev, 1, 5)) made += 1;
    if (mknodNode("/dev/full", char_dev, 1, 7)) made += 1;
    if (mknodNode("/dev/random", char_dev, 1, 8)) made += 1;
    if (mknodNode("/dev/urandom", char_dev, 1, 9)) made += 1;
    if (mknodNode("/dev/tty", char_dev, 5, 0)) made += 1;
    _ = linux.mkdir("/dev/pts", 0o755);
    if (mountPseudo("devpts", "/dev/pts")) made += 1;
    logLine(if (made > 0) "device nodes prepared" else "MISSING device nodes");
}

// ─── exec ────────────────────────────────────────────────────────────────

const ExecRequest = struct {
    id: i64 = 0,
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "/",
    timeout_ms: u32 = 10_000,
    max_output_bytes: usize = default_budget,
    uid: u32 = default_uid,
    gid: u32 = default_gid,
};

var arena: [arena_bytes]u8 = undefined;
var argv_ptrs: [max_argv + 1]?[*:0]const u8 = undefined;

/// Copy argv into one sentinel-terminated buffer. Returns null on overflow so
/// the caller reports an error frame instead of exec'ing something truncated.
fn buildArgv(args: []const []const u8) ?[*:null]const ?[*:0]const u8 {
    var off: usize = 0;
    if (args.len == 0 or args.len > max_argv) return null;
    for (args, 0..) |arg, i| {
        if (arg.len + 1 > arena.len - off) return null;
        @memcpy(arena[off..][0..arg.len], arg);
        arena[off + arg.len] = 0;
        argv_ptrs[i] = @ptrCast(arena[off..].ptr);
        off += arg.len + 1;
    }
    argv_ptrs[args.len] = null;
    return @ptrCast(&argv_ptrs);
}

fn cstr(src: []const u8, dst: []u8) ?[*:0]const u8 {
    if (src.len + 1 > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @ptrCast(dst.ptr);
}

/// What a workload's process is started with. The guest has no network device,
/// so the loopback proxy is the only egress: without these four a `git clone`
/// dials the internet directly and gets `ENETUNREACH`.
const exec_env = [_:null]?[*:0]const u8{
    "PATH=/bin:/usr/bin",
    "HOME=/workspace",
    "LANG=C",
    "TERM=dumb",
    egress.http_proxy,
    egress.https_proxy,
    egress.http_proxy_upper,
    egress.https_proxy_upper,
    egress.no_proxy,
    egress.no_proxy_upper,
    "ZIG_GLOBAL_CACHE_DIR=/opt/zig-cache",
};

fn execChild(req: *const ExecRequest, out_write: linux.fd_t, err_write: linux.fd_t) noreturn {
    var cwd_buf: [1024]u8 = undefined;
    _ = linux.setgroups(0, &[_]linux.gid_t{});
    _ = linux.setgid(req.gid);
    _ = linux.setuid(req.uid);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (cstr(req.cwd, &cwd_buf)) |cwd| _ = linux.chdir(cwd);
    _ = linux.dup2(out_write, 1);
    _ = linux.dup2(err_write, 2);
    _ = linux.close(out_write);
    _ = linux.close(err_write);
    const argv = buildArgv(req.argv);
    if (argv == null) {
        writeAll(2, "pabrik-vm-agent: argv too large\n");
        linux.exit(126);
    }
    _ = linux.execve(@ptrCast(argv_ptrs[0].?), argv.?, &exec_env);
    writeAll(2, "pabrik-vm-agent: exec failed\n");
    linux.exit(127);
}

fn pipePair(fds: *[2]linux.fd_t) bool {
    return linux.errno(linux.pipe2(fds, .{})) == .SUCCESS;
}

fn closeIfOpen(fd: linux.fd_t) void {
    if (fd >= 0) _ = linux.close(fd);
}

/// Fork/exec `req.argv` as a non-root uid and stream both pipes back until the
/// child exits, the deadline passes, or the output budget is spent. Budget is
/// enforced on the host's behalf: a flooding child loses output, not the host.
fn runExec(conn_fd: linux.fd_t, req: *const ExecRequest) void {
    const budget = if (req.max_output_bytes == 0) default_budget else req.max_output_bytes;
    const timeout_ms = if (req.timeout_ms > max_timeout_ms) max_timeout_ms else req.timeout_ms;

    var out_pipe: [2]linux.fd_t = .{ -1, -1 };
    var err_pipe: [2]linux.fd_t = .{ -1, -1 };
    if (!pipePair(&out_pipe) or !pipePair(&err_pipe)) {
        closeIfOpen(out_pipe[0]);
        closeIfOpen(out_pipe[1]);
        closeIfOpen(err_pipe[0]);
        closeIfOpen(err_pipe[1]);
        reply(conn_fd, "{{\"type\":\"exec.exit\",\"id\":{d},\"code\":-1,\"error\":\"pipe failed\"}}", .{req.id});
        return;
    }

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        closeIfOpen(out_pipe[0]);
        closeIfOpen(out_pipe[1]);
        closeIfOpen(err_pipe[0]);
        closeIfOpen(err_pipe[1]);
        reply(conn_fd, "{{\"type\":\"exec.exit\",\"id\":{d},\"code\":-1,\"error\":\"fork failed\"}}", .{req.id});
        return;
    }
    if (fork_rc == 0) execChild(req, out_pipe[1], err_pipe[1]);
    const child: linux.pid_t = @intCast(fork_rc);

    closeIfOpen(out_pipe[1]);
    closeIfOpen(err_pipe[1]);

    var fds = [_]linux.pollfd{
        .{ .fd = out_pipe[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = err_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };
    var open_count: usize = 2;
    var sent: usize = 0;
    var truncated = false;
    var timed_out = false;
    var elapsed_ms: u32 = 0;
    var buf: [read_chunk]u8 = undefined;
    var b64: [std.base64.standard.Encoder.calcSize(read_chunk)]u8 = undefined;

    while (open_count > 0) {
        const rc = linux.poll(&fds, fds.len, 100);
        if (linux.errno(rc) != .SUCCESS) break;
        elapsed_ms += 100;
        var read_any = false;
        for (&fds) |*pfd| {
            if (pfd.fd < 0) continue;
            if (pfd.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) continue;
            const n = linux.read(pfd.fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) {
                closeIfOpen(pfd.fd);
                pfd.fd = -1;
                open_count -= 1;
                continue;
            }
            read_any = true;
            const slice = buf[0..n];
            if (sent + slice.len > budget) {
                truncated = true;
                continue;
            }
            sent += slice.len;
            const kind = if (pfd.fd == out_pipe[0]) "stdout" else "stderr";
            const encoded = std.base64.standard.Encoder.encode(&b64, slice);
            reply(conn_fd, "{{\"type\":\"exec.{s}\",\"id\":{d},\"data_b64\":\"{s}\"}}", .{ kind, req.id, encoded });
        }
        if (elapsed_ms >= timeout_ms) {
            timed_out = true;
            _ = linux.kill(child, linux.SIG.KILL);
            break;
        }
    }

    closeIfOpen(out_pipe[0]);
    closeIfOpen(err_pipe[0]);

    var status: u32 = 0;
    _ = linux.wait4(child, &status, 0, null);
    const code: i64 = if (linux.W.IFEXITED(status)) @intCast(linux.W.EXITSTATUS(status)) else -1;

    if (timed_out) {
        reply(conn_fd, "{{\"type\":\"exec.timeout\",\"id\":{d},\"timeout_ms\":{d}}}", .{ req.id, timeout_ms });
    }
    reply(
        conn_fd,
        "{{\"type\":\"exec.exit\",\"id\":{d},\"code\":{d},\"bytes\":{d},\"truncated\":{s},\"timed_out\":{s}}}",
        .{ req.id, code, sent, if (truncated) "true" else "false", if (timed_out) "true" else "false" },
    );
}

// ─── detached jobs ───────────────────────────────────────────────────────

const SpawnRequest = struct {
    id: i64 = 0,
    argv: []const []const u8 = &.{},
    cwd: []const u8 = "/workspace",
    log_path: []const u8 = "",
    uid: u32 = default_uid,
    gid: u32 = default_gid,
};

/// The detached child: its own session (so a dead caller cannot take it down),
/// the log on both output streams, and the caller's uid — never root.
fn spawnChild(req: *const SpawnRequest, log_fd: linux.fd_t) noreturn {
    var cwd_buf: [1024]u8 = undefined;
    _ = linux.setsid();
    if (cstr(req.cwd, &cwd_buf)) |cwd| _ = linux.chdir(cwd);
    _ = linux.dup2(log_fd, 1);
    _ = linux.dup2(log_fd, 2);
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);
    if (log_fd > 2) _ = linux.close(log_fd);
    _ = linux.setgroups(0, &[_]linux.gid_t{});
    _ = linux.setgid(req.gid);
    _ = linux.setuid(req.uid);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    const argv = buildArgv(req.argv);
    if (argv == null) {
        writeAll(2, "pabrik-vm-agent: argv too large\n");
        linux.exit(126);
    }
    _ = linux.execve(@ptrCast(argv_ptrs[0].?), argv.?, &exec_env);
    writeAll(2, "pabrik-vm-agent: spawn exec failed\n");
    linux.exit(127);
}

/// Fork the job off and report its pid. The pid the caller is handed IS the
/// job's process-group id, which is what makes a tree stop one syscall.
fn runSpawn(conn_fd: linux.fd_t, req: *const SpawnRequest) void {
    if (req.argv.len == 0 or req.log_path.len == 0) {
        reply(conn_fd, "{{\"type\":\"spawn.error\",\"id\":{d},\"message\":\"argv and log_path are required\"}}", .{req.id});
        return;
    }
    _ = linux.mkdir(job_log_dir, 0o755);
    var log_buf: [1024]u8 = undefined;
    const log_z = cstr(req.log_path, &log_buf) orelse {
        reply(conn_fd, "{{\"type\":\"spawn.error\",\"id\":{d},\"message\":\"log path too long\"}}", .{req.id});
        return;
    };
    const open_rc = linux.open(log_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (linux.errno(open_rc) != .SUCCESS) {
        reply(conn_fd, "{{\"type\":\"spawn.error\",\"id\":{d},\"message\":\"cannot open the log\"}}", .{req.id});
        return;
    }
    const log_fd: linux.fd_t = @intCast(open_rc);

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        closeIfOpen(log_fd);
        reply(conn_fd, "{{\"type\":\"spawn.error\",\"id\":{d},\"message\":\"fork failed\"}}", .{req.id});
        return;
    }
    if (fork_rc == 0) spawnChild(req, log_fd);
    closeIfOpen(log_fd);
    reply(conn_fd, "{{\"type\":\"spawn.result\",\"id\":{d},\"pid\":{d}}}", .{ req.id, fork_rc });
}

/// Signal 0 is the existence probe: `EPERM` also means "it is there". A job
/// this agent forked is reaped FIRST, because a zombie still answers signal 0.
fn runProbe(conn_fd: linux.fd_t, id: i64, pid: i64) void {
    var status: u32 = 0;
    const reaped = linux.wait4(@intCast(pid), &status, wno_hang, null);
    const gone = linux.errno(reaped) == .SUCCESS and reaped != 0;
    const err = linux.errno(linux.syscall2(.kill, @intCast(pid), 0));
    const alive = !gone and (err == .SUCCESS or err == .PERM);
    reply(conn_fd, "{{\"type\":\"probe.result\",\"id\":{d},\"alive\":{s}}}", .{ id, if (alive) "true" else "false" });
}

/// The job's process GROUP first, then the pid itself: a job that forked keeps
/// its workers in the group, and killing only the leader leaves them running.
fn runSignal(conn_fd: linux.fd_t, id: i64, pid: i64, sig: i64) void {
    const pid_u: usize = @intCast(pid);
    const group: usize = @bitCast(-@as(isize, @intCast(pid)));
    var sent = linux.errno(linux.syscall2(.kill, group, @intCast(sig))) == .SUCCESS;
    if (linux.errno(linux.syscall2(.kill, pid_u, @intCast(sig))) == .SUCCESS) sent = true;
    reply(conn_fd, "{{\"type\":\"signal.result\",\"id\":{d},\"sent\":{s}}}", .{ id, if (sent) "true" else "false" });
}

fn logChunkMissing(conn_fd: linux.fd_t, id: i64) void {
    reply(conn_fd, "{{\"type\":\"log.chunk\",\"id\":{d},\"missing\":true}}", .{id});
}

/// One positional read of a job's log. `eof` is derived from the file's own
/// size, so the caller's cursor and the end of the file cannot disagree.
fn runReadLog(conn_fd: linux.fd_t, id: i64, path: []const u8, offset: i64, max_bytes: usize) void {
    var path_buf: [1024]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse return logChunkMissing(conn_fd, id);
    const open_rc = linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return logChunkMissing(conn_fd, id);
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    // `lseek` to the end is the size: cheaper than a stat, and the fd is ours
    // alone for the length of this request.
    const end_rc = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end_rc) != .SUCCESS) return logChunkMissing(conn_fd, id);
    const size: i64 = @intCast(end_rc);
    if (offset >= size) {
        reply(conn_fd, "{{\"type\":\"log.chunk\",\"id\":{d},\"size\":{d},\"eof\":true,\"data_b64\":\"\"}}", .{ id, size });
        return;
    }

    const want: usize = @intCast(@min(size - offset, @as(i64, @intCast(max_bytes))));
    const want_capped: usize = @min(want, log_read_chunk);
    var buf: [log_read_chunk]u8 = undefined;
    const read_rc = linux.pread(fd, &buf, want_capped, offset);
    if (linux.errno(read_rc) != .SUCCESS) return logChunkMissing(conn_fd, id);
    const got = buf[0..read_rc];

    var b64: [std.base64.standard.Encoder.calcSize(log_read_chunk)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, got);
    const at_end = offset + @as(i64, @intCast(got.len)) >= size;
    reply(
        conn_fd,
        "{{\"type\":\"log.chunk\",\"id\":{d},\"size\":{d},\"eof\":{s},\"data_b64\":\"{s}\"}}",
        .{ id, size, if (at_end) "true" else "false", encoded },
    );
}

// ─── file RPC ────────────────────────────────────────────────────────────

const workspace_root = "/workspace";
const fs_read_chunk: usize = wire.max_reply_chunk;
const max_fs_path: usize = 1024;
/// `RESOLVE_BENEATH`: every component is resolved under the workspace fd, so a
/// symlink that leaves the workspace is `EXDEV` rather than a read of something
/// else. The kernel's answer, not a string check, is what contains the path.
const resolve_beneath: u64 = 0x08;
const o_directory: u64 = 0o200000;
/// `AT_REMOVEDIR`: `unlinkat`'s "this is a directory" flag.
const at_removedir: u64 = 0x200;
const fs_write_chunk: usize = 32 * 1024;
const o_wronly: u64 = 0o1;
const o_creat: u64 = 0o100;
const o_trunc: u64 = 0o1000;
/// What the guest creates: uid 1000 owns the tree it works in.
const fs_file_mode: u64 = 0o644;
/// A walk is bounded in both directions — how deep it goes and how many
/// entries it reports — so no tree can be walked into an endless reply.
const max_walk_depth: u32 = 32;
const max_walk_entries: usize = 20_000;
/// Entries per `fs.walk` reply frame. The reply is streamed: the caller keeps
/// reading until a frame says `done`.
const fs_walk_frame_entries: usize = 48;
/// `getdents64`'s d_type for the three kinds a walk names.
const dt_dir: u8 = 4;
const dt_reg: u8 = 8;
const dt_lnk: u8 = 10;

const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

/// The agent's own containment rule, carried here because this binary imports
/// nothing but std: no absolute path, no `.`/`..` segment, no NUL.
fn relPathOk(path: []const u8) bool {
    if (path.len == 0 or path.len > max_fs_path) return false;
    if (path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or segment.len > 255) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == 0 or c == '\\') return false;
        }
    }
    return true;
}

fn openWorkspaceRoot() ?linux.fd_t {
    const rc = linux.open(workspace_root, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn openBeneath(root_fd: linux.fd_t, path: [*:0]const u8, flags: u64) ?linux.fd_t {
    return openBeneathMode(root_fd, path, flags, 0);
}

/// The same open, with the `mode` an `O_CREAT` open requires. Kept apart so a
/// creation and a read cannot be spelled by accident.
fn openBeneathMode(root_fd: linux.fd_t, path: [*:0]const u8, flags: u64, mode: u64) ?linux.fd_t {
    var how = OpenHow{ .flags = flags, .mode = mode, .resolve = resolve_beneath };
    const rc = linux.syscall6(
        .openat2,
        @as(usize, @bitCast(@as(isize, root_fd))),
        @intFromPtr(path),
        @intFromPtr(&how),
        @sizeOf(OpenHow),
        0,
        0,
    );
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// The file descriptor a `fs.read` path was opened through, or null with the
/// refusal already sent.
fn fsOpen(conn_fd: linux.fd_t, id: i64, path: []const u8, flags: u64) ?struct { root: linux.fd_t, file: linux.fd_t } {
    if (!relPathOk(path)) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is not relative to the workspace\"}}", .{id});
        return null;
    }
    var path_buf: [max_fs_path + 1]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path too long\"}}", .{id});
        return null;
    };
    const root = openWorkspaceRoot() orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the workspace is not mounted\"}}", .{id});
        return null;
    };
    const file = openBeneath(root, path_z, flags) orelse {
        _ = linux.close(root);
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"missing\":true,\"message\":\"no such file\"}}", .{id});
        return null;
    };
    return .{ .root = root, .file = file };
}

/// `fs.stat`: the kind and size of one path, resolved beneath the workspace.
/// "Is it a directory" is asked by opening it as one, which needs no stat
/// structure and cannot disagree with what the read would then do.
fn runFsStat(conn_fd: linux.fd_t, id: i64, path: []const u8) void {
    if (!relPathOk(path)) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is not relative to the workspace\"}}", .{id});
        return;
    }
    var path_buf: [max_fs_path + 1]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse return;
    const root = openWorkspaceRoot() orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the workspace is not mounted\"}}", .{id});
        return;
    };
    defer _ = linux.close(root);

    if (openBeneath(root, path_z, o_directory)) |dir| {
        _ = linux.close(dir);
        reply(conn_fd, "{{\"type\":\"fs.stat\",\"id\":{d},\"kind\":\"dir\",\"size\":0}}", .{id});
        return;
    }
    const file = openBeneath(root, path_z, 0) orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"missing\":true,\"message\":\"no such file\"}}", .{id});
        return;
    };
    defer _ = linux.close(file);
    const end_rc = linux.lseek(file, 0, linux.SEEK.END);
    const size: i64 = if (linux.errno(end_rc) == .SUCCESS) @intCast(end_rc) else 0;
    reply(conn_fd, "{{\"type\":\"fs.stat\",\"id\":{d},\"kind\":\"file\",\"size\":{d}}}", .{ id, size });
}

/// `fs.read`: one positional piece of a file, base64 in the reply. `eof` is
/// derived from the file's own size, so a cursor and the end cannot disagree.
fn runFsRead(conn_fd: linux.fd_t, id: i64, path: []const u8, offset: i64, max_bytes: usize) void {
    const opened = fsOpen(conn_fd, id, path, 0) orelse return;
    defer _ = linux.close(opened.root);
    defer _ = linux.close(opened.file);

    const end_rc = linux.lseek(opened.file, 0, linux.SEEK.END);
    if (linux.errno(end_rc) != .SUCCESS) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot size the file\"}}", .{id});
        return;
    }
    const size: i64 = @intCast(end_rc);
    if (offset >= size) {
        reply(conn_fd, "{{\"type\":\"fs.read\",\"id\":{d},\"size\":{d},\"eof\":true,\"data_b64\":\"\"}}", .{ id, size });
        return;
    }

    const want: usize = @intCast(@min(size - offset, @as(i64, @intCast(max_bytes))));
    const capped: usize = @min(want, fs_read_chunk);
    var buf: [fs_read_chunk]u8 = undefined;
    const read_rc = linux.pread(opened.file, &buf, capped, offset);
    if (linux.errno(read_rc) != .SUCCESS) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot read the file\"}}", .{id});
        return;
    }
    const got = buf[0..read_rc];
    var b64: [std.base64.standard.Encoder.calcSize(fs_read_chunk)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, got);
    const at_end = offset + @as(i64, @intCast(got.len)) >= size;
    reply(
        conn_fd,
        "{{\"type\":\"fs.read\",\"id\":{d},\"size\":{d},\"eof\":{s},\"data_b64\":\"{s}\"}}",
        .{ id, size, if (at_end) "true" else "false", encoded },
    );
}

/// `fs.remove`: one file, or one EMPTY directory. A recursive delete is the
/// caller's loop, so a mistake here cannot take a tree with it. The kernel says
/// which it is: `EISDIR` is the answer to "this was a directory after all".
fn runFsRemove(conn_fd: linux.fd_t, id: i64, path: []const u8) void {
    if (!relPathOk(path)) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is not relative to the workspace\"}}", .{id});
        return;
    }
    var path_buf: [max_fs_path + 1]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse return;
    const root = openWorkspaceRoot() orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the workspace is not mounted\"}}", .{id});
        return;
    };
    defer _ = linux.close(root);

    const dirfd: usize = @bitCast(@as(isize, root));
    const as_file = linux.errno(linux.syscall3(.unlinkat, dirfd, @intFromPtr(path_z), 0));
    if (as_file == .SUCCESS) {
        reply(conn_fd, "{{\"type\":\"fs.remove.ok\",\"id\":{d}}}", .{id});
        return;
    }
    if (as_file == .ISDIR) {
        const as_dir = linux.errno(linux.syscall3(.unlinkat, dirfd, @intFromPtr(path_z), at_removedir));
        if (as_dir == .SUCCESS) {
            reply(conn_fd, "{{\"type\":\"fs.remove.ok\",\"id\":{d}}}", .{id});
            return;
        }
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the directory is not empty\"}}", .{id});
        return;
    }
    if (as_file == .NOENT or as_file == .NOTDIR) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"missing\":true,\"message\":\"no such file\"}}", .{id});
        return;
    }
    reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot remove\"}}", .{id});
}

/// Every parent directory a write's path needs, each made under a fd the
/// kernel already resolved BENEATH the workspace: a symlinked segment is
/// `EXDEV`, never a directory somewhere else. Returns the deepest parent.
fn ensureParents(root_fd: linux.fd_t, path: []const u8) ?linux.fd_t {
    var current = root_fd;
    var owned = false;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, start, '/')) |slash| {
        const segment = path[start..slash];
        var seg_buf: [256]u8 = undefined;
        const seg_z = cstr(segment, &seg_buf) orelse return null;
        const child = openBeneath(current, seg_z, o_directory) orelse blk: {
            const made = linux.mkdirat(@intCast(current), seg_z, 0o755);
            const err = linux.errno(made);
            if (err != .SUCCESS and err != .EXIST) return null;
            break :blk openBeneath(current, seg_z, o_directory) orelse return null;
        };
        if (owned) _ = linux.close(current);
        current = child;
        owned = true;
        start = slash + 1;
    }
    return current;
}

/// `fs.write`: one positional piece of a file, CREATED by the first piece and
/// extended by the rest. The bytes are decoded before anything is opened, so a
/// bad payload cannot leave a truncated file behind.
fn runFsWrite(
    conn_fd: linux.fd_t,
    id: i64,
    path: []const u8,
    offset: i64,
    data_b64: []const u8,
    create_dirs: bool,
    truncate: bool,
) void {
    if (!relPathOk(path)) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is not relative to the workspace\"}}", .{id});
        return;
    }
    if (offset < 0) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"offset must not be negative\"}}", .{id});
        return;
    }
    var path_buf: [max_fs_path + 1]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path too long\"}}", .{id});
        return;
    };

    var data_buf: [fs_write_chunk]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const data_len = decoder.calcSizeForSlice(data_b64) catch {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"data is not base64\"}}", .{id});
        return;
    };
    if (data_len > fs_write_chunk) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"one write piece is too large\"}}", .{id});
        return;
    }
    decoder.decode(data_buf[0..data_len], data_b64) catch {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"data is not base64\"}}", .{id});
        return;
    };

    const root = openWorkspaceRoot() orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the workspace is not mounted\"}}", .{id});
        return;
    };
    defer _ = linux.close(root);

    if (create_dirs) {
        const parents = ensureParents(root, path) orelse {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot create the parent directory\"}}", .{id});
            return;
        };
        if (parents != root) _ = linux.close(parents);
    }

    var flags = o_wronly | o_creat;
    if (offset == 0 and truncate) flags |= o_trunc;
    const file = openBeneathMode(root, path_z, flags, fs_file_mode) orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot open the file for writing\"}}", .{id});
        return;
    };
    defer _ = linux.close(file);

    if (data_len > 0) {
        const written = linux.pwrite(file, data_buf[0..data_len].ptr, data_len, offset);
        if (linux.errno(written) != .SUCCESS or written != data_len) {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"cannot write the file\"}}", .{id});
            return;
        }
    }
    reply(
        conn_fd,
        "{{\"type\":\"fs.write.ok\",\"id\":{d},\"size\":{d},\"offset\":{d}}}",
        .{ id, data_len, offset + @as(i64, @intCast(data_len)) },
    );
}

/// One directory the walk has still to enter: its workspace-relative path and
/// how deep it sits. The whole walk's state is this array.
const WalkDir = struct {
    len: usize = 0,
    depth: u32 = 0,
    buf: [max_fs_path]u8 = undefined,

    fn path(self: *const WalkDir) []const u8 {
        return self.buf[0..self.len];
    }
};

const walk_frame_bytes: usize = wire.max_frame - 8 * 1024;

/// A streamed `fs.walk` reply. Entries are appended until the frame is full or
/// the per-frame cap is reached, then the frame is written and a fresh one
/// starts — the last one is the caller's `done`.
const WalkOut = struct {
    conn_fd: linux.fd_t,
    id: i64,
    frame: [walk_frame_bytes]u8 = undefined,
    off: usize = 0,
    in_frame: usize = 0,

    fn start(self: *WalkOut) void {
        var header: [96]u8 = undefined;
        const text = std.fmt.bufPrint(
            &header,
            "{{\"type\":\"fs.walk\",\"id\":{d},\"done\":false,\"entries\":[",
            .{self.id},
        ) catch return;
        @memcpy(self.frame[0..text.len], text);
        self.off = text.len;
        self.in_frame = 0;
    }

    fn full(self: *const WalkOut, path_len: usize) bool {
        // A worst case of six bytes per path byte leaves room for escaping.
        return self.in_frame == fs_walk_frame_entries or self.off + path_len * 6 + 64 >= self.frame.len;
    }

    /// What has been appended so far, as one complete frame.
    fn flush(self: *WalkOut) void {
        if (self.in_frame == 0) return;
        self.frame[self.off] = ']';
        self.frame[self.off + 1] = '}';
        writeFrame(self.conn_fd, self.frame[0 .. self.off + 2]);
        self.start();
    }

    fn append(self: *WalkOut, path: []const u8, kind: []const u8) bool {
        if (self.full(path.len)) return false;
        if (self.in_frame > 0) {
            self.frame[self.off] = ',';
            self.off += 1;
        }
        const prefix = "{\"path\":";
        @memcpy(self.frame[self.off..][0..prefix.len], prefix);
        self.off += prefix.len;
        if (!appendJsonString(&self.frame, &self.off, path)) return false;
        const kind_prefix = ",\"kind\":\"";
        @memcpy(self.frame[self.off..][0..kind_prefix.len], kind_prefix);
        self.off += kind_prefix.len;
        @memcpy(self.frame[self.off..][0..kind.len], kind);
        self.off += kind.len;
        self.frame[self.off] = '"';
        self.frame[self.off + 1] = '}';
        self.off += 2;
        self.in_frame += 1;
        return true;
    }

    /// The frame that ends the stream, whatever it carries.
    fn done(self: *WalkOut, count: usize, truncated: bool) void {
        reply(
            self.conn_fd,
            "{{\"type\":\"fs.walk\",\"id\":{d},\"done\":true,\"entries\":[],\"count\":{d},\"truncated\":{s}}}",
            .{ self.id, count, if (truncated) "true" else "false" },
        );
    }
};

fn kindName(dtype: u8) []const u8 {
    return switch (dtype) {
        dt_dir => "dir",
        dt_reg => "file",
        dt_lnk => "link",
        else => "other",
    };
}

/// A quoted JSON string, escaped, into `dst` at `off`. False when it does not
/// fit: the caller then flushes the frame and appends again.
fn appendJsonString(dst: []u8, off: *usize, text: []const u8) bool {
    if (off.* + 1 > dst.len) return false;
    dst[off.*] = '"';
    off.* += 1;
    for (text) |byte| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escape) |escaped| {
            if (off.* + escaped.len > dst.len) return false;
            @memcpy(dst[off.*..][0..escaped.len], escaped);
            off.* += escaped.len;
        } else if (byte < 0x20) {
            if (off.* + 6 > dst.len) return false;
            const hex = "0123456789abcdef";
            dst[off.*] = '\\';
            dst[off.* + 1] = 'u';
            dst[off.* + 2] = '0';
            dst[off.* + 3] = '0';
            dst[off.* + 4] = hex[byte >> 4];
            dst[off.* + 5] = hex[byte & 0x0f];
            off.* += 6;
        } else {
            if (off.* + 1 > dst.len) return false;
            dst[off.*] = byte;
            off.* += 1;
        }
    }
    if (off.* + 1 > dst.len) return false;
    dst[off.*] = '"';
    off.* += 1;
    return true;
}

/// The path an openat2 call is given: the workspace root itself is named "."
/// on the wire, because an empty path is a missing one to the kernel.
fn walkPathZ(path: []const u8, buf: []u8) ?[*:0]const u8 {
    return cstr(if (path.len == 0) "." else path, buf);
}

/// `fs.walk`: a bounded, depth-first listing of the workspace beneath `path`,
/// streamed one frame at a time. Each entry names a path RELATIVE to the
/// workspace and its kind; a size is what `fs.stat` is for.
fn runFsWalk(conn_fd: linux.fd_t, id: i64, path: []const u8, max_depth: u32, max_entries: usize) void {
    if (path.len > 0 and !relPathOk(path)) {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is not relative to the workspace\"}}", .{id});
        return;
    }
    const root = openWorkspaceRoot() orelse {
        reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"the workspace is not mounted\"}}", .{id});
        return;
    };
    defer _ = linux.close(root);

    // The starting directory must be one the walk can enter: a file or a
    // missing path is an error, not an empty listing.
    {
        var root_rel_buf: [max_fs_path + 1]u8 = undefined;
        const path_z = walkPathZ(path, &root_rel_buf) orelse return;
        const opened = openBeneath(root, path_z, o_directory) orelse {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"missing\":true,\"message\":\"no such directory\"}}", .{id});
            return;
        };
        _ = linux.close(opened);
    }

    var out = WalkOut{ .conn_fd = conn_fd, .id = id };
    out.start();

    var stack: [max_walk_depth + 1]WalkDir = undefined;
    var top: usize = 1;
    stack[0] = .{ .depth = 0, .len = path.len };
    @memcpy(stack[0].buf[0..path.len], path);

    var scratch: [max_fs_path + 1]u8 = undefined;
    var dirent_buf: [16 * 1024]u8 = undefined;
    var child_buf: [max_fs_path]u8 = undefined;
    var emitted: usize = 0;
    var truncated = false;
    var gave_up = false;

    walk: while (top > 0) {
        top -= 1;
        // The slot just popped is reused by the next push, so the directory
        // being scanned is copied out of the stack first.
        const current = stack[top];
        const dir_rel = current.path();
        const dir_z = walkPathZ(dir_rel, &scratch) orelse continue;
        const dir_fd = openBeneath(root, dir_z, o_directory) orelse continue;
        defer _ = linux.close(dir_fd);

        read_dir: while (true) {
            const n = linux.getdents64(dir_fd, &dirent_buf, dirent_buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break :read_dir;
            var at: usize = 0;
            while (at < n) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&dirent_buf[at]);
                const reclen = entry.reclen;
                if (reclen == 0) break :read_dir;
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                at += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (emitted == max_entries) {
                    truncated = true;
                    break :walk;
                }
                const child_len = if (dir_rel.len == 0) name.len else dir_rel.len + 1 + name.len;
                if (child_len > max_fs_path) continue;
                var child: []const u8 = undefined;
                if (dir_rel.len == 0) {
                    @memcpy(child_buf[0..name.len], name);
                    child = child_buf[0..name.len];
                } else {
                    @memcpy(child_buf[0..dir_rel.len], dir_rel);
                    child_buf[dir_rel.len] = '/';
                    @memcpy(child_buf[dir_rel.len + 1 ..][0..name.len], name);
                    child = child_buf[0 .. dir_rel.len + 1 + name.len];
                }
                const kind = kindName(entry.type);
                if (!out.append(child, kind)) {
                    out.flush();
                    if (!out.append(child, kind)) {
                        // A path that cannot fit a frame on its own: drop it
                        // rather than spin on it forever.
                        continue;
                    }
                }
                emitted += 1;
                if (entry.type == dt_dir and current.depth + 1 < max_depth) {
                    if (top >= stack.len) {
                        // Depth and stack travel together; this is belt and
                        // braces so a bad depth cannot write past the array.
                        gave_up = true;
                        break :walk;
                    }
                    stack[top] = .{ .depth = current.depth + 1, .len = child_len };
                    @memcpy(stack[top].buf[0..child_len], child);
                    top += 1;
                }
            }
        }
    }

    out.flush();
    out.done(emitted, truncated or gave_up);
}

// ─── interactive terminals ───────────────────────────────────────────────

/// Every terminal answers on its OWN vsock port. The agent serves one
/// connection at a time, so a terminal sharing port 5000 would freeze for as
/// long as any `exec` the tenant started — including the agent's own commands.
const tty_port_base: u32 = 5100;
const max_ttys: usize = 8;
const tty_chunk: usize = 32 * 1024;
/// `/dev/ptmx` is devtmpfs's node; the slave the kernel allocates appears under
/// the devpts mount at `/dev/pts/<n>`, owned by whoever opened the master.
const tty_ptmx = "/dev/ptmx";
const tty_pts_dir = "/dev/pts/";
const tty_shell = "/bin/sh";
const tty_cwd = "/workspace";

/// `TIOCSPTLCK` (unlock the slave), `TIOCGPTN` (which slave), `TIOCSCTTY` (this
/// pty is my controlling terminal), `TIOCSWINSZ` (window size).
const tiocsptlck: u32 = 0x40045431;
const tiocgptn: u32 = 0x80045430;
const tiocsctty: u32 = 0x540E;
const tiocswinsz: u32 = 0x5414;

const tty_min_dim: u16 = 2;
const tty_max_dim: u16 = 1000;
/// A terminal host reports before it serves; this is how long the agent waits
/// for that report before declaring it dead.
const tty_report_deadline_ms: u32 = 5_000;

const WinSize = extern struct { rows: u16, cols: u16, xpixel: u16, ypixel: u16 };

const tty_env = [_:null]?[*:0]const u8{
    "PATH=/bin:/usr/bin",
    "HOME=/workspace",
    "LANG=C",
    "TERM=xterm-256color",
    "PS1=\\w \\$ ",
    egress.http_proxy,
    egress.https_proxy,
    egress.http_proxy_upper,
    egress.https_proxy_upper,
    egress.no_proxy,
    egress.no_proxy_upper,
    "ZIG_GLOBAL_CACHE_DIR=/opt/zig-cache",
};

/// One live terminal: the agent's handle on the process that owns it. The pty
/// and the shell belong to that process, never to PID 1.
const TtySlot = struct {
    used: bool = false,
    host_pid: i64 = 0,
};

var tty_slots: [max_ttys]TtySlot = [_]TtySlot{.{}} ** max_ttys;

fn ttyWindowOk(cols: u16, rows: u16) bool {
    return cols >= tty_min_dim and cols <= tty_max_dim and
        rows >= tty_min_dim and rows <= tty_max_dim;
}

/// A shell may start at `/workspace` or anywhere inside it. No `..` segment,
/// so nothing resolves above the tenant's own tree.
fn ttyCwdOk(cwd: []const u8) bool {
    if (std.mem.eql(u8, cwd, tty_cwd)) return true;
    const prefix = tty_cwd ++ "/";
    if (!std.mem.startsWith(u8, cwd, prefix)) return false;
    var it = std.mem.splitScalar(u8, cwd[prefix.len..], '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

/// Reap the terminal hosts that died since the last open, so a slot is freed by
/// the same call that wants one.
fn ttyReapDead() void {
    for (&tty_slots) |*slot| {
        if (!slot.used) continue;
        var status: u32 = 0;
        const rc = linux.wait4(@intCast(slot.host_pid), &status, wno_hang, null);
        if (linux.errno(rc) == .SUCCESS and rc != 0) slot.* = .{};
    }
}

fn ttyFreeSlot() ?usize {
    for (&tty_slots, 0..) |*slot, i| {
        if (!slot.used) return i;
    }
    return null;
}

fn ttySetWinsize(master: linux.fd_t, cols: u16, rows: u16) bool {
    var win = WinSize{ .rows = rows, .cols = cols, .xpixel = 0, .ypixel = 0 };
    return linux.errno(linux.ioctl(master, tiocswinsz, @intFromPtr(&win))) == .SUCCESS;
}

fn vsockListen(port: u32) ?linux.fd_t {
    return switch (vsock.listen(port, wire.cid_any, 4)) {
        .fd => |fd| fd,
        .errno => null,
    };
}

/// Tell the agent why no terminal exists, then leave. The agent forwards this
/// frame, so a caller reads the guest's own reason rather than a timeout.
fn ttyFail(status_fd: linux.fd_t, message: []const u8) noreturn {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "{{\"type\":\"tty.error\",\"id\":0,\"message\":\"{s}\"}}",
        .{message},
    ) catch "{\"type\":\"tty.error\",\"id\":0,\"message\":\"terminal setup failed\"}";
    writeFrame(status_fd, text);
    linux.exit(1);
}

/// The shell side of a terminal: its own session, the pty as its controlling
/// terminal, the caller's uid — never root — and the workspace as its cwd.
fn ttyShellChild(slave_number: u32, cwd: []const u8) noreturn {
    var path_buf: [64]u8 = undefined;
    const slave_path = std.fmt.bufPrintZ(&path_buf, "{s}{d}", .{ tty_pts_dir, slave_number }) catch linux.exit(127);
    if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(127);
    const slave_rc = linux.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(slave_rc) != .SUCCESS) linux.exit(127);
    const slave: linux.fd_t = @intCast(slave_rc);
    if (linux.errno(linux.ioctl(slave, tiocsctty, 0)) != .SUCCESS) linux.exit(127);
    _ = linux.dup2(slave, 0);
    _ = linux.dup2(slave, 1);
    _ = linux.dup2(slave, 2);
    if (slave > 2) _ = linux.close(slave);

    var cwd_buf: [1024]u8 = undefined;
    if (cstr(cwd, &cwd_buf)) |dir| _ = linux.chdir(dir);
    _ = linux.setgroups(0, &[_]linux.gid_t{});
    _ = linux.setgid(default_gid);
    _ = linux.setuid(default_uid);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);

    const argv = [_:null]?[*:0]const u8{ tty_shell, null };
    _ = linux.execve(tty_shell, &argv, &tty_env);
    writeAll(2, "pabrik-vm-agent: terminal shell exec failed\n");
    linux.exit(127);
}

/// Kill the shell's whole session and wait for it. The shell leads its own
/// session, so its pid is its process group.
fn ttyKill(master: linux.fd_t, shell_pid: i64) void {
    const group: usize = @bitCast(-@as(isize, @intCast(shell_pid)));
    _ = linux.syscall2(.kill, group, @intFromEnum(linux.SIG.KILL));
    _ = linux.syscall2(.kill, @intCast(shell_pid), @intFromEnum(linux.SIG.KILL));
    var status: u32 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const rc = linux.wait4(@intCast(shell_pid), &status, wno_hang, null);
        if (linux.errno(rc) == .SUCCESS and rc != 0) break;
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    _ = linux.close(master);
}

/// One `read`: whatever the pty has right now, plus the exit state. Never
/// blocks — an empty answer is the caller's cue to ask again.
fn ttyReplyRead(conn_fd: linux.fd_t, master: linux.fd_t, shell_pid: i64, max_bytes: usize) void {
    var exited = false;
    var status: u32 = 0;
    const reaped = linux.wait4(@intCast(shell_pid), &status, wno_hang, null);
    if (linux.errno(reaped) == .SUCCESS and reaped != 0) exited = true;
    const code: i64 = if (!exited)
        0
    else if (linux.W.IFEXITED(status))
        @intCast(linux.W.EXITSTATUS(status))
    else
        -1;

    var chunk: [tty_chunk]u8 = undefined;
    var got: usize = 0;
    var pfd = [_]linux.pollfd{.{ .fd = master, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.errno(linux.poll(&pfd, 1, 0)) == .SUCCESS and
        pfd[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0)
    {
        const rc = linux.read(master, &chunk, @min(max_bytes, chunk.len));
        const err = linux.errno(rc);
        if (err == .SUCCESS) {
            // Zero bytes IS end-of-file; a short read is just a short read.
            if (rc > 0) got = rc else exited = true;
        } else if (err == .IO) {
            // EIO: every slave descriptor is closed, so the shell is gone.
            exited = true;
        }
    }

    if (got == 0) {
        reply(conn_fd, "{{\"type\":\"tty.data\",\"id\":1,\"eof\":true,\"exited\":{s},\"exit_code\":{d},\"data_b64\":\"\"}}", .{
            if (exited) "true" else "false",
            code,
        });
        return;
    }
    var b64: [std.base64.standard.Encoder.calcSize(tty_chunk)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, chunk[0..got]);
    reply(conn_fd, "{{\"type\":\"tty.data\",\"id\":1,\"eof\":false,\"exited\":{s},\"exit_code\":{d},\"data_b64\":\"{s}\"}}", .{
        if (exited) "true" else "false",
        code,
        encoded,
    });
}

fn ttyReplyWrite(conn_fd: linux.fd_t, master: linux.fd_t, data_b64: []const u8) void {
    var chunk: [tty_chunk]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"data is not base64\"}}", .{});
        return;
    };
    if (size > chunk.len) {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"one write piece is too large\"}}", .{});
        return;
    }
    std.base64.standard.Decoder.decode(chunk[0..size], data_b64) catch {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"data is not base64\"}}", .{});
        return;
    };
    var written: usize = 0;
    if (size > 0) {
        const rc = linux.write(master, chunk[0..size].ptr, size);
        if (linux.errno(rc) == .SUCCESS and rc > 0) written = rc;
    }
    reply(conn_fd, "{{\"type\":\"tty.wrote\",\"id\":1,\"bytes\":{d}}}", .{written});
}

/// One request on a terminal's own port. Returns false when the terminal is
/// finished and its host should go away.
fn ttyServeOne(conn_fd: linux.fd_t, master: linux.fd_t, shell_pid: i64) bool {
    var header: [4]u8 = undefined;
    if (!readExact(conn_fd, &header)) return true;
    const len = wire.framePayloadLen(&header);
    if (len == 0 or len > max_frame) return true;
    var payload: [max_frame]u8 = undefined;
    if (!readExact(conn_fd, payload[0..len])) return true;

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload[0..len], .{}) catch {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"bad json frame\"}}", .{});
        return true;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"frame is not an object\"}}", .{});
            return true;
        },
    };
    const op = if (obj.get("op")) |v| (if (v == .string) v.string else "") else "";

    if (std.mem.eql(u8, op, "read")) {
        const asked = if (obj.get("max_bytes")) |v| asUsize(v, tty_chunk) else tty_chunk;
        ttyReplyRead(conn_fd, master, shell_pid, @min(asked, tty_chunk));
        return true;
    }
    if (std.mem.eql(u8, op, "write")) {
        const data_b64 = if (obj.get("data_b64")) |v| (if (v == .string) v.string else "") else "";
        ttyReplyWrite(conn_fd, master, data_b64);
        return true;
    }
    if (std.mem.eql(u8, op, "resize")) {
        const cols = asU16(if (obj.get("cols")) |v| v else .{ .integer = 0 }, 0);
        const rows = asU16(if (obj.get("rows")) |v| v else .{ .integer = 0 }, 0);
        if (!ttyWindowOk(cols, rows)) {
            reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"cols/rows are out of range\"}}", .{});
            return true;
        }
        _ = ttySetWinsize(master, cols, rows);
        reply(conn_fd, "{{\"type\":\"tty.resized\",\"id\":1}}", .{});
        return true;
    }
    if (std.mem.eql(u8, op, "close")) {
        reply(conn_fd, "{{\"type\":\"tty.closed\",\"id\":1}}", .{});
        return false;
    }
    reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":1,\"message\":\"unknown terminal request\"}}", .{});
    return true;
}

/// The process that owns one terminal: it creates the pty, forks the shell,
/// binds the terminal's own vsock port, and serves until the terminal closes.
fn ttyHost(status_fd: linux.fd_t, request_id: i64, slot: usize, cols: u16, rows: u16, cwd: []const u8) noreturn {
    const master_rc = linux.open(tty_ptmx, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    if (linux.errno(master_rc) != .SUCCESS) ttyFail(status_fd, "the guest has no usable /dev/ptmx");
    const master: linux.fd_t = @intCast(master_rc);

    var unlock: u32 = 0;
    if (linux.errno(linux.ioctl(master, tiocsptlck, @intFromPtr(&unlock))) != .SUCCESS) {
        ttyFail(status_fd, "cannot unlock the pty");
    }
    var slave_number: u32 = 0;
    if (linux.errno(linux.ioctl(master, tiocgptn, @intFromPtr(&slave_number))) != .SUCCESS) {
        ttyFail(status_fd, "cannot number the pty");
    }

    const shell_rc = linux.fork();
    if (linux.errno(shell_rc) != .SUCCESS) ttyFail(status_fd, "fork failed");
    if (shell_rc == 0) ttyShellChild(slave_number, cwd);
    const shell_pid: i64 = @intCast(shell_rc);

    _ = ttySetWinsize(master, cols, rows);

    const port = tty_port_base + @as(u32, @intCast(slot));
    const listen_fd = vsockListen(port) orelse ttyFail(status_fd, "cannot listen on the terminal's port");

    var report: [512]u8 = undefined;
    const opened = std.fmt.bufPrint(
        &report,
        "{{\"type\":\"tty.opened\",\"id\":{d},\"tty_id\":{d},\"pid\":{d},\"port\":{d}}}",
        .{ request_id, slot, shell_pid, port },
    ) catch ttyFail(status_fd, "terminal setup failed");
    writeFrame(status_fd, opened);
    _ = linux.close(status_fd);

    while (true) {
        const conn_rc = linux.accept(listen_fd, null, null);
        if (linux.errno(conn_rc) != .SUCCESS) continue;
        const conn_fd: linux.fd_t = @intCast(conn_rc);
        const keep = ttyServeOne(conn_fd, master, shell_pid);
        _ = linux.close(conn_fd);
        if (!keep) {
            ttyKill(master, shell_pid);
            linux.exit(0);
        }
    }
}

/// Read the terminal host's report. A host that died without one is a failed
/// open, never an open the caller has to discover is dead.
fn ttyReadReport(status_fd: linux.fd_t, buf: []u8) ?[]const u8 {
    var waited: u32 = 0;
    while (waited < tty_report_deadline_ms) : (waited += 20) {
        var pfd = [_]linux.pollfd{.{ .fd = status_fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, 20);
        if (linux.errno(rc) != .SUCCESS) return null;
        if (rc > 0) break;
    }
    var header: [4]u8 = undefined;
    if (!readExact(status_fd, &header)) return null;
    const len = wire.framePayloadLen(&header);
    if (len == 0 or len > buf.len) return null;
    if (!readExact(status_fd, buf[0..len])) return null;
    return buf[0..len];
}

/// `tty open`: fork the terminal host and answer with its pid and port. The
/// agent itself owns no pty, so a terminal outlives any one connection.
fn runTtyOpen(conn_fd: linux.fd_t, id: i64, cols: u16, rows: u16, cwd: []const u8) void {
    if (!ttyWindowOk(cols, rows)) {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"cols/rows are out of range\"}}", .{id});
        return;
    }
    if (!ttyCwdOk(cwd)) {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"the shell must start inside /workspace\"}}", .{id});
        return;
    }
    ttyReapDead();
    const slot = ttyFreeSlot() orelse {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"all {d} terminals are in use\"}}", .{ id, max_ttys });
        return;
    };

    var pipe_fds: [2]linux.fd_t = .{ -1, -1 };
    if (!pipePair(&pipe_fds)) {
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"pipe failed\"}}", .{id});
        return;
    }
    const report_fd = pipe_fds[0];
    const status_fd = pipe_fds[1];

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        closeIfOpen(report_fd);
        closeIfOpen(status_fd);
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"fork failed\"}}", .{id});
        return;
    }
    if (fork_rc == 0) {
        _ = linux.close(report_fd);
        ttyHost(status_fd, id, slot, cols, rows, cwd);
    }
    const host_pid: i64 = @intCast(fork_rc);
    _ = linux.close(status_fd);

    var buf: [max_frame]u8 = undefined;
    const report = ttyReadReport(report_fd, &buf);
    _ = linux.close(report_fd);
    const text = report orelse {
        _ = linux.syscall2(.kill, @intCast(host_pid), @intFromEnum(linux.SIG.KILL));
        reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"the terminal host never reported\"}}", .{id});
        return;
    };
    if (std.mem.indexOf(u8, text, "\"type\":\"tty.opened\"") != null) {
        tty_slots[slot] = .{ .used = true, .host_pid = host_pid };
    }
    writeFrame(conn_fd, text);
}
// ─── guest duplexes: one MCP server's two byte streams ───────────────────

const duplex_port_base: u32 = wire.duplex_port_base;
const max_duplex: usize = wire.max_duplex;
const duplex_chunk: usize = wire.max_duplex_chunk;
/// How long one `read` waits inside the guest for a byte before answering
/// "nothing yet", and how long one `write` waits for the server to drain.
const duplex_read_wait_ms: i32 = 200;
const duplex_write_wait_ms: i64 = 5_000;
const duplex_report_deadline_ms: u32 = 5_000;
const duplex_poll_slice_ms: i32 = 20;

const DuplexRequest = struct {
    id: i64 = 0,
    argv: []const []const u8 = &.{},
    cwd: []const u8 = tty_cwd,
};

/// One live duplex: the agent's handle on the process that owns it. The pipes
/// and the child belong to that process, never to PID 1.
const DuplexSlot = struct {
    used: bool = false,
    host_pid: i64 = 0,
};

var duplex_slots: [max_duplex]DuplexSlot = [_]DuplexSlot{.{}} ** max_duplex;

fn duplexReapDead() void {
    for (&duplex_slots) |*slot| {
        if (!slot.used) continue;
        var status: u32 = 0;
        const rc = linux.wait4(@intCast(slot.host_pid), &status, wno_hang, null);
        if (linux.errno(rc) == .SUCCESS and rc != 0) slot.* = .{};
    }
}

fn duplexFreeSlot() ?usize {
    for (&duplex_slots, 0..) |*slot, i| {
        if (!slot.used) return i;
    }
    return null;
}

fn duplexFail(status_fd: linux.fd_t, message: []const u8) noreturn {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "{{\"type\":\"duplex.error\",\"id\":0,\"message\":\"{s}\"}}",
        .{message},
    ) catch "{\"type\":\"duplex.error\",\"id\":0,\"message\":\"duplex setup failed\"}";
    writeFrame(status_fd, text);
    linux.exit(1);
}

/// The server's stdin and stdout are PIPES, never a pty: a pty merges stderr
/// into stdout and echoes stdin, and either one corrupts MCP framing.
fn duplexChild(req: *const DuplexRequest, in_read: linux.fd_t, out_write: linux.fd_t) noreturn {
    var cwd_buf: [1024]u8 = undefined;
    _ = linux.setsid();
    _ = linux.dup2(in_read, 0);
    _ = linux.dup2(out_write, 1);
    const devnull_rc = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    const has_devnull = linux.errno(devnull_rc) == .SUCCESS;
    if (has_devnull) _ = linux.dup2(@intCast(devnull_rc), 2);
    if (in_read > 2) _ = linux.close(in_read);
    if (out_write > 2) _ = linux.close(out_write);
    if (has_devnull and devnull_rc > 2) _ = linux.close(@intCast(devnull_rc));
    if (cstr(req.cwd, &cwd_buf)) |cwd| _ = linux.chdir(cwd);
    _ = linux.setgroups(0, &[_]linux.gid_t{});
    _ = linux.setgid(default_gid);
    _ = linux.setuid(default_uid);
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    const argv = buildArgv(req.argv) orelse {
        writeAll(2, "pabrik-vm-agent: duplex argv too large\n");
        linux.exit(126);
    };
    _ = linux.execve(@ptrCast(argv[0].?), argv, &exec_env);
    linux.exit(127);
}

/// Kill the server's whole session and wait for it, bounded.
fn duplexKill(in_fd: linux.fd_t, out_fd: linux.fd_t, child_pid: i64) void {
    const group: usize = @bitCast(-@as(isize, @intCast(child_pid)));
    _ = linux.syscall2(.kill, group, @intFromEnum(linux.SIG.KILL));
    _ = linux.syscall2(.kill, @intCast(child_pid), @intFromEnum(linux.SIG.KILL));
    var status: u32 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const rc = linux.wait4(@intCast(child_pid), &status, wno_hang, null);
        if (linux.errno(rc) == .SUCCESS and rc != 0) break;
        const ts = linux.timespec{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    closeIfOpen(in_fd);
    closeIfOpen(out_fd);
}

fn duplexError(conn_fd: linux.fd_t, message: []const u8) void {
    reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":1,\"message\":\"{s}\"}}", .{message});
}

/// Whatever the server has written right now, plus its exit state. `eof` is
/// the read end of a pipe that every writer has closed, never "no data yet".
fn duplexReplyRead(conn_fd: linux.fd_t, out_fd: linux.fd_t, child_pid: i64, max_bytes: usize) void {
    var exited = false;
    var status: u32 = 0;
    const reaped = linux.wait4(@intCast(child_pid), &status, wno_hang, null);
    if (linux.errno(reaped) == .SUCCESS and reaped != 0) exited = true;
    const code: i64 = if (!exited)
        0
    else if (linux.W.IFEXITED(status))
        @intCast(linux.W.EXITSTATUS(status))
    else
        -1;

    var chunk: [duplex_chunk]u8 = undefined;
    var got: usize = 0;
    var pfd = [_]linux.pollfd{.{ .fd = out_fd, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.errno(linux.poll(&pfd, 1, duplex_read_wait_ms)) == .SUCCESS and pfd[0].revents != 0) {
        const rc = linux.read(out_fd, &chunk, @min(max_bytes, chunk.len));
        if (linux.errno(rc) == .SUCCESS and rc > 0) {
            got = rc;
        } else {
            // Zero bytes on a readable pipe IS end-of-file.
            exited = true;
        }
    }

    if (got == 0) {
        reply(conn_fd, "{{\"type\":\"duplex.data\",\"id\":1,\"eof\":true,\"exited\":{s},\"exit_code\":{d},\"data_b64\":\"\"}}", .{
            if (exited) "true" else "false",
            code,
        });
        return;
    }
    var b64: [std.base64.standard.Encoder.calcSize(duplex_chunk)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, chunk[0..got]);
    reply(conn_fd, "{{\"type\":\"duplex.data\",\"id\":1,\"eof\":false,\"exited\":{s},\"exit_code\":{d},\"data_b64\":\"{s}\"}}", .{
        if (exited) "true" else "false",
        code,
        encoded,
    });
}

/// Write one piece to the server's stdin, waiting for space for at most
/// `duplex_write_wait_ms`. A server that stopped draining must not park this
/// process for the rest of the workspace's life.
fn duplexReplyWrite(conn_fd: linux.fd_t, in_fd: linux.fd_t, data_b64: []const u8) void {
    var chunk: [duplex_chunk]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(data_b64) catch return duplexError(conn_fd, "data is not base64");
    if (size == 0 or size > chunk.len) return duplexError(conn_fd, "one write piece is too large");
    decoder.decode(chunk[0..size], data_b64) catch return duplexError(conn_fd, "data is not base64");

    var off: usize = 0;
    var waited: i64 = 0;
    while (off < size) {
        var pfd = [_]linux.pollfd{.{ .fd = in_fd, .events = linux.POLL.OUT, .revents = 0 }};
        const ready = linux.errno(linux.poll(&pfd, 1, duplex_poll_slice_ms)) == .SUCCESS and pfd[0].revents != 0;
        if (!ready) {
            waited += duplex_poll_slice_ms;
            if (waited >= duplex_write_wait_ms) return duplexError(conn_fd, "the server is not reading its input");
            continue;
        }
        const rc = linux.write(in_fd, chunk[off..].ptr, size - off);
        if (linux.errno(rc) != .SUCCESS) return duplexError(conn_fd, "the server closed its input");
        if (rc == 0) return duplexError(conn_fd, "the server closed its input");
        off += rc;
    }
    reply(conn_fd, "{{\"type\":\"duplex.wrote\",\"id\":1,\"bytes\":{d}}}", .{off});
}

/// One request on a duplex's own port. Returns false when the duplex is
/// finished and its host should go away.
fn duplexServeOne(conn_fd: linux.fd_t, in_fd: linux.fd_t, out_fd: linux.fd_t, child_pid: i64) bool {
    var header: [4]u8 = undefined;
    if (!readExact(conn_fd, &header)) return true;
    const len = wire.framePayloadLen(&header);
    if (len == 0 or len > max_frame) return true;
    var payload: [max_frame]u8 = undefined;
    if (!readExact(conn_fd, payload[0..len])) return true;

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload[0..len], .{}) catch {
        return duplexErrorOrKeep(conn_fd, "bad json frame");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return duplexErrorOrKeep(conn_fd, "frame is not an object"),
    };
    const op = if (obj.get("op")) |v| (if (v == .string) v.string else "") else "";

    if (std.mem.eql(u8, op, "read")) {
        const asked = if (obj.get("max_bytes")) |v| asUsize(v, duplex_chunk) else duplex_chunk;
        duplexReplyRead(conn_fd, out_fd, child_pid, @min(asked, duplex_chunk));
        return true;
    }
    if (std.mem.eql(u8, op, "write")) {
        const data_b64 = if (obj.get("data_b64")) |v| (if (v == .string) v.string else "") else "";
        duplexReplyWrite(conn_fd, in_fd, data_b64);
        return true;
    }
    if (std.mem.eql(u8, op, "close")) {
        reply(conn_fd, "{{\"type\":\"duplex.closed\",\"id\":1}}", .{});
        return false;
    }
    return duplexErrorOrKeep(conn_fd, "unknown duplex request");
}

fn duplexErrorOrKeep(conn_fd: linux.fd_t, message: []const u8) bool {
    duplexError(conn_fd, message);
    return true;
}

/// The process that owns one duplex: it creates both pipes, forks the server,
/// binds the duplex's own vsock port, and serves until the duplex closes.
fn duplexHost(status_fd: linux.fd_t, request_id: i64, slot: usize, req: *const DuplexRequest) noreturn {
    var in_fds: [2]linux.fd_t = .{ -1, -1 };
    if (!pipePair(&in_fds)) duplexFail(status_fd, "pipe failed");
    var out_fds: [2]linux.fd_t = .{ -1, -1 };
    if (!pipePair(&out_fds)) duplexFail(status_fd, "pipe failed");

    const child_rc = linux.fork();
    if (linux.errno(child_rc) != .SUCCESS) duplexFail(status_fd, "fork failed");
    if (child_rc == 0) {
        _ = linux.close(in_fds[1]);
        _ = linux.close(out_fds[0]);
        duplexChild(req, in_fds[0], out_fds[1]);
    }
    const child_pid: i64 = @intCast(child_rc);
    _ = linux.close(in_fds[0]);
    _ = linux.close(out_fds[1]);
    const in_fd = in_fds[1];
    const out_fd = out_fds[0];

    const port = duplex_port_base + @as(u32, @intCast(slot));
    const listen_fd = vsockListen(port) orelse duplexFail(status_fd, "cannot listen on the duplex's port");

    var report: [512]u8 = undefined;
    const opened = std.fmt.bufPrint(
        &report,
        "{{\"type\":\"duplex.opened\",\"id\":{d},\"duplex_id\":{d},\"pid\":{d},\"port\":{d}}}",
        .{ request_id, slot, child_pid, port },
    ) catch duplexFail(status_fd, "duplex setup failed");
    writeFrame(status_fd, opened);
    _ = linux.close(status_fd);

    while (true) {
        const conn_rc = linux.accept(listen_fd, null, null);
        if (linux.errno(conn_rc) != .SUCCESS) continue;
        const conn_fd: linux.fd_t = @intCast(conn_rc);
        const keep = duplexServeOne(conn_fd, in_fd, out_fd, child_pid);
        _ = linux.close(conn_fd);
        if (!keep) {
            duplexKill(in_fd, out_fd, child_pid);
            linux.exit(0);
        }
    }
}

fn duplexReadReport(status_fd: linux.fd_t, buf: []u8) ?[]const u8 {
    var waited: u32 = 0;
    while (waited < duplex_report_deadline_ms) : (waited += 20) {
        var pfd = [_]linux.pollfd{.{ .fd = status_fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, 20);
        if (linux.errno(rc) != .SUCCESS) return null;
        if (rc > 0) break;
    }
    var header: [4]u8 = undefined;
    if (!readExact(status_fd, &header)) return null;
    const len = wire.framePayloadLen(&header);
    if (len == 0 or len > buf.len) return null;
    if (!readExact(status_fd, buf[0..len])) return null;
    return buf[0..len];
}

/// `duplex open`: fork the duplex host and answer with its pid and port. The
/// agent itself owns no pipe, so a server outlives any one connection.
fn runDuplexOpen(conn_fd: linux.fd_t, req: *const DuplexRequest) void {
    duplexReapDead();
    const slot = duplexFreeSlot() orelse {
        reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"all {d} duplexes are in use\"}}", .{ req.id, max_duplex });
        return;
    };

    var pipe_fds: [2]linux.fd_t = .{ -1, -1 };
    if (!pipePair(&pipe_fds)) {
        reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"pipe failed\"}}", .{req.id});
        return;
    }
    const report_fd = pipe_fds[0];
    const status_fd = pipe_fds[1];

    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        closeIfOpen(report_fd);
        closeIfOpen(status_fd);
        reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"fork failed\"}}", .{req.id});
        return;
    }
    if (fork_rc == 0) {
        _ = linux.close(report_fd);
        duplexHost(status_fd, req.id, slot, req);
    }
    const host_pid: i64 = @intCast(fork_rc);
    _ = linux.close(status_fd);

    var buf: [max_frame]u8 = undefined;
    const report = duplexReadReport(report_fd, &buf);
    _ = linux.close(report_fd);
    const text = report orelse {
        _ = linux.syscall2(.kill, @intCast(host_pid), @intFromEnum(linux.SIG.KILL));
        reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"the duplex host never reported\"}}", .{req.id});
        return;
    };
    if (std.mem.indexOf(u8, text, "\"type\":\"duplex.opened\"") != null) {
        duplex_slots[slot] = .{ .used = true, .host_pid = host_pid };
    }
    writeFrame(conn_fd, text);
}

// ─── request dispatch ────────────────────────────────────────────────────

fn asU32(value: std.json.Value, fallback: u32) u32 {
    return switch (value) {
        .integer => |i| @intCast(@max(i, 0)),
        else => fallback,
    };
}

fn asI64(value: std.json.Value, fallback: i64) i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => fallback,
    };
}

fn asUsize(value: std.json.Value, fallback: usize) usize {
    return switch (value) {
        .integer => |i| @intCast(@max(i, 0)),
        else => fallback,
    };
}

fn asU16(value: std.json.Value, fallback: u16) u16 {
    return switch (value) {
        .integer => |i| @intCast(@min(@max(i, 0), std.math.maxInt(u16))),
        else => fallback,
    };
}

fn serveRequest(conn_fd: linux.fd_t, text: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{}) catch {
        reply(conn_fd, "{{\"type\":\"error\",\"message\":\"bad json frame\"}}", .{});
        return;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            reply(conn_fd, "{{\"type\":\"error\",\"message\":\"frame is not an object\"}}", .{});
            return;
        },
    };
    const kind = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";

    if (std.mem.eql(u8, kind, "shutdown")) {
        writeFrame(conn_fd, bye_json);
        _ = linux.shutdown(conn_fd, 1);
        logLine("shutdown requested");
        const magic1: usize = 0xfee1dead;
        const magic2: usize = 672274793;
        _ = linux.syscall3(.reboot, magic1, magic2, 0x4321fedc);
        while (true) _ = linux.pause();
    }
    if (std.mem.eql(u8, kind, "hello")) {
        writeFrame(conn_fd, hello_json);
        logLine("answered hello over vsock");
        return;
    }
    if (std.mem.eql(u8, kind, "exec")) {
        var req = ExecRequest{};
        if (obj.get("id")) |v| req.id = switch (v) {
            .integer => |i| i,
            else => 0,
        };
        if (obj.get("timeout_ms")) |v| req.timeout_ms = asU32(v, req.timeout_ms);
        if (obj.get("max_output_bytes")) |v| req.max_output_bytes = asUsize(v, req.max_output_bytes);
        if (obj.get("uid")) |v| req.uid = asU32(v, req.uid);
        if (obj.get("gid")) |v| req.gid = asU32(v, req.gid);
        if (obj.get("cwd")) |v| {
            if (v == .string) req.cwd = v.string;
        }
        if (obj.get("argv")) |v| {
            if (v == .array) {
                var list: [max_argv][]const u8 = undefined;
                var count: usize = 0;
                for (v.array.items) |item| {
                    if (item != .string or count == max_argv) break;
                    list[count] = item.string;
                    count += 1;
                }
                req.argv = list[0..count];
            }
        }
        if (req.argv.len == 0) {
            reply(conn_fd, "{{\"type\":\"exec.exit\",\"id\":{d},\"code\":-1,\"error\":\"argv is required\"}}", .{req.id});
            return;
        }
        runExec(conn_fd, &req);
        return;
    }
    if (std.mem.eql(u8, kind, "spawn")) {
        var req = SpawnRequest{};
        if (obj.get("id")) |v| req.id = asI64(v, 0);
        if (obj.get("uid")) |v| req.uid = asU32(v, req.uid);
        if (obj.get("gid")) |v| req.gid = asU32(v, req.gid);
        if (obj.get("cwd")) |v| {
            if (v == .string) req.cwd = v.string;
        }
        if (obj.get("log_path")) |v| {
            if (v == .string) req.log_path = v.string;
        }
        if (obj.get("argv")) |v| {
            if (v == .array) {
                var list: [max_argv][]const u8 = undefined;
                var count: usize = 0;
                for (v.array.items) |item| {
                    if (item != .string or count == max_argv) break;
                    list[count] = item.string;
                    count += 1;
                }
                req.argv = list[0..count];
            }
        }
        runSpawn(conn_fd, &req);
        return;
    }
    if (std.mem.eql(u8, kind, "tty")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const op = if (obj.get("op")) |v| (if (v == .string) v.string else "") else "";
        // Only `open` reaches the agent. A live terminal answers on its own
        // port, where a tty id names a guest process rather than a request.
        if (!std.mem.eql(u8, op, "open")) {
            reply(conn_fd, "{{\"type\":\"tty.error\",\"id\":{d},\"message\":\"the agent only opens terminals\"}}", .{id});
            return;
        }
        const cols = asU16(if (obj.get("cols")) |v| v else .{ .integer = 0 }, 0);
        const rows = asU16(if (obj.get("rows")) |v| v else .{ .integer = 0 }, 0);
        const cwd = if (obj.get("cwd")) |v| (if (v == .string) v.string else tty_cwd) else tty_cwd;
        runTtyOpen(conn_fd, id, cols, rows, cwd);
        return;
    }
    if (std.mem.eql(u8, kind, "duplex")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const op = if (obj.get("op")) |v| (if (v == .string) v.string else "") else "";
        // Only `open` reaches the agent: a live duplex answers on its own
        // port, where a duplex id names a guest process, not a request.
        if (!std.mem.eql(u8, op, "open")) {
            reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"the agent only opens duplexes\"}}", .{id});
            return;
        }
        var req = DuplexRequest{ .id = id };
        if (obj.get("cwd")) |v| {
            if (v == .string) req.cwd = v.string;
        }
        if (obj.get("argv")) |v| {
            if (v == .array) {
                var list: [max_argv][]const u8 = undefined;
                var count: usize = 0;
                for (v.array.items) |item| {
                    if (item != .string or count == max_argv) break;
                    list[count] = item.string;
                    count += 1;
                }
                req.argv = list[0..count];
            }
        }
        if (req.argv.len == 0) {
            reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"argv is required\"}}", .{id});
            return;
        }
        if (!ttyCwdOk(req.cwd)) {
            reply(conn_fd, "{{\"type\":\"duplex.error\",\"id\":{d},\"message\":\"the server must start inside /workspace\"}}", .{id});
            return;
        }
        runDuplexOpen(conn_fd, &req);
        return;
    }
    if (std.mem.eql(u8, kind, "probe")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const pid = if (obj.get("pid")) |v| asI64(v, 0) else 0;
        if (pid <= 0) {
            reply(conn_fd, "{{\"type\":\"error\",\"message\":\"pid is required\"}}", .{});
            return;
        }
        runProbe(conn_fd, id, pid);
        return;
    }
    if (std.mem.eql(u8, kind, "signal")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const pid = if (obj.get("pid")) |v| asI64(v, 0) else 0;
        const sig = if (obj.get("signal")) |v| asI64(v, 9) else 9;
        if (pid <= 0 or sig <= 0 or sig > 64) {
            reply(conn_fd, "{{\"type\":\"error\",\"message\":\"pid and signal are required\"}}", .{});
            return;
        }
        runSignal(conn_fd, id, pid, sig);
        return;
    }
    if (std.mem.eql(u8, kind, "fs.write")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const path = if (obj.get("path")) |v| (if (v == .string) v.string else "") else "";
        const data_b64 = if (obj.get("data_b64")) |v| (if (v == .string) v.string else "") else "";
        if (path.len == 0) {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is required\"}}", .{id});
            return;
        }
        const offset = if (obj.get("offset")) |v| asI64(v, 0) else 0;
        const create_dirs = if (obj.get("create_dirs")) |v| (v == .bool and v.bool) else false;
        // A request that does not say otherwise truncates at the start.
        const truncate = if (obj.get("truncate")) |v| (v == .bool and v.bool) else (offset == 0);
        return runFsWrite(conn_fd, id, path, offset, data_b64, create_dirs, truncate);
    }
    if (std.mem.eql(u8, kind, "fs.walk")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        // The workspace root itself is a legal start, so an empty path is not
        // a missing one here the way it is for a file.
        const path = if (obj.get("path")) |v| (if (v == .string) v.string else "") else "";
        const asked_depth = if (obj.get("max_depth")) |v| asUsize(v, max_walk_depth) else max_walk_depth;
        const asked_entries = if (obj.get("max_entries")) |v| asUsize(v, max_walk_entries) else max_walk_entries;
        const depth: u32 = @intCast(@min(asked_depth, max_walk_depth));
        const entries: usize = @min(asked_entries, max_walk_entries);
        if (entries == 0 or depth == 0) {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"depth and max_entries are required\"}}", .{id});
            return;
        }
        return runFsWalk(conn_fd, id, path, depth, entries);
    }
    if (std.mem.eql(u8, kind, "fs.stat") or std.mem.eql(u8, kind, "fs.read") or std.mem.eql(u8, kind, "fs.remove")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const path = if (obj.get("path")) |v| (if (v == .string) v.string else "") else "";
        if (path.len == 0) {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"path is required\"}}", .{id});
            return;
        }
        if (std.mem.eql(u8, kind, "fs.stat")) return runFsStat(conn_fd, id, path);
        if (std.mem.eql(u8, kind, "fs.remove")) return runFsRemove(conn_fd, id, path);
        const offset = if (obj.get("offset")) |v| asI64(v, 0) else 0;
        const max_bytes = if (obj.get("max_bytes")) |v| asUsize(v, fs_read_chunk) else fs_read_chunk;
        if (offset < 0 or max_bytes == 0) {
            reply(conn_fd, "{{\"type\":\"fs.error\",\"id\":{d},\"message\":\"offset and max_bytes are required\"}}", .{id});
            return;
        }
        return runFsRead(conn_fd, id, path, offset, max_bytes);
    }
    if (std.mem.eql(u8, kind, "port.forward")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const port_int = if (obj.get("port")) |v| asI64(v, 0) else 0;
        const data_b64 = if (obj.get("data_b64")) |v| (if (v == .string) v.string else "") else "";
        const max_bytes = if (obj.get("max_bytes")) |v| asUsize(v, port_forward_cap) else port_forward_cap;
        if (port_int <= 0 or port_int > 65535 or data_b64.len == 0) {
            reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"port and data are required\"}}", .{id});
            return;
        }
        return runPortForward(conn_fd, id, @intCast(port_int), data_b64, @min(max_bytes, port_forward_cap));
    }
    if (std.mem.eql(u8, kind, "read_log")) {
        const id = if (obj.get("id")) |v| asI64(v, 0) else 0;
        const path = if (obj.get("path")) |v| (if (v == .string) v.string else "") else "";
        const offset = if (obj.get("offset")) |v| asI64(v, 0) else 0;
        const max_bytes = if (obj.get("max_bytes")) |v| asUsize(v, log_read_chunk) else log_read_chunk;
        if (path.len == 0 or offset < 0 or max_bytes == 0) {
            reply(conn_fd, "{{\"type\":\"error\",\"message\":\"path, offset and max_bytes are required\"}}", .{});
            return;
        }
        runReadLog(conn_fd, id, path, offset, max_bytes);
        return;
    }
    reply(conn_fd, "{{\"type\":\"error\",\"message\":\"unknown request\"}}", .{});
}

// ─── the preview tunnel ─────────────────────────────────────────────────

/// One request forwarded to a guest loopback port, answered in pieces. The
/// guest is the only place a tenant's dev server listens, so this is the only
/// way a browser reaches it.
fn runPortForward(conn_fd: linux.fd_t, id: i64, port: u16, data_b64: []const u8, max_bytes: usize) void {
    const size = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"body is not base64\"}}", .{id});
        return;
    };
    if (size > port_forward_chunk or size > max_bytes) {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"body is too large\"}}", .{id});
        return;
    }
    var body: [port_forward_chunk]u8 = undefined;
    std.base64.standard.Decoder.decode(body[0..size], data_b64) catch {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"body is not base64\"}}", .{id});
        return;
    };
    if (port == 0) {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"port is required\"}}", .{id});
        return;
    }

    const fd = connectLoopback(port) orelse {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"no listener on 127.0.0.1:{d}\"}}", .{ id, port });
        return;
    };
    defer _ = linux.close(fd);
    if (!writeBytes(fd, body[0..size])) {
        reply(conn_fd, "{{\"type\":\"port.forward.error\",\"id\":{d},\"message\":\"the guest port closed the request\"}}", .{id});
        return;
    }
    // Half-close: the dev server reads the request through to the end of it.
    _ = linux.shutdown(fd, 1);

    var chunk: [port_forward_chunk]u8 = undefined;
    var encoded: [std.base64.standard.Encoder.calcSize(port_forward_chunk)]u8 = undefined;
    var total: usize = 0;
    var truncated = false;
    while (true) {
        const rc = linux.read(fd, &chunk, chunk.len);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS or rc == 0) break;
        if (total + rc > port_forward_cap) {
            truncated = true;
            break;
        }
        total += rc;
        const text = std.base64.standard.Encoder.encode(&encoded, chunk[0..rc]);
        reply(conn_fd, "{{\"type\":\"port.forward.data\",\"id\":{d},\"data_b64\":\"{s}\"}}", .{ id, text });
    }
    reply(conn_fd, "{{\"type\":\"port.forward.done\",\"id\":{d},\"size\":{d},\"truncated\":{s}}}", .{
        id,
        total,
        if (truncated) "true" else "false",
    });
}

/// A blocking TCP connect to the guest's own loopback, with deadlines, because
/// a dev server that never answers must not stall the agent's frame loop.
fn connectLoopback(port: u16) ?linux.fd_t {
    const rc = linux.socket(af_inet, sock_stream, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&port_forward_timeout), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&port_forward_timeout), @sizeOf(linux.timeval));
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, port), .addr = 0x0100007F };
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Start the in-guest network forwarder. The image ships it; without it the
/// tenant has no way out of the VM and no resolver, and that is logged rather
/// than guessed at.
fn startNetd() void {
    var path_buf: [64]u8 = undefined;
    const path = cstr(netd_path, &path_buf) orelse return;
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        logLine("MISSING netd: fork failed");
        return;
    }
    if (fork_rc != 0) {
        logLine("netd started");
        return;
    }
    _ = linux.setsid();
    const null_rc = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(null_rc) == .SUCCESS) {
        _ = linux.dup2(@intCast(null_rc), 0);
    }
    const argv = [_:null]?[*:0]const u8{ path, null };
    _ = linux.execve(path, &argv, &exec_env);
    logLine("MISSING netd: exec failed");
    linux.exit(127);
}

/// Framed requests until `shutdown`.
fn serve(conn_fd: linux.fd_t) void {
    var payload: [max_frame]u8 = undefined;
    while (true) {
        var header: [4]u8 = undefined;
        if (!readExact(conn_fd, &header)) return;
        const len = wire.framePayloadLen(&header);
        if (len == 0 or len > max_frame) return;
        if (!readExact(conn_fd, payload[0..len])) return;
        serveRequest(conn_fd, payload[0..len]);
    }
}

/// One connection, served to the end and closed: every request gets its own, so
/// a turn that does not close leaks a descriptor per command.
fn serveConnection(conn_fd: linux.fd_t) void {
    serve(conn_fd);
    _ = linux.close(conn_fd);
}

pub fn main() void {
    writeAll(1, "\n[pabrik-vm-agent] booting as PID 1\n");
    logLine(if (mountPseudo("proc", "/proc")) "mounted proc" else "MISSING proc");
    logLine(if (mountPseudo("sysfs", "/sys")) "mounted sysfs" else "MISSING sysfs");
    logLine(if (mountPseudo("devtmpfs", "/dev")) "mounted devtmpfs" else "MISSING devtmpfs");
    ensureDev();
    startNetd();

    const listen_fd = switch (vsock.listen(wire.agent_port, wire.cid_any, 4)) {
        .fd => |fd| fd,
        .errno => {
            logLine("vsock listen failed");
            while (true) _ = linux.pause();
        },
    };
    logLine("listening on the agent's vsock port");

    // Wait on the listener, never call `accept` bare: a failure that repeats
    // must cost a tick, not the vCPU — a spinning PID 1 starves every command.
    // The happy path stays silent: a serial write is a vmexit, a poll is not news.
    var failures: u32 = 0;
    while (true) {
        var pfd = [1]linux.pollfd{
            .{ .fd = listen_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const poll_rc = linux.poll(&pfd, pfd.len, accept_slice_ms);
        if (linux.errno(poll_rc) != .SUCCESS) continue;
        if (poll_rc == 0) continue;
        if (pfd[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) continue;
        var peer: vsock.Addr = undefined;
        var peer_len: linux.socklen_t = @sizeOf(vsock.Addr);
        const conn_rc = linux.accept(listen_fd, @ptrCast(&peer), &peer_len);
        if (linux.errno(conn_rc) != .SUCCESS) {
            failures += 1;
            // Log the first one and then rarely: a broken listener must be
            // visible without a line per attempt.
            if (failures == 1 or failures % 64 == 0) logLine("MISSING vsock accept; backing off");
            sleepMs(backoff.afterTurn(false, failures));
            continue;
        }
        failures = 0;
        serveConnection(@intCast(conn_rc));
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

/// Every handler logs to the serial console on fd 1, and under a test runner
/// fd 1 is the runner's own pipe: point it at /dev/null for the turn.
fn muteSerial() ?linux.fd_t {
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(devnull) != .SUCCESS) return null;
    const saved = linux.dup(1);
    if (linux.errno(saved) != .SUCCESS) {
        _ = linux.close(@intCast(devnull));
        return null;
    }
    _ = linux.dup2(@intCast(devnull), 1);
    _ = linux.close(@intCast(devnull));
    return @intCast(saved);
}

fn unmuteSerial(saved: ?linux.fd_t) void {
    const fd = saved orelse return;
    _ = linux.dup2(fd, 1);
    _ = linux.close(fd);
}

/// The descriptors 0..255 that are open right now, so a leak test can count a
/// delta instead of trusting a number.
fn liveDescriptors() usize {
    var live: usize = 0;
    var fd: i32 = 0;
    while (fd < 256) : (fd += 1) {
        if (linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) == .SUCCESS) live += 1;
    }
    return live;
}

/// A connected stream pair: the agent's end and the daemon's end.
fn socketPair() ?[2]linux.fd_t {
    var fds: [2]linux.fd_t = .{ -1, -1 };
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return null;
    return fds;
}

/// A read that would block forever is a hung test, not a failing one: give the
/// caller's end a deadline so a missing reply returns null.
fn setReceiveTimeout(fd: linux.fd_t, ms: i64) void {
    const tv = linux.timeval{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .usec = @intCast(@mod(ms, 1000) * 1000),
    };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
}

/// One frame, framed the way the daemon frames it: length, then payload.
fn sendFrame(fd: linux.fd_t, payload: []const u8) bool {
    var header: [4]u8 = undefined;
    wire.frameHeader(payload.len, &header);
    return writeBytes(fd, &header) and writeBytes(fd, payload);
}

/// Read one frame's payload, or null at a clean end or a broken peer.
fn readFrame(fd: linux.fd_t, out: []u8) ?[]u8 {
    var header: [4]u8 = undefined;
    if (!readExact(fd, &header)) return null;
    const len = wire.framePayloadLen(&header);
    if (len == 0 or len > out.len) return null;
    if (!readExact(fd, out[0..len])) return null;
    return out[0..len];
}

test "a served connection is closed, not left open" {
    const pair = socketPair() orelse return error.SkipZigTest;
    const agent_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 2000);
    defer _ = linux.close(caller_end);

    try std.testing.expect(sendFrame(caller_end, "{\"type\":\"hello\"}"));
    // The peer half-closes after its one frame, which is what ends `serve`.
    _ = linux.shutdown(caller_end, linux.SHUT.WR);
    const muted = muteSerial();
    serveConnection(agent_end);
    unmuteSerial(muted);

    var reply_buf: [512]u8 = undefined;
    const answer = readFrame(caller_end, &reply_buf) orelse return error.NoReply;
    try std.testing.expectEqualStrings(hello_json, answer);
    // The descriptor the agent used is gone: closing it again is EBADF, and no
    // other call ran in between that could have taken the number back.
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.close(agent_end)));
}

test "sixty turns do not grow the descriptor table" {
    // The regression this pins: one descriptor per command is a workspace that
    // stops answering after ~1020 of them.
    const baseline = liveDescriptors();
    var turn: usize = 0;
    while (turn < 60) : (turn += 1) {
        const pair = socketPair() orelse return error.SkipZigTest;
        setReceiveTimeout(pair[1], 2000);
        try std.testing.expect(sendFrame(pair[1], "{\"type\":\"hello\"}"));
        _ = linux.shutdown(pair[1], linux.SHUT.WR);
        const muted = muteSerial();
        serveConnection(pair[0]);
        unmuteSerial(muted);
        _ = linux.close(pair[1]);
    }
    try std.testing.expectEqual(baseline, liveDescriptors());
}

test "a malformed frame is answered and the connection still closes" {
    const pair = socketPair() orelse return error.SkipZigTest;
    const agent_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 2000);
    defer _ = linux.close(caller_end);

    try std.testing.expect(sendFrame(caller_end, "not json"));
    _ = linux.shutdown(caller_end, linux.SHUT.WR);
    const muted = muteSerial();
    serveConnection(agent_end);
    unmuteSerial(muted);

    var reply_buf: [512]u8 = undefined;
    const answer = readFrame(caller_end, &reply_buf) orelse return error.NoReply;
    try std.testing.expect(std.mem.indexOf(u8, answer, "bad json frame") != null);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.close(agent_end)));
}

test "an oversized frame is refused without a reply, and the connection closes" {
    const pair = socketPair() orelse return error.SkipZigTest;
    const agent_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 2000);
    defer _ = linux.close(caller_end);

    // A length the agent refuses to read at all: it must not wait for a body
    // that is never coming.
    var header: [4]u8 = undefined;
    wire.frameHeader(max_frame + 1, &header);
    try std.testing.expect(writeBytes(caller_end, &header));
    _ = linux.shutdown(caller_end, linux.SHUT.WR);
    const muted = muteSerial();
    serveConnection(agent_end);
    unmuteSerial(muted);

    var reply_buf: [64]u8 = undefined;
    try std.testing.expect(readFrame(caller_end, &reply_buf) == null);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.close(agent_end)));
}

test "every base64 reply chunk fits one frame once encoded" {
    for ([_]usize{ read_chunk, log_read_chunk, fs_read_chunk, tty_chunk, port_forward_chunk, duplex_chunk }) |chunk| {
        try std.testing.expect(wire.encodedReplyFits(chunk));
    }
    try std.testing.expect(!wire.encodedReplyFits(64 * 1024));
}

test "a streamed walk frame and its closer still fit one frame" {
    try std.testing.expect(walk_frame_bytes + 2 <= wire.max_frame);
}

// ── A duplex runs on the host, over pipes: no vsock and no VM needed. ─────

/// Both pipes plus the forked server, so the serving code is exercised exactly
/// as it runs in the guest.
const DuplexFixture = struct {
    in_fd: linux.fd_t,
    out_fd: linux.fd_t,
    child_pid: i64,

    fn spawn(argv: []const []const u8) !DuplexFixture {
        var in_fds: [2]linux.fd_t = .{ -1, -1 };
        if (!pipePair(&in_fds)) return error.NoPipe;
        var out_fds: [2]linux.fd_t = .{ -1, -1 };
        if (!pipePair(&out_fds)) {
            closeIfOpen(in_fds[0]);
            closeIfOpen(in_fds[1]);
            return error.NoPipe;
        }
        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) {
            closeIfOpen(in_fds[0]);
            closeIfOpen(in_fds[1]);
            closeIfOpen(out_fds[0]);
            closeIfOpen(out_fds[1]);
            return error.NoFork;
        }
        if (fork_rc == 0) {
            _ = linux.close(in_fds[1]);
            _ = linux.close(out_fds[0]);
            var req = DuplexRequest{ .argv = argv };
            duplexChild(&req, in_fds[0], out_fds[1]);
        }
        _ = linux.close(in_fds[0]);
        _ = linux.close(out_fds[1]);
        return .{ .in_fd = in_fds[1], .out_fd = out_fds[0], .child_pid = @intCast(fork_rc) };
    }

    fn deinit(self: *const DuplexFixture) void {
        duplexKill(self.in_fd, self.out_fd, self.child_pid);
    }
};

/// One request/answer on the duplex, driven through the same `duplexServeOne`
/// the guest host runs. Returns the reply text, borrowed from `buf`.
fn duplexAsk(
    host_end: linux.fd_t,
    caller_end: linux.fd_t,
    fx: *const DuplexFixture,
    request: []const u8,
    buf: []u8,
) ![]const u8 {
    if (!sendFrame(caller_end, request)) return error.NoSend;
    if (!duplexServeOne(host_end, fx.in_fd, fx.out_fd, fx.child_pid)) return error.HostStopped;
    return readFrame(caller_end, buf) orelse error.NoReply;
}

test "a duplex write reaches the server's stdin and its answer comes back" {
    var fx = try DuplexFixture.spawn(&.{"/bin/cat"});
    defer fx.deinit();
    const pair = socketPair() orelse return error.NoSocketPair;
    const host_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 3000);
    defer _ = linux.close(caller_end);

    // The MCP body is opaque bytes here: framing is the host client's job.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1}\n";
    var b64: [128]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, body);
    var frame_buf: [256]u8 = undefined;
    const write_frame = try std.fmt.bufPrint(
        &frame_buf,
        "{{\"op\":\"write\",\"data_b64\":\"{s}\"}}",
        .{encoded},
    );

    var reply_buf: [1024]u8 = undefined;
    const wrote = try duplexAsk(host_end, caller_end, &fx, write_frame, &reply_buf);
    try std.testing.expect(std.mem.indexOf(u8, wrote, "duplex.wrote") != null);

    var echoed = false;
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        const answered = try duplexAsk(host_end, caller_end, &fx, "{\"op\":\"read\",\"max_bytes\":64}", &reply_buf);
        if (std.mem.indexOf(u8, answered, encoded) != null) {
            echoed = true;
            try std.testing.expect(std.mem.indexOf(u8, answered, "\"eof\":false") != null);
            break;
        }
    }
    try std.testing.expect(echoed);
}

test "a duplex read reports the server's exit instead of waiting for bytes" {
    var fx = try DuplexFixture.spawn(&.{ "/bin/sh", "-c", "exit 3" });
    defer fx.deinit();
    const pair = socketPair() orelse return error.NoSocketPair;
    const host_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 3000);
    defer _ = linux.close(caller_end);

    var reply_buf: [1024]u8 = undefined;
    var answered: []const u8 = "";
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        answered = try duplexAsk(host_end, caller_end, &fx, "{\"op\":\"read\",\"max_bytes\":64}", &reply_buf);
        if (std.mem.indexOf(u8, answered, "\"exit_code\":3") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, answered, "\"eof\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered, "\"exited\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered, "\"exit_code\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, answered, "\"data_b64\":\"\"") != null);
}

test "duplex close ends the host loop, and the server is gone afterwards" {
    var fx = try DuplexFixture.spawn(&.{"/bin/cat"});
    const pair = socketPair() orelse return error.NoSocketPair;
    const host_end = pair[0];
    const caller_end = pair[1];
    setReceiveTimeout(caller_end, 3000);
    defer _ = linux.close(caller_end);

    try std.testing.expect(sendFrame(caller_end, "{\"op\":\"close\"}"));
    // `false` is what makes `duplexHost` leave its accept loop and kill the
    // server; a `true` here would keep the process alive forever.
    try std.testing.expect(!duplexServeOne(host_end, fx.in_fd, fx.out_fd, fx.child_pid));
    var reply_buf: [256]u8 = undefined;
    const closed = readFrame(caller_end, &reply_buf) orelse return error.NoReply;
    try std.testing.expect(std.mem.indexOf(u8, closed, "duplex.closed") != null);

    const pid = fx.child_pid;
    fx.deinit();
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(@intCast(pid), .TERM));
}

test "a closed duplex leaves no descriptor behind" {
    const before = liveDescriptors();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var fx = try DuplexFixture.spawn(&.{"/bin/cat"});
        fx.deinit();
    }
    try std.testing.expectEqual(before, liveDescriptors());
}
