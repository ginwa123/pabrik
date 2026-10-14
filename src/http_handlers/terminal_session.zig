//! In-memory PTY session registry for the right-sidebar terminal.

const std = @import("std");
const builtin = @import("builtin");

/// True on the platforms that can host a PTY session.
pub const is_pty_os: bool = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

/// Seconds of zero interaction after which an abandoned session is
/// reaped (24h). Any open (attach flush), poll, input, or resize
/// refreshes the age — only truly untouched sessions die.
pub const idle_timeout_s: i64 = 24 * 3600;
pub const idle_kill_s: i64 = 30 * 60;
pub const busy_output_window_s: i64 = 5 * 60;
pub const max_sessions: u32 = 20;
pub const buffer_cap: usize = 256 * 1024;
/// One poll drains at most this many bytes (32 x 8 KiB reads).
pub const max_drain_bytes_per_call: usize = 256 * 1024;
pub const max_drain_iters: usize = 32;
/// Capacity slack before we give memory back: len stays at `buffer_cap`, but
/// ArrayList capacity can double once on the way up.
pub const buffer_capacity_slack: usize = 64 * 1024;
pub const default_cols: u16 = 80;
pub const default_rows: u16 = 24;
pub const min_dim: u16 = 2;
pub const max_dim: u16 = 1000;

pub const SessionError = error{
    UnsupportedPlatform,
    InvalidCwd,
    CwdNotDir,
    TooManySessions,
    InvalidShell,
    InvalidSize,
    SessionNotFound,
    SessionExited,
    SpawnFailed,
    WriteFailed,
    ResizeFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------
// libc surface (extern "c" — no headers needed, no @cImport)
// ---------------------------------------------------------------------

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

const POLLIN: c_short = 1;
const POLLOUT: c_short = 4;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;

// TIOCSWINSZ: Linux 0x5414, macOS 0x80087467 (_IOW('t', 103, winsize)).
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .macos => 0x80087467,
    else => 0x5414,
};

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, arg: *Winsize) c_int;
extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]?[*:0]const u8) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
/// Wall-clock seconds (libc `time`, portable incl. msvcrt). Only used
/// for idle aging — coarse seconds are plenty.
extern "c" fn time(t: ?*i64) i64;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

// ---------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------

pub const Session = struct {
    id: []u8,
    master_fd: c_int,
    child_pid: c_int,
    cols: u16,
    rows: u16,
    /// Owning user id (plan 2026-09-25, W2.5).
    owner: []u8,
    /// Ring-ish output log: `buf` holds the newest bytes, `base` is the
    /// absolute cursor of `buf[0]`, `total` the absolute cursor of the
    /// end. Bytes in [0, base) were dropped by the cap.
    buf: std.ArrayList(u8),
    base: u64,
    total: u64,
    exited: bool,
    exit_code: ?i32,
    mutex: std.atomic.Mutex,
    /// Wall-clock seconds of the last interaction (open/poll/input/
    /// resize/create). Sessions older than the idle timeout with zero
    /// interaction are reaped by the lazy sweep.
    last_active_s: i64,
    /// Wall-clock seconds of the last explicit user action (input, resize,
    /// attach, create).
    last_user_active_s: i64,
    /// Wall-clock seconds when output last grew + the total cursor at
    /// that moment. Powers the busy-exempt check: a session producing
    /// output (dev server, install) is never idle-killed.
    last_output_at_s: i64,
    last_output_total: u64,

    /// Raw PTY master fd (for the WS pump's poll loop). Valid until
    /// `destroySession`.
    pub fn masterFd(s: *Session) c_int {
        return s.master_fd;
    }

    /// Current absolute output cursor (for WS attach positioning).
    pub fn totalCursor(s: *Session) u64 {
        mutexLock(&s.mutex);
        defer s.mutex.unlock();
        return s.total;
    }
};

var g_mutex: std.atomic.Mutex = .unlocked;
var g_sessions: std.StringHashMap(*Session) = undefined;
var g_inited: bool = false;
var g_id_counter: u64 = 0;
/// Live idle timeout in seconds (tests override via setter).
var g_idle_timeout_s: i64 = idle_timeout_s;
/// Live user-idle kill in seconds (tests override via setter).
var g_idle_kill_s: i64 = idle_kill_s;
/// Live max sessions (tests override via setter).
var g_max_sessions: u32 = max_sessions;
const g_alloc = std.heap.c_allocator;

/// Spin-lock acquire (std.atomic.Mutex has no blocking lock() in
/// 0.16 — same tryLock + spinLoopHint pattern as shell.zig).
fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn registry() *std.StringHashMap(*Session) {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    if (!g_inited) {
        g_sessions = std.StringHashMap(*Session).init(g_alloc);
        g_inited = true;
    }
    return &g_sessions;
}

/// Look a session up by id. The caller must hold no lock; the returned
/// pointer is valid until `destroySession` runs for it.
pub fn getSession(id: []const u8) ?*Session {    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.get(id);
}

pub fn sessionCount() usize {
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.count();
}

/// Wall-clock seconds (libc `time`). Coarse seconds are plenty for idle
/// aging.
fn nowSeconds() i64 {
    return time(null);
}

