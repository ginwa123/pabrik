// `read_file` returns raw content (no per-line number prefixes). Zig port of
// `tests/functional/read_file_raw_content_test.py` (same test name).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// `GET /api/agent-tools/registry` → the `tools` array. Python asserted
/// `isinstance(tools, list)` and returned the list; the same check plus the
/// array itself, borrowed from `doc`.
fn registryTools(doc: *const harness.Json) !std.json.Array {
    const tools = doc.array("tools") orelse {
        std.debug.print("registry should be {{tools: list}}\n", .{});
        return error.TestUnexpectedResult;
    };
    return tools;
}

/// The `description` of the tool named `name`, or `""` when the entry
/// has no description (Python's `t.get("description", "")`).
fn toolDescription(tools: std.json.Array, name: []const u8) ![]const u8 {
    for (tools.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, n, name)) continue;
        const d = obj.get("description") orelse return "";
        return switch (d) {
            .string => |s| s,
            // Python's `.get(key, "")` returned "" for a non-string too?
            else => return "",
        };
    }
    std.debug.print("registry missing {s}\n", .{name});
    return error.TestUnexpectedResult;
}

// `read_file`'s description promises raw content, not prefixed lines.
test "registry_read_file_description_documents_raw_content" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tools = try registryTools(&doc);

    // Python's failure message listed every registered name, so a
    // missing `read_file` says what IS there.
    if (!hasTool(tools, "read_file")) {
        std.debug.print("registry missing read_file; got [", .{});
        for (tools.items, 0..) |item, i| {
            if (i > 0) std.debug.print(", ", .{});
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const n = switch (obj.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            std.debug.print("{s}", .{n});
        }
        std.debug.print("]\n", .{});
        return error.TestUnexpectedResult;
    }

    const desc = try toolDescription(tools, "read_file");

    if (std.mem.indexOf(u8, desc, "prefixed with its line number") != null) {
        std.debug.print("read_file description still promises prefixed lines: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, desc, "Each returned line is prefixed") != null) {
        std.debug.print("read_file description still promises prefixed lines: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }
    if (indexOfIgnoreCase(desc, "raw") == null) {
        std.debug.print("read_file description should document raw content, got: {s}\n", .{desc});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, desc, "start_line") == null) {
        std.debug.print(
            "read_file description should point at start_line for positioning, got: {s}\n",
            .{desc},
        );
        return error.TestUnexpectedResult;
    }
}

fn hasTool(tools: std.json.Array, name: []const u8) bool {
    for (tools.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const n = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// `std.ascii.indexOfIgnoreCase` — Python's `desc.lower()` check for "raw".
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    return std.ascii.indexOfIgnoreCase(haystack, needle);
}
