//! The per-workspace config overlay over HTTP.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const pabrik_config_get = @import("pabrik_config_get.zig");
const pabrik_config_put = @import("pabrik_config_put.zig");
const workspace_config = @import("../agentic_loop/workspace_config.zig");
const store = @import("../agentic_loop/workspace_settings_store.zig");

pub const WorkspaceConfigError = error{
    WorkspaceIdRequired,
    InvalidBody,
    /// The body is a well-formed config but carries no workspace-scoped key,
    /// so accepting it would silently mean "inherit everything" when the
    /// caller believed they were saving something.
    NothingScoped,
    QueryFailed,
    OutOfMemory,
};

// =====================================================================
// Use cases (no HTTP, no io - so every rule below is testable)
// =====================================================================

/// The effective config TEXT: `base` with `overlay` merged over it. Owned by
/// the caller.
pub fn effectiveConfig(
    allocator: std.mem.Allocator,
    base_json: ?[]const u8,
    overlay_json: ?[]const u8,
) WorkspaceConfigError![]u8 {
    if (overlay_json == null) {
        return allocator.dupe(u8, base_json orelse "{}") catch return error.OutOfMemory;
    }
    return workspace_config.overlayJson(allocator, base_json orelse "", overlay_json.?) catch
        return error.OutOfMemory;
}

/// The overlay the PUT body should store: its workspace-scoped slice.
pub fn overlayFromPutBody(
    allocator: std.mem.Allocator,
    body: []const u8,
) WorkspaceConfigError![]u8 {
    // Parse first: a malformed body must be a 400, never a stored blob. This
    // is the same parser the user-scope PUT uses, so the two surfaces accept
    // the same shapes.
    _ = pabrik_config_put.parseConfigInput(allocator, body) catch return error.InvalidBody;

    const overlay = workspace_config.workspaceScopedOverlay(allocator, body) catch return error.OutOfMemory;
    errdefer allocator.free(overlay);
    if (std.mem.eql(u8, overlay, "{}")) return error.NothingScoped;
    return overlay;
}

// =====================================================================
// Error mapping (exhaustive, so a new variant breaks the build here)
// =====================================================================

fn statusFor(err: WorkspaceConfigError) u16 {
    return switch (err) {
        error.WorkspaceIdRequired, error.InvalidBody, error.NothingScoped => 400,
        error.QueryFailed, error.OutOfMemory => 500,
    };
}

fn messageFor(err: WorkspaceConfigError) []const u8 {
    return switch (err) {
        error.WorkspaceIdRequired => "workspace_id required",
        error.InvalidBody => "Invalid JSON in config",
        error.NothingScoped => "No workspace-scoped settings in that body",
        error.QueryFailed => "DB error",
        error.OutOfMemory => "Out of memory",
    };
}

// =====================================================================
// Handler plumbing
// =====================================================================

/// The `owner` half of the overlay key. * `--auth` OFF -> `FILE_MODE_OWNER`
/// (`""`), one overlay per workspace. * `--auth` ON -> the request's user,
/// exactly like `users.config_json`.
fn ownerForRequest(
    allocator: std.mem.Allocator,
    di: *pabrikcore.App,
    req: gserverz.HttpRequest,
) ?[]const u8 {
    if (!di.auth_enabled) return allocator.dupe(u8, store.FILE_MODE_OWNER) catch null;
    return auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch null;
}

/// A minimal success body. Shaped like the other write handlers' responses
/// (`{"success":true,...}`) rather than a bare 204, so a caller that only
/// checks the body still sees that the write landed.
fn okResponse(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"success\":true,\"message\":\"{s}\"}}", .{message});
}

/// The user-level config text this workspace layers over, or null.
fn loadBase(
    allocator: std.mem.Allocator,
    di: *pabrikcore.App,
    owner: []const u8,
) ?[]u8 {
    return workspace_config.baseConfigText(
        allocator,
        di.io,
        di.db,
        di.environment,
        di.auth_enabled,
        owner,
    );
}

fn loadOverlay(
    allocator: std.mem.Allocator,
    di: *pabrikcore.App,
    owner: []const u8,
    workspace_id: []const u8,
) ?[]u8 {
    if (workspace_id.len == 0) return null;
    return store.loadRaw(allocator, di.db, owner, workspace_id) catch null;
}

fn errorResponse(
    res: gserverz.HttpResponse,
    allocator: std.mem.Allocator,
    err: WorkspaceConfigError,
) !gserverz.HttpResponse {
    return res.jsonResponse(.{
        .status_code = statusFor(err),
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = messageFor(err) }),
    });
}

