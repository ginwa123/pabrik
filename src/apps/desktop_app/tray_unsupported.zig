// src/apps/desktop_app/tray_unsupported.zig
// Tray backend for platforms the desktop app has no tray implementation for
// (currently Windows, which keeps its existing window chrome only).

const std = @import("std");
const tray = @import("tray.zig");

pub const InstallError = error{TrayUnavailable};

pub fn install(handler: tray.Handler, icon: tray.IconSource) InstallError!void {
    _ = handler;
    _ = icon;
    std.log.warn("No system-tray implementation for this platform — the desktop window is the only way to quit", .{});
    return error.TrayUnavailable;
}

pub fn presentNativeWindow(native: ?*anyopaque) void {
    _ = native;
}
