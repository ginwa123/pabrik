//! The host's half of the VM's network: the two listeners a workspace's guest
//! forwarder dials (`<vsock.sock>_5001` egress, `_5002` DNS), its allowlist and
//! an audit log. The address classified is the address dialled.

const std = @import("std");
const linux = std.os.linux;
const egress = @import("egress.zig");
const vm_client = @import("vm_client.zig");

pub const egress_port: u32 = 5001;
pub const resolver_port: u32 = 5002;
pub const handshake_prefix = "PABRIK-EGRESS/1 ";
pub const max_handshake_bytes: usize = 512;
pub const max_query_bytes: usize = 1200;
pub const allow_file = "egress.allow";
pub const log_file = "egress.log";
pub const max_config_bytes: usize = 64 * 1024;

/// A workspace with no allowlist file may still fetch packages.
const default_ports = [_]u16{ 80, 443 };

const max_name_labels = 128;
const max_answers = 64;
const connect_timeout_ms: i32 = 10_000;
const dns_timeout_ms: i32 = 5_000;
const relay_slice_ms: i32 = 5_000;
const relay_idle_ms: u32 = 120_000;
const relay_chunk: usize = 64 * 1024;
/// A guest that opens a connection and says nothing holds a thread, so the
/// handshake gets 3 s. `max_connections` is the host-wide admission ceiling:
/// past it a new connection is closed instead of costing a thread.
const handshake_slices: u32 = 3;
const max_connections = 128;
const max_audit_bytes: i64 = 8 * 1024 * 1024;
const max_listeners = 64;
const max_path_bytes = 200;
const unix_af: u32 = 1;
const inet_af: u32 = 2;
const inet6_af: u32 = 10;
const sock_stream: u32 = 1;
const sock_dgram: u32 = 2;
const listen_backlog: u32 = 16;
const dns_port: u16 = 53;

pub const Config = struct {
    /// The host's own TCP ports. A workspace may not dial one, whatever
    /// address carries it.
    host_listeners: []const u16 = &.{8081},
    /// Where a guest query is forwarded. Empty means this host's
    /// `/etc/resolv.conf`, read once.
    nameservers: []const [4]u8 = &.{},
};

// ─── the allowlist ──────────────────────────────────────────────────────

pub const Allowlist = struct {
    entries: []const Entry = &.{},
    /// The rule when no file exists: the web ports, any public host.
    default_web: bool = true,

    pub const Entry = struct {
        pattern: []const u8,
        port: u16,
        any_port: bool,
    };

    pub const ParseError = error{ InvalidAllowEntry, OutOfMemory };

    /// One rule per line: `<host-or-pattern> <port|any>`, with `#` comments.
    /// Patterns are copied, so the text they were parsed from is the caller's
    /// to free.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Allowlist {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.pattern);
            entries.deinit(allocator);
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const raw_pattern = words.next() orelse return error.InvalidAllowEntry;
            const port_text = words.next() orelse return error.InvalidAllowEntry;
            if (words.next() != null) return error.InvalidAllowEntry;
            if (!validPattern(raw_pattern)) return error.InvalidAllowEntry;
            const pattern = try allocator.dupe(u8, raw_pattern);
            errdefer allocator.free(pattern);
            var entry = Entry{ .pattern = pattern, .port = 0, .any_port = false };
            if (std.mem.eql(u8, port_text, "any")) {
                entry.any_port = true;
            } else {
                entry.port = parsePort(port_text) orelse return error.InvalidAllowEntry;
            }
            try entries.append(allocator, entry);
        }
        return .{ .entries = try entries.toOwnedSlice(allocator), .default_web = false };
    }

    /// The rule a workspace that has no allowlist file gets.
    pub fn web() Allowlist {
        return .{ .entries = &.{}, .default_web = true };
    }

    pub fn deinit(self: Allowlist, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.pattern);
        allocator.free(self.entries);
    }

    pub fn allows(self: Allowlist, host: []const u8, port: u16) bool {
        if (self.default_web and portIn(&default_ports, port)) return true;
        for (self.entries) |entry| {
            if (!hostMatches(entry.pattern, host)) continue;
            if (entry.any_port or entry.port == port) return true;
        }
        return false;
    }
};

fn validPattern(pattern: []const u8) bool {
    if (pattern.len == 0 or pattern.len > 253) return false;
    for (pattern) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '*';
        if (!ok) return false;
    }
    return true;
}

/// `*` is any host; `*.example.com` is `example.com` or a host under it; a
/// bare name is that name.
fn hostMatches(pattern: []const u8, host: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.startsWith(u8, pattern, "*.")) {
        const suffix = pattern[2..];
        if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
        if (host.len <= suffix.len + 1) return false;
        if (host[host.len - suffix.len - 1] != '.') return false;
        return std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix);
    }
    return std.ascii.eqlIgnoreCase(pattern, host);
}

fn portIn(ports: []const u16, port: u16) bool {
    for (ports) |candidate| {
        if (candidate == port) return true;
    }
    return false;
}

fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = value * 10 + (c - '0');
    }
    if (value == 0 or value > 65535) return null;
    return @intCast(value);
}

/// `PABRIK_EGRESS_DENY_PORTS=8081,5432`: the ports no workspace may dial.
pub fn parsePortList(allocator: std.mem.Allocator, text: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    var parts = std.mem.tokenizeAny(u8, text, ", ");
    while (parts.next()) |part| {
        const port = parsePort(part) orelse return error.InvalidPortList;
        try out.append(allocator, port);
    }
    return out.toOwnedSlice(allocator);
}

/// The `nameserver` lines of a resolv.conf, in order.
pub fn parseNameservers(allocator: std.mem.Allocator, text: []const u8) ![]const [4]u8 {
    var out: std.ArrayList([4]u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var words = std.mem.tokenizeAny(u8, raw, " \t\r");
        const key = words.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const value = words.next() orelse continue;
        const addr = egress.parseV4(value) orelse continue;
        try out.append(allocator, addr);
        if (out.items.len == 3) break;
    }
    return out.toOwnedSlice(allocator);
}

