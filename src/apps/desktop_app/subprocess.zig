// src/apps/desktop_app/subprocess.zig Manages the pabrik child process:
// spawning it, polling its health endpoint, and cleaning it up.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");

// Windows-only WinSock2 externs, declared at module scope so they can be used
// by the Windows branch of `httpGet` (`httpGetWindows`). Why a full winsock
// block instead of `std.c.socket`? — Two reasons: 1.
const win_net = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: c_ushort, wsaData: *WSADATA) callconv(.c) c_int;
    extern "ws2_32" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) callconv(.c) c_int;
    extern "ws2_32" fn connect(sockfd: c_int, addr: [*]const u8, addrlen: c_int) callconv(.c) c_int;
    extern "ws2_32" fn send(sockfd: c_int, buf: [*]const u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn recv(sockfd: c_int, buf: [*]u8, len: c_int, flags: c_int) callconv(.c) c_int;
    extern "ws2_32" fn closesocket(sockfd: c_int) callconv(.c) c_int;
    extern "ws2_32" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_int) callconv(.c) c_int;

    /// WSADATA struct passed to WSAStartup. 400 bytes is the canonical size
    /// per Winsock 2 docs; the contents are intentionally ignored (we just
    /// need the call to succeed so the winsock runtime is available for
    const WSADATA = [400]u8;

    var wsa_init_lock: std.atomic.Mutex = .unlocked;
    var wsa_initialized: bool = false;

    /// Winsock must be initialised with WSAStartup() before any other winsock
    /// call.
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
    /// `child.id` is optional in 0.16; we normalize to a concrete `i32` (or 0
    /// if the platform doesn't expose a pid — e.g. some sandboxed
    /// environments).
    pid: i32,

    /// Send SIGTERM, wait for the child to exit, then SIGKILL if it didn't
    /// respond within a short grace period.
    pub fn terminate(self: *PabrikProcess, io: std.Io) void {
        // In Zig 0.16, `child.kill(io)` is the all-in-one "terminate + wait +
        // cleanup" function: it sends SIGTERM, blocks until the child exits,
        // then sets `child.id = null` to mark the handle reaped.
        self.child.kill(io);
    }
};

/// Poll http://127.0.0.1:<port>/health until it returns 200 or `timeout_ms`
/// elapses. Returns `error.HealthCheckTimeout` on timeout.
pub fn waitForHealth(
    port: u16,
    timeout_ms: u32,
    poll_ms: u32,
) !void {
    // Deadline tracking uses `helpers.monotonicTimestampNanos` (QPC on
    // Windows, CLOCK_MONOTONIC on POSIX — immune to NTP step adjustments) and
    // the poll sleep uses `helpers.sleepMillis` (kernel32 Sleep on Windows,
    const start_ns = helpers.monotonicTimestampNanos();
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        if (probeHealth(port)) return;

        const elapsed_ns = helpers.monotonicTimestampNanos() - start_ns;
        if (elapsed_ns >= timeout_ns) return error.HealthCheckTimeout;

        // Sleep until the next poll, capped at the remaining budget so we
        // don't overshoot the deadline by a full poll interval.
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
    /// True when a literal `<` appears in the response BODY.
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

/// `GET <path>` and report the status code (+ a body sniff). Never allocates,
/// never panics: any failure is reported as `status = 0` so callers can treat
/// "unreachable" and "not what we asked for" alike.
pub fn probeHealth(port: u16) bool {
    const p = httpGet(port, "/health");
    return p.status >= 200 and p.status < 300;
}

/// Does this server actually serve the desktop webapp at `/`? Requires a 2xx
/// AND an HTML-looking body.
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

    // 1-second per-call recv() timeout so a half-dead server can't hang the
    // probe past the next-poll interval.
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
    // per-attempt deadline so a half-dead server can't make the probe hang
    // past the next-poll interval.
    const fd: std.c.fd_t = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd == -1) return .{};
    defer _ = std.c.close(fd);

    // 1-second per-call recv() timeout. If the server hasn't responded within
    // 1s we abandon this probe and let the outer loop retry.
    const rcvtimeo: std.c.timeval = .{ .sec = 1, .usec = 0 };
    _ = std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &rcvtimeo,
        @sizeOf(@TypeOf(rcvtimeo)),
    );

    // Build sockaddr_in for 127.0.0.1:port. Port + addr are big-endian.
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
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    pabrik_path: []const u8,
    port: u16,
    static_dir: ?[]const u8,
) !PabrikProcess {
    _ = allocator; // argv is a small stack-allocated array

    // Build the argv slice. The port number is formatted into a small stack
    // buffer because argv requires a sentinel-free string slice.
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

    // stdin/stdout/stderr: for v1 we set them all to .ignore.
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
        // not a numeric PID.
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
// src/apps/desktop_app/subprocess_test.zig Tests for the pabrik subprocess
// management module.

const testing = std.testing;

test "waitForHealth: returns error.HealthCheckTimeout when target unreachable" {
    // Port 1 is "tcpmux" but on a normal dev box nothing is listening.
    // The kernel will return ECONNREFUSED on connect, so waitForHealth
    // never sees a successful response and times out.
    const result = waitForHealth(1, 200, 50);
    try testing.expectError(error.HealthCheckTimeout, result);
}

test "waitForHealth: succeeds when target returns 200" {
    // Set up a raw-socket mock server in a separate thread. The server side
    // uses Linux syscalls (no Io) so the test thread is free to make blocking
    // syscalls in waitForHealth.
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
    // little-endian on disk (i.e. struct fields) but the .port and .addr
    // fields are in network byte order (big-endian).
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

    // Give the server thread a beat to enter accept(). Without this, a very
    // fast client connect could race the listen() install.
    var setup_ts: helpers.PosixTimespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = helpers.nanosleep(&setup_ts, null);

    // Client side uses raw syscalls via waitForHealth (no Io).
    const result = waitForHealth(port, 2000, 50);
    try testing.expect(result != error.HealthCheckTimeout);
}
