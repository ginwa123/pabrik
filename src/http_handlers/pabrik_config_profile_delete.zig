//! HTTP handler + use-case for `DELETE /api/config/pabrik/profiles/:name`.
//! Removes a single profile from `config.json` and live-reloads the in-memory
//! `LlmConfig` so running workflows see the change.

const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const config = pabrikcore.config;
const user_config_store = pabrikcore.user_config_store;

// =====================================================================
// Domain types
// =====================================================================

/// Struct shape that the use-case mutates in-place. The full LlmConfig type
/// lives in `Config.zig` and is much heavier (it deserializes every known
/// field).
pub const PabrikConfigJsonForDelete = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    // Empty default — matches the parallel `ConfigJson` in
    // `pabrik_config_get.zig`/`pabrik_config_put.zig` and the `LlmConfigJson`
    // convention.
    url_style: []const u8 = "",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,

    /// Free all owned strings, the `profiles_models` ObjectMap's keys, the
    /// nested object values (shallow deep-clean for the strings), and the
    /// backing storage.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.base_url);
        allocator.free(self.url_style);
        allocator.free(self.system_prompt);
        if (self.active_profile) |ap| allocator.free(ap);
        if (self.profiles_models) |_| {
            if (self.profiles_models.? == .object) {
                // Take a direct mutable pointer to the field in `self`'s
                // storage.
                const obj: *json.ObjectMap = &self.profiles_models.?.object;
                // Walk the top-level entries: free each top-level key (duped
                // by `put`) and — if the value is an object — free the nested
                // ObjectMap's string values and backing storage via
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    if (entry.value_ptr.* == .object) {
                        const nested: *json.ObjectMap = @constCast(&entry.value_ptr.*.object);
                        freeObjectMapContents(allocator, nested);
                    }
                }
                obj.deinit(allocator);
            }
        }
    }
};

/// Response shape returned by `DELETE /api/config/pabrik/profiles/:name`.
/// `active_profile_was_cleared` is true iff the deleted profile was the
/// active one (the handler also cleared `active_profile` on disk).
pub const ProfileDeleteResponse = struct {
    success: bool,
    profile_name: []const u8,
    active_profile_was_cleared: bool = false,
    error_message: ?[]const u8 = null,
};

/// Resolved on-disk config paths. Both slices live for the lifetime of the
/// request (per-request arena) — no explicit `free` needed.
const ConfigPaths = struct {
    dir: []const u8,
    path: []const u8,
};

/// Outcome of the live-reload phase.
const LiveReloadResult = union(enum) {
    ok,
    warning: []const u8,
    fatal: []const u8,
};

// =====================================================================
// Use-case (pure)
// =====================================================================

/// Free the contents of an ObjectMap: walks its entries, freeing the string
/// values, then frees the ObjectMap's backing storage.
fn freeObjectMapContents(allocator: std.mem.Allocator, obj: *json.ObjectMap) void {
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
    obj.deinit(allocator);
}

/// Recursively free all owned data inside a `json.Value` reachable through a
/// mutable pointer.
fn freeJsonValueDeep(allocator: std.mem.Allocator, value: *json.Value) void {
    switch (value.*) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| {
                freeJsonValueDeep(allocator, item);
            }
            arr.deinit();
        },
        .object => |*obj| {
            // Walk the entries: free the keys (duped by put) and recursively
            // free the values. Production data has duped keys, so this is
            // safe in production.
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValueDeep(allocator, entry.value_ptr);
            }
            obj.deinit(allocator);
        },
    }
}

