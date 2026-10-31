//! Persistence for `workspace_invitations` (Migration 123). An invitation is a
//! PENDING ask: a row exists only while it is waiting for an answer, and
//! `accept` is the single place a `workspace_members` row is ever written.

const std = @import("std");
const test_db = @import("pabrikcore").test_db;
const database = @import("pabrikcore").database;
const helpers = @import("helpers");
const members = @import("workspace_members_store.zig");

pub const InvitationRow = struct {
    id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    invitee_user_id: []const u8,
    invitee_email: []const u8,
    invitee_name: []const u8,
    role: []const u8,
    invited_by: []const u8,
    created_at: []const u8,
};

pub const InviteArgs = struct {
    workspace_id: []const u8,
    email: []const u8 = "",
    role: members.Role = .viewer,
    invited_by: []const u8 = "",
};

pub const AnswerArgs = struct {
    invitation_id: []const u8,
    /// The caller, as resolved from the session. An invitation may only be
    /// answered by this exact account.
    invitee_user_id: []const u8 = "",
};

pub const RevokeArgs = struct {
    invitation_id: []const u8,
    workspace_id: []const u8,
};

pub const InvitationsError = error{
    WorkspaceIdRequired,
    InvitationIdRequired,
    EmailRequired,
    NotFound,
    AlreadyMember,
    AlreadyInvited,
    ReservedUser,
    QueryFailed,
    InsertFailed,
    DeleteFailed,
    OutOfMemory,
};

const SELECT_INVITATIONS =
    "SELECT i.id, i.workspace_id, COALESCE(CAST(w.name AS TEXT), ''), " ++
    "i.invitee_user_id, COALESCE(CAST(u.email AS TEXT), ''), COALESCE(CAST(u.name AS TEXT), ''), " ++
    "i.role, i.invited_by, COALESCE(CAST(i.created_at AS TEXT), '') " ++
    "FROM workspace_invitations i " ++
    "LEFT JOIN users u ON u.id = i.invitee_user_id " ++
    "LEFT JOIN workspaces w ON w.id = i.workspace_id ";

/// Newest first: an invitee answers the most recent ask first.
const ORDER_INVITATIONS = "ORDER BY i.created_at DESC, i.id DESC";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) InvitationsError!InvitationRow {
    if (values.len < 9) return error.QueryFailed;
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .workspace_id = try allocator.dupe(u8, values[1]),
        .workspace_name = try allocator.dupe(u8, values[2]),
        .invitee_user_id = try allocator.dupe(u8, values[3]),
        .invitee_email = try allocator.dupe(u8, values[4]),
        .invitee_name = try allocator.dupe(u8, values[5]),
        .role = try allocator.dupe(u8, values[6]),
        .invited_by = try allocator.dupe(u8, values[7]),
        .created_at = try allocator.dupe(u8, values[8]),
    };
}

pub fn freeInvitationRow(allocator: std.mem.Allocator, row: InvitationRow) void {
    allocator.free(row.id);
    allocator.free(row.workspace_id);
    allocator.free(row.workspace_name);
    allocator.free(row.invitee_user_id);
    allocator.free(row.invitee_email);
    allocator.free(row.invitee_name);
    allocator.free(row.role);
    allocator.free(row.invited_by);
    allocator.free(row.created_at);
}

pub fn freeInvitationRows(allocator: std.mem.Allocator, rows: []InvitationRow) void {
    for (rows) |row| freeInvitationRow(allocator, row);
    allocator.free(rows);
}

