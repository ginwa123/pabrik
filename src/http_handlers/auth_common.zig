//! Shared auth helpers for opt-in `--auth` mode. `users` (Migration 077)
//! stores identity; `auth_sessions` (Migration 089) stores one row per active
//! `pabrik_session` cookie (SHA-256 hash -> user).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_core = @import("auth_core");

// The session cookie and the token/password helpers live in `auth_core.zig`,
// which needs nothing but `databases` and `std.crypto`, so a program that
// only checks a session can compile against that instead of all of pabrik.
pub const cookie_name = auth_core.cookie_name;
pub const session_max_age_secs = auth_core.session_max_age_secs;
pub const parseSessionToken = auth_core.parseSessionToken;
pub const sha256Hex = auth_core.sha256Hex;
pub const SessionLookup = auth_core.SessionLookup;
pub const lookupSession = auth_core.lookupSession;
pub const freeSessionLookup = auth_core.freeSessionLookup;
pub const verifyPassword = auth_core.verifyPassword;
pub const hashPassword = auth_core.hashPassword;
pub const setCookieValue = auth_core.setCookieValue;
pub const clearCookieValue = auth_core.clearCookieValue;

/// Paths that never require auth even when `--auth` is on.
/// Exact match only (not prefix) to avoid accidentally opening /api/authX.
pub fn isAuthExempt(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/api/auth/login")) return true;
    if (std.mem.eql(u8, path, "/api/auth/logout")) return true;
    if (std.mem.eql(u8, path, "/health")) return true;
    if (std.mem.eql(u8, path, "/api/health")) return true;
    return false;
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

/// The `LlmConfig` for `(the user behind headers, workspace_id)`, or null when
/// neither the workspace row nor a user document resolves — the caller then
/// falls back to the singleton.
pub fn requestWorkspaceConfig(
    allocator: std.mem.Allocator,
    di: *pabrikcore.App,
    workspace_id: []const u8,
    headers: anytype,
) ?*pabrikcore.config.LlmConfig {
    if (workspace_id.len == 0) return null;
    const owner = resolveRequestUserId(allocator, di.db, di.auth_enabled, headers) catch return null;
    defer allocator.free(owner);
    return pabrikcore.session_llm_config.forOwnerAndWorkspace(
        allocator,
        di.io,
        di.db,
        di.environment,
        di.auth_enabled,
        owner,
        workspace_id,
    );
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
