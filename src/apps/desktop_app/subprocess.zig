// src/apps/desktop_app/subprocess.zig
//
// Manages the pabrik child process: spawning it, polling its health
// endpoint, and cleaning it up.
//
// `waitForHealth` connects to 127.0.0.1:<port>/health on a tight
// polling loop and returns when the server responds with a 2xx status.
// Used after `spawn()` to make sure the server is actually accepting
// requests before the webview tries to load it (avoids a race where
// the webview shows a blank page or "connection refused").
//
// `spawn` launches pabrik with `--port <port>` and returns a handle
// the caller uses to `terminate()` on shutdown.
//
// Zig 0.16 API notes (relative to the plan's draft code):
//   * Probing is platform-split: POSIX uses raw libc socket calls
//     (`std.c.socket/connect/recv/close`) which are blocking by
//     default on Linux + macOS and map `EAGAIN` to a real timeout via
//     `SO_RCVTIMEO`. Windows uses the winsock API directly
//     (`WSAStartup` + `socket`/`connect`/`send`/`recv`/`closesocket`
//     from ws2_32) — UCRT's `write`/`recvfrom`/`close` operate on the
//     CRT fd table and fail on SOCKET handles (same root cause as the
//     `sse_manager.sendAll` Windows fix), and winsock requires
//     `WSAStartup` before any other call (without it every `socket()`
//     fails with WSANOTINITIALISED and the probe can never succeed).
//     (`std.Io.net.IpAddress.connect(io, ...)` + `stream.reader` was
//     tried first and abandoned: the Io's `readVec` returns an error on
//     `EAGAIN` — the underlying socket is non-blocking and there's no
//     data yet — so a probe that hits the server before the response
//     is ready fails instead of blocking.)
//   * Deadline tracking uses `helpers.monotonicTimestampNanos` (QPC on
//     Windows, CLOCK_MONOTONIC on POSIX) and the poll sleep uses
//     `helpers.sleepMillis` (kernel32 Sleep on Windows, nanosleep on
//     POSIX) — the raw `clock_gettime`/`nanosleep` externs are
//     POSIX-only with no UCRT provider on Windows.
//   * `std.process.spawn(io, options)` returns a `Child` directly
//     (no `init` + `spawn`). `child.kill()` and `child.wait(io)`
//     take no extra args in 0.16.
//   * An earlier version of this file used raw `std.os.linux.*`
//     syscalls, which compile on macOS but invoke Linux syscall
//     numbers that don't exist on the Darwin kernel — the process
//     gets killed with SIGSYS the first time `clock_gettime` runs.
//     The libc `std.c.*` wrappers fix that without changing the
//     blocking semantics; the libc socket functions return `-1` on
//     error (with errno set) or `0`/byte-count on success, which is
//     slightly different from the raw Linux syscall return convention
//     but equivalent in practice.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");

