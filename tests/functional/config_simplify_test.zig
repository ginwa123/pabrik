// Functional tests for the config-simplify change (plan
// 2026-08-24-config-simplify-remove-defaults).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// The preboot seam
// ============================================================================

/// Every path `writeStubLlmProfile` seeds, in the same order.
const CONFIG_CANDIDATES = [_][]const []const u8{
    &.{ ".config", "pabrik", "config.json" },
    &.{ "Library", "Application Support", "pabrik", "config.json" },
    &.{ "AppData", "Roaming", "pabrik", "config.json" },
};

/// Boot with a profile-only config on disk, then replace it with `cfg_json`.
fn bootSeeded(cfg_json: []const u8) !Harness {
    const h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    for (CONFIG_CANDIDATES) |parts| {
        const dir = try harness.harnessPath(gpa, h.temp_dir, parts[0 .. parts.len - 1]);
        defer gpa.free(dir);
        std.Io.Dir.cwd().createDirPath(io, dir) catch continue;
        const file = try std.fs.path.join(gpa, &.{ dir, parts[parts.len - 1] });
        defer gpa.free(file);
        var f = try std.Io.Dir.cwd().createFile(io, file, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, cfg_json);
    }
    return h;
}

/// The `config.json` the running binary reads and writes, plus its parsed
/// form. Both owned, so the document outlives the bytes it came from.
const DiskConfig = struct {
    bytes: []u8,
    doc: harness.Json,

    fn deinit(self: *DiskConfig) void {
        self.doc.deinit();
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Read the harness HOME's `config.json` from the path the CURRENT platform's
/// `Config.zig:getDefaultConfigDir` selects.
fn platformConfigFile(home: []const u8) ![]u8 {
    return switch (@import("builtin").os.tag) {
        .macos => harness.harnessPath(gpa, home, &.{ "Library", "Application Support", "pabrik", "config.json" }),
        .windows => harness.harnessPath(gpa, home, &.{ "AppData", "Roaming", "pabrik", "config.json" }),
        else => harness.harnessPath(gpa, home, &.{ ".config", "pabrik", "config.json" }),
    };
}

/// Read + parse the on-disk `config.json` (Python's
/// `json.loads((_platform_config_dir(h.temp_dir) / "config.json").read_text())`).
fn readDiskConfig(home: []const u8) !DiskConfig {
    const path = try platformConfigFile(home);
    defer gpa.free(path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    errdefer gpa.free(bytes);
    const doc: harness.Json = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}),
    };
    return .{ .bytes = bytes, .doc = doc };
}

// ============================================================================
// Shared assertion helpers
// ============================================================================

/// The `profiles` map out of a config GET body, or a named failure.
fn profilesMap(doc: *const harness.Json) !std.json.ObjectMap {
    const v = doc.get("profiles") orelse return .{};
    return switch (v) {
        .object => |o| o,
        else => {
            std.debug.print("`profiles` is present but not an object\n", .{});
            return error.TestUnexpectedResult;
        },
    };
}

