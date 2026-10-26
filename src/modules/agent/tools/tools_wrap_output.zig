const std = @import("std");
const pabrikcore = @import("pabrikcore");

const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;
const testing = std.testing;

/// Wrap a tool result in the standardized JSON envelope. On success: emits
/// `"data"` containing the inner tool-specific JSON object.
pub fn wrapToolOutput(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    parameters: []const u8,
    success: bool,
    error_message: ?[]const u8,
    data: []const u8,
) ![]u8 {
    const params_json = try normalizeParamsJson(allocator, parameters);
    defer allocator.free(params_json);
    const tool_json = try std.json.Stringify.valueAlloc(allocator, tool_name, .{});
    defer allocator.free(tool_json);

    if (success) {
        const data_frag = try normalizeDataFragment(allocator, data);
        defer allocator.free(data_frag);
        return try std.fmt.allocPrint(
            allocator,
            "{{\"tool\":{s},\"parameters\":{s},\"success\":true,\"data\":{s},\"error\":null,\"v\":1}}",
            .{ tool_json, params_json, data_frag },
        );
    } else {
        const msg = error_message orelse "unknown error";
        const err_json = try std.json.Stringify.valueAlloc(allocator, msg, .{});
        defer allocator.free(err_json);
        return try std.fmt.allocPrint(
            allocator,
            "{{\"tool\":{s},\"parameters\":{s},\"success\":false,\"data\":null,\"error\":{s},\"v\":1}}",
            .{ tool_json, params_json, err_json },
        );
    }
}

/// Add the wall-clock duration of a tool call to its result envelope. The
/// envelope shape is fixed by `wrapToolOutput`, so the field goes in front of
/// the trailing `"v":1}`. Anything that is not an envelope is returned as is.
pub fn withDurationMs(allocator: std.mem.Allocator, envelope: []const u8, duration_ms: u64) ![]u8 {
    const prefix = "{\"tool\":";
    const suffix = ",\"v\":1}";
    if (!std.mem.startsWith(u8, envelope, prefix)) return allocator.dupe(u8, envelope);
    if (!std.mem.endsWith(u8, envelope, suffix)) return allocator.dupe(u8, envelope);
    const head = envelope[0 .. envelope.len - suffix.len];
    return std.fmt.allocPrint(allocator, "{s},\"duration_ms\":{d}{s}", .{ head, duration_ms, suffix });
}

// Every `execX` function below MUST end by calling `wrapToolOutput` so the
// LLM sees a single consistent envelope: {"tool":…, "parameters":…,
// "success":true|false, "data":{…} | null, "error":"…" | null, "v":1} The

/// Normalize a raw JSON arguments string into the JSON value that goes in the
/// envelope's `"parameters"` field. - Empty input → `{}`. - Top-level object
/// → re-serialized canonically. - Malformed JSON or non-object top level →
fn normalizeParamsJson(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, json_str, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return try allocator.dupe(u8, "{}");
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        // Malformed JSON fallback: keep the raw string under `_raw`.
        const raw_json = try std.json.Stringify.valueAlloc(allocator, json_str, .{});
        defer allocator.free(raw_json);
        return try std.fmt.allocPrint(allocator, "{{\"_raw\":{s}}}", .{raw_json});
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        // Top-level is not an object — wrap the value as `_raw`.
        const val_json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(val_json);
        return try std.fmt.allocPrint(allocator, "{{\"_raw\":{s}}}", .{val_json});
    }

    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

/// Normalize the tool-specific payload into the JSON fragment for the
/// envelope's `"data"` field. - Empty input → `null` (no payload). - Valid
/// JSON object → embedded verbatim (control chars sanitized first). -
fn normalizeDataFragment(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, data, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return try allocator.dupe(u8, "null");
    }

    const clean = try sanitizeControlChars(allocator, trimmed);
    defer allocator.free(clean);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, clean, .{}) catch {
        const raw_json = try std.json.Stringify.valueAlloc(allocator, clean, .{});
        defer allocator.free(raw_json);
        return try std.fmt.allocPrint(allocator, "{{\"_raw\":{s}}}", .{raw_json});
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const val_json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(val_json);
        return try std.fmt.allocPrint(allocator, "{{\"_raw\":{s}}}", .{val_json});
    }

    return try allocator.dupe(u8, clean);
}

test "withDurationMs - the envelope carries the duration" {
    const allocator = testing.allocator;
    const envelope = try wrapToolOutput(allocator, "read_file", "{\"path\":\"/x\"}", true, null, "{}");
    defer allocator.free(envelope);

    const stamped = try withDurationMs(allocator, envelope, 42);
    defer allocator.free(stamped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stamped, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 42), parsed.value.object.get("duration_ms").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("v").?.integer);
}

test "withDurationMs - a string that is not an envelope is left alone" {
    const allocator = testing.allocator;
    const out = try withDurationMs(allocator, "not an envelope", 42);
    defer allocator.free(out);
    try testing.expectEqualStrings("not an envelope", out);
}

test "wrapToolOutput - success with all fields, JSON params kept as object" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/foo/bar.txt\"}",
        true,
        null,
        "{\"path\":\"/foo/bar.txt\",\"content\":\"hello\",\"total_lines\":10,\"start_line\":0,\"end_line\":10}",
    );
    defer allocator.free(out);

    // Never the legacy XML envelope.
    try testing.expect(std.mem.indexOf(u8, out, "<tool>") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const env = parsed.value.object;
    try testing.expectEqualStrings("read_file", env.get("tool").?.string);
    try testing.expectEqualStrings("/foo/bar.txt", env.get("parameters").?.object.get("path").?.string);
    try testing.expect(env.get("success").?.bool);
    const data = env.get("data").?.object;
    try testing.expectEqualStrings("hello", data.get("content").?.string);
    try testing.expectEqual(@as(i64, 10), data.get("total_lines").?.integer);
    try testing.expect(env.get("error").? == .null);
    try testing.expectEqual(@as(i64, 1), env.get("v").?.integer);
}