/// Pure use-case: remove the named profile from `cfg.profiles_models` and
/// clear `cfg.active_profile` if it matched. Returns true if the profile
/// existed and was removed, false otherwise.
pub fn removeProfileFromConfig(
    allocator: std.mem.Allocator,
    cfg: *PabrikConfigJsonForDelete,
    name: []const u8,
) !bool {
    if (cfg.profiles_models == null) return false;
    if (cfg.profiles_models.? != .object) return false;

    // Take a direct mutable pointer to the ObjectMap field in `cfg`'s
    // storage (see `deinit` for the rationale on avoiding the
    // `if (optional) |pm|` capture chain).
    const profiles_obj: *json.ObjectMap = &cfg.profiles_models.?.object;

    if (profiles_obj.get(name) == null) return false;

    // fetchSwapRemove returns the KV pair; the caller takes ownership of
    // freeing the key and any value-owned data.
    if (profiles_obj.fetchSwapRemove(name)) |kv| {
        allocator.free(kv.key);
        if (kv.value == .object) {
            const removed_obj: *json.ObjectMap = @constCast(&kv.value.object);
            freeObjectMapContents(allocator, removed_obj);
        }
    }

    if (cfg.active_profile) |ap| {
        if (std.mem.eql(u8, ap, name)) {
            allocator.free(ap);
            cfg.active_profile = null;
        }
    }

    return true;
}

// =====================================================================
// Handler
// =====================================================================

/// `DELETE /api/config/pabrik/profiles/:name` Removes a single profile from
/// `config.json` and live-reloads the in-memory `LlmConfig` so running
/// workflows see the change.
pub fn pabrikConfigProfileDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Validate `:name` path parameter.
    const name = req.params.get("name") orelse
        return makeErrorResponse(allocator, res, 400, "", "Missing :name path parameter");
    if (name.len == 0)
        return makeErrorResponse(allocator, res, 400, "", "Profile name cannot be empty");

    // 1b. Auth mode: per-user config from users.config_json
    // (Migration 092). config.json is ignored and the global
    // LlmConfig is NOT reloaded (config is per-user).
    {
        const di = pabrikcore.getSingleton() catch {
            return makeErrorResponse(allocator, res, 500, name, "Failed to resolve session");
        };
        if (di.auth_enabled) {
            const tok = auth_common.parseSessionToken(req.headers) orelse {
                return makeErrorResponse(allocator, res, 401, name, "Unauthenticated");
            };
            const sess = auth_common.lookupSession(allocator, di.db, tok) orelse {
                return makeErrorResponse(allocator, res, 401, name, "Unauthenticated");
            };
            defer auth_common.freeSessionLookup(allocator, sess);
            const stored = user_config_store.loadRaw(allocator, di.db, sess.user_id) catch {
                return makeErrorResponse(allocator, res, 500, name, "Failed to load user config");
            };
            if (stored == null) {
                return makeErrorResponse(allocator, res, 404, name, "No user config exists");
            }
            const content = stored.?;
            var config_json = parseConfigJson(allocator, content) catch
                return makeErrorResponse(allocator, res, 500, name, "Invalid JSON in user config");
            const was_active = isActiveProfile(&config_json, name);
            const removed = removeProfileFromConfig(allocator, &config_json, name) catch {
                config_json.deinit(allocator);
                return makeErrorResponse(allocator, res, 500, name, "Failed to remove profile");
            };
            if (!removed) {
                config_json.deinit(allocator);
                return makeErrorResponse(allocator, res, 404, name, "Profile not found");
            }
            const config_str = std.json.Stringify.valueAlloc(allocator, config_json, .{
                .whitespace = .indent_tab,
            }) catch {
                config_json.deinit(allocator);
                return makeErrorResponse(allocator, res, 500, name, "Failed to serialize user config");
            };
            user_config_store.saveRaw(allocator, di.db, sess.user_id, config_str) catch {
                config_json.deinit(allocator);
                return makeErrorResponse(allocator, res, 500, name, "Failed to save user config");
            };
            config_json.deinit(allocator);
            di.clearMcpToolsCache();
            return makeSuccessResponse(allocator, res, name, was_active, null);
        }
    }

    // 2. Resolve on-disk config paths (dir + file). The PUT handler
    //    (pabrik_config_put.zig) uses the same pattern.
    const paths = resolveConfigPaths(allocator, name) catch
        return makeErrorResponse(allocator, res, 500, name, "Failed to resolve config paths");

    // 3. Ensure the config directory exists (idempotent).
    ensureConfigDir(io, paths.dir) catch
        return makeErrorResponse(allocator, res, 500, name, "Failed to create config directory");

    // 4. Read the existing config file. `null` = file does not exist.
    const content = readConfigFile(allocator, io, paths.path) catch {
        return makeErrorResponse(allocator, res, 500, name, "Failed to read config");
    } orelse {
        return makeErrorResponse(allocator, res, 404, name, "No config file exists");
    };

    // 5. Parse the existing config. On failure, `content` is freed by
    //    the arena (per-request reaps request-scoped allocations).
    var config_json = parseConfigJson(allocator, content) catch
        return makeErrorResponse(allocator, res, 500, name, "Invalid JSON in config");

    // 6. Apply the use-case: remove the named profile. Capture
    //    `was_active` BEFORE the use-case clears it (the use-case
    //    sets `cfg.active_profile = null` on a match).
    const was_active = isActiveProfile(&config_json, name);
    const removed = removeProfileFromConfig(allocator, &config_json, name) catch {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 500, name, "Failed to remove profile");
    };
    if (!removed) {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 404, name, "Profile not found");
    }

    // 7. Write the updated config back to disk. On failure, free the
    //    parsed struct so its owned strings don't leak.
    writeConfigBack(allocator, io, paths.path, &config_json) catch {
        config_json.deinit(allocator);
        return makeErrorResponse(allocator, res, 500, name, "Failed to write config");
    };

    // 8. Live-reload the in-memory LlmConfig.
    const reload_result = liveReloadLlmConfig(io, name);

    config_json.deinit(allocator);

    return switch (reload_result) {
        .ok => makeSuccessResponse(allocator, res, name, was_active, null),
        .warning => |msg| makeSuccessResponse(allocator, res, name, was_active, msg),
        .fatal => |msg| makeErrorResponse(allocator, res, 500, name, msg),
    };
}

