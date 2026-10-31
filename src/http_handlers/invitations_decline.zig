//! `POST /api/invitations/:invitation_id/decline` — the invitee says no. The
//! ask is deleted and nothing else changes.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");

pub const InvitationsDeclineError = error{
    InvitationIdRequired,
    InvitationNotFound,
    DeleteFailed,
    QueryFailed,
    OutOfMemory,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    invitation_id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) InvitationsDeclineError!void {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QueryFailed,
    };
    defer allocator.free(caller);

    store.decline(allocator, db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = caller,
    }) catch |err| switch (err) {
        error.InvitationIdRequired => return error.InvitationIdRequired,
        error.NotFound => return error.InvitationNotFound,
        error.DeleteFailed => return error.DeleteFailed,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn statusFor(err: InvitationsDeclineError) u16 {
    return switch (err) {
        error.InvitationIdRequired => 400,
        error.InvitationNotFound => 404,
        error.DeleteFailed, error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: InvitationsDeclineError) []const u8 {
    return switch (err) {
        error.InvitationIdRequired => "invitation_id required",
        error.InvitationNotFound => "Invitation not found",
        error.DeleteFailed, error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

pub fn invitationsDeclineHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const invitation_id = req.params.get("invitation_id") orelse "";

    useCase(allocator, di.db, invitation_id, di.auth_enabled, req.headers) catch |err| {
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
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'), ('user_ben', 'ben@example.com', 'Ben')
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

fn pendingCount(ctx: *TestCtx) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_invitations", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return std.fmt.parseInt(u64, r.values[0], 10);
}

test "useCase declines nothing for an invitation that is not the caller's" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.InvitationNotFound,
        useCase(alloc, &ctx.db, "inv_1", false, NoCookie{}),
    );
    // The row an unaddressed caller cannot see is also a row they cannot delete.
    try testing.expectEqual(@as(u64, 1), try pendingCount(&ctx));
}

test "useCase answers 400 for an empty invitation id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.InvitationIdRequired,
        useCase(alloc, &ctx.db, "", false, NoCookie{}),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvitationIdRequired));
    try testing.expectEqualStrings("Invitation not found", messageFor(error.InvitationNotFound));
}
