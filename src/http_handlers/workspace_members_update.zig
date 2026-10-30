//! `PATCH /api/workspaces/:workspace_id/members/:user_id` — change one
//! member's role. The last owner can never be demoted: a workspace with no
//! owner has nobody left who could undo it.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_members_store.zig");

/// An empty `role` is a 400, never a silent `viewer`: a PATCH with nothing
/// to change is a mistake, not a request.
const UpdateBody = struct {
    role: []const u8 = "",
};

pub const MembersUpdateError = gate.GateError || error{
    InvalidRole,
    MemberNotFound,
    LastOwner,
    UpdateFailed,
};

pub const MembersUpdateInput = struct {
    workspace_id: []const u8,
    user_id: []const u8,
    body: UpdateBody,
};

pub const MembersUpdateOutput = struct {
    member: store.MemberRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MembersUpdateInput,
    auth_enabled: bool,
    headers: anytype,
) MembersUpdateError!MembersUpdateOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, input.workspace_id, caller, .manage) catch |err| return err;

    const role = store.parseRole(input.body.role) orelse return error.InvalidRole;

    const member = store.setRole(allocator, db, .{
        .workspace_id = input.workspace_id,
        .user_id = input.user_id,
        .role = role,
    }) catch |err| switch (err) {
        error.NotFound => return error.MemberNotFound,
        error.LastOwner => return error.LastOwner,
        error.UpdateFailed => return error.UpdateFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // `setRole` requires both ids itself; an insert-only or delete-only
        // failure cannot come out of an UPDATE.
        else => unreachable,
    };
    return .{ .member = member };
}

fn statusFor(err: MembersUpdateError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.InvalidRole => 400,
        error.WorkspaceNotFound, error.MemberNotFound => 404,
        error.Forbidden => 403,
        error.LastOwner => 409,
        error.UpdateFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: MembersUpdateError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.InvalidRole => "role must be owner, admin, editor or viewer",
        error.WorkspaceNotFound => "Workspace not found",
        error.MemberNotFound => "that account is not a member of this workspace",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.LastOwner => "a workspace must keep at least one owner",
        error.UpdateFailed => "DB error",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn workspaceMembersUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    var body = UpdateBody{};
    if (req.body.len > 0) {
        body = std.json.parseFromSliceLeaky(UpdateBody, allocator, req.body, .{}) catch {
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
            .user_id = req.params.get("user_id") orelse "",
            .body = body,
        },
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer store.freeMemberRow(allocator, output.member);

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
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'One'), ('ws_2', 'Two')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben'),
        \\  ('user_cid', 'cid@example.com', 'Cid')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_1', 'user_amy', 'owner'),
        \\  ('ws_1', 'user_ben', 'viewer'),
        \\  ('ws_2', 'user_cid', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, user_id: []const u8, role: []const u8) MembersUpdateError!MembersUpdateOutput {
    return useCase(testing.allocator, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = user_id,
        .body = .{ .role = role },
    }, false, NoCookie{});
}

test "useCase changes one member's role and answers the updated row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, "user_ben", "admin");
    defer store.freeMemberRow(alloc, out.member);

    try testing.expectEqualStrings("user_ben", out.member.user_id);
    try testing.expectEqualStrings("admin", out.member.role);
    try testing.expectEqualStrings("ben@example.com", out.member.email);

    const owner = try store.getMember(alloc, &ctx.db, "ws_1", "user_amy");
    defer store.freeMemberRow(alloc, owner);
    try testing.expectEqualStrings("owner", owner.role);
}

test "useCase answers a 400 for an empty or unknown role" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "", "emperor" }) |bad| {
        try testing.expectError(error.InvalidRole, run(&ctx, "user_ben", bad));
    }
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidRole));
    try testing.expectEqualStrings("role must be owner, admin, editor or viewer", messageFor(error.InvalidRole));

    const kept = try store.getMember(alloc, &ctx.db, "ws_1", "user_ben");
    defer store.freeMemberRow(alloc, kept);
    try testing.expectEqualStrings("viewer", kept.role);
}

test "useCase answers a 404 for an account that is not a member" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.MemberNotFound, run(&ctx, "user_cid", "viewer"));
    try testing.expectEqual(@as(u16, 404), statusFor(error.MemberNotFound));
}

test "useCase answers a 409 rather than demoting the last owner" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.LastOwner, run(&ctx, "user_amy", "viewer"));
    try testing.expectEqual(@as(u16, 409), statusFor(error.LastOwner));
    try testing.expectEqualStrings("a workspace must keep at least one owner", messageFor(error.LastOwner));

    const kept = try store.getMember(alloc, &ctx.db, "ws_1", "user_amy");
    defer store.freeMemberRow(alloc, kept);
    try testing.expectEqualStrings("owner", kept.role);
}
