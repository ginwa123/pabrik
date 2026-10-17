// src/apps/desktop_app/cross_compile_check.zig Cross-target compile check for
// the desktop app's per-OS branches.

const std = @import("std");
const extraction = @import("extraction.zig");
const subprocess = @import("subprocess.zig");
const tray = @import("tray.zig");

const assets = [_]extraction.AssetEntry{
    .{ .path = "/index.html", .content = "<html></html>", .mime = "text/html" },
    .{ .path = "/assets/app.js", .content = "console.log(1)", .mime = "application/javascript" },
};

fn nothingExists(_: []const u8) bool {
    return false;
}

fn ignoreTrayAction(_: *anyopaque, _: tray.Action) void {}

export fn pabrik_desktop_cross_compile_check() callconv(.c) void {
    // Persistent content-addressed dir: `persistentBaseDir` (env + per-OS
    // path joining), the staging/marker publish, `renameAbsolute`'s
    // POSIX-vs-Win32 branches and `pathExistsAbs`'s per-OS existence check.
    const persistent = extraction.ensurePersistent(std.heap.page_allocator, &assets) catch return;
    std.heap.page_allocator.free(persistent);

    const in_base = extraction.ensurePersistentIn(
        std.heap.page_allocator,
        "/tmp/pabrik-xcheck",
        &assets,
    ) catch return;
    std.heap.page_allocator.free(in_base);

    // The legacy per-pid temp-dir path (same write/cleanup helpers).
    const temp = extraction.extract(std.heap.page_allocator, &assets) catch return;
    extraction.cleanup(std.heap.page_allocator, temp);

    // Raw-socket probes: winsock on Windows, libc on POSIX, plus the
    // status/HTML parsing shared by both. Never executed — only analysed.
    if (subprocess.probeHealth(1)) return;
    if (subprocess.probeWebapp(1)) return;
    if (subprocess.waitForHealth(1, 1, 1)) |_| {} else |_| {}
    if (subprocess.terminateByPid(1)) return;

    // The tray: icon resolution in the shared model plus whichever backend
    // this target selects.
    var icon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const icon = tray.resolveIcon("/tmp/pabrik.png", "/tmp/webapp", nothingExists, &icon_buf);
    var sink: u8 = 0;
    tray.install(.{ .ctx = &sink, .on = ignoreTrayAction }, icon) catch {};
    tray.presentNativeWindow(null);
}
