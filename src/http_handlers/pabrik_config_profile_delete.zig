//! Deleting one LLM profile, from either scope: the user-scope route
//! `DELETE /api/config/pabrik/profiles/:name`, and the workspace-scope twin in
//! `workspace_config.zig`, which also clears this workspace's own copy.

const std = @import("std");
const json = std.json;
const auth_common = @import("auth_common.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const config = pabrikcore.config;
const user_config_store = pabrikcore.user_config_store;

// =====================================================================
// Domain types
// =====================================================================

/// Body of every profile-delete response, on both routes.
pub const ProfileDeleteResponse = struct {
    success: bool,
    profile_name: []const u8,
    active_profile_was_cleared: bool = false,
    error_message: ?[]const u8 = null,
};

/// What removing a profile from a config document did.
pub const RemovalOutcome = struct {
    /// The named profile was present and is gone from the document.
    removed: bool,
    /// `active_profile` named it, and that field was cleared.
    active_cleared: bool,
};

/// The document with one profile removed, re-serialized in full. `document` is
/// owned by the caller.
pub const ProfileRemoval = struct {
    document: []u8,
    outcome: RemovalOutcome,
};

// =====================================================================
// Use-cases (pure)
// =====================================================================

/// Remove `name` from `document_json`'s `profiles_models` map, keeping every
/// other key of the document.
pub fn removeProfileFromDocument(
    allocator: std.mem.Allocator,
    document_json: []const u8,
    name: []const u8,
) !ProfileRemoval {
    const value = std.json.parseFromSliceLeaky(json.Value, allocator, document_json, .{}) catch
        return error.InvalidDocument;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidDocument,
    };

    var removed = false;
    if (obj.getPtr("profiles_models")) |profiles| {
        if (profiles.* == .object) {
            removed = profiles.object.swapRemove(name);
        }
    }

    // Only when the profile really was there: a 404 must not clear the field.
    var active_cleared = false;
    if (removed) {
        if (obj.getPtr("active_profile")) |active| {
            if (active.* == .string and std.mem.eql(u8, active.string, name)) {
                active.* = .null;
                active_cleared = true;
            }
        }
    }

    const document = try std.json.Stringify.valueAlloc(allocator, value, .{
        .whitespace = .indent_tab,
    });
    return .{
        .document = document,
        .outcome = .{ .removed = removed, .active_cleared = active_cleared },
    };
}

// =====================================================================
// The user-level config document
// =====================================================================

/// Resolved on-disk config paths. Both slices live for the lifetime of the
/// request (per-request arena) — no explicit `free` needed.
const ConfigPaths = struct {
    dir: []const u8,
    path: []const u8,
};

/// The user-level config document: `users.config_json` under `--auth`,
/// `config.json` otherwise. `null` when there is nothing to read.
pub fn loadUserConfigDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    di: *pabrikcore.App,
    owner: []const u8,
) !?[]u8 {
    if (di.auth_enabled) return user_config_store.loadRaw(allocator, di.db, owner);
    const paths = try resolveConfigPaths(allocator);
    return readConfigFile(allocator, io, paths.path);
}

/// Write the user-level config document back where `loadUserConfigDocument`
/// read it from.
pub fn saveUserConfigDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    di: *pabrikcore.App,
    owner: []const u8,
    document: []const u8,
) !void {
    if (di.auth_enabled) return user_config_store.saveRaw(allocator, di.db, owner, document);
    const paths = try resolveConfigPaths(allocator);
    try ensureConfigDir(io, paths.dir);
    try writeConfigFile(io, paths.path, document);
}

/// Remove `name` from the user-level config and persist the result. `removed =
/// false` means the document had no such profile and nothing was written.
pub fn removeProfileFromUserConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    di: *pabrikcore.App,
    owner: []const u8,
    name: []const u8,
) !RemovalOutcome {
    const existing = try loadUserConfigDocument(allocator, io, di, owner) orelse return .{
        .removed = false,
        .active_cleared = false,
    };
    const removal = try removeProfileFromDocument(allocator, existing, name);
    if (!removal.outcome.removed) return removal.outcome;

    try saveUserConfigDocument(allocator, io, di, owner, removal.document);
    return removal.outcome;
}

