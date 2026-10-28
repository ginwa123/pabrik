//! `POST /api/auth/password` — a signed-in user rotates their own password.
//! Verifies the current password, applies the length policy, re-hashes with
//! bcrypt, then revokes every OTHER session so a leaked cookie dies here.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");

/// Mirrors `create-admin`'s floor, so an account cannot be rotated into a
/// password the CLI would have refused to create.
pub const min_password_len: usize = 8;

/// bcrypt stops reading after 72 bytes and `silently_truncate_password`
/// hides that, so a longer password is rejected rather than quietly weakened.
pub const max_password_len: usize = 72;

pub const Rejection = enum {
    auth_disabled,
    not_authenticated,
    wrong_current_password,
    too_short,
    too_long,
    same_as_current,
};

pub const Outcome = union(enum) {
    /// The change landed; the payload is how many OTHER sessions were revoked.
    changed: usize,
    rejected: Rejection,
};

fn countRows(
    allocator: std.mem.Allocator,
    db: *database.Db,
    sql: []const u8,
    argv: []const []const u8,
) !usize {
    var q = try db.query(allocator, sql, argv);
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(allocator);
    if (row.values.len == 0) return 0;
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

/// Delete every session of `user_id` whose token is not `keep_token_hash`,
/// returning how many rows went. An empty `keep_token_hash` revokes all.
fn revokeSessions(
    allocator: std.mem.Allocator,
    db: *database.Db,
    user_id: []const u8,
    keep_token_hash: []const u8,
) !usize {
    const revoked = try countRows(
        allocator,
        db,
        "SELECT COUNT(*) FROM auth_sessions WHERE user_id = ? AND token_hash <> ?",
        &[_][]const u8{ user_id, keep_token_hash },
    );
    try db.exec(
        allocator,
        "DELETE FROM auth_sessions WHERE user_id = ? AND token_hash <> ?",
        &[_][]const u8{ user_id, keep_token_hash },
    );
    return revoked;
}

/// The whole change-password use case, transport-free so behavior tests can
/// drive it against an in-memory database. `current_token` is the raw cookie
/// value: it identifies the session that asked and therefore survives.
pub fn changePassword(
    allocator: std.mem.Allocator,
    db: *database.Db,
    io: std.Io,
    user_id: []const u8,
    current_token: ?[]const u8,
    current_password: []const u8,
    new_password: []const u8,
) !Outcome {
    if (user_id.len == 0) return .{ .rejected = .not_authenticated };

    var q = try db.query(
        allocator,
        "SELECT password_hash FROM users WHERE id = ? AND is_active = 1",
        &[_][]const u8{user_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return .{ .rejected = .not_authenticated };
    defer row.deinit(allocator);
    if (row.values.len == 0) return .{ .rejected = .not_authenticated };
    const stored_hash = row.values[0];

    // The current password is checked first: a caller who cannot prove they
    // own the account learns nothing about the policy for the new one.
    if (!auth_common.verifyPassword(stored_hash, current_password)) {
        return .{ .rejected = .wrong_current_password };
    }
    if (new_password.len < min_password_len) return .{ .rejected = .too_short };
    if (new_password.len > max_password_len) return .{ .rejected = .too_long };
    if (auth_common.verifyPassword(stored_hash, new_password)) {
        return .{ .rejected = .same_as_current };
    }

    const new_hash = try auth_common.hashPassword(allocator, io, new_password);
    defer allocator.free(new_hash);
    try db.exec(
        allocator,
        "UPDATE users SET password_hash = ?, updated_at = datetime('now') WHERE id = ?",
        &[_][]const u8{ new_hash, user_id },
    );

    var hash_buf: [64]u8 = undefined;
    const keep: []const u8 = blk: {
        const tok = current_token orelse break :blk "";
        if (tok.len == 0) break :blk "";
        auth_common.sha256Hex(tok, &hash_buf);
        break :blk hash_buf[0..];
    };
    const revoked = try revokeSessions(allocator, db, user_id, keep);
    return .{ .changed = revoked };
}

pub const ChangePasswordBody = struct {
    current_password: []const u8 = "",
    new_password: []const u8 = "",
};

fn rejectStatus(rejection: Rejection) struct { status: u16, code: []const u8 } {
    return switch (rejection) {
        .auth_disabled => .{ .status = 409, .code = "AuthDisabled" },
        .not_authenticated => .{ .status = 401, .code = "Unauthenticated" },
        .wrong_current_password => .{ .status = 403, .code = "WrongCurrentPassword" },
        .too_short => .{ .status = 400, .code = "PasswordTooShort" },
        .too_long => .{ .status = 400, .code = "PasswordTooLong" },
        .same_as_current => .{ .status = 400, .code = "PasswordUnchanged" },
    };
}

fn reject(
    res: gserverz.HttpResponse,
    allocator: std.mem.Allocator,
    rejection: Rejection,
) !gserverz.HttpResponse {
    const mapped = rejectStatus(rejection);
    return res.jsonResponse(.{
        .status_code = mapped.status,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = mapped.code }),
    });
}

pub fn authChangePasswordHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    // No accounts exist without `--auth`, so there is nothing to verify and
    // the UI is told to hide the form instead of failing on every submit.
    if (!di.auth_enabled) return reject(res, allocator, .auth_disabled);

    const token = auth_common.parseSessionToken(req.headers) orelse
        return reject(res, allocator, .not_authenticated);
    const sess = auth_common.lookupSession(allocator, di.db, token) orelse
        return reject(res, allocator, .not_authenticated);
    defer auth_common.freeSessionLookup(allocator, sess);

    const parsed = std.json.parseFromSliceLeaky(ChangePasswordBody, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "InvalidBody" }),
        });
    };

    const outcome = changePassword(
        allocator,
        di.db,
        ctx.io,
        sess.user_id,
        token,
        parsed.current_password,
        parsed.new_password,
    ) catch |err| {
        std.log.err("auth_password: change failed for {s}: {s}", .{ sess.email, @errorName(err) });
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "PasswordChangeFailed" }),
        });
    };

    return switch (outcome) {
        .rejected => |rejection| reject(res, allocator, rejection),
        .changed => |revoked| blk: {
            std.log.info("auth_password: {s} changed their password ({d} other sessions revoked)", .{ sess.email, revoked });
            const data = try std.json.Stringify.valueAlloc(allocator, .{
                .ok = true,
                .sessions_revoked = revoked,
            }, .{});
            break :blk res.jsonResponse(.{ .status_code = 200, .data = data });
        },
    };
}

