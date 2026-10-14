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

test "buildOpenArgv: this host's opener words, then the url" {
    // One test, every host, no branch that declines to look. The opener
    // table below covers each platform the SUT switches on, and an
    // unknown host fails this test (it does not pass vacuously): the
    // argv it produces has one word too few, so `expectEqual` on the
    // length goes red and names the platform nobody handled.
    //
    // A per-platform test would have been the easy thing here — the
    // Windows argv is `rundll32 url.dll,FileProtocolHandler <url>` and
    // the unix one is `open|xdg-open <url>`, three words against two —
    // and that is exactly the shape this suite is moving away from: a
    // test that only asserts on the host it was written for reports
    // green everywhere else without having checked anything.
    var opener_words: []const []const u8 = &.{};
    switch (builtin.os.tag) {
        .windows => opener_words = &.{ "rundll32", "url.dll,FileProtocolHandler" },
        .macos => opener_words = &.{"open"},
        .linux => opener_words = &.{"xdg-open"},
        else => {},
    }

    var buf: [3][]const u8 = undefined;
    const url = "http://127.0.0.1:8081/";
    const argv = buildOpenArgv(url, &buf);
    try testing.expectEqual(opener_words.len + 1, argv.len);
    for (opener_words, 0..) |word, i| try testing.expectEqualStrings(word, argv[i]);
    try testing.expectEqualStrings(url, argv[argv.len - 1]);
}

test "buildOpenArgv borrows the url slice without copying" {
    var buf: [3][]const u8 = undefined;
    const url = "http://127.0.0.1:9999/some/path";
    const argv = buildOpenArgv(url, &buf);
    try testing.expectEqualStrings(url, argv[argv.len - 1]);
    // Pointer equality proves no copy was made.
    try testing.expect(argv[argv.len - 1].ptr == url.ptr);
}
