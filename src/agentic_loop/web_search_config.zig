//! Per-session resolution of the `web_search` provider map.
//! `ToolExecContext.config` (`src/agentic_loop/tools.zig:101`) is the
//! `LlmConfig` SINGLETON.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const config_mod = @import("../modules/config/Config.zig");
const session_llm_config = @import("session_llm_config.zig");
const workspace_settings_store = @import("workspace_settings_store.zig");

pub const Providers = config_mod.LlmConfig.WebSearchProvidersMap;

/// Just enough of the user's stored config to reach the block.
/// `ignore_unknown_fields` keeps every unrelated key from being a parse
/// error — the stored document is the whole `config.json`, not a fragment.
const UserConfigHolder = struct {
    web_search: ?std.json.Value = null,
};

/// The providers in force for `session_id`, read from the session's workspace
/// row. `null` means the singleton in `ctx.config` is authoritative — either
/// because the run is not in auth mode, the session has no workspace, or the
/// workspace saved no providers.
pub fn resolve(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?Providers {
    const di = pabrikcore.getSingleton() catch return null;
    if (!di.auth_enabled) return null;
    if (session_id.len == 0) return null;

    const owner = session_llm_config.sessionOwner(allocator, db, session_id) catch return null;
    defer allocator.free(owner);
    return resolveForSessionWorkspace(allocator, db, owner, session_id);
}

fn resolveForSessionWorkspace(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    owner: []const u8,
    session_id: []const u8,
) ?Providers {
    const workspace_id = session_llm_config.sessionWorkspace(allocator, db, session_id) catch
        return resolveForOwner(allocator, db, owner);
    defer allocator.free(workspace_id);
    if (workspace_id.len == 0) return resolveForOwner(allocator, db, owner);

    const overlay = workspace_settings_store.loadRaw(allocator, db, owner, workspace_id) catch return null;
    const content = overlay orelse return null;
    defer allocator.free(content);
    return providersFrom(allocator, content);
}

/// The providers in one stored document, or null when it carries none.
pub fn providersFrom(allocator: std.mem.Allocator, content: []const u8) ?Providers {
    const parsed = std.json.parseFromSlice(UserConfigHolder, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const ws = parsed.value.web_search orelse return null;
    return config_mod.LlmConfig.parseWebSearchProvidersMap(allocator, ws) catch null;
}

/// The providers stored for one user, or null when they have none. Only a
/// session with no workspace still resolves here — everywhere else the
/// workspace row is the source.
pub fn resolveForOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?Providers {
    const raw = pabrikcore.user_config_store.loadRaw(allocator, db, owner) catch return null;
    const content = raw orelse return null;
    defer allocator.free(content);
    return providersFrom(allocator, content);
}

// ─── tests: matrix rows 58–63 ────────────────────────────────────────────

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn deinitDb(t: *TestCtx, alloc: std.mem.Allocator) void {
    t.db.deinit();
    t.threaded.deinit();
    _ = alloc;
}

/// Create a user + a session owned by them, and store a config document.
fn seedUser(t: *TestCtx, alloc: std.mem.Allocator, user_id: []const u8, config: ?[]const u8) !void {
    t.db.exec(alloc,
        \\INSERT INTO users (id, email, password_hash, config_json)
        \\VALUES (?, ?, 'x', ?)
    , &[_][]const u8{ user_id, user_id, config orelse "" }) catch return error.SeedUserFailed;

    t.db.exec(alloc,
        \\INSERT INTO sessions (id, name, user_id, created_at)
        \\VALUES (?, ?, ?, datetime('now'))
    , &[_][]const u8{ "sess_1", "test session", user_id }) catch return error.SeedSessionFailed;
}

const two_providers =
    \\{"web_search":{"tinyfish":{"url":"https://api.search.tinyfish.ai","key":"sk-tiny",
    \\ "curl":"https://api.search.tinyfish.ai?query=P -H \"X-API-Key: {key}\""},
    \\ "parked":{"url":"https://parked.example.com","key":"sk-p",
    \\ "curl":"https://parked.example.com?q=P -H \"X-Api-Key: {key}\"","enabled":false}}}
;

test "web_search_config: row 58 — an auth-mode session with saved config resolves" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u1", two_providers);

    var providers = resolveForOwner(alloc, &t.db, "u1") orelse return error.ExpectedProviders;
    defer config_mod.LlmConfig.freeWebSearchProvidersMap(&providers, alloc);

    // Row 62: the disabled provider loads but is not usable.
    try testing.expectEqual(@as(usize, 2), providers.count());
    try testing.expect(providers.get("tinyfish").?.isUsable());
    try testing.expect(!providers.get("parked").?.isUsable());
}

test "web_search_config: row 61 — a malformed stored config yields null, not an error" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u2", "{ this is not json");

    // A broken document must fall back to the pre-existing behaviour, not
    // take the tool down.
    try testing.expect(resolveForOwner(alloc, &t.db, "u2") == null);
}

test "web_search_config: a user with no stored config yields null" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    try seedUser(&t, alloc, "u3", null);

    // An absent row is not a request to remove their providers — the
    // caller falls back to the singleton.
    try testing.expect(resolveForOwner(alloc, &t.db, "u3") == null);
}

test "web_search_config: row 60 — a session with no owner is not an error" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);

    // A session row with a NULL user_id.
    t.db.exec(alloc,
        \\INSERT INTO sessions (id, name, user_id, created_at)
        \\VALUES ('ownerless', 'ownerless', NULL, datetime('now'))
    , &[_][]const u8{}) catch return error.SeedSessionFailed;

    try testing.expectError(error.SessionHasNoOwner, session_llm_config.sessionOwner(alloc, &t.db, "ownerless"));
    try testing.expectError(error.UnknownSession, session_llm_config.sessionOwner(alloc, &t.db, "no_such_session"));

    // …and `resolve` swallows both rather than propagating.
    _ = session_llm_config.sessionOwner(alloc, &t.db, "ownerless") catch {};
}

test "web_search_config: the stored document tolerates unrelated keys" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    // A whole config.json, not a fragment — every other key must be ignored.
    try seedUser(&t, alloc, "u4",
        \\{"active_profile":"x","mcp_servers":{"a":{"url":"https://a"}},
        \\ "tools":["read_file"],"model_compaction_size_kb":100,
        \\ "web_search":{"p":{"url":"https://p.example.com","key":"k",
        \\   "curl":"https://p.example.com?q=P -H \"A: {key}\""}}}
    );

    var providers = resolveForOwner(alloc, &t.db, "u4") orelse return error.ExpectedProviders;
    defer config_mod.LlmConfig.freeWebSearchProvidersMap(&providers, alloc);
    try testing.expectEqual(@as(usize, 1), providers.count());
}

test "web_search_config: an absent web_search key yields null, not an empty map" {
    const alloc = testing.allocator;
    var t = try setupDb();
    defer deinitDb(&t, alloc);
    // The distinction matters: null means "fall back to the singleton",
    // where an empty map would mean "the user has no providers".
    try seedUser(&t, alloc, "u5", "{\"active_profile\":\"x\"}");
    try testing.expect(resolveForOwner(alloc, &t.db, "u5") == null);
}
