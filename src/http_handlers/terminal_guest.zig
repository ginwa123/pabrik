//! Under `--saas` a terminal is a shell running INSIDE the workspace's VM,
//! reached through `pabrik-vmd`. Refusals are the point: no branch here reaches
//! a host `forkpty`, so a process that cannot name a VM says so instead.

const std = @import("std");
const terminal_session = @import("terminal_session.zig");
const runtime_mode = @import("../runtime_mode.zig");
const policy = @import("../vmd/policy.zig");
const vmd = @import("../vmd/vmd_client.zig");

/// Guest terminal ids are distinguishable from host ones on sight, so a handler
/// that receives an id can route it without consulting the mode.
pub const id_prefix = "gterm-";
/// The backend name a guest terminal reports on the wire.
pub const backend_guest_pty: []const u8 = "guest-pty";

pub const Error = error{
    /// `--saas` and no workspace id was given: the caller must name the VM.
    WorkspaceRequired,
    /// The id is not inert, so it cannot name a VM.
    WorkspaceInvalid,
    /// This host has no VM backend at all (not Linux).
    UnsupportedPlatform,
    TooManySessions,
    InvalidSize,
    ManagerUnavailable,
    ManagerRefused,
    SessionNotFound,
    SessionExited,
    WriteFailed,
    OutOfMemory,
};

/// Where a create should run. `refuse` carries the message a caller reads, so
/// the refusal explains itself instead of looking like a missing feature.
pub const Route = union(enum) {
    host,
    guest: []const u8,
    refuse: []const u8,
};

pub const workspace_hint = "SaaS mode runs the terminal inside the workspace VM: pass workspace_id";

/// Local mode keeps the host pty. A `--saas` process answers only for a
/// workspace, and refuses rather than spawning a shell on the host.
pub fn routeFor(mode: runtime_mode.Mode, workspace_id: ?[]const u8) Route {
    if (mode != .saas) return .host;
    const id = workspace_id orelse return .{ .refuse = workspace_hint };
    if (id.len == 0) return .{ .refuse = workspace_hint };
    if (!policy.workspaceIdValid(id)) return .{ .refuse = workspace_hint };
    return .{ .guest = id };
}

pub fn isGuestId(id: []const u8) bool {
    return std.mem.startsWith(u8, id, id_prefix);
}

/// The directory the guest shell starts in, as a workspace-RELATIVE path. Under
/// `--saas` the only vocabulary that exists is the guest's own, so a host path
/// resolves to the workspace root rather than being translated.
pub fn guestCwdFor(requested: []const u8) []const u8 {
    const rel = policy.relativeWorkspace(policy.guest_root, requested) orelse return "";
    return rel;
}

pub const Size = struct { cols: u16, rows: u16 };

/// Validate a create without touching the VM: the window bounds are the host
/// pty path's, so a caller cannot tell the two substrates apart by their errors.
pub fn validateSize(cols: ?u16, rows: ?u16) Error!Size {
    const c = cols orelse terminal_session.default_cols;
    const r = rows orelse terminal_session.default_rows;
    if (c < terminal_session.min_dim or c > terminal_session.max_dim or
        r < terminal_session.min_dim or r > terminal_session.max_dim)
    {
        return error.InvalidSize;
    }
    return .{ .cols = c, .rows = r };
}

/// The daemon's own reason for a refused create (the guest's, when the refusal
/// came from the VM). Copied out of the client's record so the handler can put
/// it on the wire instead of a generic string.
pub const Refusal = struct {
    pub const max = 256;
    message: [max]u8 = [_]u8{0} ** max,
    len: usize = 0,

    pub fn text(self: *const Refusal) []const u8 {
        return self.message[0..self.len];
    }
};

pub const Info = struct {
    id: []const u8,
    pid: i32,
    backend: []const u8,
};

