//! Persistence for `workspace_members` (Migration 100).

const std = @import("std");
const test_db = @import("pabrikcore").test_db;
const database = @import("pabrikcore").database;

/// The four roles Migration 100's CHECK constraint allows.
pub const Role = enum {
    owner,
    admin,
    editor,
    viewer,

    pub fn text(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn canManageMembers(self: Role) bool {
        return self == .owner or self == .admin;
    }
};

/// `?Role`, or null for text the column's CHECK constraint should have
/// rejected. Callers treat null as "this row is not usable" rather than
/// guessing a default.
pub fn parseRole(raw: []const u8) ?Role {
    return std.meta.stringToEnum(Role, raw);
}

/// `user_system` is the shared/legacy bucket, not a person: it has no
/// password and is never invited.
pub const reserved_user_id = "user_system";

/// One membership joined with its account. Every owned slice is freed by
/// `freeMemberRow`.
pub const MemberRow = struct {
    /// The workspace this membership is IN — the client needs it to navigate
    /// to the workspace an invitation was just accepted for.
    workspace_id: []const u8,
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
    joined_at: []const u8,
    invited_by: []const u8,
};

pub const AddMemberArgs = struct {
    workspace_id: []const u8,
    email: []const u8 = "",
    role: Role = .viewer,
    invited_by: []const u8 = "",
};

pub const SetRoleArgs = struct {
    workspace_id: []const u8,
    user_id: []const u8 = "",
    role: Role = .viewer,
};

pub const RemoveMemberArgs = struct {
    workspace_id: []const u8,
    user_id: []const u8 = "",
};

pub const MembersError = error{
    WorkspaceIdRequired,
    UserIdRequired,
    EmailRequired,
    NotFound,
    AlreadyMember,
    ReservedUser,
    LastOwner,
    QueryFailed,
    InsertFailed,
    UpdateFailed,
    DeleteFailed,
    OutOfMemory,
};

/// The one projection every read uses, so no call site can return a
/// different column order. `LEFT JOIN` because a `user_system` member row
/// (auth-off backfill) has no account behind it.
const SELECT_MEMBERS =
    "SELECT m.workspace_id, m.user_id, COALESCE(CAST(u.email AS TEXT), ''), COALESCE(CAST(u.name AS TEXT), ''), " ++
    "m.role, COALESCE(CAST(m.joined_at AS TEXT), ''), COALESCE(CAST(m.invited_by AS TEXT), '') " ++
    "FROM workspace_members m LEFT JOIN users u ON u.id = m.user_id ";

/// Owners first, then admins, editors, viewers; ties broken by email so the
/// list is stable across calls.
const ORDER_MEMBERS =
    "ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 " ++
    "WHEN 'editor' THEN 2 ELSE 3 END, COALESCE(u.email, ''), m.user_id";

fn rowFromValues(allocator: std.mem.Allocator, values: []const []const u8) MembersError!MemberRow {
    if (values.len < 7) return error.QueryFailed;
    return .{
        .workspace_id = try allocator.dupe(u8, values[0]),
        .user_id = try allocator.dupe(u8, values[1]),
        .email = try allocator.dupe(u8, values[2]),
        .name = try allocator.dupe(u8, values[3]),
        .role = try allocator.dupe(u8, values[4]),
        .joined_at = try allocator.dupe(u8, values[5]),
        .invited_by = try allocator.dupe(u8, values[6]),
    };
}

pub fn freeMemberRow(allocator: std.mem.Allocator, row: MemberRow) void {
    allocator.free(row.workspace_id);
    allocator.free(row.user_id);
    allocator.free(row.email);
    allocator.free(row.name);
    allocator.free(row.role);
    allocator.free(row.joined_at);
    allocator.free(row.invited_by);
}

pub fn freeMemberRows(allocator: std.mem.Allocator, rows: []MemberRow) void {
    for (rows) |row| freeMemberRow(allocator, row);
    allocator.free(rows);
}

pub fn listMembers(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) MembersError![]MemberRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;

    var q = db.query(
        allocator,
        SELECT_MEMBERS ++ "WHERE m.workspace_id = ? " ++ ORDER_MEMBERS,
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    var list: std.ArrayList(MemberRow) = .empty;
    // A mid-iteration failure would strand the rows already built; the
    // buffer belongs to the list, so unwind both here.
    errdefer {
        for (list.items) |row| freeMemberRow(allocator, row);
        list.deinit(allocator);
    }

    while (q.next() catch return error.QueryFailed) |r| {
        defer r.deinit(allocator);
        try list.append(allocator, try rowFromValues(allocator, r.values));
    }
    return list.toOwnedSlice(allocator);
}

pub fn getMember(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    user_id: []const u8,
) MembersError!MemberRow {
    if (workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (user_id.len == 0) return error.UserIdRequired;

    var q = db.query(
        allocator,
        SELECT_MEMBERS ++ "WHERE m.workspace_id = ? AND m.user_id = ?",
        &[_][]const u8{ workspace_id, user_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.NotFound;
    defer r.deinit(allocator);
    return rowFromValues(allocator, r.values);
}

/// The role `user_id` holds in `workspace_id`, or null when they are not a
/// member at all. A null is the "not allowed" answer, and it is different
/// from a role that happens to be weak.
pub fn callerRole(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    user_id: []const u8,
) MembersError!?Role {
    if (workspace_id.len == 0 or user_id.len == 0) return null;

    var q = db.query(
        allocator,
        "SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ workspace_id, user_id },
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return null;
    defer r.deinit(allocator);
    return parseRole(r.values[0]) orelse return error.QueryFailed;
}

fn ownerCount(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
) MembersError!u64 {
    var q = db.query(
        allocator,
        "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = ? AND role = 'owner'",
        &[_][]const u8{workspace_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    const r = (q.next() catch return error.QueryFailed) orelse return error.QueryFailed;
    defer r.deinit(allocator);
    return std.fmt.parseInt(u64, r.values[0], 10) catch return error.QueryFailed;
}

/// Resolve an email to the account id an invite would admit. Active accounts
/// only — a disabled login must not gain a new workspace.
fn userIdForEmail(
    allocator: std.mem.Allocator,
    db: *database.Db,
    email: []const u8,
) MembersError![]const u8 {
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

fn membershipExists(
    allocator: std.mem.Allocator,
    db: *database.Db,
    workspace_id: []const u8,
    user_id: []const u8,
) MembersError!bool {
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

/// Add an existing account to a workspace. The invite is by EMAIL because
/// that is what the person inviting knows; the id is what the row stores.
pub fn addMember(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: AddMemberArgs,
) MembersError!MemberRow {
    if (args.workspace_id.len == 0) return error.WorkspaceIdRequired;
    const email = std.mem.trim(u8, args.email, " \t\n\r");
    if (email.len == 0) return error.EmailRequired;

    const user_id = try userIdForEmail(allocator, db, email);
    defer allocator.free(user_id);
    if (std.mem.eql(u8, user_id, reserved_user_id)) return error.ReservedUser;
    if (try membershipExists(allocator, db, args.workspace_id, user_id)) return error.AlreadyMember;

    db.exec(
        allocator,
        "INSERT INTO workspace_members (workspace_id, user_id, role, invited_by) VALUES (?, ?, ?, ?)",
        &[_][]const u8{ args.workspace_id, user_id, args.role.text(), args.invited_by },
    ) catch return error.InsertFailed;

    return getMember(allocator, db, args.workspace_id, user_id);
}

/// Change one member's role. Refuses the change that would leave the
/// workspace ownerless, which is unrecoverable from inside the product.
pub fn setRole(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: SetRoleArgs,
) MembersError!MemberRow {
    const current = try getMember(allocator, db, args.workspace_id, args.user_id);
    defer freeMemberRow(allocator, current);

    const was_owner = std.mem.eql(u8, current.role, "owner");
    if (was_owner and args.role != .owner) {
        if (try ownerCount(allocator, db, args.workspace_id) <= 1) return error.LastOwner;
    }

    db.exec(
        allocator,
        "UPDATE workspace_members SET role = ? WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ args.role.text(), args.workspace_id, args.user_id },
    ) catch return error.UpdateFailed;

    return getMember(allocator, db, args.workspace_id, args.user_id);
}

pub fn removeMember(
    allocator: std.mem.Allocator,
    db: *database.Db,
    args: RemoveMemberArgs,
) MembersError!void {
    const current = try getMember(allocator, db, args.workspace_id, args.user_id);
    defer freeMemberRow(allocator, current);

    if (std.mem.eql(u8, current.role, "owner")) {
        if (try ownerCount(allocator, db, args.workspace_id) <= 1) return error.LastOwner;
    }

    db.exec(
        allocator,
        "DELETE FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ args.workspace_id, args.user_id },
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
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL UNIQUE,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  password_hash TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'user',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_members (
        \\  workspace_id TEXT NOT NULL,
        \\  user_id TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'viewer',
        \\  joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  invited_by TEXT,
        \\  PRIMARY KEY (workspace_id, user_id)
        \\)
    , &.{});
    try db.exec(alloc,
        \\INSERT INTO users (id, email, name, password_hash) VALUES
        \\  ('user_amy', 'amy@example.com', 'Amy', 'x'),
        \\  ('user_ben', 'ben@example.com', 'Ben', 'x'),
        \\  ('user_cid', 'cid@example.com', 'Cid', 'x'),
        \\  ('user_system', 'system@local', 'System', '!disabled')
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn seedMembership(ctx: *TestCtx, workspace_id: []const u8, user_id: []const u8, role: []const u8) !void {
    try ctx.db.exec(
        testing.allocator,
        "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES (?, ?, ?)",
        &[_][]const u8{ workspace_id, user_id, role },
    );
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

test "parseRole accepts exactly the four roles the column allows" {
    try testing.expectEqual(Role.owner, parseRole("owner").?);
    try testing.expectEqual(Role.admin, parseRole("admin").?);
    try testing.expectEqual(Role.editor, parseRole("editor").?);
    try testing.expectEqual(Role.viewer, parseRole("viewer").?);
    try testing.expectEqual(@as(?Role, null), parseRole("emperor"));
    try testing.expectEqual(@as(?Role, null), parseRole(""));
    try testing.expectEqual(@as(?Role, null), parseRole("Owner"));
}

test "canManageMembers is true for owner and admin only" {
    try testing.expect(Role.owner.canManageMembers());
    try testing.expect(Role.admin.canManageMembers());
    try testing.expect(!Role.editor.canManageMembers());
    try testing.expect(!Role.viewer.canManageMembers());
}

test "listMembers returns one row per member, owners first, each with its account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_ben", "viewer");
    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_cid", "admin");

    const rows = try listMembers(alloc, &ctx.db, "ws_1");
    defer freeMemberRows(alloc, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    // Owner first regardless of insertion order — the owner is who you look
    // for when the list opens.
    try testing.expectEqualStrings("user_amy", rows[0].user_id);
    try testing.expectEqualStrings("owner", rows[0].role);
    try testing.expectEqualStrings("amy@example.com", rows[0].email);
    try testing.expectEqualStrings("Amy", rows[0].name);
    try testing.expectEqualStrings("user_cid", rows[1].user_id);
    try testing.expectEqualStrings("user_ben", rows[2].user_id);
    // `joined_at` is stamped by the column default, not by this code.
    try testing.expect(rows[0].joined_at.len > 0);
}

test "listMembers never returns another workspace's members" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_2", "user_ben", "owner");

    const rows = try listMembers(alloc, &ctx.db, "ws_1");
    defer freeMemberRows(alloc, rows);

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("user_amy", rows[0].user_id);
}

test "listMembers on a workspace with no rows lists empty rather than erroring" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const rows = try listMembers(alloc, &ctx.db, "ws_nobody");
    defer freeMemberRows(alloc, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "addMember admits an existing account by email and records the inviter" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");

    const added = try addMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "  ben@example.com  ",
        .role = .editor,
        .invited_by = "user_amy",
    });
    defer freeMemberRow(alloc, added);

    try testing.expectEqualStrings("user_ben", added.user_id);
    try testing.expectEqualStrings("editor", added.role);
    try testing.expectEqualStrings("ben@example.com", added.email);
    try testing.expectEqualStrings("user_amy", added.invited_by);
    try testing.expectEqual(@as(u64, 2), try memberCount(&ctx, "ws_1"));
}

test "addMember answers NotFound for an email no active account carries" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.NotFound, addMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "nobody@example.com",
    }));

    // A disabled account is not invitable either, so the refusal does not
    // depend on the account existing.
    try ctx.db.exec(alloc, "UPDATE users SET is_active = 0 WHERE id = 'user_cid'", &.{});
    try testing.expectError(error.NotFound, addMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "cid@example.com",
    }));
    try testing.expectEqual(@as(u64, 0), try memberCount(&ctx, "ws_1"));
}

test "addMember answers EmailRequired for a blank email, never a query for ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    for ([_][]const u8{ "", "   \t\n " }) |blank| {
        try testing.expectError(error.EmailRequired, addMember(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .email = blank,
        }));
    }
}

