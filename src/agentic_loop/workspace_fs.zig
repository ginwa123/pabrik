//! The host side of a tenant file: map an absolute host path onto the guest's
//! `/workspace` and read it through `pabrik-vmd`. Local mode installs nothing —
//! a caller asks `forSession` and keeps today's behaviour on a null answer.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const runtime_mode = @import("../runtime_mode.zig");
const workspace_scope = @import("workspace_scope.zig");
const vmd = @import("../vmd/vmd_client.zig");
const policy = @import("../vmd/policy.zig");
const fs_policy = @import("../vmd/fs_policy.zig");

pub const Error = error{
    GuestWorkspaceUnknown,
    GuestPathOutsideWorkspace,
    GuestManagerUnavailable,
    GuestManagerRefused,
    GuestFileMissing,
};

/// Which guest file an absolute host path names. There is no host filesystem
/// behind this: `root` is only the string the DB records, and every byte comes
/// back over the RPC.
pub const Fs = struct {
    allocator: std.mem.Allocator,
    workspace_id: []u8,
    root: []u8,
    socket: []u8,

    pub fn deinit(self: *Fs) void {
        self.allocator.free(self.workspace_id);
        self.allocator.free(self.root);
        self.allocator.free(self.socket);
    }

    /// The path relative to the workspace root, or null when `abs` is not under
    /// it. Borrows from `abs`, so the caller keeps owning its own string.
    pub fn relative(self: *const Fs, abs: []const u8) ?[]const u8 {
        const rel = policy.relativeToRoot(self.root, abs) orelse return null;
        if (!fs_policy.pathRelValid(rel)) return null;
        return rel;
    }

    /// The whole file, read in bounded pieces until the guest says `eof`. The
    /// host never opens it, so the only copy is the one in this allocation.
    pub fn readAll(self: *const Fs, abs: []const u8) ![]u8 {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var offset: i64 = 0;
        while (true) {
            const chunk = client.readFile(self.workspace_id, rel, offset, vmd_read_chunk) catch |err| {
                return managerError(err);
            };
            defer chunk.deinit(self.allocator);
            if (chunk.missing) return Error.GuestFileMissing;
            try out.appendSlice(self.allocator, chunk.bytes);
            if (chunk.eof or chunk.bytes.len == 0) break;
            offset += @intCast(chunk.bytes.len);
            if (out.items.len > fs_policy.max_read_bytes) return error.FileTooBig;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// One file, or one empty directory. A missing path is an error, not a
    /// silent success: the tool reports "nothing there" from its own answer.
    pub fn remove(self: *const Fs, abs: []const u8) !void {
        const rel = self.relative(abs) orelse return Error.GuestPathOutsideWorkspace;
        var client = vmd.Client.init(self.allocator, self.socket);
        client.removeFile(self.workspace_id, rel) catch |err| return managerError(err);
    }
};

/// The guest's per-reply ceiling. Matches the daemon's default so a caller
/// asking for more does not simply get refused.
const vmd_read_chunk: usize = 64 * 1024;

/// The guest filesystem for a session, or null when files belong on the host.
/// Fails closed: `--saas` with no resolvable workspace is an error, never a
/// quiet fall back to reading the host.
pub fn forSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?Fs {
    if (!runtime_mode.vm_backend_available) return null;
    if (runtime_mode.currentMode() != .saas) return null;

    const workspace_id = (try workspace_scope.resolveWorkspaceId(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    errdefer allocator.free(workspace_id);
    const root = (try workspace_scope.resolveWorkspaceRoot(allocator, db, session_id)) orelse
        return Error.GuestWorkspaceUnknown;
    errdefer allocator.free(root);
    const socket = runtime_mode.socketPath() orelse return Error.GuestManagerUnavailable;
    const socket_copy = try allocator.dupe(u8, socket);
    return .{
        .allocator = allocator,
        .workspace_id = workspace_id,
        .root = root,
        .socket = socket_copy,
    };
}

fn managerError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectFailed, error.SocketFailed, error.IoFailed, error.Timeout => Error.GuestManagerUnavailable,
        error.ServerFailure => Error.GuestManagerRefused,
        else => err,
    };
}

// ============================================================================
// Behaviour tests — the pure half. A live VM is the smoke scripts' job.
// ============================================================================

const testing = std.testing;

const GuestTestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *GuestTestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn guestTestCtx() !GuestTestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(testing.allocator,
        \\CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL, status TEXT, cwd TEXT, workspace_id TEXT)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER)
    , &.{});
    try db.exec(testing.allocator,
        \\CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('i1','w1','kanban','A','/proj/a',1)
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s1','T1','i1')
    , &.{});
    try db.exec(testing.allocator,
        \\INSERT INTO sessions (id, name, status, cwd) VALUES ('s1','Task one','active','/proj/a')
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

fn testFs(root: []const u8) Fs {
    return .{
        .allocator = testing.allocator,
        .workspace_id = @constCast("w1"),
        .root = @constCast(root),
        .socket = @constCast("/nonexistent.sock"),
    };
}

test "relative: a path under the root maps, anything else is refused" {
    const fs = testFs("/proj/a");
    try testing.expectEqualStrings("src/main.zig", fs.relative("/proj/a/src/main.zig").?);
    try testing.expectEqualStrings("a.txt", fs.relative("/proj/a/a.txt").?);

    try testing.expect(fs.relative("/proj/a") == null);
    try testing.expect(fs.relative("/proj/ab/a.txt") == null);
    try testing.expect(fs.relative("/etc/passwd") == null);
    try testing.expect(fs.relative("/proj/a/../b") == null);
}

test "relative: a host path is never handed to the guest absolute" {
    const fs = testFs("/proj/a/");
    const rel = fs.relative("/proj/a/deep/file.txt").?;
    try testing.expect(!std.mem.startsWith(u8, rel, "/"));
    try testing.expect(std.mem.indexOf(u8, rel, "proj") == null);
}

test "forSession: local mode installs no guest filesystem at all" {
    try testing.expectEqual(runtime_mode.Mode.local, runtime_mode.currentMode());
    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expect((try forSession(testing.allocator, &ctx.db, "s1")) == null);
}

test "forSession: saas with a workspace but no manager refuses rather than falls back" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    var ctx = try guestTestCtx();
    defer ctx.deinit();
    runtime_mode.setManagerSocket(null);
    defer runtime_mode.setManagerSocket(null);
    try testing.expectError(Error.GuestManagerUnavailable, forSession(testing.allocator, &ctx.db, "s1"));
}

test "forSession: saas with no resolvable workspace fails closed" {
    runtime_mode.setCurrent(.saas);
    defer runtime_mode.setCurrent(.local);
    if (!runtime_mode.vm_backend_available) return;

    var ctx = try guestTestCtx();
    defer ctx.deinit();
    try testing.expectError(Error.GuestWorkspaceUnknown, forSession(testing.allocator, &ctx.db, "no-such-session"));
}

test "readAll: a path outside the workspace is refused before any RPC" {
    const fs = testFs("/proj/a");
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.readAll("/etc/passwd"));
    try testing.expectError(Error.GuestPathOutsideWorkspace, fs.remove("/etc/passwd"));
}
