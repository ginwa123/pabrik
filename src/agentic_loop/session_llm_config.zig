//! Per-session `LlmConfig` resolution for opt-in `--auth` mode.
//!
//! Why this exists: under `--auth` each user's LLM config (profiles,
//! `active_profile`, tools checklist, compaction knobs, MCP servers — the
//! same JSON shape as `config.json`) lives in `users.config_json`
//! (Migration 092) and `config.json` is documented as ignored. The
//! *Settings* handlers honour that. The `LlmConfig` singleton does not:
//! it is loaded from `config.json` once at boot and is never rewritten in
//! auth mode — `pabrik_config_put.zig` returns early after persisting to
//! the database, because one global pointer cannot serve per-user config
//! (the user who saved last would win for everybody).
//!
//! So every runtime reader of `getLlmConfig(di)` kept describing the
//! on-disk file. A `--auth` user's saved model / `api_key` / `base_url` /
//! `url_style` / tools checklist were silently ignored and every chat ran
//! on `config.json`'s `active_profile`: the Settings screen read the
//! database (honest) while the turn read the singleton (wrong).
//! `skill_evals_config.zig` documents the same trap for one feature and
//! resolves it per session; this module does it for the whole `LlmConfig`.
//!
//! ## The workspace layer (Migration 105)
//!
//! A workspace may carry a SPARSE config overlay
//! (`workspace_settings`, see `workspace_config.zig`). When it does, neither
//! source alone is correct: `users.config_json` / `config.json` is only the
//! BASE, and the workspace's keys win over it. `forSession` therefore merges
//! the overlay over the base text and parses the result through the same
//! `initFromJsonText` the on-disk path uses. A session with no overlay takes
//! the pre-existing path unchanged.
//!
//! `null` from either entry point means "the singleton is authoritative"
//! and covers every case where the database is not: file mode (`--auth`
//! off), no singleton, a session with no owner, a user who never saved
//! settings, a corrupt row. All of them fall back to the previous
//! behaviour, so the failure mode stays the pre-existing one.
//!
//! Callers own the lifetime: pass a run/request arena (production) or
//! `deinit` both the config and its strings (tests). Do not mutate the
//! returned config — one call resolves one config and others may share it.
//!
//! THE RULE (one module, one owner): this file is the only place that decides
//! which `LlmConfig` a user-scoped read sees. Call sites use one of exactly
//! two entry points and MUST NOT hand-roll `getLlmConfig(di)` for user-scoped
//! data:
//!
//!   * `forSession` — anything that has a `sessions.id` (the workflow loop,
//!     the message and compaction read paths, the context-window cascade,
//!     the session-create profile snapshot).
//!   * `auth_common.requestUserConfig` (`http_handlers`) — request-scoped
//!     handlers that have a cookie but no session row yet (workspace/agent/
//!     kanban seeding, web status); it resolves the cookie to an owner and
//!     calls `forOwner` here, so the rule still has one implementation.
//!
//! Direct `getLlmConfig(di)` reads that legitimately stay outside:
//! boot (`main.zig`) and the Settings handlers (they read/write
//! `users.config_json` themselves). The two feature-specific narrow
//! resolvers share this module's owner lookup and full-config parse:
//! `skill_evals_config.zig` delegates to `forOwner` (its struct owns no
//! memory, so the copy is free); `web_search_config.zig` reuses
//! `sessionOwner` and keeps its narrow parse only because the providers map
//! owns heap strings tied to the full config's lifetime.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const config_mod = @import("../modules/config/Config.zig");
const workspace_config = @import("workspace_config.zig");
const workspace_settings_store = @import("workspace_settings_store.zig");