test "addMember refuses the shared system account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // `user_system` has a row in `users`, so email resolution alone would
    // admit it — that row is the "visible to everyone" marker, not a person.
    try testing.expectError(error.ReservedUser, addMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "system@local",
    }));
    try testing.expectEqual(@as(u64, 0), try memberCount(&ctx, "ws_1"));
}

test "addMember refuses a second membership for the same account" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_ben", "viewer");
    try testing.expectError(error.AlreadyMember, addMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .email = "ben@example.com",
        .role = .admin,
    }));
    // The refused invite must not have upgraded the existing row.
    const kept = try getMember(alloc, &ctx.db, "ws_1", "user_ben");
    defer freeMemberRow(alloc, kept);
    try testing.expectEqualStrings("viewer", kept.role);
}

test "setRole changes one member's role and leaves the others alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_ben", "viewer");

    const updated = try setRole(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_ben",
        .role = .admin,
    });
    defer freeMemberRow(alloc, updated);
    try testing.expectEqualStrings("admin", updated.role);

    const owner = try getMember(alloc, &ctx.db, "ws_1", "user_amy");
    defer freeMemberRow(alloc, owner);
    try testing.expectEqualStrings("owner", owner.role);
}

test "setRole refuses to demote the last owner" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");

    try testing.expectError(error.LastOwner, setRole(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_amy",
        .role = .viewer,
    }));

    const kept = try getMember(alloc, &ctx.db, "ws_1", "user_amy");
    defer freeMemberRow(alloc, kept);
    try testing.expectEqualStrings("owner", kept.role);
}

