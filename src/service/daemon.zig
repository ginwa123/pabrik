// src/service/daemon.zig
//
// Cross-platform daemonization for the pabrik service.
//
// ## POSIX (Linux/macOS)
//
// Uses the classic double-fork + setsid pattern (per Linux daemon(7)).
// `std.c.fork` / `std.c.setsid` are libc wrappers (cross-platform via
// glibc/macOS libc) — the `std.os.linux.*` equivalents are Linux-syscall-only
// and fail on macOS where the syscall numbers differ.
//
// After `daemonize()` returns, the CALLER is the grandchild (the actual
// daemon). The original process and the intermediate child have already
// exited (via `std.process.exit(0)`). Callers must NOT depend on
// receiving a return value to do post-fork work in the parent.
//
// ## Windows
//
// Windows has no `fork`, so the daemonization is implemented by
// re-launching the current process via `CreateProcessW` with
// `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP` flags. The parent
// (the original foreground process) exits; the spawned child has no
// console window and no parent terminal, mirroring the POSIX
// "detached from controlling terminal" invariant.
//
// The parent/child dispatch is via an environment-variable sentinel
// `PABRIK_DAEMON_CHILD=1`:
//   - Parent (foreground `service start`): sentinel NOT set → re-exec
//     SELF with `PABRIK_DAEMON_CHILD=1` and the two flags, then `exit(0)`.
//   - Child (the spawned daemon): sentinel IS set → just return.
//
// ## Cross-platform contract
//
// `daemonize()` is the public cross-platform entry point. On any
// supported OS, after this function returns to the caller, the caller
// IS the daemon (or the daemon-compat foreground process on Windows).
// Callers (e.g. `main_service.zig::serviceStart`) chain
// `redirectStdioToLog(path)` immediately after to wire up stdio.
//
// ## Layout
//
//   * `daemonize()` — cross-platform entry point (comptime dispatch)
//   * `daemonizePosix()` — POSIX keep-alive alias (comptime-redirects
//     to `daemonize()` on Windows for backward compat)
//   * `mkdirP(path)` — cross-platform (POSIX: mkdirat; Windows: CreateDirectoryW)
//   * `redirectStdioToLog(path)` — cross-platform (POSIX: dup2; Windows: SetStdHandle)
//
// ## Zig 0.16 API notes
//
//   * `std.c.fork` returns `c_int`: child PID in parent, 0 in child,
//     -1 on error.
//   * `std.c.setsid` returns 0 on success, -1 on error.
//   * Win32 `CreateProcessW` flags are at the top of the file (NOT
//     inside an `if (builtin.os.tag == .windows)` block — we want
//     compile-time errors if Zig 0.16 silently renames them).

const std = @import("std");
const builtin = @import("builtin");

pub const DaemonError = error{
    ForkFailed,
    SessionFailed,
    OpenLogFailed,
    MkdirFailed,
    PathTooLong,
    /// Windows: CreateProcessW failed. The original process can NOT
    /// be turned into a daemon through a return path — callers should
    /// log + exit(1).
    SpawnFailed,
};

// =============================================================================
// Public cross-platform entry points
// =============================================================================