/// The `LlmConfig` in force for `session_id`, or null when the process-global
/// singleton should be read instead.
///
/// Requires `auth_enabled` and a session row carrying an owner — both are
/// cheap reads on the caller's hot path, and both are what makes the
/// database (not the file) the authority. The returned pointer is allocated
/// with `allocator` (an arena in production) and borrows nothing else.
pub fn forSession(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ?*config_mod.LlmConfig {
    const di = pabrikcore.getSingleton() catch return null;
    if (session_id.len == 0) return null;

    // Owner. Auth mode scopes config per user; file mode has one shared
    // bucket, which is the empty-string owner the workspace overlay table
    // also uses.
    var owned_owner: ?[]u8 = null;
    defer if (owned_owner) |o| allocator.free(o);
    const owner: []const u8 = if (di.auth_enabled) blk: {
        owned_owner = sessionOwner(allocator, db, session_id) catch return null;
        break :blk owned_owner.?;
    } else workspace_settings_store.FILE_MODE_OWNER;

    const workspace_id = sessionWorkspace(allocator, db, session_id) catch return null;
    defer allocator.free(workspace_id);

    const text = mergedConfigTextFor(
        allocator,
        di.io,
        db,
        di.environment,
        di.auth_enabled,
        owner,
        workspace_id,
    ) orelse return null;
    defer allocator.free(text);
    return fromJsonText(allocator, text);
}

/// The config TEXT a scoped read should parse, or `null` for "the singleton
/// is authoritative".
///
/// Split out of `forSession` so the layering can be TESTED: `forSession` needs
/// the process-global singleton, and there is no `clearSingleton`, so a test
/// that installed one would leak into every other test in the binary. This
/// function takes everything it needs as an argument.
///
/// Three cases, in the order they are decided:
///
///   1. **No overlay + `--auth` OFF** -> `null`. Unchanged behaviour: the
///      config PUT swaps the singleton synchronously, so it already tracks
///      the file, and reading config.json here would add a second source that
///      can only disagree with it. It is also the cheap path - no file read
///      per turn for the common case of a workspace that overrides nothing.
///   2. **No overlay + `--auth` ON** -> the owner's `users.config_json`, which
///      is what `forOwner` always returned. A user with no saved config gives
///      `null` and the singleton again.
///   3. **An overlay** -> base TEXT merged with the overlay. Neither source
///      alone is right any more: in file mode the singleton describes
///      `config.json`, which is now only the BASE for this session.
///
/// Caller owns the returned slice.
pub fn mergedConfigTextFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *pabrikcore.sqlite.SqliteBackend,
    environment: ?*const std.process.Environ.Map,
    auth_enabled: bool,
    owner: []const u8,
    workspace_id: []const u8,
) ?[]u8 {
    const overlay: ?[]u8 = if (workspace_id.len > 0)
        workspace_settings_store.loadRaw(allocator, db, owner, workspace_id) catch null
    else
        null;
    defer if (overlay) |o| allocator.free(o);

    const base = workspace_config.baseConfigText(allocator, io, db, environment, auth_enabled, owner);

    if (overlay == null) {
        // Case 1 and 2 - see the doc comment.
        if (!auth_enabled) {
            // File mode: a config.json read that found the file still answers
            // null, because the singleton already holds exactly those bytes.
            if (base) |b| allocator.free(b);
            return null;
        }
        // Ownership of `base` MOVES TO THE CALLER here. Freeing it on the way
        // out - the `defer` this used to have - handed the caller freed
        // memory to parse, which is a crash, not a leak.
        return base;
    }

    // Case 3. The base is only an INPUT to the merge, so it is freed here;
    // a malformed base degrades to `{}` inside `overlayJson`, so the overlay
    // still applies rather than being silently dropped.
    defer if (base) |b| allocator.free(b);
    return workspace_config.overlayJson(allocator, base orelse "", overlay.?) catch null;
}

/// The workspace this session belongs to, or `""` when the row carries none.
///
/// Sibling of `sessionOwner`: same query, same table, same single-source rule
/// - the workspace overlay's key needs BOTH halves, so they are read from one
/// row in one place rather than assembled by each caller.
pub fn sessionWorkspace(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var q = try db.query(
        allocator,
        "SELECT COALESCE(workspace_id, '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer q.deinit();
    const row = try q.next();
    const r = row orelse return error.UnknownSession;
    defer r.deinit(allocator);
    if (r.values.len < 1) return error.SessionHasNoWorkspace;
    return try allocator.dupe(u8, r.values[0]);
}

/// The `LlmConfig` stored in `users.config_json` for `owner`, or null when
/// that user has no saved config (or it cannot be used).
///
/// Split out from `forSession` so it can be tested — and called by the
/// request-scoped handlers, which already resolved the owner from the
/// session cookie — without the process-global singleton: there is no
/// `clearSingleton`, so a test that installed one would leak into every
/// other test in the binary.
///
/// No `auth_enabled` check on purpose: the caller owns that decision. A
/// non-auth caller passing the shared/system sentinel gets null (that user
/// has no row), which degrades to the singleton.
pub fn forOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    owner: []const u8,
) ?*config_mod.LlmConfig {
    if (owner.len == 0) return null;
    const raw = pabrikcore.user_config_store.loadRaw(allocator, db, owner) catch return null;
    const content = raw orelse return null;
    defer allocator.free(content);
    return fromJsonText(allocator, content);
}

