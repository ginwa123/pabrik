// Wire tests for the data the `list_agents` agent tool reads: the configured
// agents, as they sit on the wire after a config save.

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

/// A prompt containing the CDATA terminator the tool must split on the
/// wire (`]]><![CDATA[>`). Seeded here so the round-trip proves the exact
/// bytes the splitter consumes survive config persistence verbatim.
const SPLIT_PROMPT = "First half ]]> second half with <tags> & \"quotes\".";

/// The marker secrets test 4 seeds, and asserts stay confined to their
/// own two keys.
const SECRET_KEY = "sk-live-secret-marker-xyz";
const SECRET_HOST = "secret-host-marker-xyz";

// ============================================================================
// Helpers
// ============================================================================

/// `PUT /api/config/pabrik` with the object-map agent shape, seeding one
/// agent whose body is `agent_json`.
fn putAgent(h: *Harness, name: []const u8, agent_json: []const u8) !void {
    const body = try std.fmt.allocPrint(gpa,
        \\{{"profiles":{{"{s}":{s}}}}}
    , .{ name, agent_json });
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

/// `profiles[name]` as an object map.
fn agentObject(doc: *const harness.Json, name: []const u8) !std.json.ObjectMap {
    const profiles = doc.get("profiles") orelse return error.TestUnexpectedResult;
    const obj = switch (profiles) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const entry = obj.get(name) orelse return error.TestUnexpectedResult;
    return switch (entry) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
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

// A seeded agent comes back with the exact fields the tool renders.
test "populated_agent_round_trips_tool_inputs_verbatim" {
    var h = try Harness.init(gpa);
    defer h.deinit();

    const agent_json = try std.fmt.allocPrint(gpa,
        \\{{"model":"gpt-4o","base_url":"https://api.openai.com/v1","thinking":"on","temperature":"0.2","url_style":"openai","api_key":"coder-key-not-real","system_prompt":"{s}","max_capacity_tokens":128000,"compaction_threshold_percent":80,"reasoning_effort":"high"}}
    , .{LONG_PROMPT});
    defer gpa.free(agent_json);
    try putAgent(&h, "coder", agent_json);

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    const doc = try parseJson(body);
    defer doc.deinit();

    const agent = try agentObject(&doc, "coder");
    try expectStr(agent, "model", "gpt-4o", "coder.model");
    try expectStr(agent, "base_url", "https://api.openai.com/v1", "coder.base_url");
    try expectStr(agent, "thinking", "on", "coder.thinking");
    try expectStr(agent, "temperature", "0.2", "coder.temperature");
    try expectStr(agent, "url_style", "openai", "coder.url_style");
    try expectStr(agent, "system_prompt", LONG_PROMPT, "coder.system_prompt");
    try expectNumber(agent, "max_capacity_tokens", 128000, "coder.max_capacity_tokens");
    try expectNumber(agent, "compaction_threshold_percent", 80, "coder.compaction_threshold_percent");
    try expectStr(agent, "reasoning_effort", "high", "coder.reasoning_effort");
}

// All-null optionals: the tool's "sparse agent" fixture. Omitted keys must
// round-trip as absent-or-null (never invented defaults), because the tool
// treats absent tags as "inherits the default".
test "sparse_agent_null_optionals_stay_absent_or_null" {
    var h = try Harness.init(gpa);
    defer h.deinit();

    const agent_json = try std.fmt.allocPrint(gpa,
        \\{{"model":"","base_url":"","thinking":"","temperature":"","url_style":"","api_key":"","system_prompt":"{s}"}}
    , .{SPLIT_PROMPT});
    defer gpa.free(agent_json);
    try putAgent(&h, "helper", agent_json);

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    const doc = try parseJson(body);
    defer doc.deinit();

    const agent = try agentObject(&doc, "helper");
    try expectStr(agent, "system_prompt", SPLIT_PROMPT, "helper.system_prompt");
    try expectAbsentOrNull(agent, "max_capacity_tokens", "helper.max_capacity_tokens");
    try expectAbsentOrNull(agent, "compaction_threshold_percent", "helper.compaction_threshold_percent");
    try expectAbsentOrNull(agent, "thinking_budget_tokens", "helper.thinking_budget_tokens");
    try expectAbsentOrNull(agent, "reasoning_effort", "helper.reasoning_effort");
    try expectNotString(agent, "max_capacity_tokens", "helper.max_capacity_tokens");
    try expectNotString(agent, "compaction_threshold_percent", "helper.compaction_threshold_percent");
}

// The sub-agents feature is gone: nothing carries a `sub_agents` list any more.
test "no_sub_agents_key_survives_a_save" {
    var h = try Harness.init(gpa);
    defer h.deinit();

    const agent_json = try std.fmt.allocPrint(gpa,
        \\{{"model":"gpt-4o","api_key":"stub-key-not-real","sub_agents":[{{"name":"ghost","model":"m"}}]}}
    , .{});
    defer gpa.free(agent_json);
    try putAgent(&h, "coder", agent_json);

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    const doc = try parseJson(body);
    defer doc.deinit();

    const agent = try agentObject(&doc, "coder");
    if (agent.get("sub_agents")) |v| {
        std.debug.print("the sub_agents feature is gone, but the key survived: {any}\n", .{v});
        return error.TestUnexpectedResult;
    }
}

// The secrets stay confined to their own two keys: a marker in api_key or
// base_url must not leak into another field.
test "secrets_confined_to_their_own_keys" {
    var h = try Harness.init(gpa);
    defer h.deinit();

    const agent_json = try std.fmt.allocPrint(gpa,
        \\{{"model":"gpt-4o","base_url":"https://{s}","api_key":"{s}","system_prompt":"clean"}}
    , .{ SECRET_HOST, SECRET_KEY });
    defer gpa.free(agent_json);
    try putAgent(&h, "coder", agent_json);

    const body = try getConfigBody(&h);
    defer gpa.free(body);
    const doc = try parseJson(body);
    defer doc.deinit();

    const agent = try agentObject(&doc, "coder");
    try expectStr(agent, "api_key", SECRET_KEY, "coder.api_key");
    try expectStr(agent, "base_url", "https://" ++ SECRET_HOST, "coder.base_url");
    try expectStr(agent, "system_prompt", "clean", "coder.system_prompt");
    try expectStr(agent, "model", "gpt-4o", "coder.model");
}
