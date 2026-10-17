// src/apps/desktop_app/tray_macos.zig
// macOS tray backend: an NSStatusItem with its NSMenu, built through the
// Objective-C runtime. A runtime class pair forwards clicks into the model.

const std = @import("std");
const tray = @import("tray.zig");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Class = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
extern "c" fn objc_msgSend() callconv(.c) void;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;

/// `objc_msgSend` is variadic in C, so each call site casts it to the
/// concrete signature it is making.
fn send0(comptime Ret: type, target: Id, message: Sel) Ret {
    const Fn = fn (Id, Sel) callconv(.c) Ret;
    const call: *const Fn = @ptrCast(&objc_msgSend);
    return call(target, message);
}

fn send1(comptime Ret: type, comptime A1: type, target: Id, message: Sel, a1: A1) Ret {
    const Fn = fn (Id, Sel, A1) callconv(.c) Ret;
    const call: *const Fn = @ptrCast(&objc_msgSend);
    return call(target, message, a1);
}

fn send2(comptime Ret: type, comptime A1: type, comptime A2: type, target: Id, message: Sel, a1: A1, a2: A2) Ret {
    const Fn = fn (Id, Sel, A1, A2) callconv(.c) Ret;
    const call: *const Fn = @ptrCast(&objc_msgSend);
    return call(target, message, a1, a2);
}

fn send3(
    comptime Ret: type,
    comptime A1: type,
    comptime A2: type,
    comptime A3: type,
    target: Id,
    message: Sel,
    a1: A1,
    a2: A2,
    a3: A3,
) Ret {
    const Fn = fn (Id, Sel, A1, A2, A3) callconv(.c) Ret;
    const call: *const Fn = @ptrCast(&objc_msgSend);
    return call(target, message, a1, a2, a3);
}

fn selector(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

fn class(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// `[X alloc]` then `[.. init]`: one retained object of `name`.
fn create(name: [*:0]const u8) Id {
    const allocated = send0(Id, class(name), selector("alloc")) orelse return null;
    return send0(Id, allocated, selector("init"));
}

const NSSize = extern struct { width: f64, height: f64 };

const app_title = "Pabrik";
/// NSVariableStatusItemLength — the width the menu bar gives a tray icon.
const status_item_variable: f64 = -1.0;
const tray_image_points: f64 = 18;
const clicked_selector = "pabrikTrayClicked:";

pub const InstallError = error{TrayUnavailable};

var g_handler: ?tray.Handler = null;
var g_target: Id = null;
var g_target_class: Class = null;
var text_buf: [128:0]u8 = undefined;
var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

pub fn install(handler: tray.Handler, icon: tray.IconSource) InstallError!void {
    g_handler = handler;
    const target_class = ensureTargetClass() orelse return error.TrayUnavailable;
    const pool = create("NSAutoreleasePool");
    defer {
        if (pool) |handle| _ = send0(void, handle, selector("drain"));
    }

    const allocated = send0(Id, target_class, selector("alloc")) orelse return error.TrayUnavailable;
    g_target = send0(Id, allocated, selector("init")) orelse return error.TrayUnavailable;

    const menu = create("NSMenu") orelse return error.TrayUnavailable;
    for (tray.menu, 0..) |action, i| {
        const item = menuItem(action, @intCast(i)) orelse return error.TrayUnavailable;
        _ = send1(void, Id, menu, selector("addItem:"), item);
    }

    const status_bar = send0(Id, class("NSStatusBar"), selector("systemStatusBar")) orelse
        return error.TrayUnavailable;
    const status_item = send1(
        Id,
        f64,
        status_bar,
        selector("statusItemWithLength:"),
        status_item_variable,
    ) orelse return error.TrayUnavailable;
    _ = send0(Id, status_item, selector("retain"));
    _ = send1(void, Id, status_item, selector("setMenu:"), menu);

    const button = send0(Id, status_item, selector("button")) orelse return error.TrayUnavailable;
    _ = send1(void, Id, button, selector("setToolTip:"), nsString(app_title));
    if (iconImage(icon)) |image| {
        _ = send1(void, Id, button, selector("setImage:"), image);
    } else {
        _ = send1(void, Id, button, selector("setTitle:"), nsString(app_title));
    }
}

pub fn presentNativeWindow(native: ?*anyopaque) void {
    const window = native orelse return;
    _ = send1(void, Id, window, selector("makeKeyAndOrderFront:"), null);
    const app = send0(Id, class("NSApplication"), selector("sharedApplication"));
    _ = send1(void, bool, app, selector("activateIgnoringOtherApps:"), true);
}

fn menuItem(action: tray.Action, tag: i64) Id {
    const allocated = send0(Id, class("NSMenuItem"), selector("alloc")) orelse return null;
    const item = send3(
        Id,
        Id,
        Sel,
        Id,
        allocated,
        selector("initWithTitle:action:keyEquivalent:"),
        nsString(action.label()),
        selector(clicked_selector),
        nsString(""),
    ) orelse return null;
    _ = send1(void, i64, item, selector("setTag:"), tag);
    _ = send1(void, Id, item, selector("setTarget:"), g_target);
    return item;
}

fn iconImage(icon: tray.IconSource) Id {
    const path = switch (icon) {
        .file => |value| value,
        // A bare theme name has no file to load, so the button falls back
        // to its text title.
        .theme => return null,
    };
    const allocated = send0(Id, class("NSImage"), selector("alloc")) orelse return null;
    const image = send1(
        Id,
        [*:0]const u8,
        allocated,
        selector("initWithContentsOfFile:"),
        zPath(path) orelse return null,
    ) orelse return null;
    _ = send1(
        void,
        NSSize,
        image,
        selector("setSize:"),
        NSSize{ .width = tray_image_points, .height = tray_image_points },
    );
    return image;
}

fn nsString(text: []const u8) Id {
    if (text.len >= text_buf.len) return null;
    @memcpy(text_buf[0..text.len], text);
    text_buf[text.len] = 0;
    const utf8: [*:0]const u8 = text_buf[0..text.len :0].ptr;
    return send1(Id, [*:0]const u8, class("NSString"), selector("stringWithUTF8String:"), utf8);
}

fn zPath(path: []const u8) ?[*:0]const u8 {
    if (path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return path_buf[0..path.len :0].ptr;
}

fn ensureTargetClass() Class {
    if (g_target_class) |existing| return existing;
    const superclass = class("NSObject") orelse return null;
    const created = objc_allocateClassPair(superclass, "PabrikTrayTarget", 0) orelse return null;
    // "v@:@" — void return, self, _cmd, one object argument.
    if (!class_addMethod(created, selector(clicked_selector), @ptrCast(&trayClicked), "v@:@")) return null;
    objc_registerClassPair(created);
    g_target_class = created;
    return created;
}

fn trayClicked(_: Id, _: Sel, sender: Id) callconv(.c) void {
    const handler = g_handler orelse return;
    const tag = send0(i64, sender, selector("tag"));
    if (tag < 0 or tag >= tray.menu.len) return;
    handler.dispatch(tray.menu[@intCast(tag)]);
}
