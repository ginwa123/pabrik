const std = @import("std");
const pabrikcore = @import("pabrikcore");

const tool_models = pabrikcore.tool_models;

/// Lenient argument parser for the bash + pwsh tools (which share
/// `tool_models.BashInput`); the field tables below drive its XML-tag recovery
/// and its error text.
pub const TIMEOUT_ALIASES: []const []const u8 = &.{ "timeout", "mandatory_timeout" };

pub const NUMERIC_U32_FIELDS = TIMEOUT_ALIASES;
pub const NUMERIC_USIZE_FIELDS = [_][]const u8{ "max_output", "max_lines" };

/// Boolean fields on `ShellInput` whose values the LLM may have
/// contaminated with stray XML closing tags.
pub const BOOL_FIELDS = [_][]const u8{ "background", "do_encoding", "is_stop" };

/// String fields on `ShellInput` whose values the LLM may have
/// contaminated with stray XML closing tags.
pub const STRING_FIELDS = [_][]const u8{ "command", "cwd", "stdin_data" };

/// The three accepted `mode` spellings, in the order the schema lists them.
/// Kept as a constant so the error message and the schema cannot disagree
/// about what is legal.
pub const MODE_VALUES: []const []const u8 = &.{
    "foreground",
    "background",
    "background_persistence",
};

/// "foreground", "background" or "background_persistence" — the `expected`
/// text for a bad `mode`, built once from `MODE_VALUES`.
const MODE_EXPECTED = "one of \"foreground\", \"background\", \"background_persistence\"";

pub const KNOWN_FIELDS: []const []const u8 = &.{
    "command",    "cwd",         "timeout",    "mandatory_timeout",
    "max_output", "max_lines",   "stdin_data", "mode",
    "background", "do_encoding", "is_stop",
};

/// Spelled the way the payload has to carry them, so the repair hint is
/// copy-pasteable.
pub const REQUIRED_HINT =
    "\"command\" (string), \"cwd\" (absolute path), \"timeout\" (seconds, 1-600)";

pub const EXAMPLE_CALL =
    "{\"command\":\"ls -la\",\"cwd\":\"/home/you/project\",\"timeout\":30}";

const CLIP_VALUE = 120;
const CLIP_PAYLOAD = 300;

/// A call that parses but cannot run, described well enough for the model to
/// repair it without guessing. Every optional slice is owned; release the lot
/// with `freeInvalidField`.
pub const InvalidField = struct {
    field: []const u8,
    /// The offending value as the LLM emitted it (verbatim, including any
    /// stray XML closing tags), or the whole payload when the failure is at
    /// the JSON level.
    got: []const u8,
    /// The wire-shape the field accepts (e.g. `"number (u32)"`).
    expected: []const u8,
    kind: Kind = .wrong_type,
    /// The fields the payload actually carried, quoted and comma-joined.
    sent: ?[]const u8 = null,
    /// The fields the payload carried that this tool does not accept.
    unknown: ?[]const u8 = null,
    /// The declared field a single unknown one most likely meant.
    suggestion: ?[]const u8 = null,

    pub const Kind = enum { wrong_type, missing, bad_json, not_object };
};

/// Result of `parseShellArgs`. Either a typed BashInput on success or
/// structured failure info. Use `formatInvalidField` to render the
/// `InvalidField` into the envelope's error text.
pub const Result = union(enum) {
    success: tool_models.BashInput,
    failure: InvalidField,
};