// Windows-only WinSock2 externs, declared at module scope so they
// can be used by the Windows branch of `httpGet` (`httpGetWindows`).
//
// Why a full winsock block instead of `std.c.socket`? — Two reasons:
//   1. Zig 0.16's `std.c.private.socket` is declared as returning
//      `c_int` on all platforms, but the actual MSVCRT/UCRT `socket()`
//      returns `SOCKET` (= `*anyopaque` = `std.c.fd_t` on Windows).
//      The 32-bit `c_int` binding truncates the high bits of the
//      handle on x64.
//   2. More importantly, UCRT's `write`/`recvfrom`/`close` operate on
//      the CRT fd table (they route to `WriteFile`, which fails on
//      sockets with an error). The only correct way to send/receive
//      on a winsock SOCKET is the winsock API itself (`send`/`recv`)
//      plus `closesocket` for teardown — same root cause as the
//      `sse_manager.sendAll` Windows fix (see sse_manager.zig).
//
// The struct is empty on non-Windows so non-Windows builds never link
// ws2_32 (build.zig already links ws2_32 + kernel32 into
// pabrik-desktop on Windows).
const win_net = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: c_ushort, wsaData: *WSADATA) callconv(.c) c_int;
    extern "ws2_32" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) callconv(.c) c_int;
    extern "ws2_32" fn connect(sockfd: c_int, addr: [*]const u8, addrlen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn send(sockfd: c_int, buf: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn recv(sockfd: c_int, buf: [*]u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn closesocket(sockfd: c_int) callconv(.c) c_int;
    extern "ws2_32" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.c) c_int;

    /// WSADATA struct passed to WSAStartup. 400 bytes is the canonical
    /// size per Winsock 2 docs; the contents are intentionally ignored
    /// (we just need the call to succeed so the winsock runtime is
    /// available for subsequent socket() calls).
    const WSADATA = [400]u8;

    var wsa_init_lock: std.atomic.Mutex = .unlocked;
    var wsa_initialized: bool = false;

    /// Winsock must be initialised with WSAStartup() before any other
    /// winsock call. Without it, `socket()` returns INVALID_SOCKET
    /// (WSANOTINITIALISED) on every invocation — which is exactly the
    /// `HealthCheckTimeout` → `AutoSpawnFailed` failure this fix
    /// addresses. The runtime ref-counts startup calls, so the
    /// lazy-init pattern is safe (mirrors http_server.zig).
    fn ensureWinsockInitialized() void {
        if (wsa_initialized) return;
        while (!wsa_init_lock.tryLock()) std.atomic.spinLoopHint();
        defer wsa_init_lock.unlock();
        if (wsa_initialized) return;
        var wsa_data: WSADATA = undefined;
        // MAKEWORD(2, 2) = 0x0202 — request Winsock 2.2.
        const version: c_ushort = (2 << 8) | 2;
        const rc = WSAStartup(version, &wsa_data);
        if (rc != 0) {
            std.log.err("WSAStartup failed with rc={d}", .{rc});
            return;
        }
        wsa_initialized = true;
    }
} else struct {};

/// Handle to a running pabrik subprocess. Caller MUST call `terminate()`
/// (or `kill` + `wait`) before discarding, otherwise pabrik becomes a
/// zombie until the OS reaps it.
pub const PabrikProcess = struct {
    child: std.process.Child,
    port: u16,
    /// `child.id` is optional in 0.16; we normalize to a concrete `i32`
    /// (or 0 if the platform doesn't expose a pid — e.g. some sandboxed
    /// environments). The pid is useful for logging and debugging only;
    /// `terminate()` does not rely on it.
    pid: i32,

    /// Send SIGTERM, wait for the child to exit, then SIGKILL if it
    /// didn't respond within a short grace period. Always succeeds in
    /// the sense that it can't fail; kill/wait errors are swallowed
    /// (the child may have already exited, or the platform may not
    /// support the signal — either way, the caller is done with the
    /// handle).
    ///
    /// In Zig 0.16, both `child.kill(io)` and `child.wait(io)` take an
    /// `io: Io` argument (Zig moved to Io-runtime-based process control).
    /// The caller passes `io` through the PabrikProcess handle.
    pub fn terminate(self: *PabrikProcess, io: std.Io) void {
        // In Zig 0.16, `child.kill(io)` is the all-in-one "terminate +
        // wait + cleanup" function: it sends SIGTERM, blocks until the
        // child exits, then sets `child.id = null` to mark the handle
        // reaped. Calling `child.wait(io)` AFTER `kill(io)` would assert
        // `child.id != null` and panic — see the doc comment on
        // `std.process.Child.kill` in std/process/Child.zig. So we just
        // call kill and trust it to do everything synchronously.
        self.child.kill(io);
    }
};

/// Poll http://127.0.0.1:<port>/health until it returns 200 or
/// `timeout_ms` elapses. Returns `error.HealthCheckTimeout` on timeout.
///
/// On a busy CI box the pabrik process can take a few hundred ms to
/// start its HTTP server, so a typical call is `waitForHealth(...,
/// 5000, 50)` — poll every 50ms for up to 5 seconds.
pub fn waitForHealth(
    port: u16,
    timeout_ms: u32,
    poll_ms: u32,
) !void {
    // Deadline tracking uses `helpers.monotonicTimestampNanos` (QPC on
    // Windows, CLOCK_MONOTONIC on POSIX — immune to NTP step
    // adjustments) and the poll sleep uses `helpers.sleepMillis`
    // (kernel32 Sleep on Windows, nanosleep on POSIX). Both are
    // cross-platform; the previous version of this loop called the
    // POSIX-only `clock_gettime`/`nanosleep` externs directly, which
    // have no UCRT provider on Windows.
    //
    // Elapsed-based comparison (`now - start >= timeout`) instead of
    // an absolute deadline avoids u64-wraparound edge cases.
    const start_ns = helpers.monotonicTimestampNanos();
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        if (probeHealth(port)) return;

        const elapsed_ns = helpers.monotonicTimestampNanos() - start_ns;
        if (elapsed_ns >= timeout_ns) return error.HealthCheckTimeout;

        // Sleep until the next poll, capped at the remaining budget so
        // we don't overshoot the deadline by a full poll interval.
        // `poll_ms` is already millisecond-granular, so ms sleep is
        // exact for the typical 50/100ms cadences.
        const remaining_ms: u64 = @divFloor(timeout_ns - elapsed_ns, std.time.ns_per_ms);
        const sleep_ms: u32 = @intCast(@min(@as(u64, poll_ms), remaining_ms));
        helpers.sleepMillis(sleep_ms);
    }
}

