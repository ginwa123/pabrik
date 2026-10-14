// Functional tests for the in-flight stream snapshot endpoint. Zig port of
// `tests/functional/llm_stream_get_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// `POST /api/llm/session` → the new session's id. The Python original did
/// this inline in each test; the body differs only in `name`, so one helper
/// keeps the three tests focused on what they actually assert.
fn createSession(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("session create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/llm/session/<id>/stream` — owned target the caller frees.
fn streamPath(session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/llm/session/{s}/stream", .{session_id});
}

// ─── Test 1: idle session → inactive empty snapshot ────────────────────────

// A session with no in-flight stream must return active=false and
// empty content — this is what ChatView sees on every normal mount.
test "stream_get_idle_session_returns_inactive" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Create a session via the standard endpoint.
    const session_id = try createSession(&h, "stream-idle");
    defer gpa.free(session_id);

    const path = try streamPath(session_id);
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // Python: `assert body["active"] is False`. `is False` is an identity
    // check against the singleton, so a MISSING key or a truthy value both
    // fail — which is what `orelse` + expectEqual reproduces here.
    const active = doc.boolean("active") orelse {
        std.debug.print("stream snapshot has no boolean `active`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(false, active);

    const content = doc.str("content") orelse {
        std.debug.print("stream snapshot has no string `content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("", content);
}

// ─── Test 2: unknown session → still 200 inactive (in-memory only) ─────────

// The registry is in-memory keyed by session_id — an unknown id is
// simply not streaming. Must NOT 404 (the frontend treats any
// non-active response as "nothing to resume").
test "stream_get_unknown_session_returns_inactive" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/llm/session/session_never_existed/stream", .{
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const active = doc.boolean("active") orelse {
        std.debug.print("unknown-session snapshot has no boolean `active`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(false, active);
    try testing.expectEqualStrings("", doc.str("content") orelse return error.TestUnexpectedResult);
}

// ─── Test 3: sibling routes unshadowed (route-order guard) ─────────────────

// `/api/llm/session/:id/stream` was registered after /messages and
// /queue_messages; the older routes must still resolve.
test "stream_route_does_not_shadow_sibling_routes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "stream-sib");
    defer gpa.free(session_id);

    // `/messages?limit=10` — Python passed the query inline in the URL
    // string. `.params` produces the identical bytes and is the harness
    // -sanctioned spelling, so use it.
    {
        const messages_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
        defer gpa.free(messages_path);

        var r = try h.http(io, .GET, messages_path, .{
            .params = &.{.{ .name = "limit", .value = "10" }},
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("messages") == null) {
            std.debug.print("/messages response has no `messages` key: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        const queue_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/queue_messages", .{session_id});
        defer gpa.free(queue_path);

        var r = try h.http(io, .GET, queue_path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("messages") == null) {
            std.debug.print("/queue_messages response has no `messages` key: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // And the new route itself still works.
    {
        const path = try streamPath(session_id);
        defer gpa.free(path);

        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();

        // Python: `set(snap.keys()) >= {"active", "content"}` — a
        // SUBSET check, so extra keys are fine and only the two named
        // ones are required.
        if (doc.get("active") == null or doc.get("content") == null) {
            std.debug.print(
                "stream snapshot must carry both `active` and `content`, got: {s}\n",
                .{r.body},
            );
            return error.TestUnexpectedResult;
        }
    }
}