fn collect(
    allocator: std.mem.Allocator,
    db: *database.Db,
    sql: []const u8,
    params: []const []const u8,
) InvitationsError![]InvitationRow {
    var q = db.query(allocator, sql, params) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(InvitationRow) = .empty;
    // Unwind both the rows and the buffer: `toOwnedSlice` never runs on the
    // error path, so the list would otherwise leak every row it built.
    errdefer {
        for (list.items) |row| freeInvitationRow(allocator, row);
        list.deinit(allocator);
    }

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

/// Every pending invitation for one workspace — what the Members section shows
/// so an owner can see (and revoke) a request nobody has answered yet.
pub fn listForWorkspace(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) InvitationsError![]InvitationRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    return collect(
        allocator,
        db,
        SELECT_INVITATIONS ++ "WHERE i.workspace_id = ? " ++ ORDER_INVITATIONS,
        &[_][]const u8{workspace_id},
    );
}

/// The caller's own inbox, across every workspace.
pub fn listForInvitee(
    allocator: std.mem.Allocator,
    db: *database.Db,
    invitee_user_id: []const u8,
) InvitationsError![]InvitationRow {
    if (invitee_user_id.len == 0) return error.InvitationIdRequired;
    return collect(
        allocator,
        db,
        SELECT_INVITATIONS ++ "WHERE i.invitee_user_id = ? " ++ ORDER_INVITATIONS,
        &[_][]const u8{invitee_user_id},
    );
}

fn getScoped(
    allocator: std.mem.Allocator,
    db: *database.Db,
    where: []const u8,
    params: []const []const u8,
) InvitationsError!InvitationRow {
    // `where` differs per caller, so the statement is assembled at run time.
    const sql = std.mem.concat(allocator, u8, &.{ SELECT_INVITATIONS, where }) catch return error.OutOfMemory;
    defer allocator.free(sql);

    var q = db.query(allocator, sql, params) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values);
}

/// One invitation, scoped to the workspace that sent it (owner/admin view).
pub fn getForWorkspace(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    invitation_id: []const u8,
) InvitationsError!InvitationRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (invitation_id.len == 0) return error.InvitationIdRequired;
    return getScoped(
        allocator,
        db,
        "WHERE i.id = ? AND i.workspace_id = ?",
        &[_][]const u8{ invitation_id, workspace_id },
    );
}

/// One invitation, scoped to its invitee. Any other caller gets `NotFound`,
/// never a 403: an invitation is not something to confirm the existence of.
pub fn getForInvitee(
    allocator: std.mem.Allocator,
    db: *database.Db,
    invitation_id: []const u8,
    invitee_user_id: []const u8,
) InvitationsError!InvitationRow {
    if (invitation_id.len == 0 or invitee_user_id.len == 0) return error.InvitationIdRequired;
    return getScoped(
        allocator,
        db,
        "WHERE i.id = ? AND i.invitee_user_id = ?",
        &[_][]const u8{ invitation_id, invitee_user_id },
    );
}

