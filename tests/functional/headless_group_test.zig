//! Wire test: `pabrik headless group …` assembles a roster and answers the
//! routing question with no server and no model. Every call runs the real
//! binary against the harness's isolated HOME.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const Run = struct {
    result: harness.RunResult,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn json(self: *Run) !*const std.json.Value {
        if (self.parsed == null) {
            self.parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.result.stdout, .{});
        }
        return &self.parsed.?.value;
    }

    fn deinit(self: *Run) void {
        if (self.parsed) |*p| p.deinit();
        self.result.deinit(gpa);
    }
};

fn group(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "group" });
    try full.appendSlice(gpa, argv);

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);

    if (result.exit_code != 0) {
        std.debug.print(
            "headless group failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        result.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn stringField(value: *const std.json.Value, key: []const u8) ![]const u8 {
    const field = value.object.get(key) orelse return error.TestUnexpectedResult;
    return switch (field) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
}

fn boolField(value: *const std.json.Value, key: []const u8) !bool {
    const field = value.object.get(key) orelse return error.TestUnexpectedResult;
    return switch (field) {
        .bool => |b| b,
        else => return error.TestUnexpectedResult,
    };
}

fn memberNames(value: *const std.json.Value) ![]const []const u8 {
    const members = (value.object.get("members") orelse return error.TestUnexpectedResult).array;
    const names = try gpa.alloc([]const u8, members.items.len);
    for (members.items, 0..) |member, i| names[i] = try stringField(&member, "name");
    return names;
}

fn createGroup(h: *Harness, agent: []const u8) ![]u8 {
    var created = try group(h, &.{ "create", "--agent", agent, "--role", "lead" });
    defer created.deinit();
    const doc = try created.json();
    if (!try boolField(doc, "group")) return error.NotAGroup;
    return gpa.dupe(u8, try stringField(doc, "session_id"));
}

test "headless group: the roster keeps the order the agents joined in and the lead opens" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = try createGroup(&h, "Engineer");
    defer gpa.free(sid);

    var joined = try group(&h, &.{ "join", "--session", sid, "--agent", "Security Engineerr" });
    defer joined.deinit();
    var joined2 = try group(&h, &.{ "join", "--session", sid, "--agent", "Android Engineer" });
    defer joined2.deinit();

    var listed = try group(&h, &.{ "members", "--session", sid });
    defer listed.deinit();
    const doc = try listed.json();

    try testing.expect(try boolField(doc, "group"));
    try testing.expectEqualStrings("Engineer", try stringField(doc, "lead"));

    const names = try memberNames(doc);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("Engineer", names[0]);
    try testing.expectEqualStrings("Security Engineerr", names[1]);
    try testing.expectEqualStrings("Android Engineer", names[2]);

    var decided = try group(&h, &.{ "next", "--session", sid });
    defer decided.deinit();
    const routing = try decided.json();
    try testing.expectEqualStrings("speak", try stringField(routing, "action"));
    try testing.expectEqualStrings("Engineer", try stringField(routing, "agent"));
}

test "headless group: a different lead is who speaks on a thread nobody has answered" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = try createGroup(&h, "Engineer");
    defer gpa.free(sid);

    var joined = try group(&h, &.{ "join", "--session", sid, "--agent", "Security Engineerr" });
    defer joined.deinit();

    var moved = try group(&h, &.{ "lead", "--session", sid, "--agent", "Security Engineerr" });
    defer moved.deinit();
    const moved_doc = try moved.json();
    try testing.expectEqualStrings("Security Engineerr", try stringField(moved_doc, "lead"));

    var decided = try group(&h, &.{ "next", "--session", sid });
    defer decided.deinit();
    const routing = try decided.json();
    try testing.expectEqualStrings("Security Engineerr", try stringField(routing, "agent"));
}

test "headless group: a member that leaves is no longer in the roster" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const sid = try createGroup(&h, "Engineer");
    defer gpa.free(sid);

    var joined = try group(&h, &.{ "join", "--session", sid, "--agent", "Android Engineer" });
    defer joined.deinit();
    var left = try group(&h, &.{ "leave", "--session", sid, "--agent", "Android Engineer" });
    defer left.deinit();

    const doc = try left.json();
    const names = try memberNames(doc);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("Engineer", names[0]);
}

test "headless group: a session that never joined a group reports no roster" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var listed = try group(&h, &.{ "members", "--session", "sess_that_does_not_exist" });
    defer listed.deinit();
    const doc = try listed.json();

    try testing.expect(!try boolField(doc, "group"));
    try testing.expectEqualStrings("", try stringField(doc, "lead"));
    const names = try memberNames(doc);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 0), names.len);
}

test "headless group: a rejected op writes nothing to stdout" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var refused = try group(&h, &.{ "join", "--session", "sess_1" });
    defer refused.deinit();

    try testing.expectEqualStrings("", refused.result.stdout);
    try testing.expect(refused.result.stderr.len > 0);
}
