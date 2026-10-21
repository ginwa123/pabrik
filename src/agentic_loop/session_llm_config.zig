//! Per-session `LlmConfig` resolution for opt-in `--auth` mode.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const config_mod = @import("../modules/config/Config.zig");
const workspace_config = @import("workspace_config.zig");
const workspace_settings_store = @import("workspace_settings_store.zig");
const workspace_scope = @import("workspace_scope.zig");

/// The `LlmConfig` in force for `session_id`, or null when the process-global
/// singleton should be read instead.
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
pub fn mergedConfigTextFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *pabrikcore.sqlite.SqliteBackend,
    environment: ?*const std.process.Environ.Map,
    auth_enabled: bool,
    owner: []const u8,
    workspace_id: []const u8,
) ?[]u8 {
    const overlay: ?[]u8 = workspace_config.workspaceOverlay(
        allocator,
        io,
        db,
        environment,
        auth_enabled,
        owner,
        workspace_id,
    );
    defer if (overlay) |o| allocator.free(o);

    const in_workspace = workspace_id.len > 0;
    const base = if (in_workspace)
        workspace_config.scopedBaseConfigText(allocator, io, db, environment, auth_enabled, owner)
    else
        workspace_config.baseConfigText(allocator, io, db, environment, auth_enabled, owner);

    if (overlay == null) {
        if (!auth_enabled and !in_workspace) {
            // File mode, no workspace in scope: the singleton already holds
            // exactly these bytes.
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

/// The workspace this session belongs to, or `""` when it has none. Two
/// sources, in order: 1.
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
    if (r.values[0].len > 0) return try allocator.dupe(u8, r.values[0]);

    // Empty column: fall back to the canonical resolver. An unresolvable
    // session (no task link, no cwd match, an ambiguous tie) is a legal
    // legacy row and reads as "no workspace" - no overlay, no error.
    const resolved = try workspace_scope.resolveWorkspaceId(allocator, db, session_id);
    if (resolved) |w| return w;
    return try allocator.dupe(u8, "");
}

/// The `LlmConfig` stored in `users.config_json` for `owner`, or null when
/// that user has no saved config (or it cannot be used).
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

/// The `LlmConfig` for an `(owner, workspace)` pair with no session row in
/// play: the request-scoped sibling of `forSession`.
pub fn forOwnerAndWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *pabrikcore.sqlite.SqliteBackend,
    environment: ?*const std.process.Environ.Map,
    auth_enabled: bool,
    owner: []const u8,
    workspace_id: []const u8,
) ?*config_mod.LlmConfig {
    // In auth mode the overlay is keyed by the requesting user, so an empty
    // owner is "no identity" and must not fall through to the shared
    // file-mode bucket.
    if (auth_enabled and owner.len == 0) return null;
    if (workspace_id.len == 0) return forOwner(allocator, db, owner);
    const text = mergedConfigTextFor(
        allocator,
        io,
        db,
        environment,
        auth_enabled,
        owner,
        workspace_id,
    ) orelse return null;
    defer allocator.free(text);
    return fromJsonText(allocator, text);
}

/// Parse one user's saved config into a heap `LlmConfig` owned by
/// `allocator`, or null on any parse failure — a corrupt row degrades to the
/// singleton rather than failing a chat turn.
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

    try testing.expectEqualStrings("mine", cfg.active_agent.?);
    const eff = cfg.resolveEffectiveAgent("mine");
    try testing.expectEqualStrings("user-model", eff.model);
    try testing.expectEqualStrings("http://user.example/v1", eff.base_url);
    try testing.expectEqualStrings("user-key", eff.api_key);
    // The same cascade the workflow calls with an EMPTY profile name must
    // also land on the user's active_profile, not on top-level defaults.
    const via_active = cfg.resolveEffectiveAgent("");
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
    try testing.expectEqualStrings(from_text.active_agent.?, from_db.active_agent.?);
    try testing.expectEqualStrings(
        from_text.agents.get("p").?.api_key,
        from_db.agents.get("p").?.api_key,
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
// `mergedConfigTextFor` exists precisely so these can be written:
// `forSession` needs the process-global singleton and there is no

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
    try testing.expectEqualStrings("mine", cfg.active_agent.?);
}

test "auth mode: a workspace's own row wins for every key it sets" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(
        &ctx.db,
        "u_1",
        "{\"profiles_models\":{\"claude\":{\"model\":\"opus\",\"api_key\":\"sk-user\"}}," ++
            "\"active_profile\":\"claude\",\"tools\":[\"read_file\",\"write_file\"],\"retry_delay_ms\":1234}",
    );
    try putOverlay(&ctx.db, "u_1", "ws_a", "{\"tools\":[\"read_file\"]}");

    const merged = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.OverlayIgnored;
    defer alloc.free(merged);

    const cfg = fromJsonText(alloc, merged) orelse return error.Unparseable;
    defer freeResolved(cfg);

    try testing.expectEqual(@as(usize, 1), cfg.tools.?.len);
    try testing.expectEqualStrings("read_file", cfg.tools.?[0]);

    // The row sets tools and nothing about profiles, so the user's profile -
    // and the key it carries - is what a run here resolves.
    try testing.expectEqualStrings("opus", cfg.agents.get("claude").?.model);
    try testing.expectEqualStrings("claude", cfg.active_agent.?);

    // General is still shared, so the run keeps the user's retry backoff.
    try testing.expectEqual(@as(u32, 1234), cfg.retry_delay_ms);
}