// ─── the decision ───────────────────────────────────────────────────────

pub const Dial = struct {
    host: []const u8,
    port: u16,
};

/// The one line a guest forwarder sends before any payload, or null when the
/// line is not one.
pub fn parseHandshake(line: []const u8) ?Dial {
    if (!std.mem.startsWith(u8, line, handshake_prefix)) return null;
    const rest = std.mem.trim(u8, line[handshake_prefix.len..], " \t\r\n");
    var words = std.mem.tokenizeAny(u8, rest, " \t");
    const host = words.next() orelse return null;
    const port_text = words.next() orelse return null;
    if (words.next() != null) return null;
    if (host.len == 0 or host.len > 253) return null;
    for (host) |c| {
        if (c <= ' ' or c >= 0x7f) return null;
    }
    return .{ .host = host, .port = parsePort(port_text) orelse return null };
}

/// What the host can refuse before it resolves anything: a port this host
/// listens on, an address that is not public, or a host the allowlist does
/// not name.
pub fn destinationRefusal(
    host: []const u8,
    port: u16,
    allow: Allowlist,
    listeners: []const u16,
) ?egress.Refusal {
    if (egress.hostListenerDenied(port, listeners)) {
        return .{ .verdict = .loopback, .reason = "host listener" };
    }
    if (egress.classifyText(host)) |verdict| {
        if (verdict.denied()) return .{ .verdict = verdict, .reason = verdict.name() };
    } else if (!egress.queryNameValid(host)) {
        return .{ .verdict = .reserved, .reason = "not a name and not an address" };
    }
    if (!allow.allows(host, port)) {
        return .{ .verdict = .reserved, .reason = "not declared" };
    }
    return null;
}

/// The second half of resolve-then-connect: the address about to be dialled,
/// classified again.
pub fn answerRefusal(addr_text: []const u8) ?egress.Refusal {
    return egress.decide(addr_text, 0, &.{});
}

// ─── DNS: the codec, and the policy over it ─────────────────────────────

pub const Answer = struct {
    v6: bool,
    addr: [16]u8,

    pub fn text(self: Answer, buf: []u8) []const u8 {
        if (self.v6) {
            return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:" ++
                "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
                self.addr[0],  self.addr[1],  self.addr[2],  self.addr[3],
                self.addr[4],  self.addr[5],  self.addr[6],  self.addr[7],
                self.addr[8],  self.addr[9],  self.addr[10], self.addr[11],
                self.addr[12], self.addr[13], self.addr[14], self.addr[15],
            }) catch "::";
        }
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            self.addr[12], self.addr[13], self.addr[14], self.addr[15],
        }) catch "0.0.0.0";
    }
};

/// The query's own shape: one question, a standard query, and a name the
/// resolver policy accepts. Labels are expanded into `out`, because the wire
/// form is length prefixed. Anything else is refused rather than relayed.
pub fn queryName(query: []const u8, out: []u8) ?[]const u8 {
    if (query.len < 12) return null;
    if (query[2] & 0x80 != 0) return null;
    if (query[2] & 0x78 != 0) return null;
    const qdcount = (@as(u32, query[4]) << 8) | query[5];
    if (qdcount != 1) return null;
    var at: usize = 12;
    var written: usize = 0;
    var labels: usize = 0;
    while (at < query.len) {
        const len = query[at];
        if (len == 0) {
            if (labels < 2) return null;
            const name = out[0..written];
            if (!egress.queryNameValid(name)) return null;
            return name;
        }
        if (len & 0xc0 != 0) return null;
        at += 1;
        if (at + len > query.len) return null;
        if (written > 0) {
            if (written == out.len) return null;
            out[written] = '.';
            written += 1;
        }
        if (written + len > out.len) return null;
        @memcpy(out[written .. written + len], query[at .. at + len]);
        written += len;
        at += len;
        labels += 1;
        if (labels > max_name_labels) return null;
    }
    return null;
}

/// The A/AAAA answers of a response, up to `max_answers` of them. Names are
/// skipped through compression pointers, so a CNAME in front of the addresses
/// still walks.
pub fn answerAddresses(allocator: std.mem.Allocator, reply: []const u8) ![]Answer {
    var out: std.ArrayList(Answer) = .empty;
    errdefer out.deinit(allocator);
    if (reply.len < 12) return out.toOwnedSlice(allocator);
    if (reply[2] & 0x80 == 0) return out.toOwnedSlice(allocator);
    var at: usize = 12;
    const qdcount = (@as(u32, reply[4]) << 8) | reply[5];
    var q: u32 = 0;
    while (q < qdcount) : (q += 1) {
        at = skipName(reply, at) orelse return out.toOwnedSlice(allocator);
        at += 4;
        if (at > reply.len) return out.toOwnedSlice(allocator);
    }
    const ancount = (@as(u32, reply[6]) << 8) | reply[7];
    var i: u32 = 0;
    while (i < ancount and out.items.len < max_answers) : (i += 1) {
        at = skipName(reply, at) orelse break;
        if (at + 10 > reply.len) break;
        const rtype = (@as(u16, reply[at]) << 8) | reply[at + 1];
        const rdlen = (@as(u32, reply[at + 8]) << 8) | reply[at + 9];
        const rd = at + 10;
        if (rd + rdlen > reply.len) break;
        if (rtype == 1 and rdlen == 4) {
            var addr = [_]u8{0} ** 16;
            addr[10] = 0xff;
            addr[11] = 0xff;
            @memcpy(addr[12..16], reply[rd .. rd + 4]);
            try out.append(allocator, .{ .v6 = false, .addr = addr });
        } else if (rtype == 28 and rdlen == 16) {
            var addr = [_]u8{0} ** 16;
            @memcpy(addr[0..16], reply[rd .. rd + 16]);
            try out.append(allocator, .{ .v6 = true, .addr = addr });
        }
        at = rd + rdlen;
    }
    return out.toOwnedSlice(allocator);
}

