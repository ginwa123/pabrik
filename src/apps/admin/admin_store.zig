//! Data access for the admin console. Everything here talks to `users`
//! (Migration 077) and `auth_sessions` (Migration 089) and nothing else.

const std = @import("std");
const database = @import("databases").database;
const admin_common = @import("admin_common.zig");

const Db = *database.Db;

/// One account as the console shows it. The strings are owned by the caller.
pub const UserRow = struct {
    id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
    is_active: bool,
    created_at: []const u8,
    last_login_at: []const u8,
};

/// The counts the console opens with.
pub const Overview = struct {
    total_users: u32 = 0,
    active_users: u32 = 0,
    admin_users: u32 = 0,
    bot_users: u32 = 0,
    active_sessions: u32 = 0,
};

/// The failures the console knows about. A database failure is one of them
/// (`DatabaseError`), so a caller never has to catch two error sets.
pub const Error = error{
    /// No account carries that id.
    UserNotFound,
    /// The change would leave the installation without an owner.
    LastAdmin,
    /// Another account already uses that email.
    EmailTaken,
    /// The database refused the write.
    DatabaseError,
    /// The rows the console returns are copies, and a copy needs memory.
    OutOfMemory,
};

const user_columns =
    \\SELECT id, email, COALESCE(name, ''), role, is_active,
    \\       COALESCE(created_at, ''), COALESCE(last_login_at, '')
;

/// The system account is not a person and can never sign in, so the console
/// leaves it out of every list.
fn rowToUser(allocator: std.mem.Allocator, values: []const []const u8) !UserRow {
    if (values.len < 7) return error.QueryFailed;
    return .{
        .id = try allocator.dupe(u8, values[0]),
        .email = try allocator.dupe(u8, values[1]),
        .name = try allocator.dupe(u8, values[2]),
        .role = try allocator.dupe(u8, values[3]),
        .is_active = std.mem.eql(u8, values[4], "1"),
        .created_at = try allocator.dupe(u8, values[5]),
        .last_login_at = try allocator.dupe(u8, values[6]),
    };
}

pub fn freeUser(allocator: std.mem.Allocator, user: UserRow) void {
    allocator.free(user.id);
    allocator.free(user.email);
    allocator.free(user.name);
    allocator.free(user.role);
    allocator.free(user.created_at);
    allocator.free(user.last_login_at);
}

pub fn freeUsers(allocator: std.mem.Allocator, users: []UserRow) void {
    for (users) |u| freeUser(allocator, u);
    allocator.free(users);
}

/// Every real account, oldest first.
pub fn listUsers(allocator: std.mem.Allocator, db: Db) ![]UserRow {
    var q = try db.query(
        allocator,
        user_columns ++ " FROM users WHERE id != ? ORDER BY created_at, id",
        &[_][]const u8{admin_common.system_user_id},
    );
    defer q.deinit();

    var out: std.ArrayList(UserRow) = .empty;
    errdefer {
        for (out.items) |u| freeUser(allocator, u);
        out.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, try rowToUser(allocator, row.values));
    }
    return out.toOwnedSlice(allocator);
}