test "wrapToolOutput - error case nulls data and emits error" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found",
        "",
    );
    defer allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const env = parsed.value.object;
    try testing.expect(!env.get("success").?.bool);
    try testing.expectEqualStrings("File not found", env.get("error").?.string);
    try testing.expect(env.get("data").? == .null);
}

test "wrapToolOutput - empty parameters string emits empty object" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "search_skills",
        "",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("parameters").? == .object);
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("parameters").?.object.count());
}

test "wrapToolOutput - JSON params with array value are preserved" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "some_tool",
        "{\"tags\":[\"a\",\"b\",\"c\"]}",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"tags\":[\"a\",\"b\",\"c\"]") != null);
}

test "wrapToolOutput - JSON params with nested object are preserved" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{\"options\":{\"verbose\":true,\"count\":3}}",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"options\":{\"verbose\":true,\"count\":3}") != null);
}

test "wrapToolOutput - JSON params with boolean and null values" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "tool",
        "{\"enabled\":true,\"flag\":null}",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"enabled\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"flag\":null") != null);
}

test "wrapToolOutput - malformed JSON falls back to _raw" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{not valid json",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"_raw\":\"{not valid json\"") != null);
}

test "wrapToolOutput - data is preserved verbatim (no escaping)" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "{\"stdout\":\"<hi> & \\\"world\\\"\"}",
    );
    defer allocator.free(out);

    // Data is NOT re-escaped — <>& stay raw so the LLM and frontend read
    // the inner payload directly.
    try testing.expect(std.mem.indexOf(u8, out, "\"stdout\":\"<hi> & \\\"world\\\"\"") != null);
}

test "wrapToolOutput - error message is JSON-escaped" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        false,
        "bad <tag> & \"quote\"",
        "",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":\"bad <tag> & \\\"quote\\\"\"") != null);
}

test "wrapToolOutput - success and error are mutually exclusive" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        "ignored error msg",
        "{\"stdout\":\"ok\"}",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"data\":{\"stdout\":\"ok\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"error\":null") != null);
}

test "wrapToolOutput - non-JSON data is wrapped as _raw" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "just a plain string",
    );
    defer allocator.free(out);

    // Safety net so every stored row stays valid JSON while producers
    // migrate; final producers always emit objects.
    try testing.expect(std.mem.indexOf(u8, out, "\"data\":{\"_raw\":\"just a plain string\"}") != null);
}

test "wrapToolOutput - empty data on success serializes as null" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "",
    );
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"data\":null") != null);
}

test "wrapToolOutput - allocates and caller owns" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "bash",
        "{}",
        true,
        null,
        "{}",
    );
    defer allocator.free(out);
    try testing.expect(out.len > 0);
}

// ===== Tests merged from tool_output_json_contract_test.zig (2026-09-29
// flatten) ===== Phase 0 RED contract for the XML → JSON tool-output
// migration (plan `2026-09-18-agent-tool-output-xml-to-json.md`, schema in

fn parseEnvelope(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
}

test "json contract - success envelope has the six keys with data object and null error" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/x.txt\"}",
        true,
        null,
        "{\"path\":\"/x.txt\",\"content\":\"hi\",\"total_lines\":10,\"start_line\":0,\"end_line\":10}",
    );
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const env = parsed.value.object;

    try testing.expectEqualStrings("read_file", env.get("tool").?.string);
    try testing.expectEqualStrings("/x.txt", env.get("parameters").?.object.get("path").?.string);
    try testing.expect(env.get("success").?.bool);
    const data = env.get("data").?.object;
    try testing.expectEqualStrings("hi", data.get("content").?.string);
    try testing.expect(env.get("error").? == .null);
    try testing.expectEqual(@as(i64, 1), env.get("v").?.integer);
}

test "json contract - error envelope carries null data and string error" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found",
        "",
    );
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const env = parsed.value.object;

    try testing.expect(!env.get("success").?.bool);
    try testing.expect(env.get("data").? == .null);
    try testing.expectEqualStrings("File not found", env.get("error").?.string);
    try testing.expectEqual(@as(i64, 1), env.get("v").?.integer);
}

test "json contract - malformed args fall back to _raw object" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(allocator, "bash", "{not valid json", true, null, "{}");
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const params = parsed.value.object.get("parameters").?.object;
    try testing.expectEqualStrings("{not valid json", params.get("_raw").?.string);
}

test "json contract - output is JSON, never the <tool> envelope" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(allocator, "bash", "{}", true, null, "{}");
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<tool>") == null);
    // Must parse as a JSON object at all.
    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "json contract - binary stdout is sanitized, envelope stays valid JSON" {
    const allocator = testing.allocator;
    // ELF header bytes: 0x7F 'E' 'L' 'F' + NUL + C0 control. NUL truncates
    // SQLite TEXT and breaks both XML and JSON strings, so the writer must
    // replace such bytes with U+FFFD before serialization.
    const raw_stdout = [_]u8{ 0x7F, 'E', 'L', 'F', 0x00, 0x01 };
    const data = try std.fmt.allocPrint(allocator, "{{\"stdout\":\"{s}\"}}", .{raw_stdout});
    defer allocator.free(data);
    const out = try wrapToolOutput(allocator, "bash", "{}", true, null, data);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x00") == null);
    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