fn membershipExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    user_id: []const u8,
) InvitationsError!bool {
    var q = db.query(
        allocator,
        "SELECT 1 FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ workspace_id, user_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return false;
    r.deinit(allocator);
    return true;
}

fn invitationExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    invitee_user_id: []const u8,
) InvitationsError!bool {
    var q = db.query(
        allocator,
        "SELECT 1 FROM workspace_invitations WHERE workspace_id = ? AND invitee_user_id = ?",
        &[_][]const u8{ workspace_id, invitee_user_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return false;
    r.deinit(allocator);
    return true;
}

fn userIdForEmail(
    allocator: std.mem.Allocator,
    db: *database.Db,
    email: []const u8,
) InvitationsError![]const u8 {
    var q = db.query(
        allocator,
        "SELECT id FROM users WHERE email = ? AND is_active = 1",
        &[_][]const u8{email},
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return allocator.dupe(u8, r.values[0]);
}

/// Create a pending invitation. This writes NO membership row: the invitee
/// answers first, which is the whole point of the table.
pub fn invite(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: InviteArgs,
) InvitationsError!InvitationRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;
    const email = std.mem.trim(u8, args.email, " \t\n\r");
    if (email.len == 0) return error.EmailRequired;

    const invitee = try userIdForEmail(allocator, db, email);
    defer allocator.free(invitee);
    if (std.mem.eql(u8, invitee, members.reserved_user_id)) return error.ReservedUser;
    if (try membershipExists(allocator, db, args.workspace_id, invitee)) return error.AlreadyMember;
    if (try invitationExists(allocator, db, args.workspace_id, invitee)) return error.AlreadyInvited;

    const invitation_id = try std.fmt.allocPrint(allocator, "inv_{d}", .{helpers.unixTimestampNanos()});
    defer allocator.free(invitation_id);

    db.exec(
        allocator,
        "INSERT INTO workspace_invitations (id, workspace_id, invitee_user_id, role, invited_by) " ++
            "VALUES (?, ?, ?, ?, COALESCE(NULLIF(?, ''), ''))",
        &[_][]const u8{ invitation_id, args.workspace_id, invitee, args.role.text(), args.invited_by },
    ) catch return error.InsertFailed;

    return getForWorkspace(allocator, db, args.workspace_id, invitation_id);
}

/// Accept: the invitation becomes a membership **in one transaction**, so a
/// half-applied answer can never leave both rows (or neither) behind.
pub fn accept(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: AnswerArgs,
) InvitationsError!members.MemberRow {
    const invitation = try getForInvitee(allocator, db, args.invitation_id, args.invitee_user_id);
    defer freeInvitationRow(allocator, invitation);

    if (try membershipExists(allocator, db, invitation.workspace_id, invitation.invitee_user_id)) {
        return error.AlreadyMember;
    }

    var tx = db.begin() catch return error.QueryFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    tx.exec(
        allocator,
        "INSERT INTO workspace_members (workspace_id, user_id, role, invited_by) " ++
            "VALUES (?, ?, ?, COALESCE(NULLIF(?, ''), ''))",
        &[_][]const u8{
            invitation.workspace_id,
            invitation.invitee_user_id,
            invitation.role,
            invitation.invited_by,
        },
    ) catch return error.InsertFailed;

    tx.exec(
        allocator,
        "DELETE FROM workspace_invitations WHERE id = ? AND invitee_user_id = ?",
        &[_][]const u8{ args.invitation_id, args.invitee_user_id },
    ) catch return error.DeleteFailed;

    tx.commit() catch return error.InsertFailed;

    return members.getMember(allocator, db, invitation.workspace_id, invitation.invitee_user_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.QueryFailed => return error.QueryFailed,
        // The row was inserted in the transaction above; a miss here is the
        // consistency error, not a 404.
        else => return error.QueryFailed,
    };
}

/// Decline: the ask goes away and nothing else changes.
pub fn decline(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: AnswerArgs,
) InvitationsError!void {
    const invitation = try getForInvitee(allocator, db, args.invitation_id, args.invitee_user_id);
    defer freeInvitationRow(allocator, invitation);

    db.exec(
        allocator,
        "DELETE FROM workspace_invitations WHERE id = ? AND invitee_user_id = ?",
        &[_][]const u8{ args.invitation_id, args.invitee_user_id },
    ) catch return error.DeleteFailed;
}

/// Revoke: an owner/admin withdraws an invitation the invitee never answered.
pub fn revoke(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: RevokeArgs,
) InvitationsError!void {
    const invitation = try getForWorkspace(allocator, db, args.workspace_id, args.invitation_id);
    defer freeInvitationRow(allocator, invitation);

    db.exec(
        allocator,
        "DELETE FROM workspace_invitations WHERE id = ? AND workspace_id = ?",
        &[_][]const u8{ args.invitation_id, args.workspace_id },
    ) catch return error.DeleteFailed;
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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
        \\  email TEXT NOT NULL UNIQUE,
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
    try db.exec(alloc,
        \\INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Acme'), ('ws_2', 'Beta')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy'),
        \\  ('user_ben', 'ben@example.com', 'Ben'),
        \\  ('user_cid', 'cid@example.com', 'Cid'),
        \\  ('user_system', 'system@local', 'System')
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES
        \\  ('ws_1', 'user_amy', 'owner')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn invitationCount(ctx: *TestCtx, workspace_id: []const u8) !u64 {
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

fn memberCount(ctx: *TestCtx, workspace_id: []const u8) !u64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = ?",
        &[_][]const u8{workspace_id},
    );
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    return std.fmt.parseInt(u64, r.values[0], 10);
}

fn inviteBen(ctx: *TestCtx) !InvitationRow {
    return invite(testing.allocator, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "ben@example.com",
        .role = .editor,
        .invited_by = "user_amy",
    });
}

test "invite writes a pending row and NO membership" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try inviteBen(&ctx);
    defer freeInvitationRow(alloc, row);

    try testing.expectEqualStrings("ws_1", row.workspace_id);
    try testing.expectEqualStrings("user_ben", row.invitee_user_id);
    try testing.expectEqualStrings("ben@example.com", row.invitee_email);
    try testing.expectEqualStrings("editor", row.role);
    try testing.expectEqualStrings("user_amy", row.invited_by);
    try testing.expect(row.id.len > 0);

    // THE assertion this table exists for: being invited is not being in.
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_1"));
}