/// One account by id, or null when there is none.
pub fn findUser(allocator: std.mem.Allocator, db: Db, id: []const u8) !?UserRow {
    var q = try db.query(
        allocator,
        user_columns ++ " FROM users WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    return try rowToUser(allocator, row.values);
}

/// How many accounts may still act as the installation owner.
pub fn countActiveAdmins(allocator: std.mem.Allocator, db: Db) !u32 {
    var q = try db.query(
        allocator,
        "SELECT COUNT(*) FROM users WHERE role = 'admin' AND is_active = 1 AND id != ?",
        &[_][]const u8{admin_common.system_user_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(allocator);
    if (row.values.len < 1) return 0;
    return @intCast(std.fmt.parseInt(i64, row.values[0], 10) catch 0);
}

/// The counts the console opens with.
pub fn overview(allocator: std.mem.Allocator, db: Db) !Overview {
    var out: Overview = .{};
    {
        var q = try db.query(allocator,
            \\SELECT COUNT(*),
            \\       COALESCE(SUM(CASE WHEN is_active = 1 THEN 1 ELSE 0 END), 0),
            \\       COALESCE(SUM(CASE WHEN role = 'admin' AND is_active = 1 THEN 1 ELSE 0 END), 0),
            \\       COALESCE(SUM(CASE WHEN role = 'bot' THEN 1 ELSE 0 END), 0)
            \\FROM users WHERE id != ?
        , &[_][]const u8{admin_common.system_user_id});
        defer q.deinit();
        const row = (try q.next()) orelse return out;
        defer row.deinit(allocator);
        if (row.values.len >= 4) {
            out.total_users = @intCast(std.fmt.parseInt(i64, row.values[0], 10) catch 0);
            out.active_users = @intCast(std.fmt.parseInt(i64, row.values[1], 10) catch 0);
            out.admin_users = @intCast(std.fmt.parseInt(i64, row.values[2], 10) catch 0);
            out.bot_users = @intCast(std.fmt.parseInt(i64, row.values[3], 10) catch 0);
        }
    }
    {
        var q = try db.query(
            allocator,
            "SELECT COUNT(*) FROM auth_sessions WHERE expires_at > datetime('now')",
            &.{},
        );
        defer q.deinit();
        const row = (try q.next()) orelse return out;
        defer row.deinit(allocator);
        if (row.values.len >= 1) {
            out.active_sessions = @intCast(std.fmt.parseInt(i64, row.values[0], 10) catch 0);
        }
    }
    return out;
}

/// True when another account already uses that email.
pub fn emailTaken(allocator: std.mem.Allocator, db: Db, email: []const u8) !bool {
    var q = try db.query(
        allocator,
        "SELECT 1 FROM users WHERE email = ?",
        &[_][]const u8{email},
    );
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// Create an account. The caller owns the id, the email and the hash. The
/// row is NOT read back: a pooled reader can still be serving the snapshot
/// it opened before this write, so this returns the row it wrote.
pub fn insertUser(
    allocator: std.mem.Allocator,
    db: Db,
    id: []const u8,
    email: []const u8,
    name: []const u8,
    role: admin_common.Role,
    password_hash: []const u8,
    created_at: []const u8,
) Error!UserRow {
    if (emailTaken(allocator, db, email) catch return error.DatabaseError) return error.EmailTaken;
    db.exec(allocator,
        \\INSERT INTO users (id, email, name, password_hash, role, is_active, created_at, updated_at)
        \\VALUES (?, ?, COALESCE(?, ''), ?, ?, 1, ?, ?)
    , &[_][]const u8{ id, email, name, password_hash, admin_common.roleName(role), created_at, created_at }) catch return error.DatabaseError;
    return .{
        .id = try allocator.dupe(u8, id),
        .email = try allocator.dupe(u8, email),
        .name = try allocator.dupe(u8, name),
        .role = try allocator.dupe(u8, admin_common.roleName(role)),
        .is_active = true,
        .created_at = try allocator.dupe(u8, created_at),
        .last_login_at = try allocator.dupe(u8, ""),
    };
}

/// Change an account's role and/or whether it may sign in. The last active
/// owner is never demoted: an installation with no owner cannot be
/// administered again. The row returned is the one written, not a re-read.
pub fn updateUser(
    allocator: std.mem.Allocator,
    db: Db,
    id: []const u8,
    new_role: ?admin_common.Role,
    new_active: ?bool,
) Error!UserRow {
    const current = (findUser(allocator, db, id) catch return error.DatabaseError) orelse return error.UserNotFound;
    defer freeUser(allocator, current);

    const current_role = admin_common.parseRole(current.role) orelse .user;
    const role_after = new_role orelse current_role;
    const active_after = new_active orelse current.is_active;
    const was_owner = current_role == .admin and current.is_active;
    const is_owner_after = role_after == .admin and active_after;

    if (was_owner and !is_owner_after) {
        const owners = countActiveAdmins(allocator, db) catch return error.DatabaseError;
        if (owners <= 1) return error.LastAdmin;
    }

    db.exec(
        allocator,
        "UPDATE users SET role = ?, is_active = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{
            admin_common.roleName(role_after),
            if (active_after) "1" else "0",
            id,
        },
    ) catch return error.DatabaseError;

    return .{
        .id = try allocator.dupe(u8, current.id),
        .email = try allocator.dupe(u8, current.email),
        .name = try allocator.dupe(u8, current.name),
        .role = try allocator.dupe(u8, admin_common.roleName(role_after)),
        .is_active = active_after,
        .created_at = try allocator.dupe(u8, current.created_at),
        .last_login_at = try allocator.dupe(u8, current.last_login_at),
    };
}

/// Replace an account's stored password hash.
pub fn setPasswordHash(
    allocator: std.mem.Allocator,
    db: Db,
    id: []const u8,
    password_hash: []const u8,
) Error!void {
    const current = (findUser(allocator, db, id) catch return error.DatabaseError) orelse return error.UserNotFound;
    defer freeUser(allocator, current);
    db.exec(
        allocator,
        "UPDATE users SET password_hash = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{ password_hash, id },
    ) catch return error.DatabaseError;
}

// =====================================================================
// Tests — in-memory SQLite with the real `users` schema.
// =====================================================================

const testing = std.testing;

/// Create the two tables the console reads, for a database that has none
/// yet. A database pabrik has booted on already has them; this is what makes
/// `pabrik-admin` usable on a fresh file.
pub fn ensureSchema(allocator: std.mem.Allocator, db: Db) !void {
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id TEXT PRIMARY KEY,
        \\    email TEXT NOT NULL UNIQUE,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    password_hash TEXT NOT NULL,
        \\    role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'bot')),
        \\    is_active INTEGER NOT NULL DEFAULT 1,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    last_login_at DATETIME DEFAULT NULL
        \\)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS auth_sessions (
        \\    token_hash TEXT PRIMARY KEY,
        \\    user_id TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    expires_at DATETIME NOT NULL,
        \\    last_seen_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
}

/// The console's own fixtures: the schema plus the synthetic system account.
fn createUsersSchema(allocator: std.mem.Allocator, db: Db) !void {
    try ensureSchema(allocator, db);
    try db.exec(allocator,
        \\INSERT OR IGNORE INTO users (id, email, name, password_hash, role, is_active)
        \\VALUES ('user_system', 'system@local', 'System', '!disabled', 'admin', 0)
    , &.{});
}

fn addUser(
    allocator: std.mem.Allocator,
    db: Db,
    id: []const u8,
    email: []const u8,
    role: []const u8,
    active: bool,
    age: []const u8,
) !void {
    try db.exec(allocator,
        \\INSERT INTO users (id, email, name, password_hash, role, is_active, created_at)
        \\VALUES (?, ?, '', 'x', ?, ?, datetime('now', ?))
    , &[_][]const u8{ id, email, role, if (active) "1" else "0", age });
}

test "listUsers shows every real account and leaves the system account out" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "admin", true, "-3 hours");
    try addUser(alloc, &db, "user_b", "b@example.com", "user", true, "-2 hours");
    try addUser(alloc, &db, "user_c", "c@example.com", "user", false, "-1 hours");

    const users = try listUsers(alloc, &db);
    defer freeUsers(alloc, users);

    try testing.expectEqual(@as(usize, 3), users.len);
    // Oldest first: the order the table shows.
    try testing.expectEqualStrings("user_a", users[0].id);
    try testing.expectEqualStrings("user_b", users[1].id);
    try testing.expectEqualStrings("user_c", users[2].id);
    for (users) |u| try testing.expect(!std.mem.eql(u8, u.id, admin_common.system_user_id));
}

