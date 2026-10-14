// src/apps/desktop_app/webview_lib.zig Thin Zig binding for the vendored
// webview/webview library (vendor/webview/webview.h, upstream 0.12.0).

const std = @import("std");

/// Opaque webview instance (webview_t).
pub const Webview = opaque {};

/// Window size hints (webview_hint_t).
pub const Hint = enum(c_int) {
    none = 0, // WEBVIEW_HINT_NONE — width/height are default size
    min = 1, // WEBVIEW_HINT_MIN  — width/height are minimum bounds
    max = 2, // WEBVIEW_HINT_MAX  — width/height are maximum bounds
    fixed = 3, // WEBVIEW_HINT_FIXED — window not user-resizable
};

/// Error codes (webview_error_t). Non-negative = success.
pub const Error = enum(c_int) {
    missing_dependency = -5,
    canceled = -4,
    invalid_state = -3,
    invalid_argument = -2,
    unspecified = -1,
    ok = 0,
    duplicate = 1,
    not_found = 2,

    /// WEBVIEW_SUCCEEDED(error) — true for OK and informational codes.
    pub fn succeeded(self: Error) bool {
        return @intFromEnum(self) >= 0;
    }
};

// ---------------------------------------------------------------------------
// C API (extern — implemented by vendor/webview/webview.cc)
// ---------------------------------------------------------------------------

pub extern "c" fn webview_create(debug: c_int, window: ?*anyopaque) ?*Webview;
pub extern "c" fn webview_destroy(w: *Webview) Error;
pub extern "c" fn webview_run(w: *Webview) Error;
pub extern "c" fn webview_terminate(w: *Webview) Error;
pub extern "c" fn webview_dispatch(
    w: *Webview,
    fn_: *const fn (w: *Webview, arg: ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
) Error;
pub extern "c" fn webview_get_window(w: *Webview) ?*anyopaque;
pub extern "c" fn webview_get_native_handle(w: *Webview, kind: c_int) ?*anyopaque;
pub extern "c" fn webview_set_title(w: *Webview, title: [*:0]const u8) Error;
pub extern "c" fn webview_set_size(w: *Webview, width: c_int, height: c_int, hint: Hint) Error;
pub extern "c" fn webview_navigate(w: *Webview, url: [*:0]const u8) Error;
pub extern "c" fn webview_set_html(w: *Webview, html: [*:0]const u8) Error;
pub extern "c" fn webview_init(w: *Webview, js: [*:0]const u8) Error;
pub extern "c" fn webview_eval(w: *Webview, js: [*:0]const u8) Error;
pub extern "c" fn webview_bind(
    w: *Webview,
    name: [*:0]const u8,
    fn_: *const fn (id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
) Error;
pub extern "c" fn webview_unbind(w: *Webview, name: [*:0]const u8) Error;
pub extern "c" fn webview_return(w: *Webview, id: [*:0]const u8, status: c_int, result: [*:0]const u8) Error;

/// High-level convenience: create a windowed webview, navigate, run the main
/// loop until the window closes, then destroy. Mirrors the old webview.run()
/// contract so main.zig stays simple.
pub fn runWindow(
    title: [*:0]const u8,
    url: [*:0]const u8,
    width: c_int,
    height: c_int,
    debug: bool,
    force_x11: bool,
) !void {
    // Pin WebKitGTK hardware compositing before WebKit initialises
    // (task_1787761084050_0).
    _ = setEnvIfUnset("WEBKIT_FORCE_COMPOSITING_MODE", "1");

    // Idle-freeze fix (task_1788487031990_1): `--x11` was parsed into
    // `cli.Config.force_x11` but never consumed, so Wayland users had no
    // opt-out when the compositor stopped sending frame callbacks.
    if (force_x11) {
        _ = setEnvIfUnset("GDK_BACKEND", "x11");
    }

    const w = webview_create(if (debug) 1 else 0, null) orelse
        return error.WebviewCreateFailed;
    defer _ = webview_destroy(w);

    _ = webview_set_title(w, title);
    _ = webview_set_size(w, width, height, .none);
    _ = webview_navigate(w, url);
    _ = webview_run(w);
}

// ---------------------------------------------------------------------------
// Static-contract tests: the binding must stay 1:1 with the vendored header.

const testing = std.testing;

fn readVendorHeader(allocator: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "vendor/webview/webview.h",
        allocator,
        .limited(1024 * 1024),
    );
}

test "binding matches vendored webview.h C API signatures" {
    const allocator = testing.allocator;
    const header = try readVendorHeader(allocator);
    defer allocator.free(header);

    // Every function we extern-declare must exist in the vendored header
    // with the same name. If upstream renames/removes one, this fails.
    const needles = [_][]const u8{
        "webview_t webview_create(int debug, void *window)",
        "webview_error_t webview_destroy(webview_t w)",
        "webview_error_t webview_run(webview_t w)",
        "webview_error_t webview_terminate(webview_t w)",
        "webview_error_t webview_dispatch(webview_t w,",
        "void *webview_get_window(webview_t w)",
        "webview_error_t webview_set_title(webview_t w, const char *title)",
        "webview_error_t webview_set_size(webview_t w, int width, int height,",
        "webview_error_t webview_navigate(webview_t w, const char *url)",
        "webview_error_t webview_set_html(webview_t w, const char *html)",
        "webview_error_t webview_init(webview_t w, const char *js)",
        "webview_error_t webview_eval(webview_t w, const char *js)",
        "webview_error_t webview_bind(webview_t w, const char *name,",
        "webview_error_t webview_unbind(webview_t w, const char *name)",
        "webview_error_t webview_return(webview_t w, const char *id,",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, header, needle) == null) {
            std.debug.print(
                "!! vendored webview.h missing signature: {s} !!\n",
                .{needle},
            );
            return error.WebviewSignatureMissing;
        }
    }
}

