//! Repair for tool-call `arguments` that a model emitted with RAW backslashes
//! inside a JSON string literal.
const std = @import("std");
const testing = std.testing;

/// True when `c` is one of the escape introducers RFC 8259 §7 accepts as a
/// single-character escape. `u` is handled separately because it is a
/// four-hex-digit escape, not a single-character one.
fn isSimpleEscape(c: u8) bool {
    return switch (c) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => true,
        else => false,
    };
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Rewrite every backslash inside a JSON string literal that does not
/// introduce a legal escape into `\\`.
pub fn escapeRawBackslashes(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var changed = false;
    // First pass: decide whether a rewrite is needed at all, so the common
    // (already-valid) case costs no allocation.
    {
        var in_string = false;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (!in_string) {
                if (c == '"') in_string = true;
                i += 1;
                continue;
            }
            if (c == '"') {
                in_string = false;
                i += 1;
                continue;
            }
            if (c == '\\') {
                const next = if (i + 1 < raw.len) raw[i + 1] else 0;
                if (next == 'u' and i + 5 < raw.len and isHexDigit(raw[i + 2]) and isHexDigit(raw[i + 3]) and isHexDigit(raw[i + 4]) and isHexDigit(raw[i + 5])) {
                    i += 6;
                    continue;
                }
                if (isSimpleEscape(next)) {
                    i += 2;
                    continue;
                }
                changed = true;
                break;
            }
            i += 1;
        }
    }
    if (!changed) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_string = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (!in_string) {
            if (c == '"') in_string = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = false;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '\\') {
            const next = if (i + 1 < raw.len) raw[i + 1] else 0;
            const legal_u = next == 'u' and i + 5 < raw.len and isHexDigit(raw[i + 2]) and isHexDigit(raw[i + 3]) and isHexDigit(raw[i + 4]) and isHexDigit(raw[i + 5]);
            if (legal_u) {
                try out.appendSlice(allocator, raw[i .. i + 6]);
                i += 6;
                continue;
            }
            if (isSimpleEscape(next)) {
                try out.appendSlice(allocator, raw[i .. i + 2]);
                i += 2;
                continue;
            }
            // Stray backslash: the next byte is a literal character (the
            // first letter of a directory name, usually), so emit `\\` and
            // let the loop handle that byte as ordinary content.
            try out.append(allocator, '\\');
            try out.append(allocator, '\\');
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// Result of `repairToolCallArguments`. The borrow is spelled out rather
/// than left to the caller to infer from pointer identity, because getting
/// that wrong is a use-after-free on a 100 KB arguments string.
pub const RepairedArgs = union(enum) {
    /// The caller's own slice, unchanged. Do not free.
    borrowed: []const u8,
    /// A fresh allocation. Free with `deinit`.
    owned: []u8,

    pub fn slice(self: RepairedArgs) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |o| o,
        };
    }

    pub fn deinit(self: RepairedArgs, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |o| allocator.free(o),
        }
    }
};

/// `raw` if it already parses as JSON, otherwise the backslash-repaired
/// form if that parses, otherwise `null` (nothing to repair — report the
/// real error rather than substituting a fake empty object).
pub fn repairToolCallArguments(allocator: std.mem.Allocator, raw: []const u8) !?RepairedArgs {
    if (parsesAsJson(raw)) return RepairedArgs{ .borrowed = raw };

    const repaired = (try escapeRawBackslashes(allocator, raw)) orelse return null;
    if (parsesAsJson(repaired)) return RepairedArgs{ .owned = repaired };
    allocator.free(repaired);
    return null;
}

/// The letter RFC 8259 pairs with each control-character escape, so a
/// decoded control byte can be read back as the two characters the model
/// actually wrote.
fn escapeLetterForControl(c: u8) ?u8 {
    return switch (c) {
        0x08 => 'b',
        0x09 => 't',
        0x0A => 'n',
        0x0C => 'f',
        0x0D => 'r',
        else => null,
    };
}

/// Re-expand control characters in a decoded file path back into the literal
/// backslash + letter the model wrote. `escapeRawBackslashes` only rewrites
/// backslashes JSON rejects.
pub fn reexpandPathControlChars(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    const has_control = for (value) |c| {
        if (escapeLetterForControl(c) != null) break true;
    } else false;
    if (!has_control) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (escapeLetterForControl(c)) |letter| {
            try out.append(allocator, '\\');
            try out.append(allocator, letter);
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parsesAsJson(raw: []const u8) bool {
    var probe = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer probe.deinit();
    return true;
}

// ---------------------------------------------------------------------------
// The reported failure: a real Windows path, unescaped by the model.
// ---------------------------------------------------------------------------

test "reported Windows path round-trips: raw backslashes in, real path out" {
    // The segment letters are load-bearing: `\n` and `\t` are LEGAL JSON
    // escapes (so the repaired value decodes to an embedded newline + tab
    // that step 2 must re-expand) while `\p`, `\o`, `\s` and `\c` are
    const raw =
        \\{"path":"C:\Users\gilang.trisetya\.config\pabrik\notes\src\test.go","old_str":"a","new_str":"b"}
    ;
    const want = "C:\\Users\\gilang.trisetya\\.config\\pabrik\\notes\\src\\test.go";

    // Precondition: this is exactly what the model emitted, and it does NOT
    // parse. This is the byte sequence behind the "works on Linux, breaks on
    // Windows" report.
    try testing.expect(!parsesAsJson(raw));

    // Step 1 — the illegal escapes (`\U`, `\.`, `\w`, `\s`, `\i`, `\d`)
    // become legal ones, so the arguments parse at all.
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("a", parsed.value.object.get("old_str").?.string);
        try testing.expectEqualStrings("b", parsed.value.object.get("new_str").?.string);
    }

    // Step 2 — `.config\pabrik\notes` decoded to a real newline + tab,
    // because `\n` and `\t` are legal escapes the repair must not touch (a
    // multi-line `new_str` needs them).
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
        defer parsed.deinit();
        const decoded = parsed.value.object.get("path").?.string;
        try testing.expect(std.mem.indexOfScalar(u8, decoded, '\n') != null);
        const path = (try reexpandPathControlChars(testing.allocator, decoded)).?;
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(want, path);
    }
}