test "findUser answers null for an id nobody carries" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "admin", true, "-1 hours");

    const found = (try findUser(alloc, &db, "user_a")).?;
    defer freeUser(alloc, found);
    try testing.expectEqualStrings("a@example.com", found.email);
    try testing.expect(found.is_active);

    const missing = try findUser(alloc, &db, "user_zz");
    try testing.expect(missing == null);
}

test "overview counts the accounts the console shows, not the system account" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "admin", true, "-3 hours");
    try addUser(alloc, &db, "user_b", "b@example.com", "user", true, "-2 hours");
    try addUser(alloc, &db, "user_c", "c@example.com", "bot", false, "-1 hours");

    const counts = try overview(alloc, &db);
    try testing.expectEqual(@as(u32, 3), counts.total_users);
    try testing.expectEqual(@as(u32, 2), counts.active_users);
    try testing.expectEqual(@as(u32, 1), counts.admin_users);
    try testing.expectEqual(@as(u32, 1), counts.bot_users);
}

test "overview counts only the sessions that have not expired" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try db.exec(alloc,
        \\INSERT INTO auth_sessions (token_hash, user_id, expires_at)
        \\VALUES ('live', 'user_a', datetime('now', '+1 day')),
        \\       ('dead', 'user_a', datetime('now', '-1 day'))
    , &.{});

    const counts = try overview(alloc, &db);
    try testing.expectEqual(@as(u32, 1), counts.active_sessions);
}