/// Parse one user's saved config into a heap `LlmConfig` owned by
/// `allocator`, or null on any parse failure — a corrupt row degrades to
/// the singleton rather than failing a chat turn.
///
/// The mapping is `LlmConfig.initFromJsonText`, the same one the on-disk
/// path uses, so a stored row and a `config.json` with identical bytes
/// produce identical configs (that is the whole point of the fix).
pub fn fromJsonText(
    allocator: std.mem.Allocator,
    content: []const u8,
) ?*config_mod.LlmConfig {
    if (content.len == 0) return null;
    const cfg = allocator.create(config_mod.LlmConfig) catch return null;
    cfg.* = config_mod.LlmConfig.initFromJsonText(allocator, content) catch {
        allocator.destroy(cfg);
        return null;
    };
    return cfg;
}

/// The owner of `session_id`, duped into `allocator`.
///
/// Shared helper for the narrow resolvers (`skill_evals_config.zig`,
/// `web_search_config.zig`) so all three read the same row through the same
/// query. Single source of truth for owner resolution — do not duplicate.
pub fn sessionOwner(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    var q = try db.query(
        allocator,
        "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer q.deinit();
    const row = try q.next();
    const r = row orelse return error.UnknownSession;
    defer r.deinit(allocator);
    if (r.values.len < 1 or r.values[0].len == 0) return error.SessionHasNoOwner;
    return try allocator.dupe(u8, r.values[0]);
}

// =====================================================================
// Tests (in-memory SQLite with the real migration chain)
// =====================================================================

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

fn insertUser(db: *sqlite.SqliteBackend, id: []const u8, config_json: ?[]const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO users (id, email, password_hash, config_json) VALUES (?, ?, 'h', ?)",
        &[_][]const u8{ id, id, config_json orelse "" },
    );
}

fn insertSession(db: *sqlite.SqliteBackend, id: []const u8, owner: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name, status, user_id) VALUES (?, 's', 'active', ?)",
        &[_][]const u8{ id, owner },
    );
}

/// Free a config `fromJsonText`/`forOwner` handed out, then the pointer.
fn freeResolved(cfg: *config_mod.LlmConfig) void {
    cfg.deinit();
    testing.allocator.destroy(cfg);
}

test "forOwner: absent, empty and unknown owners degrade to the singleton" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expect(forOwner(testing.allocator, &ctx.db, "") == null);
    try insertUser(&ctx.db, "u_no_config", null);
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_no_config") == null);
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_missing") == null);
}

test "forOwner: a saved profile is what a chat turn gets" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const body =
        "{\"active_profile\":\"mine\",\"profiles_models\":{\"mine\":{\"model\":\"user-model\"," ++
        "\"base_url\":\"http://user.example/v1\",\"api_key\":\"user-key\",\"url_style\":\"openai\"}}}";
    try insertUser(&ctx.db, "u1", body);

    const cfg = forOwner(testing.allocator, &ctx.db, "u1") orelse return error.ConfigNotResolved;
    defer freeResolved(cfg);

    try testing.expectEqualStrings("mine", cfg.active_profile.?);
    const eff = cfg.resolveEffectiveProfile("mine");
    try testing.expectEqualStrings("user-model", eff.model);
    try testing.expectEqualStrings("http://user.example/v1", eff.base_url);
    try testing.expectEqualStrings("user-key", eff.api_key);
    // The same cascade the workflow calls with an EMPTY profile name must
    // also land on the user's active_profile, not on top-level defaults.
    const via_active = cfg.resolveEffectiveProfile("");
    try testing.expectEqualStrings("user-model", via_active.model);
    try testing.expectEqualStrings("user-key", via_active.api_key);
}

test "forOwner: the tools checklist comes from the user's row" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_tools", "{\"tools\":[\"search_skills\",\"use_skill\"]}");

    const cfg = forOwner(testing.allocator, &ctx.db, "u_tools") orelse return error.ConfigNotResolved;
    defer freeResolved(cfg);

    const tools = cfg.tools orelse return error.ToolsNotParsed;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("search_skills", tools[0]);
    try testing.expectEqualStrings("use_skill", tools[1]);
}