test "invite answers NotFound for an email no active account carries" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.NotFound, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "nobody@example.com",
    }));

    try ctx.db.exec(alloc, "UPDATE users SET is_active = 0 WHERE id = 'user_cid'", &.{});
    try testing.expectError(error.NotFound, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "cid@example.com",
    }));
    try testing.expectEqual(@as(u64, 0), try invitationCount(&ctx, "ws_1"));
}

test "invite refuses the shared system account, an existing member and a duplicate ask" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.ReservedUser, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "system@local",
    }));
    try testing.expectError(error.AlreadyMember, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "amy@example.com",
    }));

    const first = try inviteBen(&ctx);
    defer freeInvitationRow(alloc, first);
    try testing.expectError(error.AlreadyInvited, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "ben@example.com",
        .role = .admin,
    }));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_1"));
}

test "invite requires an email, and the same person may be invited to two workspaces" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.EmailRequired, invite(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "   ",
    }));

    const in_ws1 = try inviteBen(&ctx);
    defer freeInvitationRow(alloc, in_ws1);
    const in_ws2 = try invite(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .email = "ben@example.com",
    });
    defer freeInvitationRow(alloc, in_ws2);

    try testing.expect(!std.mem.eql(u8, in_ws1.id, in_ws2.id));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_2"));
}

test "listForWorkspace shows only that workspace's pending asks, with the invitee's account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const in_ws1 = try inviteBen(&ctx);
    defer freeInvitationRow(alloc, in_ws1);
    const in_ws2 = try invite(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .email = "cid@example.com",
        .role = .viewer,
        .invited_by = "user_amy",
    });
    defer freeInvitationRow(alloc, in_ws2);

    const rows = try listForWorkspace(alloc, &ctx.db, "ws_1");
    defer freeInvitationRows(alloc, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("ben@example.com", rows[0].invitee_email);
    try testing.expectEqualStrings("Ben", rows[0].invitee_name);
    try testing.expectEqualStrings("Acme", rows[0].workspace_name);
}

test "listForInvitee is the inbox: every workspace waiting on this account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const in_ws1 = try inviteBen(&ctx);
    defer freeInvitationRow(alloc, in_ws1);
    const in_ws2 = try invite(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .email = "ben@example.com",
        .role = .admin,
        .invited_by = "user_amy",
    });
    defer freeInvitationRow(alloc, in_ws2);

    const mine = try listForInvitee(alloc, &ctx.db, "user_ben");
    defer freeInvitationRows(alloc, mine);
    try testing.expectEqual(@as(usize, 2), mine.len);

    // Someone else's inbox is empty, not somebody else's list.
    const theirs = try listForInvitee(alloc, &ctx.db, "user_cid");
    defer freeInvitationRows(alloc, theirs);
    try testing.expectEqual(@as(usize, 0), theirs.len);
}

