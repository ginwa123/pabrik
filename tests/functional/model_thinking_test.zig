// Functional tests for the model-thinking knobs (plan
// 2026-08-23-model-thinking).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Fixture
// ============================================================================

/// Python `config_harness` fixture: boot with `stub_llm_profile=True` so
/// the harness pre-installs a `stub` profile.
fn bootConfigHarness() !Harness {
    return Harness.boot(io, gpa, .{ .stub_llm_profile = true });
}

// ============================================================================
// HTTP + assertion helpers
// ============================================================================

/// `PUT /api/config/pabrik` with the given JSON body, status NOT
/// asserted. Owned body; the caller frees the response.
fn putConfig(h: *Harness, body: []const u8) !harness.Response {
    return h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = body,
        .assert_status = false,
    });
}

/// `GET /api/config/pabrik` → the whole body as OWNED bytes.
fn getConfigBody(h: *Harness) ![]u8 {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

fn rootObj(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn renderKeys(obj: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", keys.items);
}

/// Python `assert alpha.get("thinking_budget_tokens") is None` — true
/// for an explicit `null` AND for an absent key (Python's `dict.get`
/// returns `None` for both, and the wire does not distinguish them here).
fn expectNullOrAbsent(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse return;
    switch (v) {
        .null => {},
        else => {
            std.debug.print("{s}: `{s}` should be null/absent, got a value\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    }
}

/// Python `assert alpha.get("thinking_budget_tokens") == 4096`.
fn expectInt(obj: std.json.ObjectMap, key: []const u8, want: i64, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        const rendered = try renderKeys(obj);
        defer gpa.free(rendered);
        std.debug.print("{s}: missing `{s}`; keys = [{s}]\n", .{ ctx, key, rendered });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .integer => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not an integer\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {d}, expected {d}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert alpha.get("reasoning_effort") == "high"`.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        const rendered = try renderKeys(obj);
        defer gpa.free(rendered);
        std.debug.print("{s}: missing `{s}`; keys = [{s}]\n", .{ ctx, key, rendered });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Assert a PUT returned 200, printing the body when it did not — the
/// handler's error text is the only thing that distinguishes the three
/// validators (`InvalidThinkingBudgetTokens`, `InvalidReasoningEffort`, and
fn expectPutOk(r: *const harness.Response, ctx: []const u8) !void {
    if (r.status == 200) return;
    const excerpt: []const u8 = if (r.body.len > 400) r.body[0..400] else r.body;
    std.debug.print("{s}: expected 200, got {d}: {s}\n", .{ ctx, r.status, excerpt });
    return error.TestUnexpectedResult;
}

/// The `profiles` OBJECT of a config GET, or null when absent / not an
/// object — Python's `r.get("profiles") or {}`.
fn profilesMap(doc: *const harness.Json) ?std.json.ObjectMap {
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => return null,
    };
    const v = root.get("profiles") orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// Parse a `GET /api/config/pabrik` body into an OWNED, SELF-CONTAINED
/// document the caller `deinit`s.
fn parseConfigDoc(config_body: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        config_body,
        // `.alloc_always` so no string borrows `config_body`: with the
        // default `.alloc_if_needed` an unescaped value points INTO the
        // caller's buffer rather than into this document's own arena.
        .{ .allocate = .alloc_always },
    ) };
}

/// The named profile object out of a `GET /api/config/pabrik` document.
/// Python: `profiles = r.get("profiles") or {}` then `profiles["alpha"]`.
fn profileObject(doc: *const harness.Json, name: []const u8) !std.json.ObjectMap {
    const profiles = profilesMap(doc) orelse {
        std.debug.print("PUT'd profile missing from GET: no `profiles` object\n", .{});
        return error.TestUnexpectedResult;
    };
    const p = profiles.get(name) orelse {
        const rendered = try renderKeys(profiles);
        defer gpa.free(rendered);
        std.debug.print("PUT'd profile missing from GET: profiles = [{s}]\n", .{rendered});
        return error.TestUnexpectedResult;
    };
    return switch (p) {
        .object => |o| o,
        else => {
            std.debug.print("profile {s} is not an object\n", .{name});
            return error.TestUnexpectedResult;
        },
    };
}

/// The profile map out of a config GET, as a sorted CSV of names.
/// Owned; used for the "all 5 user profiles survive" assertion.
fn profileNamesCsv(config_body: []const u8) ![]u8 {
    var doc = try parseConfigDoc(config_body);
    defer doc.deinit();
    const profiles = profilesMap(&doc) orelse return std.fmt.allocPrint(gpa, "", .{});
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = profiles.iterator();
    while (it.next()) |entry| try names.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", names.items);
}

/// `body` must mention `needle` (case-insensitive) — Python's
/// `"x" in body.lower()`.
fn expectBodyMentions(body: []const u8, needles: []const []const u8, ctx: []const u8) !void {
    for (needles) |needle| {
        if (containsIgnoreCase(body, needle)) return;
    }
    const excerpt: []const u8 = if (body.len > 200) body[0..200] else body;
    std.debug.print(
        "{s}: error body should mention the bad field; got: {s}\n",
        .{ ctx, excerpt },
    );
    return error.TestUnexpectedResult;
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (haystack.len < needle_lower.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle_lower.len], needle_lower)) return true;
    }
    return false;
}

comptime {
    // Body-analysis barrier: an unreferenced fn body is never
    // type-checked, so a stdlib rename inside one hides until a caller
    // appears.
    _ = bootConfigHarness;
    _ = expectPutOk;
    _ = putConfig;
    _ = getConfigBody;
    _ = profilesMap;
    _ = parseConfigDoc;
    _ = profileObject;
    _ = profileNamesCsv;
    _ = expectBodyMentions;
}

// ============================================================================
// Test 1: PUT round-trips thinking_budget_tokens + reasoning_effort
// ============================================================================

// PUT a profile with both new knobs -> GET returns the same values. This is
// the core "the wire shape works" test for the feature. Without it, a
// frontend save would silently drop the user's configuration.
test "profile_thinking_budget_and_effort_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"claude-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "thinking":"on","temperature":"auto","url_style":"anthropic",
        \\ "thinking_budget_tokens":4096,"reasoning_effort":"high"}}}
    ;
    {
        var r = try putConfig(&h, put_body);
        defer r.deinit();
        try expectPutOk(&r, "PUT /api/config/pabrik");
    }

    // GET returns the saved profile with both fields.
    const body = try getConfigBody(&h);
    defer gpa.free(body);
    var doc = try parseConfigDoc(body);
    defer doc.deinit();
    const alpha_obj = try profileObject(&doc, "alpha");
    try expectInt(alpha_obj, "thinking_budget_tokens", 4096, "profile alpha");
    try expectStr(alpha_obj, "reasoning_effort", "high", "profile alpha");
}

// ============================================================================
// Test 2: PUT rejects thinking_budget_tokens=0
// ============================================================================

// thinking_budget_tokens=0 violates Anthropic's 1024 floor. Backend
// rejects with HTTP 400 and an error body mentioning the field name.
test "profile_thinking_budget_zero_rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"claude-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "url_style":"anthropic","thinking_budget_tokens":0}}}
    ;
    // We don't pin the exact error code/message — the handler returns
    // error.InvalidThinkingBudgetTokens which the HTTP layer maps to 400 with
    // a body.
    var r = try putConfig(&h, put_body);
    defer r.deinit();
    if (r.status != 400) {
        const excerpt: []const u8 = if (r.body.len > 200) r.body[0..200] else r.body;
        std.debug.print(
            "Expected 400 for thinking_budget_tokens=0, got {d}: {s}\n",
            .{ r.status, excerpt },
        );
        return error.TestUnexpectedResult;
    }
    try expectBodyMentions(r.body, &.{ "thinking_budget", "invalidthinking" }, "thinking_budget_tokens=0");
}

// ============================================================================
// Test 3: PUT rejects thinking_budget_tokens > 2_000_000
// ============================================================================

// thinking_budget_tokens > 2_000_000 would violate Anthropic's
// strict-less-than-max_tokens rule for any reasonable max_tokens.
// Backend rejects with HTTP 400.
test "profile_thinking_budget_too_large_rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"claude-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "url_style":"anthropic","thinking_budget_tokens":3000000}}}
    ;
    var r = try putConfig(&h, put_body);
    defer r.deinit();
    if (r.status != 400) {
        const excerpt: []const u8 = if (r.body.len > 200) r.body[0..200] else r.body;
        std.debug.print(
            "Expected 400 for thinking_budget_tokens=3000000, got {d}: {s}\n",
            .{ r.status, excerpt },
        );
        return error.TestUnexpectedResult;
    }
    try expectBodyMentions(r.body, &.{"thinking_budget"}, "thinking_budget_tokens=3000000");
}

// ============================================================================
// Test 4: PUT rejects garbage reasoning_effort
// ============================================================================

// reasoning_effort outside {low, medium, high, auto} is rejected.
// Backend returns HTTP 400 with InvalidReasoningEffort in the body.
test "profile_reasoning_effort_invalid_value_rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"o1-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "url_style":"openai","reasoning_effort":"super"}}}
    ;
    var r = try putConfig(&h, put_body);
    defer r.deinit();
    if (r.status != 400) {
        const excerpt: []const u8 = if (r.body.len > 200) r.body[0..200] else r.body;
        std.debug.print(
            "Expected 400 for reasoning_effort=\"super\", got {d}: {s}\n",
            .{ r.status, excerpt },
        );
        return error.TestUnexpectedResult;
    }
    try expectBodyMentions(r.body, &.{ "reasoning_effort", "invalidreasoning" }, "reasoning_effort=\"super\"");
}

// ============================================================================
// Test 5: omitted fields default to null on round-trip
// ============================================================================

// Backward compatibility: a profile without the new fields must
// parse cleanly with both fields as null (not missing).
test "profile_thinking_knobs_default_to_null_when_omitted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"claude-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "thinking":"auto","temperature":"auto","url_style":"anthropic"}}}
    ;
    {
        var r = try putConfig(&h, put_body);
        defer r.deinit();
        try expectPutOk(&r, "PUT /api/config/pabrik");
    }

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    var doc = try parseConfigDoc(body);
    defer doc.deinit();
    const alpha_obj = try profileObject(&doc, "alpha");
    // On the wire, the field IS present (we default to null) so the
    // form has something to bind to on the next edit.
    try expectNullOrAbsent(alpha_obj, "thinking_budget_tokens", "profile alpha");
    try expectNullOrAbsent(alpha_obj, "reasoning_effort", "profile alpha");
}

// ============================================================================
// Test 6: explicit JSON null for the new fields is accepted
// ============================================================================

// Single profile with `thinking_budget_tokens: null` (and a valid
// `reasoning_effort` string) round-trips through PUT -> GET. Pre-fix
// this returned 400 InvalidThinkingBudgetTokens.
test "profile_thinking_budget_null_is_accepted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"alpha":{"model":"claude-test","base_url":"https://api.example.com","api_key":"alpha-key",
        \\ "url_style":"anthropic","thinking_budget_tokens":null,"reasoning_effort":"high"}}}
    ;
    {
        var r = try putConfig(&h, put_body);
        defer r.deinit();
        try expectPutOk(&r, "PUT /api/config/pabrik");
    }

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    var doc = try parseConfigDoc(body);
    defer doc.deinit();
    const alpha_obj = try profileObject(&doc, "alpha");
    try expectNullOrAbsent(alpha_obj, "thinking_budget_tokens", "profile alpha");
    try expectStr(alpha_obj, "reasoning_effort", "high", "profile alpha");
}

// Single profile with `reasoning_effort: null` (and a valid
// `thinking_budget_tokens` integer) round-trips through PUT -> GET.
// Pre-fix this returned 400 InvalidReasoningEffort.
test "profile_reasoning_effort_null_is_accepted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{"beta":{"model":"o1-test","base_url":"https://api.example.com","api_key":"beta-key",
        \\ "url_style":"openai","thinking_budget_tokens":4096,"reasoning_effort":null}}}
    ;
    {
        var r = try putConfig(&h, put_body);
        defer r.deinit();
        try expectPutOk(&r, "PUT /api/config/pabrik");
    }

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    var doc = try parseConfigDoc(body);
    defer doc.deinit();
    const beta_obj = try profileObject(&doc, "beta");
    try expectInt(beta_obj, "thinking_budget_tokens", 4096, "profile beta");
    try expectNullOrAbsent(beta_obj, "reasoning_effort", "profile beta");
}

// The user's exact bug case: 5 profiles where most have
// `thinking_budget_tokens: null` (and `reasoning_effort: null`). Only one
// profile sets non-null values.
test "multiple_profiles_with_null_thinking_budget_is_accepted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try bootConfigHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const put_body =
        \\{"api_endpoint":"https://api.example.com","api_key":"test-key","model":"test-model","url_style":"openai",
        \\ "profiles":{
        \\  "p1-nothing":{"model":"m","base_url":"https://x","api_key":"k1","url_style":"openai",
        \\    "thinking_budget_tokens":null,"reasoning_effort":null},
        \\  "p2-just-budget":{"model":"m","base_url":"https://x","api_key":"k2","url_style":"anthropic",
        \\    "thinking_budget_tokens":1024,"reasoning_effort":null},
        \\  "p3-just-effort":{"model":"m","base_url":"https://x","api_key":"k3","url_style":"openai",
        \\    "thinking_budget_tokens":null,"reasoning_effort":"high"},
        \\  "p4-both-set":{"model":"m","base_url":"https://x","api_key":"k4","url_style":"anthropic",
        \\    "thinking_budget_tokens":8192,"reasoning_effort":"medium"},
        \\  "p5-both-null-again":{"model":"m","base_url":"https://x","api_key":"k5","url_style":"openai",
        \\    "thinking_budget_tokens":null,"reasoning_effort":null}}}
    ;
    {
        var r = try putConfig(&h, put_body);
        defer r.deinit();
        try expectPutOk(&r, "PUT /api/config/pabrik");
    }

    // All 5 user-supplied profiles survive the PUT.
    const body = try getConfigBody(&h);
    defer gpa.free(body);

    var doc = try parseConfigDoc(body);
    defer doc.deinit();

    const expected_names = [_][]const u8{
        "p1-nothing", "p2-just-budget", "p3-just-effort", "p4-both-set", "p5-both-null-again",
    };
    {
        const profiles = profilesMap(&doc) orelse {
            std.debug.print("GET /api/config/pabrik carried no `profiles` object: {s}\n", .{body});
            return error.TestUnexpectedResult;
        };
        for (expected_names) |want| {
            if (profiles.get(want) != null) continue;
            const rendered = try profileNamesCsv(body);
            defer gpa.free(rendered);
            std.debug.print("PUT'd profile '{s}' missing from GET; got [{s}]\n", .{ want, rendered });
            return error.TestUnexpectedResult;
        }
    }

    // Spot-check the null fields round-trip.
    {
        const p1_obj = try profileObject(&doc, "p1-nothing");
        try expectNullOrAbsent(p1_obj, "thinking_budget_tokens", "p1-nothing");
        try expectNullOrAbsent(p1_obj, "reasoning_effort", "p1-nothing");
    }
    {
        const p5_obj = try profileObject(&doc, "p5-both-null-again");
        try expectNullOrAbsent(p5_obj, "thinking_budget_tokens", "p5-both-null-again");
        try expectNullOrAbsent(p5_obj, "reasoning_effort", "p5-both-null-again");
    }
    // And the non-null fields round-trip too.
    {
        const p2_obj = try profileObject(&doc, "p2-just-budget");
        try expectInt(p2_obj, "thinking_budget_tokens", 1024, "p2-just-budget");
    }
    {
        const p3_obj = try profileObject(&doc, "p3-just-effort");
        try expectStr(p3_obj, "reasoning_effort", "high", "p3-just-effort");
    }
    {
        const p4_obj = try profileObject(&doc, "p4-both-set");
        try expectInt(p4_obj, "thinking_budget_tokens", 8192, "p4-both-set");
        try expectStr(p4_obj, "reasoning_effort", "medium", "p4-both-set");
    }
}