// =====================================================================
// Sub-helpers (handler plumbing)
// =====================================================================

/// Get the singleton, then resolve the config dir + file path.
/// Logs the error and returns the same error variant on failure so
/// the handler can map it to HTTP 500.
fn resolveConfigPaths(allocator: std.mem.Allocator, name: []const u8) !ConfigPaths {
    const di = pabrikcore.getSingleton() catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: singleton unavailable: {s}", .{ name, @errorName(err) });
        return error.SingletonUnavailable;
    };
    const environment_ptr = di.environment orelse {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: environment unavailable", .{name});
        return error.EnvironmentUnavailable;
    };
    // `getDefaultConfigDir` does not actually modify the env, but its
    // signature takes a mutable pointer. The same pattern is used in
    // `pabrik_config_put.zig:185-225`.
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(environment_ptr));

    const config_dir = config.getDefaultConfigDir(allocator, environment) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: failed to get config dir: {s}", .{ name, @errorName(err) });
        return error.ConfigDirFailed;
    };
    errdefer allocator.free(config_dir);

    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: failed to build config path: {s}", .{ name, @errorName(err) });
        return error.ConfigPathFailed;
    };

    return ConfigPaths{ .dir = config_dir, .path = config_path };
}

/// Create the config directory if it does not exist (idempotent).
/// The original handler inlined this as a `catch |err|` block.
fn ensureConfigDir(io: std.Io, config_dir: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, config_dir) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to create config dir: {s}", .{@errorName(err)});
        return err;
    };
}

