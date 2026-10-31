// Functional test for the agent tools' `cwd` / path-parameter contract. Boots
// a real `pabrik` binary against an isolated tmpdir HOME and reads the
// published schema from `GET /api/agent-tools/registry`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Tools that must demand an absolute `cwd` in their published schema.
const PATH_TOOLS = [_][]const u8{
    "read_file",
    "write_file",
    "text_replace",
    "remove_file",
    "glob",
    "list_directory",
    "present_files",
    "search",
    "set_git_worktree",
};

/// Tools that must NOT publish a `cwd` parameter.
const CWD_FREE_TOOLS = [_][]const u8{
    // No filesystem parameter at all — the negative control.
    // `cwd` dropped the same day, for reasons recorded at each tool.
    "create_kanban_task",
    "add_mcp_server",
};

/// The dead tools swept out of the tree (and the registry) on 2026-10-14.
const REMOVED_TOOLS = [_][]const u8{ "change_agent", "list_agents", "remove_agent" };

/// Look up one tool object by name. Borrows from `tools`, which must outlive
/// the result.
fn findTool(tools: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (tools.items) |item| {
        if (item != .object) continue;
        const n = item.object.get("name") orelse continue;
        if (n != .string) continue;
        if (std.mem.eql(u8, n.string, name)) return item.object;
    }
    return null;
}

/// Look up one parameter object of `tool` by name.
fn findParam(tool: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const params_v = tool.get("parameters") orelse return null;
    if (params_v != .array) return null;
    for (params_v.array.items) |item| {
        if (item != .object) continue;
        const n = item.object.get("name") orelse continue;
        if (n != .string) continue;
        if (std.mem.eql(u8, n.string, name)) return item.object;
    }
    return null;
}

/// True when `tool` publishes `param` with `required: true`.
fn paramIsRequired(tool: std.json.ObjectMap, param: []const u8) bool {
    const p = findParam(tool, param) orelse return false;
    const r = p.get("required") orelse return false;
    return r == .bool and r.bool;
}

test "registry publishes `cwd` as REQUIRED on every path-taking tool" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const tools_v = doc.get("tools") orelse {
        std.debug.print("registry response has no `tools`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (tools_v != .array) {
        std.debug.print("registry `tools` is not an array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const tools = tools_v.array;

    for (PATH_TOOLS) |name| {
        const tool = findTool(tools, name) orelse {
            std.debug.print("registry is missing '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        };
        if (!paramIsRequired(tool, "cwd")) {
            std.debug.print("'{s}' does not publish a REQUIRED `cwd` parameter\n", .{name});
            return error.TestUnexpectedResult;
        }
        // The parameter the cwd is a base FOR must still be there: dropping
        // `path` would make `cwd` the only directory input, which is not the
        // shape any of these tools document.
        const path_param_name: []const u8 = if (std.mem.eql(u8, name, "present_files")) "files" else "path";
        if (findParam(tool, path_param_name) == null) {
            std.debug.print("'{s}' lost its `{s}` parameter\n", .{ name, path_param_name });
            return error.TestUnexpectedResult;
        }
    }
}

test "registry publishes NO `cwd` for the tools that dropped it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const tools = (doc.get("tools") orelse return error.TestUnexpectedResult).array;

    // Positive control: the same query that finds nothing below DOES find a
    // `cwd` on a path tool, so an empty `parameters` array would fail here
    // instead of passing everywhere.
    const probe = findTool(tools, "read_file") orelse return error.TestUnexpectedResult;
    try testing.expect(findParam(probe, "cwd") != null);

    for (CWD_FREE_TOOLS) |name| {
        const tool = findTool(tools, name) orelse {
            std.debug.print("registry is missing '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        };
        if (findParam(tool, "cwd") != null) {
            std.debug.print("'{s}' still publishes a `cwd` parameter\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "registry no longer publishes the swept dead tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const tools = (doc.get("tools") orelse return error.TestUnexpectedResult).array;

    // Control: the lookup used below finds a name that IS registered, so a
    // mistyped field (`tool_name` instead of `name`) cannot make every
    // absence assertion pass for the wrong reason.
    try testing.expect(findTool(tools, "read_file") != null);

    for (REMOVED_TOOLS) |name| {
        if (findTool(tools, name) != null) {
            std.debug.print("swept tool '{s}' is still in the registry\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}