fn skipName(buf: []const u8, start: usize) ?usize {
    var at = start;
    while (at < buf.len) {
        const len = buf[at];
        if (len & 0xc0 == 0xc0) {
            if (at + 2 > buf.len) return null;
            return at + 2;
        }
        if (len == 0) return at + 1;
        at += 1 + len;
    }
    return null;
}

/// The first address in a response the proxy would refuse to dial, written
/// into `out`, or null when every answer is public. This is what stops a
/// rebinding name from being a way around the proxy.
pub fn deniedAnswer(reply: []const u8, out: []u8, scratch: []Answer) ?[]const u8 {
    const parsed = answerAddresses(std.heap.page_allocator, reply) catch return "unreadable answer";
    defer std.heap.page_allocator.free(parsed);
    _ = scratch;
    for (parsed) |answer| {
        const text = answer.text(out);
        if (egress.answerDenied(text)) return text;
    }
    return null;
}

/// A response carrying more records than the policy walk covers is refused
/// whole: the walk stops at `max_answers`, so anything past it would be handed
/// to the guest unchecked.
pub fn answerCountOverCap(reply: []const u8) bool {
    if (reply.len < 12) return true;
    const ancount = (@as(u32, reply[6]) << 8) | reply[7];
    return ancount > max_answers;
}

/// A response whose ID does not match the query, or that is not a response,
/// is stale or poisoned and is dropped rather than forwarded.
pub fn responseBelongsTo(reply: []const u8, query: []const u8) bool {
    if (reply.len < 12 or query.len < 2) return false;
    if (reply[2] & 0x80 == 0) return false;
    return reply[0] == query[0] and reply[1] == query[1];
}

pub fn responseWithinCap(len: usize) bool {
    return len >= 12 and len <= egress.resolver_response_cap;
}

pub fn buildQuery(buf: []u8, id: u16, name: []const u8, qtype: u16) ?[]const u8 {
    if (buf.len < 12 + name.len + 6) return null;
    @memset(buf[0..12], 0);
    buf[0] = @truncate(id >> 8);
    buf[1] = @truncate(id);
    buf[2] = 0x01;
    buf[5] = 1;
    var at: usize = 12;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or at + 1 + label.len > buf.len) return null;
        buf[at] = @intCast(label.len);
        at += 1;
        @memcpy(buf[at .. at + label.len], label);
        at += label.len;
    }
    buf[at] = 0;
    at += 1;
    buf[at] = @truncate(qtype >> 8);
    buf[at + 1] = @truncate(qtype);
    buf[at + 2] = 0;
    buf[at + 3] = 1;
    return buf[0 .. at + 4];
}

// ─── the audit log ──────────────────────────────────────────────────────

/// One append-only line per dial or query. `ts` is an argument, so the line
/// is a function of its inputs and not of the clock.
pub fn auditLine(
    allocator: std.mem.Allocator,
    ts: i64,
    workspace: []const u8,
    dial: Dial,
    outcome: []const u8,
    addr: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "ts={d} workspace={s} host={s} port={d} outcome={s} addr={s}\n",
        .{ ts, workspace, dial.host, dial.port, outcome, addr },
    );
}

pub fn auditDnsLine(
    allocator: std.mem.Allocator,
    ts: i64,
    workspace: []const u8,
    name: []const u8,
    outcome: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "ts={d} workspace={s} dns={s} outcome={s}\n",
        .{ ts, workspace, name, outcome },
    );
}

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(linux.CLOCK.REALTIME, &ts)) != .SUCCESS) return 0;
    return @intCast(ts.sec);
}

// ─── the listeners ──────────────────────────────────────────────────────

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

const Listener = struct {
    allocator: std.mem.Allocator,
    fd: linux.fd_t,
    dir: []u8,
    workspace: []u8,
    sock_path: []u8,
    is_dns: bool,
    host_listeners: []const u16,
    nameservers: []const [4]u8,
};

/// The workspace's own name, taken from the directory this listener was
/// created for: nothing a guest sends can choose which allowlist applies.
pub fn workspaceOf(dir: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, dir, "/");
    const at = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[at + 1 ..];
}

/// Which listeners are already bound, and by which fd, so a workspace rebinds
/// after a restart instead of keeping the socket a dead VM left behind.
var registry = struct {
    lock: std.atomic.Mutex = .unlocked,
    count: usize = 0,
    keys: [max_listeners][max_path_bytes]u8 = undefined,
    lens: [max_listeners]usize = [_]usize{0} ** max_listeners,
    fds: [max_listeners]linux.fd_t = [_]linux.fd_t{-1} ** max_listeners,

    fn lockIt(self: *@This()) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn find(self: *@This(), key: []const u8) ?usize {
        for (self.lens[0..self.count], 0..) |len, i| {
            if (std.mem.eql(u8, self.keys[i][0..len], key)) return i;
        }
        return null;
    }

    fn add(self: *@This(), key: []const u8, fd: linux.fd_t) void {
        if (self.count == max_listeners or key.len > max_path_bytes) return;
        @memcpy(self.keys[self.count][0..key.len], key);
        self.lens[self.count] = key.len;
        self.fds[self.count] = fd;
        self.count += 1;
    }

    fn drop(self: *@This(), at: usize) void {
        const last = self.count - 1;
        self.keys[at] = self.keys[last];
        self.lens[at] = self.lens[last];
        self.fds[at] = self.fds[last];
        self.count = last;
    }
}{};