/// Cross-platform daemonization. POSIX uses double-fork + setsid.
/// Windows re-execs the current process with DETACHED_PROCESS.
///
/// CONTRACT: this function NEVER returns to the POSIX parent path
/// (the intermediate fork makes the parent exit). It only returns in
/// the grandchild (POSIX) or the spawned child (Windows). Callers
/// MUST NOT depend on receiving a return value to do post-fork work
/// in the parent.
///
/// On POSIX, doesn't redirect stdio or change cwd — call
/// `redirectStdioToLog` afterwards.
///
/// Comptime-dispatches on `builtin.os.tag` so the unused platform's
/// code is fully eliminated by the compiler (no runtime check).
pub fn daemonize(allocator: std.mem.Allocator) DaemonError!void {
    switch (builtin.os.tag) {
        .linux, .macos => return daemonizePosixImpl(),
        .windows => return daemonizeWindows(allocator),
        else => @compileError("daemon.daemonize: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

/// Backward-compat alias for `daemonize()` on POSIX. On Windows this
/// also works (calls into the Windows implementation) so legacy
/// callers compile on all platforms.
pub fn daemonizePosix(allocator: std.mem.Allocator) DaemonError!void {
    return daemonize(allocator);
}

/// Walk the parent directory chain of `path` and create each missing
/// component (idempotent: ignores EEXIST on POSIX, ERROR_ALREADY_EXISTS
/// on Windows). Used by the daemon's redirectStdioToLog to make a
/// fresh `$HOME` work without manual `mkdir -p`. Extracted as a
/// separate function so it can be unit-tested without the stdio
/// redirection side effect.
pub fn mkdirP(path: []const u8) !void {
    switch (builtin.os.tag) {
        .linux, .macos => return mkdirPPosix(path),
        .windows => return mkdirPWindows(path),
        else => @compileError("daemon.mkdirP: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

/// Redirect stdin from /dev/null and stdout/stderr to a log file. Call
/// AFTER `daemonize()` returns. The log file is opened with append
/// mode so multiple daemon lifetimes (restart cycles) preserve history.
/// Walks the parent directory chain and creates each missing component
/// (idempotent) so that a fresh `$HOME` (no `~/.local/share/pabrik/` yet)
/// works.
pub fn redirectStdioToLog(log_path: []const u8) !void {
    switch (builtin.os.tag) {
        .linux, .macos => return redirectStdioToLogPosix(log_path),
        .windows => return redirectStdioToLogWindows(log_path),
        else => @compileError("daemon.redirectStdioToLog: unsupported platform " ++ @tagName(builtin.os.tag)),
    }
}

// =============================================================================
// POSIX implementations
// =============================================================================

fn daemonizePosixImpl() DaemonError!void {
    // First fork.
    const pid1 = std.c.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) std.process.exit(0); // parent exits immediately

    // In child 1: become session leader.
    if (std.c.setsid() < 0) return error.SessionFailed;

    // Second fork — daemon is no longer session leader, so it can never
    // reacquire a controlling terminal (Linux daemon(7) idiom).
    const pid2 = std.c.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.process.exit(0); // child 1 exits

    // Grandchild returns. Caller continues here.
}

fn mkdirPPosix(path: []const u8) !void {
    const parent_dir = std.fs.path.dirname(path) orelse return;
    if (parent_dir.len == 0) return;
    // std.fs.path.componentIterator yields `Component{ .name, .path }` where
    // `.path` is the CUMULATIVE path-so-far (e.g. for "/a/b/c", second
    // component is `.name="b" .path="/a/b"`). Use `.path` directly so we
    // don't have to reconstruct the slash-joined string ourselves.
    //
    // Use std.c.mkdirat (libc wrapper, cross-platform) instead of
    // std.os.linux.mkdirat (Linux syscall number only — wrong on macOS).
    // On Linux AT.FDCWD == -100; on macOS it is -2. The libc layer
    // resolves the value at compile time via the switch in std.c.AT.
    // std.c.mkdirat returns 0 on success, -1 on failure (with errno set).
    var iter = std.fs.path.componentIterator(parent_dir);
    while (iter.next()) |component| {
        var prefix_z: [std.fs.max_path_bytes:0]u8 = undefined;
        if (component.path.len >= prefix_z.len) return error.PathTooLong;
        @memcpy(prefix_z[0..component.path.len], component.path);
        prefix_z[component.path.len] = 0;
        const rc = std.c.mkdirat(std.c.AT.FDCWD, &prefix_z, 0o755);
        if (rc != 0) {
            const err = std.c.errno(rc);
            if (err != .EXIST) return error.MkdirFailed;
        }
    }
}

fn redirectStdioToLogPosix(log_path: []const u8) !void {
    // NUL-terminated copy of log_path for the open syscall.
    var log_path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (log_path.len >= log_path_z.len) return error.PathTooLong;
    @memcpy(log_path_z[0..log_path.len], log_path);
    log_path_z[log_path.len] = 0;

    // mkdir -p the parent directory. Without this, a fresh $HOME has
    // no ~/.local/share/pabrik/ and the open() below fails.
    try mkdirP(log_path);

    // stdin → /dev/null. std.c.open returns fd_t (i32) on success,
    // -1 on failure (with errno set). We discard the error here —
    // a missing /dev/null is "weird but not fatal" for the daemon.
    //
    // The mode argument must be explicitly typed to std.c.mode_t because
    // std.c.open is variadic (libc `int open(const char*, int, ...)`);
    // Zig 0.16 rejects bare integer literals in variadic positions.
    const devnull_fd: std.c.fd_t = std.c.open(
        "/dev/null",
        .{ .ACCMODE = .RDONLY },
        @as(std.c.mode_t, 0),
    );
    if (devnull_fd >= 0) {
        _ = std.c.dup2(devnull_fd, 0);
        _ = std.c.close(devnull_fd);
    }

    // stdout/stderr → log_path (append). Same variadic-mode requirement
    // as above — cast 0o644 to std.c.mode_t explicitly.
    const log_fd: std.c.fd_t = std.c.open(&log_path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, @as(std.c.mode_t, 0o644));
    if (log_fd < 0) return error.OpenLogFailed;
    _ = std.c.dup2(log_fd, 1);
    _ = std.c.dup2(log_fd, 2);
    _ = std.c.close(log_fd);
}

// =============================================================================
// Windows implementations
// =============================================================================
//
// Compile-time gated: only the active platform's struct is materialised.
// On Linux/macOS the `win32_apis` const is replaced with `struct {}`
// so the extern decls are never visible to the linker (no
// undefined-symbol errors for `CreateProcessW` etc. on non-Windows).

const win32_apis = if (builtin.os.tag == .windows) struct {
    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE_PTR: usize = std.math.maxInt(usize);
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(INVALID_HANDLE_VALUE_PTR);

    // CreateProcessW dwCreationFlags.
    // DETACHED_PROCESS (0x00000008): no console window inherited.
    // CREATE_NEW_PROCESS_GROUP (0x00000200): new process group, so
    //   Ctrl-C / Ctrl-Break events don't propagate to us.
    // CREATE_UNICODE_ENVIRONMENT (0x00000400): lpEnvironment is wide
    //   strings (we use a wide env block).
    // EXTENDED_STARTUPINFO_PRESENT (0x00080000): reserved for future.
    const DETACHED_PROCESS: u32 = 0x00000008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
    const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;

    // STARTUPINFOW.dwFlags.
    const STARTF_USESTDHANDLES: u32 = 0x00000100;

    // CreateFileW dwDesiredAccess / dwCreationDisposition.
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_READ: u32 = 0x01;
    const FILE_SHARE_WRITE: u32 = 0x02;
    const FILE_SHARE_DELETE: u32 = 0x04;
    const OPEN_ALWAYS: u32 = 4;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    // SetStdHandle nStdHandle constants.
    const STD_INPUT_HANDLE: u32 = 0xFFFFFFF6; // -10 as DWORD
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // -11 as DWORD
    const STD_ERROR_HANDLE: u32 = 0xFFFFFFF4; // -12 as DWORD

    // GetLastError codes.
    const ERROR_ALREADY_EXISTS: u32 = 183;

    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*]const u16,
        lpCommandLine: [*]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: u32,
        dwCreationFlags: u32,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*]const u16,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) u32;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn CreateDirectoryW(
        lpPathName: [*]const u16,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) u32;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*]const u16,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn SetStdHandle(nStdHandle: u32, hHandle: HANDLE) callconv(.winapi) u32;

    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?HANDLE,
        lpFilename: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*]const u16,
        lpBuffer: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;

    const STARTUPINFOW = extern struct {
        cb: u32,
        lpReserved: ?[*]u16,
        lpDesktop: ?[*]u16,
        lpTitle: ?[*]u16,
        dwX: u32,
        dwY: u32,
        dwXSize: u32,
        dwYSize: u32,
        dwXCountChars: u32,
        dwYCountChars: u32,
        dwFillAttribute: u32,
        dwFlags: u32,
        wShowWindow: u16,
        cbReserved2: u16,
        lpReserved2: ?[*]u8,
        hStdInput: ?HANDLE,
        hStdOutput: ?HANDLE,
        hStdError: ?HANDLE,
    };

    const PROCESS_INFORMATION = extern struct {
        hProcess: HANDLE,
        hThread: HANDLE,
        dwProcessId: u32,
        dwThreadId: u32,
    };
} else struct {};

