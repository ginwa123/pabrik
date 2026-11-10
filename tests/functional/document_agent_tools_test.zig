// Functional coverage for the `document_markdown` agent tool — one tool with
// four actions (`create` / `edit` / `search` / `delete`).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const DOCUMENT_MARKDOWN = "document_markdown";

// ============================================================================
// Expected tool list — mirrors tests/functional/default_tools.py
// ============================================================================

/// Mirrors `DEFAULT_AGENT_TOOLS` — 34 names, sorted ASC, matching the wire
/// order of `GET /api/agents/:agent_id/tools`.
const DEFAULT_AGENT_TOOLS = [_][]const u8{
    "add_skill",
    "command",
    "delegate_agent",
    "document_markdown",
    "edit_skill",
    "get_plan",
    "glob",
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
    "search_skills",
    "search_tool",
    "set_skill_metadata",
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

/// The four per-action names `document_markdown` replaced. None of them may
/// survive in the registry or the seeded set.
const RETIRED_DOCUMENT_TOOLS = [_][]const u8{
    "add_document",
    "edit_document",
    "search_documents",
    "delete_document",
};

/// `DEFAULT_AGENT_TOOLS` minus `document_markdown` — the post-DELETE
/// expectation, so the assertion is about the SET and not a re-derivation.
const DEFAULT_AGENT_TOOLS_WITHOUT_DOCUMENTS = [_][]const u8{
    "add_skill",
    "command",
    "delegate_agent",
    "edit_skill",
    "get_plan",
    "glob",
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
    "search_skills",
    "search_tool",
    "set_skill_metadata",
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
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/agent {"name", "path"}` → the agent
/// item's id. Owned. `path` is derived from `h.temp_dir` — see the
/// module header for why.
fn createAgent(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"doc-tools-agent"});
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

    const item = doc.object("item") orelse {
        std.debug.print("agent create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("agent create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("agent create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/documents` → the document's id. Owned.
fn addDocument(h: *Harness, workspace_id: []const u8, title: []const u8, content: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .title = title,
        .content = content,
        .format = "markdown",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const document = doc.object("document") orelse {
        std.debug.print("document create returned no `document`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (document.get("id") orelse {
        std.debug.print("document create has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("document create id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// A GET whose body the caller parses itself. Returns OWNED bytes —
/// a `harness.Json` would alias the `Response` body this frame frees.
fn getOwned(h: *Harness, path: []const u8, expect: []const u16) ![]u8 {
    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `GET /api/agents/<id>/tools` → the seeded tool names, owned.
fn agentToolNames(h: *Harness, agent_id: []const u8) ![][]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(path);

    const raw = try getOwned(h, path, &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    return ownedStrings(doc.array("tools") orelse {
        std.debug.print("agent tools response has no `tools` array: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    });
}

fn freeNames(names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn ownedStrings(arr: std.json.Array) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (arr.items) |row| {
        const s = switch (row) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, s));
    }
    return out.toOwnedSlice(gpa);
}

fn namesContain(names: []const []u8, needle: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, needle)) return true;
    }
    return false;
}

/// `assert sorted(after) == sorted(want)` — sorts the wire list so the
/// assertion is about the SET, exactly as the Python did.
fn expectSortedSet(names: []const []u8, want: []const []const u8) !void {
    const sorted = try gpa.dupe([]const u8, names);
    defer gpa.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (!nameSlicesEqual(sorted, want)) {
        const got = try std.mem.join(gpa, ", ", sorted);
        defer gpa.free(got);
        const expected = try std.mem.join(gpa, ", ", want);
        defer gpa.free(expected);
        std.debug.print("tool set drifted:\n  got:      {s}\n  expected: {s}\n", .{ got, expected });
        return error.TestUnexpectedResult;
    }
}

/// `assert tools == DEFAULT_AGENT_TOOLS` — order-sensitive, on purpose:
/// the wire order IS the contract the Python compared.
fn expectExactSet(names: []const []u8, want: []const []const u8) !void {
    if (!nameSlicesEqual(names, want)) {
        const got = try std.mem.join(gpa, ", ", names);
        defer gpa.free(got);
        const expected = try std.mem.join(gpa, ", ", want);
        defer gpa.free(expected);
        std.debug.print("seeded tool set drifted:\n  got:      {s}\n  expected: {s}\n", .{ got, expected });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// REGISTRY — the tool exists, is dispatchable, and describes itself.
test "registry_lists_document_markdown" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const raw = try getOwned(&h, "/api/agent-tools/registry", &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    const tools = doc.array("tools") orelse {
        std.debug.print("registry has no `tools` array: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };

    var desc: ?[]const u8 = null;
    for (tools.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |v| v,
            else => continue,
        };
        const d = switch (obj.get("description") orelse continue) {
            .string => |v| v,
            else => continue,
        };
        if (std.mem.eql(u8, name, DOCUMENT_MARKDOWN)) desc = d;
    }
    if (desc == null) {
        std.debug.print("{s} missing from registry\n", .{DOCUMENT_MARKDOWN});
        return error.TestUnexpectedResult;
    }

    // A non-empty description is the floor: the registry feeds the
    // `search_tool` catalog too, and an entry with no description is a
    // row the model cannot choose on.
    if (std.mem.trim(u8, desc.?, " \t\r\n").len == 0) {
        std.debug.print("{s} has an empty description — nothing for the model to read\n", .{DOCUMENT_MARKDOWN});
        return error.TestUnexpectedResult;
    }

    // One tool covers four operations, so the description has to name all
    // four — otherwise the model never discovers `search` or `delete`.
    for ([_][]const u8{ "create", "edit", "search", "delete" }) |action| {
        if (std.mem.indexOf(u8, desc.?, action) == null) {
            std.debug.print("{s} must name the `{s}` action; got \"{s}\"\n", .{ DOCUMENT_MARKDOWN, action, desc.? });
            return error.TestUnexpectedResult;
        }
    }

    // `delete` is irreversible, and the description is the only place the
    // model can learn that before it calls.
    if (std.mem.indexOf(u8, desc.?, "IRREVERSIBLE") == null) {
        std.debug.print("{s} must lead with the irreversibility of `delete`; got \"{s}\"\n", .{ DOCUMENT_MARKDOWN, desc.? });
        return error.TestUnexpectedResult;
    }
}

// SEEDED — one tool, seeded into every new agent.
test "fresh_agent_is_seeded_with_document_markdown" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "doc-tools-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "doc-tools-agent");
    defer gpa.free(agent_id);

    const tools = try agentToolNames(&h, agent_id);
    defer freeNames(tools);

    if (!namesContain(tools, DOCUMENT_MARKDOWN)) {
        const rendered = try std.mem.join(gpa, ", ", tools);
        defer gpa.free(rendered);
        std.debug.print("{s} should be seeded; got {s}\n", .{ DOCUMENT_MARKDOWN, rendered });
        return error.TestUnexpectedResult;
    }
    for (RETIRED_DOCUMENT_TOOLS) |retired| {
        if (namesContain(tools, retired)) {
            const rendered = try std.mem.join(gpa, ", ", tools);
            defer gpa.free(rendered);
            std.debug.print("{s} was folded into {s} and must not be seeded; got {s}\n", .{ retired, DOCUMENT_MARKDOWN, rendered });
            return error.TestUnexpectedResult;
        }
    }
    // The whole seeded set still matches the shared transcription, so this
    // test doubles as the "you forgot default_tools.py" alarm.
    try expectExactSet(tools, &DEFAULT_AGENT_TOOLS);
}

// Registered is not the same as enabled — the user can still tick it off.
// `POST /api/agents/:id/tools` validates `tool_name` against
// `UNIFIED_TOOL_REGISTRY` and 400s on anything unknown.
test "document_markdown_can_be_disabled_and_reenabled" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "doc-tools-optin-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "optin-agent");
    defer gpa.free(agent_id);

    {
        const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/{s}", .{ agent_id, DOCUMENT_MARKDOWN });
        defer gpa.free(path);

        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        r.deinit();
    }

    {
        const after = try agentToolNames(&h, agent_id);
        defer freeNames(after);
        if (namesContain(after, DOCUMENT_MARKDOWN)) {
            std.debug.print("disabling {s} did not persist\n", .{DOCUMENT_MARKDOWN});
            return error.TestUnexpectedResult;
        }
        try expectSortedSet(after, &DEFAULT_AGENT_TOOLS_WITHOUT_DOCUMENTS);
    }

    // 201, not 400 — a 400 would mean the name is not in the registry.
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = DOCUMENT_MARKDOWN }, .{});
        defer gpa.free(body);

        const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
        defer gpa.free(path);

        var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
        r.deinit();
    }

    const final = try agentToolNames(&h, agent_id);
    defer freeNames(final);
    try expectExactSet(final, &DEFAULT_AGENT_TOOLS);
}

// The registry validation is real, not a rubber stamp. Without this, "POST
// returned 201" in the test above would prove nothing — an endpoint that
// accepts any string would pass it too.
test "an_unknown_tool_name_is_still_rejected" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "doc-tools-unknown-ws");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "unknown-agent");
    defer gpa.free(agent_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .tool_name = "definitely_not_a_tool_1790",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{400} });
    r.deinit();
}

