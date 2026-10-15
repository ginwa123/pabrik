const std = @import("std");

/// Sanitizes UTF-8 input by replacing invalid byte sequences with replacement characters.
pub fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const b = input[i];

        // ASCII (0x00-0x7F) - valid
        if (b < 0x80) {
            try result.append(allocator, b);
            i += 1;
            continue;
        }

        // Determine expected sequence length and validate
        const seq_len: usize = if (b & 0xE0 == 0xC0) 2 // 0x80-0xBF follow bytes
            else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else {
                // Invalid start byte - replacement character U+FFFD (EF BF BD)
                try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
                i += 1;
                continue;
            };

        // Check if we have enough bytes
        if (i + seq_len > input.len) {
            // Incomplete sequence - replacement character U+FFFD (EF BF BD)
            try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
            i += 1;
            continue;
        }

        // Validate all continuation bytes (0x80-0xBF)
        var valid = true;
        for (1..seq_len) |j| {
            if (input[i + j] & 0xC0 != 0x80) {
                valid = false;
                break;
            }
        }

        if (valid) {
            // Valid UTF-8 sequence
            try result.appendSlice(allocator, input[i .. i + seq_len]);
        } else {
            // Invalid sequence - replacement character U+FFFD (EF BF BD)
            try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBF, 0xBD });
        }

        i += seq_len;
    }

    return result.toOwnedSlice(allocator);
}

/// Sanitize a JSON string by escaping problematic characters
/// Returns allocated slice — caller must free
pub fn sanitizeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => {
                // Already escaped? peek ahead
                if (i + 1 < input.len and (input[i + 1] == 'n' or
                    input[i + 1] == 'r' or
                    input[i + 1] == 't' or
                    input[i + 1] == '"' or
                    input[i + 1] == '\\'))
                {
                    // Valid escape sequence — keep as-is
                    try out.append(allocator, '\\');
                    try out.append(allocator, input[i + 1]);
                    i += 1;
                } else {
                    // Bare backslash — escape it
                    try out.appendSlice(allocator, "\\\\");
                }
            },
            else => try out.append(allocator, input[i]),
        }
    }

    return out.toOwnedSlice(allocator);
}

test "sanitizeUtf8 valid ASCII" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "sanitizeUtf8 valid UTF-8" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "こんにちは世界");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("こんにちは世界", result);
}

test "sanitizeUtf8 invalid start byte" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xFFworld");
    defer allocator.free(result);
    // \xFF is invalid, replaced with U+FFFD (EF BF BD)
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDworld", result);
}

test "sanitizeUtf8 incomplete sequence" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xE4world");
    defer allocator.free(result);
    // \xE4 starts a 3-byte seq but only 1 continuation byte (w=0x77, not 0x80-0xBF)
    // Invalid, replaced with U+FFFD (EF BF BD), then 'rld' remains
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDrld", result);
}

test "sanitizeUtf8 invalid continuation byte" {
    const allocator = std.testing.allocator;
    const result = try sanitizeUtf8(allocator, "hello\xE4\x90world");
    defer allocator.free(result);
    // \xE4\x90 is invalid (0x90 is not valid continuation 0x80-0xBF)
    // Replaced with U+FFFD (EF BF BD), then 'orld' remains
    try std.testing.expectEqualStrings("hello\xEF\xBF\xBDorld", result);
}

/// Sanitize an arbitrary string into a single safe filesystem path component
/// (one folder/file name — never a multi-level path). Replaces `/ \ < > : " |
/// ?
pub fn sanitizePathComponent(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0) return error.InvalidPathComponent;

    var out = try allocator.dupe(u8, input);
    errdefer allocator.free(out);

    for (out) |*b| {
        const c = b.*;
        if (c == '/' or c == '\\' or c == '<' or c == '>' or c == ':' or
            c == '"' or c == '|' or c == '?' or c == '*' or c < 0x20)
        {
            b.* = '_';
        }
    }

    // Windows rejects names ending in dots/spaces — rewrite them.
    // (This also neutralizes "." and "..": they become "_" / "__",
    // both valid leaf names.)
    var end: usize = out.len;
    while (end > 0 and (out[end - 1] == '.' or out[end - 1] == ' ')) {
        out[end - 1] = '_';
        end -= 1;
    }

    if (isWindowsReservedName(out)) {
        const prefixed = try std.fmt.allocPrint(allocator, "_{s}", .{out});
        allocator.free(out);
        return prefixed;
    }

    return out;
}