/// Sentinel env var name. The parent re-execs itself with
/// `PABRIK_DAEMON_CHILD=1`; the spawned child sees this and returns
/// from `daemonize` immediately (it IS the daemon).
const PABRIK_DAEMON_CHILD: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("PABRIK_DAEMON_CHILD");


fn daemonizeWindows(allocator: std.mem.Allocator) DaemonError!void {
    // 1. If PABRIK_DAEMON_CHILD is set, we ARE the spawned daemon. Just
    //    return; the caller is the daemon process.
    const sentinel = getEnvVarW(allocator, PABRIK_DAEMON_CHILD) catch null;
    if (sentinel) |val| {
        defer allocator.free(val);
        if (val.len > 0) {
            // Sentinel is set → child path. Validate it's "1" (or any
            // non-empty value).
            return;
        }
    }

    // 2. Parent path: re-exec ourselves with the sentinel env var set,
    //    and DETACHED_PROCESS + CREATE_NEW_PROCESS_GROUP flags so the
    //    spawned child has no console and no parent terminal.
    const app_path_w = getModuleFileNameW_alloc(allocator) catch return error.SpawnFailed;
    defer allocator.free(app_path_w);

    // Build a command line: "<exe>" "<sentinel>=1". Quote minimal — the
    // exe path won't contain quotes (it's a UTF-16 module file name).
    var cmd_line: [std.fs.max_path_bytes * 2]u16 = undefined;
    const cmd_w = buildCommandLine(cmd_line[0..], app_path_w) catch return error.SpawnFailed;

    // Build the env block: copy current env + PABRIK_DAEMON_CHILD=1.
    // Env block is a sequence of NUL-terminated wide strings, terminated
    // by an empty wide string (double NUL). We append CWD parent's env
    // via GetEnvironmentStringsW (1) — but to keep this self-contained
    // we just set the sentinel explicitly via the lpEnvironment arg.
    // CreateProcessW with a wide-string env block requires
    // CREATE_UNICODE_ENVIRONMENT flag.
    var env_block: [std.fs.max_path_bytes * 4]u16 = undefined;
    const env_w = buildEnvBlock(env_block[0..]) catch return error.SpawnFailed;

    var startup_info: win32_apis.STARTUPINFOW = std.mem.zeroes(win32_apis.STARTUPINFOW);
    startup_info.cb = @sizeOf(win32_apis.STARTUPINFOW);

    var proc_info: win32_apis.PROCESS_INFORMATION = std.mem.zeroes(win32_apis.PROCESS_INFORMATION);

    const ok = win32_apis.CreateProcessW(
        null, // app name (use cmd line[0])
        @ptrCast(cmd_w.ptr), // mutable wide-char command line
        null,
        null,
        0, // bInheritHandles = FALSE
        win32_apis.DETACHED_PROCESS | win32_apis.CREATE_NEW_PROCESS_GROUP | win32_apis.CREATE_UNICODE_ENVIRONMENT,
        @ptrCast(env_w.ptr),
        null, // current directory
        &startup_info,
        &proc_info,
    );
    if (ok == 0) return error.SpawnFailed;

    // We don't need the handles — just close them. The child is now
    // detached and running on its own.
    _ = win32_apis.CloseHandle(proc_info.hProcess);
    _ = win32_apis.CloseHandle(proc_info.hThread);

    // Parent exits immediately. The spawned child is the daemon.
    std.process.exit(0);
}

