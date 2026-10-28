//! Shared parts of the admin console: who counts as the installation owner,
//! and the pure helpers every admin endpoint repeats.

const std = @import("std");
const database = @import("databases").database;
const auth_core = @import("auth_core");

/// The values `users.role` may take (Migration 077).
pub const Role = enum { admin, user, bot };

pub fn parseRole(raw: []const u8) ?Role {
    if (std.mem.eql(u8, raw, "admin")) return .admin;
    if (std.mem.eql(u8, raw, "user")) return .user;
    if (std.mem.eql(u8, raw, "bot")) return .bot;
    return null;
}

pub fn roleName(role: Role) []const u8 {
    return @tagName(role);
}

/// The synthetic account every installation starts with. It is not a person:
/// it can never sign in, so the console never lists or edits it.
pub const system_user_id = "user_system";

/// Who may use the admin console.
pub const Access = enum {
    /// The installation owner — allowed to change every account.
    owner,
    /// No usable session.
    anonymous,
    /// A session that is not an owner.
    not_owner,
};

/// Decide whether this request may act on ANY account. With `--auth` off the
/// operator owns the installation, so every request is the owner; with it on
/// the session's own `users.role` decides.
pub fn resolveAccess(
    allocator: std.mem.Allocator,
    db: *database.Db,
    auth_enabled: bool,
    headers: anytype,
) Access {
    if (!auth_enabled) return .owner;
    const token = auth_core.parseSessionToken(headers) orelse return .anonymous;
    const sess = auth_core.lookupSession(allocator, db, token) orelse return .anonymous;
    defer auth_core.freeSessionLookup(allocator, sess);
    if (!std.mem.eql(u8, sess.role, roleName(.admin))) return .not_owner;
    return .owner;
}

/// The HTTP status a refusal answers with.
pub fn accessStatus(access: Access) u16 {
    return switch (access) {
        .owner => 200,
        .anonymous => 401,
        .not_owner => 403,
    };
}

pub fn accessMessage(access: Access) []const u8 {
    return switch (access) {
        .owner => "",
        .anonymous => "Sign in as the installation owner to use the admin console",
        .not_owner => "This account is not the installation owner",
    };
}

/// 32 letters and digits, none of them easy to confuse with each other.
pub const password_alphabet = "abcdefghijkmnpqrstuvwxyz23456789";

pub const temporary_password_len = 16;

/// Build a temporary password from random bytes. `byte & 0x1f` is uniform
/// over 32 values, so every alphabet character is equally likely. The caller
/// draws the bytes, which keeps this pure.
pub fn temporaryPassword(allocator: std.mem.Allocator, random_bytes: []const u8) ![]const u8 {
    if (random_bytes.len < temporary_password_len) return error.NotEnoughRandomBytes;
    const out = try allocator.alloc(u8, temporary_password_len);
    for (random_bytes[0..temporary_password_len], 0..) |byte, i| {
        out[i] = password_alphabet[byte & 0x1f];
    }
    return out;
}

/// An id for a new account: `user_` plus hex of the given bytes.
pub fn newUserId(allocator: std.mem.Allocator, random_bytes: []const u8) ![]const u8 {
    if (random_bytes.len < 8) return error.NotEnoughRandomBytes;
    var hex: [16]u8 = undefined;
    const digits = "0123456789abcdef";
    for (random_bytes[0..8], 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0xf];
    }
    return std.fmt.allocPrint(allocator, "user_{s}", .{hex[0..]});
}

/// The email as it is stored: trimmed and lowercased. `users.email` is
/// UNIQUE, so two spellings of one address would be two accounts, and
/// lowercasing makes the console agree with the login form.
pub fn normaliseEmail(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.allocLowerString(allocator, trimmed);
}

/// A usable email address: one `@`, something on both sides, no spaces.
pub fn isValidEmail(email: []const u8) bool {
    if (email.len == 0) return false;
    if (std.mem.indexOfAny(u8, email, " \t\r\n") != null) return false;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0) return false;
    if (at + 1 >= email.len) return false;
    if (std.mem.indexOfScalar(u8, email[at + 1 ..], '@') != null) return false;
    return true;
}

/// End every session of `user_id`. A reset password must not leave a
/// session that was opened with the old one still working.
pub fn revokeSessions(
    allocator: std.mem.Allocator,
    db: *database.Db,
    user_id: []const u8,
) !void {
    try db.exec(
        allocator,
        "DELETE FROM auth_sessions WHERE user_id = ?",
        &[_][]const u8{user_id},
    );
}