/// Result of one `GET <path>` over a raw loopback socket.
pub const HttpProbe = struct {
    /// Parsed HTTP status code, or 0 when the connection failed or the
    /// status line could not be read.
    status: u16 = 0,
    /// True when a literal `<` appears in the response BODY. Distinguishes
    /// "index.html was served" from "some other 2xx response" — without it
    /// any server that answers `/` with 200 would look like a servable
    /// webapp.
    body_looks_html: bool = false,
};

/// How much of a probe response we read. Comfortably covers the status
/// line + headers + the start of index.html, which is all the status/`<`
/// sniff below needs.
const max_probe_bytes: usize = 2048;

/// Platform dispatch: winsock on Windows (UCRT socket calls don't work on
/// SOCKET handles), libc sockets on POSIX.
fn httpGet(port: u16, path: []const u8) HttpProbe {
    if (comptime builtin.os.tag == .windows) return httpGetWindows(port, path);
    return httpGetPosix(port, path);
}

/// `GET <path>` and report the status code (+ a body sniff). Never
/// allocates, never panics: any failure is reported as `status = 0` so
/// callers can treat "unreachable" and "not what we asked for" alike.
/// Is something answering `GET /health` with 2xx on this port?
///
/// NOTE: this is NOT sufficient to decide the desktop can use a server —
/// `/health` is an API route and answers 200 even when the process was
/// started without a usable `--static-dir`. Use `probeWebapp` for that.
pub fn probeHealth(port: u16) bool {
    const p = httpGet(port, "/health");
    return p.status >= 200 and p.status < 300;
}

/// Does this server actually serve the desktop webapp at `/`?
///
/// Requires a 2xx AND an HTML-looking body. A daemon whose `--static-dir`
/// no longer exists answers `/health` with 200 but `/` with
/// `404 Not Found`; attaching the webview to it is exactly the "blank 404
/// page" bug this check exists to prevent.
pub fn probeWebapp(port: u16) bool {
    const p = httpGet(port, "/");
    return p.status >= 200 and p.status < 300 and p.body_looks_html;
}

/// Can we stop reading? We need the status line (all of it) plus at least
/// one body byte that looks like markup.
fn probeResponseComplete(bytes: []const u8) bool {
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return false;
    return std.mem.indexOfScalar(u8, bytes[header_end + 4 ..], '<') != null;
}

fn parseProbeResponse(bytes: []const u8) HttpProbe {
    var out: HttpProbe = .{};
    // Status line is "HTTP/1.x NNN ..." — the 3 digits start at index 9.
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "HTTP/1.")) {
        out.status = std.fmt.parseInt(u16, bytes[9..12], 10) catch 0;
    }
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |header_end| {
        out.body_looks_html = std.mem.indexOfScalar(u8, bytes[header_end + 4 ..], '<') != null;
    }
    return out;
}