/// Windows-reserved device names, matched case-insensitively against
/// the stem (before the first '.'): CON, PRN, AUX, NUL, COM1-9, LPT1-9.
/// `mkdir CON` fails on Windows even with an extension (`CON.txt`).
fn isWindowsReservedName(name: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, name, '.')) |i| name[0..i] else name;
    const reserved = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5",
        "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5",
        "LPT6", "LPT7", "LPT8", "LPT9",
    };
    for (reserved) |r| {
        if (std.ascii.eqlIgnoreCase(stem, r)) return true;
    }
    return false;
}

test "sanitizePathComponent leaves safe names untouched" {
    const allocator = std.testing.allocator;
    const result = try sanitizePathComponent(allocator, "sess_1788360596_abcdef1234567890");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("sess_1788360596_abcdef1234567890", result);
}

test "sanitizePathComponent replaces separators and traversal" {
    const allocator = std.testing.allocator;
    const result = try sanitizePathComponent(allocator, "../../etc/passwd");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".._.._etc_passwd", result);
}

test "sanitizePathComponent replaces backslashes and reserved chars" {
    const allocator = std.testing.allocator;
    const result = try sanitizePathComponent(allocator, "a\\b<c>d:e\"f|g?h*i");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a_b_c_d_e_f_g_h_i", result);
}

test "sanitizePathComponent replaces control bytes" {
    const allocator = std.testing.allocator;
    const result = try sanitizePathComponent(allocator, "ab\x01\x1fcd");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ab__cd", result);
}

test "sanitizePathComponent rewrites trailing dots and spaces" {
    const allocator = std.testing.allocator;
    const dotted = try sanitizePathComponent(allocator, "session-123.");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("session-123_", dotted);

    const spaced = try sanitizePathComponent(allocator, "session-123 ");
    defer allocator.free(spaced);
    try std.testing.expectEqualStrings("session-123_", spaced);
}

test "sanitizePathComponent neutralizes dot-only names" {
    const allocator = std.testing.allocator;
    const dot = try sanitizePathComponent(allocator, ".");
    defer allocator.free(dot);
    try std.testing.expectEqualStrings("_", dot);

    const dotdot = try sanitizePathComponent(allocator, "..");
    defer allocator.free(dotdot);
    try std.testing.expectEqualStrings("__", dotdot);
}

test "sanitizePathComponent prefixes Windows device names" {
    const allocator = std.testing.allocator;
    const con = try sanitizePathComponent(allocator, "CON");
    defer allocator.free(con);
    try std.testing.expectEqualStrings("_CON", con);

    const com_lower = try sanitizePathComponent(allocator, "com1");
    defer allocator.free(com_lower);
    try std.testing.expectEqualStrings("_com1", com_lower);

    const nul_ext = try sanitizePathComponent(allocator, "NUL.txt");
    defer allocator.free(nul_ext);
    try std.testing.expectEqualStrings("_NUL.txt", nul_ext);

    // Non-reserved names with similar prefixes are untouched.
    const console = try sanitizePathComponent(allocator, "console");
    defer allocator.free(console);
    try std.testing.expectEqualStrings("console", console);
}

test "sanitizePathComponent rejects empty input" {
    const allocator = std.testing.allocator;
    const result = sanitizePathComponent(allocator, "");
    try std.testing.expectError(error.InvalidPathComponent, result);
}