// =====================================================================
// Handlers
// =====================================================================

pub fn workspaceConfigGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return errorResponse(res, allocator, error.WorkspaceIdRequired);

    const owner = ownerForRequest(allocator, di, req) orelse
        return errorResponse(res, allocator, error.OutOfMemory);
    defer allocator.free(owner);

    const base = loadBase(allocator, di, owner);
    defer if (base) |b| allocator.free(b);
    const overlay = loadOverlay(allocator, di, owner, workspace_id);
    defer if (overlay) |o| allocator.free(o);

    const effective = effectiveConfig(allocator, base, overlay) catch |err|
        return errorResponse(res, allocator, err);
    defer allocator.free(effective);

    // The SAME parse struct and the SAME response builder as
    // `GET /api/config/pabrik`, so the two surfaces cannot drift on the field
    // set or on masking `web_search`.
    const cfg = std.json.parseFromSliceLeaky(pabrik_config_get.ConfigJson, allocator, effective, .{
        .ignore_unknown_fields = true,
    }) catch return errorResponse(res, allocator, error.InvalidBody);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try pabrik_config_get.makeConfigResponse(allocator, cfg),
    });
}

pub fn workspaceConfigPutHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return errorResponse(res, allocator, error.WorkspaceIdRequired);

    const owner = ownerForRequest(allocator, di, req) orelse
        return errorResponse(res, allocator, error.OutOfMemory);
    defer allocator.free(owner);

    // `req.body` is `[]const u8` here (an absent body is the empty slice),
    // not an optional - do not reach for `orelse`.
    const body = req.body;
    // An empty body is "inherit": the same thing the settings page sends when
    // the user resets a workspace to the user-level config.
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        store.clear(allocator, di.db, owner, workspace_id) catch
            return errorResponse(res, allocator, error.QueryFailed);
        return res.jsonResponse(.{
            .status_code = 200,
            .data = try okResponse(allocator, "workspace config inherits the user config"),
        });
    }

    const overlay = overlayFromPutBody(allocator, body) catch |err|
        return errorResponse(res, allocator, err);
    defer allocator.free(overlay);

    store.saveRaw(allocator, di.db, owner, workspace_id, overlay) catch
        return errorResponse(res, allocator, error.QueryFailed);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try okResponse(allocator, "workspace config saved"),
    });
}

// =====================================================================
// Tests
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

const USER_CONFIG =
    \\{"profiles_models":{"claude":{"model":"opus","api_key":"sk-user"}},
    \\ "active_profile":"claude",
    \\ "tools":["read_file","write_file"],
    \\ "notify_on_complete":true,
    \\ "retry_delay_ms":2000}
;

test "effectiveConfig: no overlay means the base, unchanged" {
    const alloc = testing.allocator;
    const merged = try effectiveConfig(alloc, "{\"active_profile\":\"claude\"}", null);
    defer alloc.free(merged);
    try testing.expectEqualStrings("{\"active_profile\":\"claude\"}", merged);
}

