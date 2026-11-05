const std = @import("std");

pub fn appendEscaped(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0...0x1f => {},
            else => try out.append(allocator, c),
        }
    }
}

pub fn appendQuoted(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    try out.append(allocator, '"');
    try appendEscaped(out, allocator, text);
    try out.append(allocator, '"');
}

const testing = std.testing;

test "a quote and a backslash are escaped so the value stays one JSON string" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendQuoted(&out, testing.allocator, "a\"b\\c");

    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", out.items);
}

test "an unprintable byte never reaches the JSON text" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendQuoted(&out, testing.allocator, "a\x07b");

    try testing.expectEqualStrings("\"ab\"", out.items);
}
