//! `DELETE /api/workspaces/:workspace_id/members/:user_id` — remove one
//! member. The last owner cannot be removed, for the same reason it cannot
//! be demoted.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_members_store.zig");

pub const MembersRemoveError = gate.GateError || error{
    MemberNotFound,
    LastOwner,
    DeleteFailed,
};

pub const MembersRemoveOutput = struct {
    user_id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    user_id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) MembersRemoveError!MembersRemoveOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, workspace_id, caller, .manage) catch |err| return err;

    store.removeMember(allocator, db, .{
        .workspace_id = workspace_id,
        .user_id = user_id,
    }) catch |err| switch (err) {
        error.NotFound => return error.MemberNotFound,
        error.LastOwner => return error.LastOwner,
        error.DeleteFailed => return error.DeleteFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // `removeMember` validates both ids itself, and an INSERT cannot come
        // out of a DELETE.
        else => unreachable,
    };
    return .{ .user_id = user_id };
}

fn statusFor(err: MembersRemoveError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired => 400,
        error.WorkspaceNotFound, error.MemberNotFound => 404,
        error.Forbidden => 403,
        error.LastOwner => 409,
        error.DeleteFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: MembersRemoveError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.WorkspaceNotFound => "Workspace not found",
        error.MemberNotFound => "that account is not a member of this workspace",
        error.Forbidden => "Only a workspace owner or admin can do that",
        error.LastOwner => "a workspace must keep at least one owner",
        error.DeleteFailed, error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn workspaceMembersRemoveHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const user_id = req.params.get("user_id") orelse "";

    const output = useCase(
        allocator,
        di.db,
        req.params.get("workspace_id") orelse "",
        user_id,
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
        .user_id = output.user_id,
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
        \\  ('ws_2', 'user_ben', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

fn run(ctx: *TestCtx, user_id: []const u8) MembersRemoveError!MembersRemoveOutput {
    return useCase(testing.allocator, &ctx.db, "ws_1", user_id, false, NoCookie{});
}

fn membershipExists(ctx: *TestCtx, workspace_id: []const u8, user_id: []const u8) !bool {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ workspace_id, user_id },
    );
    defer q.deinit();
    const r = (try q.next()) orelse return false;
    r.deinit(alloc);
    return true;
}

test "useCase removes one membership and leaves the account's other workspaces alone" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try run(&ctx, "user_ben");
    try testing.expectEqualStrings("user_ben", out.user_id);

    try testing.expect(!try membershipExists(&ctx, "ws_1", "user_ben"));
    try testing.expect(try membershipExists(&ctx, "ws_2", "user_ben"));
}

test "useCase answers a 404 for an account that is not a member" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.MemberNotFound, run(&ctx, "user_cid"));
    try testing.expectEqual(@as(u16, 404), statusFor(error.MemberNotFound));
    try testing.expectEqualStrings("that account is not a member of this workspace", messageFor(error.MemberNotFound));
}

test "useCase answers a 409 rather than removing the last owner" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.LastOwner, run(&ctx, "user_amy"));
    try testing.expectEqual(@as(u16, 409), statusFor(error.LastOwner));
    try testing.expect(try membershipExists(&ctx, "ws_1", "user_amy"));
}

test "useCase answers a 400 for an empty workspace id" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(testing.allocator, &ctx.db, "", "user_ben", false, NoCookie{}),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
}
