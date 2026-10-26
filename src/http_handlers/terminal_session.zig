//! In-memory PTY session registry for the right-sidebar terminal.

const std = @import("std");
const builtin = @import("builtin");
const loggermod = @import("../modules/logger/Logger.zig");

/// Which pseudo-terminal backend this host has.
///
///   * `posix_pty` — `forkpty(3)`: Linux and macOS.
pub const PtyBackend = enum { posix_pty, conpty, none };

pub const pty_backend: PtyBackend = switch (builtin.os.tag) {
    .linux, .macos => .posix_pty,
    .windows => .conpty,
    else => .none,
};

/// True on the platforms that can host a PTY session. Kept as the one
/// name every caller (and `terminal_ws.zig`) gates on — it is now true on
/// Windows too, because ConPTY is a real PTY and not a pipe fallback.
pub const is_pty_os: bool = pty_backend != .none;

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
/// Capacity slack before we give memory back: an append grows to ~1.5x what it
/// asked for, so a buffer can sit above this while still holding under the cap.
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
/// `VOID Sleep(DWORD dwMilliseconds);` (Win32 kernel32) — the only sleep a
/// non-PTY host has, since `nanosleep` does not exist there.
extern "kernel32" fn Sleep(dw_milliseconds: u32) callconv(.winapi) void;

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

// ---------------------------------------------------------------------
// Win32 ConPTY surface (extern "kernel32" / "ws2_32" — no @cImport)
//

/// `HANDLE` — an opaque kernel object handle (pointer-sized). Absence is
/// modelled as `null`, never as `INVALID_HANDLE_VALUE`.
const HANDLE = *anyopaque;
/// `BOOL` — a 32-bit signed int in the Win32 ABI (not Zig's `bool`).
const WINBOOL = c_int;
const DWORD = u32;
/// `HRESULT` — `< 0` means failure.
const HRESULT = i32;
/// `COORD` — character-cell dimensions. X is the COLUMN count (this
/// ordering is the classic Win32 trap: it is X-then-Y, i.e. cols-first).
const Coord = extern struct { X: i16, Y: i16 };

const SecurityAttributes = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: WINBOOL,
};

/// `STARTUPINFOW` (the `W` = UTF-16 variant).
const StartupInfoW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?[*]u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

/// `STARTUPINFOEXW` — a `STARTUPINFOW` immediately followed by the
/// attribute-list pointer. `cb` must be `@sizeOf` THIS struct, which is
/// what tells `CreateProcessW` the attribute list is present.
const StartupInfoExW = extern struct {
    StartupInfo: StartupInfoW,
    lpAttributeList: ?*anyopaque,
};

