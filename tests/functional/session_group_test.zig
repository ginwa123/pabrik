//! `GET|POST|DELETE /api/llm/session/:id/group...` — the roster that turns a
//! chat into a multi-agent room. Every call runs the real binary.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

fn ensureSession(h: *Harness, sid: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{sid});
    defer gpa.free(path);
    var r = try h.http(io, .PUT, path, .{ .json_body = "{\"name\":\"room\"}", .expect = &.{200} });
    defer r.deinit();
}

fn getRoster(h: *Harness, sid: []const u8, expect: []const u16) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/group", .{sid});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();
    return r.json();
}

fn addMember(h: *Harness, sid: []const u8, agent: []const u8, role: []const u8, expect: []const u16) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/group/members", .{sid});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"agent\":\"{s}\",\"role\":\"{s}\"}}", .{ agent, role });
    defer gpa.free(body);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return r.json();
}

fn removeMember(h: *Harness, sid: []const u8, agent: []const u8, expect: []const u16) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/group/members/{s}", .{ sid, agent });
    defer gpa.free(path);
    var r = try h.http(io, .DELETE, path, .{ .expect = expect });
    defer r.deinit();
    return r.json();
}

fn setLead(h: *Harness, sid: []const u8, agent: []const u8, expect: []const u16) !harness.Json {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/group/lead", .{sid});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"agent\":\"{s}\"}}", .{agent});
    defer gpa.free(body);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    defer r.deinit();
    return r.json();
}

fn memberNames(doc: *const harness.Json) ![]const []const u8 {
    const members = doc.array("members") orelse return error.TestUnexpectedResult;
    const names = try gpa.alloc([]const u8, members.items.len);
    for (members.items, 0..) |member, i| {
        const o = switch (member) {
            .object => |m| m,
            else => return error.TestUnexpectedResult,
        };
        const name = switch (o.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        names[i] = name;
    }
    return names;
}

test "session group: a chat with no members is not a group" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_1");

    var doc = try getRoster(&h, "sess_group_1", &.{200});
    defer doc.deinit();

    try testing.expectEqual(false, doc.boolean("group").?);
    try testing.expectEqualStrings("", doc.str("lead").?);
    try testing.expectEqual(@as(usize, 0), doc.array("members").?.items.len);
}

test "session group: the first agent to join leads the room" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_2");

    var doc = try addMember(&h, "sess_group_2", "BEAM", "", &.{200});
    defer doc.deinit();

    try testing.expectEqual(true, doc.boolean("group").?);
    try testing.expectEqualStrings("BEAM", doc.str("lead").?);
    const names = try memberNames(&doc);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("BEAM", names[0]);
}

test "session group: a second agent joins as a worker and leaves the lead alone" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_3");

    var first = try addMember(&h, "sess_group_3", "BEAM", "", &.{200});
    first.deinit();

    var doc = try addMember(&h, "sess_group_3", "deepseek auto", "", &.{200});
    defer doc.deinit();

    try testing.expectEqualStrings("BEAM", doc.str("lead").?);
    const names = try memberNames(&doc);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("deepseek auto", names[1]);
}

test "session group: the lead can be handed to another member" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_4");

    var first = try addMember(&h, "sess_group_4", "BEAM", "", &.{200});
    first.deinit();
    var second = try addMember(&h, "sess_group_4", "deepseek auto", "", &.{200});
    second.deinit();

    var doc = try setLead(&h, "sess_group_4", "deepseek auto", &.{200});
    defer doc.deinit();

    try testing.expectEqualStrings("deepseek auto", doc.str("lead").?);
}

test "session group: an agent outside the roster cannot lead it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_5");

    var first = try addMember(&h, "sess_group_5", "BEAM", "", &.{200});
    first.deinit();

    var doc = try setLead(&h, "sess_group_5", "deepseek auto", &.{400});
    defer doc.deinit();

    try testing.expect(doc.str("error") != null);
}

test "session group: removing the last member stops the chat being a group" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_6");

    var first = try addMember(&h, "sess_group_6", "BEAM", "", &.{200});
    first.deinit();

    var doc = try removeMember(&h, "sess_group_6", "BEAM", &.{200});
    defer doc.deinit();

    try testing.expectEqual(false, doc.boolean("group").?);
    try testing.expectEqual(@as(usize, 0), doc.array("members").?.items.len);
}

test "session group: an unknown session is not found" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var doc = try getRoster(&h, "sess_group_missing", &.{404});
    defer doc.deinit();

    try testing.expect(doc.str("error") != null);
}

test "session group: an empty agent name is rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try ensureSession(&h, "sess_group_7");

    var doc = try addMember(&h, "sess_group_7", "", "", &.{400});
    defer doc.deinit();

    try testing.expect(doc.str("error") != null);
}
