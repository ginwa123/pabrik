// Wire tests for the data the `list_sub_agent` agent tool reads. Zig port of
// `tests/functional/list_sub_agent_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// A prompt long enough that a truncating implementation would be
// obvious (>80 chars), with a distinct tail the assertions look for.
const LONG_PROMPT =
    "You are a strict code reviewer with deep expertise in systems programming, " ++
    "testing, refactoring, and mentoring junior engineers across many languages. " ++
    "Always explain the why behind every finding.";

// A prompt containing the CDATA terminator the tool must split on the
// wire (`]]><![CDATA[>`). Seeded here so the round-trip proves the exact
// bytes the splitter consumes survive config persistence verbatim.
const SPLIT_PROMPT = "First half ]]> second half with <tags> & \"quotes\".";

/// The marker secrets test 4 seeds, and asserts stay confined to their
/// own two keys.
const SECRET_KEY = "sk-live-secret-marker-xyz";
const SECRET_HOST = "secret-host-marker-xyz";

// ============================================================================
// Seed rows
// ============================================================================

/// One `sub_agents` row as it goes on the wire.
const AgentRow = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    url_style: []const u8,
    api_key: []const u8,
    system_prompt: []const u8,
    max_capacity_tokens: ?i64 = null,
    compaction_threshold_percent: ?i64 = null,
    thinking_budget_tokens: ?i64 = null,
    reasoning_effort: ?[]const u8 = null,
};

const STRINGIFY_OPTS: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

fn tunedAgent() AgentRow {
    return .{
        .name = "coder",
        .model = "gpt-4o",
        .base_url = "https://api.openai.com/v1",
        .thinking = "on",
        .temperature = "0.2",
        .url_style = "openai",
        .api_key = "coder-key-not-real",
        .system_prompt = LONG_PROMPT,
        .max_capacity_tokens = 128000,
        .compaction_threshold_percent = 80,
        .reasoning_effort = "high",
    };
}

/// All-null optionals: mirrors the tool's "sparse row" unit fixture. Omitted
/// keys must round-trip as absent-or-null (never invented defaults), because
/// the tool treats absent tags as "inherits the profile default".
fn sparseAgent() AgentRow {
    return .{
        .name = "helper",
        .model = "",
        .base_url = "",
        .thinking = "",
        .temperature = "",
        .url_style = "",
        .api_key = "",
        .system_prompt = SPLIT_PROMPT,
    };
}

// ============================================================================
// Helpers
// ============================================================================

/// `PUT /api/config/pabrik` with the object-map profile shape, seeding
/// `sub_agents` for `profile`. Python `_put_profile`.
fn putProfile(h: *Harness, profile: []const u8, sub_agents_json: []const u8) !void {
    const body = try std.fmt.allocPrint(gpa,
        \\{{"profiles":{{"{s}":{{"model":"stub-model","base_url":"http://127.0.0.1:1","api_key":"stub-key-not-real","url_style":"openai","sub_agents":{s}}}}}}}
    , .{ profile, sub_agents_json });
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{
        .json_body = body,
        .expect = &.{200},
    });
    defer r.deinit();
}

