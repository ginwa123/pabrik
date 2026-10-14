const std = @import("std");
const pabrikcore = @import("pabrikcore");

const tool_models = pabrikcore.tool_models;

/// Lenient argument parser for the bash + pwsh tools.
///
/// ## Why this exists
///
/// The bash + pwsh tools share `tool_models.BashInput` (aliased to
/// `shell.ShellInput`). When the LLM emits tool-call arguments where a
/// numeric field (`mandatory_timeout`, `max_output`, `max_lines`) is a
/// JSON STRING instead of a JSON number — often because the LLM
/// hallucinated an XML closing tag like `</mandatory_timeout>` into the
/// value (a leak from a prior `<tool>…<mandatory_timeout>5</mandatory_timeout>…</tool>`
/// envelope in its conversation history) — `std.json.parseFromSlice`
/// refuses to coerce the string into `?u32` / `?usize` and returns
/// `error.InvalidCharacter`. That error then bubbles up as a cryptic
/// `"bash failed: InvalidCharacter"` to `handle_tool.zig`, where the
/// LLM has no idea what to fix on its next turn.
///
/// ## What this helper does
///
/// 1. Parses `arguments` as `std.json.Value` first (lenient — any
///    well-formed JSON succeeds; the type check happens per-field below).
/// 2. Walks the object tree. For each known numeric field, if the JSON
///    value is a string:
///      a) strips a single trailing `</fieldname>` substring if present
///         (the LLM hallucination cleanup), then
///      b) attempts `parseInt`. If it succeeds, uses the integer.
///         If it fails, the helper returns `Result.failure` with the
///         offending field + the verbatim value + the expected type.
///    If the value is already a number, uses it directly.
///    If the value is null or missing, falls back to the struct default.
/// 3. For boolean fields, accepts JSON bool or the strings `"true"` /
///    `"false"`. Other inputs → `Result.failure`.
/// 4. For string fields, accepts JSON string. Other inputs → `Result.failure`.
/// 5. Returns a tagged-union `Result`: on success, a typed
///    `tool_models.BashInput` ready to pass to `execute_bash` /
///    `execute_pwsh`. On failure, an `InvalidField` payload carrying
///    the field name + bad value + expected type — the caller surfaces
///    the three fields verbatim in the tool-error envelope so the LLM
///    can self-correct on its next turn.
///
/// ## Why a tagged-union result (not error payloads)
///
/// Zig 0.16's error system can only carry error *names*, not arbitrary
/// data. To give the caller a structured "field X, value Y, expected Z"
/// for the error envelope, we use a tagged-union return type. The
/// pattern is `switch (parseShellArgs(...)) { .success => |input| ...,
/// .failure => |info| ... }`.

/// Numeric fields on `ShellInput` whose values the LLM may have
/// contaminated with stray XML closing tags. Order doesn't matter; the
/// helper matches by key.
pub const NUMERIC_U32_FIELDS = [_][]const u8{ "mandatory_timeout" };
pub const NUMERIC_USIZE_FIELDS = [_][]const u8{ "max_output", "max_lines" };

/// Boolean fields on `ShellInput` whose values the LLM may have
/// contaminated with stray XML closing tags.
pub const BOOL_FIELDS = [_][]const u8{ "background", "do_encoding", "is_stop" };

/// String fields on `ShellInput` whose values the LLM may have
/// contaminated with stray XML closing tags.
pub const STRING_FIELDS = [_][]const u8{ "command", "cwd", "stdin_data" };

/// Structured error info returned when the JSON parses but a single
/// field has the wrong type or value. The caller surfaces the three
/// fields in the error envelope so the LLM can self-correct next turn.
pub const InvalidField = struct {
    field: []const u8,
    /// The bad value as the LLM emitted it (verbatim, including any
    /// stray XML closing tags). The caller echoes this back so the
    /// LLM recognizes exactly what went wrong.
    got: []const u8,
    /// The expected Zig type / wire-shape (e.g. `"number (u32)"`).
    expected: []const u8,
};

/// Result of `parseShellArgs`. Either a typed BashInput on success or
/// structured failure info. Use `formatInvalidField` to render the
/// `InvalidField` into a single human-readable line for the envelope.
pub const Result = union(enum) {
    success: tool_models.BashInput,
    failure: InvalidField,
};

/// Render an `InvalidField` into a single line suitable for the
/// `<error>` element of a tool envelope.
///
/// Format: `invalid field 'mandatory_timeout': got JSON value "5</mandatory_timeout>", expected number (u32)`
pub fn formatInvalidField(allocator: std.mem.Allocator, info: InvalidField) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "invalid field '{s}': got JSON value \"{s}\", expected {s}",
        .{ info.field, info.got, info.expected },
    );
}