// `document_markdown`'s `search` action reads the `documents` table; prove it is populated.
test "documents_crud_round_trip_the_search_tool_reads" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "doc-tools-crud-ws");
    defer gpa.free(ws_id);

    const doc_id = try addDocument(&h, ws_id, "Release plan v2", "# Release plan\n\n- ship 095\n");
    defer gpa.free(doc_id);
    if (!std.mem.startsWith(u8, doc_id, "doc_")) {
        std.debug.print("unexpected document id shape: \"{s}\"\n", .{doc_id});
        return error.TestUnexpectedResult;
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{ws_id});
        defer gpa.free(path);
        const raw = try getOwned(&h, path, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();

        const documents = doc.array("documents") orelse {
            std.debug.print("list has no `documents` array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        if (documents.items.len != 1) {
            std.debug.print("expected exactly one document, got {d}: {s}\n", .{ documents.items.len, raw });
            return error.TestUnexpectedResult;
        }
        const first = switch (documents.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("document row is not an object: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectFieldStr(first, "id", doc_id, raw);
        try expectFieldStr(first, "title", "Release plan v2", raw);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/{s}", .{ ws_id, doc_id });
        defer gpa.free(path);
        const raw = try getOwned(&h, path, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();

        const document = doc.object("document") orelse {
            std.debug.print("document GET has no `document`: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        try expectFieldStr(document, "content", "# Release plan\n\n- ship 095\n", raw);
    }

    // A second document with the same title in a DIFFERENT workspace must
    // not appear in the first workspace's list — the same `workspace_id`
    // guard the `search` action relies on, exercised over the wire.
    {
        const other_ws = try createWorkspace(&h, "doc-tools-crud-other");
        defer gpa.free(other_ws);
        const other_doc = try addDocument(&h, other_ws, "Release plan v2", "not yours");
        defer gpa.free(other_doc);

        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{ws_id});
        defer gpa.free(path);
        const raw = try getOwned(&h, path, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();

        const documents = doc.array("documents") orelse {
            std.debug.print("list has no `documents` array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        if (documents.items.len != 1) {
            std.debug.print("another workspace's document leaked into the list: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        const first = switch (documents.items[0]) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        try expectFieldStr(first, "id", doc_id, raw);
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/{s}", .{ ws_id, doc_id });
        defer gpa.free(path);

        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        r.deinit();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{ws_id});
        defer gpa.free(path);
        const raw = try getOwned(&h, path, &.{200});
        defer gpa.free(raw);

        var doc = try parseJson(raw);
        defer doc.deinit();

        const documents = doc.array("documents") orelse {
            std.debug.print("list has no `documents` array: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        if (documents.items.len != 0) {
            std.debug.print("delete left the row behind: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
    }

    // A deleted document is gone for the tools too — 404, not a 200 with
    // an empty body, so the `delete` action's "already gone" case and this
    // one agree.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/{s}", .{ ws_id, doc_id });
        defer gpa.free(path);

        var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
        r.deinit();
    }
}

// The `search` action has to match an empty body without erroring.
// `SqliteBackend.exec` binds a zero-length slice as SQL NULL, so an empty
// body is the one input that has historically broken writes.
test "documents_body_empty_round_trips_as_empty_string" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "doc-tools-empty-ws");
    defer gpa.free(ws_id);
    const doc_id = try addDocument(&h, ws_id, "Heading only", "");
    defer gpa.free(doc_id);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/{s}", .{ ws_id, doc_id });
    defer gpa.free(path);
    const raw = try getOwned(&h, path, &.{200});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();

    const document = doc.object("document") orelse {
        std.debug.print("document GET has no `document`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    try expectFieldStr(document, "content", "", raw);
}

// ============================================================================
// Assertion helpers
// ============================================================================

fn expectFieldStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, body: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("object has no `{s}`: {s}\n", .{ key, body });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string: {s}\n", .{ key, body });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        const shown = try harness.debugString(gpa, got);
        defer gpa.free(shown);
        const expected = try harness.debugString(gpa, want);
        defer gpa.free(expected);
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, shown, expected });
        return error.TestUnexpectedResult;
    }
}

/// Element-wise equality over a list of tool names. `std.mem.eql([]const u8,
/// a, b)` does not compile: its `a_elem != b_elem` test rejects a slice
/// element. Comparing length then each name is the spelling that does.
fn nameSlicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

comptime {
    // Body-analysis barrier — an unreferenced helper is never
    // type-checked, so a stdlib rename inside one stays invisible.
    _ = createWorkspace;
    _ = createAgent;
    _ = addDocument;
    _ = getOwned;
    _ = parseJson;
    _ = agentToolNames;
    _ = freeNames;
    _ = ownedStrings;
    _ = namesContain;
    _ = expectSortedSet;
    _ = expectExactSet;
    _ = expectFieldStr;
    _ = nameSlicesEqual;
    _ = DEFAULT_AGENT_TOOLS;
    _ = DEFAULT_AGENT_TOOLS_WITHOUT_DOCUMENTS;
    _ = DOCUMENT_MARKDOWN;
    _ = RETIRED_DOCUMENT_TOOLS;
}
