// Functional wire verification for the unified `command` tool.
//
// Zig port of `tests/functional/command_tool_test.py` (same test names,
// same order).
//
// Branch: worktree/pabrik-unify-command (commit `unify: add command
// tool merged from bash+pwsh`).
//
// What this covers
// ================
// The unify change merges `bash` + `pwsh` into a single `command` tool
// (`src/modules/agent/tools/command.zig`) that dispatches per-OS
// (`pwsh` on Windows, `bash` elsewhere). `bash`/`pwsh` survive only as
// unregistered shim modules (they still compile) — the equipped
// registry (`tools_equipped.zig`: `equips()` +
// `UNIFIED_TOOL_REGISTRY()`) exposes `command` ONLY.
//
// A full end-to-end LLM agent run (`echo hello` via chat) is too heavy
// for a wire test (it needs a stub LLM that returns a tool_call for
// `command`), so this test verifies the wire-visible halves instead —
// the same strategy as `agent_add_mcp_server_test.py`:
//
//   * REGISTRY — GET /api/agent-tools/registry exposes `command` and
//     NOT `bash` / `pwsh` (proves the equipped surface is
//     command-only).
//   * ENABLE/DISABLE — POST/DELETE /api/agents/:id/tools round-trips
//     `command` (proves the per-agent allowlist path accepts the new
//     name; unknown names 400).
//   * LEGACY — POST `bash` / `pwsh` now 400s (proves the old names are
//     no longer equipped).
//
// The Python original imported `DEFAULT_AGENT_TOOLS` and
// `agent_defaults_without` from `tests/functional/default_tools.py`. A
// Zig test package can only reach a NON-test file if `root.zig` names
// it in `suites`, and `root.zig` is owned by another agent for this
// port — so both are transcribed here, ONCE, and
// `agentDefaultsWithout` derives the second list from the first at
// comptime exactly as the Python helper did. The `comptime` block then
// re-asserts the invariants `default_tools.py` states in prose, so a
// drift fails at COMPILE time. It cannot catch "someone added a backend
// tool and forgot to transcribe it"; the header of `default_tools.py`
// names that one file to re-read when `DEFAULT_AGENT_TOOLS` changes —
// the same limitation `agent_tools_defaults_test.zig` documents.
//
// Paths: the Python original passed a literal `"/tmp/command-tool-test"`.
// The server validates an agent's `path` with `std.fs.path.isAbsolute`,
// which is FALSE for a leading-slash path on Windows, so this port
// derives every path from `h.temp_dir` — see `harness.harnessPath`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Expected tool lists — mirrors tests/functional/default_tools.py
// ============================================================================

/// Mirrors `DEFAULT_AGENT_TOOLS` — 33 names, sorted ASC, matching the
/// wire order of `GET /api/agents/:agent_id/tools`.
///
/// `delete_document` is deliberately ABSENT: it is irreversible, so it
/// is registered (and therefore one tick away in the Settings → Tools
/// checklist, which reads the same registry) but never seeded.
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
    "save_memory",
    "search",
    "search_documents",
    "search_skills",
    "search_tool",
    "spawn_sub_agent",
    "text_replace",
    "update_plan",
    "use_skill",
    "use_tool",
    "used_tools",
    "view_tool",
    "web_search",
    "write_file",
};

fn sliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn isSorted(list: []const []const u8) bool {
    for (list, 0..) |item, i| {
        if (i == 0) continue;
        if (std.mem.order(u8, list[i - 1], item) != .lt) return false;
    }
    return true;
}

/// Mirrors `default_tools.agent_defaults_without("command")` — the
/// seeded agent list minus one tool, still sorted ASC.
///
/// Used as the post-DELETE expectation: disabling `command` must leave
/// exactly the defaults that are not `command`, not a re-derived set.
/// Derived at COMPILE time from `EXPECTED_DEFAULTS` so the two lists
/// cannot drift — a `var` here would not do: a global holding a
/// pointer to a comptime var is rejected ("global variable contains
/// reference to comptime var"), so the buffer is copied into a `const`
/// before its address escapes the block.
const DEFAULTS_MINUS_COMMAND: []const []const u8 = blk: {
    var buf: [EXPECTED_DEFAULTS.len - 1][]const u8 = undefined;
    var i: usize = 0;
    for (EXPECTED_DEFAULTS) |name| {
        if (std.mem.eql(u8, name, "command")) continue;
        buf[i] = name;
        i += 1;
    }
    const frozen: [EXPECTED_DEFAULTS.len - 1][]const u8 = buf;
    break :blk &frozen;
};

