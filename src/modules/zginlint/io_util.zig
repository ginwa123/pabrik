//! File and path helpers for the engine.
//! `std.fs`'s convenience wrappers are gone in Zig 0.16, so an absolute path
//! is routed through the `*Absolute` entry points by hand.

const std = @import("std");

/// Read a whole file, absolute or relative to the process's directory.
pub fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited);
}


/// `dir/name` with a forward slash on every platform, so a report reads the
/// same everywhere.
pub fn join(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, dir, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, name });
}

test "io_util: join keeps a single separator" {
    const testing = std.testing;
    const joined = try join(testing.allocator, "src/", "a.zig");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("src/a.zig", joined);
}

test "io_util: join of an empty directory is the name" {
    const testing = std.testing;
    const joined = try join(testing.allocator, "", "a.zig");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("a.zig", joined);
}
