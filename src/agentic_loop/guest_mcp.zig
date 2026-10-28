//! The host half of an MCP server that runs in the tenant's VM: who may open a
//! duplex, and the channel that carries its bytes. Local mode installs
//! nothing — a caller asks `route` and keeps today's child-pipe transport.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const database = pabrikcore.database;
const mcp_stdio = pabrikcore.mcp_stdio;
const mcp_scope = pabrikcore.mcp_scope;
const runtime_mode = @import("../runtime_mode.zig");
const workspace_vm = @import("workspace_vm.zig");
const vmd = @import("../vmd/vmd_client.zig");
const policy = @import("../vmd/policy.zig");

pub const Error = error{
    GuestWorkspaceUnknown,
    /// The workspace is not VM-backed: no Firecracker, no host fallback.
    GuestWorkspaceNotVm,
    GuestManagerUnavailable,
    GuestOpenRefused,
};

/// Where an MCP server's process lives. `host` is every local install; `guest`
/// is a duplex in the tenant's VM; `unavailable` is a `--saas` process that
/// cannot reach it, which is never a quiet fall back to the host.
pub const Route = union(enum) {
    host,
    guest: Target,
    unavailable: anyerror,

    pub fn deinit(self: *Route) void {
        switch (self.*) {
            .guest => |*target| target.deinit(),
            else => {},
        }
    }
};

/// A tenant's VM, named by the workspace and the daemon's socket. Owns both
/// strings, so it outlives the request that resolved it.
pub const Target = struct {
    allocator: std.mem.Allocator,
    workspace_id: []u8,
    socket: []u8,

    pub fn deinit(self: *Target) void {
        self.allocator.free(self.workspace_id);
        self.allocator.free(self.socket);
    }
};

/// Which workspace a session's MCP servers belong to.
pub const Session = struct {
    db: ?*database.Db,
    workspace_id: []const u8,
};

/// The route for one session, decided by the placement and nothing else.
pub fn route(
    allocator: std.mem.Allocator,
    placement: workspace_vm.McpPlacement,
    session: Session,
) Route {
    if (placement == .host) return .host;
    if (session.workspace_id.len == 0) return .{ .unavailable = Error.GuestWorkspaceUnknown };
    if (!policy.workspaceIdValid(session.workspace_id)) return .{ .unavailable = Error.GuestWorkspaceUnknown };
    const db = session.db orelse return .{ .unavailable = Error.GuestWorkspaceUnknown };
    if (!workspace_vm.isVmWorkspace(allocator, db, session.workspace_id)) {
        return .{ .unavailable = Error.GuestWorkspaceNotVm };
    }
    const socket = runtime_mode.socketPath() orelse return .{ .unavailable = Error.GuestManagerUnavailable };
    const workspace_copy = allocator.dupe(u8, session.workspace_id) catch return .{ .unavailable = error.OutOfMemory };
    const socket_copy = allocator.dupe(u8, socket) catch {
        allocator.free(workspace_copy);
        return .{ .unavailable = error.OutOfMemory };
    };
    return .{ .guest = .{
        .allocator = allocator,
        .workspace_id = workspace_copy,
        .socket = socket_copy,
    } };
}