/// Test-only idle-timeout override in seconds (returns the previous
/// value — restore with defer).
pub fn setIdleTimeoutForTest(timeout_s: i64) i64 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_idle_timeout_s;
    g_idle_timeout_s = timeout_s;
    return prev;
}

/// Test-only user-idle-kill override in seconds.
pub fn setIdleKillForTest(timeout_s: i64) i64 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_idle_kill_s;
    g_idle_kill_s = timeout_s;
    return prev;
}

/// Test-only max-sessions override.
pub fn setMaxSessionsForTest(n: u32) u32 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_max_sessions;
    g_max_sessions = n;
    return prev;
}

/// Test-only hook invoked by `sweepIdleExcluding` right after the victims are
/// detached from the registry (g_mutex already released) and before teardown
/// begins.
var g_sweep_detached_hook: ?*const fn () void = null;

pub fn setSweepDetachedHookForTest(h: ?*const fn () void) void {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    g_sweep_detached_hook = h;
}

/// Pure busy predicate over stamps (unit-tested, no locks): a session is busy
/// when its shell is alive and it produced output within the busy window.
pub fn isBusyByStamps(exited: bool, last_output_at_s: i64, now_s: i64) bool {
    if (exited) return false;
    if (last_output_at_s <= 0) return false;
    return now_s - last_output_at_s < busy_output_window_s;
}

/// Locking busy check for a live session.
pub fn isBusy(s: *Session) bool {
    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    return isBusyByStamps(s.exited, s.last_output_at_s, nowSeconds());
}

/// Explicit user touch (attach/switch): refreshes both the absolute
/// and the user-idle stamps. Background polls must NOT call this.
pub fn touchUser(s: *Session) void {
    if (comptime !is_pty_os) return;
    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    const now = nowSeconds();
    s.last_active_s = now;
    s.last_user_active_s = now;
}

/// Reap sessions with zero interaction older than the idle timeout.
fn sweepIdle() void {
    sweepIdleExcluding(null);
}

/// Same as sweepIdle but never reaps `exclude`: a poll must not free its own
/// session mid-call (old readOutput swept first, then locked the freed
/// pointer — heap UAF surfacing as a remap abort in appendSlice).
fn sweepIdleExcluding(exclude: ?*Session) void {
    if (comptime !is_pty_os) return;
    const now = nowSeconds();
    const reg = registry();
    mutexLock(&g_mutex);
    // Read g_* directly: idleTimeout() would re-lock.
    const timeout = g_idle_timeout_s;
    const kill_after = g_idle_kill_s;
    var victims = std.ArrayList(*Session).empty;
    defer victims.deinit(g_alloc);
    var it = reg.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr.*;
        if (exclude) |ex| {
            if (s == ex) continue;
        }
        const user_idle = now - s.last_user_active_s > kill_after;
        const abs_idle = now - s.last_active_s > timeout;
        const busy = isBusyByStamps(s.exited, s.last_output_at_s, now);
        if (shouldReap(user_idle, abs_idle, busy)) {
            victims.append(g_alloc, s) catch break;
        }
    }
    // Detach every victim from the registry BEFORE dropping the lock.
    for (victims.items) |v| {
        const removed = reg.fetchRemove(v.id);
        std.debug.assert(removed != null);
    }
    g_mutex.unlock();
    if (g_sweep_detached_hook) |h| h();
    for (victims.items) |v| {
        reapSession(v);
    }
}

// ---------------------------------------------------------------------
// Pure validation (unit-tested, no syscalls)
// ---------------------------------------------------------------------

/// Validate create inputs without touching the OS. `cwd` must be a
/// non-empty absolute path; `cols`/`rows` fall back to defaults when
/// null and must land in [min_dim, max_dim] otherwise.
pub fn validateCreate(cwd: []const u8, cols: ?u16, rows: ?u16) SessionError!struct { cols: u16, rows: u16 } {
    if (cwd.len == 0 or !std.fs.path.isAbsolute(cwd)) return error.InvalidCwd;
    const c = cols orelse default_cols;
    const r = rows orelse default_rows;
    if (c < min_dim or c > max_dim or r < min_dim or r > max_dim) return error.InvalidSize;
    return .{ .cols = c, .rows = r };
}

/// Validate a shell override: empty means "default", otherwise it must
/// be absolute (no PATH lookup, no `sh -c` wrapping — the string is
/// exec'd directly).
pub fn validateShell(shell: ?[]const u8) SessionError!void {
    const s = shell orelse return;
    if (s.len == 0) return;
    if (!std.fs.path.isAbsolute(s)) return error.InvalidShell;
}