pub const Session = struct {
    id: []u8,
    workspace_id: []u8,
    /// The directory the shell started in, as the GUEST sees it: a path
    /// relative to the workspace root. Empty means the workspace root.
    cwd: []u8,
    /// The guest's terminal id: its slot in the VM's tty table, which is also
    /// how the daemon finds the port that terminal answers on.
    tty_id: i64,
    /// The pid of the shell, as the GUEST reports it. Never a host pid.
    guest_pid: i64,
    cols: u16,
    rows: u16,
    owner: []u8,
    buf: std.ArrayList(u8),
    base: u64,
    total: u64,
    exited: bool,
    exit_code: ?i32,
    mutex: std.atomic.Mutex,
    last_active_s: i64,
    last_user_active_s: i64,
    last_output_at_s: i64,
};

var g_mutex: std.atomic.Mutex = .unlocked;
var g_sessions: std.StringHashMap(*Session) = undefined;
var g_inited: bool = false;
var g_id_counter: u64 = 0;
var g_idle_timeout_s: i64 = terminal_session.idle_timeout_s;
var g_idle_kill_s: i64 = terminal_session.idle_kill_s;
var g_max_sessions: u32 = policy.max_ttys;
const g_alloc = std.heap.c_allocator;

fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
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

/// Wall-clock seconds through libc, exactly as the host pty path ages its
/// sessions. Coarse seconds are plenty for an idle sweep.
extern "c" fn time(t: ?*i64) i64;

fn nowSeconds() i64 {
    return time(null);
}

pub fn setIdleTimeoutForTest(seconds: i64) i64 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_idle_timeout_s;
    g_idle_timeout_s = seconds;
    return prev;
}

pub fn setIdleKillForTest(seconds: i64) i64 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_idle_kill_s;
    g_idle_kill_s = seconds;
    return prev;
}

pub fn setMaxSessionsForTest(n: u32) u32 {
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    const prev = g_max_sessions;
    g_max_sessions = n;
    return prev;
}

pub fn sessionCount() usize {
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.count();
}

/// Look a session up by id. The pointer is valid until the session is reaped.
pub fn getSession(id: []const u8) ?*Session {
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    return reg.get(id);
}

/// No session, or someone else's session: a foreign id is indistinguishable
/// from a missing one, exactly as on the host pty path.
pub fn getSessionForOwner(id: []const u8, caller_owner: []const u8) ?*Session {
    const s = getSession(id) orelse return null;
    if (s.owner.len == 0 or caller_owner.len == 0) return s;
    if (!std.mem.eql(u8, s.owner, caller_owner)) return null;
    return s;
}

/// Every live guest terminal the caller may drive, in the same shape as the
/// host list: the workspace it belongs to, the directory it started in, and
/// the console it got. Owner-scoped with the guest's own rule.
pub fn listSessionsForOwner(allocator: std.mem.Allocator, caller_owner: []const u8) ![]terminal_session.SessionSummary {
    var out = std.ArrayList(terminal_session.SessionSummary).empty;
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
        if (s.owner.len != 0 and caller_owner.len != 0 and !std.mem.eql(u8, s.owner, caller_owner)) continue;
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
            .backend = backend_guest_pty,
        }) catch |err| {
            allocator.free(id);
            allocator.free(workspace_id);
            allocator.free(cwd);
            return err;
        };
    }
    return out.toOwnedSlice(allocator);
}

fn allocId() Error![]u8 {
    mutexLock(&g_mutex);
    g_id_counter += 1;
    const n = g_id_counter;
    g_mutex.unlock();
    return std.fmt.allocPrint(g_alloc, "{s}{x}", .{ id_prefix, n }) catch return error.OutOfMemory;
}

/// Where `--saas` talks to its manager, or null when this host cannot run a VM
/// at all. Public because every terminal handler needs the same answer.
pub fn socketPath() ?[]const u8 {
    return managerSocket();
}

/// The manager's socket, or null when nothing can host a terminal.
fn managerSocket() ?[]const u8 {
    if (!runtime_mode.vm_backend_available) return null;
    return runtime_mode.socketPath();
}