test "reexpandPathControlChars: a clean path is returned as null (no allocation)" {
    try testing.expect((try reexpandPathControlChars(testing.allocator, "C:\\Users\\me\\a.go")) == null);
    try testing.expect((try reexpandPathControlChars(testing.allocator, "/tmp/a.go")) == null);
    try testing.expect((try reexpandPathControlChars(testing.allocator, "")) == null);
}

test "reexpandPathControlChars: a genuine multi-line value is left to its caller" {
    // Re-expansion is for PATHS only. A `new_str` that really is two lines
    // must stay two lines, which is why exec applies this to `path` and
    // never to the replacement text.
    const decoded = "line1\nline2";
    const out = (try reexpandPathControlChars(testing.allocator, decoded)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("line1\\nline2", out);
}

test "escapeRawBackslashes: already-valid arguments are left byte-identical (no allocation)" {
    const raw =
        \\{"path":"C:\\Users\\me\\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
    try testing.expect(parsesAsJson(raw));
}

test "escapeRawBackslashes: legal escapes inside strings survive untouched" {
    // \n and \t here are REAL escapes the model meant (a multi-line
    // new_str). Rewriting them to \\n would corrupt the replacement text.
    const raw =
        \\{"path":"/tmp/a.go","old_str":"x","new_str":"line1\nline2\ttabbed \"quoted\" c:\\slash"}
    ;
    try testing.expect(parsesAsJson(raw));
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
}

test "escapeRawBackslashes: \\uXXXX is left alone (four hex digits, not a separator)" {
    const raw =
        \\{"path":"C:\\Users\\ሴ\\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(parsesAsJson(raw));
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
}

test "escapeRawBackslashes: lowercase \\users is repaired, not mistaken for a \\u escape" {
    // `C:\users\...` looks like the start of a `\uXXXX` escape to a naive
    // scanner, but `sers` is not four hex digits — so the backslash is a
    // literal separator and must be escaped.
    const raw =
        \\{"path":"C:\users\me\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(!parsesAsJson(raw));
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("C:\\users\\me\\a.go", parsed.value.object.get("path").?.string);
}

test "escapeRawBackslashes: a Windows UNC path is repaired" {
    // `\server\share\a.go` written fully raw.
    const raw =
        \\{"path":"\\server\share\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(!parsesAsJson(raw));
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("\\server\\share\\a.go", parsed.value.object.get("path").?.string);
}

test "escapeRawBackslashes: backslashes OUTSIDE a string literal are not touched" {
    // `\d` between two top-level tokens is not inside a string; repairing
    // it would corrupt the structure rather than fix it.
    const raw =
        \\{"a":"C:\x","b":1}
    ;
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    try testing.expectEqualStrings("{\"a\":\"C:\\\\x\",\"b\":1}", repaired);
}

test "repairToolCallArguments: valid JSON is returned borrowed, not copied" {
    const raw =
        \\{"path":"/tmp/a.go","old_str":"x","new_str":"y"}
    ;
    const out = (try repairToolCallArguments(testing.allocator, raw)).?;
    try testing.expect(out == .borrowed);
    try testing.expectEqual(@intFromPtr(raw.ptr), @intFromPtr(out.slice().ptr));
    out.deinit(testing.allocator); // borrowed: must not free `raw`
}

test "repairToolCallArguments: repairable Windows arguments come back fixed" {
    const raw =
        \\{"path":"C:\Users\me\a.go","old_str":"x","new_str":"y"}
    ;
    const out = (try repairToolCallArguments(testing.allocator, raw)).?;
    defer out.deinit(testing.allocator);
    try testing.expect(out == .owned);
    try testing.expect(parsesAsJson(out.slice()));
}

test "repairToolCallArguments: unrepairable arguments return null instead of a fake {}" {
    // A truncated object (max_tokens cut mid-call) and a markdown fence are
    // not backslash problems.
    try testing.expect((try repairToolCallArguments(testing.allocator, "{\"path\":\"/tmp/a.go\",\"old_str\":")) == null);
    try testing.expect((try repairToolCallArguments(testing.allocator, "```json\n{\"path\":\"/tmp/a.go\"}\n```")) == null);
}

test "repairToolCallArguments: empty arguments stay a valid empty object" {
    const out = (try repairToolCallArguments(testing.allocator, "{}")).?;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("{}", out.slice());
}