/// Render an `InvalidField` as the error text of a tool envelope: what went
/// wrong, what the call actually carried, and a payload that would work.
pub fn formatInvalidField(allocator: std.mem.Allocator, info: InvalidField) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (info.kind) {
        .missing => {
            try out.print(
                allocator,
                "Missing required field \"{s}\": the tool cannot run without it, so nothing was executed.\n",
                .{info.field},
            );
            if (info.sent) |sent| {
                if (sent.len == 0) {
                    try out.appendSlice(allocator, "You sent: an empty arguments object.\n");
                } else {
                    try out.print(allocator, "You sent: {s}\n", .{sent});
                }
            }
            try appendUnknown(allocator, &out, info);
            try out.print(allocator, "Required: {s}\n", .{REQUIRED_HINT});
        },
        .wrong_type => {
            try out.print(allocator, "Field \"{s}\" expects {s}, got ", .{ info.field, info.expected });
            try appendQuotedClipped(allocator, &out, info.got, CLIP_VALUE);
            try out.appendSlice(allocator, ".\n");
            if (info.sent) |sent| {
                if (sent.len != 0) try out.print(allocator, "You sent: {s}\n", .{sent});
            }
            try appendUnknown(allocator, &out, info);
        },
        .bad_json => {
            try out.appendSlice(allocator, "The arguments are not valid JSON, got ");
            try appendQuotedClipped(allocator, &out, info.got, CLIP_PAYLOAD);
            try out.appendSlice(
                allocator,
                ".\nCommon causes: a ```json fence around the object, a lone backslash in a Windows path, or the call cut off mid-object.\n",
            );
        },
        .not_object => {
            try out.appendSlice(allocator, "The arguments must be ONE JSON object of named fields, got ");
            try appendQuotedClipped(allocator, &out, info.got, CLIP_PAYLOAD);
            try out.appendSlice(allocator, ".\n");
        },
    }

    try out.print(allocator, "A call that works: {s}", .{EXAMPLE_CALL});
    return out.toOwnedSlice(allocator);
}

fn appendUnknown(allocator: std.mem.Allocator, out: *std.ArrayList(u8), info: InvalidField) !void {
    const unknown = info.unknown orelse return;
    try out.print(allocator, "Unrecognized field {s}: this tool has no such parameter.", .{unknown});
    if (info.suggestion) |suggestion| {
        try out.print(allocator, " Did you mean \"{s}\"?", .{suggestion});
    }
    try out.append(allocator, '\n');
}

fn appendQuotedClipped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max: usize) !void {
    try out.append(allocator, '"');
    if (text.len <= max) {
        try out.appendSlice(allocator, text);
    } else {
        try out.appendSlice(allocator, text[0..max]);
        try out.appendSlice(allocator, "…");
    }
    try out.append(allocator, '"');
}

