//! `POST /api/invitations/:invitation_id/accept` — the invitee says yes, and
//! THIS is the only place a membership row appears out of an invitation.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");
const members = @import("../agentic_loop/workspace_members_store.zig");

pub const InvitationsAcceptError = error{
    InvitationIdRequired,
    InvitationNotFound,
    AlreadyMember,
    InsertFailed,
    DeleteFailed,
    QueryFailed,
    OutOfMemory,
};

pub const InvitationsAcceptOutput = struct {
    member: members.MemberRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    invitation_id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) InvitationsAcceptError!InvitationsAcceptOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };
    defer allocator.free(caller);

    const member = store.accept(allocator, db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = caller,
    }) catch |err| switch (err) {
        error.InvitationIdRequired => return error.InvitationIdRequired,
        // Somebody else's invitation and a missing one answer the same way.
        error.NotFound => return error.InvitationNotFound,
        error.AlreadyMember => return error.AlreadyMember,
        error.InsertFailed => return error.InsertFailed,
        error.DeleteFailed => return error.DeleteFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return .{ .member = member };
}

fn statusFor(err: InvitationsAcceptError) u16 {
    return switch (err) {
        error.InvitationIdRequired => 400,
        error.InvitationNotFound => 404,
        error.AlreadyMember => 409,
        error.InsertFailed, error.DeleteFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: InvitationsAcceptError) []const u8 {
    return switch (err) {
        error.InvitationIdRequired => "invitation_id required",
        error.InvitationNotFound => "Invitation not found",
        error.AlreadyMember => "you are already a member of that workspace",
        error.InsertFailed, error.DeleteFailed => "DB error",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn invitationsAcceptHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const output = useCase(
        allocator,
        di.db,
        req.params.get("invitation_id") orelse "",
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer members.freeMemberRow(allocator, output.member);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .member = http_response.makeWorkspaceMemberResponse(output.member),
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
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'), ('user_ben', 'ben@example.com', 'Ben')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_1', 'user_amy', 'owner')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by)
        \\VALUES ('inv_1', 'ws_1', 'user_ben', 'editor', 'user_amy')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, invitation_id: []const u8) InvitationsAcceptError!InvitationsAcceptOutput {
    return useCase(testing.allocator, &ctx.db, invitation_id, false, NoCookie{});
}

fn pendingCount(ctx: *TestCtx) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_invitations", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return std.fmt.parseInt(u64, r.values[0], 10);
}

test "useCase answers 404 for an invitation that is not the caller's" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // The installation owner is not `inv_1`'s invitee, so the row is invisible
    // to them — the same concealment a foreign workspace gets.
    try testing.expectError(error.InvitationNotFound, run(&ctx, "inv_1"));
    try testing.expectEqual(@as(u16, 404), statusFor(error.InvitationNotFound));
    try testing.expectEqualStrings("Invitation not found", messageFor(error.InvitationNotFound));
    try testing.expectEqual(@as(u64, 1), try pendingCount(&ctx));
}

test "useCase answers 400 for an empty invitation id" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.InvitationIdRequired, run(&ctx, ""));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvitationIdRequired));
}

test "accept is a 409 once the account is already a member" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A second owner promotes the invitee while the ask is still pending.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_1', 'user_ben', 'viewer')
    , &.{});
    const accepted = store.accept(alloc, &ctx.db, .{
        .invitation_id = "inv_1",
        .invitee_user_id = "user_ben",
    });
    try testing.expectError(error.AlreadyMember, accepted);
    try testing.expectEqual(@as(u16, 409), statusFor(error.AlreadyMember));
}
