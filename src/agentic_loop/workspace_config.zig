//! The per-workspace config OVERLAY: how a workspace's `workspace_settings`
//! row is combined with the user-level config.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

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

/// How a seeding pass went. Boot logs it; tests assert on it.
pub const SeedReport = struct {
    seeded: usize = 0,
    already_decided: usize = 0,
};

/// Give every UNDECIDED workspace a copy of the user-level config.
/// "Undecided" is `workspace_settings_store.hasRow`, not `hasOverlay`: a
/// workspace whose row exists with an empty body was deliberately reset to
pub fn seedWorkspaces(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    base_config_json: []const u8,
) !SeedReport {
    const store = @import("workspace_settings_store.zig");
    const overlay = try workspaceScopedOverlay(allocator, base_config_json);
    defer allocator.free(overlay);

    var report = SeedReport{};
    // Nothing to copy: seeding every workspace with `{}` would write an
    // "explicitly inherited" row for workspaces nobody has looked at yet,
    // and then the real config would never reach them.
    if (std.mem.eql(u8, overlay, "{}")) return report;

    var ids: std.ArrayList([]u8) = .empty;
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    // The reader lives in its OWN block so it is closed before the writes
    // below, not at the end of the function.
    {
        var q = db.query(allocator, "SELECT id FROM workspaces", &.{}) catch return report;
        defer q.deinit();
        while (q.next() catch null) |row| {
            defer row.deinit(allocator);
            if (row.values.len == 0 or row.values[0].len == 0) continue;
            try ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
    }

    for (ids.items) |id| {
        const decided = store.hasRow(allocator, db, store.FILE_MODE_OWNER, id) catch continue;
        if (decided) {
            report.already_decided += 1;
            continue;
        }
        store.saveRaw(allocator, db, store.FILE_MODE_OWNER, id, overlay) catch continue;
        report.seeded += 1;
    }
    return report;
}

/// The user-level config TEXT that a workspace overlay is layered over. *
/// `--auth` ON -> `users.config_json` for `owner`.
pub fn baseConfigText(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
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

// ─── the seeding pass ──────────────────────────────────────────────────────

const SeedCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupSeedDb() !SeedCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY)", &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_settings (
        \\  owner TEXT NOT NULL DEFAULT '',
        \\  workspace_id TEXT NOT NULL,
        \\  config_json TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  PRIMARY KEY (owner, workspace_id)
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownSeed(ctx: *SeedCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

fn addWorkspace(ctx: *SeedCtx, id: []const u8) !void {
    try ctx.db.exec(testing.allocator, "INSERT INTO workspaces (id) VALUES (?)", &[_][]const u8{id});
}

fn overlayBody(ctx: *SeedCtx, workspace_id: []const u8) !?[]u8 {
    const alloc = testing.allocator;
    const store = @import("workspace_settings_store.zig");
    return store.loadRaw(alloc, &ctx.db, store.FILE_MODE_OWNER, workspace_id);
}

fn hasSettingsRow(ctx: *SeedCtx, workspace_id: []const u8) !bool {
    const store = @import("workspace_settings_store.zig");
    return store.hasRow(testing.allocator, &ctx.db, store.FILE_MODE_OWNER, workspace_id);
}

test "seeding copies the user config into every existing workspace" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer teardownSeed(&ctx);

    try addWorkspace(&ctx, "ws_a");
    try addWorkspace(&ctx, "ws_b");

    const report = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);
    try testing.expectEqual(@as(usize, 2), report.seeded);
    try testing.expectEqual(@as(usize, 0), report.already_decided);

    const a = (try overlayBody(&ctx, "ws_a")) orelse return error.NotSeeded;
    defer alloc.free(a);
    var parsed = try parse(alloc, a);
    defer parsed.deinit();
    try testing.expectEqualStrings("claude", parsed.value.object.get("active_profile").?.string);
    // The credential travelled with the profile it belongs to.
    // `profiles_models`, not `profiles`: the disk key is what the runtime
    // parses - see `ScopedKey`.
    try testing.expectEqualStrings(
        "sk-secret",
        parsed.value.object.get("profiles_models").?.object.get("claude").?.object.get("api_key").?.string,
    );

    const b = (try overlayBody(&ctx, "ws_b")) orelse return error.NotSeeded;
    defer alloc.free(b);
}

test "seeding is idempotent and never overwrites a workspace that already decided" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer teardownSeed(&ctx);

    try addWorkspace(&ctx, "ws_a");
    try addWorkspace(&ctx, "ws_b");
    const store = @import("workspace_settings_store.zig");

    // ws_a already has its own override.
    try store.saveRaw(alloc, &ctx.db, store.FILE_MODE_OWNER, "ws_a", "{\"active_profile\":\"mine\"}");
    // ws_b was deliberately reset to inherit.
    try store.clear(alloc, &ctx.db, store.FILE_MODE_OWNER, "ws_b");

    const report = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);
    try testing.expectEqual(@as(usize, 0), report.seeded);
    try testing.expectEqual(@as(usize, 2), report.already_decided);

    // ws_a's own choice survived.
    const a = (try overlayBody(&ctx, "ws_a")) orelse return error.OverrideLost;
    defer alloc.free(a);
    try testing.expectEqualStrings("{\"active_profile\":\"mine\"}", a);
    // ws_b's RESET survived - this is the assertion that would fail if the
    // pass asked `hasOverlay` instead of `hasRow`, and it is the difference
    // between a reset that sticks and one that is undone at every boot.
    try testing.expect((try overlayBody(&ctx, "ws_b")) == null);
    try testing.expect(try hasSettingsRow(&ctx, "ws_b"));
}

test "a second seeding run adds no workspaces and changes nothing" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer teardownSeed(&ctx);

    try addWorkspace(&ctx, "ws_a");
    const first = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);
    try testing.expectEqual(@as(usize, 1), first.seeded);

    const second = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);
    try testing.expectEqual(@as(usize, 0), second.seeded);
    try testing.expectEqual(@as(usize, 1), second.already_decided);
}

test "a config with nothing workspace-scoped seeds nothing at all" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer teardownSeed(&ctx);

    try addWorkspace(&ctx, "ws_a");

    // The trap this guards: writing `{}` would create an "explicitly
    // inherited" row for a workspace nobody has looked at, and the real
    // config would never reach it afterwards.
    const report = try seedWorkspaces(alloc, &ctx.db, "{\"retry_delay_ms\":2000}");
    try testing.expectEqual(@as(usize, 0), report.seeded);
    try testing.expect(!try hasSettingsRow(&ctx, "ws_a"));
}

test "a new workspace added later is seeded by the next boot" {
    const alloc = testing.allocator;
    var ctx = try setupSeedDb();
    defer teardownSeed(&ctx);

    try addWorkspace(&ctx, "ws_a");
    _ = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);

    try addWorkspace(&ctx, "ws_new");
    const report = try seedWorkspaces(alloc, &ctx.db, USER_CONFIG);
    try testing.expectEqual(@as(usize, 1), report.seeded);
    try testing.expect(try hasSettingsRow(&ctx, "ws_new"));
}