/// Read the entire config file into a heap-allocated buffer.
/// Returns `null` if the file does not exist (HTTP 404 path).
/// Returns other errors on I/O failure (HTTP 500 path).
fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            std.log.err("DELETE /api/config/pabrik/profiles: failed to open config: {s}", .{@errorName(err)});
            return err;
        },
    };
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to read config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Parse the on-disk config JSON into a `PabrikConfigJsonForDelete`.
/// The parsed struct's strings are independent allocations; ownership
/// transfers to the caller (use `deinit` to free them).
fn parseConfigJson(allocator: std.mem.Allocator, content: []const u8) !PabrikConfigJsonForDelete {
    const parsed = std.json.parseFromSliceLeaky(PabrikConfigJsonForDelete, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to parse config: {s}", .{@errorName(err)});
        return err;
    };
    return parsed;
}

/// Was the named profile the currently-active one? The use-case
/// clears `active_profile` if it matched, so we capture this BEFORE
/// calling the use-case.
fn isActiveProfile(cfg: *const PabrikConfigJsonForDelete, name: []const u8) bool {
    return if (cfg.active_profile) |ap| std.mem.eql(u8, ap, name) else false;
}

/// Serialize the updated config and write it back to disk (truncate).
/// On success the file on disk is the new authoritative state.
fn writeConfigBack(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    config_json: *PabrikConfigJsonForDelete,
) !void {
    const config_str = std.json.Stringify.valueAlloc(allocator, config_json.*, .{
        .whitespace = .indent_tab,
    }) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to serialize config: {s}", .{@errorName(err)});
        return err;
    };

    const write_file = std.Io.Dir.createFileAbsolute(io, config_path, .{
        .truncate = true,
    }) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to open config for write: {s}", .{@errorName(err)});
        return err;
    };
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    writer.interface.writeAll(config_str) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to write config: {s}", .{@errorName(err)});
        return err;
    };
    writer.flush() catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles: failed to flush config: {s}", .{@errorName(err)});
        return err;
    };
}

/// Live-reload the global `LlmConfig` from disk.
fn liveReloadLlmConfig(io: std.Io, name: []const u8) LiveReloadResult {
    const di = pabrikcore.getSingleton() catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: live reload singleton failed: {s}", .{ name, @errorName(err) });
        return .{ .warning = "Profile deleted from disk but live reload failed (singleton unavailable)" };
    };

    const env_for_reload: *std.process.Environ.Map = @ptrCast(@constCast(di.environment orelse {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: live reload environment unavailable", .{name});
        return .{ .warning = "Profile deleted from disk but live reload failed (environment unavailable)" };
    }));

    const global_allocator = di.allocator;
    var new_cfg = config.LlmConfig.init(global_allocator, io, null, env_for_reload) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: live reload parse failed: {s}", .{ name, @errorName(err) });
        return .{ .warning = "Profile deleted from disk but live reload parse failed" };
    };

    const new_ptr = global_allocator.create(config.LlmConfig) catch |err| {
        std.log.err("DELETE /api/config/pabrik/profiles/{s}: live reload alloc failed: {s}", .{ name, @errorName(err) });
        // Free the local copy we failed to heap-allocate.
        var mut: *config.LlmConfig = &new_cfg;
        mut.deinit();
        return .{ .fatal = "Out of memory" };
    };
    new_ptr.* = new_cfg;

    // Atomically swap. Previous-pointer free happens inside setLlmConfig.
    pabrikcore.setLlmConfig(di, new_ptr);
    std.log.info("DELETE /api/config/pabrik/profiles/{s}: live-reloaded llm_config", .{name});
    return .ok;
}

// =====================================================================
// Response builders (DRY)
// =====================================================================

