// Functional tests for the Agent-Kanbans mirror (Migration 081). Zig port of
// `tests/functional/agent_kanbans_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Expected tool list — mirrors tests/functional/default_tools.py
// ============================================================================

/// Mirrors `DEFAULT_KANBAN_SEEDED_TOOLS` — what a fresh kanban item is born
/// with: `DEFAULT_AGENT_TOOLS` PLUS the kanban pair, sorted ASC.
const EXPECTED_KANBAN_SEEDED_TOOLS = [_][]const u8{
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
    "list_agents",
    "list_directory",
    "list_secrets",
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
    "use_skill",
    "use_tool",
    "used_tools",
    "view_session",
    "view_tool",
    "web_search",
    "write_file",
};

// ============================================================================
// Helpers
// ============================================================================

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `r.json()["id"]`.
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban {"name": ...}` → the kanban
/// item's id. Owned.
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `r.json()["item"]["id"]`.
    return itemId(&doc, r.body);
}

/// `POST /api/workspaces/<ws>/items/agent {"name", "path"}` → the agent
/// item's id. Owned.
fn createAgent(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-kanbans-test"});
    defer gpa.free(agent_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = agent_path,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `r.json()["item"]["id"]`.
    return itemId(&doc, r.body);
}

fn itemId(doc: *const harness.Json, body: []const u8) ![]u8 {
    const item = doc.object("item") orelse {
        std.debug.print("item create returned no `item`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("item create has no id: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("item create id is not a string: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/workspaces/<ws>/items/<item>/agent_kanban` — the response
/// body as OWNED bytes. A `harness.Json` aliases the `Response` body,
/// so the helper cannot return one; the caller parses.
fn getBundle(h: *Harness, workspace_id: []const u8, item_id: []const u8, expect: []const u16) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/agent_kanban", .{ workspace_id, item_id });
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Parse owned bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `POST /api/agent-kanbans/<kanban>/knowledge` with an explicit body,
/// returning the response body as OWNED bytes.
fn postKnowledge(h: *Harness, kanban_id: []const u8, json_body: []const u8, expect: []const u16) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/knowledge", .{kanban_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Assert `doc[key]` is a JSON array of strings exactly equal to `want`.
fn expectStringArray(doc: *const harness.Json, key: []const u8, want: []const []const u8) !void {
    const arr = doc.array(key) orelse {
        std.debug.print("response has no `{s}` array\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (arr.items.len != want.len) {
        const got = try renderStrings(arr.items);
        defer gpa.free(got);
        std.debug.print("`{s}` has {d} entries, expected {d}: {s}\n", .{ key, arr.items.len, want.len, got });
        return error.TestUnexpectedResult;
    }
    for (arr.items, want, 0..) |row, w, i| {
        const got = switch (row) {
            .string => |s| s,
            else => {
                std.debug.print("`{s}[{d}]` holds a non-string entry\n", .{ key, i });
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, got, w)) {
            std.debug.print("`{s}[{d}]` = \"{s}\", expected \"{s}\"\n", .{ key, i, got, w });
            return error.TestUnexpectedResult;
        }
    }
}

fn renderStrings(items: []const std.json.Value) ![]u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    for (items) |row| {
        switch (row) {
            .string => |s| try out.append(gpa, s),
            else => try out.append(gpa, "<non-string>"),
        }
    }
    return std.mem.join(gpa, ", ", out.items);
}

// ============================================================================
// Tests
// ============================================================================

// BUNDLE GET — fresh kanban is born configured with default tools.
test "bundle_get_fresh_returns_defaults" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "bare");
    defer gpa.free(kanban_id);

    const raw = try getBundle(&h, ws_id, kanban_id, &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    // `body.get("tools") == DEFAULT_KANBAN_SEEDED_TOOLS`
    try expectStringArray(&doc, "tools", &EXPECTED_KANBAN_SEEDED_TOOLS);
}

// GET wrong type — agent-type item → 400 ItemNotKanban (route scoping).
test "bundle_get_agent_type_returns_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "agent");
    defer gpa.free(agent_id);

    const raw = try getBundle(&h, ws_id, agent_id, &.{400});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    // `assert "not a kanban" in body.get("error", "").lower()`
    const message = doc.str("error") orelse "";
    if (!containsIgnoreCase(message, "not a kanban")) {
        std.debug.print("expected ItemNotKanban message, got: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

// PATCH /agent_kanban with empty description persists as ''
// (empty-slice-as-NULL regression). PORTED VERBATIM, INCLUDING THE MISSING
// ASSERTION.
test "bundle_update_description_round_trips_empty" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    // The Python body makes no request beyond these two creates. Its
    // follow-up ("PATCH against an unconfigured kanban should return
    // 404") was never written, so there is nothing to replay here.
}

// KNOWLEDGE POST — file_path='' + content set → row persists with empty file_path.
test "knowledge_create_with_inline_content" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    // Seed an extra tool (fresh kanbans seed the defaults, so use
    // preview_design_page — in UNIFIED_TOOL_REGISTRY but never a default
    // — for a clean 201).
    try postTool(&h, kanban_id, "preview_design_page", &.{201});

    // Now create an inline-content knowledge row.
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "Notes",
        .content = "inline body",
    }, .{});
    defer gpa.free(body);

    const raw = try postKnowledge(&h, kanban_id, body, &.{201});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    try expectEqualStr(&doc, "kanban_id", kanban_id);
    try expectEqualStr(&doc, "file_path", "");
    try expectEqualStr(&doc, "label", "Notes");
    try expectEqualStr(&doc, "content", "inline body");
    // COALESCE handles empty kanban → first row at position 0.
    try expectEqualInt(&doc, "position", 0);
}