const ProcessInformation = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` — the attribute slot that hands
/// the fresh pseudoconsole to the child instead of letting it allocate a
/// console of its own.
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
/// `EXTENDED_STARTUPINFO_PRESENT`.
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
/// `HANDLE_FLAG_INHERIT`.
const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
/// `STARTF_USESTDHANDLES` — "the hStd* fields are the child's standard
/// handles, use THEM". Load-bearing on both Windows backends: without it the
/// OS quietly duplicates the CALLER's standard handles into a console-flagged
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
/// `WaitForSingleObject`'s "signaled" result.
const WAIT_OBJECT_0: DWORD = 0;
/// `WaitForSingleObject`'s "the deadline passed" result.
const WAIT_TIMEOUT: DWORD = 258;

extern "kernel32" fn CreatePseudoConsole(size: Coord, hInput: HANDLE, hOutput: HANDLE, dwFlags: DWORD, phPC: *HANDLE) callconv(.winapi) HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HANDLE, size: Coord) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HANDLE) callconv(.winapi) void;
extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*SecurityAttributes, nSize: DWORD) callconv(.winapi) WINBOOL;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.winapi) WINBOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) WINBOOL;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) WINBOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) WINBOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) WINBOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) WINBOOL;
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) WINBOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(lpAttributeList: ?*anyopaque, dwAttributeCount: DWORD, dwFlags: DWORD, lpSize: *usize) callconv(.winapi) WINBOOL;
extern "kernel32" fn UpdateProcThreadAttribute(lpAttributeList: *anyopaque, dwFlags: DWORD, attribute: usize, lpValue: *const anyopaque, cbSize: usize, lpPreviousValue: ?*anyopaque, lpReturnSize: ?*usize) callconv(.winapi) WINBOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SecurityAttributes,
    lpThreadAttributes: ?*SecurityAttributes,
    bInheritHandles: WINBOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?[*:0]const u16,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *StartupInfoW,
    lpProcessInformation: *ProcessInformation,
) callconv(.winapi) WINBOOL;

/// `WSAPOLLFD` — Winsock's poll record. `fd` is POINTER-sized (`SOCKET`
/// is `UINT_PTR`), unlike POSIX `struct pollfd`, so the `PollFd` above
/// cannot be reused: a 4-byte `fd` would put `events` four bytes early
const WsaPollFd = extern struct { fd: usize, events: i16, revents: i16 };
/// `POLLRDNORM` — Winsock's "readable" bit. It is 0x0100, NOT POSIX
/// `POLLIN`'s 0x001; the two spaces do not overlap.
const POLLRDNORM: i16 = 0x0100;
extern "ws2_32" fn WSAPoll(fdarray: [*]WsaPollFd, nfds: c_ulong, timeout: c_int) callconv(.c) c_int;

/// Widen kabelweb's `i32` SOCKET value to the pointer-sized `SOCKET`
/// `WSAPOLLFD.fd` wants. Sign-preserving on purpose: `-1`
/// (`INVALID_SOCKET`) must widen to the all-ones pattern `WSAPoll`
fn socketToUsize(sock: i32) usize {
    return @as(usize, @bitCast(@as(isize, sock)));
}

/// Which side of a websocket pump's multiplex has something to say.
pub const Readiness = struct { pty: bool, sock: bool };

/// Block until the session has console output or the client socket is
/// readable, or `timeout_ms` elapses. One call site (`terminal_ws.zig`),
/// so neither backend's readiness vocabulary leaks upward.
pub fn waitReadable(s: *Session, client_fd: i32, timeout_ms: c_int) Readiness {
    if (comptime pty_backend == .conpty) {
        var fds = [_]WsaPollFd{.{ .fd = socketToUsize(client_fd), .events = POLLRDNORM, .revents = 0 }};
        const rc = WSAPoll(&fds, 1, timeout_ms);
        return .{ .pty = true, .sock = rc > 0 and (fds[0].revents & POLLRDNORM) != 0 };
    } else {
        var pfds = [_]PollFd{
            .{ .fd = s.masterFd(), .events = POLLIN, .revents = 0 },
            .{ .fd = client_fd, .events = POLLIN, .revents = 0 },
        };
        if (poll(&pfds, 2, timeout_ms) < 0) return .{ .pty = false, .sock = false };
        return .{ .pty = (pfds[0].revents & POLLIN) != 0, .sock = (pfds[1].revents & POLLIN) != 0 };
    }
}

/// Wait for `client_fd` alone to be readable, or `timeout_ms` to pass. The guest
/// terminal has no local pty to multiplex, and this is the one file that knows
/// both hosts' readiness vocabulary (`poll(2)` and `WSAPoll`).
pub fn waitSocketReadable(client_fd: i32, timeout_ms: c_int) bool {
    if (comptime pty_backend == .conpty) {
        var fds = [_]WsaPollFd{.{ .fd = socketToUsize(client_fd), .events = POLLRDNORM, .revents = 0 }};
        const rc = WSAPoll(&fds, 1, timeout_ms);
        return rc > 0 and (fds[0].revents & POLLRDNORM) != 0;
    } else {
        var pfds = [_]PollFd{.{ .fd = client_fd, .events = POLLIN, .revents = 0 }};
        if (poll(&pfds, 1, timeout_ms) < 0) return false;
        return (pfds[0].revents & POLLIN) != 0;
    }
}

/// Which Windows mechanism is BEHIND a session's handle set. Both feed the
/// same ring buffer, so only two things read this: `resizeSession` (a pipe
/// has no window size to set) and the create response, which reports it so
pub const WinBackend = enum { conpty, pipe };

/// The ConPTY handle set. Four kernel objects per session, all owned by
/// the session and all released by `reapSession`:
///
pub const WinPty = struct {
    kind: WinBackend = .conpty,
    pc: ?HANDLE = null,
    in_write: ?HANDLE = null,
    out_read: ?HANDLE = null,
    proc: ?HANDLE = null,
    thread: ?HANDLE = null,
};

// ---------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------

pub const Session = struct {
    id: []u8,
    /// POSIX PTY master fd, or `-1` on a ConPTY host.
    master_fd: c_int,
    /// POSIX child pid, or the Windows process id on a ConPTY host (the
    /// NumProcessId `CreateProcessW` reported — used for BOTH the create
    /// response's `pid` and the exit check, so the two can never disagree).
    child_pid: c_int,
    /// Windows ConPTY handles; empty on POSIX.
    win: WinPty = .{},
    cols: u16,
    rows: u16,
    /// Owning user id (plan 2026-09-25, W2.5).
    owner: []u8,
    /// The workspace this session belongs to. Empty when the create named
    /// none: a terminal is scoped to a WORKSPACE (not to a chat session),
    /// but a shell can be opened without either.
    workspace_id: []u8,
    /// The directory the shell ACTUALLY started in — the effective cwd, not
    /// the requested one (an empty cwd falls back to the server's).
    cwd: []u8,
    /// Ring-ish output log: `buf` holds the newest bytes, `base` is the
    /// absolute cursor of `buf[0]`, `total` the absolute cursor of the
    /// end. Bytes in [0, base) were dropped by the cap.
    buf: std.ArrayList(u8),
    /// Uncommitted input for the PIPE backend, which has no line discipline
    /// of its own: the server echoes what the user types and commits the whole
    /// line on Enter, so the view and the shell's line never disagree.
    line: std.ArrayList(u8) = .empty,
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
pub fn getSession(id: []const u8) ?*Session {
    const reg = registry();
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

/// Test-only registry insert that owns NO OS handles (no forkpty, no child,
/// no master fd): stamps, sweep, cap, owner checks and reap can then be
/// driven from ONE body on every host. `s.id` dies with the reap — copy it.
pub fn insertSessionForTest(owner: []const u8) SessionError!*Session {
    return insertSessionForTestIn("", owner);
}

/// Test-only insert that also records the workspace the session belongs to:
/// the list groups by it, so a test needs more than one workspace.
pub fn insertSessionForTestIn(workspace_id: []const u8, owner: []const u8) SessionError!*Session {
    const id = try allocId();
    errdefer g_alloc.free(id);
    const owner_copy = g_alloc.dupe(u8, owner) catch return error.OutOfMemory;
    errdefer g_alloc.free(owner_copy);
    const workspace_copy = g_alloc.dupe(u8, workspace_id) catch return error.OutOfMemory;
    errdefer g_alloc.free(workspace_copy);
    const cwd_copy = g_alloc.dupe(u8, "") catch return error.OutOfMemory;
    errdefer g_alloc.free(cwd_copy);
    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    errdefer g_alloc.destroy(session);
    const now = nowSeconds();
    session.* = .{
        .id = id,
        .master_fd = -1,
        .child_pid = 0,
        .cols = default_cols,
        .rows = default_rows,
        .owner = owner_copy,
        .workspace_id = workspace_copy,
        .cwd = cwd_copy,
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = now,
        .last_user_active_s = now,
        .last_output_at_s = 0,
        .last_output_total = 0,
    };
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    reg.put(id, session) catch return error.OutOfMemory;
    return session;
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
/// and the user-idle stamps. Background polls must NOT call this. Pure
/// bookkeeping — no PTY is involved, so it runs on every host.
pub fn touchUser(s: *Session) void {
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
    // Registry + stamps only: the PTY teardown is the gated part (inside
    // `reapSession`), so the sweep decision itself runs on every host.
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

/// A validated (cols, rows) pair. Named so both create paths and the
/// session record can pass it around as one value.
pub const Dims = struct { cols: u16, rows: u16 };

/// Validate create inputs without touching the OS. `cwd` must be a
/// non-empty absolute path; `cols`/`rows` fall back to defaults when
/// null and must land in [min_dim, max_dim] otherwise.
pub fn validateCreate(cwd: []const u8, cols: ?u16, rows: ?u16) SessionError!Dims {
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

/// Max-sessions cap check: registry bookkeeping, no syscalls, so the rule
/// lives in one place and holds on every host.
fn checkSessionCapacity() SessionError!void {
    const reg = registry();
    mutexLock(&g_mutex);
    const n = reg.count();
    const cap = g_max_sessions;
    g_mutex.unlock();
    if (n >= cap) return error.TooManySessions;
}

// ---------------------------------------------------------------------
// Lifecycle (PTY syscalls are comptime-gated; the registry is not)
// ---------------------------------------------------------------------

pub const SessionInfo = struct {
    id: []const u8,
    pid: i32,
    /// Which console this session ACTUALLY got, as a wire string. On Linux
    /// and macOS that is always "posix-pty". On Windows it is "conpty" for a
    /// real pseudoconsole and "pipe" for the degraded fallback, and the
    backend: []const u8,
};

/// The wire names `SessionInfo.backend` can take.
pub const backend_posix_pty: []const u8 = "posix-pty";
pub const backend_conpty: []const u8 = "conpty";
pub const backend_pipe: []const u8 = "pipe";

/// Spawn a shell on a fresh PTY. `shell` null/empty selects `$SHELL`, then
/// `/bin/bash`, then `/bin/sh`. `owner` is the server-derived user id (plan
/// 2026-09-25, W2.5); `workspace_id` is recorded for the per-workspace list.
pub fn createSession(io: std.Io, cwd: []const u8, workspace_id: []const u8, shell: ?[]const u8, cols: ?u16, rows: ?u16, owner: []const u8) SessionError!SessionInfo {
    // `if (comptime ...) { } else { }` rather than two early returns: Zig
    // elides the NOT-taken branch of a comptime-known condition, and only
    // the taken one is analyzed. That is what lets one file hold both
    if (comptime pty_backend == .conpty) {
        return createSessionWin(io, cwd, workspace_id, shell, cols, rows, owner);
    } else if (comptime pty_backend == .posix_pty) {
        return createSessionPosix(io, cwd, workspace_id, shell, cols, rows, owner);
    } else {
        return error.UnsupportedPlatform;
    }
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

/// One row of the session list: the live shell, the workspace it belongs to,
/// and where it started. The strings are owned copies.
pub const SessionSummary = struct {
    id: []u8,
    workspace_id: []u8,
    cwd: []u8,
    cols: u16,
    rows: u16,
    exited: bool,
    backend: []const u8,
};

/// Every live session the caller may drive, owner-scoped with the same rule
/// as `mayAccess`: an empty owner means no identity, and a foreign session
/// is not the caller's. The rows are owned copies: free them.
pub fn listSessionsForOwner(allocator: std.mem.Allocator, caller_owner: []const u8) ![]SessionSummary {
    var out = std.ArrayList(SessionSummary).empty;
    errdefer {
        for (out.items) |row| {
            allocator.free(row.id);
            allocator.free(row.workspace_id);
            allocator.free(row.cwd);
        }
        out.deinit(allocator);
    }
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    var it = reg.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr.*;
        if (!mayAccess(s, caller_owner)) continue;
        const id = allocator.dupe(u8, s.id) catch |err| return err;
        const workspace_id = allocator.dupe(u8, s.workspace_id) catch |err| {
            allocator.free(id);
            return err;
        };
        const cwd = allocator.dupe(u8, s.cwd) catch |err| {
            allocator.free(id);
            allocator.free(workspace_id);
            return err;
        };
        // The live fields are written under the session lock (the drain
        // grows the buffer and marks the exit), so read them the same way.
        mutexLock(&s.mutex);
        const cols = s.cols;
        const rows = s.rows;
        const exited = s.exited;
        s.mutex.unlock();
        out.append(allocator, .{
            .id = id,
            .workspace_id = workspace_id,
            .cwd = cwd,
            .cols = cols,
            .rows = rows,
            .exited = exited,
            .backend = sessionBackend(s),
        }) catch |err| {
            allocator.free(id);
            allocator.free(workspace_id);
            allocator.free(cwd);
            return err;
        };
    }
    return out.toOwnedSlice(allocator);
}

/// Free a list produced by `listSessionsForOwner` (or the guest twin).
pub fn freeSessionSummaries(allocator: std.mem.Allocator, rows: []SessionSummary) void {
    for (rows) |row| {
        allocator.free(row.id);
        allocator.free(row.workspace_id);
        allocator.free(row.cwd);
    }
    allocator.free(rows);
}

/// The console this session actually got, as a wire string — the same words
/// the create response uses, so a list row and a create answer agree.
pub fn sessionBackend(s: *Session) []const u8 {
    if (comptime pty_backend == .conpty) {
        if (s.win.kind == .conpty) return backend_conpty;
        return backend_pipe;
    }
    if (comptime pty_backend == .posix_pty) return backend_posix_pty;
    return "none";
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

/// The default shell for this host. POSIX: `$SHELL`, then `/bin/bash`.
/// Windows: `%COMSPEC%`, then the System32 path a machine that has no
/// COMSPEC still has one at. UTF-8 in, UTF-8 out — the create path
fn defaultShell() []const u8 {
    if (comptime pty_backend == .conpty) {
        // `cmd.exe` is what a Windows console gives you, and COMSPEC is
        // where Explorer/the OS points at it.
        if (getenv("COMSPEC")) |s| {
            const span = std.mem.span(s);
            if (span.len > 0 and std.fs.path.isAbsolute(span)) return span;
        }
        return "C:\\Windows\\System32\\cmd.exe";
    }
    // $SHELL via libc (no allocator, no std.posix.getenv in 0.16).
    if (getenv("SHELL")) |s| {
        const span = std.mem.span(s);
        if (span.len > 0 and std.fs.path.isAbsolute(span)) return span;
    }
    return "/bin/bash";
}

fn createSessionPosix(io: std.Io, cwd: []const u8, workspace_id: []const u8, shell_opt: ?[]const u8, cols_opt: ?u16, rows_opt: ?u16, owner: []const u8) SessionError!SessionInfo {
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
    try checkSessionCapacity();

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
    const workspace_copy = g_alloc.dupe(u8, workspace_id) catch return error.OutOfMemory;
    errdefer g_alloc.free(workspace_copy);
    const cwd_copy = g_alloc.dupe(u8, eff_cwd) catch return error.OutOfMemory;
    errdefer g_alloc.free(cwd_copy);

    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    errdefer g_alloc.destroy(session);
    session.* = .{
        .id = id,
        .master_fd = master,
        .child_pid = pid,
        .cols = dims.cols,
        .rows = dims.rows,
        .owner = owner_copy,
        .workspace_id = workspace_copy,
        .cwd = cwd_copy,
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

    return .{ .id = id, .pid = @intCast(pid), .backend = backend_posix_pty };
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

// ---------------------------------------------------------------------
// Windows ConPTY backend
//

/// Copy `src` into `dst` as NUL-terminated UTF-16LE. Returns the slice
/// WITHOUT the terminator (the terminator is what the `W` calls read).
/// A path longer than `dst` fails closed: truncating here would spawn the
fn utf8ToWide(dst: []u16, src: []const u8) SessionError![:0]u16 {
    if (dst.len == 0) return error.SpawnFailed;
    const n = std.unicode.utf8ToUtf16Le(dst[0 .. dst.len - 1], src) catch return error.SpawnFailed;
    dst[n] = 0;
    return dst[0..n :0];
}

/// The handle set a Windows spawn produced, before any Session owns it.
const WinSpawn = struct {
    handles: WinPty = .{},
    pid: DWORD = 0,
};

/// Windows create. Validates once, then spawns on the best backend this
/// host can actually deliver.
///
fn createSessionWin(io: std.Io, cwd: []const u8, workspace_id: []const u8, shell: ?[]const u8, cols: ?u16, rows: ?u16, owner: []const u8) SessionError!SessionInfo {
    // Empty cwd (fresh standalone chats have no session cwd yet): fall back
    // to the server process cwd, mirroring the POSIX path exactly.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const eff_cwd: []const u8 = if (cwd.len == 0) blk: {
        const ptr = getcwd(&cwd_buf, cwd_buf.len) orelse return error.CwdNotDir;
        break :blk std.mem.span(ptr);
    } else cwd;

    const dims = try validateCreate(eff_cwd, cols, rows);
    try validateShell(shell);

    // eff_cwd must exist and be a directory. Checked BEFORE the spawn so a
    // bad cwd is a clean 404 and never a shell that exits instantly.
    {
        var dir = std.Io.Dir.openDirAbsolute(io, eff_cwd, .{}) catch return error.CwdNotDir;
        dir.close(io);
    }

    sweepIdle();
    try checkSessionCapacity();

    const shell_path: []const u8 = blk: {
        const s = shell orelse "";
        if (s.len > 0) break :blk s;
        break :blk defaultShell();
    };

    var spawned: WinSpawn = if (createSessionConPty(eff_cwd, dims, shell_path)) |s| s else |err| switch (err) {
        error.PseudoConsoleUnusable => blk: {
            // Loud on purpose: an operator reading a log must not have to
            // guess why their terminal has no prompt. `debugPrint` keeps that
            // and drops it from a test, where every Windows CI run drives it.
            loggermod.debugPrint(
                "terminal: this host's pseudoconsole never produced a byte and its client did not survive " ++
                    "initialisation (see terminal_session.zig); creating the session with the pipe backend instead " ++
                    "— input, output and exit work, but there is no prompt echo, no ANSI and no window resize\n",
                .{},
            );
            break :blk try createSessionPipeWin(eff_cwd, dims, shell_path);
        },
        // `@as` widens what is left to the public set: a bare `return err`
        // here would put `PseudoConsoleUnusable` back into THIS function's
        // error set, increasing the type every caller has to switch on.
        else => |e| return @as(SessionError, e),
    };

    // From here a real shell exists, so EVERY exit must release it. The
    // session takes the handle set; until it exists, `spawned` owns it.
    var session: ?*Session = null;
    var id: ?[]u8 = null;
    var owner_copy: ?[]u8 = null;
    var workspace_copy: ?[]u8 = null;
    var cwd_copy: ?[]u8 = null;
    errdefer {
        if (session) |s| {
            reapSessionWin(s);
            g_alloc.free(s.owner);
            g_alloc.free(s.workspace_id);
            g_alloc.free(s.cwd);
            g_alloc.free(s.id);
            g_alloc.destroy(s);
        } else {
            closeWinHandles(spawned.handles, false);
            if (owner_copy) |o| g_alloc.free(o);
            if (workspace_copy) |w| g_alloc.free(w);
            if (cwd_copy) |c| g_alloc.free(c);
            if (id) |i| g_alloc.free(i);
        }
    }

    id = try allocId();
    owner_copy = g_alloc.dupe(u8, owner) catch return error.OutOfMemory;
    workspace_copy = g_alloc.dupe(u8, workspace_id) catch return error.OutOfMemory;
    cwd_copy = g_alloc.dupe(u8, eff_cwd) catch return error.OutOfMemory;
    const s = g_alloc.create(Session) catch return error.OutOfMemory;
    s.* = winSessionRecord(id.?, owner_copy.?, workspace_copy.?, cwd_copy.?, spawned.handles, spawned.pid, dims);
    session = s;
    // Ownership moved; a later failure must not close these twice.
    spawned.handles = .{};
    spawned.pid = 0;

    const reg = registry();
    mutexLock(&g_mutex);
    reg.put(id.?, s) catch {
        g_mutex.unlock();
        return error.OutOfMemory;
    };
    g_mutex.unlock();
    return .{ .id = id.?, .pid = @intCast(s.child_pid), .backend = if (s.win.kind == .conpty) backend_conpty else backend_pipe };
}

/// The Session record for a Windows spawn. One literal for both backends:
/// only the handle set and the reported kind differ.
fn winSessionRecord(id: []u8, owner: []u8, workspace_id: []u8, cwd: []u8, handles: WinPty, pid: DWORD, dims: Dims) Session {
    return .{
        .id = id,
        .master_fd = -1,
        .child_pid = @intCast(pid),
        .win = handles,
        .cols = dims.cols,
        .rows = dims.rows,
        .owner = owner,
        .workspace_id = workspace_id,
        .cwd = cwd,
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
}

/// A Windows spawn that failed AND may be retried on the other backend.
const WinSpawnError = SessionError || error{PseudoConsoleUnusable};

fn createSessionConPty(eff_cwd: []const u8, dims: Dims, shell_path: []const u8) WinSpawnError!WinSpawn {

    // UTF-16 conversions for the two `W` calls.
    var cwd_w: [std.fs.max_path_bytes + 1]u16 = undefined;
    var shell_w: [std.fs.max_path_bytes + 1]u16 = undefined;
    const cwd_z = try utf8ToWide(&cwd_w, eff_cwd);
    const shell_z = try utf8ToWide(&shell_w, shell_path);

    // `lpApplicationName` stays null and the command line's first token is
    // the QUOTED application path — the documented way to name an
    // executable that may contain spaces (`C:\Program Files\...`).
    var cmdline_w: [std.fs.max_path_bytes + 3]u16 = undefined;
    cmdline_w[0] = '"';
    @memcpy(cmdline_w[1..][0..shell_z.len], shell_z);
    cmdline_w[1 + shell_z.len] = '"';
    cmdline_w[2 + shell_z.len] = 0;
    // Length is the opening quote + the path + the closing quote; the NUL at
    // `2 + len` is the sentinel the slice type asserts. Off by one here is
    // a panic, not a silent over-read past the end of the command line.
    const cmdline: [:0]u16 = cmdline_w[0 .. 2 + shell_z.len :0];

    // ---- pipes -------------------------------------------------------
    // `bInheritHandle` is 1 only so the console can pick them up; every
    // flag is cleared again below. A null HANDLE is "absent", so the
    var sa = SecurityAttributes{
        .nLength = @sizeOf(SecurityAttributes),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    var in_read_h: ?HANDLE = null;
    var in_write_h: ?HANDLE = null;
    var out_read_h: ?HANDLE = null;
    var out_write_h: ?HANDLE = null;
    var pc_h: ?HANDLE = null;
    var child: ?ProcessInformation = null;
    errdefer {
        if (child) |pi| {
            _ = TerminateProcess(pi.hProcess, 1);
            _ = WaitForSingleObject(pi.hProcess, 200);
            _ = CloseHandle(pi.hProcess);
            _ = CloseHandle(pi.hThread);
        }
        if (pc_h) |h| ClosePseudoConsole(h);
        if (in_write_h) |h| _ = CloseHandle(h);
        if (out_read_h) |h| _ = CloseHandle(h);
        if (in_read_h) |h| _ = CloseHandle(h);
        if (out_write_h) |h| _ = CloseHandle(h);
    }

    {
        var r: HANDLE = undefined;
        var w: HANDLE = undefined;
        if (CreatePipe(&r, &w, &sa, 0) == 0) return error.SpawnFailed;
        in_read_h = r;
        in_write_h = w;
    }
    {
        var r: HANDLE = undefined;
        var w: HANDLE = undefined;
        if (CreatePipe(&r, &w, &sa, 0) == 0) return error.SpawnFailed;
        out_read_h = r;
        out_write_h = w;
    }
    // NOTHING crosses into the child by inheritance: the pseudoconsole
    // attribute is what wires the child's console, and an inherited copy
    // of the write end would keep the input pipe open after we close it.
    _ = SetHandleInformation(in_read_h.?, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(in_write_h.?, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(out_read_h.?, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(out_write_h.?, HANDLE_FLAG_INHERIT, 0);

    {
        var pc: HANDLE = undefined;
        // COORD is X-then-Y and X is the COLUMN count.
        const hr = CreatePseudoConsole(.{ .X = @intCast(dims.cols), .Y = @intCast(dims.rows) }, in_read_h.?, out_write_h.?, 0, &pc);
        if (hr < 0) return error.SpawnFailed;
        pc_h = pc;
    }

    // ---- attribute list + process ------------------------------------
    {
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        if (attr_size == 0) return error.SpawnFailed;
        const attr_buf = g_alloc.alignedAlloc(u8, std.mem.Alignment.of(usize), attr_size) catch return error.OutOfMemory;
        defer g_alloc.free(attr_buf);
        if (InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0) return error.SpawnFailed;
        defer DeleteProcThreadAttributeList(attr_buf.ptr);

        var si: StartupInfoExW = std.mem.zeroes(StartupInfoExW);
        // `cb` must cover the EX attribute, or CreateProcessW reads the
        // attribute pointer as uninitialised tail bytes and ignores it.
        si.StartupInfo.cb = @sizeOf(StartupInfoExW);
        si.lpAttributeList = attr_buf.ptr;
        // The attribute VALUE is the HPCON itself, so the pointer we hand
        // over must address a plain HANDLE — `&pc_h` would be a pointer to
        // an OPTIONAL, and `&pc_value` is a pointer to a pointer, since
        const pc_value: HANDLE = pc_h.?;
        if (UpdateProcThreadAttribute(attr_buf.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, @ptrCast(&pc_value), @sizeOf(HANDLE), null, null) == 0) return error.SpawnFailed;

        var pi: ProcessInformation = undefined;
        const ok = CreateProcessW(
            null,
            cmdline.ptr,
            null,
            null,
            1, // bInheritHandles — no handle is flagged inheritable; the
            // console, not inheritance, wires the child.
            EXTENDED_STARTUPINFO_PRESENT,
            null, // lpEnvironment: inherit ours
            cwd_z.ptr,
            &si.StartupInfo,
            &pi,
        );
        if (ok == 0) return error.SpawnFailed;
        child = pi;
    }

    // ---- is the pseudoconsole actually SERVICING this client? --------
    // A console that works puts the shell's prompt on OUR output pipe
    // within milliseconds. A console whose client dies during DLL
    if (!pseudoconsoleIsLive(out_read_h.?, child.?.hProcess)) return error.PseudoConsoleUnusable;

    // The console owns its pipe ends from here on; ours are closed so the
    // child's output reaches exactly one reader.
    in_read_h = null;
    out_write_h = null;

    const pi = child.?;
    const handles = WinPty{
        .kind = .conpty,
        .pc = pc_h,
        .in_write = in_write_h,
        .out_read = out_read_h,
        .proc = pi.hProcess,
        .thread = pi.hThread,
    };
    // Ownership moves to the returned WinSpawn: the errdefer above must
    // not close these on a later failure.
    pc_h = null;
    in_write_h = null;
    out_read_h = null;
    child = null;
    return .{ .handles = handles, .pid = pi.dwProcessId };
}

/// How long a fresh pseudoconsole gets to produce its first byte (and how
/// finely we look), before we decide it is not servicing its client.
const conpty_probe_ms: usize = 1500;
const conpty_probe_step_ms: usize = 25;

/// Does this pseudoconsole actually work?
///
/// A console that works puts the shell's prompt on OUR output pipe within
fn pseudoconsoleIsLive(out_read: HANDLE, proc: HANDLE) bool {
    var waited: usize = 0;
    while (waited < conpty_probe_ms) : (waited += conpty_probe_step_ms) {
        var avail: DWORD = 0;
        if (PeekNamedPipe(out_read, null, 0, null, &avail, null) == 0) return false;
        if (avail > 0) return true;
        if (WaitForSingleObject(proc, 0) == WAIT_OBJECT_0) return false;
        sleepMillis(conpty_probe_step_ms);
    }
    return false;
}

// ---------------------------------------------------------------------
// Windows pipe backend — the fallback behind `error.PseudoConsoleUnusable`
//

/// Returns the PLAIN `SessionError`: unlike the pseudoconsole path there is
/// nothing to fall back FROM, so `PseudoConsoleUnusable` is not in its set
/// and the caller's `try` cannot smuggle it out.
fn createSessionPipeWin(eff_cwd: []const u8, dims: Dims, shell_path: []const u8) SessionError!WinSpawn {
    _ = dims; // a pipe has no window size; the dims are recorded by the caller
    var cwd_w: [std.fs.max_path_bytes + 1]u16 = undefined;
    var shell_w: [std.fs.max_path_bytes + 1]u16 = undefined;
    const cwd_z = try utf8ToWide(&cwd_w, eff_cwd);
    const shell_z = try utf8ToWide(&shell_w, shell_path);

    // cmd.exe echoes every line it reads from a pipe, which would print each
    // command twice now that the server echoes the typing; `/Q` turns that off.
    // The argument is cmd.exe's alone — any other shell is named on its own.
    const calm = std.ascii.eqlIgnoreCase(std.fs.path.basename(shell_path), "cmd.exe");
    var cmdline_w: [std.fs.max_path_bytes + 8]u16 = undefined;
    cmdline_w[0] = '"';
    @memcpy(cmdline_w[1..][0..shell_z.len], shell_z);
    cmdline_w[1 + shell_z.len] = '"';
    var n: usize = 2 + shell_z.len;
    if (calm) {
        for (" /Q") |c| {
            cmdline_w[n] = c;
            n += 1;
        }
    }
    cmdline_w[n] = 0;
    const cmdline: [:0]u16 = cmdline_w[0..n :0];

    var sa = SecurityAttributes{
        .nLength = @sizeOf(SecurityAttributes),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };

    var in_read_h: ?HANDLE = null;
    var in_write_h: ?HANDLE = null;
    var out_read_h: ?HANDLE = null;
    var out_write_h: ?HANDLE = null;
    var child: ?ProcessInformation = null;
    errdefer {
        if (child) |pi| {
            _ = TerminateProcess(pi.hProcess, 1);
            _ = WaitForSingleObject(pi.hProcess, 200);
            _ = CloseHandle(pi.hProcess);
            _ = CloseHandle(pi.hThread);
        }
        if (in_write_h) |h| _ = CloseHandle(h);
        if (out_read_h) |h| _ = CloseHandle(h);
        if (in_read_h) |h| _ = CloseHandle(h);
        if (out_write_h) |h| _ = CloseHandle(h);
    }

    // stdin: the shell reads `in_read_h`, we write `in_write_h`.
    {
        var r: HANDLE = undefined;
        var w: HANDLE = undefined;
        if (CreatePipe(&r, &w, &sa, 0) == 0) return error.SpawnFailed;
        in_read_h = r;
        in_write_h = w;
    }
    // stdout + stderr share ONE pipe: the panel renders one stream, and a
    // second reader would mean a second writer to the ring buffer for no
    // gain beyond interleaving the two.
    {
        var r: HANDLE = undefined;
        var w: HANDLE = undefined;
        if (CreatePipe(&r, &w, &sa, 0) == 0) return error.SpawnFailed;
        out_read_h = r;
        out_write_h = w;
    }
    // Only the CHILD's ends may cross into it.
    _ = SetHandleInformation(in_write_h.?, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(out_read_h.?, HANDLE_FLAG_INHERIT, 0);

    var si: StartupInfoExW = std.mem.zeroes(StartupInfoExW);
    si.StartupInfo.cb = @sizeOf(StartupInfoW);
    // Here the pipes ARE the child's standard handles, and saying so is what
    // stops the OS from quietly duplicating ours instead.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_read_h.?;
    si.StartupInfo.hStdOutput = out_write_h.?;
    si.StartupInfo.hStdError = out_write_h.?;

    var pi: ProcessInformation = undefined;
    // bInheritHandles = 1: the three handles above are the only inheritable
    // ones, so exactly they cross.
    if (CreateProcessW(null, cmdline.ptr, null, null, 1, 0, null, cwd_z.ptr, &si.StartupInfo, &pi) == 0) return error.SpawnFailed;
    child = pi;

    // The child owns its ends now; ours would only keep the pipes alive
    // past its exit (so `PeekNamedPipe` would never report end-of-input).
    _ = CloseHandle(in_read_h.?);
    _ = CloseHandle(out_write_h.?);
    in_read_h = null;
    out_write_h = null;

    const handles = WinPty{
        .kind = .pipe,
        .in_write = in_write_h,
        .out_read = out_read_h,
        .proc = pi.hProcess,
        .thread = pi.hThread,
    };
    in_write_h = null;
    out_read_h = null;
    child = null;
    return .{ .handles = handles, .pid = pi.dwProcessId };
}

/// Release a Windows handle set whose owner has already cleared its copy:
/// close OUR input write end (the shell sees end-of-input and leaves), close
/// the pseudoconsole when there is one, wait briefly for the shell, kill it
fn closeWinHandles(win: WinPty, already_exited: bool) void {
    if (win.in_write) |h| _ = CloseHandle(h);
    if (win.pc) |h| ClosePseudoConsole(h);
    if (win.proc) |h| {
        if (!already_exited and WaitForSingleObject(h, 250) == WAIT_TIMEOUT) {
            _ = TerminateProcess(h, 1);
            _ = WaitForSingleObject(h, 250);
        }
        _ = CloseHandle(h);
    }
    if (win.thread) |h| _ = CloseHandle(h);
    if (win.out_read) |h| _ = CloseHandle(h);
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

/// Host dispatch for the drain. Both backends append into the SAME ring
/// buffer through `appendLocked`, which is why every layer above this
/// point (`sliceOutput` / `readOutput` / `readOutputAlloc` / the websocket
fn drainLocked(s: *Session) void {
    // if/else, not two early returns: only the taken branch of a
    // comptime-known condition is analyzed, and a statement FOLLOWING such
    // an `if` still is. That distinction is what keeps `poll(2)`/`read(2)`
    if (comptime pty_backend == .conpty) {
        drainLockedWin(s);
    } else {
        drainLockedPosix(s);
    }
}

/// Win32 drain, for BOTH Windows backends (a pseudoconsole's output pipe and
/// the pipe fallback's stdout pipe are the same kind of object to us):
/// `PeekNamedPipe` is the non-blocking readiness probe — it
fn drainLockedWin(s: *Session) void {
    // A null handle means no ConPTY to drain (a sessionless test row, or a
    // session already reaped).
    const h = s.win.out_read orelse return;
    var chunk: [8192]u8 = undefined;
    var drained: usize = 0;
    var iters: usize = 0;
    while (iters < max_drain_iters and drained < max_drain_bytes_per_call) {
        iters += 1;
        var avail: DWORD = 0;
        if (PeekNamedPipe(h, null, 0, null, &avail, null) == 0) return;
        if (avail == 0) return;
        const want: DWORD = @intCast(@min(@as(usize, avail), chunk.len));
        var got: DWORD = 0;
        if (ReadFile(h, &chunk, want, &got, null) == 0) return;
        if (got == 0) return;
        const m: usize = @intCast(got);
        appendLocked(s, chunk[0..m]);
        drained += m;
    }
}

fn drainLockedPosix(s: *Session) void {
    // No master fd => no PTY to drain (a session with no OS handles).
    if (s.master_fd < 0) return;
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
        std.mem.copyForwards(u8, s.buf.items[0 .. s.buf.items.len - drop], s.buf.items[drop..]);
        s.buf.items.len -= drop;
        s.base += drop;
    }
    shrinkCapacityLocked(s);
}

/// Give a bloated buffer's spare allocation back, keeping every byte. The target
/// is the LIVE length, never `buffer_cap`: a target past `items.len` trips the
/// assert in `shrinkAndFree`, and with asserts off it serves bytes never held.
pub fn shrinkBufferToLen(buf: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    if (buf.capacity <= buffer_cap + buffer_capacity_slack) return;
    buf.shrinkAndFree(gpa, buf.items.len);
}

fn shrinkCapacityLocked(s: *Session) void {
    shrinkBufferToLen(&s.buf, g_alloc);
}

/// Non-blocking child reaping. Sets `exited`/`exit_code` exactly once.
fn pollExitLocked(s: *Session) void {
    if (s.exited) return;
    if (comptime pty_backend == .conpty) {
        pollExitLockedWin(s);
    } else {
        pollExitLockedPosix(s);
    }
}

/// Win32 exit check, for both backends (the process handle is the process
/// handle). `WaitForSingleObject(..., 0)` is the non-blocking "has it
/// finished" probe — `waitpid(WNOHANG)`'s counterpart — and the
fn pollExitLockedWin(s: *Session) void {
    const h = s.win.proc orelse return;
    if (WaitForSingleObject(h, 0) != WAIT_OBJECT_0) return;
    var code: DWORD = 0;
    if (GetExitCodeProcess(h, &code) == 0) return;
    s.exited = true;
    // Windows exit codes are UNSIGNED. Bit-cast rather than @intCast so a
    // code above INT_MAX (STATUS_CONTROL_C_EXIT is 0xC000013A) reports as
    // a negative number instead of panicking a debug build.
    s.exit_code = @bitCast(code);
}

fn pollExitLockedPosix(s: *Session) void {
    // No OS child => nothing to reap. Also keeps `waitpid` off pid 0, which
    // means "any child of this process group".
    if (s.child_pid <= 0) return;
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

/// Write input bytes to the console (terminal input = keystrokes).
pub fn writeInput(s: *Session, data: []const u8) SessionError!usize {
    if (comptime pty_backend == .none) return error.UnsupportedPlatform;
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    s.last_user_active_s = s.last_active_s;
    defer s.mutex.unlock();
    drainLocked(s);
    pollExitLocked(s);
    if (s.exited) return error.SessionExited;
    if (comptime pty_backend == .conpty) {
        return writeInputWin(s, data);
    } else {
        return writeInputPosix(s, data);
    }
}

/// Win32 write, for both backends: straight into the console's input pipe (or
/// the shell's stdin pipe). There is no `POLLOUT` equivalent, so — unlike the
/// POSIX loop, which bounds a stuck write with a 1 s `poll` — a paste larger
fn writeInputWin(s: *Session, data: []const u8) SessionError!usize {
    const h = s.win.in_write orelse return error.WriteFailed;
    // A ConPTY console cooks its own input — echo included — so it gets the
    // client's bytes untouched. A PIPE has no line discipline at all: see
    // `writeInputPipeWin`.
    if (s.win.kind == .conpty) return writeRawAll(h, data);
    return writeInputPipeWin(s, h, data);
}

/// The line discipline a pipe does not have: a pipe-backed cmd.exe echoes a line
/// only when it COMMITS and treats DEL as an ordinary character, so the server
/// keeps the line, echoes the typing, and hands over the line + CRLF on Enter.
fn writeInputPipeWin(s: *Session, h: HANDLE, data: []const u8) SessionError!usize {
    for (data) |b| {
        if (b == '\r' or b == '\n') {
            _ = try writeRawAll(h, s.line.items);
            _ = try writeRawAll(h, "\r\n");
            s.line.clearRetainingCapacity();
            appendEchoLocked(s, "\r\n");
            continue;
        }
        if (b == 0x7f or b == 0x08) {
            const drop = eraseCodepoint(s.line.items) orelse continue;
            s.line.items.len -= drop;
            appendEchoLocked(s, "\x08 \x08");
            continue;
        }
        // Control bytes (Ctrl+C, arrows, Tab) are DROPPED: a pipe carries no
        // signals and no console history, so forwarding them would only put
        // invisible junk into the line the shell runs.
        if (b < 0x20) continue;
        try s.line.append(g_alloc, b);
        appendEchoLocked(s, &[_]u8{b});
    }
    return data.len;
}

/// Bytes the trailing UTF-8 codepoint of `line` occupies, or null when there is
/// nothing left to erase. Continuation bytes (10xxxxxx) belong to the codepoint
/// before them, so Backspace removes a whole character and not half of one.
fn eraseCodepoint(line: []const u8) ?usize {
    if (line.len == 0) return null;
    var i = line.len - 1;
    while (i > 0 and (line[i] & 0xc0) == 0x80) i -= 1;
    return line.len - i;
}

/// The server's echo of the user's typing, appended to the same ring the shell
/// writes into. The output stamps are restored around it: typing is not shell
/// output, so it must not mark the session busy for the idle sweep.
fn appendEchoLocked(s: *Session, bytes: []const u8) void {
    const out_at = s.last_output_at_s;
    const out_total = s.last_output_total;
    appendLocked(s, bytes);
    s.last_output_at_s = out_at;
    s.last_output_total = out_total;
}

fn writeRawAll(h: HANDLE, data: []const u8) SessionError!usize {
    var off: usize = 0;
    while (off < data.len) {
        // A single Win32 write is capped at DWORD bytes.
        const want: DWORD = @intCast(@min(data.len - off, std.math.maxInt(DWORD)));
        var wrote: DWORD = 0;
        if (WriteFile(h, data[off..].ptr, want, &wrote, null) == 0) return error.WriteFailed;
        if (wrote == 0) return error.WriteFailed;
        off += @intCast(wrote);
    }
    return off;
}

fn writeInputPosix(s: *Session, data: []const u8) SessionError!usize {
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
    // Every poll reaps the long-idle, but polls do NOT refresh the user stamp
    // — only explicit input/resize/attach does. Sweep + age stamp are
    // bookkeeping (every host); only the PTY drain is POSIX-only.
    sweepIdleExcluding(s);
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    defer s.mutex.unlock();
    if (comptime is_pty_os) {
        drainLocked(s);
        pollExitLocked(s);
    }
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
    // Same host-independent bookkeeping as `readOutput`: the copy is taken on
    // every host, only the PTY drain is POSIX-only.
    sweepIdleExcluding(s);
    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    s.last_active_s = nowSeconds();
    if (comptime is_pty_os) {
        drainLocked(s);
        pollExitLocked(s);
    }
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
    if (comptime pty_backend == .conpty) {
        if (s.win.kind == .conpty) {
            // ConPTY re-renders the client's screen at the new size and
            // delivers the console's own resize event to the shell — the
            // same observable effect `TIOCSWINSZ` + SIGWINCH has on POSIX.
            const pc = s.win.pc orelse return error.ResizeFailed;
            if (ResizePseudoConsole(pc, .{ .X = @intCast(cols), .Y = @intCast(rows) }) < 0) return error.ResizeFailed;
        }
        // A pipe has no console and so no window size. The new dims are
        // recorded and the call SUCCEEDS: the frontend reflows its own
        // viewport, and "resize a terminal that has nothing to resize" is
    } else {
        var win = Winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        if (ioctl(s.master_fd, TIOCSWINSZ, &win) != 0) return error.ResizeFailed;
    }
    s.cols = cols;
    s.rows = rows;
}

/// Kill the child (if running), close the master, drop the session. The
/// registry removal runs on every host; `reapSession` gates the PTY part.
pub fn destroySession(id: []const u8) SessionError!void {
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    g_mutex.unlock();
    reapSession(entry.value);
}

/// Owner-checked `destroySession` (plan 2026-09-25, W2.5). The owner check
/// is registry bookkeeping, so it holds on every host.
pub fn destroySessionForOwner(id: []const u8, caller_owner: []const u8) SessionError!void {
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
    // Only a session that owns OS handles has anything to tear down: a
    // session with no PTY (no child, no handles) is pure bookkeeping, so
    // the registry half of this runs on every host.
    if (comptime pty_backend == .conpty) {
        reapSessionWin(s);
    } else {
        reapSessionPosix(s);
    }
    s.buf.deinit(g_alloc);
    s.line.deinit(g_alloc);
    g_alloc.free(s.owner);
    g_alloc.free(s.workspace_id);
    g_alloc.free(s.cwd);
    g_alloc.free(s.id);
    g_alloc.destroy(s);
}

fn reapSessionPosix(s: *Session) void {
    if (s.child_pid <= 0) return;
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

    if (s.master_fd >= 0) _ = close(s.master_fd);
}

/// Tear down a Windows session, either backend.
///
/// The order matters and is the one the API demands:
fn reapSessionWin(s: *Session) void {
    const win = s.win;
    s.win = .{};
    mutexLock(&s.mutex);
    s.last_active_s = nowSeconds();
    const already_exited = s.exited;
    s.mutex.unlock();
    closeWinHandles(win, already_exited);
}

fn sleepMillis(ms: u64) void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const ts = Timespec{
                .tv_sec = @intCast(ms / 1000),
                .tv_nsec = @intCast((ms % 1000) * 1_000_000),
            };
            _ = nanosleep(&ts, null);
        },
        .windows => Sleep(@intCast(ms)),
        else => {},
    }
}

// ---------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "backspace erases a whole codepoint, not a byte" {
    try testing.expect(eraseCodepoint("") == null);
    try testing.expectEqual(@as(?usize, 1), eraseCodepoint("dir"));
    // A multi-byte codepoint goes back to its lead byte in one press.
    try testing.expectEqual(@as(?usize, 2), eraseCodepoint("d\u{e9}"));
    try testing.expectEqual(@as(?usize, 3), eraseCodepoint("\u{20ac}"));
    try testing.expectEqual(@as(?usize, 1), eraseCodepoint("abc\u{e9}d"));
}

test "the pipe backend echoes typing and commits the line on Enter" {
    switch (pty_backend) {
        .posix_pty => {},
        .none => {},
        .conpty => {
            const info = try createSession(testing.io, "", "ws_test", null, 80, 24, "user_test");
            defer destroySession(info.id) catch {};
            // A real console cooks AND echoes its own input; only the pipe
            // fallback needs the server's discipline, so only it asserts.
            if (!std.mem.eql(u8, info.backend, backend_pipe)) return;

            const s = getSession(info.id) orelse return error.SessionNotFound;
            sleepMillis(500);
            // Typing shows up BEFORE the line commits — the whole point.
            _ = try writeInput(s, "echo ECHOED-4c1a9f");
            try expectMarker(s, "echo ECHOED-4c1a9f", 50);
            // Backspace erases one cell in the view...
            _ = try writeInput(s, "\x7f");
            try expectMarker(s, "\x08 \x08", 50);
            // ...and that same byte is gone from the line the shell runs.
            _ = try writeInput(s, "\r");
            try expectMarker(s, "ECHOED-4c1a9\r\n", 100);
            // `/Q` keeps the pipe shell from echoing the line a second time:
            // exactly our own echo of the typed text, nothing more.
            const out = readOutput(s, 0);
            try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.data, "echo ECHOED-4c1a9"));

            _ = try writeInput(s, "exit\r");
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const o = readOutput(s, 0);
                if (o.exited) {
                    try testing.expectEqual(@as(?i32, 0), o.exit_code);
                    return;
                }
                sleepMillis(100);
            }
            return error.TestUnexpectedResult;
        },
    }
}

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

test "empty cwd falls back to the server cwd" {
    // Only the fallback lets this reach the spawn: validateCreate would
    // reject the empty string as a relative path.
    switch (pty_backend) {
        .posix_pty => {
            const info = try createSession(testing.io, "", "ws_test", "/bin/sh", 80, 24, "user_test");
            defer destroySession(info.id) catch {};
            try testing.expect(getSession(info.id) != null);
        },
        .conpty => {
            // No shell override either: the empty cwd must fall back to the
            // server's cwd AND `%COMSPEC%` must resolve, or this throws
            // instead of returning a session.
            const info = try createSession(testing.io, "", "ws_test", null, 80, 24, "user_test");
            defer destroySession(info.id) catch {};
            try testing.expect(getSession(info.id) != null);
            try testing.expect(info.pid > 0);
        },
        .none => {
            // No PTY backend: the spawn this test needs is the refusal.
            try testing.expectError(error.UnsupportedPlatform, createSession(testing.io, "", "ws_test", null, 80, 24, "user_test"));
        },
    }
}

test "idle sweep reaps untouched sessions, keeps active ones" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const a = try insertSessionForTest("user_test");
    const a_id = try testing.allocator.dupe(u8, a.id);
    defer testing.allocator.free(a_id);
    const b = try insertSessionForTest("user_test");
    const b_id = try testing.allocator.dupe(u8, b.id);
    defer testing.allocator.free(b_id);
    defer destroySession(b_id) catch {};

    // a: stale on both stamps. b: user-idle but absolutely fresh, so only
    // the explicit touch saves it — a bare output poll must NOT.
    mutexLock(&a.mutex);
    a.last_active_s -= 7200;
    a.last_user_active_s = a.last_active_s;
    a.mutex.unlock();
    mutexLock(&b.mutex);
    b.last_user_active_s -= 7200;
    b.mutex.unlock();
    touchUser(b);
    _ = readOutput(b, 0);

    sweepIdle();
    try testing.expect(getSession(a_id) == null);
    try testing.expect(getSession(b_id) != null);
}

test "isBusyByStamps exempts recent output, not exited or stale" {
    try testing.expect(isBusyByStamps(false, 1000, 1000 + busy_output_window_s - 1));
    try testing.expect(!isBusyByStamps(false, 1000, 1000 + busy_output_window_s + 1));
    try testing.expect(!isBusyByStamps(false, 0, 1000));
    try testing.expect(!isBusyByStamps(true, 1000, 1001));
}

test "poll does not refresh the user stamp" {
    const s = try insertSessionForTest("user_test");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    mutexLock(&s.mutex);
    s.last_user_active_s -= 100;
    s.last_active_s -= 100;
    const user_before = s.last_user_active_s;
    const abs_before = s.last_active_s;
    s.mutex.unlock();
    _ = readOutput(s, 0);
    mutexLock(&s.mutex);
    const user_after = s.last_user_active_s;
    const abs_after = s.last_active_s;
    s.mutex.unlock();

    // The poll ages the session forward but leaves the user stamp alone.
    try testing.expectEqual(user_before, user_after);
    try testing.expect(abs_after > abs_before);
}

test "busy session survives the user-idle kill" {
    const prev_kill = setIdleKillForTest(60);
    defer _ = setIdleKillForTest(prev_kill);
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);

    const s = try insertSessionForTest("user_test");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};
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

test "max sessions cap rejects over the limit" {
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);

    // Cap the count one above what the registry holds: the next insert is
    // what the cap must refuse.
    const base = sessionCount();
    const prev_max = setMaxSessionsForTest(@intCast(base + 1));
    defer _ = setMaxSessionsForTest(prev_max);

    const s = try insertSessionForTest("user_test");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    // At the cap: refused. On a host that can spawn, the real entry point
    // refuses for the same reason (the cap is checked before the fork).
    try testing.expectEqual(base + 1, sessionCount());
    try testing.expectError(error.TooManySessions, checkSessionCapacity());
    if (pty_backend != .none) {
        // Empty cwd resolves to the SERVER's cwd, which exists on every
        // host. The literal "/tmp" this used to pass would be a CwdNotDir
        // 404 on Windows, and the assertion below would then pass for
        try testing.expectError(error.TooManySessions, createSession(testing.io, "", "ws_test", null, 80, 24, "user_test"));
    }

    // One slot below the cap is accepted again.
    try destroySession(id);
    try checkSessionCapacity();
}

/// Poll `readOutput` for `marker` until it appears or `ticks` run out.
/// ONE body for every backend: what the console hands back is a byte
/// stream, and ConPTY wraps it in cursor/colour escapes exactly like a
fn expectMarker(s: *Session, marker: []const u8, ticks: usize) !void {
    var found = false;
    var cursor: u64 = 0;
    var i: usize = 0;
    while (i < ticks) : (i += 1) {
        const out = readOutput(s, cursor);
        cursor = out.cursor;
        if (std.mem.indexOf(u8, out.data, marker) != null) {
            found = true;
            break;
        }
        if (out.exited) break;
        sleepMillis(100);
    }
    if (!found) {
        std.debug.print("marker {s} never appeared\n", .{marker});
        return error.TestUnexpectedResult;
    }
}

test "spawned shell echoes input" {
    switch (pty_backend) {
        .posix_pty => {
            const info = try createSession(testing.io, "/tmp", "ws_test", "/bin/sh", 80, 24, "user_test");
            defer destroySession(info.id) catch {};

            const s = getSession(info.id) orelse return error.SessionNotFound;
            // Give the shell a moment to start, then send a marker.
            sleepMillis(500);
            _ = try writeInput(s, "echo MARKER-7f3a9c\n");
            try expectMarker(s, "MARKER-7f3a9c", 100);
        },
        .conpty => {
            // The Windows parity assertion, end to end on ONE live shell:
            // a Windows session answers the same operations the POSIX one
            // does — create, input, echo, resize, and an observed process
            const info = try createSession(testing.io, "", "ws_test", null, 80, 24, "user_test");
            defer destroySession(info.id) catch {};
            try testing.expect(info.pid > 0);
            const be = info.backend;
            try testing.expect(std.mem.eql(u8, be, backend_conpty) or std.mem.eql(u8, be, backend_pipe));

            const s = getSession(info.id) orelse return error.SessionNotFound;
            sleepMillis(500);
            // Enter as the CLIENT sends it, not as a test finds convenient:
            // xterm's onData emits one bare `\r`, and a pipe-backed cmd.exe
            // honours only CRLF — which is why `writeInputWin` rewrites it.
            _ = try writeInput(s, "echo MARKER-7f3a9c");
            _ = try writeInput(s, if (std.mem.eql(u8, be, backend_pipe)) "\r" else "\r\n");
            try expectMarker(s, "MARKER-7f3a9c", 100);

            // resize is `ResizePseudoConsole` on ConPTY and a recorded
            // no-op on a pipe; both must SUCCEED, because a caller cannot
            // act on "this terminal cannot be resized".
            try resizeSession(s, 100, 40);

            // `exit` ends the shell. The session must report exited + code
            // 0 rather than hang — which is exactly what the DELETE
            // handler and the websocket pump's exit frame read.
            _ = try writeInput(s, "exit\r\n");
            var exit_code: ?i32 = null;
            var cursor: u64 = 0;
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const out = readOutput(s, cursor);
                cursor = out.cursor;
                if (out.exited) {
                    exit_code = out.exit_code;
                    break;
                }
                sleepMillis(100);
            }
            try testing.expectEqual(@as(?i32, 0), exit_code);
        },
        .none => {
            // No PTY backend: every PTY step this test needs is a refusal,
            // while the registry teardown stays host-independent.
            try testing.expectError(error.UnsupportedPlatform, createSession(testing.io, "", "ws_test", null, 80, 24, "user_test"));
            const s = try insertSessionForTest("user_test");
            const id = try testing.allocator.dupe(u8, s.id);
            defer testing.allocator.free(id);
            try testing.expectError(error.UnsupportedPlatform, writeInput(s, "echo MARKER-7f3a9c\n"));
            try testing.expectError(error.UnsupportedPlatform, resizeSession(s, 80, 40));
            try destroySession(id);
            try testing.expect(getSession(id) == null);
        },
    }
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

test "shrinkBufferToLen gives the spare allocation back without touching the bytes" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    const chunk = try testing.allocator.alloc(u8, 32 * 1024);
    defer testing.allocator.free(chunk);
    @memset(chunk, 'q');

    // Append until capacity overshoots the slack while the buffer is still
    // shorter than the cap: the state a shrink target of `buffer_cap` aborts on.
    var appends: usize = 0;
    while (buf.capacity <= buffer_cap + buffer_capacity_slack or buf.items.len >= buffer_cap) {
        if (appends == 64) return error.TestUnexpectedResult;
        appends += 1;
        try buf.appendSlice(testing.allocator, chunk);
    }
    const before = try testing.allocator.dupe(u8, buf.items);
    defer testing.allocator.free(before);
    const filled = buf.items.len;
    try testing.expect(buf.capacity > filled);

    shrinkBufferToLen(&buf, testing.allocator);

    try testing.expectEqual(filled, buf.items.len);
    try testing.expectEqual(filled, buf.capacity);
    try testing.expectEqualSlices(u8, before, buf.items);
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

test "readOutput never reaps its own session mid-call" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(1);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTest("user_test");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};
    const victim = try insertSessionForTest("user_test");
    const victim_id = try testing.allocator.dupe(u8, victim.id);
    defer testing.allocator.free(victim_id);

    // The caller: user-idle past the 1s kill window, but absolutely fresh.
    // The old readOutput swept first and freed self before locking (UAF).
    mutexLock(&s.mutex);
    s.last_user_active_s = nowSeconds() - 3600;
    s.last_active_s = nowSeconds();
    s.mutex.unlock();
    // A genuinely stale neighbour, so "self survived" cannot mean the sweep
    // never ran.
    mutexLock(&victim.mutex);
    victim.last_user_active_s = nowSeconds() - 3600;
    victim.last_active_s = nowSeconds() - 7200;
    victim.last_output_at_s = 0;
    victim.mutex.unlock();

    _ = readOutput(s, 0);
    try testing.expect(getSession(id) != null);
    try testing.expect(getSession(victim_id) == null);
}

test "readOutputAlloc returns an owned copy independent of the ring" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTest("user_test");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    mutexLock(&s.mutex);
    appendLocked(s, "OWNED-COPY-4d2e");
    s.mutex.unlock();

    const out = try readOutputAlloc(testing.allocator, s, 0);
    defer testing.allocator.free(out.data);
    try testing.expectEqualStrings("OWNED-COPY-4d2e", out.data);
    try testing.expectEqual(@as(u64, "OWNED-COPY-4d2e".len), out.cursor);

    // The ring moved on after the call: the copy must not follow it.
    mutexLock(&s.mutex);
    appendLocked(s, "-TAIL");
    s.mutex.unlock();
    try testing.expectEqualStrings("OWNED-COPY-4d2e", out.data);
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

test "concurrent sweep and destroy never double-free a victim" {
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
            const s = try insertSessionForTest("user_test");
            // Test-owned id copies: the session's own id buffer is freed by
            // whoever reaps it, so the destroy side must hash its own stable
            // slice (mirrors DELETE, whose id comes from the request, not the
            const owned = try testing.allocator.dupe(u8, s.id);
            errdefer testing.allocator.free(owned);
            try owned_ids.append(testing.allocator, owned);
            victims[i] = s;
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
        .workspace_id = @constCast(""),
        .cwd = @constCast(""),
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
        .workspace_id = @constCast(""),
        .cwd = @constCast(""),
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
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTest("user_a");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    // The owner can reach it; another user gets null (=> 404 at the handler).
    try testing.expect(getSessionForOwner(id, "user_a") != null);
    try testing.expect(getSessionForOwner(id, "user_b") == null);
    // An unknown id is also null — the two cases are indistinguishable.
    try testing.expect(getSessionForOwner("term-does-not-exist", "user_a") == null);
}

test "destroySessionForOwner: a foreign caller cannot kill the session" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTest("user_a");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    // B's attempt reports "not found" and the session survives.
    try testing.expectError(error.SessionNotFound, destroySessionForOwner(id, "user_b"));
    try testing.expect(getSession(id) != null);

    // A can still destroy its own session.
    try destroySessionForOwner(id, "user_a");
    try testing.expect(getSession(id) == null);
}

// ---------------------------------------------------------------------
// The session list: what a window-level footer shows, grouped per
// workspace.

test "the list holds the caller's own shells and nobody else's" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const mine = try insertSessionForTestIn("ws_1", "user_a");
    const mine_id = try testing.allocator.dupe(u8, mine.id);
    defer testing.allocator.free(mine_id);
    defer destroySession(mine_id) catch {};

    const theirs = try insertSessionForTestIn("ws_1", "user_b");
    const theirs_id = try testing.allocator.dupe(u8, theirs.id);
    defer testing.allocator.free(theirs_id);
    defer destroySession(theirs_id) catch {};

    const rows = try listSessionsForOwner(testing.allocator, "user_a");
    defer freeSessionSummaries(testing.allocator, rows);

    var saw_mine = false;
    for (rows) |row| {
        try testing.expect(!std.mem.eql(u8, row.id, theirs_id));
        if (std.mem.eql(u8, row.id, mine_id)) saw_mine = true;
    }
    try testing.expect(saw_mine);
}

test "a list row names the workspace the shell belongs to" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTestIn("ws_42", "user_a");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    const rows = try listSessionsForOwner(testing.allocator, "user_a");
    defer freeSessionSummaries(testing.allocator, rows);

    var found = false;
    for (rows) |row| {
        if (!std.mem.eql(u8, row.id, id)) continue;
        found = true;
        try testing.expectEqualStrings("ws_42", row.workspace_id);
        try testing.expectEqual(@as(u16, default_cols), row.cols);
        try testing.expectEqual(@as(u16, default_rows), row.rows);
        try testing.expect(!row.exited);
        try testing.expect(row.backend.len > 0);
    }
    try testing.expect(found);
}

test "a caller with no identity lists every shell (auth off)" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const owned = try insertSessionForTestIn("ws_1", "user_a");
    const owned_id = try testing.allocator.dupe(u8, owned.id);
    defer testing.allocator.free(owned_id);
    defer destroySession(owned_id) catch {};

    const rows = try listSessionsForOwner(testing.allocator, "");
    defer freeSessionSummaries(testing.allocator, rows);

    var saw = false;
    for (rows) |row| {
        if (std.mem.eql(u8, row.id, owned_id)) saw = true;
    }
    try testing.expect(saw);
}

test "the list of a workspace with no shell is empty" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(3600);
    defer _ = setIdleKillForTest(prev_kill);

    const s = try insertSessionForTestIn("ws_1", "user_a");
    const id = try testing.allocator.dupe(u8, s.id);
    defer testing.allocator.free(id);
    defer destroySession(id) catch {};

    const rows = try listSessionsForOwner(testing.allocator, "user_a");
    defer freeSessionSummaries(testing.allocator, rows);
    for (rows) |row| {
        try testing.expect(!std.mem.eql(u8, row.workspace_id, "ws_other"));
    }
}
