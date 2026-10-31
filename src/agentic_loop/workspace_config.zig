//! The per-workspace config OVERLAY: how a workspace's `workspace_settings`
//! row is combined with the user-level config.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

/// Merge `overlay_json` over `base_json`, returning a newly allocated JSON
/// object text.
pub fn overlayJson(
    allocator: std.mem.Allocator,
    base_json: []const u8,
    overlay_json: []const u8,
) ![]u8 {
    const base_text = if (std.mem.trim(u8, base_json, " \t\r\n").len == 0)
        "{}"
    else
        base_json;

    const overlay_text = std.mem.trim(u8, overlay_json, " \t\r\n");
    if (overlay_text.len == 0 or std.mem.eql(u8, overlay_text, "{}")) {
        return allocator.dupe(u8, base_text);
    }

    const base_parsed = std.json.parseFromSlice(std.json.Value, allocator, base_text, .{}) catch
        return allocator.dupe(u8, base_text);
    defer base_parsed.deinit();
    const overlay_parsed = std.json.parseFromSlice(std.json.Value, allocator, overlay_text, .{}) catch
        return allocator.dupe(u8, base_text);
    defer overlay_parsed.deinit();

    const base_obj = switch (base_parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, base_text),
    };
    const overlay_obj = switch (overlay_parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, base_text),
    };
    if (overlay_obj.count() == 0) return allocator.dupe(u8, base_text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMergedObject(allocator, &out, base_obj, overlay_obj);
    return out.toOwnedSlice(allocator);
}

/// The explicit error set of the `appendMergedObject`/`appendMergedValue`
/// pair.
const AppendError = error{OutOfMemory};

/// Write `{ base keys (overlay-merged where present) , overlay-only keys }`.
fn appendMergedObject(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: std.json.ObjectMap,
    overlay: std.json.ObjectMap,
) AppendError!void {
    try out.append(allocator, '{');
    var first = true;

    var base_it = base.iterator();
    while (base_it.next()) |entry| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, out, entry.key_ptr.*);
        try out.append(allocator, ':');
        if (overlay.get(entry.key_ptr.*)) |override| {
            try appendMergedValue(allocator, out, entry.value_ptr.*, override);
        } else {
            try appendValueJson(allocator, out, entry.value_ptr.*);
        }
    }

    var overlay_it = overlay.iterator();
    while (overlay_it.next()) |entry| {
        // Already emitted above, in the base's position.
        if (base.contains(entry.key_ptr.*)) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, removed_profiles_key)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, out, entry.key_ptr.*);
        try out.append(allocator, ':');
        try appendValueJson(allocator, out, entry.value_ptr.*);
    }

    try out.append(allocator, '}');
}

/// One value under the merge rule: objects merge, everything else is replaced.
fn appendMergedValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: std.json.Value,
    overlay: std.json.Value,
) AppendError!void {
    switch (base) {
        .object => |base_obj| switch (overlay) {
            .object => |overlay_obj| {
                return appendMergedObject(allocator, out, base_obj, overlay_obj);
            },
            else => {},
        },
        else => {},
    }
    try appendValueJson(allocator, out, overlay);
}

fn appendValueJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
) AppendError!void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

/// An object KEY needs the same escaping a string value does - a profile
/// named `my "prod" key` must not be able to produce invalid JSON.
fn appendKeyJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
) AppendError!void {
    try appendValueJson(allocator, out, .{ .string = key });
}

/// The config keys that MOVED to workspace scope.
pub const ScopedKey = struct {
    /// The spelling `LlmConfigJson` parses out of config.json - the one the
    /// overlay MUST use, because the overlay is merged into that same text
    /// and then handed to `LlmConfig.initFromJsonText`.
    disk: []const u8,
    /// The spelling the HTTP wire uses, when it differs.
    wire: []const u8 = "",
};

pub const WORKSPACE_SCOPED_KEYS = [_]ScopedKey{
    // The agents map keeps its old spelling on BOTH sides: `profiles_models`
    // on disk is what every existing config.json holds, and `profiles` is what
    // the HTTP clients already speak. The concept is an AGENT (see `LlmAgent`).
    .{ .disk = "profiles_models", .wire = "profiles" },
    .{ .disk = "active_profile" },
    .{ .disk = "mcp_servers" },
    .{ .disk = "tools" },
    .{ .disk = "skill_evals" },
    .{ .disk = "web_search" },
};