/// Parse the JSON `arguments` string from a bash / pwsh tool call into a
/// tagged-union result.
pub fn parseShellArgs(
    allocator: std.mem.Allocator,
    arguments: []const u8,
) Result {
    // 1. Lenient parse as std.json.Value. Any well-formed JSON object
    //    succeeds here — the type check happens per-field below.
    const parsed_value = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        arguments,
        .{},
    ) catch {
        // Malformed JSON — surface the raw payload so the LLM can see
        // exactly what bytes it sent.
        const got_dup = allocator.dupe(u8, arguments) catch arguments;
        return .{ .failure = .{
            .field = "<json>",
            .got = got_dup,
            .expected = "JSON object",
            .kind = .bad_json,
        } };
    };
    defer parsed_value.deinit();

    const root = parsed_value.value;
    if (root != .object) {
        const got_dup = allocator.dupe(u8, arguments) catch arguments;
        return .{ .failure = .{
            .field = "<json>",
            .got = got_dup,
            .expected = "JSON object",
            .kind = .not_object,
        } };
    }
    const obj = root.object;

    // 2. Coerce each field with field-aware cleanup + clear errors.
    var out: tool_models.BashInput = .{ .command = "" };

    // command (required string)
    if (obj.get("command")) |v| {
        const s = coerceString(allocator, v, "command") orelse {
            return returnFail(allocator, &out, obj, v, "command", "string");
        };
        out.command = s;
    } else {
        // No allocator-needed slice was produced yet (command is the
        // first field we coerce), so a duped "<missing>" literal is
        // safe — the caller frees via `freeInvalidField`.
        const got_dup = allocator.dupe(u8, "<missing>") catch "<missing>";
        var failure = InvalidField{
            .field = "command",
            .got = got_dup,
            .expected = "string",
            .kind = .missing,
        };
        describeArgs(allocator, obj, &failure);
        return .{ .failure = failure };
    }

    // timeout (?u32) — or its pre-rename spelling, see `TIMEOUT_ALIASES`.
    // The error names whichever spelling the caller actually used, so a model
    // that sent `mandatory_timeout` is told about `mandatory_timeout`.
    for (TIMEOUT_ALIASES) |field| {
        const v = obj.get(field) orelse continue;
        const n = coerceU32(allocator, v, field) orelse {
            return returnFail(allocator, &out, obj, v, field, "number (u32)");
        };
        out.timeout = n;
        break;
    }
    // else: leave as null. The execute_bash validator will return
    // TimeoutMissing if still null.

    // cwd (?string)
    if (obj.get("cwd")) |v| {
        const s = coerceString(allocator, v, "cwd") orelse {
            return returnFail(allocator, &out, obj, v, "cwd", "string");
        };
        out.cwd = s;
    }

    // max_output (?usize)
    if (obj.get("max_output")) |v| {
        const n = coerceUsize(allocator, v, "max_output") orelse {
            return returnFail(allocator, &out, obj, v, "max_output", "number (usize)");
        };
        out.max_output = n;
    }

    // stdin_data (?string)
    if (obj.get("stdin_data")) |v| {
        const s = coerceString(allocator, v, "stdin_data") orelse {
            return returnFail(allocator, &out, obj, v, "stdin_data", "string");
        };
        out.stdin_data = s;
    }

    // background (bool, default false)
    if (obj.get("background")) |v| {
        const b = coerceBool(allocator, v, "background") orelse {
            return returnFail(allocator, &out, obj, v, "background", "boolean (or \"true\"/\"false\")");
        };
        out.background = b;
    }

    // max_lines (?usize)
    if (obj.get("max_lines")) |v| {
        const n = coerceUsize(allocator, v, "max_lines") orelse {
            return returnFail(allocator, &out, obj, v, "max_lines", "number (usize)");
        };
        out.max_lines = n;
    }

    // do_encoding (bool, default false)
    if (obj.get("do_encoding")) |v| {
        const b = coerceBool(allocator, v, "do_encoding") orelse {
            return returnFail(allocator, &out, obj, v, "do_encoding", "boolean (or \"true\"/\"false\")");
        };
        out.do_encoding = b;
    }

    // is_stop (bool, default false) — loop control, not a shell option.
    if (obj.get("is_stop")) |v| {
        const b = coerceBool(allocator, v, "is_stop") orelse {
            return returnFail(allocator, &out, obj, v, "is_stop", "boolean (or \"true\"/\"false\")");
        };
        out.is_stop = b;
    }

    // ─── mode (string enum) + the legacy `background` boolean ─── Resolved
    // TOGETHER, because they are two spellings of one decision and the only
    // input that cannot be resolved is `background=true` alongside an
    var explicit_mode: ?tool_models.RunMode = null;
    if (obj.get("mode")) |v| {
        const raw = coerceString(allocator, v, "mode") orelse {
            return returnFail(allocator, &out, obj, v, "mode", MODE_EXPECTED);
        };
        // `coerceString` dups; the parsed enum owns nothing, so release now.
        defer allocator.free(raw);
        explicit_mode = tool_models.RunMode.fromWire(raw) orelse {
            return returnFail(allocator, &out, obj, v, "mode", MODE_EXPECTED);
        };
    }

    if (explicit_mode) |m| {
        if (out.background and m == .foreground) {
            // Rendered as a `background` problem because that is the field
            // whose value is wrong once `mode` is explicit.
            return returnFail(
                allocator,
                &out,
                obj,
                obj.get("background") orelse .{ .bool = out.background },
                "background",
                "false, when you also pass mode=\"foreground\" (or drop mode to mean background)",
            );
        }
        // An explicit non-foreground mode keeps the legacy boolean's meaning
        // for the benefit of anything reading `.background` directly.
        out.mode = m;
        out.background = m.isDetached();
    } else if (out.background) {
        out.mode = .background;
    }

    return .{ .success = out };
}

/// Build a `Result.failure` and synchronously free any slices already
/// duped into `*out` (so the caller doesn't leak on the failure path).
/// Returns the tagged-union failure variant.
fn returnFail(
    allocator: std.mem.Allocator,
    out: *tool_models.BashInput,
    obj: std.json.ObjectMap,
    v: std.json.Value,
    field: []const u8,
    expected: []const u8,
) Result {
    freeInput(allocator, out.*);
    // Reset the command field to "" so freeInput doesn't double-free if
    // it's called again on the same struct.
    out.command = "";
    out.cwd = null;
    out.stdin_data = null;
    var failure = makeInvalidField(allocator, v, field, expected);
    describeArgs(allocator, obj, &failure);
    return .{ .failure = failure };
}

const MAX_LISTED_FIELDS = 12;
const MAX_UNKNOWN_LISTED = 3;
const MAX_SUGGESTION_DISTANCE = 2;
const MAX_FIELD_NAME = 32;

