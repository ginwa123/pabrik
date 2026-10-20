// Functional tests for the Agent Mode tool toggle wire. Zig port of
// `tests/functional/agent_tools_toggle_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Expected tool lists — mirrors tests/functional/default_tools.py
// ============================================================================

/// Mirrors `DEFAULT_AGENT_TOOLS` — 36 names, sorted ASC, matching the
/// wire order of `GET /api/agents/:agent_id/tools`.
const EXPECTED_DEFAULTS = [_][]const u8{
    "add_document",
    "add_skill",
    "ask_user",
    "command",
    "edit_document",
    "edit_skill",
    "get_plan",
    "glob",
    "list_directory",
    "list_secrets",
    "list_sub_agent",
    "list_web_search_providers",
    "load_memory",
    "present_files",
    "process",
    "read_file",
    "read_workspace_session",
    "remove_file",
    "remove_skill",
    "run_session",
    "save_memory",
    "search",
    "search_documents",
    "search_skills",
    "search_tool",
    "spawn_sub_agent",
    "text_replace",
    "update_plan",
    "update_plan_text_replace",
    "use_skill",
    "use_tool",
    "used_tools",
    "view_session",
    "view_tool",
    "web_search",
    "write_file",
};

/// An in-registry tool that is NEVER seeded, so enabling it is a clean
/// "one extra row" delta against the defaults. Python called this
/// `NON_DEFAULT_TOOL`.
const NON_DEFAULT_TOOL = "preview_design_page";

fn isSorted(list: []const []const u8) bool {
    for (list, 0..) |item, i| {
        if (i == 0) continue;
        if (std.mem.order(u8, list[i - 1], item) != .lt) return false;
    }
    return true;
}

comptime {
    @setEvalBranchQuota(20_000);
    if (EXPECTED_DEFAULTS.len != 36)
        @compileError("EXPECTED_DEFAULTS must mirror default_tools.py's 36-name DEFAULT_AGENT_TOOLS");
    if (!isSorted(&EXPECTED_DEFAULTS))
        @compileError("EXPECTED_DEFAULTS must be sorted ASC (the wire order the assertions compare against)");
    for (EXPECTED_DEFAULTS) |name| {
        if (std.mem.eql(u8, name, NON_DEFAULT_TOOL))
            @compileError("NON_DEFAULT_TOOL must NOT be one of the seeded defaults, or the enable assertions are vacuous");
    }
}

// ============================================================================
// Helpers
// ============================================================================

/// An owned list of strings copied out of a JSON response. A `harness.Json`
/// BORROWS from the `Response`'s body buffer, so a helper cannot hand one
/// back to the caller (rule 7).
const NameList = struct {
    items: [][]const u8,

    fn deinit(self: *NameList) void {
        for (self.items) |s| gpa.free(s);
        gpa.free(self.items);
        self.* = undefined;
    }
};

fn freeNameSlice(slice: [][]const u8) void {
    gpa.free(slice);
}

/// Sorted union of `base` and `extras` — the Zig spelling of Python's
/// `sorted(EXPECTED_DEFAULTS + picked)`.
fn sortedUnion(base: []const []const u8, extras: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    try out.appendSlice(gpa, extras);

    // Insertion sort by name — n is ~35, so this is the cheapest
    // correct thing and it does not need `base` to be pre-sorted.
    var i: usize = 1;
    while (i < out.items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, out.items[j - 1], out.items[j]) == .gt) : (j -= 1) {
            std.mem.swap([]const u8, &out.items[j - 1], &out.items[j]);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn expectNames(got: NameList, want: []const []const u8, what: []const u8) !void {
    if (got.items.len != want.len) {
        std.debug.print("{s}: expected {d} tools, got {d}\n", .{ what, want.len, got.items.len });
        printNames(&got, "got");
        printSlice(want, "want");
        return error.TestUnexpectedResult;
    }
    for (got.items, want, 0..) |g, w, idx| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("{s}: tools[{d}] = \"{s}\", expected \"{s}\"\n", .{ what, idx, g, w });
            return error.TestUnexpectedResult;
        }
    }
}

fn printNames(list: *const NameList, label: []const u8) void {
    std.debug.print("  {s}: [", .{label});
    for (list.items, 0..) |s, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{s});
    }
    std.debug.print("]\n", .{});
}

fn printSlice(list: []const []const u8, label: []const u8) void {
    std.debug.print("  {s}: [", .{label});
    for (list, 0..) |s, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{s});
    }
    std.debug.print("]\n", .{});
}

