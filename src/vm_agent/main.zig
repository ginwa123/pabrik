//! `pabrik-vm-agent` — guest PID 1: mount the pseudo filesystems, create the
//! device nodes this kernel lacks, then serve framed JSON over vsock (`hello`,
//! `exec`, `spawn`, `fs.*`, `shutdown`). Port forwarding is the piece still open.

const std = @import("std");
const linux = std.os.linux;

const vsock_af: u32 = 40;
const sock_stream: u32 = 1;
const cid_any: u32 = 0xFFFF_FFFF;
const agent_port: u32 = 5000;
const max_frame: usize = 64 * 1024;
const read_chunk: usize = 4096;
const arena_bytes: usize = 16 * 1024;
const max_argv: usize = 64;
const default_uid: u32 = 1000;
const default_gid: u32 = 1000;
const max_timeout_ms: u32 = 600_000;
const default_budget: usize = 256 * 1024;
/// `wait4`'s WNOHANG: probe must never block PID 1.
const wno_hang: u32 = 1;
/// Detached jobs log here, and a `read_log` reply carries at most this much of
/// one: 16 KiB of bytes is ~22 KiB of base64, comfortably inside `max_frame`.
const job_log_dir = "/tmp/pabrik";
const log_read_chunk: usize = 16 * 1024;
/// The reply formatter's buffer. A `log.chunk`/`fs.read` reply is base64, so it
/// is bigger than the bytes it carries — 64 KiB of bytes needs 88 KiB of text.
const reply_buf_bytes: usize = 128 * 1024;

const hello_json = "{\"type\":\"hello\",\"agent\":\"pabrik-vm-agent\",\"version\":\"0.2\"}";
const bye_json = "{\"type\":\"bye\"}";

/// Kernel layout: 2 + 2 + 4 + 4 bytes plus 4 of zero padding = 16.
const SockaddrVm = extern struct {
    family: u16,
    reserved: u16 = 0,
    port: u32,
    cid: u32,
    zero: [4]u8 = .{0} ** 4,
};

// ─── transport ───────────────────────────────────────────────────────────

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
        off += rc;
    }
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
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
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

const exec_env = [_:null]?[*:0]const u8{
    "PATH=/bin:/usr/bin",
    "HOME=/workspace",
    "LANG=C",
    "TERM=dumb",
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
const fs_read_chunk: usize = 64 * 1024;
const max_fs_path: usize = 1024;
/// `RESOLVE_BENEATH`: every component is resolved under the workspace fd, so a
/// symlink that leaves the workspace is `EXDEV` rather than a read of something
/// else. The kernel's answer, not a string check, is what contains the path.
const resolve_beneath: u64 = 0x08;
const o_directory: u64 = 0o200000;
/// `AT_REMOVEDIR`: `unlinkat`'s "this is a directory" flag.
const at_removedir: u64 = 0x200;
/// One `fs.write` frame's bytes. A frame is 64 KiB and base64 costs 4 bytes
/// per 3, so the envelope has room; the caller pages a file through this.
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

/// The frame a streamed walk reply is built in, by hand: the agent has no
/// allocator, so the reply's ceiling is this buffer's.
const walk_frame_bytes: usize = 56 * 1024;

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

/// Framed requests until `shutdown`.
fn serve(conn_fd: linux.fd_t) void {
    var payload: [max_frame]u8 = undefined;
    while (true) {
        var header: [4]u8 = undefined;
        if (!readExact(conn_fd, &header)) return;
        const len = std.mem.readInt(u32, &header, .big);
        if (len == 0 or len > max_frame) return;
        if (!readExact(conn_fd, payload[0..len])) return;
        serveRequest(conn_fd, payload[0..len]);
    }
}

pub fn main() void {
    writeAll(1, "\n[pabrik-vm-agent] booting as PID 1\n");
    logLine(if (mountPseudo("proc", "/proc")) "mounted proc" else "MISSING proc");
    logLine(if (mountPseudo("sysfs", "/sys")) "mounted sysfs" else "MISSING sysfs");
    logLine(if (mountPseudo("devtmpfs", "/dev")) "mounted devtmpfs" else "MISSING devtmpfs");
    ensureDev();

    const sock_rc = linux.socket(vsock_af, sock_stream, 0);
    if (linux.errno(sock_rc) != .SUCCESS) {
        logLine("vsock socket failed");
        while (true) _ = linux.pause();
    }
    const listen_fd: linux.fd_t = @intCast(sock_rc);

    var addr = SockaddrVm{ .family = vsock_af, .port = agent_port, .cid = cid_any };
    if (linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(SockaddrVm))) != .SUCCESS or
        linux.errno(linux.listen(listen_fd, 4)) != .SUCCESS)
    {
        logLine("vsock listen failed");
        while (true) _ = linux.pause();
    }
    logLine("listening on vsock port 5000");

    while (true) {
        var peer: SockaddrVm = undefined;
        var peer_len: linux.socklen_t = @sizeOf(SockaddrVm);
        const conn_rc = linux.accept(listen_fd, @ptrCast(&peer), &peer_len);
        if (linux.errno(conn_rc) != .SUCCESS) continue;
        logLine("vsock connection accepted");
        serve(@intCast(conn_rc));
        logLine("vsock connection closed");
    }
}