/// Record which fields the payload carried and which of them the tool does
/// not accept, so the error text can name the model's typo instead of only
/// reporting the field that went missing because of it.
fn describeArgs(allocator: std.mem.Allocator, obj: std.json.ObjectMap, failure: *InvalidField) void {
    const keys = obj.keys();
    failure.sent = joinQuoted(allocator, keys, keys.len, MAX_LISTED_FIELDS) catch null;

    var buffer: [MAX_UNKNOWN_LISTED][]const u8 = undefined;
    var listed: usize = 0;
    var total: usize = 0;
    for (keys) |key| {
        if (isKnownField(key)) continue;
        total += 1;
        if (listed < buffer.len) {
            buffer[listed] = key;
            listed += 1;
        }
    }
    if (total == 0) return;

    failure.unknown = joinQuoted(allocator, buffer[0..listed], total, MAX_UNKNOWN_LISTED) catch null;
    if (total != 1) return;
    const suggested = nearestField(buffer[0]) orelse return;
    failure.suggestion = allocator.dupe(u8, suggested) catch null;
}

fn joinQuoted(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    total: usize,
    limit: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const shown = @min(names.len, limit);
    for (names[0..shown], 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.print(allocator, "\"{s}\"", .{name});
    }
    if (total > shown) try out.appendSlice(allocator, ", …");
    return out.toOwnedSlice(allocator);
}

fn isKnownField(name: []const u8) bool {
    for (KNOWN_FIELDS) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

fn nearestField(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = MAX_SUGGESTION_DISTANCE + 1;
    var tied = false;
    for (KNOWN_FIELDS) |known| {
        const distance = fieldDistance(name, known) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = known;
            tied = false;
        } else if (best != null and distance == best_distance) {
            tied = true;
        }
    }
    return if (tied) null else best;
}

fn fieldDistance(a: []const u8, b: []const u8) ?usize {
    var buf_a: [MAX_FIELD_NAME]u8 = undefined;
    var buf_b: [MAX_FIELD_NAME]u8 = undefined;
    const norm_a = normalizeField(a, &buf_a) orelse return null;
    const norm_b = normalizeField(b, &buf_b) orelse return null;
    return editDistance(norm_a, norm_b, MAX_SUGGESTION_DISTANCE);
}

fn normalizeField(name: []const u8, buf: *[MAX_FIELD_NAME]u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    var n: usize = 0;
    for (name) |c| {
        if (c == '_' or c == '-') continue;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

fn editDistance(a: []const u8, b: []const u8, max: usize) ?usize {
    const length_gap = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (length_gap > max) return null;
    if (a.len > MAX_FIELD_NAME or b.len > MAX_FIELD_NAME) return null;

    var prev: [MAX_FIELD_NAME + 1]usize = undefined;
    var current: [MAX_FIELD_NAME + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        current[0] = i + 1;
        var row_min = current[0];
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            current[j + 1] = @min(@min(current[j] + 1, prev[j + 1] + 1), prev[j] + cost);
            row_min = @min(row_min, current[j + 1]);
        }
        if (row_min > max) return null;
        const swap = prev;
        prev = current;
        current = swap;
    }
    const distance = prev[b.len];
    return if (distance <= max) distance else null;
}

/// Strip a single trailing `</fieldname>` substring from `s` IF `s` ends with
/// `</fieldname>`.
fn stripFieldCloseTag(allocator: std.mem.Allocator, s: []const u8, field: []const u8) ![]u8 {
    const close = "</";
    if (s.len < close.len + field.len + 1) return try allocator.dupe(u8, s);
    // Must END with `</field>` exactly.
    const start = s.len - close.len - field.len - 1; // position of '<'
    if (!std.mem.eql(u8, s[start .. start + close.len], close)) {
        return try allocator.dupe(u8, s);
    }
    if (!std.mem.eql(u8, s[start + close.len .. start + close.len + field.len], field)) {
        return try allocator.dupe(u8, s);
    }
    if (s[s.len - 1] != '>') return try allocator.dupe(u8, s);
    // Strip the trailing </fieldname> by returning the prefix.
    return try allocator.dupe(u8, s[0..start]);
}

/// Render a JSON value as a short display string suitable for error messages.
/// For strings: the verbatim content. For numbers / bools: the JSON literal.
/// For null: the literal "null". For arrays / objects: a placeholder.
fn jsonValueDisplay(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .null => try allocator.dupe(u8, "null"),
        .array => try allocator.dupe(u8, "<array>"),
        .object => try allocator.dupe(u8, "<object>"),
        else => try allocator.dupe(u8, "<unknown>"),
    };
}

