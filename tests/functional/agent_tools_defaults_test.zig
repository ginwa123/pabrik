// Functional tests for default agent tools seeded at creation.
//
// Zig port of `tests/functional/agent_tools_defaults_test.py`
// (same test names).
//
// Plan: docs/superpowers/plans/2026-09-06-default-agent-tools-on-creation.md
//
// Covers:
//   * AGENT — POST /api/workspaces/:ws/items/agent →
//     GET /api/agents/:id/tools (as of 2026-09-16 this includes
//     `ask_user`, seeded for every agent mode) returns
//     EXPECTED_DEFAULTS (33 tools, sorted ASC).
//   * KANBAN — POST /api/workspaces/:ws/items/kanban →
//     GET /api/agent-kanbans/:id/tools returns the 33 agent defaults +
//     2 kanban tools (kanban_list, kanban_move_task) — 33 total — and
//     the bundle GET /api/workspaces/:ws/items/:id/agent_kanban is 200
//     (configured, not 404 NotConfigured).
//   * NO-BACKFILL — deleting all tools on a fresh agent leaves []
//     (empty is stable; the seed runs once at creation, never on read).
//
// WHY THE EXPECTED LISTS ARE INLINED HERE (and what keeps them honest):
// the Python original imported them from `tests/functional/default_tools.py`
// — "one copy, because there used to be four" per that module's header.
// A Zig test package can only reach a NON-test file if root.zig names it
// in `suites`, and root.zig is owned by another agent for this port, so
// the two lists are transcribed once each below. The `comptime` block
// then re-asserts the invariants `default_tools.py` states in prose —
// both lists sorted ASC, the kanban list exactly equal to the agent list
// plus the kanban pair, and the pair absent from the agent list — so a
// drift between the two fails at COMPILE time instead of in CI. It
// cannot catch "someone added a backend tool and forgot to transcribe
// it"; the header of `default_tools.py` names that one file to re-read
// when the backend's `DEFAULT_AGENT_TOOLS` changes.
//
// Paths: the Python original passed a literal `"/tmp/defaults-agent"`.
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
/// `delete_document` is deliberately ABSENT: it is irreversible, so it is
/// registered (and therefore one tick away in the Settings → Tools
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

/// Mirrors `DEFAULT_KANBAN_TOOLS` — the two tools seeded on top for a
/// kanban item, and nothing else.
const DEFAULT_KANBAN_TOOLS = [_][]const u8{
    "kanban_list",
    "kanban_move_task",
};