fn managerError(err: anyerror) Error {
    return switch (err) {
        error.ConnectFailed, error.SocketFailed, error.IoFailed, error.Timeout => error.ManagerUnavailable,
        error.ServerFailure => error.ManagerRefused,
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        else => error.ManagerRefused,
    };
}

fn checkCapacity() Error!void {
    const reg = registry();
    mutexLock(&g_mutex);
    const n = reg.count();
    const cap = g_max_sessions;
    g_mutex.unlock();
    if (n >= cap) return error.TooManySessions;
}

/// Start a shell inside the workspace's VM. The guest owns the pty; the pid that
/// comes back is the guest's.
pub fn create(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    requested_cwd: []const u8,
    cols: ?u16,
    rows: ?u16,
    owner: []const u8,
    refusal: ?*Refusal,
) Error!Info {
    if (!runtime_mode.vm_backend_available) return error.UnsupportedPlatform;
    if (!policy.workspaceIdValid(workspace_id)) return error.WorkspaceInvalid;
    const size = try validateSize(cols, rows);
    const socket = managerSocket() orelse return error.UnsupportedPlatform;

    sweepIdleExcluding(allocator, socket, null);
    try checkCapacity();

    const cwd_rel = guestCwdFor(requested_cwd);
    const cwd_copy = g_alloc.dupe(u8, cwd_rel) catch return error.OutOfMemory;
    errdefer g_alloc.free(cwd_copy);
    var client = vmd.Client.init(allocator, socket);
    const opened = client.ttyOpen(workspace_id, cwd_rel, size.cols, size.rows) catch |err| {
        if (err == vmd.Error.ServerFailure) {
            const failure = client.lastFailure();
            if (failure != null and failure.?.code == .bad_request) {
                if (refusal) |out| {
                    const text = failure.?.text();
                    out.len = @min(text.len, Refusal.max);
                    @memcpy(out.message[0..out.len], text[0..out.len]);
                }
                return error.ManagerRefused;
            }
        }
        return managerError(err);
    };

    const id = try allocId();
    errdefer g_alloc.free(id);
    const workspace_copy = g_alloc.dupe(u8, workspace_id) catch return error.OutOfMemory;
    errdefer g_alloc.free(workspace_copy);
    const owner_copy = g_alloc.dupe(u8, owner) catch return error.OutOfMemory;
    errdefer g_alloc.free(owner_copy);
    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    errdefer g_alloc.destroy(session);
    const now = nowSeconds();
    session.* = .{
        .id = id,
        .workspace_id = workspace_copy,
        .cwd = cwd_copy,
        .tty_id = opened.tty_id,
        .guest_pid = opened.pid,
        .cols = size.cols,
        .rows = size.rows,
        .owner = owner_copy,
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = now,
        .last_user_active_s = now,
        .last_output_at_s = 0,
    };
    const reg = registry();
    mutexLock(&g_mutex);
    reg.put(id, session) catch {
        g_mutex.unlock();
        return error.OutOfMemory;
    };
    g_mutex.unlock();
    return .{ .id = id, .pid = @intCast(@max(opened.pid, 0)), .backend = backend_guest_pty };
}

