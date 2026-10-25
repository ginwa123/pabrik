//! `pabrik-vm-netd` — the in-guest network forwarder: loopback, the tenant's
//! resolver config, an HTTP proxy on 127.0.0.1:3128 and a DNS proxy on
//! 127.0.0.1:53, each carried out of the VM over vsock to the host.

const std = @import("std");
const linux = std.os.linux;
const egress = @import("egress_env.zig");

// ─── constants ───────────────────────────────────────────────────────────

/// The host's two vsock listeners: egress on 5001, the resolver on 5002.
const egress_port: u32 = 5001;
const resolver_port: u32 = 5002;
/// The host's CID in virtio-vsock, and the guest's own AF_VSOCK number.
const cid_host: u32 = 2;
const vsock_af: u32 = 40;
const af_inet: u32 = 2;

/// Where netd listens for the tenant: the proxy and the resolver.
const proxy_port: u16 = 3128;
const dns_port: u16 = 53;
/// The tenant's loopback: netd binds and dials nothing else. With the opt-in
/// tap mode the guest also has `eth0`, which netd never uses.
const loopback_text = "127.0.0.1";

/// One request head, read whole. 16 KiB is past any real head, and the cap is
/// what keeps a flooding client from growing netd's stack.
const max_head: usize = 16 * 1024;
/// The handshake line and its reply: a host name, a port and a DENY reason.
const handshake_max: usize = 512;
/// A whole `403`: the reason above plus the headers wrapped around it.
const deny_bytes: usize = 1024;
/// The relay's chunk, so most of a copy crosses in one read and one write.
const relay_chunk: usize = 64 * 1024;

/// One UDP query — 1200 bytes is the EDNS-safe ceiling — and one reply from
/// the host, capped by `egress.resolver_response_cap`.
const dns_query_max: usize = 1200;
const dns_reply_max: usize = 4096;
/// A DNS header: an id, flags and four counts. Shorter is not a query.
const dns_header_bytes: usize = 12;

/// Every wait is counted in poll slices, so no single call blocks forever.
const poll_slice_ms: i32 = 1000;
const head_slices: u32 = 10;
const reply_slices: u32 = 10;
/// Each of the DNS path's two reads gets 5 s, so one datagram holds the
/// parent for at most 10 s before it is answered with SERVFAIL.
const dns_slices: u32 = 5;
/// The relay polls in 5 s slices and gives up after 120 s of no traffic.
const relay_slice_ms: i32 = 5000;
const relay_idle_ms: u32 = 120_000;
/// The listener loop's tick, which is also how often children are reaped.
const tick_ms: i32 = 1000;

/// The egress tunnel is retried five times, 200 ms apart, on ECONNREFUSED:
/// the host's listener may still be starting when the first client arrives.
const connect_attempts: usize = 5;
const connect_retry_ms: u64 = 200;
const listen_backlog: u32 = 64;

/// `SIOCGIFFLAGS`/`SIOCSIFFLAGS` on an `ifreq`, and the two flags netd sets.
const siocgifflags: u32 = 0x8913;
const siocsifflags: u32 = 0x8914;
const iff_up: i16 = 0x1;
const iff_running: i16 = 0x40;

/// The `mknod` mode of a character device, and the tenant's resolver config.
const char_dev: u32 = 0o020000;
const resolv_path = "/etc/resolv.conf";
const resolv_text = "nameserver 127.0.0.1\noptions timeout:2 attempts:3 ndots:2\n";
/// Readable by any tenant process, writable only by root. The egress profile
/// is the same: every workload has to read it, only root may rewrite it.
const tenant_readable_mode: u32 = 0o644;
/// `wait4`'s WNOHANG: reaping must never block the listeners.
const wno_hang: u32 = 1;

/// Answers netd writes itself. Each one closes the connection: a proxied
/// exchange is never reused for a second request.
const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const bad_gateway = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const established = "HTTP/1.1 200 Connection Established\r\n\r\n";

/// The two local listeners, in file scope so a forked child can close both.
var listen_tcp: ?linux.fd_t = null;
var listen_udp: ?linux.fd_t = null;