/// Parse an output cursor query value: missing/garbage falls back to 0
/// (full replay from the buffer's oldest retained byte).
pub fn parseCursor(raw: ?[]const u8) u64 {
    const s = raw orelse return 0;
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

/// Pure trim math (unit-tested, no locks, no alloc): how many oldest
/// bytes to drop when `current_len` exceeds `cap`.
pub fn trimDropLen(current_len: usize, cap: usize) usize {
    return if (current_len > cap) current_len - cap else 0;
}

/// Pure large-chunk math: when a single incoming chunk is bigger than
/// the whole cap, keep only its tail. Returns the start offset into
/// the incoming bytes (0 when it fits).
pub fn tailKeepStart(incoming_len: usize, cap: usize) usize {
    return if (incoming_len > cap) incoming_len - cap else 0;
}

/// Pure reap predicate (unit-tested): mirrors sweepIdle's victim test
/// so the rule stays in one place.
pub fn shouldReap(user_idle: bool, abs_idle: bool, busy: bool) bool {
    return (user_idle and !busy) or abs_idle;
}

// ---------------------------------------------------------------------
// Lifecycle (POSIX only — every reference is comptime-gated)
// ---------------------------------------------------------------------

pub const SessionInfo = struct {
    id: []const u8,
    pid: i32,
};

/// Spawn a shell on a fresh PTY. `shell` null/empty selects `$SHELL`, then
/// `/bin/bash`, then `/bin/sh`. `owner` is the server-derived user id (plan
/// 2026-09-25, W2.5).
pub fn createSession(io: std.Io, cwd: []const u8, shell: ?[]const u8, cols: ?u16, rows: ?u16, owner: []const u8) SessionError!SessionInfo {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    return createSessionPosix(io, cwd, shell, cols, rows, owner);
}

/// True when `caller_owner` may drive `s`.
pub fn mayAccess(s: *Session, caller_owner: []const u8) bool {
    if (s.owner.len == 0 or caller_owner.len == 0) return true;
    return std.mem.eql(u8, s.owner, caller_owner);
}

/// Look up a session by id AND check the caller may drive it. Returns null
/// for both "no such session" and "someone else's session", so a foreign id
/// is indistinguishable from a missing one (404, never 403).
pub fn getSessionForOwner(id: []const u8, caller_owner: []const u8) ?*Session {
    const s = getSession(id) orelse return null;
    if (!mayAccess(s, caller_owner)) return null;
    return s;
}

fn allocId() SessionError![]u8 {
    mutexLock(&g_mutex);
    g_id_counter += 1;
    const n = g_id_counter;
    g_mutex.unlock();
    // Counter-only: unique within the process lifetime, which is the
    // registry's lifetime (no persistence, no cross-process readers).
    return std.fmt.allocPrint(g_alloc, "term-{x}", .{n}) catch return error.OutOfMemory;
}

fn defaultShell() []const u8 {
    // $SHELL via libc (no allocator, no std.posix.getenv in 0.16).
    if (getenv("SHELL")) |s| {
        const span = std.mem.span(s);
        if (span.len > 0 and std.fs.path.isAbsolute(span)) return span;
    }
    return "/bin/bash";
}

fn createSessionPosix(io: std.Io, cwd: []const u8, shell_opt: ?[]const u8, cols_opt: ?u16, rows_opt: ?u16, owner: []const u8) SessionError!SessionInfo {
    // Empty cwd (fresh standalone chats have no session cwd yet): fall back
    // to the server process cwd, mirroring the agent shell tools'
    // optional-cwd behavior.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const eff_cwd: []const u8 = if (cwd.len == 0) blk: {
        const ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdNotDir;
        break :blk std.mem.span(ptr);
    } else cwd;

    const dims = try validateCreate(eff_cwd, cols_opt, rows_opt);
    try validateShell(shell_opt);

    // eff_cwd must exist and be a directory (checked before fork so the
    // child never has to report it).
    {
        var dir = std.Io.Dir.openDirAbsolute(io, eff_cwd, .{}) catch return error.CwdNotDir;
        dir.close(io);
    }

    // Lazy idle sweep: abandoned shells age out instead of
    // accumulating forever. Sweep first so a reaped slot frees
    // immediately, then enforce the max-sessions cap with 429.
    sweepIdle();
    {
        const reg = registry();
        mutexLock(&g_mutex);
        const n = reg.count();
        const cap = g_max_sessions;
        g_mutex.unlock();
        if (n >= cap) return error.TooManySessions;
    }

    const shell_path: []const u8 = blk: {
        const s = shell_opt orelse "";
        if (s.len > 0) break :blk s;
        break :blk defaultShell();
    };

    var win = Winsize{ .ws_row = dims.rows, .ws_col = dims.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &win);
    if (pid < 0) return error.SpawnFailed;

    if (pid == 0) {
        // Child: never return. NUL-terminate via stack copies (no
        // allocator use after fork).
        childMain(eff_cwd, shell_path);
    }

    // Parent.
    errdefer {
        _ = kill(pid, SIGKILL);
        _ = close(master);
    }

    const id = try allocId();
    errdefer g_alloc.free(id);

    const owner_copy = g_alloc.dupe(u8, owner) catch return error.OutOfMemory;
    errdefer g_alloc.free(owner_copy);

    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    errdefer g_alloc.destroy(session);
    session.* = .{
        .id = id,
        .master_fd = master,
        .child_pid = pid,
        .cols = dims.cols,
        .rows = dims.rows,
        .owner = owner_copy,
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = nowSeconds(),
        .last_user_active_s = nowSeconds(),
        .last_output_at_s = 0,
        .last_output_total = 0,
    };

    const reg = registry();
    mutexLock(&g_mutex);
    reg.put(id, session) catch {
        g_mutex.unlock();
        return error.OutOfMemory;
    };
    g_mutex.unlock();

    return .{ .id = id, .pid = @intCast(pid) };
}

