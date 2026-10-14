const std = @import("std");

pub fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            // XML 1.0 forbids C0 controls except \t \n \r, plus DEL. Binary
            // stdout (e.g.
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try result.appendSlice(allocator, "�"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Replace bytes that are illegal in both XML 1.0 and JSON strings with
/// U+FFFD: NUL, C0 controls except \t \n \r, and DEL.
pub fn sanitizeControlChars(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try result.appendSlice(allocator, "�"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

test "sanitizeControlChars replaces NUL/C0/DEL, leaves text and entities alone" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x7F, 'E', 'L', 'F', 0x00, 0x01, '\t', '\n', '<', '&' };
    const out = try sanitizeControlChars(allocator, &input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x00") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ELF") != null);
    // < and & are NOT escaped — JSON handles them natively.
    try std.testing.expect(std.mem.indexOf(u8, out, "<") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&") != null);
    // \t \n pass through.
    try std.testing.expect(std.mem.indexOf(u8, out, "\t") != null);
}
