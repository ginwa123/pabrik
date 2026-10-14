//! `messages` command — GET /api/llm/session/<id>/messages.

const std = @import("std");
const config = @import("../config.zig");
const client_mod = @import("../client.zig");

pub const Args = struct {
    session_id: []const u8,
    limit: u32 = 100,
    reverse: bool = false,
};

pub fn run(args: Args, cfg: config.Config, io: std.Io) @import("root.zig").DispatchResult {
    const allocator = std.heap.page_allocator;
    var http_client = @import("kabelweb").client.Client.init(allocator);
    defer http_client.deinit();

    const path = std.fmt.allocPrint(
        allocator,
        "/api/llm/session/{s}/messages?limit={d}{s}",
        .{
            args.session_id,
            args.limit,
            if (args.reverse) "&reverse=1" else "",
        },
    ) catch return .err;
    defer allocator.free(path);

    const response_body = client_mod.getJson(allocator, &http_client, cfg.server, path) catch {
        return .err;
    };
    defer allocator.free(response_body);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    stdout_writer.interface.writeAll(response_body) catch return .err;
    stdout_writer.interface.writeByte('\n') catch return .err;
    stdout_writer.interface.flush() catch return .err;
    return .ok;
}

// ===== Tests merged from messages_test.zig (2026-09-29 flatten) ===== Tests
// for src/commands/messages.zig (GET /api/llm/session/:id/messages). Real
// tests land when the command itself lands.

const testing = std.testing;

test "messages: placeholder (command not yet implemented)" {
    try testing.expect(true);
}