fn boot() !Harness {
    return Harness.boot(io, gpa, .{});
}

/// `POST /api/workspaces` → the new workspace's id (owned).
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":{f}}}", .{std.json.fmt(name, .{})});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("POST /api/workspaces returned no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

/// `POST /api/workspaces/:ws/items/agent` → the agent id (owned), after
/// asserting the `{item, agent}` envelope and the 1-1 id invariant.
fn createAgent(h: *Harness, ws_id: []const u8, name: []const u8, path: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":{f},\"path\":{f}}}",
        .{ std.json.fmt(name, .{}), std.json.fmt(path, .{}) },
    );
    defer gpa.free(body);
    const create_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(create_path);

    var r = try h.http(io, .POST, create_path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const item = doc.object("item") orelse {
        std.debug.print("missing `item` envelope in agent-create response\n", .{});
        return error.TestUnexpectedResult;
    };
    const agent = doc.object("agent") orelse {
        std.debug.print("missing `agent` envelope in agent-create response\n", .{});
        return error.TestUnexpectedResult;
    };
    const item_type = switch (item.get("item_type") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("created item has no string `item_type`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, item_type, "agent")) {
        std.debug.print("created item should be type `agent`, got \"{s}\"\n", .{item_type});
        return error.TestUnexpectedResult;
    }
    const item_id = switch (item.get("id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("created item has no string `id`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    const agent_id = switch (agent.get("id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("created agent has no string `id`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, agent_id, item_id)) {
        std.debug.print(
            "agents.id should equal workspace_items.id (1-1 invariant); agent.id={s} vs item.id={s}\n",
            .{ agent_id, item_id },
        );
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, item_id);
}

/// The default agent path for this suite, derived from the harness
/// tempdir (see the header note on `isAbsolute`).
fn agentPath(h: *Harness) ![]u8 {
    return harness.harnessPath(gpa, h.temp_dir, &.{"agent-tools-toggle-test"});
}

/// `GET /api/agents/:agent_id/tools` → the enabled tool_names (owned).
fn listTools(h: *Harness, agent_id: []const u8) !NameList {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("tools") orelse {
        std.debug.print("tools response should be {{tools: list}}\n", .{});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => {
                std.debug.print("tools[] contains a non-string entry\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        try out.append(gpa, try gpa.dupe(u8, s));
    }
    return .{ .items = try out.toOwnedSlice(gpa) };
}

/// The `AgentToolRow` a successful enable returned, copied out so it outlives
/// the response body. Wire shape: the backend returns the row DIRECTLY (not
/// wrapped in `{tool: ...}`) — see the Python docstring on `_enable_tool`.
const EnabledTool = struct {
    tool_name: []u8,
    enabled: i64,

    fn deinit(self: *EnabledTool) void {
        gpa.free(self.tool_name);
        self.* = undefined;
    }
};

fn enableTool(h: *Harness, agent_id: []const u8, tool_name: []const u8) !EnabledTool {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(gpa, "{{\"tool_name\":{f}}}", .{std.json.fmt(tool_name, .{})});
    defer gpa.free(body);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got_name = doc.str("tool_name") orelse {
        std.debug.print("enable response has no string `tool_name`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_name, tool_name)) {
        std.debug.print("expected tool_name={s}, got {s}\n", .{ tool_name, got_name });
        return error.TestUnexpectedResult;
    }
    const got_agent = doc.str("agent_id") orelse {
        std.debug.print("enable response has no string `agent_id`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_agent, agent_id)) {
        std.debug.print("expected agent_id={s}, got {s}\n", .{ agent_id, got_agent });
        return error.TestUnexpectedResult;
    }
    const row_id = doc.str("id") orelse "";
    if (!std.mem.startsWith(u8, row_id, "at_")) {
        std.debug.print("expected row id to start with `at_`, got \"{s}\"\n", .{row_id});
        return error.TestUnexpectedResult;
    }
    const enabled = doc.int("enabled") orelse {
        std.debug.print("enable response has no integer `enabled`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (enabled != 1) {
        std.debug.print("expected enabled=1, got {d}\n", .{enabled});
        return error.TestUnexpectedResult;
    }
    return .{ .tool_name = try gpa.dupe(u8, got_name), .enabled = enabled };
}

/// `DELETE /api/agents/:agent_id/tools/:tool_name` → asserts `{ok: true}`.
fn disableTool(h: *Harness, agent_id: []const u8, tool_name: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/{s}", .{ agent_id, tool_name });
    defer gpa.free(path);
    var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const ok = doc.boolean("ok") orelse {
        std.debug.print("delete response has no boolean `ok`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!ok) {
        std.debug.print("expected ok=true from the delete response\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// `GET /api/agent-tools/registry` → every canonical tool name (owned). Used
/// to pick tool_names we KNOW are valid, so the enable-unknown cases are
/// intentional rather than accidental.
fn registryTools(h: *Harness) !NameList {
    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("tools") orelse {
        std.debug.print("registry response has no `tools` array\n", .{});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const s = switch (obj.get("name") orelse std.json.Value{ .null = {} }) {
            .string => |str| str,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, s));
    }
    if (out.items.len < 1) {
        std.debug.print("registry returned 0 tools — fixture broken?\n", .{});
        return error.TestUnexpectedResult;
    }
    return .{ .items = try out.toOwnedSlice(gpa) };
}

fn isDefaultTool(name: []const u8) bool {
    for (EXPECTED_DEFAULTS) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

/// The registry names that are NOT seeded defaults, copied out as a
/// borrowed-name slice valid while `registry` lives. Python: `[n for n in
/// registry if n not in EXPECTED_DEFAULTS]`.
fn nonDefaultCandidates(registry: NameList) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (registry.items) |n| {
        if (!isDefaultTool(n)) try out.append(gpa, n);
    }
    return out.toOwnedSlice(gpa);
}

// ============================================================================
// TestEnableTool — POST /api/agents/:agent_id/tools
// ============================================================================

// POST /tools inserts a row and returns the flat AgentToolRow envelope.
test "post_inserts_row_and_returns_envelope" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    var tool = try enableTool(&h, agent_id, NON_DEFAULT_TOOL);
    defer tool.deinit();
    if (!std.mem.eql(u8, tool.tool_name, NON_DEFAULT_TOOL)) {
        std.debug.print("expected tool_name={s}, got {s}\n", .{ NON_DEFAULT_TOOL, tool.tool_name });
        return error.TestUnexpectedResult;
    }
    if (tool.enabled != 1) {
        std.debug.print("expected enabled=1, got {d}\n", .{tool.enabled});
        return error.TestUnexpectedResult;
    }

    // The DB row persists beyond the create call — list now reflects
    // defaults + the new tool (sorted ASC).
    const expected = try sortedUnion(&EXPECTED_DEFAULTS, &.{NON_DEFAULT_TOOL});
    defer freeNameSlice(expected);
    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, expected, "after enabling a non-default tool");
}

// A second POST with the same (agent_id, tool_name) hits the UNIQUE
// index → 409 Conflict, and leaves the state untouched.
test "post_rejects_duplicate_with_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    {
        var tool = try enableTool(&h, agent_id, NON_DEFAULT_TOOL);
        tool.deinit();
    }

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(tools_path);
    const body = try std.fmt.allocPrint(gpa, "{{\"tool_name\":{f}}}", .{std.json.fmt(NON_DEFAULT_TOOL, .{})});
    defer gpa.free(body);
    var dup = try h.http(io, .POST, tools_path, .{ .json_body = body, .expect = &.{409} });
    dup.deinit();

    // State unchanged — defaults + exactly one extra row.
    const expected = try sortedUnion(&EXPECTED_DEFAULTS, &.{NON_DEFAULT_TOOL});
    defer freeNameSlice(expected);
    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, expected, "after a rejected duplicate enable");
}

// A tool_name absent from the registry → 400, and no row is created.
test "post_rejects_unknown_tool_with_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    // `this_tool_definitely_does_not_exist_xyz` is not in the registry
    // by construction.
    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(tools_path);
    var bad = try h.http(io, .POST, tools_path, .{
        .json_body = "{\"tool_name\":\"this_tool_definitely_does_not_exist_xyz\"}",
        .expect = &.{400},
    });
    bad.deinit();

    // No row created — defaults unchanged.
    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, &EXPECTED_DEFAULTS, "after a rejected unknown tool");
}

// An empty `tool_name` in the body → 400 (ToolNameRequired).
test "post_rejects_empty_tool_name_with_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(tools_path);
    var r = try h.http(io, .POST, tools_path, .{
        .json_body = "{\"tool_name\":\"\"}",
        .expect = &.{400},
    });
    r.deinit();
}

// ============================================================================
// TestListTools — GET /api/agents/:agent_id/tools
// ============================================================================

// Fresh agents are born with DEFAULT_AGENT_TOOLS, sorted ASC.
test "defaults_seeded_on_create" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, &EXPECTED_DEFAULTS, "fresh agent");
}

// Enabling three non-default tools in REVERSE alphabetical order still
// lists them ASC — the agent-loop filter and the frontend list both
// depend on that.
test "returns_sorted_ascending" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    var registry = try registryTools(&h);
    defer registry.deinit();
    const candidates = try nonDefaultCandidates(registry);
    defer gpa.free(candidates);
    if (candidates.len < 3) {
        std.debug.print("need >=3 non-default tools in registry; got {d}\n", .{candidates.len});
        return error.TestUnexpectedResult;
    }
    const picked = candidates[0..3];

    // Insert in reverse order.
    var i: usize = picked.len;
    while (i > 0) {
        i -= 1;
        var tool = try enableTool(&h, agent_id, picked[i]);
        tool.deinit();
    }

    const expected = try sortedUnion(&EXPECTED_DEFAULTS, picked);
    defer freeNameSlice(expected);
    var listed = try listTools(&h, agent_id);
    defer listed.deinit();
    try expectNames(listed, expected, "GET /tools after reverse-order enables");
}

// ============================================================================
// TestDisableTool — DELETE /api/agents/:agent_id/tools/:tool_name
// ============================================================================

// DELETE removes the row; the list drops back to the seeded defaults. The
// DELETE path param is `:tool_name` (the plan's Task 1+2 rename), so this
// route would 404 against the old `:tool_id` spelling.
test "delete_removes_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    {
        var tool = try enableTool(&h, agent_id, NON_DEFAULT_TOOL);
        tool.deinit();
    }
    {
        const with_extra = try sortedUnion(&EXPECTED_DEFAULTS, &.{NON_DEFAULT_TOOL});
        defer freeNameSlice(with_extra);
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, with_extra, "after enabling");
    }

    try disableTool(&h, agent_id, NON_DEFAULT_TOOL);

    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, &EXPECTED_DEFAULTS, "after disabling");
}