/// Bind the two guest-initiated sockets for a workspace, once. Safe to call on
/// every dispatch, so the listeners exist before the guest's first dial.
pub fn ensure(allocator: std.mem.Allocator, layout: vm_client.Layout, host_listeners: []const u16) void {
    for ([_]u32{ egress_port, resolver_port }) |port| {
        var key_buf: [max_path_bytes]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}_{d}", .{ layout.vsock_sock, port }) catch continue;
        registry.lockIt();
        const known = registry.find(key) != null;
        const room = registry.count < max_listeners;
        registry.lock.unlock();
        if (known) continue;
        // Never unlink a socket a live listener owns: with no slot left, the
        // workspace keeps what it has and says so rather than rebinding.
        if (!room) {
            log("egress: no listener slot left for {s}", .{key});
            continue;
        }
        if (bindListener(allocator, layout, key, port == resolver_port, host_listeners)) |listener| {
            const thread = std.Thread.spawn(.{}, acceptLoop, .{listener}) catch {
                _ = linux.close(listener.fd);
                continue;
            };
            thread.detach();
            log("egress: workspace {s} listens on {s}", .{ listener.workspace, key });
        }
    }
}

fn bindListener(
    allocator: std.mem.Allocator,
    layout: vm_client.Layout,
    key: []const u8,
    is_dns: bool,
    host_listeners: []const u16,
) ?*Listener {
    var path_buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(key, &path_buf) orelse return null;
    _ = linux.unlink(path_z);
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..key.len], key);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    if (linux.errno(linux.listen(fd, listen_backlog)) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    const listener = allocator.create(Listener) catch {
        _ = linux.close(fd);
        return null;
    };
    listener.* = .{
        .allocator = allocator,
        .fd = fd,
        .dir = allocator.dupe(u8, layout.dir) catch {
            allocator.destroy(listener);
            _ = linux.close(fd);
            return null;
        },
        .workspace = undefined,
        .sock_path = undefined,
        .is_dns = is_dns,
        .host_listeners = host_listeners,
        .nameservers = nameservers(allocator),
    };
    listener.workspace = allocator.dupe(u8, workspaceOf(layout.dir)) catch listener.dir;
    listener.sock_path = allocator.dupe(u8, key) catch listener.dir;
    registry.lockIt();
    registry.add(key, fd);
    registry.lock.unlock();
    return listener;
}

/// Close and unlink a workspace's listeners, so the next boot rebinds them
/// instead of leaving a socket the guest's dial would land on forever.
pub fn release(layout: vm_client.Layout) void {
    for ([_]u32{ egress_port, resolver_port }) |port| {
        var key_buf: [max_path_bytes]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}_{d}", .{ layout.vsock_sock, port }) catch continue;
        registry.lockIt();
        if (registry.find(key)) |at| {
            const fd = registry.fds[at];
            registry.drop(at);
            registry.lock.unlock();
            _ = linux.close(fd);
        } else {
            registry.lock.unlock();
        }
        var zbuf: [max_path_bytes]u8 = undefined;
        if (cstr(key, &zbuf)) |path_z| _ = linux.unlink(path_z);
    }
}

var live_connections = std.atomic.Value(u32).init(0);

