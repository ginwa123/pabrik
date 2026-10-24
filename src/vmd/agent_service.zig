//! The host's half of the agent hand-off: it serves the current agent to a
//! guest's bootstrap, so a workspace's disk never carries the agent and a new
//! one reaches every workspace at the next boot.

const std = @import("std");
const linux = std.os.linux;
const vm_client = @import("vm_client.zig");

/// The vsock port the guest's bootstrap dials.
pub const agent_port: u32 = 5003;

/// What the guest asks for.
pub const request_line = "AGENT\n";

/// The most a guest may ask for in one line.
pub const max_request_bytes: usize = 64;

/// The agent's bytes, as one transfer. The agent is ~13 MiB.
pub const max_agent_bytes: usize = 64 * 1024 * 1024;

/// True when the guest's line is the request we answer.
pub fn isAgentRequest(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), std.mem.trimEnd(u8, request_line, "\r\n"));
}

/// The head that carries the length: `OK <bytes>\n`.
pub fn replyHead(buf: []u8, len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "OK {d}\n", .{len});
}

/// The length the head carries, or null when it is not a length we serve.
pub fn parseHead(line: []const u8) ?usize {
    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, trimmed, "OK ")) return null;
    const digits = std.mem.trim(u8, trimmed[3..], " ");
    if (digits.len == 0) return null;
    const len = std.fmt.parseInt(usize, digits, 10) catch return null;
    if (len == 0 or len > max_agent_bytes) return null;
    return len;
}

// ─── the listener ────────────────────────────────────────────────────────

const unix_af: u32 = 1;
const sock_stream: u32 = 1;
const backlog: u32 = 16;
const max_path_bytes: usize = 4096;
/// One listener per workspace, so this is the ceiling on how many hand-off
/// sockets one daemon holds. A box past it keeps the listeners it has.
const max_listeners: usize = 512;
/// How long an accept that ran out of descriptors pauses before retrying.
const starved_backoff_ns: u64 = 100 * std.time.ns_per_ms;

const Listener = struct {
    fd: linux.fd_t,
    key: []u8,
    allocator: std.mem.Allocator,
    agent: []const u8,
};

/// `<vsock.sock>_5003` — the path a guest's bootstrap dials.
pub fn keyFor(layout: vm_client.Layout, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}_{d}", .{ layout.vsock_sock, agent_port }) catch null;
}

pub const Reservation = enum { reserved, already_bound, no_room };

/// Which keys already have a listener, so `ensure` is a lookup after the first
/// call for a workspace. It used to be nothing at all: every dispatch bound a
/// fresh socket, forked a fresh accept thread and leaked both, so one busy
/// workspace walked the daemon into `RLIMIT_NOFILE` (1024 on this box). The
/// daemon's own `accept4` then failed with `EMFILE`, and that ended it.
const Registry = struct {
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

    /// Claim the key BEFORE its socket exists, so two dispatches that arrive
    /// together cannot both bind: the loser used to unlink the winner's socket
    /// and then fail its own bind with `EADDRINUSE` (errno 98).
    fn reserve(self: *@This(), key: []const u8) Reservation {
        if (self.find(key) != null) return .already_bound;
        if (self.count == max_listeners or key.len > max_path_bytes) return .no_room;
        @memcpy(self.keys[self.count][0..key.len], key);
        self.lens[self.count] = key.len;
        self.fds[self.count] = -1;
        self.count += 1;
        return .reserved;
    }

    fn record(self: *@This(), key: []const u8, fd: linux.fd_t) void {
        if (self.find(key)) |at| self.fds[at] = fd;
    }

    fn drop(self: *@This(), key: []const u8) void {
        const at = self.find(key) orelse return;
        const last = self.count - 1;
        self.keys[at] = self.keys[last];
        self.lens[at] = self.lens[last];
        self.fds[at] = self.fds[last];
        self.count = last;
    }
};

var bound = Registry{};

/// Bind the hand-off socket for a workspace, once. Safe to call on every
/// dispatch, so the listener exists before the guest's first dial — and cheap,
/// because every call after the first is a lookup.
pub fn ensure(allocator: std.mem.Allocator, layout: vm_client.Layout, agent: []const u8) void {
    if (agent.len == 0) return;
    // The socket lives in the workspace's directory, which the reconciler
    // creates when it boots the VM — but the listener has to be there
    // BEFORE the guest starts, so the directory is made here.
    vm_client.ensureWorkspaceDir(layout) catch return;
    var key_buf: [max_path_bytes]u8 = undefined;
    const key = keyFor(layout, &key_buf) orelse return;

    bound.lockIt();
    const reservation = bound.reserve(key);
    bound.lock.unlock();
    switch (reservation) {
        .already_bound => return,
        .no_room => {
            log("agent: no listener slot left for {s}", .{key});
            return;
        },
        .reserved => {},
    }

    if (bindListener(allocator, key, agent)) return;
    // The socket never came up: give the slot back so the next dispatch tries
    // again instead of believing this workspace is served.
    bound.lockIt();
    bound.drop(key);
    bound.lock.unlock();
}

