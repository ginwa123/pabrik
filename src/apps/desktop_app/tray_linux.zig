// src/apps/desktop_app/tray_linux.zig
// Linux tray backend: a StatusNotifierItem via libayatana-appindicator (so
// Wayland-first shells show it), falling back to the GTK3 GtkStatusIcon.

const std = @import("std");
const tray = @import("tray.zig");

const GtkStatusIcon = opaque {};
const AppIndicator = opaque {};

const app_id = "pabrik";
const app_title = "Pabrik";
const category_application_status: c_int = 0;
const status_active: c_int = 1;

// ---------------------------------------------------------------------------
// C API (GTK3 is already a link-time dependency of pabrik-desktop on Linux)

extern "c" fn gtk_status_icon_new_from_file(filename: [*:0]const u8) ?*GtkStatusIcon;
extern "c" fn gtk_status_icon_new_from_icon_name(icon_name: [*:0]const u8) ?*GtkStatusIcon;
extern "c" fn gtk_status_icon_set_visible(icon: *GtkStatusIcon, visible: c_int) void;
extern "c" fn gtk_status_icon_set_tooltip_text(icon: *GtkStatusIcon, text: [*:0]const u8) void;
extern "c" fn gtk_menu_new() ?*anyopaque;
extern "c" fn gtk_menu_item_new_with_label(label: [*:0]const u8) ?*anyopaque;
extern "c" fn gtk_menu_shell_append(shell: *anyopaque, child: *anyopaque) void;
extern "c" fn gtk_widget_show_all(widget: *anyopaque) void;
extern "c" fn gtk_menu_popup_at_pointer(menu: *anyopaque, trigger_event: ?*anyopaque) void;
extern "c" fn gtk_window_present(window: *anyopaque) void;
extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*const anyopaque,
    connect_flags: c_int,
) c_ulong;

const ActivatedFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
const PopupMenuFn = *const fn (?*anyopaque, c_uint, c_uint, ?*anyopaque) callconv(.c) void;

fn connectActivate(instance: *anyopaque, handler: ActivatedFn, data: ?*anyopaque) void {
    _ = g_signal_connect_data(instance, "activate", @ptrCast(handler), data, null, 0);
}

fn connectPopupMenu(instance: *anyopaque, handler: PopupMenuFn) void {
    _ = g_signal_connect_data(instance, "popup-menu", @ptrCast(handler), null, null, 0);
}

// ---------------------------------------------------------------------------
// AyatanaAppIndicator / AppIndicator, resolved at runtime so the binary does
// not acquire a hard dependency on a library many distros ship elsewhere.

const NewWithPathFn = *const fn ([*:0]const u8, [*:0]const u8, c_int, [*:0]const u8) callconv(.c) ?*AppIndicator;
const SetStatusFn = *const fn (*AppIndicator, c_int) callconv(.c) void;
const SetMenuFn = *const fn (*AppIndicator, ?*anyopaque) callconv(.c) void;
const SetTitleFn = *const fn (*AppIndicator, [*:0]const u8) callconv(.c) void;

const AppIndicatorApi = struct {
    new_with_path: NewWithPathFn,
    set_status: SetStatusFn,
    set_menu: SetMenuFn,
    set_title: SetTitleFn,
};

/// Sonames, Ayatana first — the maintained fork is what current distros ship.
const app_indicator_libraries = [_][]const u8{
    "libayatana-appindicator3.so.1",
    "libappindicator3.so.1",
};

pub const Kind = enum { app_indicator, status_icon };

/// Which backends to try, best first. AppIndicator covers Wayland and every
/// shell that speaks StatusNotifierItem; GtkStatusIcon only works where an
/// XEmbed tray exists, so it is reached only when the library is absent.
pub fn kindOrder(app_indicator_loaded: bool) []const Kind {
    return if (app_indicator_loaded) &.{ .app_indicator, .status_icon } else &.{.status_icon};
}

/// Where an AppIndicator looks for its icon: the SNI spec resolves
/// `IconName` inside `IconThemePath`, while hosts that accept a file path
/// read the absolute name directly — this backend advertises both.
pub const IconRef = struct { name: []const u8, theme_path: []const u8 };

pub fn iconRef(path: []const u8) IconRef {
    return .{
        .name = path,
        .theme_path = std.fs.path.dirname(path) orelse ".",
    };
}

pub const InstallError = error{TrayUnavailable};

/// Menu-item context that lives as long as the process (there is exactly one
/// tray per process, so a fixed table beats an allocation).
const Slot = struct {
    action: tray.Action,
    handler: tray.Handler,
};

var g_handler: ?tray.Handler = null;
var g_menu: ?*anyopaque = null;
var slots: [tray.menu.len]Slot = undefined;
var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
var name_buf: [std.fs.max_path_bytes:0]u8 = undefined;
/// Held only to keep the shared object mapped for the life of the process.
var indicator_lib: ?std.DynLib = null;
var indicator_api: ?AppIndicatorApi = null;