/// Parse the JSON `arguments` string from a bash / pwsh tool call into
/// a tagged-union result. The string is parsed as `std.json.Value`
/// first (lenient), then coerced field-by-field. Numeric and boolean
/// fields get field-aware XML-close-tag cleanup before coercion.
///
/// `arguments` is the raw `tc.function.arguments` slice — typically
/// arena-allocated, ownership doesn't matter (we dup what we keep).
/// The returned `success` BashInput has its slice fields allocated
/// with `allocator`; the caller owns them.
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
        } };
    }
    const obj = root.object;

    // 2. Coerce each field with field-aware cleanup + clear errors.
    //
    // Pattern: `try returnFail(field, v, expected)` is a small helper
    // (below) that builds the InvalidField, frees any slices already
    // duped into `out`, and returns the failure tagged-union variant.
    // Zig's `errdefer` doesn't fire on `return .{ .failure = ... }`
    // (that's a normal return, not an error), so we use an explicit
    // helper that does the cleanup synchronously.
    var out: tool_models.BashInput = .{ .command = "" };

    // command (required string)
    if (obj.get("command")) |v| {
        const s = coerceString(allocator, v, "command") orelse {
            return returnFail(allocator, &out, v, "command", "string");
        };
        out.command = s;
    } else {
        // No allocator-needed slice was produced yet (command is the
        // first field we coerce), so a duped "<missing>" literal is
        // safe — the caller frees via freeFailure.
        const got_dup = allocator.dupe(u8, "<missing>") catch "<missing>";
        return .{ .failure = .{
            .field = "command",
            .got = got_dup,
            .expected = "string",
        } };
    }

    // mandatory_timeout (?u32)
    if (obj.get("mandatory_timeout")) |v| {
        const n = coerceU32(allocator, v, "mandatory_timeout") orelse {
            return returnFail(allocator, &out, v, "mandatory_timeout", "number (u32)");
        };
        out.mandatory_timeout = n;
    }
    // else: leave as null. The execute_bash validator will return
    // MandatoryTimeoutMissing if still null.

    // cwd (?string)
    if (obj.get("cwd")) |v| {
        const s = coerceString(allocator, v, "cwd") orelse {
            return returnFail(allocator, &out, v, "cwd", "string");
        };
        out.cwd = s;
    }

    // max_output (?usize)
    if (obj.get("max_output")) |v| {
        const n = coerceUsize(allocator, v, "max_output") orelse {
            return returnFail(allocator, &out, v, "max_output", "number (usize)");
        };
        out.max_output = n;
    }

    // stdin_data (?string)
    if (obj.get("stdin_data")) |v| {
        const s = coerceString(allocator, v, "stdin_data") orelse {
            return returnFail(allocator, &out, v, "stdin_data", "string");
        };
        out.stdin_data = s;
    }

    // background (bool, default false)
    if (obj.get("background")) |v| {
        const b = coerceBool(allocator, v, "background") orelse {
            return returnFail(allocator, &out, v, "background", "boolean (or \"true\"/\"false\")");
        };
        out.background = b;
    }

    // max_lines (?usize)
    if (obj.get("max_lines")) |v| {
        const n = coerceUsize(allocator, v, "max_lines") orelse {
            return returnFail(allocator, &out, v, "max_lines", "number (usize)");
        };
        out.max_lines = n;
    }

    // do_encoding (bool, default false)
    if (obj.get("do_encoding")) |v| {
        const b = coerceBool(allocator, v, "do_encoding") orelse {
            return returnFail(allocator, &out, v, "do_encoding", "boolean (or \"true\"/\"false\")");
        };
        out.do_encoding = b;
    }

    // is_stop (bool, default false) — loop control, not a shell option.
    if (obj.get("is_stop")) |v| {
        const b = coerceBool(allocator, v, "is_stop") orelse {
            return returnFail(allocator, &out, v, "is_stop", "boolean (or \"true\"/\"false\")");
        };
        out.is_stop = b;
    }

    return .{ .success = out };
}

/// Build a `Result.failure` and synchronously free any slices already
/// duped into `*out` (so the caller doesn't leak on the failure path).
/// Returns the tagged-union failure variant.
fn returnFail(
    allocator: std.mem.Allocator,
    out: *tool_models.BashInput,
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
    return .{ .failure = makeInvalidField(allocator, v, field, expected) };
}

/// Strip a single trailing `</fieldname>` substring from `s` IF `s`
/// ends with `</fieldname>`. Returns a freshly allocated slice (or the
/// original `s` if no cleanup is needed).
///
/// Examples:
///   `"5</mandatory_timeout>"` → `"5"`
///   `"5</mandatory_timeout></mandatory_timeout>"` → `"5</mandatory_timeout>"`
///     (only one strip — the rest is left for `parseInt` to fail on,
///     giving the LLM a chance to see the remaining garbage).
///   `"hello world"` → `"hello world"` (unchanged)
///   `"<a href=\"x\">"` → `"<a href=\"x\">"` (unchanged — different tag)
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