// ─── shapes ──────────────────────────────────────────────────────────────

/// Kernel layout: 2 + 2 + 4 + 4 bytes plus 4 of zero padding = 16.
const SockaddrVm = extern struct {
    family: u16,
    reserved: u16 = 0,
    port: u32,
    cid: u32,
    zero: [4]u8 = .{0} ** 4,
};

/// `struct ifreq` as these two ioctls see it: 16 bytes of name, the flags,
/// then padding out to the 40-byte view the kernel reads.
const IfReq = extern struct {
    name: [16]u8,
    flags: i16,
    pad: [22]u8 = .{0} ** 22,
};

/// The head read so far: `head` ends at the blank line, and `buffered` also
/// carries any body bytes that arrived in the same reads.
const Head = struct {
    head: []const u8,
    buffered: []const u8,
};

/// A request line's three space-separated fields.
const RequestLine = struct {
    method: []const u8,
    target: []const u8,
    version: []const u8,
};

/// The three shapes a request target can have as far as netd is concerned.
const DestKind = enum { connect, absolute, bad };

/// Where a request is bound: the egress host and port, and for absolute form
/// the origin-form path the request line has to be rewritten to.
const Dest = struct {
    kind: DestKind,
    host: []const u8,
    port: u16,
    origin: []const u8,
};

/// What one relay pump did: bytes moved, nothing to move, or an end.
const Pump = enum { moved, idle, eof, failed };

// ─── transport ───────────────────────────────────────────────────────────

/// Every byte of `bytes`, or false as soon as a write fails.
fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

/// One line of the serial console's netd log.
fn logLine(bytes: []const u8) void {
    _ = writeAll(1, "[pabrik-vm-netd] ");
    _ = writeAll(1, bytes);
    _ = writeAll(1, "\n");
}

/// One polled read: null on EOF, error or the slice timing out.
fn readSome(fd: linux.fd_t, buf: []u8, slice_ms: i32) ?usize {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&fds, 1, slice_ms);
    if (linux.errno(rc) != .SUCCESS) return null;
    if (rc == 0) return null;
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return n;
}

/// Fill `buf` from `fd`, giving up after `slices` polls of `slice_ms`.
fn readExact(fd: linux.fd_t, buf: []u8, slice_ms: i32, slices: u32) bool {
    var off: usize = 0;
    var left = slices;
    while (off < buf.len and left > 0) {
        const n = readSome(fd, buf[off..], slice_ms) orelse {
            left -= 1;
            continue;
        };
        off += n;
    }
    return off == buf.len;
}

/// One `\n`-terminated reply line without its newline, or null on the 512
/// byte cap, a dead host or the deadline.
fn readReplyLine(fd: linux.fd_t, buf: []u8) ?[]const u8 {
    var have: usize = 0;
    var left: u32 = reply_slices;
    while (left > 0) {
        if (have == buf.len) return null;
        const n = readSome(fd, buf[have..], poll_slice_ms) orelse {
            left -= 1;
            continue;
        };
        have += n;
        if (std.mem.indexOfScalar(u8, buf[0..have], '\n')) |end| return buf[0..end];
    }
    return null;
}

/// A NUL-terminated copy of `src` in `dst`, or null when it does not fit.
fn cstr(src: []const u8, dst: []u8) ?[*:0]const u8 {
    if (src.len + 1 > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @ptrCast(dst.ptr);
}

/// A blocking sleep of `ms`: the retry pause between the connect attempts.
fn sleepMs(ms: u64) void {
    const ts = linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&ts, null);
}

// ─── guest setup ─────────────────────────────────────────────────────────

/// `_exit(0)` for a forked child: the thread's own exit, so a child that
/// somehow grew a second thread cannot take the parent down with it.
fn childExit() noreturn {
    linux.exit(0);
}

