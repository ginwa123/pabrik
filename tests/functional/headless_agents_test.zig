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

fn agents(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "agents" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);
    if (result.exit_code != 0) {
        std.debug.print(
            "headless agents failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        var failed = Run{ .result = result };
        failed.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

/// Replace the harness's stub profile with the config this test needs.
fn writeConfig(h: *Harness, body: []const u8) !void {
    const dir = try harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik" });
    defer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const file = try std.fs.path.join(gpa, &.{ dir, "config.json" });
    defer gpa.free(file);
    var f = try std.Io.Dir.cwd().createFile(io, file, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn row(doc: *const std.json.Value, index: usize) std.json.ObjectMap {
    return doc.object.get("agents").?.array.items[index].object;
}

fn effective(doc: *const std.json.Value, field: []const u8) []const u8 {
    return doc.object.get("effective").?.object.get(field).?.string;
}

test "headless agents: a switched-off agent is never the agent a call uses" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try writeConfig(&h,
        \\{
        \\  "profiles_models": {
        \\    "retired": {
        \\      "model": "retired-model",
        \\      "base_url": "https://retired.example.com",
        \\      "api_key": "retired-key",
        \\      "enabled": false
        \\    },
        \\    "live": {
        \\      "model": "live-model",
        \\      "base_url": "https://live.example.com",
        \\      "api_key": "live-key",
        \\      "url_style": "anthropic"
        \\    }
        \\  },
        \\  "active_profile": "retired"
        \\}
    );

    {
        // The stored pointer still names the switched-off agent; the call does not use it.
        var run = try agents(&h, &.{});
        defer run.deinit();
        const doc = try run.json();

        try testing.expectEqualStrings("retired", doc.object.get("active_profile").?.string);
        try testing.expectEqualStrings("top-level", doc.object.get("source").?.string);
        try testing.expectEqualStrings("live-model", effective(doc, "model"));
        try testing.expectEqualStrings("anthropic", effective(doc, "url_style"));

        try testing.expectEqual(@as(usize, 2), doc.object.get("agents").?.array.items.len);
        try testing.expectEqualStrings("live", row(doc, 0).get("name").?.string);
        try testing.expect(row(doc, 0).get("enabled").?.bool);
        try testing.expect(!row(doc, 0).get("is_active").?.bool);
        try testing.expectEqualStrings("retired", row(doc, 1).get("name").?.string);
        try testing.expect(!row(doc, 1).get("enabled").?.bool);
        try testing.expect(row(doc, 1).get("is_active").?.bool);
    }

    {
        // A chat pinned to the agent the user switched off says so instead of running something else.
        var run = try agents(&h, &.{ "--profile", "retired" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings("top-level", doc.object.get("source").?.string);
        try testing.expectEqualStrings("live-model", effective(doc, "model"));
    }

    {
        // An enabled agent is the one that answers, and the report says which slot it came from.
        var run = try agents(&h, &.{ "--profile", "live" });
        defer run.deinit();
        const doc = try run.json();
        try testing.expectEqualStrings("selected", doc.object.get("source").?.string);
        try testing.expectEqualStrings("live-model", effective(doc, "model"));
    }
}
