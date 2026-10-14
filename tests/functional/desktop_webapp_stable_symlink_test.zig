// Functional tests for the stable `--static-dir` alias (`<base>/current`).
// Zig port of `tests/functional/desktop_webapp_stable_symlink_test.py` (same
// test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// The response body as text (the harness body is always valid UTF-8 —
/// HTTP bodies here are text or base64, never raw binary).
fn text(r: *const harness.Response) []const u8 {
    return r.text();
}

/// Minimal stand-in for one versioned webapp dir. Python took `(root, body)`
/// and created `root/assets`, `root/index.html` and `root/assets/app.js`.
fn makeVersion(root: []const u8, body: []const u8) !void {
    const assets = try std.fs.path.join(gpa, &.{ root, "assets" });
    defer gpa.free(assets);
    try std.Io.Dir.cwd().createDirPath(io, assets);

    const index = try std.fs.path.join(gpa, &.{ root, "index.html" });
    defer gpa.free(index);
    {
        const html = try std.fmt.allocPrint(
            gpa,
            "<!DOCTYPE html><html><body>{s}</body></html>",
            .{body},
        );
        defer gpa.free(html);
        var f = try std.Io.Dir.cwd().createFile(io, index, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, html);
    }

    const app_js = try std.fs.path.join(gpa, &.{ assets, "app.js" });
    defer gpa.free(app_js);
    var f = try std.Io.Dir.cwd().createFile(io, app_js, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "console.log('pabrik');");
}

/// Whether this host lets an unprivileged process create a symlink. On
/// Windows a symlink needs either Developer Mode or
/// `SeCreateSymbolicLinkPrivilege`.
fn symlinkSupported(link_path: []const u8, target: []const u8) bool {
    const probe = std.fmt.allocPrint(gpa, "{s}.probe", .{link_path}) catch return false;
    defer gpa.free(probe);
    std.Io.Dir.cwd().symLink(io, target, probe, .{ .is_directory = true }) catch return false;
    std.Io.Dir.cwd().deleteFile(io, probe) catch {};
    return true;
}

/// Create the stable link `<base>/current` pointing at `target_name`
/// (a RELATIVE name, resolved inside `<base>` — the same shape the
/// desktop writes).
fn createLink(link_path: []const u8, target_name: []const u8) !void {
    try std.Io.Dir.cwd().symLink(io, target_name, link_path, .{ .is_directory = true });
}

/// Atomically point `link_path` at `target_name` (same dance as the desktop's
/// `extraction.zig`): create a uniquely-named sibling link, then `rename` it
/// over the stable one, so a reader never observes a moment where `current`
fn pointLink(link_path: []const u8, target_name: []const u8) !void {
    const tmp = try std.fmt.allocPrint(
        gpa,
        "{s}.tmp-{d}",
        .{ link_path, std.Thread.getCurrentId() },
    );
    defer gpa.free(tmp);

    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().symLink(io, target_name, tmp, .{ .is_directory = true });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), link_path, io);
}

// ============================================================================
// Test 1
// ============================================================================

// Booting with `--static-dir <base>/current` serves the app.
test "stable_symlink_serves_the_app" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    const v1 = try std.fs.path.join(gpa, &.{ base, "hash-v1" });
    defer gpa.free(v1);
    const stable = try std.fs.path.join(gpa, &.{ base, "current" });
    defer gpa.free(stable);

    try makeVersion(v1, "stable shell v1");

    if (!symlinkSupported(stable, "hash-v1")) {
        std.debug.print(
            "this host cannot create a symlink; the product's stable-webapp layout requires one\n",
            .{},
        );
        return error.SkipZigTest;
    }
    try createLink(stable, "hash-v1");

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &.{ "--static-dir", stable },
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }
    {
        var r = try h.http(io, .GET, "/health", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
}

// ============================================================================
// Test 2
// ============================================================================

// An upgrade flip keeps the old daemon on its boot version (no 404
// window), while a fresh boot on the same stable string gets the new one.
test "flipping_the_stable_link_never_404s_the_running_daemon" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    const v1 = try std.fs.path.join(gpa, &.{ base, "hash-v1" });
    defer gpa.free(v1);
    const v2 = try std.fs.path.join(gpa, &.{ base, "hash-v2" });
    defer gpa.free(v2);
    const stable = try std.fs.path.join(gpa, &.{ base, "current" });
    defer gpa.free(stable);

    try makeVersion(v1, "stable shell v1");
    try makeVersion(v2, "stable shell v2");

    if (!symlinkSupported(stable, "hash-v1")) {
        std.debug.print(
            "this host cannot create a symlink; the product's stable-webapp layout requires one\n",
            .{},
        );
        return error.SkipZigTest;
    }
    try createLink(stable, "hash-v1");

    var first = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &.{ "--static-dir", stable },
    });
    defer first.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try first.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }

    // Upgrade: flip the stable link. The running daemon stays pinned to
    // its boot version — critically, it must NOT 404 in between.
    try pointLink(stable, "hash-v2");
    {
        var r = try first.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }

    // A fresh boot on the SAME stable string picks up the new version.
    {
        var second = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &.{ "--static-dir", stable },
        });
        defer second.deinit(io) catch |err| {
            std.debug.print("second teardown: {s}\n", .{@errorName(err)});
        };

        var r = try second.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v2") != null);
    }
}