/// SIGPIPE would kill a relay's child mid-write; ignore it and let `write`
/// report the broken pipe instead.
fn ignoreSigpipe() void {
    const act = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = .{0},
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

/// One inet socket of the given type, as raw a fd as the kernel returns.
fn socketInet(kind: u32) ?linux.fd_t {
    const rc = linux.socket(af_inet, kind, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// One decimal octet of a dotted quad: digits only, and a leading zero only
/// when the number is 0.
fn parseOctet(part: []const u8) ?u32 {
    if (part.len == 0 or part.len > 3) return null;
    if (part.len > 1 and part[0] == '0') return null;
    var value: u32 = 0;
    for (part) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    if (value > 255) return null;
    return value;
}

/// Four strict octets (`127.1` is refused, so is `256.0.0.1`), returned as the
/// octets' big-endian number, which `sockaddr.in` wants byte-swapped on the
/// way in — the same treatment its port field gets.
fn parseIpv4(text: []const u8) ?u32 {
    var value: u32 = 0;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, text, '.');
    while (it.next()) |part| {
        if (parts == 4) return null;
        const octet = parseOctet(part) orelse return null;
        value = (value << 8) | octet;
        parts += 1;
    }
    if (parts != 4) return null;
    return value;
}

/// Create the device node at `path` unless it is already there: the kernel
/// answers `EEXIST` for a node the agent made, which is not a failure.
fn makeNode(path: []const u8, major: u32, minor: u32) bool {
    var buf: [64]u8 = undefined;
    const path_z = cstr(path, &buf) orelse return false;
    const dev = (major << 8) | minor;
    const err = linux.errno(linux.mknod(path_z, char_dev, @intCast(dev)));
    return err == .SUCCESS or err == .EXIST;
}

/// The three device nodes netd wants present, so a redirected child has the
/// usual `/dev/null`, `/dev/zero` and `/dev/urandom`.
fn ensureDev() void {
    _ = linux.mkdir("/dev", 0o755);
    var present: usize = 0;
    if (makeNode("/dev/null", 1, 3)) present += 1;
    if (makeNode("/dev/zero", 1, 5)) present += 1;
    if (makeNode("/dev/urandom", 1, 9)) present += 1;
    logLine(if (present == 3) "device nodes ready" else "MISSING device nodes");
}

/// Raise `lo` with `SIOCSIFFLAGS`: the kernel has the interface, nothing in
/// the guest ever brings it up, and every listener below needs it. A failure
/// is logged, not fatal — the binds will say so themselves.
fn bringLoopbackUp() bool {
    const fd = socketInet(linux.SOCK.DGRAM) orelse return false;
    defer _ = linux.close(fd);
    var req = IfReq{ .name = [_]u8{0} ** 16, .flags = 0 };
    req.name[0] = 'l';
    req.name[1] = 'o';
    if (linux.errno(linux.ioctl(fd, siocgifflags, @intFromPtr(&req))) != .SUCCESS) return false;
    req.flags |= iff_up | iff_running;
    return linux.errno(linux.ioctl(fd, siocsifflags, @intFromPtr(&req))) == .SUCCESS;
}

/// Bind an open inet socket to 127.0.0.1:port.
fn bindLoopback(fd: linux.fd_t, port: u16) bool {
    const octets = parseIpv4(loopback_text) orelse return false;
    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, octets),
    };
    return linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) == .SUCCESS;
}

/// A listening TCP socket on 127.0.0.1:port, or null when the kernel refuses
/// the socket, the address or the listen.
fn bindLoopbackTcp(port: u16) ?linux.fd_t {
    const fd = socketInet(linux.SOCK.STREAM) orelse return null;
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(i32));
    if (!bindLoopback(fd, port) or linux.errno(linux.listen(fd, listen_backlog)) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// A UDP socket bound on 127.0.0.1:port: the tenant's resolver.
fn bindLoopbackUdp(port: u16) ?linux.fd_t {
    const fd = socketInet(linux.SOCK.DGRAM) orelse return null;
    if (!bindLoopback(fd, port)) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

/// Write the resolver config, creating `/etc` if the image has none. The
/// nameserver is netd itself, so a lookup lands on the DNS proxy below.
fn writeResolvConf() bool {
    _ = linux.mkdir("/etc", 0o755);
    var buf: [64]u8 = undefined;
    const path = cstr(resolv_path, &buf) orelse return false;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, tenant_readable_mode);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return writeAll(fd, resolv_text);
}

/// Write the egress profile: every login shell gets the proxy the workload is
/// handed at exec time, so `sh -l` and the terminal tab reach the host too.
fn writeProfileScript() bool {
    _ = linux.mkdir("/etc", 0o755);
    _ = linux.mkdir("/etc/profile.d", 0o755);
    var buf: [128]u8 = undefined;
    const path = cstr(egress.profile_path, &buf) orelse return false;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, tenant_readable_mode);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    return writeAll(fd, egress.profile_script);
}