comptime {
    @setEvalBranchQuota(20_000);
    if (EXPECTED_DEFAULTS.len != 33)
        @compileError("EXPECTED_DEFAULTS must mirror default_tools.py's 33-name DEFAULT_AGENT_TOOLS");
    if (!isSorted(&EXPECTED_DEFAULTS))
        @compileError("EXPECTED_DEFAULTS must be sorted ASC (the wire order the assertions compare against)");
    if (DEFAULTS_MINUS_COMMAND.len != EXPECTED_DEFAULTS.len - 1)
        @compileError("DEFAULTS_MINUS_COMMAND must be EXPECTED_DEFAULTS minus exactly one tool");
    if (!isSorted(DEFAULTS_MINUS_COMMAND))
        @compileError("DEFAULTS_MINUS_COMMAND must be sorted ASC");
    if (sliceContains(DEFAULTS_MINUS_COMMAND, "command"))
        @compileError("DEFAULTS_MINUS_COMMAND must NOT contain `command`");
}

// ============================================================================
// Helpers (mirror agent_tools_toggle_test.py)
// ============================================================================

fn boot() !Harness {
    return Harness.boot(io, gpa, .{});
}

/// `POST /api/workspaces` → the new workspace's id (an owned copy).
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
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

/// `POST /api/workspaces/:ws/items/agent` → the new item id.
///
/// Asserts the `{item, agent}` envelope AND the 1-1 invariant
/// `agents.id == workspace_items.id` on the way out — the Python helper
/// asserted both, and the envelope is what the frontend destructures.
fn createAgent(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const path = try harness.harnessPath(gpa, h.temp_dir, &.{"command-tool-test"});
    defer gpa.free(path);
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"{s}\",\"path\":\"{s}\"}}",
        .{ name, path },
    );
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{workspace_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const item = doc.object("item") orelse {
        std.debug.print("missing 'item' envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const agent = doc.object("agent") orelse {
        std.debug.print("missing 'agent' envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const item_id = item.get("id") orelse return error.TestUnexpectedResult;
    const agent_id = agent.get("id") orelse return error.TestUnexpectedResult;
    if (item_id != .string or agent_id != .string) {
        std.debug.print("item.id / agent.id must both be strings: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, item_id.string, agent_id.string)) {
        std.debug.print(
            "agents.id should equal workspace_items.id (1-1 invariant). " ++
                "got agent.id='{s}' vs item.id='{s}'\n",
            .{ agent_id.string, item_id.string },
        );
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, item_id.string);
}

/// The registry's tool names, in wire order.
///
/// `assert len(names) >= 1` in the Python original: a registry that
/// returned zero tools would make every membership assertion below pass
/// vacuously, so the non-empty check is load-bearing, not a smoke test.
///
/// Every name is DUPPED: the borrowed slices live inside the parsed
/// JSON arena, which this function's `defer doc.deinit()` reaps before
/// the caller ever looks at them.
fn registryNames(h: *Harness) ![][]const u8 {
    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tools = doc.array("tools") orelse {
        std.debug.print("registry has no `tools` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (tools.items.len < 1) {
        std.debug.print("registry returned 0 tools — fixture broken?\n", .{});
        return error.TestUnexpectedResult;
    }

    const names = try gpa.alloc([]const u8, tools.items.len);
    errdefer gpa.free(names);
    for (tools.items, 0..) |item, i| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                std.debug.print("registry tools[{d}] is not an object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        const name = switch (obj.get("name") orelse {
            std.debug.print("registry tools[{d}] has no `name`\n", .{i});
            return error.TestUnexpectedResult;
        }) {
            .string => |v| v,
            else => {
                std.debug.print("registry tools[{d}].name is not a string\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        names[i] = try gpa.dupe(u8, name);
    }
    return names;
}

/// `GET /api/agents/:id/tools` → the enabled tool names, in wire order.
///
/// Unlike the registry, this one does NOT assert non-empty: "every tool
/// deleted" is a legitimate state the lifecycle test walks through. The
/// names are duped for the same arena reason as `registryNames`.
fn listTools(h: *Harness, agent_id: []const u8) ![][]const u8 {
    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tools = doc.array("tools") orelse {
        std.debug.print("tools response should be {{tools: list}}, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    const names = try gpa.alloc([]const u8, tools.items.len);
    errdefer gpa.free(names);
    for (tools.items, 0..) |item, i| {
        names[i] = try gpa.dupe(u8, switch (item) {
            .string => |s| s,
            else => {
                std.debug.print("tools[{d}] is not a string\n", .{i});
                return error.TestUnexpectedResult;
            },
        });
    }
    return names;
}

fn freeNames(names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// `POST /api/agents/:id/tools` → 201 + the created row.
///
/// Asserts `tool_name` round-tripped, which is what proves the wire
/// field name is the one the frontend sends (not, say, `name`).
fn enableTool(h: *Harness, agent_id: []const u8, tool_name: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"tool_name\":\"{s}\"}}", .{tool_name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got = doc.str("tool_name") orelse {
        std.debug.print("enable response has no `tool_name`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, tool_name)) {
        std.debug.print("expected tool_name='{s}', got '{s}'\n", .{ tool_name, got });
        return error.TestUnexpectedResult;
    }
}

/// `POST .../tools` with a status the CALLER asserts (409 / 400). The
/// body is discarded: the Python original only asserted the status.
fn postToolExpecting(h: *Harness, agent_id: []const u8, tool_name: []const u8, expect: []const u16) !void {
    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(url);
    const body = try std.fmt.allocPrint(gpa, "{{\"tool_name\":\"{s}\"}}", .{tool_name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = expect });
    r.deinit();
}

fn deleteTool(h: *Harness, agent_id: []const u8, tool_name: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/{s}", .{ agent_id, tool_name });
    defer gpa.free(url);

    var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // `assert r.json().get("ok") is True` — an absent key must fail.
    const ok = doc.boolean("ok") orelse {
        std.debug.print("delete response has no boolean `ok`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expect(ok);
}

/// Exact-equality against the wire's `tools` array. The Python original
/// compared the whole list, and the whole list IS the contract, so a
/// length mismatch, an order mismatch and a name mismatch all fail.
fn expectToolList(got: []const []const u8, expected: []const []const u8, what: []const u8) !void {
    if (got.len != expected.len) {
        std.debug.print("{s}: expected {d} tools, got {d}\n", .{ what, expected.len, got.len });
        printList("got", got);
        printList("want", expected);
        return error.TestUnexpectedResult;
    }
    for (got, expected, 0..) |g, w, i| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("{s}: tools[{d}] = \"{s}\", expected \"{s}\"\n", .{ what, i, g, w });
            return error.TestUnexpectedResult;
        }
    }
}

fn printList(label: []const u8, list: []const []const u8) void {
    std.debug.print("  {s}: [", .{label});
    for (list, 0..) |item, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{item});
    }
    std.debug.print("]\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

// TestCommandRegistry — the equipped surface is `command` ONLY.
test "registry_exposes_only_command_no_bash_no_pwsh" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const names = try registryNames(&h);
    defer freeNames(names);

    if (sliceContains(names, "command") == false) {
        std.debug.print("registry missing unified 'command' tool\n", .{});
        printList("names", names);
        return error.TestUnexpectedResult;
    }
    if (sliceContains(names, "bash")) {
        std.debug.print("registry still equips legacy 'bash'\n", .{});
        printList("names", names);
        return error.TestUnexpectedResult;
    }
    if (sliceContains(names, "pwsh")) {
        std.debug.print("registry still equips legacy 'pwsh'\n", .{});
        printList("names", names);
        return error.TestUnexpectedResult;
    }
}

// TestCommandEnableDisable — DELETE command removes it; re-POST
// restores it (round-trip).
test "command_enable_list_disable_lifecycle" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "cmd-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "cmd-agent");
    defer gpa.free(agent_id);

    {
        const names = try listTools(&h, agent_id);
        defer freeNames(names);
        // Fresh agents are born with the seeded defaults (sorted ASC).
        try expectToolList(names, &EXPECTED_DEFAULTS, "fresh agent");
    }

    try deleteTool(&h, agent_id, "command");

    {
        const names = try listTools(&h, agent_id);
        defer freeNames(names);
        try expectToolList(names, DEFAULTS_MINUS_COMMAND, "after DELETE command");
    }

    try enableTool(&h, agent_id, "command");

    {
        const names = try listTools(&h, agent_id);
        defer freeNames(names);
        try expectToolList(names, &EXPECTED_DEFAULTS, "after re-POST command");
    }
}

// TestCommandEnableDisable — POST of seeded `command` hits the UNIQUE
// index → 409.
test "command_enable_duplicate_is_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "cmd-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "cmd-agent");
    defer gpa.free(agent_id);

    try postToolExpecting(&h, agent_id, "command", &.{409});

    // The rejected POST must leave the seeded set exactly as it was.
    const names = try listTools(&h, agent_id);
    defer freeNames(names);
    try expectToolList(names, &EXPECTED_DEFAULTS, "after duplicate POST");
}

// TestLegacyNamesRejected — the removed `bash` name is no longer
// equipped (unknown → 400).
test "bash_enable_now_400s_after_unify" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "cmd-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "cmd-agent");
    defer gpa.free(agent_id);

    try postToolExpecting(&h, agent_id, "bash", &.{400});

    const names = try listTools(&h, agent_id);
    defer freeNames(names);
    try expectToolList(names, &EXPECTED_DEFAULTS, "after rejected bash POST");
}

// TestLegacyNamesRejected — the removed `pwsh` name is no longer
// equipped (unknown → 400).
test "pwsh_enable_now_400s_after_unify" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "cmd-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "cmd-agent");
    defer gpa.free(agent_id);

    try postToolExpecting(&h, agent_id, "pwsh", &.{400});

    const names = try listTools(&h, agent_id);
    defer freeNames(names);
    try expectToolList(names, &EXPECTED_DEFAULTS, "after rejected pwsh POST");
}
