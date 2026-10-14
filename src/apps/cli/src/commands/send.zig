//! `send` command — POST /api/llm/session with a message.

const std = @import("std");
const config = @import("../config.zig");
const client_mod = @import("../client.zig");

pub const Args = struct {
    message: []const u8,
    session_id: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    allowed_tools: []const u8 = "all",
    cwd: []const u8 = "",
    auto_retry: bool = false,
};

pub fn run(args: Args, cfg: config.Config, io: std.Io) @import("root.zig").DispatchResult {
    const allocator = std.heap.page_allocator;
    var http_client = custom_http_client.Client.init(allocator);
    defer http_client.deinit();

    // Pick the session id (CLI flag → config default → fresh session).
    const session_id = args.session_id orelse cfg.session_id orelse blk: {
        // Generate a fresh session id with a millisecond timestamp suffix
        // (matches the project's `session-<unix-ms>` convention).
        const ts_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        const buf = std.fmt.allocPrint(allocator, "session-{d}", .{ts_ms}) catch return .err;
        break :blk buf;
    };
    defer if (args.session_id == null and cfg.session_id == null) allocator.free(session_id);

    // Profile: flag > config default > empty (lets the server pick).
    const profile = args.profile orelse cfg.profile orelse "";

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"allowed_tools\":\"{s}\",\"cwd_session\":\"{s}\",\"image_urls\":\"\",\"selected_profile_model\":\"{s}\",\"is_auto_retry_until_stop\":\"{s}\"}}",
        .{
            session_id,
            args.message,
            args.allowed_tools,
            args.cwd,
            profile,
            if (args.auto_retry) "true" else "",
        },
    ) catch return .err;
    defer allocator.free(body);

    const response_body = client_mod.postJson(allocator, &http_client, cfg.server, "/api/llm/session", body) catch {
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

// A tiny alias so the run() signature reads naturally without forcing
// the caller to spell out `custom_http_client.Client`.
const custom_http_client = @import("kabelweb").client;
const client_typedef = custom_http_client;

// ===== Tests merged from send_test.zig (2026-09-29 flatten) ===== Tests for
// src/commands/send.zig (POST /api/llm/session). Real tests land when the
// command itself lands.

const testing = std.testing;

test "send: placeholder (command not yet implemented)" {
    try testing.expect(true);
}