/// Render a JSON value as a short display string suitable for error
/// messages. For strings: the verbatim content. For numbers / bools:
/// the JSON literal. For null: the literal "null". For arrays /
/// objects: a placeholder.
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
            // `</field>` from string fields too — the LLM may have
            // polluted a string like `"echo a > /tmp/x</command>"` by
            // accidentally closing the wrong element.
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
/// Use with `defer freeFailure(testing.allocator, info);` at the top of
/// every failure-arm test body.
fn freeFailure(allocator: std.mem.Allocator, info: InvalidField) void {
    allocator.free(info.got);
}

test "parseShellArgs: recovers from LLM XML-fragment hallucination in mandatory_timeout" {
    // The exact wire the user pasted.
    const args =
        \\{"command":"echo b","cwd":"/tmp","mandatory_timeout":"5</mandatory_timeout>"}
    ;
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqualStrings("echo b", input.command);
            try testing.expectEqualStrings("/tmp", input.cwd.?);
            try testing.expectEqual(@as(u32, 5), input.mandatory_timeout.?);
        },
        .failure => |info| {
            std.debug.print("unexpected failure: {s}\n", .{info.field});
            return error.TestUnexpectedResult;
        },
    }
}

test "parseShellArgs: numeric string mandatory_timeout" {
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":\"30\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 30), input.mandatory_timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: real number mandatory_timeout" {
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":30}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expectEqual(@as(u32, 30), input.mandatory_timeout.?);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: missing mandatory_timeout leaves null (validator fires later)" {
    const args = "{\"command\":\"ls\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => |input| {
            defer freeInput(testing.allocator, input);
            try testing.expect(input.mandatory_timeout == null);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "parseShellArgs: missing required command returns failure" {
    const args = "{\"mandatory_timeout\":5}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("command", result.failure.field);
    try testing.expectEqualStrings("<missing>", result.failure.got);
}

test "parseShellArgs: truly garbage mandatory_timeout returns failure with rich info" {
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":\"abc\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("mandatory_timeout", result.failure.field);
    try testing.expectEqualStrings("abc", result.failure.got);
    try testing.expectEqualStrings("number (u32)", result.failure.expected);
}

test "parseShellArgs: failure message renders cleanly for the envelope" {
    // Use a value that's not a recoverable XML-fragment (no matching
    // close tag) so the parser genuinely fails. The envelope-rendering
    // helper surfaces the bad value verbatim.
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":\"not-a-number\"}";
    const result = parseShellArgs(testing.allocator, args);
    switch (result) {
        .success => return error.TestUnexpectedResult,
        .failure => |info| {
            defer freeFailure(testing.allocator, info);
            const msg = try formatInvalidField(testing.allocator, info);
            defer testing.allocator.free(msg);
            try testing.expect(std.mem.indexOf(u8, msg, "mandatory_timeout") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "not-a-number") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "number (u32)") != null);
        },
    }
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
            defer testing.allocator.free(info.got);
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
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("<json>", result.failure.field);
    try testing.expectEqualStrings("{not valid json", result.failure.got);
}

test "parseShellArgs: non-object root returns failure" {
    const args = "[1, 2, 3]";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("<json>", result.failure.field);
}

test "parseShellArgs: bool field with garbage string returns failure" {
    const args = "{\"command\":\"ls\",\"background\":\"maybe\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
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
    // Even after stripping `</mandatory_timeout>`, the value still
    // contains `<mandatory_timeout>` opener — parseInt fails. The
    // helper surfaces the ORIGINAL value (with the tag) so the LLM
    // sees the corruption, not a stripped cleaned value.
    const args = "{\"command\":\"ls\",\"mandatory_timeout\":\"5<mandatory_timeout>5</mandatory_timeout>\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("mandatory_timeout", result.failure.field);
    // The got value should still contain the original XML fragment.
    try testing.expect(std.mem.indexOf(u8, result.failure.got, "</mandatory_timeout>") != null);
}

test "stripFieldCloseTag: only strips matching tag, leaves the rest" {
    const got = try stripFieldCloseTag(testing.allocator, "5</mandatory_timeout>", "mandatory_timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5", got);
}

test "stripFieldCloseTag: leaves non-matching tag intact" {
    const got = try stripFieldCloseTag(testing.allocator, "5</command>", "mandatory_timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5</command>", got);
}

test "stripFieldCloseTag: leaves short strings alone" {
    const got = try stripFieldCloseTag(testing.allocator, "5", "mandatory_timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("5", got);
}

test "stripFieldCloseTag: leaves empty string alone" {
    const got = try stripFieldCloseTag(testing.allocator, "", "mandatory_timeout");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}