fn bindListener(allocator: std.mem.Allocator, key: []const u8, agent: []const u8) bool {
    var path_buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(key, &path_buf) orelse return false;
    _ = linux.unlink(path_z);
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) {
        log("agent: no socket for {s}", .{key});
        return false;
    }
    const fd: linux.fd_t = @intCast(rc);
    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    const name = key[0..@min(key.len, 107)];
    @memcpy(addr.path[0..name.len], name);
    const bind_errno = linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrUn)));
    if (bind_errno != .SUCCESS) {
        log("agent: cannot bind {s} (errno {d})", .{ key, @intFromEnum(bind_errno) });
        _ = linux.close(fd);
        return false;
    }
    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) {
        log("agent: cannot listen on {s}", .{key});
        _ = linux.close(fd);
        return false;
    }
    const listener = allocator.create(Listener) catch {
        _ = linux.close(fd);
        return false;
    };
    listener.* = .{
        .fd = fd,
        .key = allocator.dupe(u8, key) catch {
            allocator.destroy(listener);
            _ = linux.close(fd);
            return false;
        },
        .allocator = allocator,
        .agent = agent,
    };
    const thread = std.Thread.spawn(.{}, acceptLoop, .{listener}) catch {
        allocator.free(listener.key);
        allocator.destroy(listener);
        _ = linux.close(fd);
        return false;
    };
    thread.detach();
    log("agent: serving {s} on {s}", .{ key, key });
    bound.lockIt();
    bound.record(key, fd);
    bound.lock.unlock();
    return true;
}

fn acceptLoop(listener: *Listener) void {
    defer {
        _ = linux.close(listener.fd);
        listener.allocator.free(listener.key);
        listener.allocator.destroy(listener);
    }
    while (true) {
        const rc = linux.accept(listener.fd, null, null);
        const err = linux.errno(rc);
        if (err == .SUCCESS) {
            const fd: linux.fd_t = @intCast(rc);
            serve(listener, fd);
            _ = linux.close(fd);
            continue;
        }
        if (err == .INTR) continue;
        // A descriptor-starved accept must not spin: the guest dials once, at
        // boot, so a short pause costs nothing and keeps the CPU quiet.
        if (err == .MFILE or err == .NFILE or err == .NOBUFS or err == .NOMEM) {
            var pause = linux.timespec{ .sec = 0, .nsec = @intCast(starved_backoff_ns) };
            _ = linux.nanosleep(&pause, null);
            continue;
        }
        return;
    }
}

/// Answer one guest: the request line, then the head and the agent.
fn serve(listener: *Listener, fd: linux.fd_t) void {
    var buf: [max_request_bytes]u8 = undefined;
    var have: usize = 0;
    while (have < buf.len) {
        const n = linux.read(fd, buf[have..].ptr, buf.len - have);
        if (linux.errno(n) != .SUCCESS) return;
        const got: usize = @intCast(n);
        if (got == 0) return;
        have += got;
        if (std.mem.indexOfScalar(u8, buf[0..have], '\n') != null) break;
    }
    const end = std.mem.indexOfScalar(u8, buf[0..have], '\n') orelse return;
    if (!isAgentRequest(buf[0..end])) {
        log("agent: that is not the agent request", .{});
        return;
    }

    var head: [32]u8 = undefined;
    const head_text = replyHead(&head, listener.agent.len) catch return;
    if (!writeAll(fd, head_text)) return;
    if (!writeAll(fd, listener.agent)) return;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (linux.errno(n) != .SUCCESS) return false;
        const wrote: usize = @intCast(n);
        if (wrote == 0) return false;
        sent += wrote;
    }
    return true;
}

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