// ============================================================================
// Behavior tests — in-memory SQLite, no HTTP, no globals.
// ============================================================================

const testing = std.testing;

fn setupSchema(alloc: std.mem.Allocator, db: *database.Db) !void {
    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  password_hash TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'user',
        \\  is_active INTEGER NOT NULL DEFAULT 1,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE auth_sessions (
        \\  token_hash TEXT PRIMARY KEY,
        \\  user_id TEXT NOT NULL,
        \\  expires_at TIMESTAMP NOT NULL
        \\)
    , &[_][]const u8{});
}

fn insertUser(db: *database.Db, alloc: std.mem.Allocator, io: std.Io, user_id: []const u8, password: []const u8) !void {
    const hash = try auth_common.hashPassword(alloc, io, password);
    defer alloc.free(hash);
    try db.exec(alloc, "INSERT INTO users (id, email, password_hash) VALUES (?, ?, ?)", &[_][]const u8{ user_id, user_id, hash });
}

fn insertSession(db: *database.Db, alloc: std.mem.Allocator, raw_token: []const u8, user_id: []const u8) !void {
    var hash: [64]u8 = undefined;
    auth_common.sha256Hex(raw_token, &hash);
    try db.exec(alloc, "INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, ?, datetime('now', '+1 day'))", &[_][]const u8{ hash[0..], user_id });
}

fn storedHash(db: *database.Db, alloc: std.mem.Allocator, user_id: []const u8) ![]u8 {
    var q = try db.query(alloc, "SELECT password_hash FROM users WHERE id = ?", &[_][]const u8{user_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

fn sessionCount(db: *database.Db, alloc: std.mem.Allocator, user_id: []const u8) !usize {
    return countRows(
        alloc,
        db,
        "SELECT COUNT(*) FROM auth_sessions WHERE user_id = ?",
        &[_][]const u8{user_id},
    );
}

fn sessionSurvives(db: *database.Db, alloc: std.mem.Allocator, raw_token: []const u8) !bool {
    var hash: [64]u8 = undefined;
    auth_common.sha256Hex(raw_token, &hash);
    const n = try countRows(
        alloc,
        db,
        "SELECT COUNT(*) FROM auth_sessions WHERE token_hash = ?",
        &[_][]const u8{hash[0..]},
    );
    return n == 1;
}

const Ctx = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    db: database.Db,

    fn open() !Ctx {
        const alloc = testing.allocator;
        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();
        var db: database.Db = .{};
        errdefer db.deinit();
        try test_db.openMemory(&db, threaded.io());
        try setupSchema(alloc, &db);
        return .{ .alloc = alloc, .threaded = threaded, .db = db };
    }

    fn close(self: *Ctx) void {
        self.db.deinit();
        self.threaded.deinit();
    }

    fn io(self: *Ctx) std.Io {
        return self.threaded.io();
    }
};

test "a correct current password and a valid new one replaces the stored hash" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", "new-password-1");

    try testing.expectEqual(@as(usize, 0), outcome.changed);
    const hash = try storedHash(&ctx.db, ctx.alloc, "user_a");
    defer ctx.alloc.free(hash);
    try testing.expect(auth_common.verifyPassword(hash, "new-password-1"));
    try testing.expect(!auth_common.verifyPassword(hash, "old-password-1"));
}

test "a wrong current password leaves the stored hash untouched" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "not-my-password", "new-password-1");

    try testing.expectEqual(Rejection.wrong_current_password, outcome.rejected);
    const hash = try storedHash(&ctx.db, ctx.alloc, "user_a");
    defer ctx.alloc.free(hash);
    try testing.expect(auth_common.verifyPassword(hash, "old-password-1"));
}