test "insertUser stores the account and refuses a second use of the email" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);

    const created = try insertUser(alloc, &db, "user_new", "new@example.com", "New Person", .user, "hash", "2026-01-02 03:04:05");
    defer freeUser(alloc, created);
    try testing.expectEqualStrings("user_new", created.id);
    try testing.expectEqualStrings("new@example.com", created.email);
    try testing.expectEqualStrings("New Person", created.name);
    try testing.expectEqualStrings("user", created.role);
    try testing.expect(created.is_active);
    try testing.expectEqualStrings("2026-01-02 03:04:05", created.created_at);

    const stored = (try findUser(alloc, &db, "user_new")).?;
    defer freeUser(alloc, stored);
    try testing.expectEqualStrings("new@example.com", stored.email);
    try testing.expectEqualStrings("New Person", stored.name);
    try testing.expectEqualStrings("user", stored.role);
    try testing.expect(stored.is_active);
    try testing.expectEqualStrings("2026-01-02 03:04:05", stored.created_at);

    try testing.expectError(error.EmailTaken, insertUser(alloc, &db, "user_2", "new@example.com", "", .user, "hash", "2026-01-02 03:04:05"));
}

test "insertUser accepts an account with no name" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);

    const created = try insertUser(alloc, &db, "user_new", "new@example.com", "", .user, "hash", "2026-01-02 03:04:05");
    defer freeUser(alloc, created);
    try testing.expectEqualStrings("", created.name);

    const stored = (try findUser(alloc, &db, "user_new")).?;
    defer freeUser(alloc, stored);
    try testing.expectEqualStrings("", stored.name);
}

test "updateUser changes the role and whether the account may sign in" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "user", true, "-1 hours");
    try addUser(alloc, &db, "user_b", "b@example.com", "admin", true, "-1 hours");

    const changed = try updateUser(alloc, &db, "user_a", .bot, false);
    defer freeUser(alloc, changed);
    try testing.expectEqualStrings("bot", changed.role);
    try testing.expect(!changed.is_active);

    const stored = (try findUser(alloc, &db, "user_a")).?;
    defer freeUser(alloc, stored);
    try testing.expectEqualStrings("bot", stored.role);
    try testing.expect(!stored.is_active);
}

test "updateUser reports an id nobody carries" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);

    try testing.expectError(error.UserNotFound, updateUser(alloc, &db, "user_zz", .admin, true));
}

test "updateUser refuses to leave the installation without an owner" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "admin", true, "-1 hours");

    try testing.expectError(error.LastAdmin, updateUser(alloc, &db, "user_a", .user, true));
    try testing.expectError(error.LastAdmin, updateUser(alloc, &db, "user_a", .admin, false));

    const untouched = (try findUser(alloc, &db, "user_a")).?;
    defer freeUser(alloc, untouched);
    try testing.expectEqualStrings("admin", untouched.role);
    try testing.expect(untouched.is_active);
}

test "updateUser lets a second owner take over before the first one steps down" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "admin", true, "-2 hours");
    try addUser(alloc, &db, "user_b", "b@example.com", "user", true, "-1 hours");

    const promoted = try updateUser(alloc, &db, "user_b", .admin, true);
    defer freeUser(alloc, promoted);
    try testing.expectEqualStrings("admin", promoted.role);
    const demoted = try updateUser(alloc, &db, "user_a", .user, false);
    defer freeUser(alloc, demoted);
    try testing.expectEqualStrings("user", demoted.role);
    try testing.expect(!demoted.is_active);

    const stored = (try findUser(alloc, &db, "user_a")).?;
    defer freeUser(alloc, stored);
    try testing.expectEqualStrings("user", stored.role);
    try testing.expect(!stored.is_active);
}

test "setPasswordHash replaces the stored hash and reports an unknown id" {
    const alloc = testing.allocator;
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(testing.io, ":memory:");
    try createUsersSchema(alloc, &db);
    try addUser(alloc, &db, "user_a", "a@example.com", "user", true, "-1 hours");

    try setPasswordHash(alloc, &db, "user_a", "new-hash");
    var q = try db.query(alloc, "SELECT password_hash FROM users WHERE id = ?", &[_][]const u8{"user_a"});
    defer q.deinit();
    const row = (try q.next()).?;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("new-hash", row.values[0]);

    try testing.expectError(error.UserNotFound, setPasswordHash(alloc, &db, "user_zz", "x"));
}