// Deleting twice is a 200 no-op both times — never a 404.
test "delete_is_idempotent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    {
        var tool = try enableTool(&h, agent_id, NON_DEFAULT_TOOL);
        tool.deinit();
    }

    // First delete removes the row.
    try disableTool(&h, agent_id, NON_DEFAULT_TOOL);
    {
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, &EXPECTED_DEFAULTS, "after the first delete");
    }

    // Second delete is a no-op (200, not 404) — matches the useCase's
    // scope-by-agent_id design + handler semantics.
    try disableTool(&h, agent_id, NON_DEFAULT_TOOL);
    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, &EXPECTED_DEFAULTS, "after the second (no-op) delete");
}

// Deleting a tool_name that was never enabled is a no-op, not a 404.
test "delete_unknown_tool_name_no_ops" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    try disableTool(&h, agent_id, "totally_nonexistent_tool_xyz");

    var got = try listTools(&h, agent_id);
    defer got.deinit();
    try expectNames(got, &EXPECTED_DEFAULTS, "after a no-op delete");
}

// The empty path segment resolves to `tools/<empty>`, which the router
// happily matches with `tool_name=""`; the handler validates it and
// answers 400 — NOT 404.
test "delete_rejects_empty_tool_name" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/", .{agent_id});
    defer gpa.free(tools_path);
    var r = try h.http(io, .DELETE, tools_path, .{ .expect = &.{400} });
    r.deinit();
}

