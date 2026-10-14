const std = @import("std");


/// Helper to get pabrik data directory (~/local/share/pabrik/data/apps)
pub fn getDataAppsDir(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) ![]u8 {
    _ = io;
    // On POSIX systems, the canonical user-home env var is `HOME`.
    const home = blk: {
        if (environment.get("HOME")) |h| {
            if (h.len > 0) break :blk h;
        }
        if (environment.get("USERPROFILE")) |u| {
            if (u.len > 0) break :blk u;
        }
        return error.HomeNotFound;
    };
    return std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "pabrik",
        "data",
        "apps",
    });
}

test "getDataAppsDir uses HOME when set" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/testuser");
    try env_map.put("USERPROFILE", "C:\\Users\\testuser");

    const result = try getDataAppsDir(allocator, std.testing.io, &env_map);
    defer allocator.free(result);

    const expected = try std.fs.path.join(allocator, &[_][]const u8{
        "/home/testuser", ".local", "share", "pabrik", "data", "apps",
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "getDataAppsDir falls back to USERPROFILE when HOME is missing" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    // No HOME at all — native Windows cmd/pwsh case.
    try env_map.put("USERPROFILE", "C:\\Users\\testuser");

    const result = try getDataAppsDir(allocator, std.testing.io, &env_map);
    defer allocator.free(result);

    const expected = try std.fs.path.join(allocator, &[_][]const u8{
        "C:\\Users\\testuser", ".local", "share", "pabrik", "data", "apps",
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "getDataAppsDir falls back to USERPROFILE when HOME is empty" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "");
    try env_map.put("USERPROFILE", "C:\\Users\\testuser");

    const result = try getDataAppsDir(allocator, std.testing.io, &env_map);
    defer allocator.free(result);

    const expected = try std.fs.path.join(allocator, &[_][]const u8{
        "C:\\Users\\testuser", ".local", "share", "pabrik", "data", "apps",
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}

test "getDataAppsDir returns HomeNotFound when HOME and USERPROFILE are both missing" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const result = getDataAppsDir(allocator, std.testing.io, &env_map);
    try std.testing.expectError(error.HomeNotFound, result);
}