// =====================================================================
// Handler: DELETE /api/config/pabrik/profiles/:name
// =====================================================================

/// Removes a single profile from the user-level config (`users.config_json`
/// under `--auth`, `config.json` otherwise) and live-reloads the in-memory
/// `LlmConfig` so running workflows see the change.
pub fn pabrikConfigProfileDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const name = req.params.get("name") orelse
        return makeErrorResponse(allocator, res, 400, "", "Missing :name path parameter");
    if (name.len == 0)
        return makeErrorResponse(allocator, res, 400, "", "Profile name cannot be empty");

    const di = pabrikcore.getSingleton() catch
        return makeErrorResponse(allocator, res, 500, name, "Failed to resolve session");

    // Auth mode: the session names the owner whose `config_json` is edited.
    // The id is COPIED: `freeSessionLookup` runs at the end of this block, and
    // the work below happens after that.
    var owner: []const u8 = "";
    var owner_owned: ?[]u8 = null;
    defer if (owner_owned) |owned| allocator.free(owned);
    if (di.auth_enabled) {
        const tok = auth_common.parseSessionToken(req.headers) orelse
            return makeErrorResponse(allocator, res, 401, name, "Unauthenticated");
        const sess = auth_common.lookupSession(allocator, di.db, tok) orelse
            return makeErrorResponse(allocator, res, 401, name, "Unauthenticated");
        defer auth_common.freeSessionLookup(allocator, sess);
        owner_owned = try allocator.dupe(u8, sess.user_id);
        owner = owner_owned.?;
    }

    const outcome = removeProfileFromUserConfig(allocator, io, di, owner, name) catch |err| switch (err) {
        error.InvalidDocument => return makeErrorResponse(allocator, res, 500, name, "Invalid JSON in config"),
        else => return makeErrorResponse(allocator, res, 500, name, "Failed to update the config"),
    };
    if (!outcome.removed)
        return makeErrorResponse(allocator, res, 404, name, "Profile not found");

    // Config is per-user under `--auth`, so there is no global to reload.
    if (di.auth_enabled) {
        di.clearMcpToolsCache();
        return makeSuccessResponse(allocator, res, name, outcome.active_cleared, null);
    }

    return switch (liveReloadLlmConfig(io, name)) {
        .ok => makeSuccessResponse(allocator, res, name, outcome.active_cleared, null),
        .warning => |msg| makeSuccessResponse(allocator, res, name, outcome.active_cleared, msg),
        .fatal => |msg| makeErrorResponse(allocator, res, 500, name, msg),
    };
}

// =====================================================================
// File-mode plumbing
// =====================================================================

/// Resolve the config dir + file path from the process environment.
fn resolveConfigPaths(allocator: std.mem.Allocator) !ConfigPaths {
    const di = pabrikcore.getSingleton() catch |err| {
        std.log.err("profile delete: singleton unavailable: {s}", .{@errorName(err)});
        return error.SingletonUnavailable;
    };
    const environment_ptr = di.environment orelse {
        std.log.err("profile delete: environment unavailable", .{});
        return error.EnvironmentUnavailable;
    };
    // `getDefaultConfigDir` only READS the map, but its parameter is a mutable
    // pointer - the same cast the config handlers use.
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("profile delete: failed to get config dir: {s}", .{@errorName(err)});
        return error.ConfigDirFailed;
    };
    errdefer allocator.free(config_dir);

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("profile delete: failed to build config path: {s}", .{@errorName(err)});
        return error.ConfigPathFailed;
    };

    return ConfigPaths{ .dir = config_dir, .path = config_path };
}

/// Create the config directory if it does not exist (idempotent).
fn ensureConfigDir(io: std.Io, config_dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("profile delete: failed to create config dir: {s}", .{@errorName(err)});
        return err;
    };
}