// KNOWLEDGE REORDER — PATCH /knowledge/reorder reaches the REORDER handler (not shadowed by :knowledge_id).
test "knowledge_reorder_reaches_reorder_handler" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    try postTool(&h, kanban_id, "preview_design_page", &.{201});

    // Seed 2 knowledge rows.
    const a_path = try harness.harnessPath(gpa, h.temp_dir, &.{"a.md"});
    defer gpa.free(a_path);
    const b_path = try harness.harnessPath(gpa, h.temp_dir, &.{"b.md"});
    defer gpa.free(b_path);

    const id_a = try createKnowledgeRow(&h, kanban_id, a_path, "A");
    defer gpa.free(id_a);
    const id_b = try createKnowledgeRow(&h, kanban_id, b_path, "B");
    defer gpa.free(id_b);

    // Reorder — if route shadowing bites, this returns 404 "knowledge row
    // not found" (captured by :knowledge_id="reorder") instead of {ok:true}.
    {
        const reorder_body = try std.json.Stringify.valueAlloc(gpa, .{
            .ordered_ids = &[_][]const u8{ id_b, id_a },
        }, .{});
        defer gpa.free(reorder_body);

        const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/knowledge/reorder", .{kanban_id});
        defer gpa.free(path);

        var r = try h.http(io, .PATCH, path, .{ .json_body = reorder_body, .expect = &.{200} });
        r.deinit();
    }

    // GET bundle and assert B comes first (position DESC).
    const raw = try getBundle(&h, ws_id, kanban_id, &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    const knowledges = doc.array("knowledges") orelse {
        std.debug.print("bundle has no `knowledges` array: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    const got = try knowledgeIds(knowledges);
    defer gpa.free(got);
    const want_order = try std.mem.join(gpa, ",", &[_][]const u8{ id_b, id_a });
    defer gpa.free(want_order);

    if (!std.mem.eql(u8, got, want_order)) {
        std.debug.print("reorder didn't change ordering; got {s}: {s}\n", .{ got, raw });
        return error.TestUnexpectedResult;
    }
}

// TOOLS — Re-POSTing the same (kanban_id, tool_name) returns 409 DuplicateTool.
test "tools_duplicate_returns_409" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    // Fresh kanbans seed the defaults — use preview_design_page (never a
    // default) for a clean first 201.
    try postTool(&h, kanban_id, "preview_design_page", &.{201});

    // Second POST with the same tool → 409.
    try postTool(&h, kanban_id, "preview_design_page", &.{409});
}

// TOOLS — POST with an unknown tool_name returns 400 UnknownTool (no auto-create).
test "tools_unknown_returns_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    // Fresh kanbans are born configured — no seed POST needed.
    // Try an unknown tool → 400.
    try postTool(&h, kanban_id, "totally_made_up_tool_xyz", &.{400});
}

// SYSTEM_PROMPT — first row gets position 0 (COALESCE handles empty table).
test "system_prompt_first_row_position_zero" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    // Fresh kanbans are born configured — no seed POST needed.
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .title = "Persona",
        .content = "You are X",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/system_prompt", .{kanban_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    try expectEqualInt(&doc, "position", 0);
}

// SYSTEM_PROMPT — POST with whitespace-only content returns 400 ContentRequired.
test "system_prompt_empty_content_returns_400" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-kanbans-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .title = "T",
        .content = "   \n\t  ",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/system_prompt", .{kanban_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{400} });
    r.deinit();
}

// ============================================================================
// Assertion + fixture helpers used above
// ============================================================================

fn postTool(h: *Harness, kanban_id: []const u8, tool_name: []const u8, expect: []const u16) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = tool_name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/agent-kanbans/{s}/tools", .{kanban_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
    r.deinit();
}

/// One file-backed knowledge row. Returns its id, owned.
fn createKnowledgeRow(h: *Harness, kanban_id: []const u8, file_path: []const u8, label: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = file_path,
        .label = label,
        .content = "",
    }, .{});
    defer gpa.free(body);

    const raw = try postKnowledge(h, kanban_id, body, &.{201});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    const id = doc.str("id") orelse {
        std.debug.print("knowledge create returned no id: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// The knowledge rows' ids, comma-joined. Borrowed from the live
/// document; freed by the caller.
fn knowledgeIds(knowledges: std.json.Array) ![]u8 {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(gpa);
    for (knowledges.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, id);
    }
    return std.mem.join(gpa, ",", out.items);
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle_lower.len], needle_lower)) return true;
    }
    return false;
}

fn expectEqualStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectEqualInt(doc: *const harness.Json, key: []const u8, want: i64) !void {
    const got = doc.int(key) orelse {
        std.debug.print("response has no integer `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {d}, expected {d}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — an unreferenced helper is never
    // type-checked, so a stdlib rename inside one stays invisible.
    _ = createWorkspace;
    _ = createKanban;
    _ = createAgent;
    _ = itemId;
    _ = getBundle;
    _ = parseJson;
    _ = postKnowledge;
    _ = postTool;
    _ = createKnowledgeRow;
    _ = knowledgeIds;
    _ = expectStringArray;
    _ = renderStrings;
    _ = containsIgnoreCase;
    _ = expectEqualStr;
    _ = expectEqualInt;
    _ = EXPECTED_KANBAN_SEEDED_TOOLS;
}