/// Build a JSON error response with a `ProfileDeleteResponse` body.
/// Used for every 4xx/5xx exit path in the handler.
fn makeErrorResponse(
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

/// Build the 200 OK success response. `warning` is `null` on a clean
/// success or a short string on a "deleted from disk but live reload
/// had a non-fatal issue" outcome.
fn makeSuccessResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    name: []const u8,
    was_active: bool,
    warning: ?[]const u8,
) !gserverz.HttpResponse {
    const body = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = true,
        .profile_name = name,
        .active_profile_was_cleared = was_active,
        .error_message = warning,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

// ===== Tests merged from pabrik_config_profile_delete_test.zig (2026-09-11
// flatten) ===== Tests for the pure `removeProfileFromConfig` use-case used
// by the `DELETE /api/config/pabrik/profiles/:name` handler.

const testing = std.testing;

// The symbols under test (`removeProfileFromConfig` and
// `PabrikConfigJsonForDelete`) are defined in
// `http_handlers/pabrik_config_profile_delete.zig` and re-exported by

/// Build a `PabrikConfigJsonForDelete` with two profiles (`alpha` and `beta`)
/// and `active_profile = "alpha"`.
fn makeConfigJson(allocator: std.mem.Allocator) !PabrikConfigJsonForDelete {
    var cfg: PabrikConfigJsonForDelete = .{};
    errdefer cfg.deinit(allocator);

    cfg.api_key = try allocator.dupe(u8, "test-key");
    cfg.model = try allocator.dupe(u8, "gpt-4o");
    cfg.base_url = try allocator.dupe(u8, "https://api.example.com");
    cfg.url_style = try allocator.dupe(u8, "openai");
    cfg.max_tokens = null;
    cfg.system_prompt = try allocator.dupe(u8, "");
    cfg.active_profile = try allocator.dupe(u8, "alpha");

    // Build the profiles map as a local var, populate it, then attach to
    // `cfg` — the same pattern used in `pabrik_config_put.zig`.
    var profiles = try json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer profiles.deinit(allocator);

    // alpha
    var alpha = try json.ObjectMap.init(allocator, &.{}, &.{});
    try alpha.put(allocator, "model", .{ .string = try allocator.dupe(u8, "gpt-4o") });
    try alpha.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.example.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "alpha"), .{ .object = alpha });

    // beta
    var beta = try json.ObjectMap.init(allocator, &.{}, &.{});
    try beta.put(allocator, "model", .{ .string = try allocator.dupe(u8, "claude") });
    try beta.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.anthropic.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "beta"), .{ .object = beta });

    cfg.profiles_models = .{ .object = profiles };
    return cfg;
}

/// Build a minimal `PabrikConfigJsonForDelete` with `profiles_models = null`
/// and `active_profile = null` — exercises the "missing profiles_models"
/// graceful path.
fn makeEmptyConfigJson(allocator: std.mem.Allocator) !PabrikConfigJsonForDelete {
    var cfg: PabrikConfigJsonForDelete = .{};
    errdefer cfg.deinit(allocator);

    cfg.api_key = try allocator.dupe(u8, "");
    cfg.model = try allocator.dupe(u8, "");
    cfg.base_url = try allocator.dupe(u8, "");
    cfg.url_style = try allocator.dupe(u8, "openai");
    cfg.max_tokens = null;
    cfg.system_prompt = try allocator.dupe(u8, "");
    cfg.profiles_models = null;
    cfg.active_profile = null;

    return cfg;
}

test "removeProfileFromConfig: removes the named profile and returns true" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(removed);

    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 1), obj.count());
    try testing.expect(obj.get("alpha") == null);
    try testing.expect(obj.get("beta") != null);
}

test "removeProfileFromConfig: returns false when the profile does not exist" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "ghost");
    try testing.expect(!removed);

    // Existing profiles unchanged
    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 2), obj.count());
}

test "removeProfileFromConfig: clears active_profile when it matches the deleted name" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(cfg.active_profile == null);
}

test "removeProfileFromConfig: preserves active_profile when it does not match" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "beta");
    try testing.expectEqualStrings("alpha", cfg.active_profile.?);
}

test "removeProfileFromConfig: handles missing profiles_models gracefully" {
    const allocator = testing.allocator;
    var cfg = try makeEmptyConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(!removed);
}
