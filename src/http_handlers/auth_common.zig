//! Shared auth helpers for opt-in `--auth` mode. `users` (Migration 077)
//! stores identity; `auth_sessions` (Migration 089) stores one row per active
//! `pabrik_session` cookie (SHA-256 hash -> user).

const std = @import("std");
const pabrikcore = @import("pabrikcore");

pub const cookie_name = "pabrik_session";

pub const session_max_age_secs: u32 = 30 * 24 * 3600; // 30 days

/// Paths that never require auth even when `--auth` is on.
/// Exact match only (not prefix) to avoid accidentally opening /api/authX.
pub fn isAuthExempt(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/api/auth/login")) return true;
    if (std.mem.eql(u8, path, "/api/auth/logout")) return true;
    if (std.mem.eql(u8, path, "/health")) return true;
    if (std.mem.eql(u8, path, "/api/health")) return true;
    return false;
}

/// Extract `pabrik_session` cookie value. Returns null for missing,
/// empty, or malformed Cookie headers (empty is treated as absent,
/// never as a value — see the `""`-as-value pitfall).
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
        // Basic sanity: opaque hex token we issue is 64 chars.
        // Accept anything non-empty here; DB lookup is the real gate.
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

/// Validate a raw cookie token against `auth_sessions` + `users`.
/// Returns null when: token empty, unknown hash, expired, or user inactive.
/// Caller owns the duped slices in the returned struct (free with allocator).
pub fn lookupSession(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    raw_token: []const u8,
) ?SessionLookup {
    if (raw_token.len == 0) return null;
    var hash_hex: [64]u8 = undefined;
    sha256Hex(raw_token, &hash_hex);

    var q = db.query(allocator,
        \\SELECT s.user_id, u.email, COALESCE(u.name, ''), u.role
        \\FROM auth_sessions s JOIN users u ON u.id = s.user_id
        \\WHERE s.token_hash = ? AND s.expires_at > datetime('now') AND u.is_active = 1
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

// =====================================================================
// Per-request owner resolution — the input to per-user row isolation.
// =====================================================================

/// Sentinel owner id: Migration 077's backfill target for every row that
/// predates `--auth`, and the answer `resolveRequestUserId` gives whenever
/// identity cannot be established.
pub const system_user_id = "user_system";

/// SQL predicate for "rows that `alias` may see".
pub fn ownerVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "(? = '{s}' OR {s}.user_id IS NULL OR {s}.user_id = '' OR {s}.user_id = '{s}' OR {s}.user_id = ?)",
        .{ system_user_id, alias, alias, alias, system_user_id, alias },
    );
}

/// SQL predicate for "workspaces `alias` may see", backed by the
/// `workspace_members` join table (Migration 100). This is the successor to
/// `ownerVisibilityClause` for WORKSPACES ONLY.
pub fn workspaceVisibilityClause(comptime alias: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "(? = '{s}' OR EXISTS (SELECT 1 FROM workspace_members m WHERE m.workspace_id = {s}.id AND (m.user_id = ? OR m.user_id = '{s}')))",
        .{ system_user_id, alias, system_user_id },
    );
}

/// Map an owner id onto something safe to bind into a NOT NULL column.
pub fn normaliseOwnerId(user_id: []const u8) []const u8 {
    return if (user_id.len == 0) system_user_id else user_id;
}

/// True when `user_id` is the shared/legacy bucket rather than a real
/// owner. Callers use this to detect (and log) writes that fell back to
/// the sentinel while `--auth` was on — a mis-scoping signal.
pub fn isSharedOwner(user_id: []const u8) bool {
    return user_id.len == 0 or std.mem.eql(u8, user_id, system_user_id);
}