test "vendored webview.h has the NVIDIA dmabuf workaround built in" {
    // The whole reason for this swap: upstream applies the
    // WEBKIT_DISABLE_DMABUF_RENDERER workaround itself when the
    // WebKit-version + X11 + NVIDIA conditions match.
    const allocator = testing.allocator;
    const header = try readVendorHeader(allocator);
    defer allocator.free(header);

    if (std.mem.indexOf(u8, header, "apply_webkit_dmabuf_workaround") == null) {
        std.debug.print(
            "!! vendored webview.h lost apply_webkit_dmabuf_workaround !!\n",
            .{},
        );
        return error.WebviewDmabufWorkaroundMissing;
    }
    if (std.mem.indexOf(u8, header, "WEBKIT_DISABLE_DMABUF_RENDERER") == null) {
        std.debug.print(
            "!! vendored webview.h lost WEBKIT_DISABLE_DMABUF_RENDERER pin !!\n",
            .{},
        );
        return error.WebviewDmabufPinMissing;
    }
}

test "vendored webview.h enables clipboard access + devtools on debug" {
    // Two behaviors our old linux.zig provided manually that the
    // library must now provide for us: paste-images clipboard access
    // and developer extras under debug=true.
    const allocator = testing.allocator;
    const header = try readVendorHeader(allocator);
    defer allocator.free(header);

    const needles = [_][]const u8{
        "webkit_settings_set_javascript_can_access_clipboard(settings, true)",
        "webkit_settings_set_enable_developer_extras(settings,",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, header, needle) == null) {
            std.debug.print(
                "!! vendored webview.h missing behavior: {s} !!\n",
                .{needle},
            );
            return error.WebviewBehaviorMissing;
        }
    }
}

test "Error.succeeded mirrors WEBVIEW_SUCCEEDED semantics" {
    try testing.expect(Error.ok.succeeded());
    try testing.expect(Error.duplicate.succeeded());
    try testing.expect(Error.not_found.succeeded());
    try testing.expect(!Error.unspecified.succeeded());
    try testing.expect(!Error.missing_dependency.succeeded());
}

// ---------------------------------------------------------------------------
// runWindow() must pin WebKitGTK env vars BEFORE webview_create
// (task_1787761084050_0 / desktop scroll-perf cross-platform plan).

/// Idempotent env-var pin: set `key=value` in the process environment, but
/// only if the variable is NOT already set.
const builtin = @import("builtin");
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setEnvIfUnset(key: [*:0]const u8, value: [*:0]const u8) bool {
    if (builtin.os.tag == .windows) return false;
    if (std.c.getenv(key) != null) return false;
    return setenv(key, value, 0) == 0;
}

test "setEnvIfUnset sets the variable on first call and reports true" {
    // Use a per-test unique name so concurrent test runs in the same
    // process don't collide. PABRIK_TEST_SETENV_FRESH_VAR is unlikely to
    // exist in the wild.
    const key = "PABRIK_TEST_SETENV_FRESH_VAR";
    // Defensive: clear any leftover from a prior failed run.
    _ = unsetenv(key);
    try testing.expect(std.c.getenv(key) == null);

    const wrote = setEnvIfUnset(key, "1");
    try testing.expect(wrote);
    try testing.expectEqualStrings("1", std.mem.span(std.c.getenv(key).?));

    // Cleanup.
    _ = unsetenv(key);
}

test "setEnvIfUnset preserves existing user override and reports false" {
    const key = "PABRIK_TEST_SETENV_PRESERVE_VAR";
    // Seed: user has explicitly set the variable to "0" (a hypothetical
    // opt-out). setEnvIfUnset must not change it.
    try testing.expectEqual(@as(c_int, 0), setenv(key, "0", 1));
    try testing.expectEqualStrings("0", std.mem.span(std.c.getenv(key).?));

    const wrote = setEnvIfUnset(key, "1");
    try testing.expect(!wrote);
    // The user's "0" must still be there — we did NOT overwrite.
    try testing.expectEqualStrings("0", std.mem.span(std.c.getenv(key).?));

    // Cleanup.
    _ = unsetenv(key);
}
