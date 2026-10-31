//! `POST /api/workspaces/:workspace_id/invitations` — ask an existing account
//! to join. This writes NO membership: the invitee accepts or declines first.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");
const members = @import("../agentic_loop/workspace_members_store.zig");

const InviteBody = struct {
    email: []const u8 = "",
    role: []const u8 = "",
};

pub const InvitationsCreateError = gate.GateError || error{
    EmailRequired,
    InvalidRole,
    UserNotFound,
    AlreadyMember,
    AlreadyInvited,
    ReservedUser,
    InsertFailed,
};

pub const InvitationsCreateOutput = struct {
    invitation: store.InvitationRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    body: InviteBody,
    auth_enabled: bool,
    headers: anytype,
) InvitationsCreateError!InvitationsCreateOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, workspace_id, caller, .manage) catch |err| return err;

    const role: members.Role = if (body.role.len == 0)
        .viewer
    else
        members.parseRole(body.role) orelse return error.InvalidRole;

    const invitation = store.invite(allocator, db, .{
        .workspace_id = workspace_id,
        .email = body.email,
        .role = role,
        .invited_by = caller,
    }) catch |err| switch (err) {
        error.EmailRequired => return error.EmailRequired,
        error.NotFound => return error.UserNotFound,
        error.AlreadyMember => return error.AlreadyMember,
        error.AlreadyInvited => return error.AlreadyInvited,
        error.ReservedUser => return error.ReservedUser,
        error.InsertFailed => return error.InsertFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // Answering and revoking are the only paths that produce these.
        else => unreachable,
    };
    return .{ .invitation = invitation };
}

fn statusFor(err: InvitationsCreateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.EmailRequired, error.InvalidRole, error.ReservedUser => 400,
        error.WorkspaceNotFound, error.UserNotFound => 404,
        error.Forbidden => 403,
        error.AlreadyMember, error.AlreadyInvited => 409,
        error.InsertFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

/// `email` is echoed only for the 404, so the form can say WHICH address found
/// no account instead of "not found".
fn messageFor(
    err: InvitationsCreateError,
    allocator: std.mem.Allocator,
    email: []const u8,
) ![]const u8 {
    return switch (err) {
        error.EmailRequired => "email is required",
        error.InvalidRole => "role must be owner, admin, editor or viewer",
        error.UserNotFound => try std.fmt.allocPrint(
            allocator,
            "no active account with the email '{s}'",
            .{std.mem.trim(u8, email, " \t\n\r")},
        ),
        error.AlreadyMember => "that account is already a member of this workspace",
        error.AlreadyInvited => "that account already has a pending invitation to this workspace",
        error.ReservedUser => "the shared system account cannot be invited",
        error.WorkspaceIdRequired => "workspace_id required",
        error.WorkspaceNotFound => "Workspace not found",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.InsertFailed, error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn workspaceInvitationsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    var body = InviteBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(InviteBody, allocator, req.body, .{}) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
    }

    const output = useCase(
        allocator,
        di.db,
        req.params.get("workspace_id") orelse "",
        body,
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = try messageFor(err, allocator, body.email) },
            ),
        });
    };
    defer store.freeInvitationRow(allocator, output.invitation);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .invitation = http_response.makeWorkspaceInvitationResponse(output.invitation),
    }, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
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
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  is_active INTEGER NOT NULL DEFAULT 1
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
        \\CREATE TABLE workspace_invitations (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  invitee_user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer',
        \\  invited_by TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben'),
        \\  ('user_system', 'system@local', 'System')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_1', 'user_amy', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, body: InviteBody) InvitationsCreateError!InvitationsCreateOutput {
    return useCase(testing.allocator, &ctx.db, "ws_1", body, false, NoCookie{});
}

fn counts(ctx: *TestCtx) !struct { invitations: u64, members: u64 } {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT (SELECT COUNT(*) FROM workspace_invitations), (SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_1')",
        &.{},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return .{
        .invitations = try std.fmt.parseInt(u64, r.values[0], 10),
        .members = try std.fmt.parseInt(u64, r.values[1], 10),
    };
}

test "useCase creates a pending invitation and grants NO membership" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com", .role = "editor" });
    defer store.freeInvitationRow(alloc, out.invitation);

    try testing.expectEqualStrings("user_ben", out.invitation.invitee_user_id);
    try testing.expectEqualStrings("editor", out.invitation.role);
    try testing.expectEqualStrings("user_system", out.invitation.invited_by);

    const after = try counts(&ctx);
    try testing.expectEqual(@as(u64, 1), after.invitations);
    // The invitee is not a member until they accept — this is the requirement.
    try testing.expectEqual(@as(u64, 1), after.members);
}

test "useCase defaults an omitted role to viewer, never to a managing role" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com" });
    defer store.freeInvitationRow(alloc, out.invitation);
    try testing.expectEqualStrings("viewer", out.invitation.role);
}

test "useCase answers a 404 naming the address when no account carries it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.UserNotFound, run(&ctx, .{ .email = "ghost@example.com" }));
    try testing.expectEqual(@as(u16, 404), statusFor(error.UserNotFound));

    const message = try messageFor(error.UserNotFound, alloc, " ghost@example.com ");
    defer alloc.free(message);
    try testing.expectEqualStrings("no active account with the email 'ghost@example.com'", message);
}

test "useCase answers 400 for a blank email and for a role the column cannot hold" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.EmailRequired, run(&ctx, .{ .email = "   " }));
    try testing.expectError(error.InvalidRole, run(&ctx, .{ .email = "ben@example.com", .role = "emperor" }));
    try testing.expectEqual(@as(u16, 400), statusFor(error.EmailRequired));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidRole));

    const after = try counts(&ctx);
    try testing.expectEqual(@as(u64, 0), after.invitations);
}

test "useCase answers 409 for an existing member and for a duplicate invitation" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.AlreadyMember, run(&ctx, .{ .email = "amy@example.com" }));

    const first = try run(&ctx, .{ .email = "ben@example.com" });
    defer store.freeInvitationRow(alloc, first.invitation);
    try testing.expectError(error.AlreadyInvited, run(&ctx, .{ .email = "ben@example.com", .role = "admin" }));
    try testing.expectEqual(@as(u16, 409), statusFor(error.AlreadyInvited));

    const after = try counts(&ctx);
    try testing.expectEqual(@as(u64, 1), after.invitations);
}

test "the created body is the invitation, and it says the ask is still pending" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com", .role = "viewer" });
    defer store.freeInvitationRow(alloc, out.invitation);

    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .invitation = http_response.makeWorkspaceInvitationResponse(out.invitation),
    }, .{});
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "ben@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Acme") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"viewer\"") != null);
}