test "effectiveConfig: an overlay wins and the base survives underneath" {
    const alloc = testing.allocator;
    const e = try effectiveConfig(alloc, USER_CONFIG, "{\"tools\":[\"read_file\"]}");
    defer alloc.free(e);

    // `parseFromSlice` + deinit, NOT the leaky variant: the leaky one exists
    // for an arena-backed request allocator, and under `testing.allocator` it
    // reports every allocation as a leak (which is how CI caught this file).
    var parsed = try std.json.parseFromSlice(pabrik_config_get.ConfigJson, alloc, e, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const cfg = parsed.value;
    // The overlay's list replaced the user's two-entry list...
    try testing.expectEqual(@as(usize, 1), cfg.tools.?.len);
    // ...and the profile the workspace never mentioned - with its credential
    // - is still there.
    try testing.expect(std.mem.indexOf(u8, e, "sk-user") != null);
    try testing.expectEqual(@as(u32, 2000), cfg.retry_delay_ms);
}

test "effectiveConfig: no base at all still applies the overlay" {
    const alloc = testing.allocator;
    const merged = try effectiveConfig(alloc, null, "{\"active_profile\":\"mine\"}");
    defer alloc.free(merged);
    try testing.expectEqualStrings("{\"active_profile\":\"mine\"}", merged);
}

test "overlayFromPutBody keeps only the workspace-scoped keys" {
    // An arena, because `overlayFromPutBody` runs the same `parseConfigInput`
    // the HTTP handler does - and that parser is `parseFromSliceLeaky` on
    // purpose, since the handler gives it the request arena.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const body =
        \\{"profiles":{"claude":{"model":"opus"}},
        \\ "tools":["read_file"],
        \\ "notify_on_complete":true,
        \\ "retry_delay_ms":2000,
        \\ "web_launch_enabled":true}
    ;
    const overlay = try overlayFromPutBody(alloc, body);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, overlay, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // `profiles` is normalised to the on-disk `profiles_models` - see
    // `workspace_config.ScopedKey`.
    try testing.expect(obj.get("profiles_models") != null);
    try testing.expect(obj.get("tools") != null);
    // The General-tab keys stay user-level (D4).
    try testing.expect(obj.get("notify_on_complete") == null);
    try testing.expect(obj.get("retry_delay_ms") == null);
    try testing.expect(obj.get("web_launch_enabled") == null);
}

test "overlayFromPutBody refuses a body with nothing scoped, and malformed JSON" {
    // Arena for the same reason as the test above: the parse that REFUSES also
    // goes through the leaky parser.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // Refusing beats storing `{}`: storing it would look like a successful
    // save while every setting the user typed silently stayed user-level.
    try testing.expectError(error.NothingScoped, overlayFromPutBody(alloc, "{\"retry_delay_ms\":2000}"));
    try testing.expectError(error.NothingScoped, overlayFromPutBody(alloc, "{}"));
    try testing.expectError(error.InvalidBody, overlayFromPutBody(alloc, "{\"tools\":"));
}

test "statusFor/messageFor map every variant (a new one breaks this switch)" {
    try testing.expectEqual(@as(u16, 400), statusFor(error.WorkspaceIdRequired));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidBody));
    try testing.expectEqual(@as(u16, 400), statusFor(error.NothingScoped));
    try testing.expectEqual(@as(u16, 500), statusFor(error.QueryFailed));
    try testing.expectEqual(@as(u16, 500), statusFor(error.OutOfMemory));
    try testing.expectEqualStrings("workspace_id required", messageFor(error.WorkspaceIdRequired));
}

test "the GET response masks the web_search key, like the user-scope GET" {
    // An ARENA, exactly like the equivalent test in `pabrik_config_get.zig`:
    // `maskProviders` builds a whole masked copy of the providers map and the
    // response builder serialises it, and neither hands ownership back.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const secret = "SENTINEL_SECRET_DO_NOT_LEAK";
    const base = "{\"web_search\":{\"brave\":{\"url\":\"https://api.search.brave.com\",\"key\":\"" ++ secret ++ "\"}}}";

    const e = try effectiveConfig(alloc, base, null);
    var parsed = try std.json.parseFromSlice(pabrik_config_get.ConfigJson, alloc, e, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const cfg = parsed.value;

    // Positive control: the unmasked field really does hold the secret, so
    // the absence assertion below cannot pass vacuously.
    try testing.expect(std.mem.indexOf(u8, cfg.web_search.?.object.get("brave").?.object.get("key").?.string, secret) != null);

    const wire = try pabrik_config_get.makeConfigResponse(alloc, cfg);
    try testing.expect(std.mem.indexOf(u8, wire, secret) == null);
    // The section still ships - masking redacts the key, it does not drop the
    // block the Settings UI renders.
    try testing.expect(std.mem.indexOf(u8, wire, "\"web_search\":{") != null);
}

test "a workspace's overlay is invisible to another workspace over the store path" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try store.saveRaw(alloc, &ctx.db, store.FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"a\"}");

    // Captured and freed: `loadRaw` returns an OWNED slice, and passing it
    // straight into the call leaked it (CI: "leaked 1 allocations").
    const overlay_a = store.loadRaw(alloc, &ctx.db, store.FILE_MODE_OWNER, "ws_a") catch null;
    defer if (overlay_a) |o| alloc.free(o);
    const for_a = try effectiveConfig(alloc, USER_CONFIG, overlay_a);
    defer alloc.free(for_a);
    try testing.expect(std.mem.indexOf(u8, for_a, "\"a\"") != null);

    const overlay_b = store.loadRaw(alloc, &ctx.db, store.FILE_MODE_OWNER, "ws_b") catch null;
    defer if (overlay_b) |o| alloc.free(o);
    const for_b = try effectiveConfig(alloc, USER_CONFIG, overlay_b);
    defer alloc.free(for_b);
    // Inheriting: the user's profile, not ws_a's override.
    try testing.expect(std.mem.indexOf(u8, for_b, "claude") != null);
}
