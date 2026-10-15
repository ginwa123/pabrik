//! Transport: HTTP glue between the TUI and the pabrik backend. Sole user of
//! `custom_http_client` inside the tui module.

const std = @import("std");
const custom_http_client = @import("kabelweb").client;

pub const TransportError = error{
    HttpRequestFailed,
    OutOfMemory,
};

/// POST /api/llm/session with a chat message. On success returns the
/// session id echoed by the server (caller owns).
pub fn postSend(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
) ![]u8 {
    const body = try buildSendBody(allocator, session_id, message, cwd);
    defer allocator.free(body);

    const url = try joinUrl(allocator, server, "/api/llm/session");
    defer allocator.free(url);

    const headers = [_]custom_http_client.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const response = try custom_http_client.post(client, url, body, &headers, .{ .timeout_ms = 30_000 });
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        std.log.warn("POST /api/llm/session -> {d}: {s}", .{ response.status_code, response.body });
        return TransportError.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

/// GET /api/llm/session/:id/messages. Returns the raw JSON body
/// (caller owns). The caller parses it with std.json.
pub fn getMessages(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    server: []const u8,
    session_id: []const u8,
    limit: u32,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "/api/llm/session/{s}/messages?limit={d}&direction=asc",
        .{ session_id, limit },
    );
    defer allocator.free(path);
    const url = try joinUrl(allocator, server, path);
    defer allocator.free(url);

    const response = try custom_http_client.get(client, url, .{ .timeout_ms = 15_000 });
    defer response.deinit(allocator);
    if (response.status_code < 200 or response.status_code >= 300) {
        return TransportError.HttpRequestFailed;
    }
    return allocator.dupe(u8, response.body);
}

/// Open a long-lived SSE stream on /api/events. Caller MUST call
/// `.deinit()` on the returned stream.
pub fn openEvents(
    allocator: std.mem.Allocator,
    client: *custom_http_client.Client,
    io: std.Io,
    server: []const u8,
) !custom_http_client.ResponseStream {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/api/events?channels=llm,queue",
        .{server},
    );
    defer allocator.free(url);
    return client.openStream(io, .{ .method = .GET, .url = url }, .{
        .timeout_ms = null, // SSE is long-lived
    });
}

fn joinUrl(allocator: std.mem.Allocator, server: []const u8, path: []const u8) ![]u8 {
    const base = if (server.len > 0 and server[server.len - 1] == '/')
        server[0 .. server.len - 1]
    else
        server;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
}

/// Build the JSON body for POST /api/llm/session. Every string field is
/// properly JSON-escaped (quotes, backslashes, control bytes) so user
/// input containing `"`, `\`, or newlines cannot break the wire shape.
pub fn buildSendBody(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"session_id\":");
    try std.json.Stringify.encodeJsonString(session_id, .{}, w);
    try w.writeAll(",\"queue_message\":");
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll(",\"allowed_tools\":\"all\",\"cwd_session\":");
    try std.json.Stringify.encodeJsonString(cwd, .{}, w);
    try w.writeAll(
        ",\"image_urls\":\"\",\"selected_profile_model\":\"\"," ++
            "\"is_auto_retry_until_stop\":\"\"}",
    );
    return aw.toOwnedSlice();
}

// ----------------------------------------------------------------------------
// Tests — pure helpers only; HTTP paths need a live server.
// ----------------------------------------------------------------------------

const testing = std.testing;

test "joinUrl: strips trailing slash" {
    const u = try joinUrl(testing.allocator, "http://x:8081/", "/api/x");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("http://x:8081/api/x", u);
}

test "buildSendBody: cwd_session is JSON-escaped and round-trips" {
    const body = try buildSendBody(testing.allocator, "s1", "hi", "/home/ginwa/my project");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/home/ginwa/my project", parsed.value.object.get("cwd_session").?.string);
}

test "buildSendBody: cwd with quote and backslash is escaped" {
    const body = try buildSendBody(testing.allocator, "s1", "hi", "/tmp/a\"b\\c");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/tmp/a\"b\\c", parsed.value.object.get("cwd_session").?.string);
}

test "buildSendBody: empty cwd still produces valid JSON with empty cwd_session" {
    const body = try buildSendBody(testing.allocator, "s1", "hi", "");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.object.get("cwd_session").?.string);
}

test "buildSendBody: non-empty cwd is sent as cwd_session (regression: tui always sent empty)" {
    const body = try buildSendBody(testing.allocator, "session-1", "hi", "/home/ginwa/my-project");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("/home/ginwa/my-project", parsed.value.object.get("cwd_session").?.string);
}

// ===== Tests merged from tdd_round2_test.zig (2026-09-29 flatten) ===== TDD
// round 2 — regression tests written BEFORE the fixes.

// ============================================================================
// 1. transport.buildSendBody — JSON injection safety
// ============================================================================

test "buildSendBody: plain message round-trips" {
    const body = try buildSendBody(testing.allocator, "session-1", "hi", "");
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"session_id\":\"session-1\",\"queue_message\":\"hi\",\"allowed_tools\":\"all\",\"cwd_session\":\"\",\"image_urls\":\"\",\"selected_profile_model\":\"\",\"is_auto_retry_until_stop\":\"\"}",
        body,
    );
}

test "buildSendBody: embedded double quote is escaped (was raw -> invalid JSON)" {
    const body = try buildSendBody(testing.allocator, "s", "say \"hi\"", "");
    defer testing.allocator.free(body);
    // The body must PARSE as JSON and carry the quote through.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("say \"hi\"", qm.string);
}

test "buildSendBody: backslash is escaped" {
    const body = try buildSendBody(testing.allocator, "s", "path C:\\tmp", "");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("path C:\\tmp", qm.string);
}

test "buildSendBody: newline is escaped (multi-line message)" {
    const body = try buildSendBody(testing.allocator, "s", "line1\nline2", "");
    defer testing.allocator.free(body);
    // Body must remain a SINGLE line of JSON (no raw control byte).
    try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const qm = parsed.value.object.get("queue_message").?;
    try testing.expectEqualStrings("line1\nline2", qm.string);
}

test "buildSendBody: session id with quote cannot break out of the field" {
    const body = try buildSendBody(testing.allocator, "evil\"}", "x", "");
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const sid = parsed.value.object.get("session_id").?;
    try testing.expectEqualStrings("evil\"}", sid.string);
}