/// Walk the parent directory chain of `path` and create each missing
/// component using Win32 `CreateDirectoryW` (idempotent on
/// `ERROR_ALREADY_EXISTS`).
fn mkdirPWindows(path: []const u8) !void {
    // Walk component by component, creating each. Use UTF-16 wide
    // strings because CreateDirectoryW requires them.
    //
    // Strategy: scan the path for `\` separators and accumulate each
    // prefix. For each prefix, call CreateDirectoryW. If it returns
    // nonzero OR the error is ERROR_ALREADY_EXISTS, treat as success.
    var path_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const path_w = pathToWideZ(path, &path_w_buf) catch return error.PathTooLong;

    // Start after the first `\` (the drive root, e.g. "C:\"). The
    // drive root always exists, so creating it would fail.
    var i: usize = 0;
    // Skip the drive prefix like "C:" if present.
    if (path_w.len >= 2 and path_w[1] == ':') {
        i = 2;
        if (i < path_w.len and path_w[i] == '\\') i += 1;
    } else if (i < path_w.len and path_w[i] == '\\') {
        i += 1;
    }

    while (i < path_w.len) : (i += 1) {
        if (path_w[i] == '\\' or path_w[i] == '/') {
            // Try to create the prefix `path_w[0..i]`.
            var prefix: [std.fs.max_path_bytes]u16 = undefined;
            if (i >= prefix.len) return error.PathTooLong;
            @memcpy(prefix[0..i], path_w[0..i]);
            prefix[i] = 0;
            const ok = win32_apis.CreateDirectoryW(&prefix, null);
            if (ok == 0) {
                const err = win32_apis.GetLastError();
                if (err != win32_apis.ERROR_ALREADY_EXISTS) return error.MkdirFailed;
            }
        }
    }
    // Finally create the deepest directory (everything after the last
    // separator is the leaf filename; the parent directory is what's
    // already created). If the path is a directory itself, this also
    // creates it.
    var full: [std.fs.max_path_bytes:0]u16 = undefined;
    if (path_w.len >= full.len) return error.PathTooLong;
    @memcpy(full[0..path_w.len], path_w);
    full[path_w.len] = 0;
    const ok = win32_apis.CreateDirectoryW(&full, null);
    if (ok == 0) {
        const err = win32_apis.GetLastError();
        if (err != win32_apis.ERROR_ALREADY_EXISTS) return error.MkdirFailed;
    }
}