/// True when a `sessions` row with this id exists at all, regardless of
/// owner.
pub fn sessionExistsById(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    if (session_id.len == 0) return false;
    var q = db.query(
        allocator,
        "SELECT 1 FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// True when `workspace_id` exists AND the given owner may see it.
pub fn canSeeWorkspace(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    workspace_id: []const u8,
    owner: []const u8,
) bool {
    if (workspace_id.len == 0) return false;
    var q = db.query(
        allocator,
        "SELECT 1 FROM workspaces WHERE id = ? AND " ++ comptime workspaceVisibilityClause("workspaces"),
        &[_][]const u8{ workspace_id, owner, owner },
    ) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// Session counterpart of `canSeeWorkspace`: true when `session_id` exists
/// AND the given owner may see it.
pub fn canSeeSession(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
    owner: []const u8,
) bool {
    if (session_id.len == 0) return false;
    var q = db.query(
        allocator,
        "SELECT 1 FROM sessions WHERE id = ? AND " ++ comptime ownerVisibilityClause("sessions"),
        &[_][]const u8{ session_id, owner, owner },
    ) catch return false;
    defer q.deinit();
    const row = q.next() catch return false;
    if (row) |r| {
        r.deinit(allocator);
        return true;
    }
    return false;
}

/// Resolve the owner id for the current request, server-side.
pub fn resolveRequestUserId(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    auth_enabled: bool,
    headers: anytype,
) ![]const u8 {
    if (!auth_enabled) return allocator.dupe(u8, system_user_id);
    const token = parseSessionToken(headers) orelse return allocator.dupe(u8, system_user_id);
    const sess = lookupSession(allocator, db, token) orelse return allocator.dupe(u8, system_user_id);
    // Keep only the owner id; the rest of the identity is not needed here.
    allocator.free(sess.email);
    allocator.free(sess.name);
    allocator.free(sess.role);
    return sess.user_id;
}

/// Buffer-writing variant of `resolveRequestUserId` for callers that want to
/// avoid a heap allocation (the terminal handlers, whose owner is a short
/// per-request string).
pub fn resolveOwnerInto(buf: []u8, headers: anytype) ?[]const u8 {
    const di = pabrikcore.getSingleton() catch return null;
    const owner = resolveRequestUserId(di.allocator, di.db, di.auth_enabled, headers) catch return null;
    defer di.allocator.free(owner);
    if (owner.len > buf.len) return null;
    @memcpy(buf[0..owner.len], owner);
    return buf[0..owner.len];
}

/// The `LlmConfig` for the user behind `headers`, or null when the
/// process-global singleton is authoritative.
pub fn requestUserConfig(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    auth_enabled: bool,
    headers: anytype,
) ?*pabrikcore.config.LlmConfig {
    // File mode: the config PUT swaps the singleton synchronously, so it is
    // already the authority. Reading the database here would add a second
    // source that can only ever disagree with it.
    if (!auth_enabled) return null;
    const owner = resolveRequestUserId(allocator, db, auth_enabled, headers) catch return null;
    defer allocator.free(owner);
    return pabrikcore.session_llm_config.forOwner(allocator, db, owner);
}

/// Verify a password against a stored `users.password_hash`.
/// Sentinel `!disabled` (user_system) always fails. Supports bcrypt
/// hashes; any other format fails closed.
pub fn verifyPassword(stored_hash: []const u8, password: []const u8) bool {
    if (stored_hash.len == 0 or password.len == 0) return false;
    if (std.mem.eql(u8, stored_hash, "!disabled")) return false;
    std.crypto.pwhash.bcrypt.strVerify(stored_hash, password, .{ .silently_truncate_password = true }) catch return false;
    return true;
}

/// Hash a password with bcrypt for storage in `users.password_hash`.
/// Returns an owned slice.
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

// ===================================================================== Tests
// (in-memory SQLite via useCase-adjacent helpers is covered in
// auth_login_test; here we test pure helpers with no DB).

test "isAuthExempt allows login/logout/health only" {
    try std.testing.expect(isAuthExempt("/api/auth/login"));
    try std.testing.expect(isAuthExempt("/api/auth/logout"));
    try std.testing.expect(isAuthExempt("/health"));
    try std.testing.expect(isAuthExempt("/api/health"));
    try std.testing.expect(!isAuthExempt("/api/workspaces"));
    try std.testing.expect(!isAuthExempt("/api/auth/me"));
    try std.testing.expect(!isAuthExempt("/api/auth/loginX"));
}

test "parseSessionToken handles empty as absent" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "");
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "pabrik_session=");
    try std.testing.expect(parseSessionToken(m) == null);
    try m.put("Cookie", "other=1; pabrik_session=abc123; x=2");
    const v = parseSessionToken(m) orelse return error.Missing;
    try std.testing.expectEqualStrings("abc123", v);
}