fn acceptLoop(listener: *Listener) void {
    while (true) {
        const rc = linux.accept4(listener.fd, null, null, linux.SOCK.CLOEXEC);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) {
            if (err == .BADF or err == .INVAL or err == .NOTSOCK) return;
            continue;
        }
        const conn: linux.fd_t = @intCast(rc);
        // Admission before a thread: a guest in a loop must not be able to
        // spend the daemon's threads and fds on connections it never uses.
        if (live_connections.fetchAdd(1, .seq_cst) >= max_connections) {
            _ = live_connections.fetchSub(1, .seq_cst);
            _ = linux.close(conn);
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleConnection, .{ listener, conn }) catch {
            _ = live_connections.fetchSub(1, .seq_cst);
            _ = linux.close(conn);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(listener: *Listener, conn: linux.fd_t) void {
    defer _ = live_connections.fetchSub(1, .seq_cst);
    defer _ = linux.close(conn);
    if (listener.is_dns) {
        dnsConnection(listener, conn);
    } else {
        egressConnection(listener, conn);
    }
}

// ─── the egress tunnel ──────────────────────────────────────────────────

fn egressConnection(listener: *Listener, conn: linux.fd_t) void {
    var line_buf: [max_handshake_bytes]u8 = undefined;
    const line = readLine(conn, &line_buf) orelse {
        denyLine(conn, "no handshake");
        return;
    };
    const dial = parseHandshake(line) orelse {
        auditDial(listener, .{ .host = "", .port = 0 }, "malformed handshake", "-");
        denyLine(conn, "malformed handshake");
        return;
    };
    const allow = loadAllowlist(listener);
    defer allow.deinit(listener.allocator);
    if (destinationRefusal(dial.host, dial.port, allow, listener.host_listeners)) |refusal| {
        auditDial(listener, dial, refusal.reason, "-");
        denyLine(conn, refusal.reason);
        return;
    }
    var addr_buf: [64]u8 = undefined;
    const remote = dialResolved(listener, dial, &addr_buf) orelse {
        auditDial(listener, dial, "unreachable", "-");
        denyLine(conn, "unreachable");
        return;
    };
    defer _ = linux.close(remote);
    auditDial(listener, dial, "allowed", addr_buf[0..]);
    _ = writeAll(conn, "OK\n");
    relay(conn, remote);
}

/// Resolve the name, check every answer, then dial the literal that was
/// checked. A name that is already an address skips the resolution.
fn dialResolved(listener: *Listener, dial: Dial, addr_buf: []u8) ?linux.fd_t {
    if (egress.classifyText(dial.host) != null) {
        if (dial.host.len > addr_buf.len) return null;
        @memcpy(addr_buf[0..dial.host.len], dial.host);
        return dialIp(dial.host, dial.port);
    }
    for (listener.nameservers) |ns| {
        var query_buf: [512]u8 = undefined;
        const query = buildQuery(&query_buf, 0x4242, dial.host, 1) orelse continue;
        var reply_buf: [egress.resolver_response_cap]u8 = undefined;
        const reply = udpQuery(ns, query, &reply_buf) orelse continue;
        if (!responseBelongsTo(reply, query)) continue;
        const answers = answerAddresses(listener.allocator, reply) catch continue;
        defer listener.allocator.free(answers);
        if (answers.len == 0) continue;
        for (answers) |answer| {
            const text = answer.text(addr_buf);
            if (answerRefusal(text) != null) {
                auditDial(listener, dial, "answer denied", text);
                return null;
            }
        }
        const text = answers[0].text(addr_buf);
        if (dialIp(text, dial.port)) |fd| return fd;
    }
    return null;
}

fn dialIp(addr_text: []const u8, port: u16) ?linux.fd_t {
    var storage: SockaddrStorage = undefined;
    const sockaddr = sockaddrFor(addr_text, port, &storage) orelse return null;
    const rc = linux.socket(sockaddr.family, sock_stream | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    const err = linux.errno(linux.connect(fd, sockaddr.ptr, sockaddr.len));
    if (err == .SUCCESS) return fd;
    if (err != .INPROGRESS and err != .AGAIN) return null;
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
    const ready_rc = linux.poll(&fds, 1, connect_timeout_ms);
    if (linux.errno(ready_rc) != .SUCCESS or ready_rc == 0) return null;
    var so_error: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    const opt_rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &len);
    if (linux.errno(opt_rc) != .SUCCESS or so_error != 0) return null;
    return fd;
}

const SockaddrStorage = extern union {
    in: linux.sockaddr.in,
    in6: linux.sockaddr.in6,
};

const Sockaddr = struct {
    ptr: *const linux.sockaddr,
    len: linux.socklen_t,
    family: u32,
};

fn sockaddrFor(text: []const u8, port: u16, storage: *SockaddrStorage) ?Sockaddr {
    if (egress.parseV4(text)) |octets| {
        storage.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(octets),
        };
        return .{
            .ptr = @ptrCast(&storage.in),
            .len = @sizeOf(linux.sockaddr.in),
            .family = inet_af,
        };
    }
    const parsed = std.Io.net.IpAddress.parseIp6(text, port) catch return null;
    storage.in6 = .{
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = parsed.ip6.bytes,
        .scope_id = 0,
    };
    return .{
        .ptr = @ptrCast(&storage.in6),
        .len = @sizeOf(linux.sockaddr.in6),
        .family = inet6_af,
    };
}

// ─── the resolver ───────────────────────────────────────────────────────

fn dnsConnection(listener: *Listener, conn: linux.fd_t) void {
    var len_buf: [2]u8 = undefined;
    if (!readExact(conn, &len_buf, dns_timeout_ms)) return;
    const want = (@as(usize, len_buf[0]) << 8) | len_buf[1];
    if (want < 12 or want > max_query_bytes) {
        refuseFrame(conn);
        return;
    }
    var query_buf: [max_query_bytes]u8 = undefined;
    if (!readExact(conn, query_buf[0..want], dns_timeout_ms)) return;
    const query = query_buf[0..want];
    var name_buf: [256]u8 = undefined;
    const name = queryName(query, &name_buf) orelse {
        auditDns(listener, "-", "query refused");
        refuseFrame(conn);
        return;
    };
    var reply_buf: [egress.resolver_response_cap]u8 = undefined;
    const reply = forwardQuery(listener, query, &reply_buf) orelse {
        auditDns(listener, name, "no answer");
        refuseFrame(conn);
        return;
    };
    if (!responseBelongsTo(reply, query) or !responseWithinCap(reply.len)) {
        auditDns(listener, name, "bad answer frame");
        refuseFrame(conn);
        return;
    }
    if (answerCountOverCap(reply)) {
        auditDns(listener, name, "more answers than the policy walk");
        refuseFrame(conn);
        return;
    }
    var answer_buf: [64]u8 = undefined;
    var scratch: [max_answers]Answer = undefined;
    if (deniedAnswer(reply, &answer_buf, &scratch)) |denied| {
        auditDns(listener, name, denied);
        refuseFrame(conn);
        return;
    }
    auditDns(listener, name, "answered");
    var out: [2]u8 = undefined;
    out[0] = @truncate(reply.len >> 8);
    out[1] = @truncate(reply.len);
    _ = writeAll(conn, &out);
    _ = writeAll(conn, reply);
}

fn forwardQuery(listener: *Listener, query: []const u8, out: []u8) ?[]const u8 {
    for (listener.nameservers) |ns| {
        if (udpQuery(ns, query, out)) |reply| return reply;
    }
    return null;
}

/// A length of zero is the refusal: the guest's resolver answers SERVFAIL for
/// its own client, so a denied name is a failed lookup and not a silence.
fn refuseFrame(conn: linux.fd_t) void {
    _ = writeAll(conn, &[_]u8{ 0, 0 });
}

fn auditDial(listener: *Listener, dial: Dial, outcome: []const u8, addr: []const u8) void {
    const line = auditLine(listener.allocator, nowSeconds(), listener.workspace, dial, outcome, addr) catch return;
    defer listener.allocator.free(line);
    audit(listener.allocator, listener.dir, line);
}

fn auditDns(listener: *Listener, name: []const u8, outcome: []const u8) void {
    const line = auditDnsLine(listener.allocator, nowSeconds(), listener.workspace, name, outcome) catch return;
    defer listener.allocator.free(line);
    audit(listener.allocator, listener.dir, line);
}

fn audit(allocator: std.mem.Allocator, dir: []const u8, line: []const u8) void {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, log_file }) catch return;
    defer allocator.free(path);
    var buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(path, &buf) orelse return;
    const rc = linux.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    // A guest in a retry loop must not fill its own disk image with the log.
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(size) == .SUCCESS and @as(i64, @intCast(size)) >= max_audit_bytes) return;
    _ = writeAll(fd, line);
}

// ─── sockets, files ─────────────────────────────────────────────────────