/// `GET /api/config/pabrik` → the whole body. Owned (a `harness.Json`
/// aliases the response body, so it may not be returned from a helper).
fn getConfigBody(h: *Harness) ![]u8 {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Parse owned bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `profiles[profile].get("sub_agents")` as a raw `Value`. `.null` stands for
/// BOTH "key absent" and "explicit JSON null", which is exactly what Python's
/// `... .get("sub_agents") or []` collapsed.
fn profileSubAgents(doc: *const harness.Json, profile: []const u8, raw: []const u8) !std.json.Value {
    if (doc.get("sub_agents")) |v| switch (v) {
        .null => {},
        else => {
            std.debug.print(
                "top-level sub_agents must stay null (per-profile only), got: {s}\n",
                .{raw},
            );
            return error.TestUnexpectedResult;
        },
    };

    const profiles = doc.object("profiles") orelse {
        std.debug.print("config body has no `profiles` object: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    const entry = profiles.get(profile) orelse {
        std.debug.print(
            "profile `{s}` missing from the response: [{s}]\n",
            .{ profile, try renderProfileKeys(profiles) },
        );
        return error.TestUnexpectedResult;
    };
    const entry_obj = switch (entry) {
        .object => |o| o,
        else => {
            std.debug.print("profile `{s}` is not an object: {s}\n", .{ profile, raw });
            return error.TestUnexpectedResult;
        },
    };
    return entry_obj.get("sub_agents") orelse .null;
}

/// Comma-joined, sorted profile names — Python's `sorted(profiles)`.
fn renderProfileKeys(profiles: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = profiles.iterator();
    while (it.next()) |kv| try keys.append(gpa, kv.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", keys.items);
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Python `obj.get(key) == "want"` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent\n", .{ ctx, key });
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

/// Python `obj.get(key) == n` for a numeric field. Accepts an integer
/// OR a float payload, because Python's `==` did (`128000 == 128000.0`).
fn expectNumber(obj: std.json.ObjectMap, key: []const u8, want: f64, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => {
            std.debug.print("{s}: `{s}` is not a number\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {d}, expected {d}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `obj.get(key) is None` — the key is ABSENT or explicitly JSON null.
/// Anything else (number, string, `0`, `""`) is the regression this guards: a
/// stored default would make the tool emit a phantom tag.
fn expectAbsentOrNull(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse return;
    switch (v) {
        .null => return,
        else => {
            std.debug.print("{s}: `{s}` gained a default: {any}\n", .{ ctx, key, v });
            return error.TestUnexpectedResult;
        },
    }
}

/// Python `assert not isinstance(row.get(key), str)`.
fn expectNotString(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse return;
    switch (v) {
        .string => {
            std.debug.print("{s}: numeric knob `{s}` unexpectedly a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
        else => return,
    }
}

// ============================================================================
// Tests
// ============================================================================

// Two seeded rows come back with the exact fields the tool renders.
test "populated_profile_round_trips_tool_inputs_verbatim" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const seeded = [_]AgentRow{ tunedAgent(), sparseAgent() };
    const seeded_json = try std.json.Stringify.valueAlloc(gpa, seeded, STRINGIFY_OPTS);
    defer gpa.free(seeded_json);
    try putProfile(&h, "stub", seeded_json);

    const raw = try getConfigBody(&h);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const agents = switch (try profileSubAgents(&doc, "stub", raw)) {
        .array => |a| a,
        else => {
            std.debug.print("expected `sub_agents` to be an array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    if (agents.items.len != 2) {
        std.debug.print("expected 2 sub-agent rows, got {d}: {s}\n", .{ agents.items.len, raw });
        return error.TestUnexpectedResult;
    }

    // `[a.get("name") for a in agents] == ["coder", "helper"]` — order is
    // the render order, so it is asserted positionally.
    const coder = switch (agents.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try expectStr(coder, "name", "coder", "row 0");
    const helper = switch (agents.items[1]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try expectStr(helper, "name", "helper", "row 1");

    try expectStr(coder, "model", "gpt-4o", "row 0");
    try expectStr(coder, "thinking", "on", "row 0");
    try expectStr(coder, "temperature", "0.2", "row 0");
    try expectStr(coder, "url_style", "openai", "row 0");
    try expectNumber(coder, "max_capacity_tokens", 128000, "row 0");
    try expectNumber(coder, "compaction_threshold_percent", 80, "row 0");
    try expectStr(coder, "reasoning_effort", "high", "row 0");

    // Full prompt verbatim: head, middle, AND tail (a truncating
    // implementation would drop the tail).
    const prompt = coder.get("system_prompt") orelse {
        std.debug.print("row 0: `system_prompt` is absent: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    const prompt_str = switch (prompt) {
        .string => |x| x,
        else => {
            std.debug.print("row 0: `system_prompt` is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, prompt_str, LONG_PROMPT)) {
        std.debug.print(
            "row 0: `system_prompt` did not round-trip verbatim.\n  want: {s}\n  got:  {s}\n",
            .{ LONG_PROMPT, prompt_str },
        );
        return error.TestUnexpectedResult;
    }
    if (prompt_str.len <= 80) {
        std.debug.print("row 0: prompt is {d} chars; the fixture must exceed 80\n", .{prompt_str.len});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, prompt_str, "the why behind every finding.") == null) {
        std.debug.print("row 0: prompt lost its tail: {s}\n", .{prompt_str});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, prompt_str, "...") != null) {
        std.debug.print("truncation marker inside round-tripped prompt: {s}\n", .{prompt_str});
        return error.TestUnexpectedResult;
    }
}

// Omitted tuning knobs must not gain invented defaults in storage.
test "sparse_row_null_optionals_stay_absent_or_null" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const seeded = [_]AgentRow{ tunedAgent(), sparseAgent() };
    const seeded_json = try std.json.Stringify.valueAlloc(gpa, seeded, STRINGIFY_OPTS);
    defer gpa.free(seeded_json);
    try putProfile(&h, "stub", seeded_json);

    const raw = try getConfigBody(&h);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const agents = switch (try profileSubAgents(&doc, "stub", raw)) {
        .array => |a| a,
        else => {
            std.debug.print("expected `sub_agents` to be an array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };

    // `next(a for a in agents if a.get("name") == "helper")` — a search,
    // not an index, so the port searches too.
    var helper: ?std.json.ObjectMap = null;
    for (agents.items) |entry| {
        const o = switch (entry) {
            .object => |x| x,
            else => continue,
        };
        const name = switch (o.get("name") orelse continue) {
            .string => |x| x,
            else => continue,
        };
        if (std.mem.eql(u8, name, "helper")) {
            helper = o;
            break;
        }
    }
    const row = helper orelse {
        std.debug.print("sparse row `helper` missing from: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };

    for ([_][]const u8{
        "max_capacity_tokens",
        "compaction_threshold_percent",
        "thinking_budget_tokens",
        "reasoning_effort",
    }) |key| {
        try expectAbsentOrNull(row, key, "sparse row");
    }

    // The CDATA-terminator bytes survive persistence verbatim so the
    // tool's `]]><![CDATA[>` splitter sees the exact input it handles in
    // its unit tests.
    try expectStr(row, "system_prompt", SPLIT_PROMPT, "sparse row");
}

// A profile with no subagents round-trips zero rows, no error. This is the
// storage precondition for the tool's `<empty/>` branch (empty list after
// seeding nothing).
test "empty_profile_yields_no_rows" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const seeded_json = try std.json.Stringify.valueAlloc(gpa, [_]AgentRow{}, STRINGIFY_OPTS);
    defer gpa.free(seeded_json);
    try putProfile(&h, "stub", seeded_json);

    const raw = try getConfigBody(&h);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    // Python: `return profiles[profile].get("sub_agents") or []` then
    // `assert agents == []` — so absent, null, and an empty array all
    // pass. Anything with LENGTH, or a non-array, does not.
    switch (try profileSubAgents(&doc, "stub", raw)) {
        .null => return,
        .array => |a| {
            if (a.items.len != 0) {
                std.debug.print("expected zero sub-agent rows, got {d}: {s}\n", .{ a.items.len, raw });
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("`sub_agents` is neither null nor an array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    }
}

// Secret VALUES are confined to `api_key`/`base_url` keys only. Honesty note:
// `GET /api/config/pabrik` is the settings API and legitimately returns
// `api_key`/`base_url` (the settings UI needs them — cf.
test "secrets_confined_to_their_own_keys" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // Python `dict(TUNED_AGENT, api_key=..., base_url=...)`.
    var agent = tunedAgent();
    agent.api_key = SECRET_KEY;
    agent.base_url = try std.fmt.allocPrint(gpa, "https://{s}.example/v1", .{SECRET_HOST});
    defer gpa.free(agent.base_url);

    const seeded_json = try std.json.Stringify.valueAlloc(gpa, [_]AgentRow{agent}, STRINGIFY_OPTS);
    defer gpa.free(seeded_json);
    try putProfile(&h, "stub", seeded_json);

    const raw = try getConfigBody(&h);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const agents = switch (try profileSubAgents(&doc, "stub", raw)) {
        .array => |a| a,
        else => {
            std.debug.print("expected `sub_agents` to be an array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    if (agents.items.len != 1) {
        std.debug.print("expected 1 sub-agent row, got {d}: {s}\n", .{ agents.items.len, raw });
        return error.TestUnexpectedResult;
    }
    const row = switch (agents.items[0]) {
        .object => |o| o,
        else => {
            std.debug.print("sub-agent row is not an object: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };

    // Seeding worked: the secrets are present under their own keys.
    try expectStr(row, "api_key", SECRET_KEY, "row 0");
    try expectStr(row, "base_url", agent.base_url, "row 0");

    // ... and absent from every field the tool renders into the envelope.
    for ([_][]const u8{
        "name",
        "model",
        "url_style",
        "thinking",
        "temperature",
        "reasoning_effort",
        "system_prompt",
    }) |key| {
        const v = row.get(key) orelse {
            std.debug.print("row 0: `{s}` is absent; expected a string\n", .{key});
            return error.TestUnexpectedResult;
        };
        const s = switch (v) {
            .string => |x| x,
            else => {
                std.debug.print("row 0: `{s}` is not a string\n", .{key});
                return error.TestUnexpectedResult;
            },
        };
        if (std.mem.indexOf(u8, s, SECRET_KEY) != null) {
            std.debug.print("secret in `{s}`: {s}\n", .{ key, s });
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, s, SECRET_HOST) != null) {
            std.debug.print("secret host in `{s}`: {s}\n", .{ key, s });
            return error.TestUnexpectedResult;
        }
    }

    for ([_][]const u8{
        "max_capacity_tokens",
        "compaction_threshold_percent",
        "thinking_budget_tokens",
    }) |key| {
        try expectNotString(row, key, "row 0");
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = AgentRow;
    _ = tunedAgent;
    _ = sparseAgent;
    _ = putProfile;
    _ = getConfigBody;
    _ = parseJson;
    _ = profileSubAgents;
    _ = renderProfileKeys;
    _ = expectStr;
    _ = expectNumber;
    _ = expectAbsentOrNull;
    _ = expectNotString;
}