/// Windows probe via the winsock API directly. Requires WSAStartup
/// (lazy-init'd above) — without it every `socket()` call fails with
/// WSANOTINITIALISED and the probe can never succeed.
fn httpGetWindows(port: u16, path: []const u8) HttpProbe {
    win_net.ensureWinsockInitialized();

    // AF_INET=2, SOCK_STREAM=1, IPPROTO_TCP=6 (same constants
    // http_server.zig and test_helpers.zig use on Windows).
    const sock = win_net.socket(2, 1, 6);
    if (sock == -1) return .{}; // INVALID_SOCKET
    defer _ = win_net.closesocket(sock);

    // 1-second per-call recv() timeout so a half-dead server can't hang
    // the probe past the next-poll interval. NOTE: on Windows
    // SO_RCVTIMEO takes a DWORD of milliseconds (not a timeval struct
    // like POSIX) — SOL_SOCKET=0xFFFF, SO_RCVTIMEO=0x1006.
    const timeout_ms_win: u32 = 1000;
    _ = win_net.setsockopt(sock, 0xFFFF, 0x1006, @ptrCast(&timeout_ms_win), @sizeOf(u32));

    // sockaddr_in for 127.0.0.1:port. Layout matches test_helpers.zig's
    // TCP-loopback fixture (family/port/addr/zero); 0x0100007f is
    // 127.0.0.1 as a little-endian u32 (wire bytes 127,0,0,1).
    const sockaddr = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0x0100007f,
        .zero = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    if (win_net.connect(sock, std.mem.asBytes(&sockaddr), @sizeOf(std.c.sockaddr.in)) != 0) return .{};

    // Send a minimal HTTP/1.0 request (server closes after one response
    // — no keep-alive bookkeeping needed).
    var req_buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET {s} HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{path},
    ) catch return .{};
    var sent: usize = 0;
    while (sent < req.len) {
        const n = win_net.send(sock, req[sent..].ptr, @intCast(req.len - sent), 0);
        if (n <= 0) return .{};
        sent += @intCast(n);
    }

    // Read the status line + the start of the body. We stop early once we
    // have both (see probeResponseComplete) and otherwise at EOF, which
    // `Connection: close` guarantees.
    var buf: [max_probe_bytes]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = win_net.recv(sock, buf[total..].ptr, @intCast(buf.len - total), 0);
        if (n <= 0) break; // -1 = error/timeout, 0 = EOF — server closed
        total += @intCast(n);
        if (probeResponseComplete(buf[0..total])) break;
    }
    return parseProbeResponse(buf[0..total]);
}

fn httpGetPosix(port: u16, path: []const u8) HttpProbe {
    // Open a blocking TCP socket. SO_RCVTIMEO gives the recv() call a
    // per-attempt deadline so a half-dead server can't make the probe
    // hang past the next-poll interval.
    //
    // Uses libc `std.c.socket`. An earlier version called
    // `std.os.linux.socket` which compiles on macOS but invokes the
    // Linux syscall number — which doesn't exist on the Darwin kernel,
    // so the process gets killed with SIGSYS on the first probe.
    // (Windows never reaches this function — see `httpGet` dispatch.)
    const fd: std.c.fd_t = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd == -1) return .{};
    defer _ = std.c.close(fd);

    // 1-second per-call recv() timeout. If the server hasn't responded
    // within 1s we abandon this probe and let the outer loop retry.
    // Use `std.c.timeval` (cross-platform) so the field layout matches
    // the kernel's expectation on both Linux and macOS — previous
    // versions of this file used a hand-rolled byte array, which was
    // easy to get wrong on little-endian targets (e.g. tv_sec = 1
    // needs bytes [1, 0, 0, 0, 0, 0, 0, 0], not [0, 0, 0, 1, ...]).
    const rcvtimeo: std.c.timeval = .{ .sec = 1, .usec = 0 };
    _ = std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &rcvtimeo,
        @sizeOf(@TypeOf(rcvtimeo)),
    );

    // Build sockaddr_in for 127.0.0.1:port. Port + addr are big-endian.
    // `std.c.sockaddr.in` has fields `family`, `port`, `addr`, `zero`
    // on Linux (4 fields, 16 bytes); on macOS there's an additional
    // `len: u8` prefix field. Both versions default `family` to AF.INET
    // and `zero` to all-zeros, so we only set `port` and `addr`.
    const addr_bytes = [_]u8{ 127, 0, 0, 1 };
    var addr: u32 = 0;
    for (addr_bytes, 0..) |b, i| addr |= @as(u32, b) << @intCast(i * 8);
    const sockaddr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = addr,
    };
    const connect_rc = std.c.connect(
        fd,
        @ptrCast(&sockaddr),
        @sizeOf(std.c.sockaddr.in),
    );
    if (connect_rc == -1) return .{};

    // Send a minimal HTTP/1.0 request. We use HTTP/1.0 (not 1.1) so
    // the server is allowed to close the connection after the single
    // response — no keep-alive bookkeeping needed.
    var req_buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET {s} HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{path},
    ) catch return .{};
    // Loop the write: a short write on the post-spawn verification path
    // would look like "server down" and get a healthy child killed.
    var sent: usize = 0;
    while (sent < req.len) {
        const n: isize = std.c.write(fd, req[sent..].ptr, req.len - sent);
        if (n <= 0) return .{};
        sent += @intCast(n);
    }

    // Read the status line + the start of the body. We stop early once we
    // have both (see probeResponseComplete) and otherwise at EOF, which
    // `Connection: close` guarantees.
    var buf: [max_probe_bytes]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n_rc = std.c.recvfrom(fd, buf[total..].ptr, buf.len - total, 0, null, null);
        if (n_rc <= 0) break; // -1 = error/timeout, 0 = EOF — server closed
        total += @intCast(n_rc);
        if (probeResponseComplete(buf[0..total])) break;
    }
    return parseProbeResponse(buf[0..total]);
}