pub const Output = struct {
    data: []u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

/// Everything the guest produced since `cursor`, plus the exit state. An empty
/// answer with `exited` false means the terminal is simply quiet.
pub fn readOutputAlloc(
    allocator: std.mem.Allocator,
    socket: []const u8,
    s: *Session,
    cursor: u64,
) Error!Output {
    var client = vmd.Client.init(allocator, socket);
    const chunk = client.ttyRead(s.workspace_id, s.tty_id, policy.max_tty_chunk) catch |err| {
        return managerError(err);
    };
    defer chunk.deinit(allocator);

    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    s.last_active_s = nowSeconds();
    if (chunk.data.len > 0) appendLocked(s, chunk.data);
    if (chunk.exited) {
        s.exited = true;
        s.exit_code = @intCast(chunk.exit_code);
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
    return .{
        .data = try allocator.dupe(u8, s.buf.items[off..]),
        .cursor = s.total,
        .exited = s.exited,
        .exit_code = s.exit_code,
    };
}

fn appendLocked(s: *Session, bytes: []const u8) void {
    if (bytes.len >= terminal_session.buffer_cap) {
        const start = terminal_session.tailKeepStart(bytes.len, terminal_session.buffer_cap);
        s.buf.clearRetainingCapacity();
        s.buf.appendSlice(g_alloc, bytes[start..]) catch {
            s.total += bytes.len;
            s.base = s.total;
            s.buf.clearRetainingCapacity();
            s.last_output_at_s = nowSeconds();
            return;
        };
        s.total += bytes.len;
        s.base = s.total - s.buf.items.len;
        s.last_output_at_s = nowSeconds();
        return;
    }
    s.buf.appendSlice(g_alloc, bytes) catch {
        s.total += bytes.len;
        s.base = s.total;
        s.buf.clearRetainingCapacity();
        s.last_output_at_s = nowSeconds();
        return;
    };
    s.total += bytes.len;
    s.last_output_at_s = nowSeconds();
    if (s.buf.items.len > terminal_session.buffer_cap) {
        const drop = terminal_session.trimDropLen(s.buf.items.len, terminal_session.buffer_cap);
        std.mem.copyForwards(u8, s.buf.items[0 .. s.buf.items.len - drop], s.buf.items[drop..]);
        s.buf.items.len -= drop;
        s.base += drop;
    }
    terminal_session.shrinkBufferToLen(&s.buf, g_alloc);
}

/// The exit code the shell reported, when it has exited.
pub fn exitCode(s: *Session) ?i32 {
    mutexLock(&s.mutex);
    defer s.mutex.unlock();
    return s.exit_code;
}

pub fn writeInput(allocator: std.mem.Allocator, socket: []const u8, s: *Session, data: []const u8) Error!usize {
    if (data.len == 0) return 0;
    if (s.exited) return error.SessionExited;
    mutexLock(&s.mutex);
    const active = nowSeconds();
    s.last_active_s = active;
    s.last_user_active_s = active;
    s.mutex.unlock();

    var client = vmd.Client.init(allocator, socket);
    const written = client.ttyWrite(s.workspace_id, s.tty_id, data) catch |err| {
        if (err == vmd.Error.ServerFailure) {
            const failure = client.lastFailure();
            if (failure != null and failure.?.code == .not_ready) {
                markExited(s);
                return error.SessionExited;
            }
            return error.WriteFailed;
        }
        return managerError(err);
    };
    return written;
}

pub fn resizeSession(allocator: std.mem.Allocator, socket: []const u8, s: *Session, cols: u16, rows: u16) Error!void {
    const size = try validateSize(cols, rows);
    if (s.exited) return error.SessionExited;
    var client = vmd.Client.init(allocator, socket);
    client.ttyResize(s.workspace_id, s.tty_id, size.cols, size.rows) catch |err| return managerError(err);
    mutexLock(&s.mutex);
    s.cols = size.cols;
    s.rows = size.rows;
    s.last_active_s = nowSeconds();
    s.last_user_active_s = s.last_active_s;
    s.mutex.unlock();
}

fn markExited(s: *Session) void {
    mutexLock(&s.mutex);
    s.exited = true;
    if (s.exit_code == null) s.exit_code = -1;
    s.mutex.unlock();
}

/// Delete by id alone: the daemon needs no caller identity to kill a shell.
pub fn destroy(allocator: std.mem.Allocator, socket: []const u8, id: []const u8) Error!void {
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    g_mutex.unlock();
    reapSession(allocator, socket, entry.value);
}

pub fn destroyForOwner(allocator: std.mem.Allocator, socket: []const u8, id: []const u8, caller_owner: []const u8) Error!void {
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(id) orelse {
        g_mutex.unlock();
        return error.SessionNotFound;
    };
    const allowed = entry.value.owner.len == 0 or caller_owner.len == 0 or
        std.mem.eql(u8, entry.value.owner, caller_owner);
    if (!allowed) {
        reg.put(entry.key, entry.value) catch {};
        g_mutex.unlock();
        return error.SessionNotFound;
    }
    g_mutex.unlock();
    reapSession(allocator, socket, entry.value);
}

/// Teardown for a session already removed from the registry: kill the guest
/// shell, give the buffer back, free the record.
fn reapSession(allocator: std.mem.Allocator, socket: []const u8, s: *Session) void {
    var client = vmd.Client.init(allocator, socket);
    client.ttyClose(s.workspace_id, s.tty_id) catch {};
    s.buf.deinit(g_alloc);
    g_alloc.free(s.owner);
    g_alloc.free(s.workspace_id);
    g_alloc.free(s.cwd);
    g_alloc.free(s.id);
    g_alloc.destroy(s);
}

/// Reap what nothing touched past the idle timeout. The rule is the host pty
/// path's own (`terminal_session.shouldReap`), so a terminal ages out at the same
/// rate in either substrate.
pub fn sweepIdle(allocator: std.mem.Allocator, socket: []const u8) void {
    sweepIdleExcluding(allocator, socket, null);
}

fn sweepIdleExcluding(allocator: std.mem.Allocator, socket: []const u8, exclude: ?*Session) void {
    const now = nowSeconds();
    const reg = registry();
    mutexLock(&g_mutex);
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
        const busy = terminal_session.isBusyByStamps(s.exited, s.last_output_at_s, now);
        if (terminal_session.shouldReap(user_idle, abs_idle, busy)) {
            victims.append(g_alloc, s) catch break;
        }
    }
    for (victims.items) |v| {
        _ = reg.fetchRemove(v.id);
    }
    g_mutex.unlock();
    for (victims.items) |v| {
        reapSession(allocator, socket, v);
    }
}

// ==== Behaviour tests: the decisions, not the VM — a live terminal is the
// ==== functional UI test's job.

const testing = std.testing;

fn expectRoute(expected: Route, actual: Route) !void {
    switch (expected) {
        .host => try testing.expectEqual(Route.host, actual),
        .guest => |ws| switch (actual) {
            .guest => |got| try testing.expectEqualStrings(ws, got),
            else => return error.TestUnexpectedResult,
        },
        .refuse => |msg| switch (actual) {
            .refuse => |got| try testing.expectEqualStrings(msg, got),
            else => return error.TestUnexpectedResult,
        },
    }
}

test "routeFor: a --saas process never falls back to the host pty" {
    // Local mode keeps the host pty whether or not a workspace is named.
    try expectRoute(.host, routeFor(.local, null));
    try expectRoute(.host, routeFor(.local, "ws_1"));

    try expectRoute(.{ .refuse = workspace_hint }, routeFor(.saas, null));
    try expectRoute(.{ .refuse = workspace_hint }, routeFor(.saas, ""));
    try expectRoute(.{ .guest = "ws_1" }, routeFor(.saas, "ws_1"));
}

test "routeFor: an id that cannot name a VM is refused, not rewritten" {
    try expectRoute(.{ .refuse = workspace_hint }, routeFor(.saas, "../../etc"));
    try expectRoute(.{ .refuse = workspace_hint }, routeFor(.saas, "/home/you/project"));
    try expectRoute(.{ .refuse = workspace_hint }, routeFor(.saas, "ws 1"));
}

test "isGuestId: a guest terminal is told apart from a host one by its id" {
    try testing.expect(isGuestId("gterm-1"));
    try testing.expect(!isGuestId("term-1"));
    try testing.expect(!isGuestId(""));
}

test "guestCwdFor: the guest vocabulary is honoured, a host path starts at the root" {
    try testing.expectEqualStrings("", guestCwdFor(""));
    try testing.expectEqualStrings("", guestCwdFor("/workspace"));
    try testing.expectEqualStrings("src/agent", guestCwdFor("/workspace/src/agent"));

    try testing.expectEqualStrings("", guestCwdFor("/home/you/project"));
    try testing.expectEqualStrings("", guestCwdFor("/workspaces"));
    try testing.expectEqualStrings("", guestCwdFor("/workspace/../etc"));
}

test "validateSize: the window bounds match the host pty path" {
    const dflt = try validateSize(null, null);
    try testing.expectEqual(terminal_session.default_cols, dflt.cols);
    try testing.expectEqual(terminal_session.default_rows, dflt.rows);

    try testing.expectError(error.InvalidSize, validateSize(1, 24));
    try testing.expectError(error.InvalidSize, validateSize(80, terminal_session.max_dim + 1));
}

fn insertSessionForTest(workspace_id: []const u8, owner: []const u8) !*Session {
    const id = try allocId();
    const workspace_copy = try allocStr(workspace_id);
    const cwd_copy = try allocStr("");
    const owner_copy = try allocStr(owner);
    const session = g_alloc.create(Session) catch return error.OutOfMemory;
    const now = nowSeconds();
    session.* = .{
        .id = id,
        .workspace_id = workspace_copy,
        .cwd = cwd_copy,
        .tty_id = 0,
        .guest_pid = 0,
        .cols = terminal_session.default_cols,
        .rows = terminal_session.default_rows,
        .owner = owner_copy,
        .buf = .empty,
        .base = 0,
        .total = 0,
        .exited = false,
        .exit_code = null,
        .mutex = .unlocked,
        .last_active_s = now,
        .last_user_active_s = now,
        .last_output_at_s = 0,
    };
    const reg = registry();
    mutexLock(&g_mutex);
    defer g_mutex.unlock();
    reg.put(id, session) catch return error.OutOfMemory;
    return session;
}

fn allocStr(text: []const u8) ![]u8 {
    return g_alloc.dupe(u8, text);
}

fn removeSessionForTest(s: *Session) void {
    const reg = registry();
    mutexLock(&g_mutex);
    const entry = reg.fetchRemove(s.id) orelse {
        g_mutex.unlock();
        return;
    };
    g_mutex.unlock();
    entry.value.buf.deinit(g_alloc);
    g_alloc.free(entry.value.owner);
    g_alloc.free(entry.value.workspace_id);
    g_alloc.free(entry.value.cwd);
    g_alloc.free(entry.value.id);
    g_alloc.destroy(entry.value);
}

test "the guest buffer keeps an absolute cursor across appends" {
    const s = try insertSessionForTest("ws_1", "user_test");
    defer removeSessionForTest(s);

    mutexLock(&s.mutex);
    appendLocked(s, "first");
    appendLocked(s, "-second");
    const total = s.total;
    const kept = try testing.allocator.dupe(u8, s.buf.items);
    s.mutex.unlock();
    defer testing.allocator.free(kept);

    try testing.expectEqualStrings("first-second", kept);
    try testing.expectEqual(@as(u64, 12), total);
}

test "the guest buffer drops the oldest bytes once past the cap" {
    const s = try insertSessionForTest("ws_1", "user_test");
    defer removeSessionForTest(s);

    const big = try testing.allocator.alloc(u8, terminal_session.buffer_cap + 4096);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    @memcpy(big[0..2], "AB");

    mutexLock(&s.mutex);
    appendLocked(s, big);
    const base = s.base;
    const total = s.total;
    const len = s.buf.items.len;
    s.mutex.unlock();

    try testing.expectEqual(@as(usize, terminal_session.buffer_cap), len);
    try testing.expectEqual(@as(u64, 4096), base);
    try testing.expectEqual(@as(u64, big.len), total);
}

test "a burst past the cap keeps the newest bytes and does not abort the process" {
    const s = try insertSessionForTest("ws_1", "user_test");
    defer removeSessionForTest(s);

    const chunk = try testing.allocator.alloc(u8, policy.max_tty_chunk);
    defer testing.allocator.free(chunk);

    // 16 x 32 KiB guest chunks, the largest a read returns. Capacity overshoots
    // the slack one append BEFORE the stream fills the cap: the aborting state.
    mutexLock(&s.mutex);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        @memset(chunk, 'a' + @as(u8, @intCast(i)));
        appendLocked(s, chunk);
    }
    const len = s.buf.items.len;
    const total = s.total;
    const base = s.base;
    const kept = try testing.allocator.dupe(u8, s.buf.items);
    s.mutex.unlock();
    defer testing.allocator.free(kept);

    try testing.expectEqual(terminal_session.buffer_cap, len);
    try testing.expectEqual(@as(u64, 16 * policy.max_tty_chunk), total);
    try testing.expectEqual(total - terminal_session.buffer_cap, base);
    // The window that survives is the newest cap-sized tail: the last eight
    // chunks, in order, with nothing left of the seven before them.
    try testing.expectEqual(@as(u8, 'a' + 8), kept[0]);
    try testing.expectEqual(@as(u8, 'a' + 15), kept[kept.len - 1]);
}