fn makeInvalidField(allocator: std.mem.Allocator, v: std.json.Value, field: []const u8, expected: []const u8) InvalidField {
    return InvalidField{
        .field = field,
        .got = jsonValueDisplay(allocator, v) catch "<unrepresentable>",
        .expected = expected,
    };
}

fn coerceString(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    field: []const u8,
) ?[]u8 {
    switch (v) {
        .string => |s| {
            // Field-aware XML-close-tag cleanup: strip a single trailing
            // `</field>` from string fields too — the LLM may have polluted a
            // string like `"echo a > /tmp/x</command>"` by accidentally
            return stripFieldCloseTag(allocator, s, field) catch null;
        },
        else => return null,
    }
}

fn coerceU32(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    field: []const u8,
) ?u32 {
    switch (v) {
        .integer => |i| {
            if (i < 0) return null;
            return @intCast(i);
        },
        .float => |f| {
            if (f < 0) return null;
            return @intFromFloat(f);
        },
        .string => |s| {
            // Field-aware XML-close-tag cleanup (the user's exact bug).
            const cleaned = stripFieldCloseTag(allocator, s, field) catch return null;
            defer allocator.free(cleaned);
            return std.fmt.parseInt(u32, cleaned, 10) catch null;
        },
        else => return null,
    }
}

fn coerceUsize(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    field: []const u8,
) ?usize {
    switch (v) {
        .integer => |i| {
            if (i < 0) return null;
            return @intCast(i);
        },
        .float => |f| {
            if (f < 0) return null;
            return @intFromFloat(f);
        },
        .string => |s| {
            const cleaned = stripFieldCloseTag(allocator, s, field) catch return null;
            defer allocator.free(cleaned);
            return std.fmt.parseInt(usize, cleaned, 10) catch null;
        },
        else => return null,
    }
}

fn coerceBool(
    allocator: std.mem.Allocator,
    v: std.json.Value,
    field: []const u8,
) ?bool {
    switch (v) {
        .bool => |b| return b,
        .string => |s| {
            // Field-aware XML-close-tag cleanup: same recovery as the
            // numeric coercers. `true</do_encoding>` → "true" → true.
            const cleaned = stripFieldCloseTag(allocator, s, field) catch return null;
            defer allocator.free(cleaned);
            if (std.mem.eql(u8, cleaned, "true")) return true;
            if (std.mem.eql(u8, cleaned, "false")) return false;
            return null;
        },
        else => return null,
    }
}

// ============================================================================
// Tests — regression coverage for the user's bug + the common variations.
// ============================================================================

const testing = std.testing;

/// Free every owned slice in a `BashInput` returned by `parseShellArgs`.
/// Use with `defer freeInput(testing.allocator, input);` at the top of
/// every success-arm test body.
fn freeInput(allocator: std.mem.Allocator, input: tool_models.BashInput) void {
    allocator.free(input.command);
    if (input.cwd) |c| allocator.free(c);
    if (input.stdin_data) |s| allocator.free(s);
}

/// Free every owned slice in an `InvalidField` returned by `parseShellArgs`.
/// Use with `defer freeInvalidField(testing.allocator, info);` at the top of
/// every failure-arm test body.
pub fn freeInvalidField(allocator: std.mem.Allocator, info: InvalidField) void {
    allocator.free(info.got);
    if (info.sent) |sent| allocator.free(sent);
    if (info.unknown) |unknown| allocator.free(unknown);
    if (info.suggestion) |suggestion| allocator.free(suggestion);
}

test "parseShellArgs: recovers from LLM XML-fragment hallucination in timeout" {
    // The exact wire the user pasted.
    const args =
        \\{"command":"echo b","cwd":"/tmp","timeout":"5</timeout>"}
    ;
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqualStrings("echo b", input.command);
            try testing.expectEqualStrings("/tmp", input.cwd.?);
            try testing.expectEqual(@as(u32, 5), input.timeout.?);
        },
        .failure => |info| {
            std.debug.print("unexpected failure: {s}\n", .{info.field});
            return error.TestUnexpectedResult;
        },
    }
}