/// A connected AF_VSOCK stream to the host, retried on `ECONNREFUSED` because
/// the host's listener may still be coming up when the first client arrives.
fn connectVsock(port: u32) ?linux.fd_t {
    var attempt: usize = 0;
    while (attempt < connect_attempts) : (attempt += 1) {
        const rc = linux.socket(vsock_af, linux.SOCK.STREAM, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(rc);
        var addr = SockaddrVm{ .family = vsock_af, .port = port, .cid = cid_host };
        const err = linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
        if (err == .SUCCESS) return fd;
        _ = linux.close(fd);
        if (err != .CONNREFUSED) return null;
        sleepMs(connect_retry_ms);
    }
    return null;
}

// ─── proxy ───────────────────────────────────────────────────────────────

/// The index just past the blank line that ends a head, for `\r\n\r\n` or a
/// bare `\n\n`. The CRLF form is tested first: a body starting with a newline
/// must not be mistaken for the end of the head.
fn headEnd(buf: []const u8) ?usize {
    var at: usize = 0;
    while (at < buf.len) : (at += 1) {
        if (buf[at] != '\n') continue;
        if (at >= 3 and std.mem.eql(u8, buf[at - 3 .. at + 1], "\r\n\r\n")) return at + 1;
        if (at + 1 < buf.len and buf[at + 1] == '\n') return at + 2;
    }
    return null;
}

/// Read until the blank line that ends the head, or null on the 16 KiB cap,
/// a dead client or the 10 s deadline.
fn readHead(fd: linux.fd_t, buf: []u8) ?Head {
    var have: usize = 0;
    var left: u32 = head_slices;
    while (left > 0) {
        if (headEnd(buf[0..have])) |end| {
            return .{ .head = buf[0..end], .buffered = buf[0..have] };
        }
        if (have == buf.len) return null;
        const n = readSome(fd, buf[have..], poll_slice_ms) orelse {
            left -= 1;
            continue;
        };
        have += n;
    }
    return null;
}

/// A request line's method, target and version, or null when one is missing.
fn parseRequestLine(line: []const u8) ?RequestLine {
    const text = std.mem.trim(u8, line, " \t\r\n");
    const first = std.mem.indexOfAny(u8, text, " \t") orelse return null;
    const method = text[0..first];
    const rest = std.mem.trimStart(u8, text[first..], " \t");
    const second = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const version = std.mem.trim(u8, rest[second..], " \t");
    const target = rest[0..second];
    if (method.len == 0 or target.len == 0 or version.len == 0) return null;
    return .{ .method = method, .target = target, .version = version };
}

/// The value of the `Host:` header, matched case-insensitively, or null.
fn hostHeader(head: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "host")) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// A port from decimal text: digits only, non-empty, at most 65535.
fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = value * 10 + (c - '0');
    }
    if (value > 65535) return null;
    return @intCast(value);
}

