// Functional tests for the branded app icons.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

fn readRepoFile(path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

/// ICO pixel data starts at byte 62 for the single-image 32x32/32bpp brand
/// file (6-byte header + 16-byte dir entry + 40-byte BITMAPINFOHEADER). The
/// first pixel is the top-left background cell, stored BGRA.
const ICO_PIXEL_OFF = 62;

test "favicon_ico_serves_the_brand_icon_byte_identical" {
    try harness.requirePabrikBin(io, gpa);

    const expected = try readRepoFile("src/apps/desktop/public/favicon.ico");
    defer gpa.free(expected);

    // Sanity on the fixture itself: a one-image ICO with the opaque
    // brand background. If the artwork is ever re-rendered with a
    // different layout this fails fast here, not at the wire assert.
    try testing.expect(expected.len >= ICO_PIXEL_OFF + 4);
    try testing.expectEqual(@as(u8, 0x00), expected[0]);
    try testing.expectEqual(@as(u8, 0x00), expected[1]);
    try testing.expectEqual(@as(u8, 0x01), expected[2]);
    try testing.expectEqual(@as(u8, 0x00), expected[3]);
    try testing.expectEqual(@as(u8, 0xFF), expected[ICO_PIXEL_OFF + 3]);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "icon-webapp" });
    defer gpa.free(webapp_dir);
    try std.Io.Dir.cwd().createDirPath(io, webapp_dir);
    {
        const p = try std.fs.path.join(gpa, &.{ webapp_dir, "index.html" });
        defer gpa.free(p);
        try writeFileAt(p, "<!DOCTYPE html><html><body>pabrik</body></html>");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ webapp_dir, "favicon.ico" });
        defer gpa.free(p);
        try writeFileAt(p, expected);
    }

    const args = [_][]const u8{ "--static-dir", webapp_dir };
    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &args,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/favicon.ico", .{});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    const ct = r.header("content-type") orelse return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, ct, "image/x-icon") == null and
        std.mem.indexOf(u8, ct, "image/vnd.microsoft.icon") == null)
    {
        std.debug.print("unexpected favicon content-type: {s}\n", .{ct});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualSlices(u8, expected, r.body);
}

test "apple_touch_icon_serves_the_brand_png" {
    try harness.requirePabrikBin(io, gpa);

    const expected = try readRepoFile("src/apps/desktop/public/apple-touch-icon.png");
    defer gpa.free(expected);

    // PNG magic, and a plausible (non-trivial) size for a 180x180 icon.
    try testing.expect(expected.len > 1000);
    try testing.expectEqualSlices(
        u8,
        &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A },
        expected[0..8],
    );

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "icon-webapp" });
    defer gpa.free(webapp_dir);
    try std.Io.Dir.cwd().createDirPath(io, webapp_dir);
    {
        const p = try std.fs.path.join(gpa, &.{ webapp_dir, "index.html" });
        defer gpa.free(p);
        try writeFileAt(p, "<!DOCTYPE html><html><body>pabrik</body></html>");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ webapp_dir, "apple-touch-icon.png" });
        defer gpa.free(p);
        try writeFileAt(p, expected);
    }

    const args = [_][]const u8{ "--static-dir", webapp_dir };
    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &args,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/apple-touch-icon.png", .{});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    const ct = r.header("content-type") orelse return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, ct, "image/png") == null) {
        std.debug.print("unexpected apple-touch-icon content-type: {s}\n", .{ct});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualSlices(u8, expected, r.body);
}