fn cstr(text: []const u8, buf: []u8) ?[*:0]const u8 {
    if (text.len + 1 > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return @ptrCast(buf.ptr);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

// ─── the leak that killed the manager ────────────────────────────────────
//
// Every dispatch — `exec`, `tty`, `fs.*`, `spawn`, `probe`, `signal`, `log` —
// calls `ensure`, so `ensure` has to be free after the first call. It was not:
// each call opened a socket, forked an accept thread and leaked both. One busy
// workspace therefore walked the daemon into `RLIMIT_NOFILE`, and the daemon's
// own `accept4` then failed with `EMFILE` — which the accept loop turned into
// `Error.AcceptFailed`, `main` into `exit(1)`, and left every Firecracker VMM
// it owned running with no manager. The observable is a descriptor and a
// thread; no fake could show either, so these tests use real sockets in a
// per-test temp dir.

/// How long a test waits for the listener's answer. The accept thread is
/// somebody else's, so the wait is a deadline, never a sleep.
const answer_deadline_ms: i32 = 5000;

/// How many entries a /proc directory holds, dot entries included. Raw
/// `getdents64`: a directory listing is the one thing this file needs, and it
/// costs one descriptor that it closes itself.
fn countEntries(path: []const u8) !usize {
    var path_buf: [max_path_bytes]u8 = undefined;
    const path_z = cstr(path, &path_buf) orelse return error.PathTooLong;
    const rc = linux.open(path_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var entries: usize = 0;
    var raw: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &raw, raw.len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const entry: *align(1) linux.dirent64 = @ptrCast(raw[off..].ptr);
            entries += 1;
            off += entry.reclen;
        }
    }
    return entries;
}

/// Descriptors this process has open, the listing's own descriptor and its two
/// dot entries excluded. A listener is a descriptor, so this is the number the
/// crash was about.
fn openDescriptors() !usize {
    return try countEntries("/proc/self/fd") - 3;
}

/// Threads this process runs. Each leaked listener also leaked its accept
/// thread, so this number climbed with the descriptor count.
fn liveThreads() !usize {
    return try countEntries("/proc/self/task") - 2;
}

fn layoutIn(allocator: std.mem.Allocator, root: []const u8) !vm_client.Layout {
    return vm_client.layoutFor(allocator, .{
        .workspace_id = "ws_hand_off_leak",
        .base_image = "/dev/null",
        .kernel = "/dev/null",
        .fc_bin = "/dev/null",
        .root = root,
    });
}

var temp_seq = std.atomic.Value(u32).init(0);

/// A short, per-test root under /tmp. `testing.tmpDir` lives under the build
/// cache, and a unix socket path is capped at 108 bytes — deeper than that and
/// the bind is `ENAMETOOLONG`, not a leak.
fn makeTempRoot(allocator: std.mem.Allocator) ![]u8 {
    const seq = temp_seq.fetchAdd(1, .seq_cst);
    const path = try std.fmt.allocPrint(allocator, "/tmp/vmd-agent-test-{d}-{d}", .{ linux.getpid(), seq });
    var buf: [max_path_bytes]u8 = undefined;
    const z = cstr(path, &buf) orelse {
        allocator.free(path);
        return error.PathTooLong;
    };
    if (linux.errno(linux.mkdir(z, 0o700)) != .SUCCESS) {
        allocator.free(path);
        return error.MkdirFailed;
    }
    return path;
}

/// Remove the socket and the directories `layoutFor` + `ensureWorkspaceDir`
/// created, so a test leaves nothing behind.
fn removeTempRoot(root: []const u8, layout: vm_client.Layout) void {
    var buf: [max_path_bytes]u8 = undefined;
    var key_buf: [max_path_bytes]u8 = undefined;
    if (keyFor(layout, &key_buf)) |key| {
        if (cstr(key, &buf)) |z| _ = linux.unlink(z);
    }
    if (cstr(layout.vsock_sock, &buf)) |z| _ = linux.unlink(z);
    if (cstr(layout.dir, &buf)) |z| _ = linux.rmdir(z);
    var workspaces_buf: [max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&workspaces_buf, "{s}/workspaces", .{root})) |workspaces| {
        if (cstr(workspaces, &buf)) |z| _ = linux.rmdir(z);
    } else |_| {}
    if (cstr(root, &buf)) |z| _ = linux.rmdir(z);
}

/// Counts the bytes still held, so a heap leak is an assertion and not a line
/// in a log nobody reads. The listener's own memory is intentionally still
/// alive when the test ends (its accept thread is detached), so the assertion
/// is a delta across the dispatches, never "zero at the end".
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.live_bytes -= memory.len;
    }
};