test "parseShellArgs: numeric string timeout" {
    const args = "{\"command\":\"ls\",\"timeout\":\"30\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 30), input.timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: real number timeout" {
    const args = "{\"command\":\"ls\",\"timeout\":30}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 30), input.timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: missing timeout leaves null (validator fires later)" {
    const args = "{\"command\":\"ls\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.timeout == null);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: missing required command returns failure" {
    const args = "{\"timeout\":5}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("command", result.failure.field);
    try testing.expectEqualStrings("<missing>", result.failure.got);
}

test "parseShellArgs: truly garbage timeout returns failure with rich info" {
    const args = "{\"command\":\"ls\",\"timeout\":\"abc\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("timeout", result.failure.field);
    try testing.expectEqualStrings("abc", result.failure.got);
    try testing.expectEqualStrings("number (u32)", result.failure.expected);
}

test "parseShellArgs: failure message renders cleanly for the envelope" {
    // Use a value that's not a recoverable XML-fragment (no matching
    // close tag) so the parser genuinely fails. The envelope-rendering
    // helper surfaces the bad value verbatim.
    const args = "{\"command\":\"ls\",\"timeout\":\"not-a-number\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(testing.allocator, info);
            const msg = try formatInvalidField(testing.allocator, info);
            defer testing.allocator.free(msg);
            try testing.expect(std.mem.indexOf(u8, msg, "timeout") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "not-a-number") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "number (u32)") != null);
        },
    }
}

fn failureMessage(allocator: std.mem.Allocator, args: []const u8) ![]u8 {
    switch (parseShellArgs(allocator, args)) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(allocator, info);
            return formatInvalidField(allocator, info);
        },
    }
}

fn manyUnknownFields(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.append(allocator, '{');
    for (0..count) |i| {
        if (i != 0) try payload.append(allocator, ',');
        try payload.print(allocator, "\"k{d}\":{d}", .{ i, i });
    }
    try payload.append(allocator, '}');
    return payload.toOwnedSlice(allocator);
}

test "formatInvalidField: a missing field names what the call did send and what to send instead" {
    const msg = try failureMessage(testing.allocator, "{\"timeout\":5,\"cwd\":\"/tmp\"}");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "Missing required field \"command\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "You sent: \"timeout\", \"cwd\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, EXAMPLE_CALL) != null);
}

test "formatInvalidField: an empty arguments object is named as empty, not as <missing>" {
    const msg = try failureMessage(testing.allocator, "{}");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "an empty arguments object") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "<missing>") == null);
}

test "formatInvalidField: a misspelled field points at the field it meant" {
    const msg = try failureMessage(testing.allocator, "{\"comand\":\"ls\",\"timeout\":5}");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "Unrecognized field \"comand\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Did you mean \"command\"?") != null);
}

test "formatInvalidField: a field this tool does not have is named, not silently dropped" {
    const msg = try failureMessage(testing.allocator, "{\"command\":\"ls\",\"timeout\":\"soon\",\"directory\":\"/tmp\"}");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "Unrecognized field \"directory\"") != null);
}

test "formatInvalidField: a wrong-typed field shows the value received and the shape it needs" {
    const msg = try failureMessage(testing.allocator, "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"timeout\":\"soon\"}");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "\"timeout\" expects number (u32)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"soon\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, EXAMPLE_CALL) != null);
}

test "formatInvalidField: malformed JSON carries the payload and the likely causes" {
    const msg = try failureMessage(testing.allocator, "{not valid json");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "not valid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "{not valid json") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "Common causes") != null);
    try testing.expect(std.mem.indexOf(u8, msg, EXAMPLE_CALL) != null);
}

test "formatInvalidField: a non-object root asks for one object of named fields" {
    const msg = try failureMessage(testing.allocator, "[1, 2, 3]");
    defer testing.allocator.free(msg);

    try testing.expect(std.mem.indexOf(u8, msg, "ONE JSON object") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "[1, 2, 3]") != null);
}

