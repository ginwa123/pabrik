// src/apps/desktop_app/cli.zig Command-line parser for pabrik-desktop. Parses
// --port, --pabrik-path, --pabrik-url, --window-size, --title, --user-agent,
// --icon, --smoke-test, --help / -h.

const std = @import("std");

pub const Config = struct {
    /// Port to bind pabrik on. 0 = auto-pick a free port.
    /// Ignored when `pabrik_url` is set (connect mode).
    port: u16 = 0,
    /// Optional explicit path to the pabrik binary.
    /// Ignored when `pabrik_url` is set (connect mode).
    pabrik_path: ?[]const u8 = null,
    /// If set, skip the spawn/healthcheck/asset-extraction path entirely and
    /// just point the webview at this URL.
    pabrik_url: ?[]const u8 = null,
    /// Decoupled-service mode (added in 2026-07): when no `pabrik` daemon
    /// is running, refuse to auto-spawn one and surface an actionable
    /// error instead. Default: false (auto-spawn is the default).
    no_auto_start: bool = false,
    /// Override the port used by the probe / auto-spawn fallback.
    /// 0 = use the state file's port, or 8081 if no state file.
    attach_port: u16 = 0,
    /// Window dimensions.
    window_width: u32 = 1280,
    window_height: u32 = 800,
    /// Window title. The default value is a string literal — do NOT free it.
    /// Heap-allocated titles (set via `--title`) MUST be freed by deinit().
    title: []const u8 = "Pabrik",
    /// Optional User-Agent override.
    user_agent: ?[]const u8 = null,
    /// Optional path to a window icon.
    icon_path: ?[]const u8 = null,
    /// If true, the app runs in CI-friendly mode: open, wait briefly, exit.
    smoke_test: bool = false,
    /// If true, enable the webview's DevTools (right-click → Inspect
    /// Element → DevTools panel). Off by default; enable for dev
    /// workflow.
    enable_devtools: bool = false,
    /// Linux-only today (no-op on macOS/Windows): when true, force
    /// `GDK_BACKEND=x11` before gtk_init.
    force_x11: bool = false,
    /// Browser-tab mode: open the resolved URL in the OS default
    /// browser (new tab) instead of a native webview window, then
    /// exit. Same attach/auto-spawn flow, no webview involved.
    browser: bool = false,

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        if (self.pabrik_path) |p| allocator.free(p);
        if (self.pabrik_url) |u| allocator.free(u);
        // title: free only if heap-allocated (i.e. user set --title with a
        // value different from the default literal).
        if (!std.mem.eql(u8, self.title, "Pabrik")) allocator.free(self.title);
        if (self.user_agent) |ua| allocator.free(ua);
        if (self.icon_path) |ip| allocator.free(ip);
    }
};

pub const CliError = error{
    ShowHelp,
    InvalidPort,
    InvalidSize,
    MissingValue,
    UnknownArg,
    /// allocator.dupe() failure — Zig 0.16 requires this in the error set
    /// since `try` propagates OutOfMemory as a distinct error.
    OutOfMemory,
};

const usage =
    \\Usage: pabrik-desktop [options]
    \\
    \\Two modes:
    \\  Spawn mode (default): spawn pabrik as a child process, wait for it
    \\    to be healthy, then open the webview. Closing the window kills
    \\    the spawned pabrik. Uses --port and --pabrik-path.
    \\  Connect mode (--pabrik-url): skip spawning; just open the webview at
    \\    the given URL. Useful for attaching to a pabrik you already have
    \\    running. --port and --pabrik-path are ignored in this mode.
    \\
    \\Options:
    \\  --port PORT              Port for pabrik to bind on (default: 0 = auto-pick)
    \\  --pabrik-path PATH        Explicit path to pabrik binary
    \\  --pabrik-url URL          Connect mode: point webview at this URL
    \\                            (e.g. http://127.0.0.1:8081) instead of
    \\                            spawning a new pabrik
    \\  --window-size WxH        Window size in pixels (default: 1280x800)
    \\  --title TITLE            Window title (default: "Pabrik")
    \\  --user-agent UA          User-Agent string for the webview
    \\  --icon PATH              Path to window icon
    \\  --smoke-test             Open, wait 2s, exit (for CI)
    \\  --devtools               Enable webview DevTools (right-click → Inspect
    \\                            Element → DevTools panel). Off by default.
    \\  --x11                    Linux only: force GDK_BACKEND=x11 so WebKitGTK
    \\                            uses XWayland instead of Wayland. Workaround
    \\                            for the NVIDIA + Wayland stack where
    \\                            WebKitGPUProcess silently fails to start and
    \\                            the web-process eats 1 CPU core doing software
    \\                            rasterization. No-op on macOS/Windows.
    \\  --browser                Open the resolved URL in the OS default
    \\                            browser (new tab) instead of a webview
    \\                            window, then exit. Same attach flow.
    \\  --help, -h               Show this help
    \\
;

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) CliError!Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--pabrik-path")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.pabrik_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--pabrik-url")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.pabrik_url = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--window-size")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const x_idx = std.mem.indexOfScalar(u8, args[i], 'x') orelse return error.InvalidSize;
            const w = std.fmt.parseInt(u32, args[i][0..x_idx], 10) catch return error.InvalidSize;
            const h = std.fmt.parseInt(u32, args[i][x_idx + 1..], 10) catch return error.InvalidSize;
            cfg.window_width = w;
            cfg.window_height = h;
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            // Free the previous title if it was heap-allocated (i.e. user
            // passed --title twice with a non-default value). If the previous
            // value was the literal "Pabrik", skip the free.
            if (!std.mem.eql(u8, cfg.title, "Pabrik")) allocator.free(cfg.title);
            cfg.title = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--user-agent")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (cfg.user_agent) |ua| allocator.free(ua);
            cfg.user_agent = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--icon")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (cfg.icon_path) |ip| allocator.free(ip);
            cfg.icon_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--smoke-test")) {
            cfg.smoke_test = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-start")) {
            cfg.no_auto_start = true;
        } else if (std.mem.eql(u8, arg, "--attach-port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cfg.attach_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--devtools")) {
            cfg.enable_devtools = true;
        } else if (std.mem.eql(u8, arg, "--x11")) {
            // Linux-only flag (no-op on macOS/Windows). Forces the GDK
            // windowing backend to X11 so GDK/XWayland backs the WebKit web
            // view instead of GDK/Wayland.
            cfg.force_x11 = true;
        } else if (std.mem.eql(u8, arg, "--browser")) {
            cfg.browser = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // std.debug.print writes to stderr by default.
            std.debug.print("{s}", .{usage});
            return error.ShowHelp;
        } else {
            std.debug.print("Unknown argument: {s}\n\n{s}", .{ arg, usage });
            return error.UnknownArg;
        }
    }
    return cfg;
}