/// Split a request target into the egress host and port. `CONNECT` carries
/// `host[:port]`; an absolute-form target carries `http://host[:port]/path`
/// and reports the path back so the request line can be rewritten to it.
fn parseDest(method: []const u8, target: []const u8) Dest {
    if (std.mem.eql(u8, method, "CONNECT")) {
        const colon = std.mem.indexOfScalar(u8, target, ':');
        const host = if (colon) |at| target[0..at] else target;
        const port: u16 = if (colon) |at| (parsePort(target[at + 1 ..]) orelse 0) else 443;
        return .{ .kind = .connect, .host = host, .port = port, .origin = "" };
    }
    if (std.ascii.startsWithIgnoreCase(target, "http://")) {
        const rest = target["http://".len..];
        const end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
        const authority = rest[0..end];
        if (authority.len == 0) return .{ .kind = .bad, .host = "", .port = 0, .origin = "" };
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        const host = if (colon) |at| authority[0..at] else authority;
        const port: u16 = if (colon) |at| (parsePort(authority[at + 1 ..]) orelse 0) else 80;
        const origin = if (end == rest.len) "/" else rest[end..];
        return .{ .kind = .absolute, .host = host, .port = port, .origin = origin };
    }
    return .{ .kind = .bad, .host = "", .port = 0, .origin = "" };
}

/// The one-line egress handshake `PABRIK-EGRESS/1 <host> <port>\n`. Null when
/// the host is empty, the port is refused, or the line cannot fit 512 bytes.
fn handshakeLine(buf: []u8, host: []const u8, port: u16) ?[]const u8 {
    if (host.len == 0 or port == 0) return null;
    for (host) |c| {
        // The line is space-separated, so no host byte may be one.
        if (c <= ' ' or c >= 0x7f) return null;
    }
    return std.fmt.bufPrint(buf, "PABRIK-EGRESS/1 {s} {d}\n", .{ host, port }) catch return null;
}

/// Whether a poll result says this fd has something to read or has ended.
fn ready(pfd: linux.pollfd) bool {
    return pfd.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0;
}

/// Move whatever `src` has to `dst`, once. `eof` is the peer closing its end,
/// which the caller has to forward as a half-close rather than a teardown.
fn pumpOnce(src: linux.fd_t, dst: linux.fd_t, buf: []u8) Pump {
    const n = linux.read(src, buf.ptr, buf.len);
    const read_err = linux.errno(n);
    if (read_err == .INTR or read_err == .AGAIN) return .idle;
    if (read_err != .SUCCESS or n == 0) return .eof;
    var off: usize = 0;
    while (off < n) {
        const w = linux.write(dst, buf.ptr + off, n - off);
        if (linux.errno(w) != .SUCCESS or w == 0) return .failed;
        off += w;
    }
    return .moved;
}

/// Pump both ways until both directions are done or 120 s pass with nothing
/// moving. A direction that ends is half-closed, so its peer still sees the
/// rest of the stream and then a clean EOF.
fn relay(client_fd: linux.fd_t, vsock_fd: linux.fd_t) void {
    var buf: [relay_chunk]u8 = undefined;
    var client_open = true;
    var vsock_open = true;
    var idle_ms: u32 = 0;
    while (client_open or vsock_open) {
        var fds = [2]linux.pollfd{
            .{ .fd = if (client_open) client_fd else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (vsock_open) vsock_fd else -1, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, fds.len, relay_slice_ms);
        if (linux.errno(rc) != .SUCCESS) break;
        if (rc == 0) {
            idle_ms += @intCast(relay_slice_ms);
            if (idle_ms >= relay_idle_ms) break;
            continue;
        }
        var moved = false;
        var failed = false;
        if (client_open and ready(fds[0])) {
            switch (pumpOnce(client_fd, vsock_fd, &buf)) {
                .moved => moved = true,
                .idle => {},
                .eof => {
                    client_open = false;
                    _ = linux.shutdown(vsock_fd, linux.SHUT.WR);
                },
                .failed => failed = true,
            }
        }
        if (!failed and vsock_open and ready(fds[1])) {
            switch (pumpOnce(vsock_fd, client_fd, &buf)) {
                .moved => moved = true,
                .idle => {},
                .eof => {
                    vsock_open = false;
                    _ = linux.shutdown(client_fd, linux.SHUT.WR);
                },
                .failed => failed = true,
            }
        }
        if (failed) break;
        if (moved) idle_ms = 0;
    }
}

/// The `403` a host `DENY` becomes: the reason is body text, and the status
/// can never be a `200` whatever the host said.
fn denyClient(conn_fd: linux.fd_t, reason: []const u8) void {
    const text = std.mem.trim(u8, reason, " \t\r\n");
    var buf: [deny_bytes]u8 = undefined;
    const reply = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}\n",
        .{ text.len + 1, text },
    ) catch {
        _ = writeAll(conn_fd, forbidden);
        return;
    };
    _ = writeAll(conn_fd, reply);
}