test "forOwner: a corrupt row degrades instead of failing the turn" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_bad", "{ this is not json");
    try testing.expect(forOwner(testing.allocator, &ctx.db, "u_bad") == null);
    try testing.expect(fromJsonText(testing.allocator, "") == null);
    try testing.expect(fromJsonText(testing.allocator, "null") == null);
}

test "fromJsonText: matches the on-disk parse for identical bytes" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Same bytes in both places: the database copy must produce the same
    // config a config.json with those bytes would (that is the promise the
    // fix rests on — file mode and auth mode cannot diverge).
    const body =
        "{\"active_profile\":\"p\",\"profiles_models\":{\"p\":{\"model\":\"m\"," ++
        "\"base_url\":\"http://x/v1\",\"api_key\":\"k\"}},\"tools\":[\"used_tools\"]}";
    try insertUser(&ctx.db, "u_same", body);

    const from_db = forOwner(testing.allocator, &ctx.db, "u_same") orelse return error.ConfigNotResolved;
    defer freeResolved(from_db);
    const from_text = fromJsonText(testing.allocator, body) orelse return error.ConfigNotResolved;
    defer freeResolved(from_text);

    try testing.expectEqualStrings(from_text.model, from_db.model);
    try testing.expectEqualStrings(from_text.active_profile.?, from_db.active_profile.?);
    try testing.expectEqualStrings(
        from_text.profiles_models.get("p").?.api_key,
        from_db.profiles_models.get("p").?.api_key,
    );
    try testing.expectEqual(from_text.tools.?.len, from_db.tools.?.len);
}

test "sessionOwner: owner is read from the session, absent owner is an error" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try insertUser(&ctx.db, "u_owner", null);
    try insertSession(&ctx.db, "s_owned", "u_owner");
    try insertSession(&ctx.db, "s_orphan", "");

    const owner = try sessionOwner(testing.allocator, &ctx.db, "s_owned");
    defer testing.allocator.free(owner);
    try testing.expectEqualStrings("u_owner", owner);

    try testing.expectError(error.SessionHasNoOwner, sessionOwner(testing.allocator, &ctx.db, "s_orphan"));
    try testing.expectError(error.UnknownSession, sessionOwner(testing.allocator, &ctx.db, "s_missing"));
}

// ─── The workspace layer (Migration 105) ───────────────────────────────────
//
// `mergedConfigTextFor` exists precisely so these can be written: `forSession`
// needs the process-global singleton and there is no `clearSingleton`, so a
// test that installed one would leak into every other test in the binary.
//
// The two assertions that matter most are the last two: an overlay must reach
// the workspace it belongs to and NOTHING else - not another workspace, and
// not another user in the same workspace.

const store = @import("workspace_settings_store.zig");

fn putOverlay(db: *sqlite.SqliteBackend, owner: []const u8, workspace_id: []const u8, body: []const u8) !void {
    try store.saveRaw(testing.allocator, db, owner, workspace_id, body);
}

test "no overlay in file mode is null, so the singleton stays authoritative" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try testing.expect(mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, false, "", "ws_a") == null);

    // Positive control: the same call DOES answer once an overlay exists, so
    // the null above is "nothing to merge" and not a function that never works.
    try putOverlay(&ctx.db, "", "ws_a", "{\"tools\":[\"read_file\"]}");
    const merged = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, false, "", "ws_a") orelse
        return error.OverlayIgnored;
    defer alloc.free(merged);
    try testing.expect(std.mem.indexOf(u8, merged, "read_file") != null);
}

test "an overlay in file mode merges over the base and replaces an array" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // `environment = null` means no config.json is reachable, so the base is
    // empty - which is exactly the fresh-install case. The overlay must still
    // apply rather than being dropped for want of a base.
    try putOverlay(&ctx.db, "", "ws_a", "{\"tools\":[\"read_file\"],\"active_profile\":\"mine\"}");
    const merged = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, false, "", "ws_a") orelse
        return error.OverlayIgnored;
    defer alloc.free(merged);

    const cfg = fromJsonText(alloc, merged) orelse return error.Unparseable;
    defer freeResolved(cfg);
    try testing.expectEqual(@as(usize, 1), cfg.tools.?.len);
    try testing.expectEqualStrings("read_file", cfg.tools.?[0]);
    try testing.expectEqualStrings("mine", cfg.active_profile.?);
}

