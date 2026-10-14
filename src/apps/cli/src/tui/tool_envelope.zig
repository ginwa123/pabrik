//! Parse the JSON tool envelope produced by
//! `src/agentic_loop/tools_wrap_output.zig`.

const std = @import("std");
const testing = std.testing;

/// Parsed shape of the JSON tool envelope. All string slices are OWNED — call
/// `deinit` to free them.
pub const ToolEnvelope = struct {
    name: []const u8,
    parameters: []const u8,
    data: []const u8,
    success: bool,
    err_msg: []const u8,

    pub fn deinit(self: ToolEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parameters);
        allocator.free(self.data);
        allocator.free(self.err_msg);
    }
};

/// Walk the JSON envelope and return a parsed struct, or `null` when the
/// input is not a v1 envelope (missing keys, wrong types, unknown `v`).
pub fn tryParseToolEnvelope(allocator: std.mem.Allocator, content: []const u8) ?ToolEnvelope {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const v = obj.get("v") orelse return null;
    if (v != .integer or v.integer != 1) return null;

    const tool = obj.get("tool") orelse return null;
    if (tool != .string) return null;

    const success_val = obj.get("success") orelse return null;
    if (success_val != .bool) return null;

    const name = allocator.dupe(u8, tool.string) catch return null;
    errdefer allocator.free(name);

    const parameters = if (obj.get("parameters")) |p| blk: {
        if (p == .null) break :blk allocator.dupe(u8, "{}") catch return null;
        break :blk std.json.Stringify.valueAlloc(allocator, p, .{}) catch return null;
    } else allocator.dupe(u8, "{}") catch return null;
    errdefer allocator.free(parameters);

    const data = if (obj.get("data")) |d| blk: {
        if (d == .null) break :blk allocator.dupe(u8, "") catch return null;
        break :blk std.json.Stringify.valueAlloc(allocator, d, .{}) catch return null;
    } else allocator.dupe(u8, "") catch return null;
    errdefer allocator.free(data);

    const err_msg = if (obj.get("error")) |e| blk: {
        if (e != .string) break :blk allocator.dupe(u8, "") catch return null;
        break :blk allocator.dupe(u8, e.string) catch return null;
    } else allocator.dupe(u8, "") catch return null;

    return .{
        .name = name,
        .parameters = parameters,
        .data = data,
        .success = success_val.bool,
        .err_msg = err_msg,
    };
}

/// Extract a string field from a canonical-JSON object slice. Returns a
/// borrowed slice (valid while `json_obj` lives) or `""` when the key is
/// missing or not a string.
fn dataField(json_obj: []const u8, allocator: std.mem.Allocator, key: []const u8) []const u8 {
    if (json_obj.len == 0) return "";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_obj, .{}) catch return "";
    defer parsed.deinit();
    if (parsed.value != .object) return "";
    const val = parsed.value.object.get(key) orelse return "";
    if (val != .string) return "";
    return val.string;
}

/// Pick the most informative primary field for the header line. Whitelist
/// mirrors the desktop's ToolCardHeader logic.
pub fn toolEnvelopePrimary(allocator: std.mem.Allocator, env: ToolEnvelope) ![]u8 {
    if (env.name.len == 0) return try allocator.dupe(u8, "unknown");

    if (std.mem.eql(u8, env.name, "read_file") or
        std.mem.eql(u8, env.name, "write_file") or
        std.mem.eql(u8, env.name, "text_replace"))
    {
        const path = dataField(env.data, allocator, "path");
        if (path.len > 0) return try allocator.dupe(u8, path);
    }

    if (std.mem.eql(u8, env.name, "search")) {
        const q = dataField(env.data, allocator, "pattern");
        if (q.len > 0) return try allocator.dupe(u8, q);
    }

    if (std.mem.eql(u8, env.name, "glob")) {
        const p = dataField(env.data, allocator, "pattern");
        if (p.len > 0) return try allocator.dupe(u8, p);
    }

    if (std.mem.eql(u8, env.name, "bash") or std.mem.eql(u8, env.name, "pwsh") or std.mem.eql(u8, env.name, "command")) {
        const limit: usize = 64;
        const stdout = dataField(env.data, allocator, "stdout");
        if (stdout.len == 0) return try allocator.dupe(u8, "");
        if (stdout.len <= limit) return try allocator.dupe(u8, stdout);
        return try allocator.dupe(u8, stdout[0..limit]);
    }

    // Fallback — empty string (NOT the tool name). The previous behaviour
    // returned env.name, which produced tool cards like `▶ load_memory
    // load_memory ✓` — the name appeared twice.
    return try allocator.dupe(u8, "");
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "tryParseToolEnvelope: valid envelope returns parsed struct" {
    const allocator = testing.allocator;
    const content =
        "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"/foo.txt\"},\"success\":true,\"data\":{\"content\":\"hi\"},\"error\":null,\"v\":1}";
    var env = tryParseToolEnvelope(allocator, content) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    try testing.expectEqualStrings("read_file", env.name);
    try testing.expect(env.success);
    try testing.expectEqualStrings("{\"content\":\"hi\"}", env.data);
    try testing.expectEqualStrings("", env.err_msg);
}

test "tryParseToolEnvelope: success=false with error" {
    const allocator = testing.allocator;
    const content =
        "{\"tool\":\"bash\",\"parameters\":{\"command\":\"bad\"},\"success\":false,\"data\":null,\"error\":\"boom\",\"v\":1}";
    var env = tryParseToolEnvelope(allocator, content) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    try testing.expect(!env.success);
    try testing.expectEqualStrings("boom", env.err_msg);
}

test "tryParseToolEnvelope: missing tool returns null" {
    const allocator = testing.allocator;
    try testing.expect(tryParseToolEnvelope(allocator, "{\"parameters\":{},\"success\":true,\"data\":{},\"error\":null,\"v\":1}") == null);
}

test "tryParseToolEnvelope: missing success returns null" {
    const allocator = testing.allocator;
    try testing.expect(tryParseToolEnvelope(allocator, "{\"tool\":\"x\",\"data\":{}}") == null);
}

test "tryParseToolEnvelope: plain text returns null" {
    const allocator = testing.allocator;
    try testing.expect(tryParseToolEnvelope(allocator, "some plain legacy output") == null);
}

test "tryParseToolEnvelope: legacy XML returns null" {
    const allocator = testing.allocator;
    try testing.expect(tryParseToolEnvelope(allocator, "<tool><name>x</name></tool>") == null);
}

test "toolEnvelopePrimary: read_file uses path from data" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"read_file\",\"parameters\":{},\"success\":true,\"data\":{\"path\":\"/foo.txt\",\"content\":\"hi\"},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("/foo.txt", primary);
}