/// The value for one scoped key, preferring the ON-DISK spelling.
fn scopedValue(obj: std.json.ObjectMap, key: ScopedKey) ?std.json.Value {
    if (obj.get(key.disk)) |v| return v;
    if (key.wire.len > 0) return obj.get(key.wire);
    return null;
}

/// The workspace-scoped SLICE of a user-level config, as overlay JSON.
pub fn workspaceScopedOverlay(
    allocator: std.mem.Allocator,
    user_config_json: []const u8,
) ![]u8 {
    const text = std.mem.trim(u8, user_config_json, " \t\r\n");
    if (text.len == 0) return allocator.dupe(u8, "{}");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
        return allocator.dupe(u8, "{}");
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "{}"),
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    for (WORKSPACE_SCOPED_KEYS) |key| {
        const value = scopedValue(obj, key) orelse continue;
        // A null value carries no override - copying `"tools": null` into the
        // overlay would say "this workspace overrides tools" and show an
        // Overridden pill over the user's own list.
        if (value == .null) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        // Always the DISK spelling, whichever spelling the input used.
        try appendKeyJson(allocator, &out, key.disk);
        try out.append(allocator, ':');
        try appendValueJson(allocator, &out, value);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn isWorkspaceScopedKey(key: []const u8) bool {
    for (WORKSPACE_SCOPED_KEYS) |scoped| {
        if (std.mem.eql(u8, key, scoped.disk)) return true;
        if (scoped.wire.len > 0 and std.mem.eql(u8, key, scoped.wire)) return true;
    }
    return false;
}

/// The user-level document minus the workspace-scoped keys: everything a
/// workspace still shares once its own row owns profiles, MCP servers, tools,
/// skill evals and web search.
pub fn withoutScopedKeys(allocator: std.mem.Allocator, base_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, base_json, .{}) catch
        return allocator.dupe(u8, "{}");
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, "{}"),
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (isWorkspaceScopedKey(entry.key_ptr.*)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, &out, entry.key_ptr.*);
        try out.append(allocator, ':');
        try appendValueJson(allocator, &out, entry.value_ptr.*);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

const settings_store = @import("workspace_settings_store.zig");

/// The user-level config TEXT that a workspace overlay is layered over. *
/// `--auth` ON -> `users.config_json` for `owner`.
pub fn baseConfigText(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    environment: ?*const std.process.Environ.Map,
    auth_enabled: bool,
    owner: []const u8,
) ?[]u8 {
    if (auth_enabled) {
        return pabrikcore.user_config_store.loadRaw(allocator, db, owner) catch null;
    }

    const env = environment orelse return null;
    // `getDefaultConfigPath` only READS the map, but its parameter is a
    // mutable pointer. Same cast the config handlers use.
    const config_path = pabrikcore.config.getDefaultConfigPath(allocator, @constCast(env)) catch return null;
    defer allocator.free(config_path);

    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch return null;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch null;
}

/// `baseConfigText` with the workspace-scoped keys removed. A workspace owns
/// its profiles, MCP servers, tools, skill evals and web search through its
/// own row, so it inherits only the rest (General) from the user document.
pub fn scopedBaseConfigText(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    environment: ?*const std.process.Environ.Map,
    auth_enabled: bool,
    owner: []const u8,
) ?[]u8 {
    const base = baseConfigText(allocator, io, db, environment, auth_enabled, owner) orelse return null;
    const stripped = withoutScopedKeys(allocator, base) catch null;
    allocator.free(base);
    return stripped;
}

/// The overlay key that records profile names this workspace removed. It is
/// bookkeeping, not config: it is never merged into a config document.
pub const removed_profiles_key = "removed_profiles";