/// Mirrors `DEFAULT_KANBAN_SEEDED_TOOLS` — what a fresh kanban item is
/// born with: the agent defaults PLUS the kanban pair, sorted ASC.
const EXPECTED_KANBAN_DEFAULTS = [_][]const u8{
    "add_document",
    "add_skill",
    "ask_user",
    "command",
    "edit_document",
    "edit_skill",
    "get_plan",
    "glob",
    "kanban_list",
    "kanban_move_task",
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

comptime {
    @setEvalBranchQuota(20_000);
    if (EXPECTED_DEFAULTS.len != 33)
        @compileError("EXPECTED_DEFAULTS must mirror default_tools.py's 33-name DEFAULT_AGENT_TOOLS");
    if (EXPECTED_KANBAN_DEFAULTS.len != EXPECTED_DEFAULTS.len + 2)
        @compileError("EXPECTED_KANBAN_DEFAULTS must be EXPECTED_DEFAULTS plus exactly the two kanban tools");
    if (!isSorted(&EXPECTED_DEFAULTS))
        @compileError("EXPECTED_DEFAULTS must be sorted ASC (the wire order the assertions compare against)");
    if (!isSorted(&EXPECTED_KANBAN_DEFAULTS))
        @compileError("EXPECTED_KANBAN_DEFAULTS must be sorted ASC");
    for (EXPECTED_DEFAULTS) |name| {
        if (sliceContains(&DEFAULT_KANBAN_TOOLS, name))
            @compileError("kanban tools must NOT appear in EXPECTED_DEFAULTS: " ++ name);
    }
    for (EXPECTED_KANBAN_DEFAULTS) |name| {
        if (sliceContains(&EXPECTED_DEFAULTS, name)) continue;
        if (sliceContains(&DEFAULT_KANBAN_TOOLS, name)) continue;
        @compileError("EXPECTED_KANBAN_DEFAULTS carries a name that is neither an agent default nor a kanban tool: " ++ name);
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn boot() !Harness {
    return Harness.boot(io, gpa, .{});
}

/// `POST /api/workspaces` → the new workspace's id.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse return error.TestUnexpectedResult);
}

/// `POST .../items/{agent,kanban}` answers `{"item": {"id": ...}}`.
/// Returns an owned copy of that id.
fn createdItemId(doc: *const harness.Json) ![]u8 {
    const item = doc.object("item") orelse {
        std.debug.print("create response has no `item` object\n", .{});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("create response has no item.id\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("create response item.id is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

fn printToolList(arr: std.json.Array) void {
    std.debug.print("  got: [", .{});
    for (arr.items, 0..) |item, i| {
        if (i > 0) std.debug.print(", ", .{});
        switch (item) {
            .string => |s| std.debug.print("\"{s}\"", .{s}),
            else => std.debug.print("<non-string>", .{}),
        }
    }
    std.debug.print("]\n", .{});
}

fn printExpected(list: []const []const u8) void {
    std.debug.print("  want: [", .{});
    for (list, 0..) |item, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("\"{s}\"", .{item});
    }
    std.debug.print("]\n", .{});
}

/// Exact-equality against the wire's `tools` array. The Python original
/// compared the whole list, and the whole list IS the contract, so a
/// length mismatch, an order mismatch, and a name mismatch all fail.
fn expectToolList(doc: *const harness.Json, expected: []const []const u8, what: []const u8) !void {
    const arr = doc.array("tools") orelse {
        std.debug.print("{s}: response has no `tools` array\n", .{what});
        return error.TestUnexpectedResult;
    };
    if (arr.items.len != expected.len) {
        std.debug.print("{s}: expected {d} tools, got {d}\n", .{ what, expected.len, arr.items.len });
        printToolList(arr);
        printExpected(expected);
        return error.TestUnexpectedResult;
    }
    for (arr.items, expected, 0..) |item, want, i| {
        const got = switch (item) {
            .string => |s| s,
            else => {
                std.debug.print("{s}: tools[{d}] is not a string\n", .{ what, i });
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: tools[{d}] = \"{s}\", expected \"{s}\"\n", .{ what, i, got, want });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

// A freshly-created agent is born with DEFAULT_AGENT_TOOLS, exactly.
test "agent_create_seeds_default_tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "defaults-ws");
    defer gpa.free(ws_id);

    // Derived from `h.temp_dir` rather than a literal "/tmp/..." — the
    // handler rejects a non-absolute path with 400, and "/tmp/x" is
    // NOT absolute on Windows.
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"defaults-agent"});
    defer gpa.free(agent_path);

    const create_body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"fresh-agent\",\"path\":\"{s}\"}}",
        .{agent_path},
    );
    defer gpa.free(create_body);

    const create_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(create_path);

    var cr = try h.http(io, .POST, create_path, .{ .json_body = create_body, .expect = &.{201} });
    defer cr.deinit();
    var cdoc = try cr.json();
    defer cdoc.deinit();
    const item_id = try createdItemId(&cdoc);
    defer gpa.free(item_id);

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{item_id});
    defer gpa.free(tools_path);

    var r = try h.http(io, .GET, tools_path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try expectToolList(&doc, &EXPECTED_DEFAULTS, "fresh agent");
}

// A freshly-created kanban seeds the agent defaults PLUS the kanban pair,
// and its `agent_kanban` bundle is configured (200, not 404).
test "kanban_create_seeds_agent_kanban_and_tools" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "defaults-ws");
    defer gpa.free(ws_id);

    const create_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(create_path);

    var cr = try h.http(io, .POST, create_path, .{
        .json_body = "{\"name\":\"fresh-board\"}",
        .expect = &.{201},
    });
    defer cr.deinit();
    var cdoc = try cr.json();
    defer cdoc.deinit();
    const kanban_id = try createdItemId(&cdoc);
    defer gpa.free(kanban_id);

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/tools", .{kanban_id});
    defer gpa.free(tools_path);

    var r = try h.http(io, .GET, tools_path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try expectToolList(&doc, &EXPECTED_KANBAN_DEFAULTS, "fresh kanban");

    // The bundle must be CONFIGURED (200), not the 404 NotConfigured
    // a mis-wired mirror would produce, and it carries the same list.
    const bundle_path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/agent_kanban",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(bundle_path);

    var br = try h.http(io, .GET, bundle_path, .{ .expect = &.{200} });
    defer br.deinit();
    var bdoc = try br.json();
    defer bdoc.deinit();
    try expectToolList(&bdoc, &EXPECTED_KANBAN_DEFAULTS, "fresh kanban bundle");
}

// The seed runs ONCE at creation: deleting every default leaves `[]`
// and a later read does NOT backfill.
test "delete_all_tools_leaves_empty_no_backfill" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "defaults-ws");
    defer gpa.free(ws_id);

    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"defaults-strip"});
    defer gpa.free(agent_path);

    const create_body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"strip-agent\",\"path\":\"{s}\"}}",
        .{agent_path},
    );
    defer gpa.free(create_body);

    const create_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(create_path);

    var cr = try h.http(io, .POST, create_path, .{ .json_body = create_body, .expect = &.{201} });
    defer cr.deinit();
    var cdoc = try cr.json();
    defer cdoc.deinit();
    const agent_id = try createdItemId(&cdoc);
    defer gpa.free(agent_id);

    for (EXPECTED_DEFAULTS) |name| {
        const del_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/{s}", .{ agent_id, name });
        defer gpa.free(del_path);
        var dr = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        dr.deinit();
    }

    const tools_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(tools_path);

    var r = try h.http(io, .GET, tools_path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try expectToolList(&doc, &.{}, "after deleting all defaults");
}