test "formatInvalidField: the message stops growing with the number of unrecognized fields" {
    const few = try manyUnknownFields(testing.allocator, 15);
    defer testing.allocator.free(few);
    const many = try manyUnknownFields(testing.allocator, 40);
    defer testing.allocator.free(many);

    const few_msg = try failureMessage(testing.allocator, few);
    defer testing.allocator.free(few_msg);
    const many_msg = try failureMessage(testing.allocator, many);
    defer testing.allocator.free(many_msg);

    try testing.expectEqualStrings(few_msg, many_msg);
}

test "parseShellArgs: bool from string 'true'" {
    const args = "{\"command\":\"ls\",\"background\":\"true\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.background);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: bool from string 'false'" {
    const args = "{\"command\":\"ls\",\"background\":\"false\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(!input.background);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: is_stop defaults to false when absent" {
    // Every existing caller (and every transcript written before this field
    // existed) omits `is_stop`. Absent must mean "keep looping" — not
    // "unset in a way that has to be guarded at each read site".
    const args = "{\"command\":\"ls\",\"cwd\":\"/tmp\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(!input.is_stop);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: is_stop reads a JSON boolean" {
    const args = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"is_stop\":true}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.is_stop);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: is_stop reads a string boolean" {
    // The lenient path that exists for `background` must cover `is_stop`
    // too: a model that learned the bool-as-string shape from an old
    // transcript must not get an error it cannot act on.
    const args = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"is_stop\":\"true\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.is_stop);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: a garbage is_stop names the field instead of guessing" {
    // The dangerous alternative is coercing `"yes"`-ish input to true or
    // false. Either guess ends the user's turn (or keeps it running) on a
    // value the model never sent, so this must be a structured failure.
    const args = "{\"command\":\"ls\",\"cwd\":\"/tmp\",\"is_stop\":\"maybe\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(testing.allocator, info);
            try testing.expectEqualStrings("is_stop", info.field);
            try testing.expectEqualStrings("maybe", info.got);
        },
    }
}

test "parseShellArgs: is_stop is documented as a lenient bool field" {
    // BOOL_FIELDS is what the header promises covers every boolean the LLM
    // may contaminate with a stray XML close tag. A boolean added to the
    // struct but not to this table silently loses that recovery.
    var found = false;
    for (BOOL_FIELDS) |name| {
        if (std.mem.eql(u8, name, "is_stop")) found = true;
    }
    try testing.expect(found);
}

test "parseShellArgs: mode reads each of the three wire spellings" {
    for (MODE_VALUES) |wire| {
        const args = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"command\":\"pnpm run dev\",\"cwd\":\"/w\",\"mode\":\"{s}\"}}",
            .{wire},
        );
        defer testing.allocator.free(args);
        switch (parseShellArgs(testing.allocator, args)) {
            .success => |input| {
                defer freeInput(testing.allocator, input);
                try testing.expectEqualStrings(wire, input.mode.toWire());
                try testing.expectEqual(input.mode.isDetached(), input.background);
            },
            .failure => return error.TestUnexpectedResult,
        }
    }
}

test "parseShellArgs: an unknown mode names the field instead of picking a default" {
    // The dangerous alternative is falling back to `foreground`: the model
    // asked for a detached dev server and would instead get a call that blocks
    // for 60 s and then gets killed.
    const args = "{\"command\":\"pnpm run dev\",\"cwd\":\"/w\",\"mode\":\"persistent\"}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(testing.allocator, info);
            try testing.expectEqualStrings("mode", info.field);
            try testing.expectEqualStrings("persistent", info.got);
        },
    }
}

test "parseShellArgs: background=true still means mode=background" {
    // Every transcript written before `mode` existed uses this, and so does
    // every in-tree caller. It has to keep meaning exactly what it meant.
    const args = "{\"command\":\"zig build\",\"background\":true}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(tool_models.RunMode.background, input.mode);
            try testing.expect(input.background);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: background=true with mode=foreground is rejected, not guessed" {
    // Both readings are defensible, so neither may win silently: one ends in
    // a detached `pnpm run dev` the caller wanted blocked, the other in a 60
    // s-murdered dev server.
    const args = "{\"command\":\"x\",\"background\":true,\"mode\":\"foreground\"}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(testing.allocator, info);
            try testing.expectEqualStrings("background", info.field);
            try testing.expectEqualStrings("true", info.got);
            try testing.expect(std.mem.indexOf(u8, info.expected, "mode") != null);
        },
    }
}

