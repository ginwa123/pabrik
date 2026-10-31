//! The permission gate for `/api/workspaces/:id/members`: an invisible
//! workspace is a 404 (as `workspace_delete.zig` answers), a visible one the
//! caller may not administer is a 403.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const auth_common = @import("auth_common.zig");
const store = @import("../agentic_loop/workspace_members_store.zig");

pub const Access = enum {
    /// Any member of the workspace.
    read,
    /// `owner` or `admin` only.
    manage,
};

pub const GateError = error{
    WorkspaceIdRequired,
    /// Not visible to this caller. Never distinguished from "does not exist".
    WorkspaceNotFound,
    Forbidden,
    QueryFailed,
    OutOfMemory,
};

/// The caller's user id, resolved server-side from the session cookie.
pub fn callerFor(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    auth_enabled: bool,
    headers: anytype,
) GateError![]const u8 {
    return auth_common.resolveRequestUserId(allocator, db, auth_enabled, headers) catch error.OutOfMemory;
}

pub fn check(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    caller: []const u8,
    access: Access,
) GateError!void {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (!auth_common.canSeeWorkspace(allocator, db, workspace_id, caller)) return error.WorkspaceNotFound;

    // `user_system` is the installation owner (auth off). It holds no member
    // row of its own on a modern workspace, so it short-circuits here.
    if (std.mem.eql(u8, caller, auth_common.system_user_id)) return;

    const role = store.callerRole(allocator, db, workspace_id, caller) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };

    const allowed = switch (access) {
        // Membership — not mere visibility. A workspace shared through a
        // `user_system` row is visible to everyone, and its member list is
        // every member's email address.
        .read => role != null,
        .manage => if (role) |r| r.canManageMembers() else false,
    };
    if (!allowed) return error.Forbidden;
}

pub fn statusFor(err: GateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired => 400,
        error.WorkspaceNotFound => 404,
        error.Forbidden => 403,
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

pub fn messageFor(err: GateError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.WorkspaceNotFound => "Workspace not found",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const database = pabrikcore.database;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  user_id TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL,
        \\  user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at TIMESTAMP,
        \\  invited_by TEXT,
        \\  PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspaces (id, name, user_id) VALUES
        \\  ('ws_private', 'Private', 'user_amy'),
        \\  ('ws_shared', 'Shared', 'user_system')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_private', 'user_amy', 'owner'),
        \\  ('ws_private', 'user_ben', 'admin'),
        \\  ('ws_private', 'user_cid', 'editor'),
        \\  ('ws_private', 'user_dan', 'viewer'),
        \\  ('ws_shared', 'user_system', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "check lets any member read the list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "user_amy", "user_ben", "user_cid", "user_dan" }) |caller| {
        try check(alloc, &ctx.db, "ws_private", caller, .read);
    }
}

test "check lets only owner and admin manage the list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try check(alloc, &ctx.db, "ws_private", "user_amy", .manage);
    try check(alloc, &ctx.db, "ws_private", "user_ben", .manage);

    // An editor can read the workspace's documents; that is not a licence to
    // hand it to someone else.
    try testing.expectError(error.Forbidden, check(alloc, &ctx.db, "ws_private", "user_cid", .manage));
    try testing.expectError(error.Forbidden, check(alloc, &ctx.db, "ws_private", "user_dan", .manage));
}

test "check answers WorkspaceNotFound to a caller who cannot see the workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.WorkspaceNotFound, check(alloc, &ctx.db, "ws_private", "user_zoe", .read));
    try testing.expectError(error.WorkspaceNotFound, check(alloc, &ctx.db, "ws_missing", "user_amy", .read));
    try testing.expectEqual(@as(u16, 404), statusFor(error.WorkspaceNotFound));
}

test "check refuses management of a shared workspace to a non-member, even though it is visible" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The `user_system` member row makes ws_shared visible to everybody.
    try testing.expect(auth_common.canSeeWorkspace(alloc, &ctx.db, "ws_shared", "user_amy"));
    // …and still not manageable by them: the member list is email addresses.
    try testing.expectError(error.Forbidden, check(alloc, &ctx.db, "ws_shared", "user_amy", .read));
    try testing.expectError(error.Forbidden, check(alloc, &ctx.db, "ws_shared", "user_amy", .manage));
    try testing.expectEqual(@as(u16, 403), statusFor(error.Forbidden));
}

test "check treats the installation owner as able to do everything" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Auth off: the caller IS the installation owner, and there is no member
    // row naming it on a workspace that was never shared.
    try check(alloc, &ctx.db, "ws_private", auth_common.system_user_id, .manage);
    try check(alloc, &ctx.db, "ws_shared", auth_common.system_user_id, .manage);
}

test "check answers WorkspaceIdRequired for an empty id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.WorkspaceIdRequired, check(alloc, &ctx.db, "", "user_amy", .read));
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
}

test "the gate's messages never name another user" {
    // A 403 body that named the owner would turn the gate into a directory.
    try testing.expect(std.mem.indexOf(u8, messageFor(error.Forbidden), "user_") == null);
    try testing.expect(std.mem.indexOf(u8, messageFor(error.WorkspaceNotFound), "ws_") == null);
}