/// Read the whole config file. `null` means it does not exist.
fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.err("profile delete: failed to open config: {s}", .{@errorName(err)});
            return err;
        },
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("profile delete: failed to read config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Replace the config file with `document` (truncate).
fn writeConfigFile(io: std.Io, config_path: []const u8, document: []const u8) !void {
    const write_file = std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    }) catch |err| {
        std.log.err("profile delete: failed to open config for write: {s}", .{@errorName(err)});
        return err;
    };
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    writer.interface.writeAll(document) catch |err| {
        std.log.err("profile delete: failed to write config: {s}", .{@errorName(err)});
        return err;
    };
    writer.flush() catch |err| {
        std.log.err("profile delete: failed to flush config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Outcome of the live-reload phase.
pub const LiveReloadResult = union(enum) {
    ok,
    warning: []const u8,
    fatal: []const u8,
};

/// Live-reload the global `LlmConfig` from disk.
pub fn liveReloadLlmConfig(io: std.Io, name: []const u8) LiveReloadResult {
    const di = pabrikcore.getSingleton() catch |err| {
        std.log.err("profile delete: live reload singleton failed: {s}", .{@errorName(err)});
        return .{ .warning = "Profile deleted from disk but live reload failed (singleton unavailable)" };
    };

    const env_for_reload: *std.process.Environ.Map = @ptrCast(@constCast(di.environment orelse {
        std.log.err("profile delete/{s}: live reload environment unavailable", .{name});
        return .{ .warning = "Profile deleted from disk but live reload failed (environment unavailable)" };
    }));

    const global_allocator = di.allocator;
    var new_cfg = config.LlmConfig.init(global_allocator, io, null, env_for_reload) catch |err| {
        std.log.err("profile delete/{s}: live reload parse failed: {s}", .{ name, @errorName(err) });
        return .{ .warning = "Profile deleted from disk but live reload parse failed" };
    };

    const new_ptr = global_allocator.create(config.LlmConfig) catch |err| {
        std.log.err("profile delete/{s}: live reload alloc failed: {s}", .{ name, @errorName(err) });
        var mut: *config.LlmConfig = &new_cfg;
        mut.deinit();
        return .{ .fatal = "Out of memory" };
    };
    new_ptr.* = new_cfg;

    // Atomically swap. Previous-pointer free happens inside setLlmConfig.
    pabrikcore.setLlmConfig(di, new_ptr);
    std.log.info("profile delete/{s}: live-reloaded llm_config", .{name});
    return .ok;
}

// =====================================================================
// Response builders (shared with the workspace-scope route)
// =====================================================================

/// Build a JSON error response with a `ProfileDeleteResponse` body.
pub fn makeErrorResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    status_code: u16,
    name: []const u8,
    error_message: []const u8,
) !gserverz.HttpResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = false,
        .profile_name = name,
        .error_message = error_message,
    }, .{});
    return res.jsonResponse(.{ .status_code = status_code, .data = body });
}

/// Build the 200 OK success response. `warning` is `null` on a clean success or
/// a short string when the delete landed but the live reload did not.
pub fn makeSuccessResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    name: []const u8,
    active_cleared: bool,
    warning: ?[]const u8,
) !gserverz.HttpResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = true,
        .profile_name = name,
        .active_profile_was_cleared = active_cleared,
        .error_message = warning,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

/// A config shaped like a real one: the profile map, the active profile, and
/// the keys that have nothing to do with profiles.
const FULL_CONFIG =
    \\{"profiles_models":{
    \\  "alpha":{"model":"gpt-4o","base_url":"https://api.example.com","api_key":"sk-alpha"},
    \\  "beta":{"model":"claude","base_url":"https://api.anthropic.com","api_key":"sk-beta"}},
    \\ "active_profile":"alpha",
    \\ "mcp_servers":{"graphify":{"command":"/usr/bin/python3"}},
    \\ "tools":["glob","search"],
    \\ "skill_evals":{"enabled":true,"max_skills_per_run":5},
    \\ "web_search":{"brave":{"url":"https://api.search.brave.com","key":"sk-search"}},
    \\ "notify_on_complete":true,
    \\ "retry_delay_ms":2000}
;

