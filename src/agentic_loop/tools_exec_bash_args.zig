const std = @import("std");
const pabrikcore = @import("pabrikcore");

const tool_models = pabrikcore.tool_models;

/// Lenient argument parser for the bash + pwsh tools. ## Why this exists The
/// bash + pwsh tools share `tool_models.BashInput` (aliased to
/// `shell.ShellInput`).

/// Numeric fields on `ShellInput` whose values the LLM may have contaminated
/// with stray XML closing tags. Order doesn't matter; the helper matches by
/// key.
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

/// Render an `InvalidField` into a single line suitable for the `<error>`
/// element of a tool envelope. Format: `invalid field 'timeout': got JSON
/// value "5</timeout>", expected number (u32)`
pub fn formatInvalidField(allocator: std.mem.Allocator, info: InvalidField) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "invalid field '{s}': got JSON value \"{s}\", expected {s}",
        .{ info.field, info.got, info.expected },
    );
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

    // timeout (?u32) — or its pre-rename spelling, see `TIMEOUT_ALIASES`.
    // The error names whichever spelling the caller actually used, so a model
    // that sent `mandatory_timeout` is told about `mandatory_timeout`.
    for (TIMEOUT_ALIASES) |field| {
        const v = obj.get(field) orelse continue;
        const n = coerceU32(allocator, v, field) orelse {
            return returnFail(allocator, &out, v, field, "number (u32)");
        };
        out.timeout = n;
        break;
    }
    // else: leave as null. The execute_bash validator will return
    // TimeoutMissing if still null.

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

    // ─── mode (string enum) + the legacy `background` boolean ─── Resolved
    // TOGETHER, because they are two spellings of one decision and the only
    // input that cannot be resolved is `background=true` alongside an
    var explicit_mode: ?tool_models.RunMode = null;
    if (obj.get("mode")) |v| {
        const raw = coerceString(allocator, v, "mode") orelse {
            return returnFail(allocator, &out, v, "mode", MODE_EXPECTED);
        };
        // `coerceString` dups; the parsed enum owns nothing, so release now.
        defer allocator.free(raw);
        explicit_mode = tool_models.RunMode.fromWire(raw) orelse {
            return returnFail(allocator, &out, v, "mode", MODE_EXPECTED);
        };
    }

    if (explicit_mode) |m| {
        if (out.background and m == .foreground) {
            // Rendered as a `background` problem because that is the field
            // whose value is wrong once `mode` is explicit.
            return returnFail(
                allocator,
                &out,
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
/// Use with `defer freeFailure(testing.allocator, info);` at the top of
/// every failure-arm test body.
fn freeFailure(allocator: std.mem.Allocator, info: InvalidField) void {
    allocator.free(info.got);
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
    defer freeFailure(testing.allocator, result.failure);
    try testing.expectEqualStrings("command", result.failure.field);
    try testing.expectEqualStrings("<missing>", result.failure.got);
}

test "parseShellArgs: truly garbage timeout returns failure with rich info" {
    const args = "{\"command\":\"ls\",\"timeout\":\"abc\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
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
            defer freeFailure(testing.allocator, info);
            const msg = try formatInvalidField(testing.allocator, info);
            defer testing.allocator.free(msg);
            try testing.expect(std.mem.indexOf(u8, msg, "timeout") != null);
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
            defer testing.allocator.free(info.got);
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
            defer testing.allocator.free(info.got);
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
            defer testing.allocator.free(info.got);
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
    // Even after stripping `</timeout>`, the value still contains `<timeout>`
    // opener — parseInt fails. The helper surfaces the ORIGINAL value (with
    // the tag) so the LLM sees the corruption, not a stripped cleaned value.
    const args = "{\"command\":\"ls\",\"timeout\":\"5<timeout>5</timeout>\"}";
    const result = parseShellArgs(testing.allocator, args);
    try testing.expect(result == .failure);
    defer freeFailure(testing.allocator, result.failure);
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