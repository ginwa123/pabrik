//! The part of `--auth` that needs nothing but SQLite and `std.crypto`: the
//! session cookie, the token hash and the password hash. It is its own module
//! so the admin console can link this instead of all of pabrik.

const std = @import("std");
const database = @import("databases").database;

pub const cookie_name = "pabrik_session";

pub const session_max_age_secs: u32 = 30 * 24 * 3600; // 30 days

/// Extract `pabrik_session` cookie value. Returns null for missing,
/// empty, or malformed Cookie headers (empty is treated as absent).
pub fn parseSessionToken(headers: anytype) ?[]const u8 {
    const cookie = headers.get("Cookie") orelse headers.get("cookie") orelse return null;
    if (cookie.len == 0) return null;
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len <= cookie_name.len + 1) continue;
        if (!std.mem.startsWith(u8, trimmed, cookie_name ++ "=")) continue;
        const val = std.mem.trim(u8, trimmed[cookie_name.len + 1 ..], " \t\"");
        if (val.len == 0) return null;
        return val;
    }
    return null;
}

/// Hex-encode SHA-256(token) into a 64-char lowercase string.
pub fn sha256Hex(token: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

pub const SessionLookup = struct {
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
};

/// A session is live while `expires_at` is still in the future and the account
/// can still sign in. The comparison is spelled per backend (UTC on both), so
/// it does not depend on migration 121's `datetime()` shim existing in the
/// database being read.
///
/// This is `dialect.now_stamp_utc`, repeated because this file is compiled as
/// its own module (`auth_core`) and `dialect.zig` already belongs to
/// `pabrikcore` — a file may belong to one module only.
const live_session = " AND s.expires_at > " ++
    (if (database.backend_is_postgres) "(now() AT TIME ZONE 'UTC')" else "datetime('now')") ++
    " AND u.is_active = 1";

/// Validate a raw cookie token against `auth_sessions` + `users`, or null
/// when it is empty, unknown, expired, or the account is switched off.
pub fn lookupSession(
    allocator: std.mem.Allocator,
    db: *database.Db,
    raw_token: []const u8,
) ?SessionLookup {
    if (raw_token.len == 0) return null;
    var hash_hex: [64]u8 = undefined;
    sha256Hex(raw_token, &hash_hex);

    var q = db.query(allocator,
        \\SELECT s.user_id, u.email, COALESCE(CAST(u.name AS TEXT), ''), u.role
        \\FROM auth_sessions s JOIN users u ON u.id = s.user_id
        \\WHERE s.token_hash = ?
    ++ live_session
    , &[_][]const u8{hash_hex[0..]}) catch return null;
    defer q.deinit();
    const row = q.next() catch return null;
    const r = row orelse return null;
    defer r.deinit(allocator);
    if (r.values.len < 4) return null;
    return SessionLookup{
        .user_id = allocator.dupe(u8, r.values[0]) catch return null,
        .email = allocator.dupe(u8, r.values[1]) catch return null,
        .name = allocator.dupe(u8, r.values[2]) catch return null,
        .role = allocator.dupe(u8, r.values[3]) catch return null,
    };
}

pub fn freeSessionLookup(allocator: std.mem.Allocator, s: SessionLookup) void {
    allocator.free(s.user_id);
    allocator.free(s.email);
    allocator.free(s.name);
    allocator.free(s.role);
}

/// Verify a password against a stored `users.password_hash`. The sentinel
/// `!disabled` (the system account) always fails, and any format other than
/// bcrypt fails closed.
pub fn verifyPassword(stored_hash: []const u8, password: []const u8) bool {
    if (stored_hash.len == 0 or password.len == 0) return false;
    if (std.mem.eql(u8, stored_hash, "!disabled")) return false;
    std.crypto.pwhash.bcrypt.strVerify(stored_hash, password, .{ .silently_truncate_password = true }) catch return false;
    return true;
}

/// Hash a password with bcrypt for storage in `users.password_hash`.
pub fn hashPassword(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    var out_buf: [256]u8 = undefined;
    const hash_slice = try std.crypto.pwhash.bcrypt.strHash(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &out_buf, io);
    return allocator.dupe(u8, hash_slice);
}

/// Build a `Set-Cookie` value for the session cookie.
pub fn setCookieValue(allocator: std.mem.Allocator, raw_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}", .{ cookie_name, raw_token, session_max_age_secs });
}

pub fn clearCookieValue(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", .{cookie_name});
}