pub fn install(handler: tray.Handler, icon: tray.IconSource) InstallError!void {
    g_handler = handler;
    const menu = gtk_menu_new() orelse return error.TrayUnavailable;
    if (!buildMenu(menu, handler)) return error.TrayUnavailable;
    g_menu = menu;

    const api = loadAppIndicator();
    for (kindOrder(api != null)) |kind| {
        const started = switch (kind) {
            .app_indicator => if (api) |loaded| startAppIndicator(loaded, menu, icon) else false,
            .status_icon => startStatusIcon(icon),
        };
        if (started) return;
    }
    return error.TrayUnavailable;
}

pub fn presentNativeWindow(native: ?*anyopaque) void {
    gtk_window_present(native orelse return);
}

fn buildMenu(menu: *anyopaque, handler: tray.Handler) bool {
    for (tray.menu, 0..) |action, i| {
        const item = gtk_menu_item_new_with_label(action.label().ptr) orelse return false;
        slots[i] = .{ .action = action, .handler = handler };
        connectActivate(item, itemActivated, &slots[i]);
        gtk_menu_shell_append(menu, item);
    }
    gtk_widget_show_all(menu);
    return true;
}

fn itemActivated(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const slot: *const Slot = @ptrCast(@alignCast(data orelse return));
    slot.handler.dispatch(slot.action);
}

fn statusIconActivated(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (g_handler) |handler| handler.dispatch(.show_window);
}

fn statusIconPopupMenu(_: ?*anyopaque, _: c_uint, _: c_uint, _: ?*anyopaque) callconv(.c) void {
    gtk_menu_popup_at_pointer(g_menu orelse return, null);
}

fn startStatusIcon(icon: tray.IconSource) bool {
    const status_icon = makeStatusIcon(icon) orelse return false;
    gtk_status_icon_set_tooltip_text(status_icon, app_title);
    gtk_status_icon_set_visible(status_icon, 1);
    connectActivate(status_icon, statusIconActivated, null);
    connectPopupMenu(status_icon, statusIconPopupMenu);
    return true;
}

fn makeStatusIcon(icon: tray.IconSource) ?*GtkStatusIcon {
    return switch (icon) {
        .file => |path| if (z(&path_buf, path)) |path_z|
            gtk_status_icon_new_from_file(path_z)
        else
            null,
        .theme => |name| if (z(&name_buf, name)) |name_z|
            gtk_status_icon_new_from_icon_name(name_z)
        else
            null,
    };
}

fn startAppIndicator(api: AppIndicatorApi, menu: *anyopaque, icon: tray.IconSource) bool {
    const indicator = switch (icon) {
        .file => |path| blk: {
            const ref = iconRef(path);
            const theme_path_z = z(&path_buf, ref.theme_path) orelse break :blk null;
            const name_z = z(&name_buf, ref.name) orelse break :blk null;
            break :blk api.new_with_path(app_id, name_z, category_application_status, theme_path_z);
        },
        .theme => |name| if (z(&name_buf, name)) |name_z|
            api.new_with_path(app_id, name_z, category_application_status, "")
        else
            null,
    } orelse return false;

    api.set_title(indicator, app_title);
    api.set_status(indicator, status_active);
    api.set_menu(indicator, menu);
    return true;
}

fn loadAppIndicator() ?AppIndicatorApi {
    if (indicator_api) |api| return api;
    for (app_indicator_libraries) |soname| {
        var lib = std.DynLib.open(soname) catch continue;
        const api = AppIndicatorApi{
            .new_with_path = lib.lookup(NewWithPathFn, "app_indicator_new_with_path") orelse {
                lib.close();
                continue;
            },
            .set_status = lib.lookup(SetStatusFn, "app_indicator_set_status") orelse {
                lib.close();
                continue;
            },
            .set_menu = lib.lookup(SetMenuFn, "app_indicator_set_menu") orelse {
                lib.close();
                continue;
            },
            .set_title = lib.lookup(SetTitleFn, "app_indicator_set_title") orelse {
                lib.close();
                continue;
            },
        };
        indicator_lib = lib;
        indicator_api = api;
        return api;
    }
    return null;
}

fn z(buf: *[std.fs.max_path_bytes:0]u8, value: []const u8) ?[*:0]const u8 {
    if (value.len >= buf.len) return null;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    return buf[0..value.len :0].ptr;
}

const testing = std.testing;

test "AppIndicator is tried first when it loads, and is not tried when it does not" {
    try testing.expectEqualSlices(Kind, &.{ .app_indicator, .status_icon }, kindOrder(true));
    try testing.expectEqualSlices(Kind, &.{.status_icon}, kindOrder(false));
}

test "a file icon is advertised by its own path, with its directory as the theme path" {
    const ref = iconRef("/home/u/.cache/pabrik/webapp/apple-touch-icon.png");
    try testing.expectEqualStrings("/home/u/.cache/pabrik/webapp/apple-touch-icon.png", ref.name);
    try testing.expectEqualStrings("/home/u/.cache/pabrik/webapp", ref.theme_path);
}

test "an icon name without a directory is advertised against the current directory" {
    const ref = iconRef("pabrik.png");
    try testing.expectEqualStrings("pabrik.png", ref.name);
    try testing.expectEqualStrings(".", ref.theme_path);
}