fn udpQuery(ns: [4]u8, query: []const u8, out: []u8) ?[]const u8 {
    const rc = linux.socket(inet_af, sock_dgram | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, dns_port),
        .addr = @bitCast(ns),
    };
    var tv = linux.timeval{ .sec = 0, .usec = 0 };
    tv.sec = @intCast(@divTrunc(dns_timeout_ms, 1000));
    tv.usec = @intCast(@mod(dns_timeout_ms, 1000) * 1000);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    const sent = linux.sendto(fd, query.ptr, query.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    if (linux.errno(sent) != .SUCCESS) return null;
    const got = linux.recvfrom(fd, out.ptr, out.len, 0, null, null);
    if (linux.errno(got) != .SUCCESS or got < 12) return null;
    return out[0..got];
}

fn relay(a: linux.fd_t, b: linux.fd_t) void {
    var buf: [relay_chunk]u8 = undefined;
    var a_open = true;
    var b_open = true;
    var idle_ms: u32 = 0;
    while (a_open or b_open) {
        var fds = [2]linux.pollfd{
            .{ .fd = if (a_open) a else -1, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (b_open) b else -1, .events = linux.POLL.IN, .revents = 0 },
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
        if (a_open and ready(fds[0])) {
            switch (pumpOnce(a, b, &buf)) {
                .moved => moved = true,
                .idle => {},
                .eof => {
                    a_open = false;
                    _ = linux.shutdown(b, linux.SHUT.WR);
                },
                .failed => failed = true,
            }
        }
        if (!failed and b_open and ready(fds[1])) {
            switch (pumpOnce(b, a, &buf)) {
                .moved => moved = true,
                .idle => {},
                .eof => {
                    b_open = false;
                    _ = linux.shutdown(a, linux.SHUT.WR);
                },
                .failed => failed = true,
            }
        }
        if (failed) break;
        if (moved) idle_ms = 0;
    }
}

const Pump = enum { moved, idle, eof, failed };

fn ready(pfd: linux.pollfd) bool {
    return pfd.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0;
}

fn pumpOnce(src: linux.fd_t, dst: linux.fd_t, buf: []u8) Pump {
    const n = linux.read(src, buf.ptr, buf.len);
    const err = linux.errno(n);
    if (err == .INTR or err == .AGAIN) return .idle;
    if (err != .SUCCESS or n == 0) return .eof;
    var off: usize = 0;
    while (off < n) {
        const w = linux.write(dst, buf.ptr + off, n - off);
        if (linux.errno(w) != .SUCCESS or w == 0) return .failed;
        off += w;
    }
    return .moved;
}

fn readLine(fd: linux.fd_t, buf: []u8) ?[]const u8 {
    var have: usize = 0;
    var left: u32 = handshake_slices;
    while (left > 0) {
        if (have == buf.len) return null;
        const n = readSome(fd, buf[have..], 1000) orelse {
            left -= 1;
            continue;
        };
        have += n;
        if (std.mem.indexOfScalar(u8, buf[0..have], '\n')) |end| {
            return std.mem.trim(u8, buf[0..end], "\r");
        }
    }
    return null;
}

fn readExact(fd: linux.fd_t, buf: []u8, timeout_ms: i32) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = readSome(fd, buf[off..], timeout_ms) orelse return false;
        off += n;
    }
    return true;
}

fn readSome(fd: linux.fd_t, buf: []u8, timeout_ms: i32) ?usize {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&fds, 1, timeout_ms);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return null;
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return n;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
        off += rc;
    }
    return true;
}

fn denyLine(conn: linux.fd_t, reason: []const u8) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "DENY {s}\n", .{reason}) catch {
        _ = writeAll(conn, "DENY refused\n");
        return;
    };
    _ = writeAll(conn, line);
}

fn cstr(src: []const u8, dst: []u8) ?[*:0]const u8 {
    if (src.len + 1 > dst.len) return null;
    @memcpy(dst[0..src.len], src);
    dst[src.len] = 0;
    return @ptrCast(dst.ptr);
}