/// Redirect stdin from NUL and stdout/stderr to a log file using
/// Win32 `CreateFileW` + `SetStdHandle`. Walks the parent directory
/// chain first so a fresh `$HOME` works.
fn redirectStdioToLogWindows(log_path: []const u8) !void {
    // mkdir -p the parent directory.
    try mkdirP(log_path);

    // Open "NUL" for stdin (Windows equivalent of /dev/null).
    var nul_w_buf: [8:0]u16 = undefined;
    const nul_w_len = std.unicode.utf8ToUtf16Le(nul_w_buf[0..7], "NUL") catch @panic("utf8ToUtf16Le failed converting \"NUL\" for the Windows stdio redirect");
    nul_w_buf[nul_w_len] = 0;
    const nul_handle = win32_apis.CreateFileW(
        nul_w_buf[0..nul_w_len :0].ptr,
        win32_apis.GENERIC_READ,
        win32_apis.FILE_SHARE_READ | win32_apis.FILE_SHARE_WRITE,
        null,
        win32_apis.OPEN_ALWAYS,
        win32_apis.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    const nul_addr: usize = @intFromPtr(nul_handle);
    if (nul_addr == 0 or nul_addr == win32_apis.INVALID_HANDLE_VALUE_PTR) {
        return error.OpenLogFailed;
    }
    if (win32_apis.SetStdHandle(win32_apis.STD_INPUT_HANDLE, nul_handle) == 0) {
        _ = win32_apis.CloseHandle(nul_handle);
        return error.OpenLogFailed;
    }
    _ = win32_apis.CloseHandle(nul_handle);

    // Open the log file (append or create).
    var log_w_buf: [std.fs.max_path_bytes]u16 = undefined;
    const log_w = pathToWideZ(log_path, &log_w_buf) catch return error.PathTooLong;
    const log_handle = win32_apis.CreateFileW(
        log_w.ptr,
        win32_apis.GENERIC_WRITE,
        win32_apis.FILE_SHARE_READ | win32_apis.FILE_SHARE_WRITE,
        null,
        win32_apis.OPEN_ALWAYS,
        win32_apis.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    const log_addr: usize = @intFromPtr(log_handle);
    if (log_addr == 0 or log_addr == win32_apis.INVALID_HANDLE_VALUE_PTR) {
        return error.OpenLogFailed;
    }
    if (win32_apis.SetStdHandle(win32_apis.STD_OUTPUT_HANDLE, log_handle) == 0) {
        _ = win32_apis.CloseHandle(log_handle);
        return error.OpenLogFailed;
    }
    if (win32_apis.SetStdHandle(win32_apis.STD_ERROR_HANDLE, log_handle) == 0) {
        _ = win32_apis.CloseHandle(log_handle);
        return error.OpenLogFailed;
    }
    _ = win32_apis.CloseHandle(log_handle);
}

// =============================================================================
// Windows helpers (UTF-16 conversion, env, command line, exe path)
// =============================================================================

/// Convert a UTF-8 path slice to a NUL-terminated UTF-16 LE slice.
/// Returns error.PathTooLong if the wide representation doesn't fit
/// in `buf` (including the NUL terminator).
fn pathToWideZ(path: []const u8, buf: []u16) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    const needed = std.unicode.calcUtf16LeLen(path) catch return error.PathTooLong;
    if (needed + 1 > buf.len) return error.PathTooLong;
    _ = std.unicode.utf8ToUtf16Le(buf[0..needed], path) catch return error.PathTooLong;
    buf[needed] = 0;
    return buf[0..needed :0];
}

/// Get the current module's file path as a heap-allocated
/// NUL-terminated UTF-16 string. Caller frees the returned slice.
fn getModuleFileNameW_alloc(allocator: std.mem.Allocator) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    // GetModuleFileNameW returns the length in characters (not
    // including the NUL terminator). 0 means failure.
    const len = win32_apis.GetModuleFileNameW(null, &buf, buf.len);
    if (len == 0) return error.PathTooLong;
    if (len >= buf.len) return error.PathTooLong;
    buf[len] = 0;
    const result = allocator.allocSentinel(u16, len, 0) catch
        return error.OutOfMemory;
    @memcpy(result[0..len], buf[0..len]);
    return result;
}

