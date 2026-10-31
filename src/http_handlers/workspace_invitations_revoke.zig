//! `DELETE /api/workspaces/:workspace_id/invitations/:invitation_id` — an
//! owner/admin withdraws an ask nobody has answered.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");

pub const InvitationsRevokeError = gate.GateError || error{
    InvitationNotFound,
    DeleteFailed,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    invitation_id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) InvitationsRevokeError!void {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, workspace_id, caller, .manage) catch |err| return err;

    store.revoke(allocator, db, .{
        .invitation_id = invitation_id,
        .workspace_id = workspace_id,
    }) catch |err| switch (err) {
        error.NotFound => return error.InvitationNotFound,
        error.DeleteFailed => return error.DeleteFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn statusFor(err: InvitationsRevokeError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired => 400,
        error.WorkspaceNotFound, error.InvitationNotFound => 404,
        error.Forbidden => 403,
        error.DeleteFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: InvitationsRevokeError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.WorkspaceNotFound => "Workspace not found",
        error.InvitationNotFound => "Invitation not found",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.DeleteFailed, error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn workspaceInvitationsRevokeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const invitation_id = req.params.get("invitation_id") orelse "";

    useCase(
        allocator,
        di.db,
        req.params.get("workspace_id") orelse "",
        invitation_id,
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .success = true,
        .id = invitation_id,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
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
        \\CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at TIMESTAMP, invited_by TEXT, PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_invitations (
        \\  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, invitee_user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer', invited_by TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme'), ('ws_2', 'Beta')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'), ('user_ben', 'ben@example.com', 'Ben')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_1', 'user_amy', 'owner')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by) VALUES
        \\  ('inv_1', 'ws_1', 'user_ben', 'editor', 'user_amy'),
        \\  ('inv_2', 'ws_2', 'user_ben', 'viewer', 'user_amy')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, workspace_id: []const u8, invitation_id: []const u8) InvitationsRevokeError!void {
    return useCase(testing.allocator, &ctx.db, workspace_id, invitation_id, false, NoCookie{});
}

fn pendingCount(ctx: *TestCtx, workspace_id: []const u8) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COUNT(*) FROM workspace_invitations WHERE workspace_id = ?",
        &[_][]const u8{workspace_id},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return std.fmt.parseInt(u64, r.values[0], 10);
}

test "useCase revokes this workspace's invitation and leaves the other workspace's alone" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try run(&ctx, "ws_1", "inv_1");
    try testing.expectEqual(@as(u64, 0), try pendingCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try pendingCount(&ctx, "ws_2"));
}

test "useCase answers 404 when the invitation belongs to another workspace" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Revoking ws_2's invitation THROUGH ws_1 is not a cross-tenant delete.
    try testing.expectError(error.InvitationNotFound, run(&ctx, "ws_1", "inv_2"));
    try testing.expectEqual(@as(u16, 404), statusFor(error.InvitationNotFound));
    try testing.expectEqual(@as(u64, 1), try pendingCount(&ctx, "ws_2"));
}
