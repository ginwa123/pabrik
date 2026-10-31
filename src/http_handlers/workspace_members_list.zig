//! `GET /api/workspaces/:workspace_id/members` — every member of one
//! workspace joined with its account, owners first. Never another
//! workspace's rows.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const gate = @import("workspace_members_gate.zig");
const store = @import("../agentic_loop/workspace_members_store.zig");

/// Exactly the gate's set: reading cannot fail in a way the gate does not
/// already describe.
pub const MembersListError = gate.GateError;

pub const MembersListInput = struct {
    workspace_id: []const u8,
};

pub const MembersListOutput = struct {
    /// Owned; the caller frees it with `store.freeMemberRows`.
    members: []store.MemberRow,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: MembersListInput,
    auth_enabled: bool,
    headers: anytype,
) MembersListError!MembersListOutput {
    const caller = gate.callerFor(allocator, db, auth_enabled, headers) catch |err| return err;
    defer allocator.free(caller);
    gate.check(allocator, db, input.workspace_id, caller, .read) catch |err| return err;

    const rows = store.listMembers(allocator, db, input.workspace_id) catch |err| switch (err) {
        error.WorkspaceIdRequired => return error.WorkspaceIdRequired,
        error.QueryFailed => return error.QueryFailed,
        error.OutOfMemory => return error.OutOfMemory,
        // Writes and the by-id reads are the only paths that can produce
        // these, and this is neither.
        else => unreachable,
    };
    return .{ .members = rows };
}

fn statusFor(err: MembersListError) u16 {
    return gate.statusFor(err);
}

fn messageFor(err: MembersListError) []const u8 {
    return gate.messageFor(err);
}

pub fn workspaceMembersListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();

    const output = useCase(
        allocator,
        di.db,
        .{ .workspace_id = req.params.get("workspace_id") orelse "" },
        di.auth_enabled,
        req.headers,
    ) catch |err| {
        return res.jsonResponse(.{
            .status_code = statusFor(err),
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
        });
    };
    defer store.freeMemberRows(allocator, output.members);

    const data = try http_response.makeWorkspaceMemberListResponse(allocator, output.members);
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
        \\  ('user_ben', 'ben@example.com', 'Ben')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role, invited_by) VALUES
        \\  ('ws_1', 'user_ben', 'viewer', 'user_amy'),
        \\  ('ws_1', 'user_amy', 'owner', NULL),
        \\  ('ws_2', 'user_ben', 'owner', NULL)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// No Cookie header, so `resolveRequestUserId` answers the installation
/// owner — the auth-off deployment this handler must also serve.
const NoCookie = struct {
    pub fn get(_: @This(), _: []const u8) ?[]const u8 {
        return null;
    }
};

test "useCase lists one workspace's members, owner first, with no invite left null" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" }, false, NoCookie{});
    defer store.freeMemberRows(alloc, out.members);

    try testing.expectEqual(@as(usize, 2), out.members.len);
    try testing.expectEqualStrings("user_amy", out.members[0].user_id);
    try testing.expectEqualStrings("owner", out.members[0].role);
    try testing.expectEqualStrings("user_ben", out.members[1].user_id);
    // `invited_by` is the INVITER's id, and a NULL there renders as '' rather
    // than as the text "null".
    try testing.expectEqualStrings("user_amy", out.members[1].invited_by);
    try testing.expectEqualStrings("", out.members[0].invited_by);
}

test "useCase answers a 404 for a workspace that does not exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceNotFound,
        useCase(alloc, &ctx.db, .{ .workspace_id = "ws_nope" }, false, NoCookie{}),
    );
    try testing.expectEqual(@as(u16, 404), statusFor(error.WorkspaceNotFound));
}

test "useCase answers a 400 for an empty workspace id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{ .workspace_id = "" }, false, NoCookie{}),
    );
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
}

test "the list body carries each member's email and role, and no other workspace's rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, .{ .workspace_id = "ws_1" }, false, NoCookie{});
    defer store.freeMemberRows(alloc, out.members);

    const json = try http_response.makeWorkspaceMemberListResponse(alloc, out.members);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "amy@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, json, "ben@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, json, "ws_2") == null);
}
