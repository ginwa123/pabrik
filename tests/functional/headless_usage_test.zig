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

fn usage(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "usage" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);
    if (result.exit_code != 0) {
        std.debug.print(
            "headless usage failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        var failed = Run{ .result = result };
        failed.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

test "headless usage: the day range, the default window and a refused range" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "usage-headless");
    defer gpa.free(ws);

    {
        var run = try usage(&h, &.{ "--workspace", ws, "--range", "1d" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings(ws, doc.object.get("workspace_id").?.string);
        try testing.expectEqualStrings("1d", doc.object.get("range").?.string);

        const totals = doc.object.get("totals").?.object;
        try testing.expectEqual(@as(i64, 0), totals.get("calls").?.integer);
        try testing.expectEqual(@as(i64, 0), totals.get("input_tokens").?.integer);
        try testing.expectEqual(@as(i64, 0), totals.get("reported_input_tokens").?.integer);
        try testing.expect(totals.get("cache_hit_rate").? == .null);
    }

    {
        var run = try usage(&h, &.{ "--workspace", ws });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings("30d", doc.object.get("range").?.string);
    }

    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "headless", "usage", "--workspace", ws, "--range", "14d" });

        var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, argv.items, 60_000);
        defer result.deinit(gpa);
        try testing.expect(result.exit_code != 0);
        try testing.expectEqualStrings("", result.stdout);
    }
}

test "the usage endpoint accepts the one-day range and refuses a range it does not own" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "usage-day-range");
    defer gpa.free(ws);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/usage?range=1d", .{ws});
    defer gpa.free(path);

    var ok = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer ok.deinit();
    var doc = try ok.json();
    defer doc.deinit();
    try testing.expectEqualStrings("1d", doc.str("range") orelse return error.TestUnexpectedResult);

    const bad = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/usage?range=14d", .{ws});
    defer gpa.free(bad);

    var refused = try h.http(io, .GET, bad, .{ .expect = &.{400} });
    defer refused.deinit();
}