test "auth mode: a workspace with no row adopts the user's scoped settings" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(
        &ctx.db,
        "u_1",
        "{\"active_profile\":\"mine\",\"tools\":[\"read_file\",\"write_file\"],\"retry_delay_ms\":1234}",
    );
    const text = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.UserConfigLost;
    defer alloc.free(text);

    const cfg = fromJsonText(alloc, text) orelse return error.Unparseable;
    defer freeResolved(cfg);
    // A workspace nobody has saved into runs with what the user set up, which
    // is also what the agent sections have to render.
    try testing.expectEqual(@as(usize, 2), cfg.tools.?.len);
    try testing.expectEqualStrings("mine", cfg.active_agent.?);
    try testing.expectEqual(@as(u32, 1234), cfg.retry_delay_ms);

    // A user who never saved settings, and no overlay either: the singleton.
    try testing.expect(mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_none", "ws_a") == null);
}

test "an empty profile copy runs on the user's profiles" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(
        &ctx.db,
        "u_1",
        "{\"profiles_models\":{\"claude\":{\"model\":\"opus\",\"api_key\":\"sk-user\"}}," ++
            "\"active_profile\":\"claude\"}",
    );
    // The copy a workspace takes while the user has no profiles yet.
    try putOverlay(&ctx.db, "u_1", "ws_a", "{\"profiles_models\":{}}");

    const merged = mergedConfigTextFor(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.OverlayIgnored;
    defer alloc.free(merged);

    const cfg = fromJsonText(alloc, merged) orelse return error.Unparseable;
    defer freeResolved(cfg);
    try testing.expectEqualStrings("opus", cfg.agents.get("claude").?.model);
    try testing.expectEqualStrings("claude", cfg.active_agent.?);
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

// ─── Reachability of the workspace layer ───────────────────────────────────
// `forSession` is what makes the overlay apply to a real chat, and it can
// only layer the overlay once it knows the workspace.

test "sessionWorkspace: an empty column resolves through the task link" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // Exactly the shape a kanban create writes: a sessions row with no
    // workspace_id, plus the task row whose id IS the session id (Migration
    // 052 dropped the redundant `session_id` column).
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1', 'ws_kanban', 'kanban')",
        &.{},
    );
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s_task', 'T', 'wi_1')",
        &.{},
    );
    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, user_id) VALUES ('s_task', 's', 'active', 'u_1')",
        &.{},
    );

    const ws = try sessionWorkspace(alloc, &ctx.db, "s_task");
    defer alloc.free(ws);
    try testing.expectEqualStrings("ws_kanban", ws);
}

test "sessionWorkspace: a set column still wins over the task link" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // An explicit binding is authoritative: a future writer of the column must
    // not be overridden by the (heuristic) resolver.
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1', 'ws_from_task', 'kanban')",
        &.{},
    );
    try ctx.db.exec(
        alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('s_bound', 'T', 'wi_1')",
        &.{},
    );
    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, user_id, workspace_id) VALUES ('s_bound', 's', 'active', 'u_1', 'ws_bound')",
        &.{},
    );

    const ws = try sessionWorkspace(alloc, &ctx.db, "s_bound");
    defer alloc.free(ws);
    try testing.expectEqualStrings("ws_bound", ws);
}

test "sessionWorkspace: no task link and no cwd match reads as no workspace" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    // A plain chat outside every workspace item path: fail closed to "", no
    // overlay, no error. `workspace_scope.resolveWorkspaceId` owns that rule.
    try ctx.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status, user_id, cwd) VALUES ('s_plain', 's', 'active', 'u_1', '/nowhere/at/all')",
        &.{},
    );
    const ws = try sessionWorkspace(alloc, &ctx.db, "s_plain");
    defer alloc.free(ws);
    try testing.expectEqualStrings("", ws);
}

test "forOwnerAndWorkspace: the workspace's own active_profile and profiles win" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = testing.allocator;

    try insertUser(
        &ctx.db,
        "u_1",
        "{\"profiles_models\":{\"user-default\":{\"model\":\"user-model\",\"base_url\":\"http://user.example/v1\"}}," ++
            "\"active_profile\":\"user-default\"}",
    );
    try putOverlay(
        &ctx.db,
        "u_1",
        "ws_a",
        "{\"profiles_models\":{\"ws-default\":{\"model\":\"ws-model\",\"base_url\":\"http://ws.example/v1\"}}," ++
            "\"active_profile\":\"ws-default\"}",
    );

    const cfg = forOwnerAndWorkspace(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "ws_a") orelse
        return error.ScopedConfigMissing;
    defer freeResolved(cfg);
    try testing.expectEqualStrings("ws-default", cfg.active_agent.?);
    try testing.expectEqualStrings("ws-model", cfg.resolveEffectiveAgent(cfg.active_agent.?).model);
    // The workspace's list is its own: the user's profile is not inherited.
    try testing.expect(cfg.agents.get("ws-default") != null);
    try testing.expect(cfg.agents.get("user-default") == null);

    // No workspace id: the user-level answer, unchanged.
    const plain = forOwnerAndWorkspace(alloc, ctx.threaded.io(), &ctx.db, null, true, "u_1", "") orelse
        return error.UserConfigMissing;
    defer freeResolved(plain);
    try testing.expectEqualStrings("user-default", plain.active_agent.?);

    // No identity in auth mode: nothing scoped, so the caller falls back to
    // the singleton rather than to the shared file-mode bucket.
    try testing.expect(forOwnerAndWorkspace(alloc, ctx.threaded.io(), &ctx.db, null, true, "", "ws_a") == null);
}