test "setRole may demote an owner while another owner remains" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_ben", "owner");

    const updated = try setRole(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_ben",
        .role = .editor,
    });
    defer freeMemberRow(alloc, updated);
    try testing.expectEqualStrings("editor", updated.role);
}

test "setRole on a non-member is NotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try testing.expectError(error.NotFound, setRole(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_cid",
        .role = .viewer,
    }));
}

test "removeMember deletes the row and leaves the other workspaces alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_ben", "viewer");
    try seedMembership(&ctx, "ws_2", "user_ben", "owner");

    try removeMember(alloc, &ctx.db, .{ .workspace_id = "ws_1", .user_id = "user_ben" });

    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
    try testing.expectError(error.NotFound, getMember(alloc, &ctx.db, "ws_1", "user_ben"));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_2"));
}

test "removeMember refuses to remove the last owner" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try testing.expectError(error.LastOwner, removeMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_amy",
    }));
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
}

test "removeMember may remove an owner while another owner remains" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_ben", "owner");

    try removeMember(alloc, &ctx.db, .{ .workspace_id = "ws_1", .user_id = "user_ben" });
    try testing.expectEqual(@as(u64, 1), try memberCount(&ctx, "ws_1"));
}

test "removeMember on a non-member is NotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(error.NotFound, removeMember(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .user_id = "user_cid",
    }));
}

test "callerRole reports a member's role and null for a stranger" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedMembership(&ctx, "ws_1", "user_amy", "owner");
    try seedMembership(&ctx, "ws_1", "user_ben", "viewer");

    try testing.expectEqual(Role.owner, (try callerRole(alloc, &ctx.db, "ws_1", "user_amy")).?);
    try testing.expectEqual(Role.viewer, (try callerRole(alloc, &ctx.db, "ws_1", "user_ben")).?);
    // Never a member here: the answer is null, NOT a default role.
    try testing.expectEqual(@as(?Role, null), try callerRole(alloc, &ctx.db, "ws_1", "user_cid"));
    try testing.expectEqual(@as(?Role, null), try callerRole(alloc, &ctx.db, "ws_2", "user_amy"));
}
