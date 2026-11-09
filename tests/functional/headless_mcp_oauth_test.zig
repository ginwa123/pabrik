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

fn mcpOAuth(h: *Harness, argv: []const []const u8) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "mcp-oauth" });
    try full.appendSlice(gpa, argv);

    const result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 120_000);
    if (result.exit_code != 0) {
        std.debug.print(
            "headless mcp-oauth failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        var failed = Run{ .result = result };
        failed.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, id);
}

fn boolean(doc: *const std.json.Value, key: []const u8) ?bool {
    const obj = switch (doc.*) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

test "headless help lists the mcp-oauth verb and its ops" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{ "headless", "help" }, 120_000);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(?u8, 0), result.exit_code);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "mcp-oauth") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "authorize-url") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "exchange") != null);
}

test "headless mcp-oauth status reports an unauthorized server without a token" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "mcp-oauth-status");
    defer gpa.free(ws);

    var run = try mcpOAuth(&h, &.{
        "status",
        "--url",
        "http://127.0.0.1:9/mcp",
        "--workspace",
        ws,
        "--server",
        "files",
    });
    defer run.deinit();
    const doc = try run.json();
    try testing.expectEqual(false, boolean(doc, "authorized").?);
}

test "headless mcp-oauth exchange without a pending authorization fails without stdout" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "mcp-oauth-missing");
    defer gpa.free(ws);

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{
        "headless", "mcp-oauth",              "exchange",
        "--url",    "http://127.0.0.1:9/mcp", "--workspace",
        ws,         "--server",               "files",
        "--state",  "st_unknown",             "--code",
        "code-1",
    });

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 120_000);
    defer result.deinit(gpa);
    try testing.expect(result.exit_code != 0);
    try testing.expectEqualStrings("", result.stdout);
}

test "headless mcp-oauth rejects an unknown op" {
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, &.{ "headless", "mcp-oauth", "nope" }, 120_000);
    defer result.deinit(gpa);
    try testing.expect(result.exit_code != 0);
    try testing.expectEqualStrings("", result.stdout);
}