// ============================================================================
// TestToolToggleLifecycle — end-to-end enable/list/delete
// ============================================================================

// enable a → list → enable b → delete a → delete b → re-enable a.
test "full_lifecycle" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ws");
    defer gpa.free(ws_id);
    const path = try agentPath(&h);
    defer gpa.free(path);
    const agent_id = try createAgent(&h, ws_id, "test-agent", path);
    defer gpa.free(agent_id);

    var registry = try registryTools(&h);
    defer registry.deinit();
    const candidates = try nonDefaultCandidates(registry);
    defer gpa.free(candidates);
    if (candidates.len < 2) {
        std.debug.print("need >=2 non-default tools for lifecycle; got {d}\n", .{candidates.len});
        return error.TestUnexpectedResult;
    }
    const tool_a = candidates[0];
    const tool_b = candidates[1];

    // 1. Enable tool_a.
    {
        var t = try enableTool(&h, agent_id, tool_a);
        t.deinit();
    }
    {
        const want = try sortedUnion(&EXPECTED_DEFAULTS, &.{tool_a});
        defer freeNameSlice(want);
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, want, "step 1: after enabling tool_a");
    }

    // 2. Enable tool_b (mixed alphabetical order — proves the list
    //    returns ASC sorted regardless of insertion order).
    {
        var t = try enableTool(&h, agent_id, tool_b);
        t.deinit();
    }
    {
        const want = try sortedUnion(&EXPECTED_DEFAULTS, &.{ tool_a, tool_b });
        defer freeNameSlice(want);
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, want, "step 2: after enabling tool_b");
    }

    // 3. Disable tool_a. tool_b should remain.
    try disableTool(&h, agent_id, tool_a);
    {
        const want = try sortedUnion(&EXPECTED_DEFAULTS, &.{tool_b});
        defer freeNameSlice(want);
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, want, "step 3: after disabling tool_a");
    }

    // 4. Disable tool_b. Back to the seeded defaults.
    try disableTool(&h, agent_id, tool_b);
    {
        var got = try listTools(&h, agent_id);
        defer got.deinit();
        try expectNames(got, &EXPECTED_DEFAULTS, "step 4: after disabling tool_b");
    }

    // 5. State survives: re-enabling tool_a starts fresh — no UNIQUE
    //    violation, because the row was deleted.
    {
        var t = try enableTool(&h, agent_id, tool_a);
        t.deinit();
    }
    const want = try sortedUnion(&EXPECTED_DEFAULTS, &.{tool_a});
    defer freeNameSlice(want);
    var final_got = try listTools(&h, agent_id);
    defer final_got.deinit();
    try expectNames(final_got, want, "step 5: after re-enabling tool_a");
}

