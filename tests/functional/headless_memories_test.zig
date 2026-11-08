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

fn memories(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "memories" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);
    if (result.exit_code != 0) {
        std.debug.print(
            "headless memories failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        var failed = Run{ .result = result };
        failed.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn memoriesPath(workspace_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/api/workspaces/{s}/memories", .{workspace_id});
}

test "headless memories: save, list, get and delete round-trip through the rows the HTTP API serves" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "memories-headless");
    defer gpa.free(ws);

    var saved_id: []u8 = undefined;
    {
        var run = try memories(&h, &.{
            "save",
            "--workspace",
            ws,
            "--content",
            "the deploy target is staging",
            "--tags",
            "ops, deploy",
        });
        defer run.deinit();
        const doc = try run.json();
        const memory = doc.object.get("memory").?.object;
        try testing.expectEqualStrings("the deploy target is staging", memory.get("content").?.string);

        const tags = memory.get("tags").?.array;
        try testing.expectEqual(@as(usize, 2), tags.items.len);
        try testing.expectEqualStrings("ops", tags.items[0].string);
        try testing.expectEqualStrings("deploy", tags.items[1].string);

        saved_id = try gpa.dupe(u8, memory.get("id").?.string);
    }
    defer gpa.free(saved_id);

    {
        var run = try memories(&h, &.{ "list", "--workspace", ws });
        defer run.deinit();
        const doc = try run.json();
        const list = doc.object.get("memories").?.array;
        try testing.expectEqual(@as(usize, 1), list.items.len);
        try testing.expectEqualStrings(saved_id, list.items[0].object.get("id").?.string);
        try testing.expectEqual(@as(i64, 1), doc.object.get("total_count").?.integer);
    }

    {
        var run = try memories(&h, &.{ "get", "--workspace", ws, "--id", saved_id });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings(
            "the deploy target is staging",
            doc.object.get("memory").?.object.get("content").?.string,
        );
    }

    {
        const path = try memoriesPath(ws);
        defer gpa.free(path);

        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const list = doc.array("memories") orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 1), list.items.len);
        try testing.expectEqualStrings(
            saved_id,
            list.items[0].object.get("id").?.string,
        );
    }

    {
        var run = try memories(&h, &.{ "delete", "--workspace", ws, "--id", saved_id });
        defer run.deinit();
        const doc = try run.json();
        try testing.expect(doc.object.get("success").?.bool);
        try testing.expectEqualStrings(saved_id, doc.object.get("id").?.string);
    }

    {
        var run = try memories(&h, &.{ "list", "--workspace", ws });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(@as(usize, 0), doc.object.get("memories").?.array.items.len);
    }
}

test "headless memories: a note saved in one workspace is invisible in another" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const alpha = try createWorkspace(&h, "memories-alpha");
    defer gpa.free(alpha);
    const beta = try createWorkspace(&h, "memories-beta");
    defer gpa.free(beta);

    var saved_id: []u8 = undefined;
    {
        var run = try memories(&h, &.{
            "save",
            "--workspace",
            alpha,
            "--content",
            "alpha only note",
        });
        defer run.deinit();
        const doc = try run.json();
        saved_id = try gpa.dupe(u8, doc.object.get("memory").?.object.get("id").?.string);
    }
    defer gpa.free(saved_id);

    {
        var run = try memories(&h, &.{ "list", "--workspace", beta });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(@as(usize, 0), doc.object.get("memories").?.array.items.len);
    }

    {
        var run = try memories(&h, &.{ "get", "--workspace", beta, "--id", saved_id });
        defer run.deinit();
        const doc = try run.json();
        try testing.expect(doc.object.get("memory").? == .null);
    }

    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "headless", "memories", "delete", "--workspace", beta, "--id", saved_id });

        var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, argv.items, 60_000);
        defer result.deinit(gpa);
        try testing.expect(result.exit_code != 0);
        try testing.expectEqualStrings("", result.stdout);
    }

    {
        var run = try memories(&h, &.{ "list", "--workspace", alpha });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(@as(usize, 1), doc.object.get("memories").?.array.items.len);
    }
}

test "headless memories: --query narrows the list to matching bodies and tags" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "memories-search");
    defer gpa.free(ws);

    {
        var run = try memories(&h, &.{ "save", "--workspace", ws, "--content", "the deploy target is staging", "--tags", "ops" });
        defer run.deinit();
    }
    {
        var run = try memories(&h, &.{ "save", "--workspace", ws, "--content", "design tokens live in style.css", "--tags", "frontend" });
        defer run.deinit();
    }

    {
        var run = try memories(&h, &.{ "list", "--workspace", ws, "--query", "deploy" });
        defer run.deinit();
        const doc = try run.json();
        const list = doc.object.get("memories").?.array;
        try testing.expectEqual(@as(usize, 1), list.items.len);
        try testing.expectEqualStrings("the deploy target is staging", list.items[0].object.get("content").?.string);
    }

    {
        var run = try memories(&h, &.{ "list", "--workspace", ws, "--query", "frontend" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(@as(usize, 1), doc.object.get("memories").?.array.items.len);
    }

    {
        var run = try memories(&h, &.{ "list", "--workspace", ws, "--query", "kubernetes" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqual(@as(usize, 0), doc.object.get("memories").?.array.items.len);
    }
}

test "headless memories: a save with no body is refused and nothing is stored" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "memories-empty");
    defer gpa.free(ws);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "headless", "memories", "save", "--workspace", ws, "--content", "" });

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, argv.items, 60_000);
    defer result.deinit(gpa);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "--content") != null);

    var run = try memories(&h, &.{ "list", "--workspace", ws });
    defer run.deinit();
    const doc = try run.json();
    try testing.expectEqual(@as(usize, 0), doc.object.get("memories").?.array.items.len);
}
