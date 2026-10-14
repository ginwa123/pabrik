// Subagent selected_profile_model forwarding (task_1789672620943_1). Zig port
// of `tests/functional/subagent_selected_profile_test.py`.

// QUERY STRINGS ARE IN THE PATH, NOT IN `HttpOptions.params`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Poll `GET /api/llm/session/:id/messages` until a non-null
/// `selected_profile_model` shows up, and return it OWNED. Returns `null`
/// after 30 attempts — the Python helper's `None`.
fn getProfileViaMessages(h: *Harness, session_id: []const u8) !?[]u8 {
    // Query is INLINED, not passed via `HttpOptions.params`: see the
    // "QUERY STRINGS ARE IN THE PATH" note at the top of this file.
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=1", .{session_id});
    defer gpa.free(path);

    var attempt: usize = 0;
    while (attempt < 30) : (attempt += 1) {
        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        // The `@as(?[]u8, ...)` is load-bearing: a bare `try` yields
        // `[]u8`, which will not coerce into the optional return type.
        if (doc.str("selected_profile_model")) |got| return @as(?[]u8, try gpa.dupe(u8, got));

        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    return null;
}

// PUT profile -> GET messages echoes it (DB not NULL, re-read works).
test "subagent_profile_persists_and_rereads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_subagent_profile_fwd_001";
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    {
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"selected_profile_model\":\"union alpha\"}",
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings("union alpha", doc.str("selected_profile_model").?);
    }

    const got = try getProfileViaMessages(&h, session_id);
    defer if (got) |g| gpa.free(g);

    // Python: `assert got == "union alpha"` — a profile lost on
    // re-read is exactly the subagent-child NULL regression.
    try testing.expectEqualStrings("union alpha", got orelse {
        std.debug.print("selected_profile_model never appeared on re-read for {s}\n", .{session_id});
        return error.TestUnexpectedResult;
    });
}

// PUT with explicit empty profile clears it (HTTP always writes).
test "empty_profile_explicitly_clears_via_put" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_subagent_profile_fwd_002";
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    {
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"selected_profile_model\":\"union alpha\"}",
            .expect = &.{200},
        });
        defer r.deinit();
    }

    // Explicit empty = clear by design (session_update.zig always writes).
    {
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"selected_profile_model\":\"\"}",
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings("", doc.str("selected_profile_model").?);
    }

    const got = try getProfileViaMessages(&h, session_id);
    defer if (got) |g| gpa.free(g);

    // With zero llm_history rows the messages endpoint yields null
    // (no JOINed row); both None and '' mean "no profile".
    if (got) |g| try testing.expectEqualStrings("", g);
}