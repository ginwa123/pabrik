//! `POST /api/workspaces/:workspace_id/members` — invite an existing account
//! into a workspace by email, with a role. Answers 201 with the new row.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_members_store.zig");

/// Both fields default to "" so an empty body parses and is then refused by
/// validation, rather than answering "Invalid JSON body" to a blank form.
const InviteBody = struct {
    email: []const u8 = "",
    role: []const u8 = "",
};

pub const MembersInviteError = gate.GateError || error{
    EmailRequired,
    InvalidRole,
    UserNotFound,
    AlreadyMember,
    ReservedUser,
    InsertFailed,
};

pub const MembersInviteInput = struct {
    workspace_id: []const u8,
    body: InviteBody,
};

pub const MembersInviteOutput = struct {
    member: store.MemberRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MembersInviteInput,
    auth_enabled: bool,
    headers: anytype,
) MembersInviteError!MembersInviteOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, input.workspace_id, caller, .manage) catch |err| return err;

    // No role means the column's own default, which is `viewer` — the least
    // privilege an invite can grant.
    const role: store.Role = if (input.body.role.len == 0)
        .viewer
    else
        store.parseRole(input.body.role) orelse return error.InvalidRole;

    const member = store.addMember(allocator, db, .{
        .workspace_id = input.workspace_id,
        .email = input.body.email,
        .role = role,
        .invited_by = caller,
    }) catch |err| switch (err) {
        error.EmailRequired => return error.EmailRequired,
        error.NotFound => return error.UserNotFound,
        error.AlreadyMember => return error.AlreadyMember,
        error.ReservedUser => return error.ReservedUser,
        error.InsertFailed => return error.InsertFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // Reads and the last-owner guard are the only paths that produce
        // these, and an insert is neither.
        else => unreachable,
    };
    return .{ .member = member };
}

fn statusFor(err: MembersInviteError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.EmailRequired, error.InvalidRole, error.ReservedUser => 400,
        error.WorkspaceNotFound, error.UserNotFound => 404,
        error.Forbidden => 403,
        error.AlreadyMember => 409,
        error.InsertFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

/// `email` is echoed only for the 404, so the form can say WHICH address
/// found no account instead of "not found".
fn messageFor(
    err: MembersInviteError,
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
        error.ReservedUser => "the shared system account cannot be invited",
        error.InsertFailed => "DB error",
        error.WorkspaceIdRequired => "workspace_id required",
        error.WorkspaceNotFound => "Workspace not found",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn workspaceMembersInviteHandler(
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
        .{
            .workspace_id = req.params.get("workspace_id") orelse "",
            .body = body,
        },
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
    defer store.freeMemberRow(allocator, output.member);

    const data = try std.json.Stringify.valueAlloc(allocator, .{
        .member = http_response.makeWorkspaceMemberResponse(output.member),
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
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'One')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben'),
        \\  ('user_cid', 'cid@example.com', 'Cid')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_1', 'user_amy', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// No Cookie header: the installation owner, i.e. the auth-off caller.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, body: InviteBody) MembersInviteError!MembersInviteOutput {
    return useCase(testing.allocator, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = body,
    }, false, NoCookie{});
}

fn memberCount(ctx: *TestCtx) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = 'ws_1'", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return std.fmt.parseInt(u64, r.values[0], 10);
}

test "useCase invites an existing account and answers 201 with the joined row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com", .role = "editor" });
    defer store.freeMemberRow(alloc, out.member);

    try testing.expectEqualStrings("user_ben", out.member.user_id);
    try testing.expectEqualStrings("editor", out.member.role);
    try testing.expectEqualStrings("ben@example.com", out.member.email);
    try testing.expectEqualStrings("user_system", out.member.invited_by);
    try testing.expectEqual(@as(u64, 2), try memberCount(&ctx));
}

test "useCase defaults an omitted role to viewer, never to a managing role" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com" });
    defer store.freeMemberRow(alloc, out.member);
    try testing.expectEqualStrings("viewer", out.member.role);
}

test "useCase answers a 404 naming the address when no account carries it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.UserNotFound, run(&ctx, .{ .email = "nobody@example.com" }));
    try testing.expectEqual(@as(u16, 404), statusFor(error.UserNotFound));

    const message = try messageFor(error.UserNotFound, alloc, " nobody@example.com ");
    defer alloc.free(message);
    try testing.expectEqualStrings("no active account with the email 'nobody@example.com'", message);
}

test "useCase answers a 400 for a blank email and writes nothing" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.EmailRequired, run(&ctx, .{ .email = "   " }));
    try testing.expectEqual(@as(u16, 400), statusFor(error.EmailRequired));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx));
}

test "useCase answers a 400 for a role the column does not allow" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.InvalidRole, run(&ctx, .{ .email = "ben@example.com", .role = "emperor" }));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidRole));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx));
}

test "useCase answers a 409 for an account that is already a member" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.AlreadyMember, run(&ctx, .{ .email = "amy@example.com", .role = "admin" }));
    try testing.expectEqual(@as(u16, 409), statusFor(error.AlreadyMember));
    // The refused invite must not have re-roled the existing owner.
    const owner = try store.getMember(alloc, &ctx.db, "ws_1", "user_amy");
    defer store.freeMemberRow(alloc, owner);
    try testing.expectEqualStrings("owner", owner.role);
}

test "the invite response is the member row, without the inviter's session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, .{ .email = "ben@example.com", .role = "viewer" });
    defer store.freeMemberRow(alloc, out.member);

    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .member = http_response.makeWorkspaceMemberResponse(out.member),
    }, .{});
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "ben@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"role\":\"viewer\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "password") == null);
}