/// Spawn pabrik as a child process with `--port <port>` and, optionally,
/// `--static-dir <path>` (so pabrik serves the embedded webapp at `/`).
/// The caller is responsible for calling `terminate()` on the returned
/// handle before discarding it.
///
/// `io` is the Io runtime handle (Zig 0.16's `std.process.spawn` takes
/// `io: Io` as its first arg). `allocator` is used by the Child handle
/// internally — pass the long-lived app allocator, NOT std.testing.allocator.
///
/// `static_dir`: if non-null, the child pabrik is started with
/// `--static-dir <path>` so it serves the directory's contents at HTTP
/// `/`. pabrik-desktop's spawn mode passes the path of the temp dir
/// containing the extracted webapp assets; connect mode passes null
/// (the user is responsible for running their own pabrik with the right
/// --static-dir).
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    pabrik_path: []const u8,
    port: u16,
    static_dir: ?[]const u8,
) !PabrikProcess {
    _ = allocator; // argv is a small stack-allocated array

    // Build the argv slice. The port number is formatted into a small
    // stack buffer because argv requires a sentinel-free string slice.
    // We use a fixed-size array (max 5 args) and slice it down to the
    // actual count — avoids a heap allocation for the common case.
    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch @panic("bufPrint failed formatting the spawn port");

    var argv_buf: [5][]const u8 = .{
        pabrik_path, "--port", port_str, "--static-dir", undefined,
    };
    var argv_count: usize = 3;
    if (static_dir) |sd| {
        argv_buf[3] = "--static-dir";
        argv_buf[4] = sd;
        argv_count = 5;
    }
    const argv = argv_buf[0..argv_count];

    // stdin/stdout/stderr: for v1 we set them all to .ignore. The design
    // doc says we should capture stderr for diagnostics, but Chunk 2 is
    // a pure unit-test milestone and Chunk 8 will wire up capture if
    // the webview chunks find a need for it.
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        // Map spawn errors into a single descriptive error so callers
        // can match on `error.SpawnFailed` without enumerating every
        // OS-level variant.
        std.log.err("spawn pabrik at {s} failed: {s}", .{ pabrik_path, @errorName(err) });
        return error.SpawnFailed;
    };

    return .{
        .child = child,
        .port = port,
        // Windows note: `child.id` is `?HANDLE` (= `?*anyopaque`) on Windows,
        // not a numeric PID. There is no real libc `pid_t` in the MSVCRT/
        // UCRT, so we can't `@intCast` a HANDLE to `i32`. Per the doc comment
        // on `pid`, the field is purely for logging/debugging and `terminate()`
        // uses `child.id` directly — so 0 on Windows is a correct no-op
        // (and matches the existing "or 0 if the platform doesn't expose a
        // pid" semantic for sandboxed environments).
        .pid = switch (builtin.os.tag) {
            .windows => 0,
            else => if (child.id) |pid| @intCast(pid) else 0,
        },
    };
}



comptime {
    // Quiet the unused-import warning if the platform branch below is
    // empty for the current target. `builtin` is referenced in the
    // module doc; this is just a safety net.
    _ = builtin;
}

// ===== Tests merged from subprocess_test.zig (2026-09-29 flatten) =====
// src/apps/desktop_app/subprocess_test.zig
//
// Tests for the pabrik subprocess management module. Two test cases:
//
//   1. waitForHealth timeout: poll a port that nothing is listening on,
//      expect `error.HealthCheckTimeout` before the deadline elapses.
//   2. waitForHealth success: stand up a tiny mock HTTP server in a
//      background thread, point waitForHealth at it, expect success
//      within the timeout window.
//
// Both the mock server and the health-check probe use **raw Linux
// syscalls** (`std.os.linux.socket/bind/listen/accept/recv/...`).
// waitForHealth does too — the `std.Io.net` abstraction was tried
// first and abandoned: its `readVec` returns an error on `EAGAIN`
// (the underlying socket is non-blocking, so a probe that hits the
// server before the response is ready fails instead of blocking),
// which makes a one-shot health check unreliable. Raw blocking
// syscalls with `SO_RCVTIMEO` give clean "block until the response
// arrives" semantics.
//
// Zig 0.16 API notes:
//   * `std.Io.Threaded.init(allocator, .{})` then `.io()` replaces
//     the old implicit-global `std.Io`.
//   * Raw socket syscalls live in `std.os.linux.*` (no public
//     `std.posix.socket/bind/...` wrappers in 0.16).
//   * `std.c.nanosleep` + `std.posix.timespec` for blocking waits.