test "a new password one character under the minimum is rejected" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    var short: [max_password_len]u8 = undefined;
    @memset(&short, 'x');
    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", short[0 .. min_password_len - 1]);

    try testing.expectEqual(Rejection.too_short, outcome.rejected);
}

test "a new password exactly at the minimum length is accepted" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    const eight = "abcdefgh";
    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", eight);

    try testing.expectEqual(@as(usize, 0), outcome.changed);
    const hash = try storedHash(&ctx.db, ctx.alloc, "user_a");
    defer ctx.alloc.free(hash);
    try testing.expect(auth_common.verifyPassword(hash, eight));
}

test "a new password past bcrypt's 72-byte limit is rejected rather than truncated" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    var long: [max_password_len + 1]u8 = undefined;
    @memset(&long, 'y');
    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", long[0..]);

    try testing.expectEqual(Rejection.too_long, outcome.rejected);
}

test "reusing the current password is rejected" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", "old-password-1");

    try testing.expectEqual(Rejection.same_as_current, outcome.rejected);
}

test "changing a password signs out every other session and keeps the one that asked" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");
    try insertSession(&ctx.db, ctx.alloc, "laptop", "user_a");
    try insertSession(&ctx.db, ctx.alloc, "phone", "user_a");
    try insertSession(&ctx.db, ctx.alloc, "tablet", "user_a");

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "laptop", "old-password-1", "new-password-1");

    try testing.expectEqual(@as(usize, 2), outcome.changed);
    try testing.expectEqual(@as(usize, 1), try sessionCount(&ctx.db, ctx.alloc, "user_a"));
    try testing.expect(try sessionSurvives(&ctx.db, ctx.alloc, "laptop"));
    try testing.expect(!try sessionSurvives(&ctx.db, ctx.alloc, "phone"));
}

test "a rejected change leaves every session signed in" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");
    try insertSession(&ctx.db, ctx.alloc, "laptop", "user_a");
    try insertSession(&ctx.db, ctx.alloc, "phone", "user_a");

    _ = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "laptop", "wrong", "new-password-1");

    try testing.expectEqual(@as(usize, 2), try sessionCount(&ctx.db, ctx.alloc, "user_a"));
}

test "another user's password cannot be rotated" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_a", "old-password-1");
    try insertUser(&ctx.db, ctx.alloc, ctx.io(), "user_b", "old-password-1");
    try insertSession(&ctx.db, ctx.alloc, "bob-laptop", "user_b");

    _ = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_a", "tok", "old-password-1", "new-password-1");

    const bob_hash = try storedHash(&ctx.db, ctx.alloc, "user_b");
    defer ctx.alloc.free(bob_hash);
    try testing.expect(auth_common.verifyPassword(bob_hash, "old-password-1"));
    try testing.expect(try sessionSurvives(&ctx.db, ctx.alloc, "bob-laptop"));
}

test "the disabled system account can never verify a current password" {
    var ctx = try Ctx.open();
    defer ctx.close();
    try ctx.db.exec(ctx.alloc, "INSERT INTO users (id, email, password_hash, role) VALUES ('user_system', 'system@pabrik.local', '!disabled', 'bot')", &[_][]const u8{});
    try insertSession(&ctx.db, ctx.alloc, "sys", "user_system");

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_system", "sys", "", "new-password-1");

    try testing.expectEqual(Rejection.wrong_current_password, outcome.rejected);
    try testing.expect(try sessionSurvives(&ctx.db, ctx.alloc, "sys"));
}

test "an unknown user id is rejected without touching any row" {
    var ctx = try Ctx.open();
    defer ctx.close();

    const outcome = try changePassword(ctx.alloc, &ctx.db, ctx.io(), "user_ghost", "tok", "old-password-1", "new-password-1");

    try testing.expectEqual(Rejection.not_authenticated, outcome.rejected);
}

test "an empty user id is rejected before the database is read" {
    const outcome = try changePassword(testing.allocator, undefined, testing.io, "", null, "a", "b");
    try testing.expectEqual(Rejection.not_authenticated, outcome.rejected);
}