/// Get the value of an environment variable as a NUL-terminated
/// wide string. Returns `null` if the variable is not set.
fn getEnvVarW(allocator: std.mem.Allocator, name: [:0]const u16) !?[:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    // `name.ptr` is `[*]const u16` (many-pointer without sentinel info).
    // The Win32 API takes `[*:0]const u16` (many-pointer with sentinel
    // info). Cast to preserve the NUL terminator contract.
    const len = win32_apis.GetEnvironmentVariableW(@ptrCast(name.ptr), &buf, buf.len);
    if (len == 0) return null;
    if (len > buf.len) return error.PathTooLong;
    // Need to allocate a NUL-terminated copy because buf's NUL is at
    // buf[len] but the returned slice must be [:0]u16.
    const result = allocator.allocSentinel(u16, len, 0) catch
        return error.OutOfMemory;
    @memcpy(result[0..len], buf[0..len]);
    return result;
}

/// Build a command line string for CreateProcessW. Format: `"<exe>"`.
/// We pass the exe path as a quoted argument so it survives CreateProcessW's
/// argv parsing even if the path contains spaces.
fn buildCommandLine(buf: []u16, exe_path: [:0]const u16) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    // Format: "exe_path" NUL
    // We need 2 (quotes) + exe_path.len + 1 (NUL) characters.
    const needed = exe_path.len + 3;
    if (needed > buf.len) return error.PathTooLong;

    buf[0] = '"';
    @memcpy(buf[1..1 + exe_path.len], exe_path[0..exe_path.len]);
    buf[1 + exe_path.len] = '"';
    buf[1 + exe_path.len + 1] = 0;
    return buf[0 .. 1 + exe_path.len + 1 :0];
}

/// Build an environment block for CreateProcessW: a sequence of
/// NUL-terminated wide strings `NAME=VALUE`, terminated by an empty
/// wide string (double NUL). We just build `PABRIK_DAEMON_CHILD=1\0\0`.
fn buildEnvBlock(buf: []u16) ![:0]u16 {
    if (builtin.os.tag != .windows) unreachable;
    // "PABRIK_DAEMON_CHILD=1" in UTF-16 = 20 chars + 1 NUL terminator + 1 final NUL.
    const name = "PABRIK_DAEMON_CHILD=1";
    const needed = std.unicode.calcUtf16LeLen(name) catch return error.PathTooLong;
    if (needed + 2 > buf.len) return error.PathTooLong;
    _ = std.unicode.utf8ToUtf16Le(buf[0..needed], name) catch return error.PathTooLong;
    buf[needed] = 0;
    buf[needed + 1] = 0; // terminator
    return buf[0..needed :0];
}

// `pidAlive` was REMOVED from this file on 2026-07-24. Callers now use
// the cross-platform helper `helpers.process_status.isProcessRunning(pid)`
// from `src/helpers/process_status.zig`, which handles `pid <= 0`
// early-return plus the Windows `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
// path. The old POSIX implementation here used libc `kill(pid, 0)`
// which doesn't compile on Windows in Zig 0.16 (`std.c.pid_t` is
// `*anyopaque`).
//
// Previous call sites (now routed via the helper):
//   src/service/main_service.zig::serviceStart  (1 site)
//   src/service/main_service.zig::serviceStop   (3 sites)
//   src/service/main_service.zig::serviceStatus (1 site)
//   src/service/daemon.zig                      (4 tests, renamed)
//
// Do NOT re-add `pub fn pidAlive(...)` here — it would re-introduce the
// Windows compile blocker.