test "accept turns the invitation into a membership with the invited role, and deletes the ask" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try inviteBen(&ctx);
    const invitation_id = try alloc.dupe(u8, row.id);
    defer alloc.free(invitation_id);
    freeInvitationRow(alloc, row);

    const member = try accept(alloc, &ctx.db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = "user_ben",
    });
    defer members.freeMemberRow(alloc, member);

    try testing.expectEqualStrings("user_ben", member.user_id);
    try testing.expectEqualStrings("editor", member.role);
    try testing.expectEqualStrings("user_amy", member.invited_by);

    try testing.expectEqual(@as(u64, 2), try memberCount(&ctx, "ws_1"));
    // The ask is consumed: one row cannot be answered twice.
    try testing.expectEqual(@as(u64, 0), try invitationCount(&ctx, "ws_1"));
    try testing.expectError(error.NotFound, getForInvitee(alloc, &ctx.db, invitation_id, "user_ben"));
}

test "accept answers NotFound for somebody else's invitation, and changes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try inviteBen(&ctx);
    const invitation_id = try alloc.dupe(u8, row.id);
    defer alloc.free(invitation_id);
    freeInvitationRow(alloc, row);

    // `user_cid` holds the id but is not the invitee.
    try testing.expectError(error.NotFound, accept(alloc, &ctx.db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = "user_cid",
    }));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_1"));
}

test "accept refuses an invitation whose account is already a member" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try inviteBen(&ctx);
    const invitation_id = try alloc.dupe(u8, row.id);
    defer alloc.free(invitation_id);
    freeInvitationRow(alloc, row);

    // Promoted by another owner while the invitation was waiting.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_1', 'user_ben', 'viewer')
    , &.{});

    try testing.expectError(error.AlreadyMember, accept(alloc, &ctx.db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = "user_ben",
    }));
    // The existing membership was not re-roled by the stale invitation.
    const kept = try members.getMember(alloc, &ctx.db, "ws_1", "user_ben");
    defer members.freeMemberRow(alloc, kept);
    try testing.expectEqualStrings("viewer", kept.role);
}

test "decline deletes the ask and grants nothing" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try inviteBen(&ctx);
    const invitation_id = try alloc.dupe(u8, row.id);
    defer alloc.free(invitation_id);
    freeInvitationRow(alloc, row);

    try decline(alloc, &ctx.db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = "user_ben",
    });

    try testing.expectEqual(@as(u64, 0), try invitationCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
    // A second decline has nothing left to answer.
    try testing.expectError(error.NotFound, decline(alloc, &ctx.db, .{
        .invitation_id = invitation_id,
        .invitee_user_id = "user_ben",
    }));
}

test "revoke withdraws one workspace's invitation and leaves the other workspace's alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const in_ws1 = try inviteBen(&ctx);
    const ws1_id = try alloc.dupe(u8, in_ws1.id);
    defer alloc.free(ws1_id);
    freeInvitationRow(alloc, in_ws1);
    const in_ws2 = try invite(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .email = "ben@example.com",
    });
    defer freeInvitationRow(alloc, in_ws2);

    try revoke(alloc, &ctx.db, .{ .invitation_id = ws1_id, .workspace_id = "ws_1" });
    try testing.expectEqual(@as(u64, 0), try invitationCount(&ctx, "ws_1"));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_2"));

    // Revoking through the WRONG workspace is a 404, not a cross-tenant delete.
    try testing.expectError(error.NotFound, revoke(alloc, &ctx.db, .{
        .invitation_id = in_ws2.id,
        .workspace_id = "ws_1",
    }));
    try testing.expectEqual(@as(u64, 1), try invitationCount(&ctx, "ws_2"));
}