/// The string at `key` of a JSON object, or a named failure.
fn strField(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (o.get(key) orelse {
        std.debug.print("missing `{s}` in a JSON object\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// The seven top-level keys plan 2026-08-24-config-simplify removed. Test 1
/// asserts none of them is on the GET wire; test 2 asserts none of them is
/// written back to disk.
const REMOVED_WIRE_KEYS = [_][]const u8{
    "api_endpoint",
    "api_key",
    "model",
    "url_style",
    "temperature",
    "max_tokens",
    "system_prompt",
};

/// The six keys test 2 checks on DISK (`api_endpoint` is not in this list:
/// Python's test 2 named only these six, and `api_endpoint` was already not
/// a field of the on-disk `ConfigJson` writer).
const REMOVED_DISK_KEYS = [_][]const u8{
    "api_key",
    "model",
    "base_url",
    "url_style",
    "max_tokens",
    "system_prompt",
};

/// Assert none of `keys` is present at the ROOT of `doc`.
fn expectNoKeysAtRoot(doc: *const harness.Json, keys: []const []const u8, what: []const u8) !void {
    for (keys) |key| {
        if (doc.get(key) != null) {
            std.debug.print("removed top-level default '{s}' is still {s}\n", .{ key, what });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 1: a profile-only config serves a profile-only payload
// ============================================================================

// A config.json without top-level api_key/model/base_url/url_style serves
// cleanly. GET /api/config/pabrik → 200 with `profiles` present and NONE of
// the removed keys on the wire.
test "profile_only_config_boots_and_get_has_no_default_fields" {
    try harness.requirePabrikBin(io, gpa);

    const seed =
        \\{
        \\  "profiles_models": {
        \\    "alpha": {
        \\      "model": "alpha-model",
        \\      "base_url": "https://alpha.example.com",
        \\      "api_key": "alpha-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "alpha",
        \\  "notify_on_complete": true,
        \\  "retry_delay_ms": 1000
        \\}
    ;
    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const profiles = try profilesMap(&doc);
    const alpha = switch (profiles.get("alpha") orelse {
        std.debug.print("profile `alpha` missing from GET: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("profiles.alpha is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqualStrings("alpha-model", try strField(alpha, "model"));
    try testing.expectEqualStrings("alpha", doc.str("active_profile") orelse {
        std.debug.print("GET has no `active_profile`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });

    try expectNoKeysAtRoot(&doc, &REMOVED_WIRE_KEYS, "on the GET wire");
}

// ============================================================================
// Test 2: a defaults-free PUT never writes the defaults back
// ============================================================================

// PUT exactly what the new frontend sends (no top-level defaults) → 200; the
// on-disk config.json gains none of the six keys; the PUT'd profile survives.
test "put_without_defaults_keeps_file_clean" {
    try harness.requirePabrikBin(io, gpa);

    const seed =
        \\{
        \\  "profiles_models": {},
        \\  "active_profile": null
        \\}
    ;
    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{
        \\  "profiles": {
        \\    "work": {
        \\      "model": "work-model",
        \\      "base_url": "https://work.example.com",
        \\      "api_key": "work-key",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "work",
        \\  "notify_on_complete": false,
        \\  "retry_delay_ms": 500
        \\}
    ;
    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = put_body,
            .expect = &.{200},
        });
        defer r.deinit();
    }

    var disk = try readDiskConfig(h.temp_dir);
    defer disk.deinit();

    try expectNoKeysAtRoot(&disk.doc, &REMOVED_DISK_KEYS, "on disk");

    const on_disk_profiles = disk.doc.object("profiles_models") orelse {
        std.debug.print("config.json has no `profiles_models`: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    };
    if (!on_disk_profiles.contains("work")) {
        std.debug.print("PUT'd `work` profile missing from disk: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("work", disk.doc.str("active_profile") orelse {
        std.debug.print("config.json has no `active_profile`: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    });
    try testing.expectEqual(@as(i64, 500), disk.doc.int("retry_delay_ms") orelse {
        std.debug.print("config.json has no integer `retry_delay_ms`: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    });
}

// ============================================================================
// Test 3: a legacy config with top-level keys still serves
// ============================================================================

// Backward compat: a legacy config WITH top-level keys still serves. Present
// keys win over backfill — the read surface answers exactly as it did before
// this change.
test "old_format_config_still_boots" {
    try harness.requirePabrikBin(io, gpa);

    const seed =
        \\{
        \\  "api_key": "legacy-key",
        \\  "model": "legacy-model",
        \\  "base_url": "https://legacy.example.com",
        \\  "url_style": "openai",
        \\  "profiles_models": {
        \\    "p1": {
        \\      "model": "p1-model",
        \\      "base_url": "https://p1.example.com",
        \\      "api_key": "p1-key",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "p1"
        \\}
    ;
    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const profiles = try profilesMap(&doc);
    if (!profiles.contains("p1")) {
        std.debug.print("legacy config's `p1` profile missing from GET: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("p1", doc.str("active_profile") orelse {
        std.debug.print("GET has no `active_profile`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

// ============================================================================
// Test 4: PUT live-reload succeeds on a profile-only config
// ============================================================================

// The PUT handler live-reloads LlmConfig from disk after saving. On a
// profile-only config the reload must SUCCEED (backfill provides the
// credentials validate() requires) — no degraded error body.
test "put_live_reload_succeeds_on_profile_only_config" {
    try harness.requirePabrikBin(io, gpa);

    const seed =
        \\{
        \\  "profiles_models": {
        \\    "solo": {
        \\      "model": "solo-model",
        \\      "base_url": "http://127.0.0.1:1",
        \\      "api_key": "solo-key",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "solo"
        \\}
    ;
    var h = try bootSeeded(seed);
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .PUT, "/api/config/pabrik", .{
            .json_body = "{\"retry_delay_ms\":250}",
            .expect = &.{200},
        });
        defer r.deinit();

        // Python: `body.get("error", "")` then `"failed" not in err.lower()`.
        // A 200 body carrying "Config saved to disk but ... failed ..." is
        // exactly the degraded case the test exists to catch.
        var doc = try r.json();
        defer doc.deinit();
        const err = doc.str("error") orelse "";
        const lowered = try gpa.alloc(u8, err.len);
        defer gpa.free(lowered);
        _ = std.ascii.lowerString(lowered, err);
        if (std.mem.indexOf(u8, lowered, "failed") != null) {
            std.debug.print("PUT live-reload degraded on a profile-only config: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // And the value landed on disk.
    var disk = try readDiskConfig(h.temp_dir);
    defer disk.deinit();
    try testing.expectEqual(@as(i64, 250), disk.doc.int("retry_delay_ms") orelse {
        std.debug.print("config.json has no integer `retry_delay_ms`: {s}\n", .{disk.bytes});
        return error.TestUnexpectedResult;
    });
}

// The helpers are referenced so their bodies are type-checked; an
// unreferenced function is never analysed, which is where a stdlib rename
// would hide.
comptime {
    _ = bootSeeded;
    _ = readDiskConfig;
    _ = platformConfigFile;
    _ = profilesMap;
    _ = strField;
    _ = expectNoKeysAtRoot;
}
