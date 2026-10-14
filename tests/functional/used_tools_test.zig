// Wire tests for the `used_tools` agent tool. Zig port of
// `tests/functional/used_tools_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// An owned copy of a wire `tools` string array. Python compared
/// `"used_tools" in tools` against the live list and printed it in the
/// failure message.
const ToolNames = struct {
    items: [][]u8,

    fn deinit(self: *ToolNames) void {
        for (self.items) |it| gpa.free(it);
        gpa.free(self.items);
        self.* = undefined;
    }

    fn contains(self: *const ToolNames, name: []const u8) bool {
        for (self.items) |it| {
            if (std.mem.eql(u8, it, name)) return true;
        }
        return false;
    }

    /// The Python assertion's `{tools!r}`.
    fn dump(self: *const ToolNames) void {
        std.debug.print("  got: [", .{});
        for (self.items, 0..) |it, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("\"{s}\"", .{it});
        }
        std.debug.print("]\n", .{});
    }
};

/// `POST /api/workspaces` → the new workspace's id. Caller frees.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("workspace create response has no string `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// `POST /api/workspaces/{ws}/items/agent` → the new agent's id.
/// Caller frees.
fn createAgent(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    // Derived from `h.temp_dir`, not a literal "/tmp/..." — see header.
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"used-tools-test"});
    defer gpa.free(agent_path);

    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"{s}\",\"path\":\"{s}\"}}",
        .{ name, agent_path },
    );
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return itemId(&doc);
}

/// `POST /api/workspaces/{ws}/items/kanban` → the new board's id.
/// Caller frees.
fn createKanban(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(path);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return itemId(&doc);
}

/// `{"item": {"id": ...}}` → an owned copy of that id.
fn itemId(doc: *const harness.Json) ![]u8 {
    const item = doc.object("item") orelse {
        std.debug.print("create response has no `item` object\n", .{});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, switch (item.get("id") orelse {
        std.debug.print("create response has no item.id\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("create response item.id is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    });
}

/// GET a `{"tools": [...]}` listing and copy the names out.
fn toolNames(h: *Harness, path: []const u8) !ToolNames {
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("tools") orelse {
        std.debug.print("{s}: response has no `tools` array: {s}\n", .{ path, r.body });
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |it| gpa.free(it);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        switch (item) {
            .string => |s| try out.append(gpa, try gpa.dupe(u8, s)),
            else => {
                std.debug.print("{s}: `tools` carries a non-string entry\n", .{path});
                return error.TestUnexpectedResult;
            },
        }
    }
    return .{ .items = try out.toOwnedSlice(gpa) };
}

// UNIFIED_TOOL_REGISTRY → GET /api/agent-tools/registry.
test "registry_exposes_used_tools_with_description" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tools = doc.array("tools") orelse {
        std.debug.print("registry response has no `tools` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (tools.items.len < 1) {
        std.debug.print("registry returned 0 tools — fixture broken?\n", .{});
        return error.TestUnexpectedResult;
    }

    var found = false;
    for (tools.items) |item| {
        const o = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, name, "used_tools")) continue;
        found = true;

        const desc = switch (o.get("description") orelse {
            std.debug.print("used_tools registry entry should carry a description\n", .{});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("used_tools registry description is not a string\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expect(desc.len > 0);
    }

    if (!found) {
        std.debug.print("registry missing 'used_tools'; got:", .{});
        for (tools.items) |item| {
            const o = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const name = switch (o.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            std.debug.print(" {s}", .{name});
        }
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// TestUsedToolsSeeded
// ============================================================================

// Agent mode: DEFAULT_AGENT_TOOLS seeds used_tools at creation.
test "fresh_agent_allowlist_contains_used_tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "used-tools-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "used-tools-agent");
    defer gpa.free(agent_id);

    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(path);

    var tools = try toolNames(&h, path);
    defer tools.deinit();
    if (!tools.contains("used_tools")) {
        std.debug.print("fresh agent should seed used_tools\n", .{});
        tools.dump();
        return error.TestUnexpectedResult;
    }
}

// Kanban mode: DEFAULT_AGENT_TOOLS legacy path seeds used_tools.
test "fresh_kanban_allowlist_contains_used_tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "used-tools-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "used-tools-board");
    defer gpa.free(kanban_id);

    const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/tools", .{kanban_id});
    defer gpa.free(path);

    var tools = try toolNames(&h, path);
    defer tools.deinit();
    if (!tools.contains("used_tools")) {
        std.debug.print("fresh kanban should seed used_tools\n", .{});
        tools.dump();
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// TestUsedToolsLifecycle
// ============================================================================

// DELETE removes it; re-POST restores it (first-class tool).
test "disable_and_reenable_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "used-tools-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "used-tools-agent");
    defer gpa.free(agent_id);

    const del_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/used_tools", .{agent_id});
    defer gpa.free(del_path);
    {
        var r = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        r.deinit();
    }

    const list_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(list_path);

    {
        var tools = try toolNames(&h, list_path);
        defer tools.deinit();
        if (tools.contains("used_tools")) {
            std.debug.print("used_tools should be gone after DELETE\n", .{});
            tools.dump();
            return error.TestUnexpectedResult;
        }
    }

    const create_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(create_path);
    {
        var r = try h.http(io, .POST, create_path, .{
            .json_body = "{\"tool_name\":\"used_tools\"}",
            .expect = &.{201},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqualStrings("used_tools", doc.str("tool_name") orelse {
            std.debug.print("re-POST response has no string `tool_name`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    var tools = try toolNames(&h, list_path);
    defer tools.deinit();
    if (!tools.contains("used_tools")) {
        std.debug.print("used_tools should be back after re-POST\n", .{});
        tools.dump();
        return error.TestUnexpectedResult;
    }
}
