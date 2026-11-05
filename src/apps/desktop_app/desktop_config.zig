const std = @import("std");
const json_text = @import("json_text.zig");

pub const file_name = "desktop.json";
pub const base_url_key = "base_url";

pub fn pathNextTo(allocator: std.mem.Allocator, state_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(state_path) orelse return error.PathResolutionFailed;
    return std.fs.path.join(allocator, &.{ dir, file_name });
}

pub fn readBaseUrl(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch
        return null;
    defer allocator.free(data);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch
        return null;
    const value = switch (parsed) {
        .object => |object| object.get(base_url_key) orelse return null,
        else => return null,
    };
    const base_url = switch (value) {
        .string => |text| text,
        else => return null,
    };
    if (base_url.len == 0) return null;
    return try allocator.dupe(u8, base_url);
}

pub fn writeBaseUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    base_url: []const u8,
) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.PathResolutionFailed;

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"" ++ base_url_key ++ "\":");
    try json_text.appendQuoted(&json, allocator, base_url);
    try json.appendSlice(allocator, "}\n");

    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len + 4 >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    @memcpy(path_buf[path.len..][0..4], ".tmp");
    path_buf[path.len + 4] = 0;
    const tmp_path: []const u8 = path_buf[0 .. path.len + 4];

    try createParents(io, path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = json.items });
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

pub fn forget(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn createParents(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

const testing = std.testing;

fn tempDirPath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

fn pathIn(dir: []const u8, rest: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, rest });
}

test "a saved base url is read back unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try writeBaseUrl(testing.allocator, testing.io, path, "http://192.168.1.20:8081/pabrik");
    const saved = try readBaseUrl(testing.allocator, testing.io, path);
    defer if (saved) |url| testing.allocator.free(url);

    try testing.expectEqualStrings("http://192.168.1.20:8081/pabrik", saved.?);
}

test "a base url with a quote in its path survives the round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try writeBaseUrl(testing.allocator, testing.io, path, "https://example.com/a\"b");
    const saved = try readBaseUrl(testing.allocator, testing.io, path);
    defer if (saved) |url| testing.allocator.free(url);

    try testing.expectEqualStrings("https://example.com/a\"b", saved.?);
}

test "a desktop that never saved a server reports no base url" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try testing.expectEqual(@as(?[]u8, null), try readBaseUrl(testing.allocator, testing.io, path));
}

test "a corrupt config reports no base url instead of failing the launch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{not json at all" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try testing.expectEqual(@as(?[]u8, null), try readBaseUrl(testing.allocator, testing.io, path));
}

test "a config written by a newer version without a base url reports none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{\"theme\":\"dark\"}" });
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try testing.expectEqual(@as(?[]u8, null), try readBaseUrl(testing.allocator, testing.io, path));
}

test "saving creates the missing parent directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, "nested/deeper/desktop.json", &path_buf);

    try writeBaseUrl(testing.allocator, testing.io, path, "https://pabrik.example.com");
    const saved = try readBaseUrl(testing.allocator, testing.io, path);
    defer if (saved) |url| testing.allocator.free(url);

    try testing.expectEqualStrings("https://pabrik.example.com", saved.?);
}

test "forgetting the server makes the next launch fall back to local" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    try writeBaseUrl(testing.allocator, testing.io, path, "https://pabrik.example.com");
    forget(testing.io, path);

    try testing.expectEqual(@as(?[]u8, null), try readBaseUrl(testing.allocator, testing.io, path));
}

test "forgetting a server that was never saved is harmless" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tempDirPath(&tmp, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathIn(dir, file_name, &path_buf);

    forget(testing.io, path);

    try testing.expectEqual(@as(?[]u8, null), try readBaseUrl(testing.allocator, testing.io, path));
}

test "the desktop config sits next to the service state file" {
    const path = try pathNextTo(testing.allocator, "/home/person/.local/state/pabrik/state.json");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/person/.local/state/pabrik/desktop.json", path);
}

test "a relative config path is refused instead of writing into the cwd" {
    try testing.expectError(
        error.PathResolutionFailed,
        writeBaseUrl(testing.allocator, testing.io, "desktop.json", "https://pabrik.example.com"),
    );
}