/// One duplex in a tenant's VM, seen as a pair of byte streams.
const Duplex = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket: []u8,
    workspace_id: []u8,
    duplex_id: i64,
    closed: bool = false,

    fn channel(self: *Duplex) mcp_stdio.Channel {
        return .{ .io = self.io, .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn read(ctx: *anyopaque, dst: []u8) mcp_stdio.Channel.ChannelError!mcp_stdio.Channel.ReadResult {
        const self: *Duplex = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        if (dst.len == 0) return .{ .n = 0 };
        var client = vmd.Client.init(self.allocator, self.socket);
        const chunk = client.duplexRead(
            self.workspace_id,
            self.duplex_id,
            @min(dst.len, policy.max_duplex_chunk),
        ) catch |err| switch (err) {
            // The guest host answers "nothing listening" as an EOF, so a
            // connect failure here is the daemon, not the server.
            error.Timeout => return error.NothingYet,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Closed,
        };
        defer chunk.deinit(self.allocator);
        if (chunk.data.len > 0) {
            const n = @min(dst.len, chunk.data.len);
            @memcpy(dst[0..n], chunk.data[0..n]);
            return .{ .n = n };
        }
        if (chunk.eof or chunk.exited) return .{ .n = 0, .eof = true };
        return error.NothingYet;
    }

    fn write(ctx: *anyopaque, bytes: []const u8) mcp_stdio.Channel.ChannelError!void {
        const self: *Duplex = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        var client = vmd.Client.init(self.allocator, self.socket);
        var off: usize = 0;
        while (off < bytes.len) {
            const end = @min(off + policy.max_duplex_chunk, bytes.len);
            const taken = client.duplexWrite(self.workspace_id, self.duplex_id, bytes[off..end]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Closed,
            };
            if (taken == 0) return error.Closed;
            off += taken;
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *Duplex = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        var client = vmd.Client.init(self.allocator, self.socket);
        client.duplexClose(self.workspace_id, self.duplex_id) catch {};
        self.allocator.free(self.socket);
        self.allocator.free(self.workspace_id);
        self.allocator.destroy(self);
    }
};

const vtable = mcp_stdio.Channel.VTable{
    .read = Duplex.read,
    .write = Duplex.write,
    .close = Duplex.close,
};

/// The opener the guest registry uses: one duplex per server, opened through
/// the daemon and addressed by the id the guest minted.
pub fn openChannel(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: mcp_stdio.GuestTarget,
    name: []const u8,
    argv: []const []const u8,
) anyerror!mcp_stdio.Channel {
    _ = name;
    if (target.workspace_id.len == 0 or target.socket.len == 0) return Error.GuestWorkspaceUnknown;
    if (!policy.workspaceIdValid(target.workspace_id)) return Error.GuestWorkspaceUnknown;
    if (argv.len == 0) return Error.GuestOpenRefused;

    const cwd = try policy.guestCwd(allocator, policy.guest_root, "");
    defer allocator.free(cwd);

    var client = vmd.Client.init(allocator, target.socket);
    const opened = client.duplexOpen(target.workspace_id, cwd, argv) catch return Error.GuestOpenRefused;

    const handle = try allocator.create(Duplex);
    errdefer allocator.destroy(handle);
    const socket_copy = try allocator.dupe(u8, target.socket);
    errdefer allocator.free(socket_copy);
    const workspace_copy = try allocator.dupe(u8, target.workspace_id);
    errdefer allocator.free(workspace_copy);
    handle.* = .{
        .allocator = allocator,
        .io = io,
        .socket = socket_copy,
        .workspace_id = workspace_copy,
        .duplex_id = opened.duplex_id,
    };
    return handle.channel();
}

// ============================================================================
// The transport a call runs on, whichever side of the seam it lives
// ============================================================================

/// `StdioClient` and `GuestStdioClient` have the same three calls; this is
/// what lets a call site stay transport-agnostic.
pub const Transport = union(enum) {
    stdio: *mcp_stdio.StdioClient,
    guest: *mcp_stdio.GuestStdioClient,

    pub fn send(
        self: Transport,
        body: []const u8,
        deadline_ns: u64,
        is_cancelled: ?*const fn () bool,
    ) !void {
        return switch (self) {
            .stdio => |client| client.sendNDJSON(body, deadline_ns, is_cancelled),
            .guest => |client| client.sendNDJSON(body, deadline_ns, is_cancelled),
        };
    }

    pub fn recv(self: Transport, deadline_ns: u64, is_cancelled: ?*const fn () bool) ![]u8 {
        return switch (self) {
            .stdio => |client| client.recv(deadline_ns, is_cancelled),
            .guest => |client| client.recv(deadline_ns, is_cancelled),
        };
    }

    /// Where a response body was allocated, so the caller frees it in the same
    /// arena that produced it.
    pub fn allocator(self: Transport) std.mem.Allocator {
        return switch (self) {
            .stdio => |client| client.allocator(),
            .guest => |client| client.allocator(),
        };
    }
};

/// The lease a call holds on its server, on whichever transport it runs.
pub const Held = union(enum) {
    stdio: mcp_stdio.Lease,
    guest: mcp_stdio.GuestLease,

    pub fn transport(self: Held) Transport {
        return switch (self) {
            .stdio => |lease| .{ .stdio = lease.client() },
            .guest => |lease| .{ .guest = lease.client() },
        };
    }

    /// Flag the server for replacement: the next `acquire` respawns a child or
    /// reopens a duplex instead of handing back the same broken one.
    pub fn markStale(self: Held) void {
        switch (self) {
            .stdio => |lease| lease.markStale(),
            .guest => |lease| lease.markStale(),
        }
    }

    pub fn release(self: *Held) void {
        switch (self.*) {
            .stdio => |*lease| lease.release(),
            .guest => |*lease| lease.release(),
        }
    }
};

pub const LeaseOptions = struct {
    /// How long to wait for another caller's in-flight transaction. Never 0:
    /// `AcquireOptions`' 0 means "wait forever", which parks a neighbour.
    wait_ns: u64,
    is_cancelled: ?*const fn () bool = null,
    scope: mcp_scope.Scope = .{},
};

/// Hold `server_name` on the transport the route names. This is the ONE place
/// host-versus-guest is decided, so no call site can forget the rule.
pub fn acquire(
    allocator: std.mem.Allocator,
    io: ?std.Io,
    route_value: Route,
    server_name: []const u8,
    argv: []const []const u8,
    opts: LeaseOptions,
) !Held {
    switch (route_value) {
        .host => {
            const registry = pabrikcore.mcpStdioRegistry(allocator);
            const lease = try registry.acquire(server_name, argv, .{
                .wait_ns = opts.wait_ns,
                .is_cancelled = opts.is_cancelled,
                .scope = opts.scope,
            });
            return .{ .stdio = lease };
        },
        .guest => |target| {
            const io_value = io orelse return Error.GuestManagerUnavailable;
            // Through the singleton so the registry outlives the per-turn
            // arena that a tool call's `allocator` may be.
            const registry = pabrikcore.mcpGuestRegistry(io_value, openChannel, allocator);
            const lease = try registry.acquire(server_name, argv, .{
                .wait_ns = opts.wait_ns,
                .is_cancelled = opts.is_cancelled,
                .scope = opts.scope,
                .target = .{ .workspace_id = target.workspace_id, .socket = target.socket },
            });
            return .{ .guest = lease };
        },
        .unavailable => |err| return err,
    }
}

// ============================================================================
// Behaviour tests — the route table. A live VM is the smoke scripts' job.
// ============================================================================

const testing = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn testCtx() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(testing.allocator,
        \\CREATE TABLE workspaces (id TEXT PRIMARY KEY, is_vm INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspaces (id, is_vm) VALUES ('ws_vm', 1), ('ws_host', 0)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "local mode keeps MCP on the host and installs no guest target" {
    try testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    var route_value = route(testing.allocator, .host, .{ .db = null, .workspace_id = "" });
    defer route_value.deinit();
    try testing.expectEqual(Route.host, route_value);
}

test "saas with a VM workspace resolves that workspace's own daemon socket" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    runtime_mode.setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    var ctx = try testCtx();
    defer ctx.deinit();

    var route_value = route(testing.allocator, .guest, .{ .db = &ctx.db, .workspace_id = "ws_vm" });
    defer route_value.deinit();
    switch (route_value) {
        .guest => |target| {
            try testing.expectEqualStrings("ws_vm", target.workspace_id);
            try testing.expectEqualStrings("/run/user/1000/pabrik-vmd.sock", target.socket);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "saas refuses a workspace that is not VM-backed instead of using the host" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    runtime_mode.setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    var ctx = try testCtx();
    defer ctx.deinit();

    var route_value = route(testing.allocator, .guest, .{ .db = &ctx.db, .workspace_id = "ws_host" });
    defer route_value.deinit();
    try testing.expectEqual(Error.GuestWorkspaceNotVm, route_value.unavailable);
}

test "saas with no session, no database or no manager refuses rather than falls back" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    runtime_mode.setManagerSocket("/run/user/1000/pabrik-vmd.sock");
    defer runtime_mode.setManagerSocket(null);

    var ctx = try testCtx();
    defer ctx.deinit();

    var no_session = route(testing.allocator, .guest, .{ .db = &ctx.db, .workspace_id = "" });
    defer no_session.deinit();
    try testing.expectEqual(Error.GuestWorkspaceUnknown, no_session.unavailable);

    var no_db = route(testing.allocator, .guest, .{ .db = null, .workspace_id = "ws_vm" });
    defer no_db.deinit();
    try testing.expectEqual(Error.GuestWorkspaceUnknown, no_db.unavailable);

    var hostile = route(testing.allocator, .guest, .{ .db = &ctx.db, .workspace_id = "../../etc" });
    defer hostile.deinit();
    try testing.expectEqual(Error.GuestWorkspaceUnknown, hostile.unavailable);

    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);
    var no_manager = route(testing.allocator, .guest, .{ .db = &ctx.db, .workspace_id = "ws_vm" });
    defer no_manager.deinit();
    try testing.expectEqual(Error.GuestManagerUnavailable, no_manager.unavailable);
}

test "an opener with no workspace, no socket or no argv refuses before any RPC" {
    try testing.expectError(
        Error.GuestWorkspaceUnknown,
        openChannel(testing.allocator, testing.io, .{ .workspace_id = "", .socket = "/tmp/s.sock" }, "s", &.{"server"}),
    );
    try testing.expectError(
        Error.GuestWorkspaceUnknown,
        openChannel(testing.allocator, testing.io, .{ .workspace_id = "ws_1", .socket = "" }, "s", &.{"server"}),
    );
    try testing.expectError(
        Error.GuestWorkspaceUnknown,
        openChannel(testing.allocator, testing.io, .{ .workspace_id = "../etc", .socket = "/tmp/s.sock" }, "s", &.{"server"}),
    );
    try testing.expectError(
        Error.GuestOpenRefused,
        openChannel(testing.allocator, testing.io, .{ .workspace_id = "ws_1", .socket = "/tmp/s.sock" }, "s", &.{}),
    );
}