/// One client connection, in its own forked child: read the head, work out
/// the destination, open the egress tunnel, then relay until either side ends.
fn serveTcpClient(conn_fd: linux.fd_t) void {
    var buf: [max_head]u8 = undefined;
    const got = readHead(conn_fd, &buf) orelse {
        _ = writeAll(conn_fd, bad_request);
        return;
    };
    const line_end = std.mem.indexOfScalar(u8, got.head, '\n') orelse got.head.len;
    const line = parseRequestLine(got.head[0..line_end]) orelse {
        _ = writeAll(conn_fd, bad_request);
        return;
    };
    const dest = parseDest(line.method, line.target);
    if (dest.kind == .bad) {
        _ = writeAll(conn_fd, bad_request);
        return;
    }
    // A CONNECT whose authority is missing still names its host in `Host:`.
    const host = if (dest.host.len > 0) dest.host else (hostHeader(got.head) orelse "");
    var hs: [handshake_max]u8 = undefined;
    const handshake = handshakeLine(&hs, host, dest.port) orelse {
        _ = writeAll(conn_fd, bad_gateway);
        return;
    };

    var fixed: [max_head]u8 = undefined;
    var fixed_len: usize = 0;
    if (dest.kind == .absolute) {
        const rewritten = std.fmt.bufPrint(&fixed, "{s} {s} {s}\r\n", .{ line.method, dest.origin, line.version }) catch {
            _ = writeAll(conn_fd, bad_request);
            return;
        };
        fixed_len = rewritten.len;
    }

    const egress_fd = connectVsock(egress_port) orelse {
        _ = writeAll(conn_fd, bad_gateway);
        return;
    };
    defer _ = linux.close(egress_fd);
    if (!writeAll(egress_fd, handshake)) {
        _ = writeAll(conn_fd, bad_gateway);
        return;
    }
    var reply_buf: [handshake_max]u8 = undefined;
    const reply = readReplyLine(egress_fd, &reply_buf) orelse {
        _ = writeAll(conn_fd, bad_gateway);
        return;
    };
    if (std.mem.startsWith(u8, reply, "DENY")) {
        denyClient(conn_fd, reply["DENY".len..]);
        return;
    }
    if (!std.mem.startsWith(u8, reply, "OK")) {
        _ = writeAll(conn_fd, bad_gateway);
        return;
    }
    if (dest.kind == .connect) {
        if (!writeAll(conn_fd, established)) return;
    } else {
        // Into the tunnel: the rewritten request line, then the caller's own
        // header lines and the blank line, then any body that arrived with
        // them. The client sees nothing but the server's answer.
        const rest_at = if (line_end < got.head.len) line_end + 1 else got.head.len;
        if (!writeAll(egress_fd, fixed[0..fixed_len]) or
            !writeAll(egress_fd, got.head[rest_at..]) or
            !writeAll(egress_fd, got.buffered[got.head.len..]))
        {
            _ = writeAll(conn_fd, bad_gateway);
            return;
        }
    }
    relay(conn_fd, egress_fd);
}

/// Accept one client and fork it. The parent closes its copy of the accepted
/// fd at once, so only the child owns the connection.
fn acceptAndFork(listen_fd: linux.fd_t) void {
    const rc = linux.accept(listen_fd, null, null);
    if (linux.errno(rc) != .SUCCESS) return;
    const conn_fd: linux.fd_t = @intCast(rc);
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) {
        _ = linux.close(conn_fd);
        return;
    }
    if (fork_rc == 0) {
        _ = linux.close(listen_fd);
        if (listen_udp) |udp| _ = linux.close(udp);
        serveTcpClient(conn_fd);
        _ = linux.close(conn_fd);
        childExit();
    }
    _ = linux.close(conn_fd);
}