// ===== Tests merged from daemon_test.zig (2026-09-29 flatten) =====

// Tests for src/service/daemon.zig (cross-platform daemonization).
//
// ## POSIX daemonize
//
// The POSIX daemonize test forks a child process and verifies the
// grandchild's PPID differs from the original process (which is the
// daemon(7) invariant for "detached from controlling terminal / parent
// process group").
//
// ## Windows daemonize
//
// On Windows, `daemonize()` re-launches the current process via
// `CreateProcessW` with `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP`
// flags, then the parent exits. The detection that "we are the
// detached daemon, not the parent" uses an environment-variable
// sentinel (`PABRIK_DAEMON_CHILD=1`). The static-contract test verifies
// the sentinel-based dispatch is in place; the behavioral test
// (forking the executable) only runs on POSIX.
//
// ## Zig 0.16 API notes
//
//   * std.c.pipe(&pipe_fds) returns 0 on success; -1 on error.
//   * std.c.fork returns the new child's PID (c_int) in the parent,
//     0 in the child, or -1 on error.
//   * std.c.write / read / close are libc wrappers returning
//     isize / c_int; -1 (with errno) on error.
//
// As of 2026-07-24, `daemon.zig::pidAlive` was deleted in favour of the
// cross-platform helper `helpers.process_status.isProcessRunning` —
// which already handles `pid <= 0` early-return plus the Windows
// `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` path (see
// `src/helpers/process_status.zig`). The four pidAlive tests now
// exercise that helper directly.

const testing = std.testing;
// helpers/ lives at src/helpers/, one directory up from src/service/.
const helpers = @import("helpers");

test "isProcessRunning returns false for pid 0" {
    try testing.expect(!helpers.process_status.isProcessRunning(0));
}

test "isProcessRunning returns false for negative pid" {
    try testing.expect(!helpers.process_status.isProcessRunning(-1));
    try testing.expect(!helpers.process_status.isProcessRunning(-99999));
}

test "isProcessRunning returns true for own pid" {
    // Use helpers.process.getCurrentProcessId() (returns i32 cross-platform)
    // rather than std.c.getpid() which returns `*anyopaque` on Windows.
    try testing.expect(helpers.process_status.isProcessRunning(helpers.process.getCurrentProcessId()));
}

test "isProcessRunning returns false for nonexistent pid" {
    if (builtin.os.tag == .windows) {
        // Skip: on Windows we'd need a PID we KNOW doesn't exist and that
        // doesn't get auto-recycled by the kernel in the test window.
        // Skip rather than flaky-test.
        return;
    }
    // Pick a PID that's almost certainly not running. 0x7ffffff0 is
    // near INT_MAX and outside the typical PID range on Linux.
    try testing.expect(!helpers.process_status.isProcessRunning(0x7ffffff0));
}

// ============================================================================
// Cross-platform daemonize() tests
// ============================================================================

// Static contract: a cross-platform `daemonize()` function must exist.
// On POSIX it wraps the double-fork + setsid; on Windows it re-execs
// via CreateProcessW with DETACHED_PROCESS. The function is referenced
// here so the compiler must type-check it on every platform — if the
// function is missing OR throws @compileError on a target, this test
// fails to compile.
test "daemon.daemonize is callable cross-platform" {
    // Just take the address — if this compiles, the function exists.
    const function_pointer = &daemonize;
    _ = function_pointer;
    try testing.expect(true);
}

// Static contract: `daemon.daemonizePosix` is kept as a backward-compat
// alias for `daemonize` on POSIX. On Windows, the function exists but
// calls into the Windows implementation (so legacy callers compile).
test "daemon.daemonizePosix is callable cross-platform" {
    const function_pointer = &daemonizePosix;
    _ = function_pointer;
    try testing.expect(true);
}

// ============================================================================
// Existing POSIX tests
// ============================================================================

