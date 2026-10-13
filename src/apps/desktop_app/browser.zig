// src/apps/desktop_app/browser.zig
//
// Browser-tab mode for pabrik-desktop (`--browser`).
//
// Reuses the exact same attach flow as the webview path (state file →
// probe → auto-spawn detached pabrik), but instead of opening a native
// webview window it opens the resolved URL in the OS default browser
// (new tab/window — the browser decides) and exits 0 immediately.
// The daemon keeps running; closing the browser tab does NOT stop it,
// same decoupled lifecycle as closing the webview window.

const std = @import("std");
const builtin = @import("builtin");

/// Build the OS opener argv for `url`. Returned slice borrows `url`
/// (no allocation) — caller must keep `url` alive until spawn returns.
///
///   Linux:   xdg-open <url>
///   macOS:   open <url>
///   Windows: rundll32 url.dll,FileProtocolHandler <url>
pub fn buildOpenArgv(url: []const u8, out: *[3][]const u8) []const []const u8 {
    if (comptime builtin.os.tag == .windows) {
        out[0] = "rundll32";
        out[1] = "url.dll,FileProtocolHandler";
        out[2] = url;
        return out[0..3];
    } else if (comptime builtin.os.tag == .macos) {
        out[0] = "open";
        out[1] = url;
        return out[0..2];
    } else {
        out[0] = "xdg-open";
        out[1] = url;
        return out[0..2];
    }
}

/// Open `url` in the OS default browser (detached, no blocking).
/// stdio is ignored so no browser stdout pollutes the desktop log.
pub fn openBrowser(io: std.Io, url: []const u8) !void {
    var argv_buf: [3][]const u8 = undefined;
    const argv = buildOpenArgv(url, &argv_buf);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.log.err("Failed to open browser at {s}: {s}", .{ url, @errorName(err) });
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .macos) {
            std.log.err("Hint: install xdg-utils (provides xdg-open), or open {s} manually.", .{url});
        }
        return err;
    };
    // Detach: do not wait. Reap handle without blocking — kill() in
    // Zig 0.16 terminates + waits, which would kill the browser shim
    // before it hands off to the real browser. Instead just drop the
    // handle; the OS reaps the short-lived opener (xdg-open/open exit
    // on their own after dispatching).
    _ = &child;
    std.log.info("Opened browser at {s}", .{url});
}

// ---------------------------------------------------------------------------
// Tests (run under `zig build test` via test_runner.zig)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildOpenArgv names this host's opener and appends the url" {
    // Every branch is asserted on ITS host rather than bailed out of: the
    // Windows opener is not `open`+url but `rundll32 url.dll,
    // FileProtocolHandler`+url, so the argv is three words there and two
    // elsewhere. Bailing out on Windows left the only desktop-app
    // browser-launch test unrun on one of the three shipped platforms.
    var buf: [3][]const u8 = undefined;
    const argv = buildOpenArgv("http://127.0.0.1:8081/", &buf);
    if (comptime builtin.os.tag == .windows) {
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings("rundll32", argv[0]);
        try testing.expectEqualStrings("url.dll,FileProtocolHandler", argv[1]);
        try testing.expectEqualStrings("http://127.0.0.1:8081/", argv[2]);
    } else {
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings("http://127.0.0.1:8081/", argv[1]);
        if (comptime builtin.os.tag == .macos) {
            try testing.expectEqualStrings("open", argv[0]);
        } else {
            try testing.expectEqualStrings("xdg-open", argv[0]);
        }
    }
}

test "buildOpenArgv borrows the url slice without copying" {
    var buf: [3][]const u8 = undefined;
    const url = "http://127.0.0.1:9999/some/path";
    const argv = buildOpenArgv(url, &buf);
    try testing.expectEqualStrings(url, argv[argv.len - 1]);
    // Pointer equality proves no copy was made.
    try testing.expect(argv[argv.len - 1].ptr == url.ptr);
}