test "sha256Hex is stable and lowercase hex" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    sha256Hex("hello", &a);
    sha256Hex("hello", &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
    for (a) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
}

test "verifyPassword rejects sentinel and empty" {
    try std.testing.expect(!verifyPassword("!disabled", "anything"));
    try std.testing.expect(!verifyPassword("", "x"));
    try std.testing.expect(!verifyPassword("$2b$10$xxx", ""));
}

test "ownerVisibilityClause lets the system user see everything" {
    const sql = ownerVisibilityClause("w");
    // The sentinel test comes FIRST, which is why callers bind the owner twice.
    try std.testing.expect(std.mem.startsWith(u8, sql, "(? = 'user_system' OR "));
    try std.testing.expect(std.mem.indexOf(u8, sql, "w.user_id IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "w.user_id = ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "w.user_id = 'user_system'") != null);
    // The viewer's id is always the trailing bind parameter.
    try std.testing.expect(std.mem.endsWith(u8, sql, "w.user_id = ?)"));
    // And the alias is honoured (callers use real table aliases).
    const h = ownerVisibilityClause("h");
    try std.testing.expect(std.mem.indexOf(u8, h, "h.user_id IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "w.") == null);
}

test "canSeeSession: own + shared visible, another user's hidden, system sees all" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('s_a','user_a'), ('s_b','user_b'), ('s_legacy',NULL)", &.{});

    // Own session and shared legacy row: visible.
    try std.testing.expect(canSeeSession(alloc, &db, "s_a", "user_a"));
    try std.testing.expect(canSeeSession(alloc, &db, "s_legacy", "user_a"));
    // Another user's session: hidden. This is the leak the middleware closes.
    try std.testing.expect(!canSeeSession(alloc, &db, "s_b", "user_a"));
    // The system user (auth off) sees everything, by decision 2026-09-25.
    try std.testing.expect(canSeeSession(alloc, &db, "s_b", system_user_id));
    try std.testing.expect(canSeeSession(alloc, &db, "s_a", system_user_id));
    // Unknown / empty ids are never visible.
    try std.testing.expect(!canSeeSession(alloc, &db, "s_missing", "user_a"));
    try std.testing.expect(!canSeeSession(alloc, &db, "", "user_a"));
}

test "resolveRequestUserId falls back to the sentinel without identity" {
    // Both the auth-off path and the auth-on-with-no-cookie path return
    // before the DB is touched, so an undefined db is safe here.
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();

    const off = try resolveRequestUserId(std.testing.allocator, undefined, false, headers);
    defer std.testing.allocator.free(off);
    try std.testing.expectEqualStrings(system_user_id, off);

    const on = try resolveRequestUserId(std.testing.allocator, undefined, true, headers);
    defer std.testing.allocator.free(on);
    try std.testing.expectEqualStrings(system_user_id, on);
}

test "resolveRequestUserId maps a valid cookie to the owning user" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE users (
        \\  id TEXT PRIMARY KEY,
        \\  email TEXT NOT NULL,
        \\  name TEXT NOT NULL DEFAULT '',
        \\  password_hash TEXT NOT NULL,
        \\  role TEXT NOT NULL DEFAULT 'user',
        \\  is_active INTEGER NOT NULL DEFAULT 1
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE auth_sessions (
        \\  token_hash TEXT PRIMARY KEY,
        \\  user_id TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  expires_at DATETIME NOT NULL,
        \\  last_seen_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(alloc, "INSERT INTO users (id, email, password_hash) VALUES ('user_a', 'a@example.com', 'x')", &.{});

    const token = "deadbeef";
    var hash: [64]u8 = undefined;
    sha256Hex(token, &hash);
    try db.exec(alloc, "INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES (?, 'user_a', datetime('now', '+1 day'))", &[_][]const u8{hash[0..]});

    var headers = std.StringHashMap([]const u8).init(alloc);
    defer headers.deinit();
    try headers.put("Cookie", "pabrik_session=deadbeef");
    const owner = try resolveRequestUserId(alloc, &db, true, headers);
    defer alloc.free(owner);
    try std.testing.expectEqualStrings("user_a", owner);

    // An unknown token is not an error — it resolves to the shared bucket.
    var anon = std.StringHashMap([]const u8).init(alloc);
    defer anon.deinit();
    try anon.put("Cookie", "pabrik_session=unknown");
    const stranger = try resolveRequestUserId(alloc, &db, true, anon);
    defer alloc.free(stranger);
    try std.testing.expectEqualStrings(system_user_id, stranger);
}

// ============================================================================
// workspace_members — visibility clause + owner normalisation
// ============================================================================

fn countByte(haystack: []const u8, needle: u8) usize {
    var n: usize = 0;
    for (haystack) |c| {
        if (c == needle) n += 1;
    }
    return n;
}

test "workspaceVisibilityClause keeps the two-bind arity the call sites already use" {
    const sql = workspaceVisibilityClause("workspaces");

    // THE load-bearing assertion.
    try std.testing.expectEqual(@as(usize, 2), countByte(sql, '?'));

    // The sentinel test comes FIRST and short-circuits before the subquery,
    // which is what makes auth-off ("no identity, so the installation sees
    // everything") free rather than a full table scan.
    try std.testing.expect(std.mem.startsWith(u8, sql, "(? = 'user_system' OR EXISTS ("));
}

test "workspaceVisibilityClause expresses membership OR the shared legacy bucket" {
    const sql = workspaceVisibilityClause("w");
    // The caller is a member...
    try std.testing.expect(std.mem.indexOf(u8, sql, "FROM workspace_members") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "m.workspace_id = w.id") != null);
    // ...OR the workspace carries the sentinel member, i.e. it is shared.
    // This is what keeps a pre-`--auth` workspace visible to everyone, and
    // it is why adding that one member row IS the "share" operation.
    try std.testing.expect(std.mem.indexOf(u8, sql, "m.user_id = 'user_system'") != null);

    // The alias must be honoured, or the query will not compile: passing "w"
    // must never emit a bare `workspaces.`.
    try std.testing.expect(std.mem.indexOf(u8, sql, "workspaces.") == null);
    const other = workspaceVisibilityClause("ws");
    try std.testing.expect(std.mem.indexOf(u8, other, "m.workspace_id = ws.id") != null);
    try std.testing.expect(countByte(other, '?') == 2);
}

test "workspaceVisibilityClause never reads workspaces.user_id" {
    // The column is deprecated in Migration 100 but still EXISTS on disk.
    // If this clause ever grew a `{alias}.user_id` arm again, the membership
    // table would stop being the source of truth and the two could drift.
    const sql = workspaceVisibilityClause("workspaces");
    try std.testing.expect(std.mem.indexOf(u8, sql, "user_id IS NULL") == null);
    try std.testing.expect(std.mem.indexOf(u8, sql, ".user_id = ''") == null);
}

test "normaliseOwnerId maps an empty owner to the sentinel, never NULL" {
    // SqliteBackend.exec binds an empty slice as SQL NULL, and
    // workspace_members.user_id is NOT NULL. Binding a raw empty owner is a
    // runtime constraint violation — this helper is what prevents it.
    try std.testing.expectEqualStrings(system_user_id, normaliseOwnerId(""));
    try std.testing.expectEqualStrings(system_user_id, normaliseOwnerId(system_user_id));
    try std.testing.expectEqualStrings("user_a", normaliseOwnerId("user_a"));
}

test "normaliseOwnerId is exactly isSharedOwner for the empty case" {
    // The two must not drift: `workspaces_reorder` treats a shared owner as
    // "see everything", so normalising to the sentinel has to agree with it.
    try std.testing.expect(isSharedOwner(normaliseOwnerId("")));
    try std.testing.expect(!isSharedOwner(normaliseOwnerId("user_a")));
}