/// Read a whole file, up to `cap` bytes. Null when it is absent or longer than
/// the cap, which the callers all treat as "use the default".
pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    var buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(path, &buf) orelse return null;
    const rc = linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (out.items.len <= cap) {
        const n = linux.read(fd, &chunk, chunk.len);
        const err = linux.errno(n);
        if (err == .INTR) continue;
        if (err != .SUCCESS or n == 0) break;
        out.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    if (out.items.len > cap) {
        out.deinit(allocator);
        return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn loadAllowlist(listener: *Listener) Allowlist {
    const path = std.fmt.allocPrint(listener.allocator, "{s}/{s}", .{ listener.dir, allow_file }) catch return Allowlist.web();
    defer listener.allocator.free(path);
    const text = readFileAlloc(listener.allocator, path, max_config_bytes) orelse return Allowlist.web();
    defer listener.allocator.free(text);
    return Allowlist.parse(listener.allocator, text) catch {
        log("egress: {s} is not readable as rules; refusing every dial", .{path});
        return .{ .entries = &.{}, .default_web = false };
    };
}

/// One public resolver, for a host whose own configuration names none. Static,
/// because a listener outlives the call that built it.
const fallback_nameservers = [_][4]u8{.{ 1, 1, 1, 1 }};

var loaded_nameservers: ?[]const [4]u8 = null;

fn nameservers(allocator: std.mem.Allocator) []const [4]u8 {
    if (loaded_nameservers) |found| return found;
    if (readFileAlloc(allocator, "/etc/resolv.conf", max_config_bytes)) |text| {
        defer allocator.free(text);
        const parsed = parseNameservers(allocator, text) catch &.{};
        if (parsed.len > 0) {
            loaded_nameservers = parsed;
            return parsed;
        }
    }
    loaded_nameservers = &fallback_nameservers;
    return &fallback_nameservers;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

const testing = std.testing;

const ResponseBuilder = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *ResponseBuilder, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn header(self: *ResponseBuilder, id: u16, flags: u8, qd: u16, an: u16) void {
        var h = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        h[0] = @truncate(id >> 8);
        h[1] = @truncate(id);
        h[2] = flags;
        h[4] = @truncate(qd >> 8);
        h[5] = @truncate(qd);
        h[6] = @truncate(an >> 8);
        h[7] = @truncate(an);
        self.push(&h);
    }

    fn question(self: *ResponseBuilder, name: []const u8) void {
        var labels = std.mem.splitScalar(u8, name, '.');
        while (labels.next()) |label| {
            self.push(&[_]u8{@intCast(label.len)});
            self.push(label);
        }
        self.push(&[_]u8{ 0, 0, 1, 0, 1 });
    }

    fn answerA(self: *ResponseBuilder, ip: [4]u8) void {
        self.push(&[_]u8{ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4 });
        self.push(&ip);
    }

    fn answerAAAA(self: *ResponseBuilder, ip: [16]u8) void {
        self.push(&[_]u8{ 0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16 });
        self.push(&ip);
    }

    fn text(self: *ResponseBuilder) []const u8 {
        return self.buf[0..self.len];
    }
};

test "a dial to a port this host listens on is refused whatever address carries it" {
    const listeners = [_]u16{ 8081, 3000 };
    const allow = Allowlist.web();
    const refusal = destinationRefusal("93.184.216.34", 8081, allow, &listeners).?;
    try testing.expectEqualStrings("host listener", refusal.reason);
    try testing.expect(destinationRefusal("93.184.216.34", 3000, allow, &listeners) != null);
    try testing.expect(destinationRefusal("93.184.216.34", 443, allow, &listeners) == null);
}

test "a dial to an address inside the host is refused, in either family" {
    const listeners = [_]u16{8081};
    const allow = Allowlist.web();
    try testing.expectEqual(
        egress.Verdict.loopback,
        destinationRefusal("127.0.0.1", 443, allow, &listeners).?.verdict,
    );
    try testing.expectEqual(
        egress.Verdict.loopback,
        destinationRefusal("::ffff:127.0.0.1", 443, allow, &listeners).?.verdict,
    );
    try testing.expectEqual(
        egress.Verdict.private,
        destinationRefusal("10.0.0.5", 443, allow, &listeners).?.verdict,
    );
    try testing.expectEqual(
        egress.Verdict.metadata,
        destinationRefusal("169.254.169.254", 80, allow, &listeners).?.verdict,
    );
}

test "the default allowlist admits the web ports and nothing else" {
    const allow = Allowlist.web();
    try testing.expect(allow.allows("registry.npmjs.org", 443));
    try testing.expect(allow.allows("example.com", 80));
    try testing.expect(!allow.allows("example.com", 22));
    try testing.expect(!allow.allows("example.com", 0));
}

test "a declared rule admits its pattern and its port, and no other port" {
    const allocator = testing.allocator;
    const allow = try Allowlist.parse(
        allocator,
        "# the project's own hosts\n" ++
            "*.example.com 8443\n" ++
            "mirror.internal any\n",
    );
    defer allow.deinit(allocator);
    try testing.expect(allow.allows("example.com", 8443));
    try testing.expect(allow.allows("a.b.example.com", 8443));
    try testing.expect(allow.allows("MIRROR.INTERNAL", 5432));
    try testing.expect(!allow.allows("example.com", 443));
    try testing.expect(!allow.allows("example.com.evil.net", 8443));
    try testing.expect(!allow.allows("notexample.com", 8443));
}

test "an allowlist file that cannot be read as rules refuses every dial" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidAllowEntry, Allowlist.parse(allocator, "example.com not-a-port"));
    try testing.expectError(error.InvalidAllowEntry, Allowlist.parse(allocator, "example.com"));
    try testing.expectError(error.InvalidAllowEntry, Allowlist.parse(allocator, "ex ample.com 443"));
}

test "the handshake line names a host and a port, and nothing else" {
    const ok = parseHandshake("PABRIK-EGRESS/1 registry.npmjs.org 443").?;
    try testing.expectEqualStrings("registry.npmjs.org", ok.host);
    try testing.expectEqual(@as(u16, 443), ok.port);

    try testing.expect(parseHandshake("PABRIK-EGRESS/1 127.0.0.1 3128") != null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/2 example.com 443") == null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/1 example.com") == null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/1 example.com 0") == null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/1 example.com 70000") == null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/1 example.com 44 3") == null);
    try testing.expect(parseHandshake("PABRIK-EGRESS/1 ex\xc3\xa4mple 443") == null);
    try testing.expect(parseHandshake("CONNECT example.com:443 HTTP/1.1") == null);
}

test "the workspace is the listener's directory, not anything on the wire" {
    try testing.expectEqualStrings("ws_1", workspaceOf("/root/workspaces/ws_1"));
    try testing.expectEqualStrings("ws_1", workspaceOf("/root/workspaces/ws_1/"));
    try testing.expectEqualStrings("ws_1", workspaceOf("ws_1"));
}

test "the resolver refuses a query it cannot read as a name" {
    var buf: [256]u8 = undefined;
    const query = buildQuery(&buf, 0x1234, "registry.npmjs.org", 1).?;
    var name_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("registry.npmjs.org", queryName(query, &name_buf).?);
    try testing.expectEqual(@as(u8, 1), query[5]);

    const ip_q = buildQuery(&buf, 1, "1.2.3.4", 1).?;
    try testing.expectEqualStrings("1.2.3.4", queryName(ip_q, &name_buf).?);

    try testing.expect(queryName(query[0..11], &name_buf) == null);

    var single: [256]u8 = undefined;
    const short = buildQuery(&single, 1, "localhost", 1).?;
    try testing.expect(queryName(short, &name_buf) == null);

    const response = blk: {
        var b = ResponseBuilder{};
        b.header(0x1234, 0x81, 1, 0);
        b.question("registry.npmjs.org");
        break :blk b.buf[0..b.len];
    };
    try testing.expect(queryName(response, &name_buf) == null);
}

