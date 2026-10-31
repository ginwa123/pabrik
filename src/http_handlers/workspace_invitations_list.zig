//! `GET /api/workspaces/:workspace_id/invitations` — the pending asks for one
//! workspace. Owner/admin only: the list carries invitee email addresses.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_invitations_store.zig");

pub const InvitationsListError = gate.GateError;

pub const InvitationsListOutput = struct {
    /// Owned; the caller frees it with `store.freeInvitationRows`.
    invitations: []store.InvitationRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) InvitationsListError!InvitationsListOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, workspace_id, caller, .manage) catch |err| return err;

    const rows = store.listForWorkspace(allocator, db, workspace_id) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // Answering and revoking are the only paths that produce these.
        else => unreachable,
    };
    return .{ .invitations = rows };
}

pub fn workspaceInvitationsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const output = useCase(
        allocator,
        di.db,
        req.params.get("workspace_id") orelse "",
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = gate.statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = gate.messageFor(err) }),
        });
    };
    defer store.freeInvitationRows(allocator, output.invitations);

    const data = try http_response.makeWorkspaceInvitationListResponse(allocator, output.invitations);
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
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme'), ('ws_2', 'Beta')", &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben'),
        \\  ('user_cid', 'cid@example.com', 'Cid')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_1', 'user_amy', 'owner'),
        \\  ('ws_1', 'user_cid', 'editor')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by) VALUES
        \\  ('inv_1', 'ws_1', 'user_ben', 'editor', 'user_amy'),
        \\  ('inv_2', 'ws_2', 'user_ben', 'viewer', 'user_cid')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

test "useCase lists one workspace's pending invitations, with the invitee's account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, "ws_1", false, NoCookie{});
    defer store.freeInvitationRows(alloc, out.invitations);

    try testing.expectEqual(@as(usize, 1), out.invitations.len);
    try testing.expectEqualStrings("inv_1", out.invitations[0].id);
    try testing.expectEqualStrings("ben@example.com", out.invitations[0].invitee_email);
    try testing.expectEqualStrings("editor", out.invitations[0].role);
}

test "useCase answers a 404 for a workspace that does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceNotFound,
        useCase(alloc, &ctx.db, "ws_nope", false, NoCookie{}),
    );
    try testing.expectEqual(@as(u16, 404), gate.statusFor(error.WorkspaceNotFound));
}

test "the list body carries the invitee's address and never a value from the membership table" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, "ws_1", false, NoCookie{});
    defer store.freeInvitationRows(alloc, out.invitations);

    const json = try http_response.makeWorkspaceInvitationListResponse(alloc, out.invitations);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "ben@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Acme") != null);
    try testing.expect(std.mem.indexOf(u8, json, "inv_2") == null);
}