/// `overlay_json` with `name` recorded as removed from this workspace, so the
/// user document cannot hand the profile back over a later read.
pub fn withRemovedProfile(
    allocator: std.mem.Allocator,
    overlay_json: []const u8,
    name: []const u8,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, overlay_json, .{}) catch
        return allocator.dupe(u8, overlay_json);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return allocator.dupe(u8, overlay_json),
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, removed_profiles_key)) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendKeyJson(allocator, &out, entry.key_ptr.*);
        try out.append(allocator, ':');
        try appendValueJson(allocator, &out, entry.value_ptr.*);
    }
    if (!first) try out.append(allocator, ',');
    try appendKeyJson(allocator, &out, removed_profiles_key);
    try out.append(allocator, ':');
    try out.append(allocator, '[');
    var first_name = true;
    if (obj.get(removed_profiles_key)) |existing| {
        if (existing == .array) for (existing.array.items) |item| {
            if (item != .string) continue;
            if (std.mem.eql(u8, item.string, name)) continue;
            if (!first_name) try out.append(allocator, ',');
            first_name = false;
            try appendValueJson(allocator, &out, item);
        };
    }
    if (!first_name) try out.append(allocator, ',');
    try appendValueJson(allocator, &out, .{ .string = name });
    try out.append(allocator, ']');
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// The scoped settings a read layers over `scopedBaseConfigText`: the
/// workspace's OWN row and nothing else. No row (or a cleared one) means no
/// scoped settings - which is what makes a brand-new workspace start empty.
pub fn workspaceOverlay(
    allocator: std.mem.Allocator,
    db: *database.Db,
    auth_enabled: bool,
    owner: []const u8,
    workspace_id: []const u8,
) ?[]u8 {
    if (workspace_id.len == 0) return null;
    const key = settings_store.ownerKey(auth_enabled, owner);
    // A row that cannot be opened is reported, never silently rendered as "this
    // workspace inherits everything" - the two states need different remedies.
    return settings_store.loadRaw(allocator, db, key, workspace_id) catch |err| {
        std.log.warn("workspace config: cannot unseal the overlay for {s}/{s} ({s})", .{ key, workspace_id, @errorName(err) });
        return null;
    };
}

// ===================================================================== Tests
// ===================================================================== Every
// assertion re-PARSES the merged text and reads a value out of it, rather

const testing = std.testing;

const Parsed = std.json.Parsed(std.json.Value);

fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

