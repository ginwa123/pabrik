// Functional: chat content envelopes (Option A) stay wire-compatible. POST
// /api/llm/session with a plain `queue_message`, then poll GET
// /api/llm/session/:id/messages until the user row lands.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

fn sendBody(session_id: []const u8, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = message,
        .cwd_session = "",
        .allowed_tools = "all",
        .image_urls = "",
        .selected_profile_model = "",
        .is_auto_retry_until_stop = "",
    }, .{});
}

fn getMessages(h: *Harness, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{
        .params = &.{
            .{ .name = "sort_by", .value = "created_at" },
            .{ .name = "direction", .value = "asc" },
            .{ .name = "limit", .value = "100" },
        },
        .expect = &.{200},
    });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

fn firstUserContent(body: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const msgs = parsed.value.object.get("messages") orelse return null;
    if (msgs != .array) return null;
    for (msgs.array.items) |m| {
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = m.object.get("content") orelse continue;
        if (content != .string) continue;
        return try gpa.dupe(u8, content.string);
    }
    return null;
}

test "chat envelope: user message round-trips as plain text on the wire" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const session_id = "envelope-wire-001";
    const body = try sendBody(session_id, "i wanna ask with you");
    defer gpa.free(body);
    {
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer r.deinit();
    }

    // Poll until the user row lands (worker drains the queue async).
    var wire: ?[]u8 = null;
    defer if (wire) |w| gpa.free(w);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const raw = try getMessages(&h, session_id);
        defer gpa.free(raw);
        if (try firstUserContent(raw)) |c| {
            wire = c;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
    }
    const got = wire orelse return error.TestUnexpectedResult;

    // Wire compat: plain human text, never the JSON envelope.
    try testing.expectEqualStrings("i wanna ask with you", got);
    try testing.expect(std.mem.indexOf(u8, got, "\"msg\"") == null);
}
