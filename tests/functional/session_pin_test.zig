// `POST /api/llm/session/:id/pin` + `POST /api/llm/session/reorder_pinned` —
// pinned sessions for the PINNED section above RECENT (Migration 104).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

fn ensureSession(h: *Harness, sid: []const u8, name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{sid});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

fn postPin(h: *Harness, sid: []const u8, pinned: bool, expect: []const u16) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/pin", .{sid});
    defer gpa.free(path);
    const body = if (pinned) "{\"is_pinned\":true}" else "{\"is_pinned\":false}";
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return r.json();
}

fn postReorder(h: *Harness, ids: []const []const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try buf.writer.writeAll("{\"ordered_ids\":[");
    for (ids, 0..) |id, i| {
        if (i > 0) try buf.writer.writeAll(",");
        try buf.writer.writeByte('"');
        try buf.writer.writeAll(id);
        try buf.writer.writeByte('"');
    }
    try buf.writer.writeAll("]}");
    const body = try buf.toOwnedSlice();
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/llm/session/reorder_pinned", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

fn findSessionInList(doc: *const harness.Json, id: []const u8) !std.json.Value {
    const sessions = doc.array("sessions") orelse return error.TestUnexpectedResult;
    var found: ?std.json.Value = null;
    for (sessions.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const n = switch (o.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, n, id)) continue;
        if (found != null) return error.TestUnexpectedResult;
        found = item;
    }
    return found orelse error.TestUnexpectedResult;
}

fn fetchList(h: *Harness) !harness.Response {
    return h.http(io, .GET, "/api/llm/session", .{
        .params = &.{.{ .name = "limit", .value = "100" }},
        .expect = &.{200},
    });
}

// ============================================================================
// Tests
// ============================================================================

test "pin_returns_200_and_list_carries_is_pinned" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_pin_1";
    try ensureSession(&h, sid, "pin me");

    var body = try postPin(&h, sid, true, &.{200});
    defer body.deinit();
    if (body.boolean("success") != true) return error.TestUnexpectedResult;
    if (body.boolean("is_pinned") != true) return error.TestUnexpectedResult;

    var list = try fetchList(&h);
    defer list.deinit();
    var ldoc = try list.json();
    defer ldoc.deinit();
    const entry = try findSessionInList(&ldoc, sid);
    const pinned = switch (entry) {
        .object => |o| switch (o.get("is_pinned") orelse return error.TestUnexpectedResult) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    if (!pinned) {
        std.debug.print("list row for {s} is not pinned after pin\n", .{sid});
        return error.TestUnexpectedResult;
    }
}

test "unpin_clears_and_list_reads_false" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = "sess_pin_2";
    try ensureSession(&h, sid, "pin then unpin");
    {
        var b = try postPin(&h, sid, true, &.{200});
        b.deinit();
    }
    var ubody = try postPin(&h, sid, false, &.{200});
    defer ubody.deinit();
    if (ubody.boolean("success") != true) return error.TestUnexpectedResult;
    if (ubody.boolean("is_pinned") != false) return error.TestUnexpectedResult;

    var list = try fetchList(&h);
    defer list.deinit();
    var ldoc = try list.json();
    defer ldoc.deinit();
    const entry = try findSessionInList(&ldoc, sid);
    const pinned = switch (entry) {
        .object => |o| switch (o.get("is_pinned") orelse return error.TestUnexpectedResult) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    if (pinned) {
        std.debug.print("list row for {s} still pinned after unpin\n", .{sid});
        return error.TestUnexpectedResult;
    }
}

test "reorder_pinned_changes_positions" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_pin_a", "A");
    try ensureSession(&h, "sess_pin_b", "B");
    {
        var b1 = try postPin(&h, "sess_pin_a", true, &.{200});
        b1.deinit();
        var b2 = try postPin(&h, "sess_pin_b", true, &.{200});
        b2.deinit();
    }
    // Display order [b, a]: b gets the higher position.
    const order = [_][]const u8{ "sess_pin_b", "sess_pin_a" };
    try postReorder(&h, &order);

    var list = try fetchList(&h);
    defer list.deinit();
    var ldoc = try list.json();
    defer ldoc.deinit();
    const ea = try findSessionInList(&ldoc, "sess_pin_a");
    const eb = try findSessionInList(&ldoc, "sess_pin_b");
    const pa = switch (ea) {
        .object => |o| switch (o.get("pinned_position") orelse return error.TestUnexpectedResult) {
            .integer => |n| n,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    const pb = switch (eb) {
        .object => |o| switch (o.get("pinned_position") orelse return error.TestUnexpectedResult) {
            .integer => |n| n,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    if (!(pb > pa)) {
        std.debug.print("reorder failed: pos_b={d} pos_a={d}, want b > a\n", .{ pb, pa });
        return error.TestUnexpectedResult;
    }
}

test "pin_unknown_session_404s" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var b = try postPin(&h, "sess_pin_nope", true, &.{404});
    defer b.deinit();
}
