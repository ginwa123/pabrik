// Functional contract: session metadata must NOT require the messages
// endpoint.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

const SESSION_ID = "sess_detail_metadata_1";

fn putSession(h: *Harness, body: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{SESSION_ID});
    defer gpa.free(path);
    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

fn getDetail(h: *Harness) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{SESSION_ID});
    defer gpa.free(path);
    return h.http(io, .GET, path, .{ .expect = &.{200} });
}

fn getMessagesLimit1(h: *Harness) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{SESSION_ID});
    defer gpa.free(path);
    const params = [1]Harness.Param{.{ .name = "limit", .value = "1" }};
    return h.http(io, .GET, path, .{ .params = &params, .expect = &.{200} });
}

// Detail endpoint carries all getSession() fields, no messages key.
test "session_detail_returns_metadata_without_messages_payload" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putSession(&h, "{\"name\":\"detail-contract-chat\",\"selected_profile_model\":\"900ribu\"}");

    var r = try getDetail(&h);
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const sid = doc.str("session_id") orelse {
        std.debug.print("detail has no session_id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(SESSION_ID, sid);
    try testing.expectEqualStrings("detail-contract-chat", doc.str("name") orelse "");
    try testing.expectEqualStrings("900ribu", doc.str("selected_profile_model") orelse "");

    for ([_][]const u8{
        "cwd",         "created_at",     "git_worktree_cwd",  "pr_url",
        "pr_provider", "sub_agent_name", "parent_session_id",
    }) |key| {
        if (doc.get(key) == null) {
            std.debug.print("detail response missing {s}: {s}\n", .{ key, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // The whole point: no message payload rides along.
    if (doc.get("messages") != null) {
        std.debug.print("detail endpoint must not embed messages\n", .{});
        return error.TestUnexpectedResult;
    }
    if (r.body.len >= 4096) {
        std.debug.print("detail response should be ~1 kB, got {d} bytes\n", .{r.body.len});
        return error.TestUnexpectedResult;
    }
}

// Zero-message session: detail has the row, messages?limit=1 has none.
test "session_detail_works_with_zero_messages" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putSession(&h, "{\"name\":\"fresh-no-messages-yet\"}");

    {
        var r = try getDetail(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings("fresh-no-messages-yet", doc.str("name") orelse "");
    }

    {
        var r = try getMessagesLimit1(&h);
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const messages = doc.array("messages") orelse {
            std.debug.print("messages endpoint has no messages array: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (messages.items.len != 0) {
            std.debug.print("fresh session must have no message rows\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Reproduce the screenshot: limit=1 returns ~200 kB, detail stays ~1 kB.
test "old_limit1_path_carries_message_weight_detail_does_not" {
    try harness.requirePabrikBin(io, gpa);
    // The ballast POST below names `selected_profile_model: "stub"`: boot the
    // stub profile so the turn is accepted and the user row is stored (the
    // dispatch itself fails against the dead endpoint, which is fine — only
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putSession(&h, "{\"name\":\"heavy-oldest-message\"}");

    // Seed the ballast through the product's own write path: a 200 kB user
    // message becomes the session's oldest row (see file header).
    {
        const ballast = try gpa.alloc(u8, 200_000);
        defer gpa.free(ballast);
        @memset(ballast, 'x');
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"session_id\":\"{s}\",\"queue_message\":\"{s}\",\"selected_profile_model\":\"stub\"}}",
            .{ SESSION_ID, ballast },
        );
        defer gpa.free(body);
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .assert_status = false,
            .timeout_s = 30.0,
        });
        defer r.deinit();
    }

    // Wait for the user row to land; fail loudly if it never does so a
    // vacuous pass is impossible.
    {
        const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 15_000;
        while (true) {
            var r = try getMessagesLimit1(&h);
            defer r.deinit();
            var doc = try r.json();
            defer doc.deinit();
            const messages = doc.array("messages") orelse return error.TestUnexpectedResult;
            if (messages.items.len != 0) break;
            if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) {
                std.debug.print("seeded user message never appeared\n", .{});
                return error.TestUnexpectedResult;
            }
            std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
        }
    }

    var old = try getMessagesLimit1(&h);
    defer old.deinit();
    if (old.body.len <= 100_000) {
        std.debug.print(
            "expected the old limit=1 path to drag the message weight, got {d} bytes\n",
            .{old.body.len},
        );
        return error.TestUnexpectedResult;
    }

    var new = try getDetail(&h);
    defer new.deinit();
    var doc = try new.json();
    defer doc.deinit();
    if (doc.get("messages") != null) {
        std.debug.print("detail must not embed messages\n", .{});
        return error.TestUnexpectedResult;
    }
    if (new.body.len >= 4096) {
        std.debug.print(
            "detail must stay small with a heavy message present, got {d} bytes\n",
            .{new.body.len},
        );
        return error.TestUnexpectedResult;
    }
    if (!(new.body.len * 25 < old.body.len)) {
        std.debug.print(
            "detail ({d} B) should be an order of magnitude smaller than limit=1 ({d} B)\n",
            .{ new.body.len, old.body.len },
        );
        return error.TestUnexpectedResult;
    }
}