/// Dial the hand-off socket the way a guest's bootstrap does: one request
/// line, then the head and the agent.
fn askTheListener(allocator: std.mem.Allocator, key: []const u8, request: []const u8) ![]u8 {
    const rc = linux.socket(unix_af, sock_stream | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NoSocket;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var addr = SockaddrUn{ .family = unix_af, .path = [_]u8{0} ** 108 };
    if (key.len > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..key.len], key);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrUn))) != .SUCCESS) {
        return error.ConnectFailed;
    }
    if (!writeAll(fd, request)) return error.WriteFailed;

    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, answer_deadline_ms) == 0) return error.NoAnswer;

    var head_buf: [32]u8 = undefined;
    var head_len: usize = 0;
    while (std.mem.indexOfScalar(u8, head_buf[0..head_len], '\n') == null) {
        if (head_len == head_buf.len) return error.NoAnswer;
        const n = linux.read(fd, head_buf[head_len..].ptr, head_buf.len - head_len);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        const got: usize = @intCast(n);
        if (got == 0) return error.ReadFailed;
        head_len += got;
    }
    const newline = std.mem.indexOfScalar(u8, head_buf[0..head_len], '\n').?;
    const len = parseHead(head_buf[0..newline]) orelse return error.NoAnswer;

    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    // The head and the body can arrive in one segment, so whatever followed
    // the newline is already the start of the agent.
    const already = head_buf[newline + 1 .. head_len];
    const carried = @min(already.len, len);
    @memcpy(body[0..carried], already[0..carried]);
    var have: usize = carried;
    while (have < len) {
        const n = linux.read(fd, body[have..].ptr, len - have);
        if (linux.errno(n) != .SUCCESS) return error.ReadFailed;
        const got: usize = @intCast(n);
        if (got == 0) return error.ReadFailed;
        have += got;
    }
    return body;
}

test "a workspace keeps one hand-off listener however often the daemon dispatches" {
    var counting = CountingAllocator{ .parent = std.heap.page_allocator };
    const allocator = counting.allocator();
    const root = try makeTempRoot(allocator);
    defer allocator.free(root);
    const layout = try layoutIn(allocator, root);
    defer layout.deinit(allocator);
    defer removeTempRoot(root, layout);

    ensure(allocator, layout, "the agent's bytes");
    const descriptors = try openDescriptors();
    const threads = try liveThreads();
    const bytes = counting.live_bytes;

    for (0..16) |_| ensure(allocator, layout, "the agent's bytes");

    // One socket, one accept thread, one Listener: the second dispatch and
    // every one after it must cost none of the three.
    try testing.expectEqual(descriptors, try openDescriptors());
    try testing.expectEqual(threads, try liveThreads());
    try testing.expectEqual(bytes, counting.live_bytes);
}

test "the guest's bootstrap is answered after the daemon dispatches again" {
    var counting = CountingAllocator{ .parent = std.heap.page_allocator };
    const allocator = counting.allocator();
    const root = try makeTempRoot(allocator);
    defer allocator.free(root);
    const layout = try layoutIn(allocator, root);
    defer layout.deinit(allocator);
    defer removeTempRoot(root, layout);

    ensure(allocator, layout, "the agent's bytes");
    // A later dispatch must not unlink the socket a booting guest is about to
    // dial, nor answer `EADDRINUSE` on a bind of its own.
    ensure(allocator, layout, "the agent's bytes");

    var key_buf: [max_path_bytes]u8 = undefined;
    const key = keyFor(layout, &key_buf).?;
    const answer = try askTheListener(allocator, key, "AGENT\n");
    defer allocator.free(answer);
    try testing.expectEqualStrings("the agent's bytes", answer);
}

test "a reserved key is reserved once" {
    var registry = Registry{};
    try testing.expectEqual(Reservation.reserved, registry.reserve("/vms/ws_a/vsock.sock_5003"));
    try testing.expectEqual(Reservation.already_bound, registry.reserve("/vms/ws_a/vsock.sock_5003"));
    try testing.expectEqual(Reservation.reserved, registry.reserve("/vms/ws_b/vsock.sock_5003"));
    try testing.expectEqual(@as(usize, 2), registry.count);
}

test "a dropped reservation can be taken again" {
    var registry = Registry{};
    _ = registry.reserve("/vms/ws_a/vsock.sock_5003");
    registry.drop("/vms/ws_a/vsock.sock_5003");
    try testing.expectEqual(@as(usize, 0), registry.count);
    try testing.expectEqual(Reservation.reserved, registry.reserve("/vms/ws_a/vsock.sock_5003"));
}

test "the guest's request is the one we answer" {
    try testing.expect(isAgentRequest("AGENT\n"));
    try testing.expect(isAgentRequest("AGENT\r\n"));
    try testing.expect(!isAgentRequest("AGENTS\n"));
    try testing.expect(!isAgentRequest(""));
}

test "the head carries the length, and only a length we serve" {
    var buf: [32]u8 = undefined;
    const head = try replyHead(&buf, 4096);
    try testing.expectEqualStrings("OK 4096\n", head);
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096\n"));
    try testing.expectEqual(@as(?usize, 4096), parseHead("OK 4096"));
    try testing.expect(parseHead("OK 0\n") == null);
    try testing.expect(parseHead("OK not-a-number\n") == null);
    try testing.expect(parseHead("nope\n") == null);
}