test "a scalar in the overlay wins and everything else survives" {
    const alloc = testing.allocator;
    const base = "{\"retry_delay_ms\":2000,\"notify_on_complete\":false}";
    const merged = try overlayJson(alloc, base, "{\"retry_delay_ms\":500}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 500), obj.get("retry_delay_ms").?.integer);
    // Absent from the overlay -> the user's value is what a run sees.
    try testing.expectEqual(false, obj.get("notify_on_complete").?.bool);
}

test "an array is REPLACED, so a workspace can narrow the tool list" {
    const alloc = testing.allocator;
    const base = "{\"tools\":[\"read_file\",\"write_file\",\"bash\"]}";
    const merged = try overlayJson(alloc, base, "{\"tools\":[\"read_file\"]}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    // The positive control: the base list really had three entries, so a
    // length of 1 below is a replacement and not a no-op on an empty base.
    try testing.expectEqual(@as(usize, 1), tools.items.len);
    try testing.expectEqualStrings("read_file", tools.items[0].string);
}

test "objects DEEP-merge, so overriding one profile field keeps its api_key" {
    const alloc = testing.allocator;
    const base =
        "{\"active_profile\":\"claude\"," ++
        "\"profiles\":{\"claude\":{\"model\":\"opus\",\"api_key\":\"sk-secret\"}," ++
        "\"other\":{\"model\":\"gpt-4o\"}}}";
    const merged = try overlayJson(alloc, base, "{\"profiles\":{\"claude\":{\"model\":\"sonnet\"}}}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;

    const claude = obj.get("profiles").?.object.get("claude").?.object;
    try testing.expectEqualStrings("sonnet", claude.get("model").?.string);
    // The credential the workspace never mentioned. "Last write wins" would
    // have dropped it and broken every run in this workspace.
    try testing.expectEqualStrings("sk-secret", claude.get("api_key").?.string);
    // A profile the overlay never mentioned at all.
    try testing.expectEqualStrings("gpt-4o", obj.get("profiles").?.object.get("other").?.object.get("model").?.string);
    // A top-level key the overlay never mentioned.
    try testing.expectEqualStrings("claude", obj.get("active_profile").?.string);
}

test "a key that exists only in the overlay is added" {
    const alloc = testing.allocator;
    const merged = try overlayJson(alloc, "{\"retry_delay_ms\":2000}", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("claude", obj.get("active_profile").?.string);
    try testing.expectEqual(@as(i64, 2000), obj.get("retry_delay_ms").?.integer);
}

test "an empty or `{}` overlay returns the base byte-for-byte" {
    const alloc = testing.allocator;
    const base = "{\"a\":1,\"b\":{\"c\":2}}";

    const from_empty = try overlayJson(alloc, base, "");
    defer alloc.free(from_empty);
    try testing.expectEqualStrings(base, from_empty);

    const from_braces = try overlayJson(alloc, base, "  {}  ");
    defer alloc.free(from_braces);
    try testing.expectEqualStrings(base, from_braces);

    const from_whitespace = try overlayJson(alloc, base, "\n\t ");
    defer alloc.free(from_whitespace);
    try testing.expectEqualStrings(base, from_whitespace);
}

test "a malformed overlay degrades to the base instead of breaking the turn" {
    const alloc = testing.allocator;
    const base = "{\"retry_delay_ms\":2000}";

    const merged = try overlayJson(alloc, base, "{\"retry_delay_ms\": ");
    defer alloc.free(merged);
    try testing.expectEqualStrings(base, merged);

    // A non-object overlay is equally unusable: there are no keys to merge in.
    const array_overlay = try overlayJson(alloc, base, "[1,2,3]");
    defer alloc.free(array_overlay);
    try testing.expectEqualStrings(base, array_overlay);

    const scalar_overlay = try overlayJson(alloc, base, "\"nope\"");
    defer alloc.free(scalar_overlay);
    try testing.expectEqualStrings(base, scalar_overlay);
}

test "an empty base is treated as an empty object, so the overlay still applies" {
    const alloc = testing.allocator;
    const merged = try overlayJson(alloc, "", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    try testing.expectEqualStrings("claude", parsed.value.object.get("active_profile").?.string);
}

test "a malformed BASE degrades to the malformed text rather than to invalid JSON" {
    const alloc = testing.allocator;
    // Nothing sensible can be merged into a broken base; handing the caller a
    // copy of what it passed is the only honest answer, and it keeps this
    // function's "never fails a turn" contract.
    const merged = try overlayJson(alloc, "{oops", "{\"active_profile\":\"claude\"}");
    defer alloc.free(merged);
    try testing.expectEqualStrings("{oops", merged);
}

test "keys needing JSON escaping survive the round trip" {
    const alloc = testing.allocator;
    // Profile names are user input, and a quote in one must not be able to
    // produce text that fails to parse.
    const merged = try overlayJson(alloc, "{}", "{\"a\\\"b\":1}");
    defer alloc.free(merged);

    var parsed = try parse(alloc, merged);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("a\"b").?.integer);
}

// ─── the copy slice ────────────────────────────────────────────────────────
// The single most important property here is a NEGATIVE one: the copy must
// NOT carry the General-tab keys.

const USER_CONFIG =
    \\{"profiles_models":{"claude":{"model":"opus","api_key":"sk-secret"}},
    \\ "active_profile":"claude",
    \\ "mcp_servers":{"files":{"transport":"stdio","command":"mcp-files"}},
    \\ "tools":["read_file","write_file"],
    \\ "web_search":{"brave":{"url":"https://api.search.brave.com","key":"sk-search"}},
    \\ "skill_evals":{"enabled":true,"max_skills_per_run":4},
    \\ "notify_on_complete":true,
    \\ "notify_on_error":true,
    \\ "retry_delay_ms":2000,
    \\ "web_launch_enabled":true,
    \\ "model_compaction_size_kb":250,
    \\ "max_capacity_token_model":200000,
    \\ "compaction_threshold_percent":80}
;

test "the copy carries every workspace-scoped key" {
    const alloc = testing.allocator;
    const copy = try workspaceScopedOverlay(alloc, USER_CONFIG);
    defer alloc.free(copy);

    var parsed = try parse(alloc, copy);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("opus", obj.get("profiles_models").?.object.get("claude").?.object.get("model").?.string);
    try testing.expectEqualStrings("claude", obj.get("active_profile").?.string);
    try testing.expect(obj.get("mcp_servers").?.object.get("files") != null);
    try testing.expectEqual(@as(usize, 2), obj.get("tools").?.array.items.len);
    try testing.expectEqual(true, obj.get("skill_evals").?.object.get("enabled").?.bool);
    try testing.expect(obj.get("web_search") != null);
}

test "the copy does NOT carry the General-tab keys, so they keep applying everywhere" {
    const alloc = testing.allocator;

    // Positive control: the source really does have them.
    var source = try parse(alloc, USER_CONFIG);
    defer source.deinit();
    for ([_][]const u8{ "notify_on_complete", "notify_on_error", "retry_delay_ms", "web_launch_enabled", "model_compaction_size_kb", "max_capacity_token_model", "compaction_threshold_percent" }) |key| {
        try testing.expect(source.value.object.get(key) != null);
    }

    const copy = try workspaceScopedOverlay(alloc, USER_CONFIG);
    defer alloc.free(copy);
    var parsed = try parse(alloc, copy);
    defer parsed.deinit();

    for ([_][]const u8{ "notify_on_complete", "notify_on_error", "retry_delay_ms", "web_launch_enabled", "model_compaction_size_kb", "max_capacity_token_model", "compaction_threshold_percent" }) |key| {
        try testing.expect(parsed.value.object.get(key) == null);
    }
}

test "a config using the WIRE spelling is normalised to the on-disk one" {
    const alloc = testing.allocator;

    // The bug this pins: `LlmConfigJson` parses `profiles_models`, while the
    // HTTP wire calls it `profiles`.
    const wire_shaped = "{\"profiles\":{\"claude\":{\"model\":\"opus\"}},\"tools\":[\"read_file\"]}";
    const copy = try workspaceScopedOverlay(alloc, wire_shaped);
    defer alloc.free(copy);

    var parsed = try parse(alloc, copy);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("profiles") == null);
    try testing.expectEqualStrings(
        "opus",
        parsed.value.object.get("profiles_models").?.object.get("claude").?.object.get("model").?.string,
    );
    // The keys that need no translation still come through.
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("tools").?.array.items.len);
}

test "the on-disk spelling wins when a config carries both" {
    const alloc = testing.allocator;
    const copy = try workspaceScopedOverlay(
        alloc,
        "{\"profiles_models\":{\"a\":{\"model\":\"disk\"}},\"profiles\":{\"b\":{\"model\":\"wire\"}}}",
    );
    defer alloc.free(copy);

    var parsed = try parse(alloc, copy);
    defer parsed.deinit();
    // One key, not two: emitting both would let a stale wire-spelled map
    // shadow the real one depending on iteration order.
    try testing.expectEqual(@as(usize, 1), parsed.value.object.count());
    try testing.expect(parsed.value.object.get("profiles_models").?.object.get("a") != null);
}

test "the copy is exactly the workspace-scoped key set, no more" {
    const alloc = testing.allocator;
    const copy = try workspaceScopedOverlay(alloc, USER_CONFIG);
    defer alloc.free(copy);

    var parsed = try parse(alloc, copy);
    defer parsed.deinit();
    try testing.expectEqual(WORKSPACE_SCOPED_KEYS.len, parsed.value.object.count());
}

test "a null or absent key is not copied, so it cannot fake an override" {
    const alloc = testing.allocator;
    const copy = try workspaceScopedOverlay(
        alloc,
        "{\"tools\":null,\"active_profile\":\"claude\",\"profiles_models\":{\"p\":{\"model\":\"m\"}}}",
    );
    defer alloc.free(copy);

    var parsed = try parse(alloc, copy);
    defer parsed.deinit();
    // `tools: null` means "no explicit list" at user level. Copying it would
    // claim this workspace overrides tools while overriding it with nothing.
    try testing.expect(parsed.value.object.get("tools") == null);
    try testing.expect(parsed.value.object.get("active_profile") != null);
    try testing.expect(parsed.value.object.get("profiles_models") != null);
}

test "a config with nothing to copy yields {}, never junk" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "", "   ", "not json", "[1,2]", "{}", "{\"retry_delay_ms\":2000}" }) |input| {
        const copy = try workspaceScopedOverlay(alloc, input);
        defer alloc.free(copy);
        try testing.expectEqualStrings("{}", copy);
    }
}

