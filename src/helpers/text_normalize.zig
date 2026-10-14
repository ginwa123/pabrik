//! Cross-platform source-text normalization for static-contract tests.

const std = @import("std");

/// Replace every `\r\n` in `source` with `\n`. The returned buffer is
/// heap-allocated and owned by the caller; `source` is read-only.
pub fn normalizeLineEndings(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // Count the `\r\n` pairs so we know exactly how much to allocate. Bare
    // `\r` (not followed by `\n`) is preserved — Mac Classic-era files use
    // bare `\r` as a line ending and we should not corrupt them.
    var crlf_count: usize = 0;
    var i: usize = 0;
    while (i + 1 < source.len) {
        if (source[i] == '\r' and source[i + 1] == '\n') {
            crlf_count += 1;
            i += 2;
        } else {
            i += 1;
        }
    }

    // Fast path: no CRLF → just dupe. Caller still owns the result.
    if (crlf_count == 0) {
        return try allocator.dupe(u8, source);
    }

    // Output is shorter by `crlf_count` bytes (one `\r` removed per
    // CRLF pair; the `\n` stays). Bare `\r` adds back its own byte.
    const out = try allocator.alloc(u8, source.len - crlf_count);
    errdefer allocator.free(out);

    var dst: usize = 0;
    var j: usize = 0;
    while (j < source.len) {
        if (j + 1 < source.len and source[j] == '\r' and source[j + 1] == '\n') {
            out[dst] = '\n';
            j += 2;
            dst += 1;
        } else {
            out[dst] = source[j];
            j += 1;
            dst += 1;
        }
    }

    return out[0..dst];
}

// ─── The impl/tests boundary ───────────────────────────────────────────────

/// The first marker a test suite carries once it is merged into its
/// implementation file. Must stay byte-identical to the marker the 2026-09-29
/// flatten writes (`// ===== Tests merged from <file> (YYYY-MM-DD flatten) =====`).
pub const merged_tests_marker = "// ===== Tests merged from";

/// Slice a source file down to its IMPLEMENTATION half: everything before the
/// first `merged_tests_marker`. A static-contract test greps its own file's
/// source for a needle.
pub fn implementationOnly(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const end = std.mem.indexOf(u8, source, merged_tests_marker) orelse source.len;
    return try allocator.dupe(u8, source[0..end]);
}


// ─── Tests for the helper itself ────────────────────────────────────────────

test "normalizeLineEndings: LF input unchanged" {
    const allocator = std.testing.allocator;
    const input = "line one\nline two\nline three\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "normalizeLineEndings: CRLF input → LF output" {
    const allocator = std.testing.allocator;
    const input = "line one\r\nline two\r\nline three\r\n";
    const expected = "line one\nline two\nline three\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
    // Length must shrink by exactly 3 (one \r per CRLF).
    try std.testing.expectEqual(@as(usize, expected.len), result.len);
}

test "normalizeLineEndings: mixed endings" {
    const allocator = std.testing.allocator;
    // 2 CRLF + 1 LF + 1 bare CR + 1 LF
    const input = "a\r\nb\nc\rd\n";
    const expected = "a\nb\nc\rd\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "normalizeLineEndings: empty input" {
    const allocator = std.testing.allocator;
    const result = try normalizeLineEndings(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "normalizeLineEndings: trailing \\r without following \\n" {
    // Stray \r at end of file (some Mac Classic-era files have this).
    // Should be preserved as-is.
    const allocator = std.testing.allocator;
    const input = "hello\r";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\r", result);
    try std.testing.expectEqual(@as(usize, 6), result.len);
}

test "normalizeLineEndings: lone \\n (Unix) and \\r\\n (Windows) coexist" {
    const allocator = std.testing.allocator;
    const input = "before\r\nmiddle\nafter\r\n";
    const expected = "before\nmiddle\nafter\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "implementationOnly: file with no marker is returned whole" {
    const allocator = std.testing.allocator;
    const input = "pub fn a() void {}\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "implementationOnly: truncates at the first merged-tests marker" {
    const allocator = std.testing.allocator;
    const input =
        "pub fn a() void {}\n" ++
        merged_tests_marker ++
        " x_test.zig (2026-09-29 flatten) =====\n" ++
        "test \"a still calls a\" { _ = a; }\n" ++
        merged_tests_marker ++
        " y_test.zig (2026-09-29 flatten) =====\n" ++
        "test \"b\" {}\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("pub fn a() void {}\n", result);
}

test "implementationOnly: the test half is what it removes" {
    const allocator = std.testing.allocator;
    const input =
        "pub fn a() void {}\n" ++
        merged_tests_marker ++
        " x_test.zig (2026-09-29 flatten) =====\n" ++
        "const needle = \"needle\";\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    // The point of the helper: a needle that only appears in the test half
    // must NOT be findable in the sliced result.
    try std.testing.expect(std.mem.indexOf(u8, result, "needle") == null);
}