/// Child side of forkpty: chdir, set TERM, exec the shell. Diverges
/// (noreturn) — on any failure `_exit(127)` so the parent observes a
/// clean child exit instead of a hung PTY.
fn childMain(cwd: []const u8, shell_path: []const u8) noreturn {
    // Stack buffers: paths longer than max_path_bytes fail closed.
    var cwd_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var shell_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (cwd.len > std.fs.max_path_bytes or shell_path.len > std.fs.max_path_bytes) _exit(127);
    @memcpy(cwd_buf[0..cwd.len], cwd);
    cwd_buf[cwd.len] = 0;
    @memcpy(shell_buf[0..shell_path.len], shell_path);
    shell_buf[shell_path.len] = 0;

    if (chdir(cwd_buf[0..cwd.len :0]) != 0) _exit(127);
    _ = setenv("TERM", "xterm-256color", 1);
    var argv = [_:null]?[*:0]const u8{ shell_buf[0..shell_path.len :0], null };
    _ = execvp(shell_buf[0..shell_path.len :0], argv[0..]);
    _exit(127);
}

/// Drain newly arrived output into the session buffer and refresh the
/// exit state. Safe to call on every poll; never blocks (zero-timeout
/// `poll()` gates each `read()`).
pub fn drainSession(s: *Session) void {
    if (comptime !is_pty_os) return;
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
}

fn drainLocked(s: *Session) void {
    var pfds = [_]PollFd{.{ .fd = s.master_fd, .events = POLLIN, .revents = 0 }};
    var chunk: [8192]u8 = undefined;
    var drained: usize = 0;
    var iters: usize = 0;
    while (iters < max_drain_iters and drained < max_drain_bytes_per_call) {
        iters += 1;
        if (poll(&pfds, 1, 0) <= 0) return;
        if (pfds[0].revents & POLLIN == 0) return;
        const n = read(s.master_fd, &chunk, chunk.len);
        if (n <= 0) return; // EAGAIN/EIO/closed slave — exit state comes from waitpid.
        const m: usize = @intCast(n);
        appendLocked(s, chunk[0..m]);
        drained += m;
    }
}

fn appendLocked(s: *Session, bytes: []const u8) void {
    // Huge single chunk (>= cap): skip the transient giant alloc and
    // keep only the tail. Cursor math preserves the absolute stream:
    // everything before base' was dropped by the cap.
    if (bytes.len >= buffer_cap) {
        const start = tailKeepStart(bytes.len, buffer_cap);
        s.buf.clearRetainingCapacity();
        s.buf.appendSlice(g_alloc, bytes[start..]) catch {
            s.total += bytes.len;
            s.base = s.total;
            s.buf.clearRetainingCapacity();
            s.last_output_at_s = nowSeconds();
            s.last_output_total = s.total;
            return;
        };
        s.total += bytes.len;
        s.base = s.total - s.buf.items.len;
        s.last_output_at_s = nowSeconds();
        s.last_output_total = s.total;
        shrinkCapacityLocked(s);
        return;
    }
    s.buf.appendSlice(g_alloc, bytes) catch {
        // OOM mid-stream: drop the incoming chunk rather than killing
        // the session; the cursor still advances so readers stay in
        // sync (they observe a gap, not a stall).
        s.total += bytes.len;
        s.base = s.total;
        s.buf.clearRetainingCapacity();
        s.last_output_at_s = nowSeconds();
        s.last_output_total = s.total;
        return;
    };
    s.total += bytes.len;
    s.last_output_at_s = nowSeconds();
    s.last_output_total = s.total;
    if (s.buf.items.len > buffer_cap) {
        const drop = trimDropLen(s.buf.items.len, buffer_cap);
        // Ordered drop of the oldest bytes.
        std.mem.copyForwards(u8, s.buf.items[0..s.buf.items.len - drop], s.buf.items[drop..]);
        s.buf.items.len -= drop;
        s.base += drop;
    }
    shrinkCapacityLocked(s);
}

/// Give bloated capacity back after a burst. Len stays at the cap;
/// only the spare allocation is released so the next burst doesn't
/// remap from a pinned 512 KiB+ base under memory pressure.
fn shrinkCapacityLocked(s: *Session) void {
    if (s.buf.capacity > buffer_cap + buffer_capacity_slack) {
        s.buf.shrinkAndFree(g_alloc, buffer_cap);
    }
}

/// Non-blocking child reaping. Sets `exited`/`exit_code` exactly once.
fn pollExitLocked(s: *Session) void {
    if (s.exited) return;
    var status: c_int = 0;
    const rc = waitpid(s.child_pid, &status, WNOHANG);
    if (rc <= 0) return;
    s.exited = true;
    s.exit_code = decodeStatus(status);
}

