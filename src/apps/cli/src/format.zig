//! Pretty-printer for CLI output.

const std = @import("std");

pub fn prettyJson(
    allocator: std.mem.Allocator,
    options: std.json.Stringify.Options,
    value: anytype,
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.json.Stringify.value(value, options, &aw.writer);
    return aw.toOwnedSlice();
}

test "prettyJson: encodes a struct" {
    const S = struct { id: []const u8, status: []const u8 };
    const v = S{ .id = "session-1", .status = "send" };
    const out = try prettyJson(testing.allocator, .{ .whitespace = .indent_2 }, v);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"session-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"send\"") != null);
}

test "prettyJson: encodes a std.json.Value" {
    // `parseFromSliceLeaky` leaks the inner strings/slices — the test would
    // crash the debug allocator. Switch to `parseFromSlice` + an arena so we
    // can free everything in one shot via `Parsed.deinit`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"k\":1}",
        .{},
    );
    defer parsed.deinit();
    const out = try prettyJson(testing.allocator, .{ .whitespace = .indent_2 }, parsed.value);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"k\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1") != null);
}

const testing = std.testing;