test "toolEnvelopePrimary: write_file uses path from data" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"write_file\",\"parameters\":{},\"success\":true,\"data\":{\"path\":\"/a/b/c.txt\"},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("/a/b/c.txt", primary);
}

test "toolEnvelopePrimary: text_replace uses path from data" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"text_replace\",\"parameters\":{},\"success\":true,\"data\":{\"path\":\"/foo.txt\",\"replaced\":3},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("/foo.txt", primary);
}

test "toolEnvelopePrimary: search uses pattern from data" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"search\",\"parameters\":{},\"success\":true,\"data\":{\"pattern\":\"foo bar\",\"returned\":3},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("foo bar", primary);
}

test "toolEnvelopePrimary: glob uses pattern from data" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"glob\",\"parameters\":{},\"success\":true,\"data\":{\"pattern\":\"**/*.zig\"},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("**/*.zig", primary);
}

test "toolEnvelopePrimary: bash truncates stdout to 64 chars" {
    const allocator = testing.allocator;
    const long_output = "a" ** 200;
    const content = try std.fmt.allocPrint(allocator, "{{\"tool\":\"bash\",\"parameters\":{{}},\"success\":true,\"data\":{{\"stdout\":\"{s}\"}},\"error\":null,\"v\":1}}", .{long_output});
    defer allocator.free(content);
    var env = tryParseToolEnvelope(allocator, content) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expect(primary.len <= 64);
    try testing.expect(primary.len > 0);
}

test "toolEnvelopePrimary: command truncates stdout to 64 chars" {
    const allocator = testing.allocator;
    const long_output = "a" ** 200;
    const content = try std.fmt.allocPrint(allocator, "{{\"tool\":\"command\",\"parameters\":{{}},\"success\":true,\"data\":{{\"stdout\":\"{s}\"}},\"error\":null,\"v\":1}}", .{long_output});
    defer allocator.free(content);
    var env = tryParseToolEnvelope(allocator, content) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expect(primary.len <= 64);
    try testing.expect(primary.len > 0);
}

test "toolEnvelopePrimary: unknown tool returns empty (no duplicate)" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"weird_thing\",\"parameters\":{},\"success\":true,\"data\":{},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    // Round-2 fix: the fallback used to return env.name, which made tool
    // cards render as `▶ load_memory load_memory ✓` (the name appeared
    // twice).
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("", primary);
}

test "toolEnvelopePrimary: whitelisted tool with no matching field returns empty" {
    // load_memory data has no whitelisted key — must NOT fall back to
    // the tool name.
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"load_memory\",\"parameters\":{},\"success\":true,\"data\":{\"results\":[]},\"error\":null,\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("", primary);
}

test "toolEnvelopePrimary: empty data (error path) returns empty" {
    const allocator = testing.allocator;
    var env = tryParseToolEnvelope(
        allocator,
        "{\"tool\":\"read_file\",\"parameters\":{},\"success\":false,\"data\":null,\"error\":\"not found\",\"v\":1}",
    ) orelse return error.UnexpectedNull;
    defer env.deinit(allocator);
    const primary = try toolEnvelopePrimary(allocator, env);
    defer allocator.free(primary);
    try testing.expectEqualStrings("", primary);
}