test "parseShellArgs: background=true alongside a detached mode is not a contradiction" {
    // Both fields say "detach", so the modern one simply wins. Rejecting this
    // would break a caller that is adding `mode` to a call site that still
    // passes the boolean.
    const args = "{\"command\":\"pnpm run dev\",\"background\":true,\"mode\":\"background_persistence\"}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(tool_models.RunMode.background_persistence, input.mode);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: mode=foreground with background=false is just foreground" {
    const args = "{\"command\":\"ls\",\"background\":false,\"mode\":\"foreground\"}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(tool_models.RunMode.foreground, input.mode);
            try testing.expect(!input.background);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: the pre-rename `mandatory_timeout` spelling still parses" {
    // Old transcripts carry it, and so does any cached tool schema. Dropping
    // the spelling would turn a previously-valid turn into `TimeoutMissing`.
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":45}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 45), input.timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: `timeout` wins when both spellings are present" {
    const args = "{\"command\":\"ls\",\"timeout\":7,\"mandatory_timeout\":45}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 7), input.timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: a bad alias value is reported under the name the caller used" {
    // Naming it `timeout` when the caller wrote `mandatory_timeout` would send
    // the model looking for a field it never sent.
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":\"soon\"}";
    switch (parseShellArgs(testing.allocator, args)) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeInvalidField(testing.allocator, info);
            try testing.expectEqualStrings("mandatory_timeout", info.field);
        },
    }
}

test "parseShellArgs: max_output with stray XML fragment" {
    const args = "{\"command\":\"ls\",\"max_output\":\"4096</max_output>\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(usize, 4096), input.max_output.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: max_output as JSON number" {
    const args = "{\"command\":\"ls\",\"max_output\":4096}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(usize, 4096), input.max_output.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: cwd with stray XML fragment" {
    const args = "{\"command\":\"ls\",\"cwd\":\"/tmp</cwd>\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqualStrings("/tmp", input.cwd.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: string field with non-matching close tag is left alone" {
    // `</command>` is NOT `</cwd>` — must NOT strip.
    const args = "{\"command\":\"echo '<a href=\\\"x\\\">'\",\"cwd\":\"/tmp\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqualStrings("echo '<a href=\"x\">'", input.command);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: malformed JSON returns failure with the raw payload" {
    const args = "{not valid json";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("<json>", result.failure.field);
    try testing.expectEqualStrings("{not valid json", result.failure.got);
}

test "parseShellArgs: non-object root returns failure" {
    const args = "[1, 2, 3]";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("<json>", result.failure.field);
}

test "parseShellArgs: bool field with garbage string returns failure" {
    const args = "{\"command\":\"ls\",\"background\":\"maybe\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("background", result.failure.field);
    try testing.expectEqualStrings("maybe", result.failure.got);
}

test "parseShellArgs: max_lines with stray XML fragment" {
    const args = "{\"command\":\"ls\",\"max_lines\":\"500</max_lines>\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(usize, 500), input.max_lines.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: do_encoding with stray XML fragment" {
    const args = "{\"command\":\"ls\",\"do_encoding\":\"true</do_encoding>\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.do_encoding);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: complex XML fragment that resists parseInt returns rich failure" {
    // Even after stripping `</timeout>`, the value still contains `<timeout>`
    // opener — parseInt fails. The helper surfaces the ORIGINAL value (with
    // the tag) so the LLM sees the corruption, not a stripped cleaned value.
    const args = "{\"command\":\"ls\",\"timeout\":\"5<timeout>5</timeout>\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeInvalidField(testing.allocator, result.failure);
    try testing.expectEqualStrings("timeout", result.failure.field);
    // The got value should still contain the original XML fragment.
    try testing.expect(std.mem.indexOf(u8, result.failure.got, "</timeout>") != null);
}

test "stripFieldCloseTag: only strips matching tag, leaves the rest" {
    const got = try stripFieldCloseTag(testing.allocator, "5</timeout>", "timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5", got);
}

test "stripFieldCloseTag: leaves non-matching tag intact" {
    const got = try stripFieldCloseTag(testing.allocator, "5</command>", "timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5</command>", got);
}

test "stripFieldCloseTag: leaves short strings alone" {
    const got = try stripFieldCloseTag(testing.allocator, "5", "timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5", got);
}

test "stripFieldCloseTag: leaves empty string alone" {
    const got = try stripFieldCloseTag(testing.allocator, "", "timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}