test "a foreign caller cannot reach another owner's guest terminal" {
    const s = try insertSessionForTest("ws_1", "user_a");
    defer removeSessionForTest(s);

    try testing.expect(getSessionForOwner(s.id, "user_a") != null);
    try testing.expect(getSessionForOwner(s.id, "user_b") == null);
    try testing.expect(getSessionForOwner("gterm-nope", "user_a") == null);
}

test "a guest terminal ages out on the host path's own rule" {
    const prev_timeout = setIdleTimeoutForTest(3600);
    defer _ = setIdleTimeoutForTest(prev_timeout);
    const prev_kill = setIdleKillForTest(60);
    defer _ = setIdleKillForTest(prev_kill);

    const stale = try insertSessionForTest("ws_1", "user_test");
    const stale_id = try allocStr(stale.id);
    defer g_alloc.free(stale_id);
    const busy = try insertSessionForTest("ws_1", "user_test");
    const busy_id = try allocStr(busy.id);
    defer g_alloc.free(busy_id);
    defer if (getSession(busy_id)) |s| removeSessionForTest(s);

    mutexLock(&stale.mutex);
    stale.last_user_active_s = nowSeconds() - 3600;
    stale.last_active_s = nowSeconds() - 3600;
    stale.last_output_at_s = 0;
    stale.mutex.unlock();
    mutexLock(&busy.mutex);
    busy.last_user_active_s = nowSeconds() - 3600;
    busy.last_active_s = nowSeconds();
    busy.last_output_at_s = nowSeconds();
    busy.mutex.unlock();

    // No manager on this socket, so a reaped session's `tty close` is a no-op
    // that cannot reach a VM; the sweep decision is what this asserts.
    sweepIdle(testing.allocator, "/nonexistent/pabrik-vmd.sock");
    try testing.expect(getSession(stale_id) == null);
    try testing.expect(getSession(busy_id) != null);
}

test "the guest list holds the caller's own shells, with their workspace" {
    const mine = try insertSessionForTest("ws_1", "user_a");
    defer removeSessionForTest(mine);
    const theirs = try insertSessionForTest("ws_2", "user_b");
    defer removeSessionForTest(theirs);

    const rows = try listSessionsForOwner(testing.allocator, "user_a");
    defer terminal_session.freeSessionSummaries(testing.allocator, rows);

    var found = false;
    for (rows) |row| {
        try testing.expect(!std.mem.eql(u8, row.id, theirs.id));
        if (!std.mem.eql(u8, row.id, mine.id)) continue;
        found = true;
        try testing.expectEqualStrings("ws_1", row.workspace_id);
        try testing.expectEqualStrings(backend_guest_pty, row.backend);
        try testing.expectEqual(@as(u16, terminal_session.default_cols), row.cols);
    }
    try testing.expect(found);
}