/// Reap every child that has finished, without ever waiting on one.
fn reapChildren() void {
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, wno_hang, null);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return;
    }
}

// ─── dns ─────────────────────────────────────────────────────────────────

/// The SERVFAIL answer a failed lookup gets: the query echoed back, QR set,
/// RCODE 2 in the flag byte, and the three record counts at bytes 6..12 zeroed.
fn servfailFrom(query: []const u8, out: []u8) ?[]const u8 {
    if (query.len < dns_header_bytes or query.len > out.len) return null;
    @memcpy(out[0..query.len], query);
    out[2] |= 0x80;
    out[3] = (out[3] & 0xF0) | 0x02;
    @memset(out[6..12], 0);
    return out[0..query.len];
}

/// One query over a fresh vsock stream: a 2-byte big-endian length, the
/// message, and the same framing back — a length of 0 is a refusal.
fn dnsOverVsock(query: []const u8, out: []u8) ?[]const u8 {
    const fd = connectVsock(resolver_port) orelse return null;
    defer _ = linux.close(fd);
    var header: [2]u8 = undefined;
    header[0] = @truncate(query.len >> 8);
    header[1] = @truncate(query.len);
    if (!writeAll(fd, &header) or !writeAll(fd, query)) return null;
    if (!readExact(fd, &header, poll_slice_ms, dns_slices)) return null;
    const len = (@as(usize, header[0]) << 8) | @as(usize, header[1]);
    if (len < dns_header_bytes or len > out.len) return null;
    if (!readExact(fd, out[0..len], poll_slice_ms, dns_slices)) return null;
    return out[0..len];
}

/// One datagram on the resolver socket, answered from the same socket. The
/// exchange is serial in the parent: it is a bounded round trip, and forking
/// per datagram would cost more than it saves.
fn dnsExchange(udp_fd: linux.fd_t) void {
    var query: [dns_query_max]u8 = undefined;
    var peer: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
    var peer_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const rc = linux.recvfrom(udp_fd, &query, query.len, 0, @ptrCast(&peer), &peer_len);
    if (linux.errno(rc) != .SUCCESS) return;
    const got = query[0..rc];
    // Shorter than a DNS header: nothing to answer, nothing to echo.
    if (got.len < dns_header_bytes) return;

    var answer: [dns_reply_max]u8 = undefined;
    const reply = dnsOverVsock(got, &answer) orelse (servfailFrom(got, &answer) orelse return);
    _ = linux.sendto(udp_fd, reply.ptr, reply.len, 0, @ptrCast(&peer), peer_len);
}

// ─── listeners ───────────────────────────────────────────────────────────