fn decodeStatus(status: c_int) i32 {
    const u: c_uint = @bitCast(status);
    // WIFEXITED: low 7 bits zero. WEXITSTATUS: bits 8..15.
    if ((u & 0x7f) == 0) return @intCast((u >> 8) & 0xff);
    // Signaled: report as a negative signal number (128+SIGKILL
    // shell convention would collide with real exit codes).
    const sig = u & 0x7f;
    if (sig == 0x7f) return -100; // stopped, not exited — shouldn't happen via WNOHANG reap.
    return -@as(i32, @intCast(sig));
}

/// Write input bytes to the PTY master (terminal input = keystrokes).
pub fn writeInput(s: *Session, data: []const u8) SessionError!usize {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    s.last_user_active_s = s.last_active_s;
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
    if (s.exited) return error.SessionExited;
    var off: usize = 0;
    var pfds = [_]PollFd{.{ .fd = s.master_fd, .events = POLLOUT, .revents = 0 }};
    while (off < data.len) {
        if (poll(&pfds, 1, 1000) <= 0) return error.WriteFailed;
        if (pfds[0].revents & POLLOUT == 0) return error.WriteFailed;
        const n = write(s.master_fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    return off;
}

pub const OutputSlice = struct {
    data: []const u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

/// Read output since `cursor` (absolute). `data` borrows the session
/// buffer — the caller must copy it before the next registry call.
/// Call `drainSession` first (or use `readOutput`, which does).
pub fn sliceOutput(s: *Session, cursor: u64) OutputSlice {
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    defer s.mutex.unlock();
    const start = @max(cursor, s.base);
    if (start >= s.total) {
        return .{ .data = &.{}, .cursor = s.total, .exited = s.exited, .exit_code = s.exit_code };
    }
    const off = start - s.base;
    return .{
        .data = s.buf.items[off..],
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

/// Drain + slice in one call (the poll endpoint's primitive).
pub fn readOutput(s: *Session, cursor: u64) OutputSlice {
    if (comptime !is_pty_os) {
        return .{ .data = &.{}, .cursor = cursor, .exited = true, .exit_code = null };
    }
    // Every poll reaps the long-idle, but polls do NOT refresh the user stamp
    // — only explicit input/resize/attach does.
    sweepIdleExcluding(s);
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
    const start = @max(cursor, s.base);
    if (start >= s.total) {
        return .{ .data = &.{}, .cursor = s.total, .exited = s.exited, .exit_code = s.exit_code };
    }
    const off = start - s.base;
    return .{
        .data = s.buf.items[off..],
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

/// Owned variant of readOutput: drains under the session lock and dupes the
/// requested tail into `allocator` before unlocking, so the caller holds no
/// borrow into the live ring buffer.
pub const OwnedOutput = struct {
    data: []u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

pub fn readOutputAlloc(allocator: std.mem.Allocator, s: *Session, cursor: u64) !OwnedOutput {
    if (comptime !is_pty_os) {
        return .{ .data = try allocator.alloc(u8, 0), .cursor = cursor, .exited = true, .exit_code = null };
    }
    sweepIdleExcluding(s);
    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    s.last_active_s = nowSeconds();
    drainLocked(s);
    pollExitLocked(s);
    const start = @max(cursor, s.base);
    if (start >= s.total) {
        return .{
            .data = try allocator.alloc(u8, 0),
            .cursor = s.total,
            .exited = s.exited,
            .exit_code = s.exit_code,
        };
    }
    const off = start - s.base;
    const owned = try allocator.dupe(u8, s.buf.items[off..]);
    return .{
        .data = owned,
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

/// Send SIGWINCH-sized window to the child (TIOCSWINSZ + SIGWINCH is
/// delivered by the kernel on resize).
pub fn resizeSession(s: *Session, cols: u16, rows: u16) SessionError!void {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    if (cols < min_dim or cols > max_dim or rows < min_dim or rows > max_dim) return error.InvalidSize;
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    s.last_user_active_s = s.last_active_s;
    defer s.mutex.unlock();
    if (s.exited) return error.SessionExited;
    var win = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (ioctl(s.master_fd, TIOCSWINSZ, &win) != 0) return error.ResizeFailed;
    s.cols = cols;
    s.rows = rows;
}

/// Kill the child (if running), close the master, drop the session.
pub fn destroySession(id: []const u8) SessionError!void {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    g_mutex.unlock();
    reapSession(entry.value);
}

/// Owner-checked `destroySession` (plan 2026-09-25, W2.5).
pub fn destroySessionForOwner(id: []const u8, caller_owner: []const u8) SessionError!void {
    if (comptime !is_pty_os) return error.UnsupportedPlatform;
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    const allowed = mayAccess(entry.value, caller_owner);
    if (!allowed) {
        // Put it back: the caller is not allowed to destroy it.
        reg.put(entry.key, entry.value) catch {};
        g_mutex.unlock();
        return error.SessionNotFound;
    }
    g_mutex.unlock();
    reapSession(entry.value);
}

/// Tear down a session that is NO LONGER in the registry — the caller
/// must have removed it under g_mutex (exclusive ownership) and must
/// not touch `s` afterwards. Frees `s.id` and `s` itself.
fn reapSession(s: *Session) void {
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    const already_exited = s.exited;
    s.mutex.unlock();
    if (!already_exited) _ = kill(s.child_pid, SIGKILL);

    // Bounded reap so the child never stays a zombie (50 x 10ms).
    var i: usize = 0;
    var status: c_int = 0;
    while (i < 50) : (i += 1) {
        if (waitpid(s.child_pid, &status, WNOHANG) != 0) break;
        sleepMillis(10);
    }

    _ = close(s.master_fd);
    s.buf.deinit(g_alloc);
    g_alloc.free(s.owner);
    g_alloc.free(s.id);
    g_alloc.destroy(s);
}

fn sleepMillis(ms: u64) void {
    const ts = Timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&ts, null);
}

// ---------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "validateCreate accepts absolute cwd with defaults" {
    const dims = try validateCreate("/tmp", null, null);
    try testing.expectEqual(default_cols, dims.cols);
    try testing.expectEqual(default_rows, dims.rows);
}

test "validateCreate rejects relative/empty cwd and bad sizes" {
    try testing.expectError(error.InvalidCwd, validateCreate("", null, null));
    try testing.expectError(error.InvalidCwd, validateCreate("relative/path", null, null));
    try testing.expectError(error.InvalidSize, validateCreate("/tmp", 1, 24));
    try testing.expectError(error.InvalidSize, validateCreate("/tmp", 80, 1001));
    const dims = try validateCreate("/tmp", 100, 40);
    try testing.expectEqual(@as(u16, 100), dims.cols);
    try testing.expectEqual(@as(u16, 40), dims.rows);
}

test "validateShell rejects relative shells, accepts absolute/empty" {
    try validateShell(null);
    try validateShell("");
    try validateShell("/bin/bash");
    try testing.expectError(error.InvalidShell, validateShell("bash"));
}

test "parseCursor defaults to 0 on missing/garbage" {
    try testing.expectEqual(@as(u64, 0), parseCursor(null));
    try testing.expectEqual(@as(u64, 0), parseCursor(""));
    try testing.expectEqual(@as(u64, 0), parseCursor("nope"));
    try testing.expectEqual(@as(u64, 42), parseCursor("42"));
}

test "decodeStatus maps normal exits and signals" {
    // exit(3): status word 0x0300.
    try testing.expectEqual(@as(i32, 3), decodeStatus(0x0300));
    try testing.expectEqual(@as(i32, 0), decodeStatus(0));
    // Killed by SIGKILL (9): 0x0009 -> -9.
    try testing.expectEqual(@as(i32, -9), decodeStatus(0x0009));
}

test "empty cwd falls back to the server cwd (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;

    const info = try createSession(testing.io, "", "/bin/sh", 80, 24, "user_test");
    defer destroySession(info.id) catch {};
    const s = getSession(info.id) orelse return error.SessionNotFound;
    _ = s;
}

test "idle sweep reaps untouched sessions, keeps active ones (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const a = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    const a_id = try testing.allocator.dupe(u8, a.id);
    defer testing.allocator.free(a_id);
    const b = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    defer destroySession(b.id) catch {};

    // Backdate a past the timeout (both stamps); touch b's user stamp
    // so it stays fresh. A bare output poll must NOT save a session.
    const sa = getSession(a_id) orelse return error.SessionNotFound;
    mutexLock(&sa.mutex);
    sa.last_active_s -= 7200;
    sa.last_user_active_s = sa.last_active_s;
    sa.mutex.unlock();
    const sb = getSession(b.id) orelse return error.SessionNotFound;
    touchUser(sb);
    _ = readOutput(sb, 0);

    sweepIdle();
    try testing.expect(getSession(a_id) == null);
    try testing.expect(getSession(b.id) != null);
}

test "isBusyByStamps exempts recent output, not exited or stale" {
    try testing.expect(isBusyByStamps(false, 1000, 1000 + busy_output_window_s - 1));
    try testing.expect(!isBusyByStamps(false, 1000, 1000 + busy_output_window_s + 1));
    try testing.expect(!isBusyByStamps(false, 0, 1000));
    try testing.expect(!isBusyByStamps(true, 1000, 1001));
}

test "poll does not refresh the user stamp (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    defer destroySession(info.id) catch {};
    const s = getSession(info.id) orelse return error.SessionNotFound;
    mutexLock(&s.mutex);
    s.last_user_active_s -= 100;
    const user_before = s.last_user_active_s;
    s.mutex.unlock();
    _ = readOutput(s, 0);
    mutexLock(&s.mutex);
    const user_after = s.last_user_active_s;
    s.mutex.unlock();
    try testing.expectEqual(user_before, user_after);
}

test "busy session survives the user-idle kill (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_kill = setIdleKillForTest(60);
    defer _ = setIdleKillForTest(prev_kill);
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);

    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    const id = try testing.allocator.dupe(u8, info.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};
    const s = getSession(id) orelse return error.SessionNotFound;
    // User idle past the kill window, but output just grew (dev server).
    mutexLock(&s.mutex);
    s.last_user_active_s = nowSeconds() - 3600;
    s.last_active_s = nowSeconds();
    s.last_output_at_s = nowSeconds();
    s.last_output_total = s.total + 1;
    s.mutex.unlock();

    sweepIdle();
    try testing.expect(getSession(id) != null);
}

test "max sessions cap rejects over the limit (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_max = setMaxSessionsForTest(2);
    defer _ = setMaxSessionsForTest(prev_max);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);

    const a = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    defer destroySession(a.id) catch {};
    const b = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    defer destroySession(b.id) catch {};
    try testing.expectError(error.TooManySessions, createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test"));
}

test "spawned shell echoes input (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;

    const cwd = "/tmp";
    const info = try createSession(testing.io, cwd, "/bin/sh", 80, 24, "user_test");
    defer destroySession(info.id) catch {};

    const s = getSession(info.id) orelse return error.SessionNotFound;
    // Give the shell a moment to start, then send a marker.
    sleepMillis(500);
    _ = try writeInput(s, "echo MARKER-7f3a9c\n");

    // Poll for the marker (shell echo + command output).
    var found = false;
    var cursor: u64 = 0;
    var ticks: usize = 0;
    while (ticks < 100) : (ticks += 1) {
        const out = readOutput(s, cursor);
        cursor = out.cursor;
        if (std.mem.indexOf(u8, out.data, "MARKER-7f3a9c") != null) {
            found = true;
            break;
        }
        if (out.exited) break;
        sleepMillis(100);
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------
// Crash-fix regression tests (TDD: terminal buffer remap abort)
// ---------------------------------------------------------------------

test "trimDropLen keeps buffer at cap" {
    try testing.expectEqual(@as(usize, 0), trimDropLen(100, buffer_cap));
    try testing.expectEqual(@as(usize, 0), trimDropLen(buffer_cap, buffer_cap));
    try testing.expectEqual(@as(usize, 1), trimDropLen(buffer_cap + 1, buffer_cap));
    try testing.expectEqual(@as(usize, 8192), trimDropLen(buffer_cap + 8192, buffer_cap));
}

test "tailKeepStart keeps only the tail of oversized chunks" {
    try testing.expectEqual(@as(usize, 0), tailKeepStart(100, buffer_cap));
    try testing.expectEqual(@as(usize, 0), tailKeepStart(buffer_cap, buffer_cap));
    try testing.expectEqual(@as(usize, 1), tailKeepStart(buffer_cap + 1, buffer_cap));
    try testing.expectEqual(@as(usize, 8192), tailKeepStart(buffer_cap + 8192, buffer_cap));
}

test "shouldReap mirrors the sweep victim rule" {
    try testing.expect(shouldReap(true, false, false));
    try testing.expect(!shouldReap(true, false, true));
    try testing.expect(shouldReap(false, true, false));
    try testing.expect(shouldReap(false, true, true));
    try testing.expect(!shouldReap(false, false, false));
}

test "drain budget bounds one poll (no unbounded spin)" {
    try testing.expect(max_drain_iters * 8192 >= max_drain_bytes_per_call);
    try testing.expectEqual(@as(usize, 256 * 1024), max_drain_bytes_per_call);
    try testing.expectEqual(@as(usize, 32), max_drain_iters);
}

test "readOutput never reaps its own session mid-call (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(1);
    defer _ = setIdleKillForTest(prev_kill);

    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    const id = try testing.allocator.dupe(u8, info.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};
    const s = getSession(id) orelse return error.SessionNotFound;
    // User-idle past the 1s kill window, but absolutely fresh: the old
    // readOutput swept first and freed self before locking (UAF). The
    // fixed version excludes self from its own sweep.
    mutexLock(&s.mutex);
    s.last_user_active_s = nowSeconds() - 3600;
    s.last_active_s = nowSeconds();
    s.mutex.unlock();

    _ = readOutput(s, 0);
    try testing.expect(getSession(id) != null);
}

test "readOutputAlloc returns an owned copy independent of the ring (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
    defer destroySession(info.id) catch {};
    const s = getSession(info.id) orelse return error.SessionNotFound;
    sleepMillis(500);
    _ = try writeInput(s, "echo OWNED-COPY-4d2e\n");
    var cursor: u64 = 0;
    var found = false;
    var ticks: usize = 0;
    while (ticks < 50) : (ticks += 1) {
        const out = try readOutputAlloc(testing.allocator, s, cursor);
        defer testing.allocator.free(out.data);
        cursor = out.cursor;
        if (std.mem.indexOf(u8, out.data, "OWNED-COPY-4d2e") != null) {
            found = true;
            break;
        }
        if (out.exited) break;
        sleepMillis(100);
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------
// Crash-fix regression: sweep vs concurrent destroy race (SEGV in
// destroySession's fetchRemove hashing a freed id slice)

/// Thread entry points for the sweep/destroy race test (file scope:
/// thread fns cannot capture test locals).
const SweepRace = struct {
    var parked: std.atomic.Value(bool) = .init(false);

    fn sweepAll() void {
        sweepIdle();
    }
    fn parkAfterDetach() void {
        parked.store(true, .release);
        sleepMillis(200);
    }
};

test "concurrent sweep and destroy never double-free a victim (posix only)" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_kill = setIdleKillForTest(1);
    defer _ = setIdleKillForTest(prev_kill);
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    defer setSweepDetachedHookForTest(null);

    // The old sweep collected `*Session` pointers, dropped g_mutex, then
    // called destroySession(v.id) per victim.
    const rounds: usize = 3;
    const per_round: usize = 3;
    var owned_ids = std.ArrayList([]u8).empty;
    defer {
        for (owned_ids.items) |id| testing.allocator.free(id);
        owned_ids.deinit(testing.allocator);
    }

    var r: usize = 0;
    while (r < rounds) : (r += 1) {
        var victims: [per_round]*Session = undefined;
        var i: usize = 0;
        while (i < per_round) : (i += 1) {
            const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_test");
            // Test-owned id copies: the session's own id buffer is freed by
            // whoever reaps it, so the destroy side must hash its own stable
            // slice (mirrors DELETE, whose id comes from the request, not the
            const owned = try testing.allocator.dupe(u8, info.id);
            errdefer testing.allocator.free(owned);
            try owned_ids.append(testing.allocator, owned);
            victims[i] = getSession(owned) orelse return error.SessionNotFound;
        }
        // Make every session a sweep victim (idle past kill, never busy).
        for (victims) |s| {
            mutexLock(&s.mutex);
            s.last_active_s = nowSeconds() - 7200;
            s.last_user_active_s = s.last_active_s;
            s.last_output_at_s = 0;
            s.mutex.unlock();
        }

        SweepRace.parked.store(false, .release);
        setSweepDetachedHookForTest(SweepRace.parkAfterDetach);
        const sweeper = try std.Thread.spawn(.{}, SweepRace.sweepAll, .{});
        var spins: usize = 0;
        while (!SweepRace.parked.load(.acquire)) {
            sleepMillis(1);
            spins += 1;
            if (spins > 5000) break;
        }
        try testing.expect(SweepRace.parked.load(.acquire));
        setSweepDetachedHookForTest(null);

        // Destroy side of the race: after the handoff the victims belong to
        // the sweeper, so every destroy must observe SessionNotFound — never
        // free memory the sweeper still points at.
        const base = owned_ids.items.len - per_round;
        for (owned_ids.items[base..]) |id| {
            try testing.expectError(error.SessionNotFound, destroySession(id));
        }

        sweeper.join();
        // Exactly one side owns each victim; nothing leaks or
        // double-frees.
        try testing.expectEqual(@as(usize, 0), sessionCount());
    }
}

// ---------------------------------------------------------------------
// Per-user terminal isolation (plan 2026-09-25, W2.5)
// ---------------------------------------------------------------------

test "mayAccess: same owner allowed, different owner denied" {
    var s = Session{
        .id = @constCast("t1"),
        .master_fd = -1,
        .child_pid = 0,
        .cols = 80,
        .rows = 24,
        .owner = @constCast("user_a"),
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = 0,
        .last_user_active_s = 0,
        .last_output_at_s = 0,
        .last_output_total = 0,
    };
    try testing.expect(mayAccess(&s, "user_a"));
    try testing.expect(!mayAccess(&s, "user_b"));
}

test "mayAccess: an empty owner on either side means no identity (auth off)" {
    // Auth off: the session was created with no owner, so every caller may
    // attach — the pre-isolation behaviour.
    var ownerless = Session{
        .id = @constCast("t2"),
        .master_fd = -1,
        .child_pid = 0,
        .cols = 80,
        .rows = 24,
        .owner = @constCast(""),
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = 0,
        .last_user_active_s = 0,
        .last_output_at_s = 0,
        .last_output_total = 0,
    };
    try testing.expect(mayAccess(&ownerless, "user_a"));
    try testing.expect(mayAccess(&ownerless, ""));

    // A caller with no identity (auth off) may attach to an owned session.
    var owned = ownerless;
    owned.owner = @constCast("user_a");
    try testing.expect(mayAccess(&owned, ""));
}

test "getSessionForOwner: foreign id is indistinguishable from a missing one" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_a");
    const id = try testing.allocator.dupe(u8, info.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    // The owner can reach it; another user gets null (=> 404 at the handler).
    try testing.expect(getSessionForOwner(id, "user_a") != null);
    try testing.expect(getSessionForOwner(id, "user_b") == null);
    // An unknown id is also null — the two cases are indistinguishable.
    try testing.expect(getSessionForOwner("term-does-not-exist", "user_a") == null);
}

test "destroySessionForOwner: a foreign caller cannot kill the session" {
    if (comptime !is_pty_os) return error.SkipZigTest;
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const info = try createSession(testing.io, "/tmp", "/bin/sh", 80, 24, "user_a");
    const id = try testing.allocator.dupe(u8, info.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    // B's attempt reports "not found" and the session survives.
    try testing.expectError(error.SessionNotFound, destroySessionForOwner(id, "user_b"));
    try testing.expect(getSession(id) != null);

    // A can still destroy its own session.
    try destroySessionForOwner(id, "user_a");
    try testing.expect(getSession(id) == null);
}
