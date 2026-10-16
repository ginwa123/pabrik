// Functional tests for pabrik config (Tier 1.7). Zig port of
// `tests/functional/pabrik_config_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Boot with the harness-installed `stub` profile already on disk.
///
/// This is Python's `config_harness` fixture: `stub_llm_profile=True`.
fn bootConfig() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

/// `GET /api/config/pabrik` → the parsed body. Caller `deinit`s.
fn getConfig(h: *Harness) !harness.Json {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return r.json();
}

/// `PUT /api/config/pabrik` with an explicit expected status. Caller `deinit`s.
fn putConfig(h: *Harness, body: []const u8, expect: []const u16) !harness.Response {
    return h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = expect });
}

/// `DELETE /api/config/pabrik/profiles/<name>`. Caller `deinit`s.
fn deleteProfile(h: *Harness, name: []const u8, expect: []const u16) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/config/pabrik/profiles/{s}", .{name});
    defer gpa.free(path);
    return h.http(io, .DELETE, path, .{ .expect = expect });
}

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

/// The profile entry `name` inside a `profiles` map, or a named failure.
fn profile(map: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (map.get(name) orelse {
        std.debug.print("profiles has no '{s}' entry\n", .{name});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => {
            std.debug.print("profiles['{s}'] is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// The string at `key` of a JSON object, or a named failure.
fn strField(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (o.get(key) orelse {
        std.debug.print("missing `{s}` in a profile object\n", .{key});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
}

/// Is `active_profile` explicitly JSON `null` on this response? Python:
/// `after.get("active_profile") is None`, which is true for BOTH an absent
/// key and a `null` value.
fn activeProfileIsAbsent(doc: *const harness.Json) bool {
    const v = doc.get("active_profile") orelse return true;
    return v == .null;
}

// ============================================================================
// Test 1: GET returns the harness-installed stub profile
// ============================================================================

// GET /api/config/pabrik → 200 with `profiles_models` map that contains the
// harness-installed `stub` profile.
test "get_pabrik_config_returns_stub_profile" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = try getConfig(&h);
    defer doc.deinit();

    const profiles = try profilesMap(&doc);
    const stub = try profile(profiles, "stub");
    try testing.expectEqualStrings("stub-model", try strField(stub, "model"));
    try testing.expectEqualStrings("http://127.0.0.1:1", try strField(stub, "base_url"));
}

// ============================================================================
// Test 2: PUT round-trips a new profile
// ============================================================================

// PUT a fresh `profiles_models` object → GET returns the new profile.
// Existing fields (stub) are replaced wholesale by the on-disk PUT body
// (PUT is a full replace).
test "put_pabrik_config_round_trips_a_new_profile" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{
        \\  "api_endpoint": "https://api.example.com",
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "url_style": "openai",
        \\  "profiles": {
        \\    "new-profile": {
        \\      "model": "new-model",
        \\      "base_url": "https://new.example.com",
        \\      "api_key": "new-key",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "new-profile"
        \\}
    ;
    {
        var r = try putConfig(&h, put_body, &.{200});
        defer r.deinit();
    }

    var doc = try getConfig(&h);
    defer doc.deinit();

    const profiles = try profilesMap(&doc);
    const np = try profile(profiles, "new-profile");
    try testing.expectEqualStrings("new-model", try strField(np, "model"));
    try testing.expectEqualStrings("new-profile", doc.str("active_profile") orelse {
        std.debug.print("GET after PUT has no `active_profile`\n", .{});
        return error.TestUnexpectedResult;
    });
}

// ============================================================================
// Test 3: a malformed JSON body is a 400 naming the problem
// ============================================================================

// PUT with `{not json}` → 400 'Invalid JSON input'. Python reached for
// `urllib.request` here because its helper took a dict.
test "put_pabrik_config_rejects_invalid_json" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = "{not json}",
        .assert_status = false,
    });
    defer r.deinit();

    if (r.status != 400) {
        std.debug.print("expected 400 for a malformed JSON body, got {d}: {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    // `pabrik_config_put.zig` answers `{"error":"Invalid JSON input"}`.
    if (std.mem.indexOf(u8, r.body, "Invalid JSON") == null) {
        std.debug.print("400 should mention 'Invalid JSON', got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: PUT {} preserves what is on disk
// ============================================================================

// PUT `{}` → 200; an empty body has all fields defaulted, which means the
// existing on-disk config is read first and the empty PUT's defaulted fields
// (api_endpoint='', model='', etc.) are applied as 'no change' (the apply
test "put_pabrik_config_empty_body_preserves_existing" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try putConfig(&h, "{}", &.{200});
        defer r.deinit();
    }

    var doc = try getConfig(&h);
    defer doc.deinit();

    // The stub profile is still present (PUT {} doesn't wipe it).
    const profiles = try profilesMap(&doc);
    const stub = try profile(profiles, "stub");
    try testing.expectEqualStrings("stub-model", try strField(stub, "model"));
}

// ============================================================================
// Test 5: DELETE /profiles/stub removes it
// ============================================================================

// DELETE /api/config/pabrik/profiles/stub → 200; GET no longer contains the
// `stub` profile.
test "delete_profile_removes_it_from_list" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try deleteProfile(&h, "stub", &.{200});
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("DELETE response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqualStrings("stub", doc.str("profile_name") orelse {
            std.debug.print("DELETE response has no string `profile_name`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    // GET confirms the profile is gone.
    var after = try getConfig(&h);
    defer after.deinit();
    const profiles = try profilesMap(&after);
    if (profiles.contains("stub")) {
        std.debug.print("deleted profile 'stub' is still in profiles\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5b: deleting one profile keeps every OTHER key of the config
// ============================================================================

// DELETE /api/config/pabrik/profiles/<name> rewrites config.json. It must take
// the profile and nothing else: the other profiles, the MCP servers, the tool
// checklist, the web-search provider and the General settings all stay.
test "delete_profile_keeps_the_rest_of_the_config" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{
        \\  "profiles": {
        \\    "todelete": {"model": "model-a", "base_url": "https://a.example.com", "api_key": "k-a"},
        \\    "keeper": {"model": "model-b", "base_url": "https://b.example.com", "api_key": "k-b"}
        \\  },
        \\  "active_profile": "todelete",
        \\  "mcp_servers": {"graphify": {"command": "/usr/bin/python3", "args": ["-m", "graphify.serve"]}},
        \\  "tools": ["glob", "search"],
        \\  "skill_evals": {"enabled": true, "max_skills_per_run": 5},
        \\  "web_search": {"brave": {"url": "https://api.search.brave.com", "key": "SENTINEL_SEARCH_KEY",
        \\   "curl": "https://api.search.brave.com/res/v1/web/search?q=PLACEHOLDER -H \"X-Subscription-Token: {key}\""}},
        \\  "notify_on_complete": true,
        \\  "retry_delay_ms": 4242
        \\}
    ;
    {
        var r = try putConfig(&h, put_body, &.{200});
        defer r.deinit();
    }

    {
        var r = try deleteProfile(&h, "todelete", &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("DELETE response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqual(true, doc.boolean("active_profile_was_cleared") orelse {
            std.debug.print("`todelete` was the active profile but the flag is wrong: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    var doc = try getConfig(&h);
    defer doc.deinit();

    const profiles = try profilesMap(&doc);
    if (profiles.contains("todelete")) {
        std.debug.print("deleted profile 'todelete' is still in profiles\n", .{});
        return error.TestUnexpectedResult;
    }
    const keeper = try profile(profiles, "keeper");
    try testing.expectEqualStrings("model-b", try strField(keeper, "model"));
    try testing.expectEqualStrings("k-b", try strField(keeper, "api_key"));

    if (doc.get("mcp_servers") == null) {
        std.debug.print("the delete dropped mcp_servers\n", .{});
        return error.TestUnexpectedResult;
    }
    const tools = doc.array("tools") orelse {
        std.debug.print("the delete dropped the tool checklist\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 2), tools.items.len);
    const evals = doc.object("skill_evals") orelse {
        std.debug.print("the delete dropped skill_evals\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(true, evals.get("enabled").?.bool);
    // The provider block still ships (its `key` is masked on the wire, so the
    // section's presence is the strongest available assertion here).
    if (doc.get("web_search") == null) {
        std.debug.print("the delete dropped web_search\n", .{});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(true, doc.boolean("notify_on_complete") orelse {
        std.debug.print("the delete dropped notify_on_complete\n", .{});
        return error.TestUnexpectedResult;
    });
    try testing.expectEqual(@as(i64, 4242), doc.int("retry_delay_ms") orelse {
        std.debug.print("the delete dropped retry_delay_ms\n", .{});
        return error.TestUnexpectedResult;
    });
    if (!activeProfileIsAbsent(&doc)) {
        std.debug.print("active_profile should be null after deleting it\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: DELETE of an unknown profile is a 404 with a message
// ============================================================================

// DELETE /api/config/pabrik/profiles/no-such-profile → 404. The handler
// returns `{success: false, profile_name, error_message}` with HTTP 404 when
// the profile is not found.
test "delete_profile_404_for_unknown_name" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try deleteProfile(&h, "no-such-profile", &.{404});
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(false, doc.boolean("success") orelse {
        std.debug.print("404 response has no bool `success`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
    try testing.expectEqualStrings("no-such-profile", doc.str("profile_name") orelse {
        std.debug.print("404 response has no string `profile_name`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
    if (doc.get("error_message") == null) {
        std.debug.print("404 should include an error_message\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: deleting one profile leaves the others alone
// ============================================================================

// PUT {profiles: {A: {...}, B: {...}}}, DELETE A → B survives. Tests that
// DELETE is scoped to a single name and the rest of the profiles_models map
// is preserved.
test "delete_one_profile_does_not_touch_others" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{
        \\  "api_endpoint": "https://api.example.com",
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "url_style": "openai",
        \\  "profiles": {
        \\    "A": {
        \\      "model": "model-a",
        \\      "base_url": "https://a.example.com",
        \\      "api_key": "k-a",
        \\      "url_style": "openai"
        \\    },
        \\    "B": {
        \\      "model": "model-b",
        \\      "base_url": "https://b.example.com",
        \\      "api_key": "k-b",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "B"
        \\}
    ;
    {
        var r = try putConfig(&h, put_body, &.{200});
        defer r.deinit();
    }

    // DELETE only A.
    {
        var r = try deleteProfile(&h, "A", &.{200});
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("DELETE response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqualStrings("A", doc.str("profile_name") orelse {
            std.debug.print("DELETE response has no string `profile_name`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        // active_profile is B (not A), so nothing was cleared.
        try testing.expectEqual(false, doc.boolean("active_profile_was_cleared") orelse {
            std.debug.print("DELETE response has no bool `active_profile_was_cleared`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    // GET confirms: A gone, B survives.
    var after = try getConfig(&h);
    defer after.deinit();
    const profiles = try profilesMap(&after);
    if (profiles.contains("A")) {
        std.debug.print("A should be deleted\n", .{});
        return error.TestUnexpectedResult;
    }
    const b = try profile(profiles, "B");
    try testing.expectEqualStrings("model-b", try strField(b, "model"));
}

// ============================================================================
// Test 8: deleting the active profile clears `active_profile`
// ============================================================================

// PUT {active_profile: 'target'}, DELETE /profiles/target →
// `active_profile_was_cleared: true` and the field is null on GET.
test "delete_active_profile_clears_active_profile_field" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootConfig();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{
        \\  "api_endpoint": "https://api.example.com",
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "url_style": "openai",
        \\  "profiles": {
        \\    "target": {
        \\      "model": "target-model",
        \\      "base_url": "https://target.example.com",
        \\      "api_key": "k-t",
        \\      "url_style": "openai"
        \\    }
        \\  },
        \\  "active_profile": "target"
        \\}
    ;
    {
        var r = try putConfig(&h, put_body, &.{200});
        defer r.deinit();
    }

    // DELETE the active profile.
    {
        var r = try deleteProfile(&h, "target", &.{200});
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("DELETE response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqual(true, doc.boolean("active_profile_was_cleared") orelse {
            std.debug.print("DELETE response has no bool `active_profile_was_cleared`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    // GET confirms: active_profile is null.
    var after = try getConfig(&h);
    defer after.deinit();
    if (!activeProfileIsAbsent(&after)) {
        std.debug.print("active_profile should be null after deleting it, got '{s}'\n", .{
            after.str("active_profile") orelse "<non-string>",
        });
        return error.TestUnexpectedResult;
    }
}

// The helpers are referenced so their bodies are type-checked; an
// unreferenced function is never analysed, which is where a stdlib rename
// would hide.
comptime {
    _ = bootConfig;
    _ = getConfig;
    _ = putConfig;
    _ = deleteProfile;
    _ = profilesMap;
    _ = profile;
    _ = strField;
    _ = activeProfileIsAbsent;
}
