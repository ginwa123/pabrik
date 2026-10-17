// src/apps/desktop_app/tray.zig Platform-independent part of the desktop
// app's system-tray icon: the menu entries, what a click means, and where
// the icon comes from. The per-OS backends render this model.

const std = @import("std");
const builtin = @import("builtin");

/// A thing the user can ask for from the tray menu.
pub const Action = enum {
    show_window,
    open_in_browser,
    quit,

    /// Stable identifier for the action — the backend maps a native menu
    /// item back to this, so it must not be a display string.
    pub fn id(self: Action) [:0]const u8 {
        return switch (self) {
            .show_window => "show",
            .open_in_browser => "browser",
            .quit => "quit",
        };
    }

    /// What the user reads in the menu (sentinel-terminated for the C APIs).
    pub fn label(self: Action) [:0]const u8 {
        return switch (self) {
            .show_window => "Show Pabrik",
            .open_in_browser => "Open in Browser",
            .quit => "Quit Pabrik",
        };
    }
};

/// The tray menu, top to bottom. Order is the render order.
pub const menu = [_]Action{ .show_window, .open_in_browser, .quit };

pub fn actionFor(id: []const u8) ?Action {
    for (menu) |action| {
        if (std.mem.eql(u8, id, action.id())) return action;
    }
    return null;
}

/// What the tray does when an action fires. `ctx` is owned by the caller.
pub const Handler = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, action: Action) void,

    pub fn dispatch(self: Handler, action: Action) void {
        self.on(self.ctx, action);
    }
};

pub const IconSource = union(enum) {
    /// Load this image file.
    file: []const u8,
    /// Look this name up in the desktop icon theme.
    theme: []const u8,
};

/// Icon-theme name to fall back to when no image file on disk resolves.
pub const theme_icon = "pabrik";

/// The PNG the desktop app already materialises next to index.html; using
/// it means the tray shows the real brand mark with no extra asset.
pub const webapp_icon_file = "apple-touch-icon.png";

/// Pick the icon: an explicit `--icon` wins, then the webapp's own icon,
/// then the icon-theme name. A returned `.file` may point into `buf`, so
/// `buf` must outlive the result.
pub fn resolveIcon(
    explicit: ?[]const u8,
    webapp_dir: []const u8,
    exists: *const fn (path: []const u8) bool,
    buf: []u8,
) IconSource {
    if (explicit) |path| {
        if (exists(path)) return .{ .file = path };
    }
    if (joinIconPath(webapp_dir, buf)) |candidate| {
        if (exists(candidate)) return .{ .file = candidate };
    }
    return .{ .theme = theme_icon };
}

/// `<webapp_dir>/apple-touch-icon.png`, with exactly one separator. Null
/// when the directory is empty or does not fit in `buf`.
pub fn joinIconPath(webapp_dir: []const u8, buf: []u8) ?[]const u8 {
    const dir = std.mem.trimEnd(u8, webapp_dir, "/");
    if (dir.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, webapp_icon_file }) catch null;
}

// The tray is a POSIX-desktop concept here: Windows keeps its existing
// title-bar behaviour, so the facade selects a no-op backend there.
pub const Backend = switch (builtin.os.tag) {
    .linux => @import("tray_linux.zig"),
    .macos => @import("tray_macos.zig"),
    else => @import("tray_unsupported.zig"),
};

pub const InstallError = Backend.InstallError;

pub fn install(handler: Handler, icon: IconSource) InstallError!void {
    return Backend.install(handler, icon);
}

/// Bring the native window to the front. `native` is whatever
/// `webview_lib.webview_get_window` returned.
pub fn presentNativeWindow(native: ?*anyopaque) void {
    return Backend.presentNativeWindow(native);
}

const testing = std.testing;

var existing: []const []const u8 = &.{};

fn existsInSet(path: []const u8) bool {
    for (existing) |known| {
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

test "every menu entry keeps a distinct id that maps back to it" {
    for (menu, 0..) |action, i| {
        try testing.expectEqual(action, actionFor(action.id()).?);
        for (menu[0..i]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier.id(), action.id()));
        }
    }
}

test "the menu offers exactly one way to quit, and it is the last entry" {
    var quits: usize = 0;
    for (menu) |action| {
        if (action == .quit) quits += 1;
    }
    try testing.expectEqual(@as(usize, 1), quits);
    try testing.expectEqual(Action.quit, menu[menu.len - 1]);
}

test "an unknown menu id maps to no action" {
    try testing.expectEqual(@as(?Action, null), actionFor(""));
    try testing.expectEqual(@as(?Action, null), actionFor("Quit Pabrik"));
    try testing.expectEqual(@as(?Action, null), actionFor("quit "));
}

test "every menu entry carries a non-empty label" {
    for (menu) |action| {
        try testing.expect(action.label().len > 0);
    }
}

/// The `.file` path of `icon`, or a plain test failure — reading the union
/// field directly would abort the whole binary on a tag mismatch.
fn expectFileIcon(icon: IconSource) ![]const u8 {
    return switch (icon) {
        .file => |path| path,
        .theme => error.ExpectedFileIcon,
    };
}

test "an existing --icon file is the tray icon" {
    var buf: [64]u8 = undefined;
    existing = &.{"/opt/pabrik/pabrik.png"};
    defer existing = &.{};

    try testing.expectEqualStrings(
        "/opt/pabrik/pabrik.png",
        try expectFileIcon(resolveIcon("/opt/pabrik/pabrik.png", "/webapp", existsInSet, &buf)),
    );
}

test "a missing --icon falls back to the webapp's own icon" {
    var buf: [64]u8 = undefined;
    existing = &.{"/webapp/apple-touch-icon.png"};
    defer existing = &.{};

    try testing.expectEqualStrings(
        "/webapp/apple-touch-icon.png",
        try expectFileIcon(resolveIcon("/opt/absent.png", "/webapp", existsInSet, &buf)),
    );
}

test "with no image on disk the icon falls back to the theme name" {
    var buf: [64]u8 = undefined;
    existing = &.{};
    defer existing = &.{};

    switch (resolveIcon(null, "/webapp", existsInSet, &buf)) {
        .theme => |name| try testing.expectEqualStrings(theme_icon, name),
        .file => return error.ExpectedThemeIcon,
    }
}

test "the webapp icon path is joined with exactly one separator" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/webapp/apple-touch-icon.png", joinIconPath("/webapp", &buf).?);
    try testing.expectEqualStrings("/webapp/apple-touch-icon.png", joinIconPath("/webapp/", &buf).?);
    try testing.expectEqualStrings("/webapp/apple-touch-icon.png", joinIconPath("/webapp//", &buf).?);
}

test "an empty webapp directory yields no icon path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), joinIconPath("", &buf));
}