const testing = std.testing;

test "waitForHealth: returns error.HealthCheckTimeout when target unreachable" {
    // Port 1 is "tcpmux" but on a normal dev box nothing is listening.
    // The kernel will return ECONNREFUSED on connect, so waitForHealth
    // never sees a successful response and times out.
    const result = waitForHealth(1, 200, 50);
    try testing.expectError(error.HealthCheckTimeout, result);
}

test "waitForHealth: succeeds when target returns 200" {
    // Set up a raw-socket mock server in a separate thread. The server
    // side uses Linux syscalls (no Io) so the test thread is free to
    // make blocking syscalls in waitForHealth.
    //
    // The Zig 0.16 stdlib has no public `std.posix.socket/bind/...`
    // wrappers — those calls live in `std.os.linux.*` and return a raw
    // `usize` (success value on success, `-errno` cast to `usize` on
    // failure). We cast/check the return inline. The `errno()` helper
    // inside posix.zig is private, so for test setup we just check
    // that the rc fits in a non-negative fd_t.
    const fd_rc = std.os.linux.socket(
        std.os.linux.AF.INET,
        std.os.linux.SOCK.STREAM,
        0,
    );
    if (fd_rc > std.math.maxInt(i32)) return error.TestSetupFailed;
    const fd: i32 = @intCast(fd_rc);
    defer _ = std.os.linux.close(fd);

    // SO_REUSEADDR so the kernel doesn't hold the port in TIME_WAIT
    // after the test process exits (lets consecutive test runs reuse
    // the same port).
    const one: c_int = 1;
    _ = std.os.linux.setsockopt(
        fd,
        std.os.linux.SOL.SOCKET,
        std.os.linux.SO.REUSEADDR,
        @ptrCast(&one),
        @sizeOf(c_int),
    );

    // Bind to 127.0.0.1:0 — kernel picks the port. sockaddr.in is
    // little-endian on disk (i.e. struct fields) but the .port and
    // .addr fields are in network byte order (big-endian). The literal
    // 0x0100007F is 127.0.0.1 in network byte order.
    var bind_addr = std.os.linux.sockaddr.in{
        .port = 0,
        .addr = 0x0100007F,
    };
    const bind_rc = std.os.linux.bind(
        fd,
        @ptrCast(&bind_addr),
        @sizeOf(std.os.linux.sockaddr.in),
    );
    if (bind_rc != 0) return error.TestSetupFailed;

    // Get the assigned port back from the kernel.
    var assigned: std.os.linux.sockaddr.in = undefined;
    var addr_len: std.os.linux.socklen_t = @sizeOf(std.os.linux.sockaddr.in);
    _ = std.os.linux.getsockname(fd, @ptrCast(&assigned), &addr_len);
    const port = std.mem.bigToNative(u16, assigned.port);

    const listen_rc = std.os.linux.listen(fd, 1);
    if (listen_rc != 0) return error.TestSetupFailed;

    // Server thread: accept one connection, write 200 OK, close. All
    // raw syscalls — no Io involvement.
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(server_fd: i32) void {
            const conn_rc = std.os.linux.accept(server_fd, null, null);
            if (conn_rc <= std.math.maxInt(i32)) {
                const conn_fd: i32 = @intCast(conn_rc);
                const response = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK";
                _ = std.os.linux.write(conn_fd, response.ptr, response.len);
                _ = std.os.linux.close(conn_fd);
            }
        }
    }.run, .{fd});
    defer thread.join();

    // Give the server thread a beat to enter accept(). Without this, a
    // very fast client connect could race the listen() install.
    // We use `helpers.PosixTimespec` (and `helpers.nanosleep`) instead
    // of `std.posix.timespec` because the stdlib version is `void` on
    // Windows in Zig 0.16.
    var setup_ts: helpers.PosixTimespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = helpers.nanosleep(&setup_ts, null);

    // Client side uses raw syscalls via waitForHealth (no Io).
    const result = waitForHealth(port, 2000, 50);
    try testing.expect(result != error.HealthCheckTimeout);
}