/// Every test runs on an ARENA: `removeProfileFromDocument` parses with
/// `parseFromSliceLeaky` (the handlers give it the request arena), so the
/// document and everything parsed out of it share one lifetime.
const TestArena = struct {
    state: std.heap.ArenaAllocator,

    fn init() TestArena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestArena) void {
        self.state.deinit();
    }

    fn allocator(self: *TestArena) std.mem.Allocator {
        return self.state.allocator();
    }
};

test "removeProfileFromDocument: removes the named profile and keeps every other key" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const removal = try removeProfileFromDocument(alloc, FULL_CONFIG, "alpha");
    try testing.expect(removal.outcome.removed);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    const profiles = obj.get("profiles_models").?.object;
    try testing.expect(profiles.get("alpha") == null);
    try testing.expectEqualStrings("claude", profiles.get("beta").?.object.get("model").?.string);
    try testing.expectEqualStrings(
        "sk-beta",
        profiles.get("beta").?.object.get("api_key").?.string,
    );

    // The keys a stripped write-back struct used to drop.
    try testing.expect(obj.get("mcp_servers").?.object.get("graphify") != null);
    try testing.expectEqual(@as(usize, 2), obj.get("tools").?.array.items.len);
    try testing.expectEqual(true, obj.get("skill_evals").?.object.get("enabled").?.bool);
    try testing.expectEqualStrings(
        "sk-search",
        obj.get("web_search").?.object.get("brave").?.object.get("key").?.string,
    );
    try testing.expectEqual(true, obj.get("notify_on_complete").?.bool);
    try testing.expectEqual(@as(i64, 2000), obj.get("retry_delay_ms").?.integer);
}

test "removeProfileFromDocument: clears active_profile when it named the deleted profile" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const removal = try removeProfileFromDocument(alloc, FULL_CONFIG, "alpha");
    try testing.expect(removal.outcome.active_cleared);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("active_profile").? == .null);
}

test "removeProfileFromDocument: leaves active_profile alone when another profile was deleted" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const removal = try removeProfileFromDocument(alloc, FULL_CONFIG, "beta");
    try testing.expect(removal.outcome.removed);
    try testing.expect(!removal.outcome.active_cleared);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("alpha", parsed.value.object.get("active_profile").?.string);
}

test "removeProfileFromDocument: reports not-removed for an unknown name, changing nothing" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const removal = try removeProfileFromDocument(alloc, FULL_CONFIG, "ghost");
    try testing.expect(!removal.outcome.removed);
    try testing.expect(!removal.outcome.active_cleared);

    // The document round-trips unchanged, so a caller that ignores the flag
    // still cannot lose data by writing it back.
    var before = try std.json.parseFromSlice(std.json.Value, alloc, FULL_CONFIG, .{});
    defer before.deinit();
    var after = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer after.deinit();
    try testing.expectEqual(
        before.value.object.get("profiles_models").?.object.count(),
        after.value.object.get("profiles_models").?.object.count(),
    );
    try testing.expect(after.value.object.get("tools") != null);
}

test "removeProfileFromDocument: a document with no profiles map still round-trips" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const removal = try removeProfileFromDocument(alloc, "{\"retry_delay_ms\":2000}", "alpha");
    try testing.expect(!removal.outcome.removed);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 2000), parsed.value.object.get("retry_delay_ms").?.integer);
}

test "removeProfileFromDocument: removes the last profile without touching the rest" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    const last =
        \\{"profiles_models":{"only":{"model":"m"}},"active_profile":"only","tools":["glob"]}
    ;
    const removal = try removeProfileFromDocument(alloc, last, "only");
    try testing.expect(removal.outcome.removed);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, removal.document, .{});
    defer parsed.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("profiles_models").?.object.count(),
    );
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("tools").?.array.items.len);
}

test "removeProfileFromDocument: a malformed document is rejected, never half-applied" {
    var arena = TestArena.init();
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(
        error.InvalidDocument,
        removeProfileFromDocument(alloc, "{oops", "alpha"),
    );
    try testing.expectError(
        error.InvalidDocument,
        removeProfileFromDocument(alloc, "[1,2,3]", "alpha"),
    );
}
