//! Wire test: `pabrik headless compaction` runs the `compaction` tool's path with
//! no port bound. The session has no history, so an allowed run reports
//! `compacted:false`: the ALLOW/DENY decision is what this pins.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

fn createSessionInWorkspace(h: *Harness, workspace_id: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .workspace_id = workspace_id }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/session", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("session create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// The exact write the Runtime tab's toggle makes, so this test drives the
/// setting through its production path rather than by editing a file.
fn setAutoCompaction(h: *Harness, workspace_id: []const u8, enabled: bool) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/config", .{workspace_id});
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .agent_auto_compaction = enabled }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    r.deinit();
}

/// The GET the Runtime tab renders from.
fn readAutoCompaction(h: *Harness, workspace_id: []const u8) !bool {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/config", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return doc.boolean("agent_auto_compaction") orelse return error.SettingMissingOnTheWire;
}

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

fn compaction(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "compaction" });
    try full.appendSlice(gpa, argv);

    return .{ .result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000) };
}

test "headless compaction: the workspace switch refuses the agent, and --force overrides it" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "compaction-switch");
    defer gpa.free(ws);
    const session = try createSessionInWorkspace(&h, ws);
    defer gpa.free(session);

    // 1. The key is absent on disk, which reads as ENABLED: the tool an agent
    //    would call is allowed to run.
    {
        var run = try compaction(&h, &.{session});
        defer run.deinit();
        if (run.result.exit_code != 0) {
            std.debug.print(
                "headless compaction failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ run.result.exit_code, run.result.stdout, run.result.stderr },
            );
            return error.TestUnexpectedResult;
        }
        const doc = try run.json();
        try testing.expectEqualStrings(session, doc.object.get("session_id").?.string);
        try testing.expect(doc.object.get("agent_auto_compaction").?.bool);
        try testing.expect(doc.object.get("allowed").?.bool);
        try testing.expect(!doc.object.get("forced").?.bool);
        // Nothing to compact yet, so the run reports it instead of failing.
        try testing.expect(!doc.object.get("compacted").?.bool);
        try testing.expect(
            std.mem.indexOf(u8, doc.object.get("message").?.string, "too few messages") != null,
        );
    }

    // 2. The workspace turns the switch OFF. The agent is now refused, the exit
    //    code says so, and the message names the setting.
    {
        try setAutoCompaction(&h, ws, false);
        try testing.expect(!(try readAutoCompaction(&h, ws)));

        var run = try compaction(&h, &.{session});
        defer run.deinit();
        try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);

        const doc = try run.json();
        try testing.expect(!doc.object.get("agent_auto_compaction").?.bool);
        try testing.expect(!doc.object.get("allowed").?.bool);
        try testing.expect(!doc.object.get("compacted").?.bool);
        try testing.expect(
            std.mem.indexOf(u8, doc.object.get("message").?.string, "agent_auto_compaction") != null,
        );
    }

    // 3. `--force` is what the user's Compact button does (force = true), so the
    //    switch may not block it.
    {
        var run = try compaction(&h, &.{ session, "--force" });
        defer run.deinit();
        if (run.result.exit_code != 0) {
            std.debug.print(
                "force run failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
                .{ run.result.exit_code, run.result.stdout, run.result.stderr },
            );
            return error.TestUnexpectedResult;
        }
        const doc = try run.json();
        try testing.expect(doc.object.get("allowed").?.bool);
        try testing.expect(doc.object.get("forced").?.bool);
        try testing.expect(!doc.object.get("agent_auto_compaction").?.bool);
    }
}

test "headless compaction: an unknown session exits non-zero and prints no object" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var run = try compaction(&h, &.{"sess_that_does_not_exist"});
    defer run.deinit();

    try testing.expect(run.result.exit_code != null and run.result.exit_code.? != 0);
    // stdout is the machine channel: a failure never prints a half object.
    try testing.expectEqualStrings("", run.result.stdout);
}
