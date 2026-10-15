// Sub-agent identity columns (Migration 091, task_1789909961925_0). Zig port
// of `tests/functional/subagent_identity_test.py`.

// QUERY STRINGS ARE IN THE PATH, NOT IN `HttpOptions.params`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Assert the wire value at `v` is one of `(None, "")`.
fn expectNullOrEmpty(v: std.json.Value, key: []const u8) !void {
    switch (v) {
        .null => {},
        .string => |s| try testing.expectEqualStrings("", s),
        else => {
            std.debug.print("{s} was neither null nor a string on the wire\n", .{key});
            return error.TestUnexpectedResult;
        },
    }
}

// Main session echoes null/empty identity fields (keys present).
test "messages_wire_includes_sub_agent_identity" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "sess_subagent_identity_001";

    const put_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(put_path);
    {
        const body =
            \\{"selected_profile_model":"muse spark auto"}
        ;
        var r = try h.http(io, .PUT, put_path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    // Query is INLINED, not passed via `HttpOptions.params`: see the
    // "QUERY STRINGS ARE IN THE PATH" note at the top of this file.
    const messages_path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages?limit=1", .{session_id});
    defer gpa.free(messages_path);

    var r = try h.http(io, .GET, messages_path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Python: `assert "sub_agent_name" in body`.
    const sub_agent_name = doc.get("sub_agent_name") orelse {
        std.debug.print("missing sub_agent_name key in: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // Python: `assert "parent_session_id" in body`.
    const parent_session_id = doc.get("parent_session_id") orelse {
        std.debug.print("missing parent_session_id key in: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    // Python: `body["sub_agent_name"] in (None, "")` — a MAIN session
    // is nobody's sub-agent, so both fields must be unset.
    try expectNullOrEmpty(sub_agent_name, "sub_agent_name");
    try expectNullOrEmpty(parent_session_id, "parent_session_id");

    // Parent profile still flows through unchanged. Python:
    //   `body.get("selected_profile_model") in (None, "muse spark auto", "")`
    if (doc.get("selected_profile_model")) |profile| switch (profile) {
        .null => {},
        .string => |s| try testing.expect(
            std.mem.eql(u8, s, "muse spark auto") or s.len == 0,
        ),
        else => {
            std.debug.print("selected_profile_model was not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
}