pub fn main() void {
    ignoreSigpipe();
    logLine("starting");
    ensureDev();
    logLine(if (bringLoopbackUp()) "lo up" else "MISSING lo up");
    logLine(if (writeResolvConf()) "resolv.conf written" else "MISSING resolv.conf");
    logLine(if (writeProfileScript()) "egress profile written" else "MISSING egress profile");

    listen_tcp = bindLoopbackTcp(proxy_port);
    logLine(if (listen_tcp != null) "proxy listening on 127.0.0.1:3128" else "MISSING proxy listener");
    listen_udp = bindLoopbackUdp(dns_port);
    logLine(if (listen_udp != null) "dns listening on 127.0.0.1:53" else "MISSING dns listener");

    // One loop over both listeners plus a tick, so neither starves the other
    // and children are reaped even when nothing is arriving.
    while (true) {
        var fds = [2]linux.pollfd{
            .{ .fd = listen_tcp orelse -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = listen_udp orelse -1, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, fds.len, tick_ms);
        reapChildren();
        if (linux.errno(rc) != .SUCCESS) continue;
        if (fds[0].fd >= 0 and ready(fds[0])) acceptAndFork(fds[0].fd);
        if (fds[1].fd >= 0 and ready(fds[1])) dnsExchange(fds[1].fd);
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

test "parseIpv4 refuses anything but four strict octets" {
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x00000000), parseIpv4("0.0.0.0"));
    try std.testing.expectEqual(@as(?u32, 0xff000001), parseIpv4("255.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("127.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("127.0.0.01"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("256.0.0.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("1.2.3.4.5"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("1.2.3."));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4("1.2.3.-1"));
    // What the kernel wants in `sockaddr.in.addr`, byte-swapped on the way in.
    try std.testing.expectEqual(@as(u32, 0x0100007f), std.mem.nativeToBig(u32, parseIpv4("127.0.0.1").?));
}

test "parseDest covers CONNECT, absolute form and the rest" {
    const c = parseDest("CONNECT", "example.com:8443");
    try std.testing.expectEqual(DestKind.connect, c.kind);
    try std.testing.expectEqualStrings("example.com", c.host);
    try std.testing.expectEqual(@as(u16, 8443), c.port);
    // A CONNECT with no port is 443, and a bad one is left for the handshake.
    try std.testing.expectEqual(@as(u16, 443), parseDest("CONNECT", "example.com").port);
    try std.testing.expectEqual(@as(u16, 0), parseDest("CONNECT", "example.com:x").port);

    const a = parseDest("GET", "http://example.com/a?b=1");
    try std.testing.expectEqual(DestKind.absolute, a.kind);
    try std.testing.expectEqualStrings("example.com", a.host);
    try std.testing.expectEqual(@as(u16, 80), a.port);
    try std.testing.expectEqualStrings("/a?b=1", a.origin);
    // An authority with nothing after it is the origin-form root.
    const b = parseDest("POST", "http://example.com:8080");
    try std.testing.expectEqual(@as(u16, 8080), b.port);
    try std.testing.expectEqualStrings("/", b.origin);
    try std.testing.expectEqualStrings("?x", parseDest("GET", "http://example.com?x").origin);

    try std.testing.expectEqual(DestKind.bad, parseDest("GET", "/index.html").kind);
    try std.testing.expectEqual(DestKind.bad, parseDest("GET", "http://").kind);
}

test "handshakeLine refuses an unusable host or port" {
    var buf: [handshake_max]u8 = undefined;
    try std.testing.expectEqualStrings("PABRIK-EGRESS/1 example.com 443\n", handshakeLine(&buf, "example.com", 443).?);
    try std.testing.expectEqual(@as(?[]const u8, null), handshakeLine(&buf, "", 443));
    try std.testing.expectEqual(@as(?[]const u8, null), handshakeLine(&buf, "example.com", 0));
    try std.testing.expectEqual(@as(?[]const u8, null), handshakeLine(&buf, "exa mple", 443));
}

test "servfailFrom echoes the query with RCODE 2 and no records" {
    var query: [dns_header_bytes + 4]u8 = undefined;
    const id: u16 = 0x1234;
    query[0] = @truncate(id >> 8);
    query[1] = @truncate(id);
    query[2] = 0x01;
    query[3] = 0x20;
    @memset(query[4..], 0xab);
    var out: [dns_reply_max]u8 = undefined;
    const reply = servfailFrom(&query, &out).?;
    try std.testing.expectEqual(@as(usize, dns_header_bytes + 4), reply.len);
    try std.testing.expectEqual(@as(u8, 0x12), reply[0]);
    try std.testing.expectEqual(@as(u8, 0x34), reply[1]);
    try std.testing.expectEqual(@as(u8, 0x81), reply[2]);
    try std.testing.expectEqual(@as(u8, 0x22), reply[3]);
    for (reply[6..12]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualSlices(u8, query[12..], reply[12..]);
    // Shorter than a DNS header: there is nothing to echo.
    try std.testing.expectEqual(@as(?[]const u8, null), servfailFrom(query[0..4], &out));
}

test "headEnd finds either blank line without eating a body" {
    try std.testing.expectEqual(@as(?usize, 5), headEnd("a\r\n\r\nbody"));
    try std.testing.expectEqual(@as(?usize, 3), headEnd("a\n\nbody"));
    try std.testing.expectEqual(@as(?usize, null), headEnd("a\r\n"));
    // A body that opens with a newline is body, not a second terminator.
    try std.testing.expectEqual(@as(?usize, 5), headEnd("a\r\n\r\n\n"));
}