/// The current UTC time in the format SQLite's `datetime('now')` writes, moved
/// by `offset_secs` (negative = in the past). The console stamps its own rows,
/// so the value it reports back is the value it stored, not a second reading of
/// a clock it does not control. Writing the stamp ourselves also keeps the
/// tests free of `datetime('now', '-3 hours')`, which postgres does not have.
pub fn utcStamp(allocator: std.mem.Allocator, io: std.Io, offset_secs: i64) ![]u8 {
    const stamp = std.Io.Timestamp.now(io, .real);
    const now: i64 = @intCast(@divTrunc(stamp.nanoseconds, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now + offset_secs) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        @as(u32, @intCast(day_seconds.getHoursIntoDay())),
        @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
        @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
    });
}

/// `utcStamp` for now, the value `created_at` is written with.
pub fn sqliteNow(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return utcStamp(allocator, io, 0);
}

const testing = std.testing;

test "utcStamp writes the datetime('now') format and moves by whole seconds" {
    const alloc = testing.allocator;
    const now = try utcStamp(alloc, testing.io, 0);
    defer alloc.free(now);
    // `YYYY-MM-DD HH:MM:SS`, the shape both backends compare as text.
    try testing.expectEqual(@as(usize, 19), now.len);
    try testing.expectEqual(@as(u8, '-'), now[4]);
    try testing.expectEqual(@as(u8, ':'), now[13]);

    const earlier = try utcStamp(alloc, testing.io, -3600);
    defer alloc.free(earlier);
    try testing.expectEqual(@as(usize, 19), earlier.len);
    // One hour back is a different stamp, and never a later one.
    try testing.expect(!std.mem.eql(u8, now, earlier));
    try testing.expect(std.mem.order(u8, earlier, now) == .lt);
}

test "parseRole accepts exactly the three roles the users table allows" {
    try testing.expectEqual(Role.admin, parseRole("admin").?);
    try testing.expectEqual(Role.user, parseRole("user").?);
    try testing.expectEqual(Role.bot, parseRole("bot").?);
    try testing.expect(parseRole("Admin") == null);
    try testing.expect(parseRole("owner") == null);
    try testing.expect(parseRole("") == null);
}

test "accessStatus answers 401 without a session and 403 for a non-owner" {
    try testing.expectEqual(@as(u16, 200), accessStatus(.owner));
    try testing.expectEqual(@as(u16, 401), accessStatus(.anonymous));
    try testing.expectEqual(@as(u16, 403), accessStatus(.not_owner));
    try testing.expect(accessMessage(.anonymous).len > 0);
    try testing.expect(accessMessage(.not_owner).len > 0);
    try testing.expectEqualStrings("", accessMessage(.owner));
}

test "temporaryPassword draws only from the alphabet and never repeats a byte" {
    const alloc = testing.allocator;
    const bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const pw = try temporaryPassword(alloc, &bytes);
    defer alloc.free(pw);
    try testing.expectEqual(temporary_password_len, pw.len);
    for (pw) |c| {
        try testing.expect(std.mem.indexOfScalar(u8, password_alphabet, c) != null);
    }
    // The same bytes give the same password: the drawing is the only input.
    const again = try temporaryPassword(alloc, &bytes);
    defer alloc.free(again);
    try testing.expectEqualStrings(pw, again);
}

test "temporaryPassword refuses fewer bytes than it needs" {
    const alloc = testing.allocator;
    try testing.expectError(error.NotEnoughRandomBytes, temporaryPassword(alloc, &[_]u8{ 1, 2, 3 }));
}

test "newUserId is prefixed and hex, and rejects a short draw" {
    const alloc = testing.allocator;
    const id = try newUserId(alloc, &[_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33 });
    defer alloc.free(id);
    try testing.expectEqualStrings("user_deadbeef00112233", id);
    try testing.expectError(error.NotEnoughRandomBytes, newUserId(alloc, &[_]u8{ 1, 2, 3 }));
}

test "normaliseEmail trims and lowercases so one address is one account" {
    const alloc = testing.allocator;
    const a = try normaliseEmail(alloc, "  Admin@Example.COM ");
    defer alloc.free(a);
    try testing.expectEqualStrings("admin@example.com", a);
}

test "isValidEmail rejects what a login form would reject" {
    try testing.expect(isValidEmail("admin@example.com"));
    try testing.expect(isValidEmail("a@b"));
    try testing.expect(!isValidEmail(""));
    try testing.expect(!isValidEmail("no-at-sign"));
    try testing.expect(!isValidEmail("@example.com"));
    try testing.expect(!isValidEmail("admin@"));
    try testing.expect(!isValidEmail("a@b@c"));
    try testing.expect(!isValidEmail("admin example@x.com"));
}