// ===== Tests merged from cli_test.zig (2026-09-29 flatten) ===== Tests for
// the CLI parser.

const testing = std.testing;

test "parseArgs: defaults" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"pabrik-desktop"};
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u16, 0), cfg.port); // 0 = auto-pick
    try testing.expect(cfg.pabrik_path == null);
    try testing.expect(cfg.pabrik_url == null);
    try testing.expectEqual(@as(u32, 1280), cfg.window_width);
    try testing.expectEqual(@as(u32, 800), cfg.window_height);
    try testing.expectEqualStrings("Pabrik", cfg.title);
    try testing.expect(!cfg.smoke_test);
    try testing.expect(!cfg.enable_devtools);
}

test "parseArgs: --port" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--port", "9999" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u16, 9999), cfg.port);
}

test "parseArgs: --pabrik-path" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--pabrik-path", "/tmp/pabrik" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.pabrik_path != null);
    try testing.expectEqualStrings("/tmp/pabrik", cfg.pabrik_path.?);
}

test "parseArgs: --pabrik-url switches to connect mode" {
    const allocator = testing.allocator;
    const args = [_][]const u8{
        "pabrik-desktop",
        "--pabrik-url",
        "http://127.0.0.1:8081",
    };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.pabrik_url != null);
    try testing.expectEqualStrings("http://127.0.0.1:8081", cfg.pabrik_url.?);
    // --port and --pabrik-path are ignored in connect mode but still parseable.
    // We just verify they default to null/0 here (the caller is responsible
    // for honoring cfg.pabrik_url and ignoring the other fields).
    try testing.expectEqual(@as(u16, 0), cfg.port);
    try testing.expect(cfg.pabrik_path == null);
}

test "parseArgs: --window-size 1024x768" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--window-size", "1024x768" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqual(@as(u32, 1024), cfg.window_width);
    try testing.expectEqual(@as(u32, 768), cfg.window_height);
}

test "parseArgs: --title" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--title", "My Pabrik" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expectEqualStrings("My Pabrik", cfg.title);
}

test "parseArgs: --smoke-test" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--smoke-test" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.smoke_test);
}

test "parseArgs: --devtools enables webview DevTools" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--devtools" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.enable_devtools);
}

test "parseArgs: --x11 forces X11 backend opt-in" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--x11" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.force_x11);
}

test "parseArgs: --x11 defaults to false" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"pabrik-desktop"};
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(!cfg.force_x11);
}

test "parseArgs: --browser opens in default browser instead of webview" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--browser" };
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(cfg.browser);
}

test "parseArgs: browser defaults to false" {
    const allocator = testing.allocator;
    const args = [_][]const u8{"pabrik-desktop"};
    const cfg = try parse(allocator, &args);
    defer cfg.deinit(allocator);
    try testing.expect(!cfg.browser);
}

test "parseArgs: --help prints usage and signals help" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--help" };
    const result = parse(allocator, &args);
    try testing.expectError(error.ShowHelp, result);
}

test "parseArgs: invalid port returns InvalidPort" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--port", "abc" };
    const result = parse(allocator, &args);
    try testing.expectError(error.InvalidPort, result);
}

test "parseArgs: --window-size without x returns InvalidSize" {
    const allocator = testing.allocator;
    const args = [_][]const u8{ "pabrik-desktop", "--window-size", "1024" };
    const result = parse(allocator, &args);
    try testing.expectError(error.InvalidSize, result);
}