// Tool toggles on agent_A do not affect agent_B. Both agents live in separate
// workspaces (isolation proof; a same-workspace second create also works
// since the workspace_item_id fix in workspace_items_create_agent.zig).
test "scoped_to_agent_id" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_a = try createWorkspace(&h, "ws-A");
    defer gpa.free(ws_a);
    const ws_b = try createWorkspace(&h, "ws-B");
    defer gpa.free(ws_b);
    const path_a = try agentPath(&h);
    defer gpa.free(path_a);
    const path_b = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-tools-toggle-test-b"});
    defer gpa.free(path_b);

    const agent_a = try createAgent(&h, ws_a, "agent-A", path_a);
    defer gpa.free(agent_a);
    const agent_b = try createAgent(&h, ws_b, "agent-B", path_b);
    defer gpa.free(agent_b);

    {
        var t = try enableTool(&h, agent_a, NON_DEFAULT_TOOL);
        t.deinit();
    }

    const want_a = try sortedUnion(&EXPECTED_DEFAULTS, &.{NON_DEFAULT_TOOL});
    defer freeNameSlice(want_a);

    // agent_B keeps its own seeded defaults — proving no cross-agent
    // leakage regardless of workspace.
    {
        var got_b = try listTools(&h, agent_b);
        defer got_b.deinit();
        try expectNames(got_b, &EXPECTED_DEFAULTS, "agent_B after toggling agent_A");
    }
    {
        var got_a = try listTools(&h, agent_a);
        defer got_a.deinit();
        try expectNames(got_a, want_a, "agent_A after its own enable");
    }

    // DELETE scoping: deleting the extra tool from agent_B is a no-op
    // (agent_B never had it), and agent_A's row is untouched.
    try disableTool(&h, agent_b, NON_DEFAULT_TOOL);
    var got_a = try listTools(&h, agent_a);
    defer got_a.deinit();
    try expectNames(got_a, want_a, "agent_A after a no-op delete on agent_B");
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = boot;
    _ = createWorkspace;
    _ = createAgent;
    _ = agentPath;
    _ = listTools;
    _ = enableTool;
    _ = disableTool;
    _ = registryTools;
    _ = isDefaultTool;
    _ = nonDefaultCandidates;
    _ = sortedUnion;
    _ = expectNames;
    _ = printNames;
    _ = printSlice;
    _ = freeNameSlice;
    _ = NameList.deinit;
    _ = EnabledTool.deinit;
    _ = Harness.boot;
}
