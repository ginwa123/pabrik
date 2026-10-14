//! Public API surface for the `pabrikcli` package. Re-exports the modules
//! consumed by the CLI executable and the test runner. Keeping the surface
//! small makes the build graph cheap to recompute.

pub const config = @import("config.zig");
pub const client = @import("client.zig");
pub const format = @import("format.zig");
pub const commands = @import("commands/root.zig");

/// Re-export kabelweb's client so subcommands can reach it via the `cli`
/// namespace: `cli.custom_http_client.Client`.
pub const custom_http_client = @import("kabelweb").client;

// Test imports — keep them sorted alphabetically. Each implementation file
// carries its own tests inline (merged from the former `*_test.zig` files),
// so importing the implementation is what makes those tests discoverable.
test {
    _ = @import("config.zig");
    _ = @import("client.zig");
    _ = @import("commands/sessions.zig");
    _ = @import("commands/messages.zig");
    _ = @import("commands/send.zig");
    _ = @import("commands/events.zig");
    _ = @import("commands/pr_status.zig");
}

const std = @import("std");
const testing = std.testing;

test "root: format.prettyJson renders an object" {
    const out = try format.prettyJson(testing.allocator, .{ .whitespace = .indent_2 }, .{
        .id = "session-1",
        .status = "send",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"session-1\"") != null);
}

test "root: client.buildUrl joins server + path" {
    const u = try client.buildUrl(testing.allocator, "http://x:8081", "/api/llm/session");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/llm/session", u);
}

test "root: commands.parseCommand dispatches 'send' to Root" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "send", "hello" };
    const cmd = try commands.parseCommand(testing.allocator, &args, &buf);
    try testing.expectEqual(commands.CommandKind.send, cmd.kind);
}