test "auth mode: the overlay wins over the user config and the rest survives" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // The user's saved config: a profile WITH a credential, plus two tools.
    try insertUser(
        &ctx.db,
        "u_1",
        "{\"profiles_models\":{\"claude\":{\"model\":\"opus\",\"api_key\":\"sk-user\"}}," ++
            "\"active_profile\":\"claude\",\"tools\":[\"read_file\",\"write_file\"]}",
    );
    // The workspace overrides ONLY the tool list.
    try putOverlay(&ctx.db, "u_1", "ws_a", "{\"tools\":[\"read_file\"]}");

    const merged = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.OverlayIgnored;
    defer alloc.free(merged);

    const cfg = fromJsonText(alloc, merged) orelse return error.Unparseable;
    defer freeResolved(cfg);

    // The overlay's key won...
    try testing.expectEqual(@as(usize, 1), cfg.tools.?.len);
    try testing.expectEqualStrings("read_file", cfg.tools.?[0]);
    // ...and everything the workspace did not mention still came from the
    // user config, credential included. A "last write wins" merge would have
    // dropped the whole profile and broken every turn in this workspace.
    try testing.expectEqual(@as(usize, 1), cfg.profiles_models.count());
    const profile = cfg.profiles_models.get("claude") orelse return error.ProfileLost;
    try testing.expectEqualStrings("opus", profile.model);
    try testing.expectEqualStrings("sk-user", profile.api_key);
    try testing.expectEqualStrings("claude", cfg.active_profile.?);
}

test "auth mode with no overlay still returns the user config, unchanged" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(&ctx.db, "u_1", "{\"active_profile\":\"mine\",\"tools\":[\"read_file\",\"write_file\"]}");
    const text = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.UserConfigLost;
    defer alloc.free(text);

    const cfg = fromJsonText(alloc, text) orelse return error.Unparseable;
    defer freeResolved(cfg);
    try testing.expectEqual(@as(usize, 2), cfg.tools.?.len);
    try testing.expectEqualStrings("mine", cfg.active_profile.?);

    // A user who never saved settings, and no overlay either: the singleton.
    try testing.expect(mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_none", "ws_a") == null);
}

test "an overlay never reaches another workspace" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try putOverlay(&ctx.db, "", "ws_a", "{\"active_profile\":\"mine\"}");

    try testing.expect(mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, false, "", "ws_b") == null);
    // Positive control: ws_a itself does see it. The slice is owned, so it is
    // freed - an assertion that only checks `!= null` leaks the whole config.
    const seen = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, false, "", "ws_a") orelse
        return error.OverlayInvisible;
    defer alloc.free(seen);
    try testing.expect(std.mem.indexOf(u8, seen, "mine") != null);
}

test "an overlay never reaches another user in the same workspace" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // u_1 saved a config AND an overlay for the shared workspace. u_2 must
    // see their own config (here: none) - never u_1's, which carries a key.
    try insertUser(&ctx.db, "u_1", "{\"active_profile\":\"mine\"}");
    try putOverlay(&ctx.db, "u_1", "ws_shared", "{\"active_profile\":\"u1-only\"}");

    try testing.expect(mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_2", "ws_shared") == null);

    // And u_1 still gets theirs - so the null above is isolation, not a
    // broken lookup.
    const mine = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_shared") orelse
        return error.OverlayLost;
    defer alloc.free(mine);
    try testing.expect(std.mem.indexOf(u8, mine, "u1-only") != null);
}

test "a session with no workspace_id keeps the user-level answer" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(&ctx.db, "u_1", "{\"active_profile\":\"mine\"}");
    // Empty workspace_id: no overlay lookup at all, so the user config comes
    // through exactly as it did before the workspace layer existed.
    const text = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "") orelse
        return error.UserConfigLost;
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "mine") != null);
}

test "sessionWorkspace reads the row, and an unknown session is an error" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, user_id, workspace_id) VALUES ('s_1', 's', 'active', 'u_1', 'ws_a')",
        &.{},
    );
    const ws = try sessionWorkspace(alloc, &ctx.db, "s_1");
    defer alloc.free(ws);
    try testing.expectEqualStrings("ws_a", ws);

    try testing.expectError(error.UnknownSession, sessionWorkspace(alloc, &ctx.db, "s_nope"));

    // A row with no workspace reads as "" - not an error, because a session
    // without a workspace is a legal legacy row.
    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, user_id) VALUES ('s_2', 's', 'active', 'u_1')",
        &.{},
    );
    const none = try sessionWorkspace(alloc, &ctx.db, "s_2");
    defer alloc.free(none);
    try testing.expectEqualStrings("", none);
}