// ─── the read path ─────────────────────────────────────────────────────────

const OverlayCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupOverlayDb() !OverlayCtx {
    const alloc = testing.allocator;
    settings_store.installTestKey();
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_settings (
        \\  owner TEXT NOT NULL DEFAULT '',
        \\  workspace_id TEXT NOT NULL,
        \\  config_json TEXT,
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY (owner, workspace_id)
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownOverlay(ctx: *OverlayCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn addWorkspace(ctx: *OverlayCtx, id: []const u8) !void {
    try ctx.db.exec(testing.allocator, "INSERT INTO workspaces (id) VALUES (?)", &[_][]const u8{id});
}

test "a workspace that was never configured has no scoped settings at all" {
    const alloc = testing.allocator;
    var ctx = try setupOverlayDb();
    defer teardownOverlay(&ctx);

    try addWorkspace(&ctx, "ws_new");

    try testing.expect(workspaceOverlay(alloc, &ctx.db, true, "u_1", "ws_new") == null);
    try testing.expect(workspaceOverlay(alloc, &ctx.db, false, "user_system", "ws_new") == null);
}

test "a cleared row is exactly as empty as no row" {
    const alloc = testing.allocator;
    var ctx = try setupOverlayDb();
    defer teardownOverlay(&ctx);

    try addWorkspace(&ctx, "ws_a");
    try settings_store.clear(alloc, &ctx.db, settings_store.FILE_MODE_OWNER, "ws_a");

    try testing.expect(workspaceOverlay(alloc, &ctx.db, false, "user_system", "ws_a") == null);
}

test "the workspace's own row is returned exactly, with nothing filled in" {
    const alloc = testing.allocator;
    var ctx = try setupOverlayDb();
    defer teardownOverlay(&ctx);

    try addWorkspace(&ctx, "ws_a");
    const stored = "{\"tools\":[\"glob\"]}";
    try settings_store.saveRaw(alloc, &ctx.db, settings_store.FILE_MODE_OWNER, "ws_a", stored);

    const overlay = workspaceOverlay(alloc, &ctx.db, false, "user_system", "ws_a") orelse
        return error.OverlayMissing;
    defer alloc.free(overlay);
    try testing.expectEqualStrings(stored, overlay);
}

test "an empty workspace_id has no overlay, whatever is stored" {
    const alloc = testing.allocator;
    var ctx = try setupOverlayDb();
    defer teardownOverlay(&ctx);

    try testing.expect(workspaceOverlay(alloc, &ctx.db, true, "u_1", "") == null);
}

test "a removed profile name is recorded once" {
    const alloc = testing.allocator;
    const once = try withRemovedProfile(alloc, "{\"profiles_models\":{}}", "gone");
    defer alloc.free(once);
    const twice = try withRemovedProfile(alloc, once, "gone");
    defer alloc.free(twice);

    var parsed = try parse(alloc, twice);
    defer parsed.deinit();
    const names = parsed.value.object.get(removed_profiles_key).?.array;
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings("gone", names.items[0].string);
}

// ─── The user document a workspace still shares ─────────────────────────────

const MIXED_CONFIG =
    \\{"profiles_models":{"claude":{"model":"opus","api_key":"sk-user"}},
    \\ "active_profile":"claude",
    \\ "tools":["read_file"],
    \\ "mcp_servers":{"a":{"url":"https://a.example.com"}},
    \\ "skill_evals":{"enabled":true},
    \\ "web_search":{"brave":{"url":"https://api.search.brave.com","key":"k"}},
    \\ "retry_delay_ms":1234,
    \\ "notify_on_complete":false}
;

test "withoutScopedKeys keeps General and drops every workspace-scoped key" {
    const alloc = testing.allocator;
    const stripped = try withoutScopedKeys(alloc, MIXED_CONFIG);
    defer alloc.free(stripped);

    var parsed = try parse(alloc, stripped);
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expect(obj.get("profiles_models") == null);
    try testing.expect(obj.get("profiles") == null);
    try testing.expect(obj.get("active_profile") == null);
    try testing.expect(obj.get("tools") == null);
    try testing.expect(obj.get("mcp_servers") == null);
    try testing.expect(obj.get("skill_evals") == null);
    try testing.expect(obj.get("web_search") == null);

    try testing.expectEqual(@as(i64, 1234), obj.get("retry_delay_ms").?.integer);
    try testing.expectEqual(false, obj.get("notify_on_complete").?.bool);
}

test "withoutScopedKeys strips the wire spelling `profiles` too" {
    const alloc = testing.allocator;
    const stripped = try withoutScopedKeys(alloc, "{\"profiles\":{\"a\":{}},\"retry_delay_ms\":7}");
    defer alloc.free(stripped);

    var parsed = try parse(alloc, stripped);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("profiles") == null);
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("retry_delay_ms").?.integer);
}