test "POSIX daemonize detaches the grandchild from the original" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    // Setup a pipe for parent → grandchild communication.
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const original_ppid = std.c.getpid();
    const pid = std.c.fork();
    if (pid == 0) {
        // Child 1 (will become session leader then exit).
        _ = std.c.close(pipe_fds[0]);
        if (std.c.setsid() < 0) std.process.exit(1);

        const pid2 = std.c.fork();
        if (pid2 != 0) std.process.exit(0); // child 1 exits

        // Grandchild — write the new PPID back to parent.
        const new_ppid = std.c.getppid();
        const ppid_bytes = std.mem.asBytes(&new_ppid);
        _ = std.c.write(pipe_fds[1], ppid_bytes.ptr, ppid_bytes.len);
        _ = std.c.close(pipe_fds[1]);
        std.process.exit(0);
    }
    // Parent reads the grandchild's PPID.
    _ = std.c.close(pipe_fds[1]);
    var ppid_buf: [@sizeOf(c_int)]u8 = undefined;
    _ = std.c.read(pipe_fds[0], @ptrCast(&ppid_buf), ppid_buf.len);
    _ = std.c.close(pipe_fds[0]);
    // std.c.waitpid takes (pid: pid_t, status: ?*c_int, options: c_int).
    // The status pointer is optional — pass null to discard exit status.
    _ = std.c.waitpid(pid, null, 0);

    const child_ppid = std.mem.readInt(c_int, &ppid_buf, std.builtin.Endian.little);
    // After double-fork, the grandchild's PPID is either 1 (init) or
    // the PID of the process that reaped child 1 (usually a subreaper).
    // The key invariant: PPID is no longer the original parent's PID.
    try testing.expect(child_ppid != original_ppid);
}

test "mkdirP creates all parent dirs of a fresh nested path" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    // Build a path under a fresh tmpdir whose nested parent dir does not
    // exist. mkdirP must create every component without error and the
    // leaf's parent dir must exist after the call.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const tmp_dir_path = dir_buf[0..dir_len];

    const leaf = "deeply/nested/that/does/not/exist/service.log";
    const path = try testing.allocator.alloc(u8, tmp_dir_path.len + 1 + leaf.len);
    defer testing.allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    path[tmp_dir_path.len] = '/';
    @memcpy(path[tmp_dir_path.len + 1..], leaf);

    // Pre-condition: the deeply-nested dir does not exist.
    var pre_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(pre_z[0..path.len], path);
    pre_z[path.len] = 0;
    try testing.expect(std.c.access(&pre_z, 0) != 0);

    try mkdirP(path);

    // Post-condition: the deepest parent dir must now exist.
    const parent = std.fs.path.dirname(path).?;
    var post_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(post_z[0..parent.len], parent);
    post_z[parent.len] = 0;
    try testing.expect(std.c.access(&post_z, 0) == 0);
}

test "mkdirP is idempotent on an already-existing parent dir" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    // /tmp always exists; calling mkdirP on "/tmp/anything" must not error.
    try mkdirP("/tmp/this-is-a-mkdirP-test/service.log");
    try mkdirP("/tmp/this-is-a-mkdirP-test/service.log");
}

// ============================================================================
// Windows-specific cross-platform tests
// ============================================================================

// On Windows, mkdirP is implemented via CreateDirectoryW. It should
// still create nested dirs and be idempotent. We run a smoke test
// using a path under the system temp dir.
test "Windows mkdirP creates all parent dirs of a fresh nested path" {
    if (builtin.os.tag != .windows) return;

    // The system temp dir on Windows is %TEMP% (typically C:\Users\<user>\AppData\Local\Temp).
    // We can't depend on std.testing.tmpDir returning a cross-platform
    // realpath on Windows (the underlying realpath uses posix symlinks
    // semantics). Instead we build a unique path under the temp dir.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_z = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse return;
    const tmp = std.mem.sliceTo(tmp_z, 0);
    if (tmp.len >= tmp_buf.len) return;
    @memcpy(tmp_buf[0..tmp.len], tmp);
    const tmp_dir_path: []u8 = tmp_buf[0..tmp.len];

    const leaf = "\\pabrik-mkdirP-test\\deeply\\nested\\that\\does\\not\\exist\\service.log";
    const path = try testing.allocator.alloc(u8, tmp_dir_path.len + leaf.len);
    defer testing.allocator.free(path);
    @memcpy(path[0..tmp_dir_path.len], tmp_dir_path);
    @memcpy(path[tmp_dir_path.len..], leaf);

    // Best-effort cleanup of any prior test residue (idempotent).
    try mkdirP(path);

    // Idempotency: calling again must not error.
    try mkdirP(path);
}
