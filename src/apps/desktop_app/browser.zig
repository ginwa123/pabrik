// src/apps/desktop_app/browser.zig Browser-tab mode for pabrik-desktop
// (`--browser`).

const std = @import("std");
const builtin = @import("builtin");

/// Build the OS opener argv for `url`. Returned slice borrows `url` (no
/// allocation) — caller must keep `url` alive until spawn returns.
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
    // Detach: do not wait.
    _ = &child;
    std.log.info("Opened browser at {s}", .{url});
}

// ---------------------------------------------------------------------------
// Tests (run under `zig build test` via test_runner.zig)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildOpenArgv: this host's opener words, then the url" {
    // One test, every host, no branch that declines to look.
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