test "a response that answers a different question is dropped" {
    var query: [512]u8 = undefined;
    const built = buildQuery(&query, 0xbeef, "example.com", 1).?;
    var b = ResponseBuilder{};
    b.header(0xbeef, 0x81, 1, 1);
    b.question("example.com");
    b.answerA(.{ 93, 184, 216, 34 });
    try testing.expect(responseBelongsTo(b.text(), built));

    var other = ResponseBuilder{};
    other.header(0x0001, 0x81, 1, 1);
    other.question("example.com");
    other.answerA(.{ 93, 184, 216, 34 });
    try testing.expect(!responseBelongsTo(other.text(), built));

    var not_a_response = ResponseBuilder{};
    not_a_response.header(0xbeef, 0x01, 1, 0);
    not_a_response.question("example.com");
    try testing.expect(!responseBelongsTo(not_a_response.text(), built));
}

test "an answer that points inside the host fails the lookup" {
    var b = ResponseBuilder{};
    b.header(0x0101, 0x81, 1, 1);
    b.question("rebind.example.com");
    b.answerA(.{ 127, 0, 0, 1 });
    var out: [64]u8 = undefined;
    var scratch: [max_answers]Answer = undefined;
    try testing.expectEqualStrings("127.0.0.1", deniedAnswer(b.text(), &out, &scratch).?);

    var public = ResponseBuilder{};
    public.header(0x0101, 0x81, 1, 2);
    public.question("example.com");
    public.answerA(.{ 93, 184, 216, 34 });
    public.answerA(.{ 10, 0, 0, 1 });
    try testing.expectEqualStrings("10.0.0.1", deniedAnswer(public.text(), &out, &scratch).?);

    var all_public = ResponseBuilder{};
    all_public.header(0x0101, 0x81, 1, 1);
    all_public.question("example.com");
    all_public.answerA(.{ 93, 184, 216, 34 });
    try testing.expect(deniedAnswer(all_public.text(), &out, &scratch) == null);
}

test "a v6 answer inside the host is denied in its own family" {
    var b = ResponseBuilder{};
    b.header(0x0202, 0x81, 1, 1);
    b.question("rebind.example.com");
    var loopback = [_]u8{0} ** 16;
    loopback[15] = 1;
    b.answerAAAA(loopback);
    var out: [64]u8 = undefined;
    var scratch: [max_answers]Answer = undefined;
    try testing.expectEqualStrings("0000:0000:0000:0000:0000:0000:0000:0001", deniedAnswer(b.text(), &out, &scratch).?);

    var mapped = [_]u8{0} ** 16;
    mapped[10] = 0xff;
    mapped[11] = 0xff;
    mapped[12] = 169;
    mapped[13] = 254;
    mapped[14] = 169;
    mapped[15] = 254;
    var c = ResponseBuilder{};
    c.header(0x0203, 0x81, 1, 1);
    c.question("rebind.example.com");
    c.answerAAAA(mapped);
    try testing.expect(deniedAnswer(c.text(), &out, &scratch) != null);
}

test "a CNAME in front of an address does not stop the walk" {
    var b = ResponseBuilder{};
    b.header(0x0303, 0x81, 1, 2);
    b.question("alias.example.com");
    b.push(&[_]u8{ 0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 5 });
    b.push(&[_]u8{ 3, 'c', 'd', 'n', 0 });
    b.answerA(.{ 93, 184, 216, 34 });
    const answers = try answerAddresses(testing.allocator, b.text());
    defer testing.allocator.free(answers);
    try testing.expectEqual(@as(usize, 1), answers.len);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("93.184.216.34", answers[0].text(&out));
}

test "a response with more records than the walk covers is refused whole" {
    var b = ResponseBuilder{};
    b.header(0x0404, 0x81, 1, 65);
    b.question("many.example.com");
    try testing.expect(answerCountOverCap(b.text()));

    var ok = ResponseBuilder{};
    ok.header(0x0404, 0x81, 1, 2);
    ok.question("two.example.com");
    ok.answerA(.{ 93, 184, 216, 34 });
    ok.answerA(.{ 93, 184, 216, 35 });
    try testing.expect(!answerCountOverCap(ok.text()));

    try testing.expect(answerCountOverCap("short"));
}

test "a response longer than the resolver cap is refused" {
    try testing.expect(responseWithinCap(egress.resolver_response_cap));
    try testing.expect(!responseWithinCap(egress.resolver_response_cap + 1));
    try testing.expect(!responseWithinCap(11));
}

test "the audit line records the dial and the outcome it got" {
    const line = try auditLine(
        testing.allocator,
        1_700_000_000,
        "ws_1",
        .{ .host = "example.com", .port = 443 },
        "allowed",
        "93.184.216.34",
    );
    defer testing.allocator.free(line);
    try testing.expectEqualStrings(
        "ts=1700000000 workspace=ws_1 host=example.com port=443 outcome=allowed addr=93.184.216.34\n",
        line,
    );
}

test "the denied-port list parses, and a bad entry is an error" {
    const ports = try parsePortList(testing.allocator, "8081, 5432");
    defer testing.allocator.free(ports);
    try testing.expectEqualSlices(u16, &[_]u16{ 8081, 5432 }, ports);
    try testing.expectError(error.InvalidPortList, parsePortList(testing.allocator, "8081,,abc"));
}

test "the host's nameservers come out of a resolv.conf, in order" {
    const found = try parseNameservers(testing.allocator, "# comment\nnameserver 192.168.1.1\nnameserver 1.1.1.1\nsearch lan\n");
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual([4]u8{ 192, 168, 1, 1 }, found[0]);
    try testing.expectEqual([4]u8{ 1, 1, 1, 1 }, found[1]);
}
