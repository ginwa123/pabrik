//! `events` command — tail the SSE event stream at /api/events. This is the
//! one CLI command that produces streaming output (server-sent events).

const std = @import("std");
const config = @import("../config.zig");

pub const Args = struct {
    channels: []const u8 = "workers,sessions,kanban,design_element,llm,queue",
};

pub fn run(args: Args, cfg: config.Config, io: std.Io) @import("root.zig").DispatchResult {
    const allocator = std.heap.page_allocator;
    var http_client = @import("kabelweb").client.Client.init(allocator);
    defer http_client.deinit();

    const url = std.fmt.allocPrint(
        allocator,
        "{s}/api/events?channels={s}",
        .{ cfg.server, args.channels },
    ) catch return .err;
    defer allocator.free(url);

    var stream = http_client.openStream(io, .{ .method = .GET, .url = url }, .{
        .timeout_ms = null, // SSE is long-lived; no per-chunk timeout
    }) catch {
        return .err;
    };
    defer stream.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    while (true) {
        const chunk = stream.next() catch return .err;
        const bytes = chunk orelse break;
        defer allocator.free(bytes);
        stdout_writer.interface.writeAll(bytes) catch return .err;
        stdout_writer.interface.flush() catch return .err;
    }
    return .ok;
}

// ===== Tests merged from events_test.zig (2026-09-29 flatten) ===== Tests
// for src/commands/events.zig (GET /api/events SSE). Real tests land when the
// command itself lands.

const testing = std.testing;

test "events: placeholder (command not yet implemented)" {
    try testing.expect(true);
}