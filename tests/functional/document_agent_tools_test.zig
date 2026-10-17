// Functional coverage for the `delete_document` / `search_documents` agent
// tools.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const DELETE_DOCUMENT = "delete_document";
const SEARCH_DOCUMENTS = "search_documents";

// ============================================================================
// Expected tool list — mirrors tests/functional/default_tools.py
// ============================================================================

/// Mirrors `DEFAULT_AGENT_TOOLS` — 35 names, sorted ASC, matching the wire
/// order of `GET /api/agents/:agent_id/tools`.
const DEFAULT_AGENT_TOOLS = [_][]const u8{
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
    "use_skill",
    "use_tool",
    "used_tools",
    "view_session",
    "view_tool",
    "web_search",
    "write_file",
};

/// `sorted(DEFAULT_AGENT_TOOLS + ["delete_document"])` — what the wire
/// must carry once the user opts in. `delete_document` sorts between
/// `command` and `edit_document`.
const AGENT_TOOLS_WITH_DELETE = [_][]const u8{
    "add_document",
    "add_skill",
    "ask_user",
    "command",
    "delete_document",
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

// REGISTRY — the tools exist, are dispatchable, and describe themselves.
test "registry_lists_both_new_document_tools" {
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

    // Both must be registered. A registry entry is what makes a tool
    // dispatchable AND what puts a checkbox in Settings → Tools — if
    // either is missing the user has no way to reach the tool at all.
    var search_desc: ?[]const u8 = null;
    var delete_desc: ?[]const u8 = null;
    for (tools.items) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const desc = switch (obj.get("description") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, SEARCH_DOCUMENTS)) search_desc = desc;
        if (std.mem.eql(u8, name, DELETE_DOCUMENT)) delete_desc = desc;
    }
    if (search_desc == null) {
        std.debug.print("{s} missing from registry\n", .{SEARCH_DOCUMENTS});
        return error.TestUnexpectedResult;
    }
    if (delete_desc == null) {
        std.debug.print("{s} missing from registry\n", .{DELETE_DOCUMENT});
        return error.TestUnexpectedResult;
    }

    // A non-empty description is the floor: the registry feeds the
    // `search_tool` catalog too, and an entry with no description is a
    // row the model cannot choose on.
    if (std.mem.trim(u8, search_desc.?, " \t\r\n").len == 0) {
        std.debug.print("{s} has an empty description — nothing for the model to read\n", .{SEARCH_DOCUMENTS});
        return error.TestUnexpectedResult;
    }
    if (std.mem.trim(u8, delete_desc.?, " \t\r\n").len == 0) {
        std.debug.print("{s} has an empty description — nothing for the model to read\n", .{DELETE_DOCUMENT});
        return error.TestUnexpectedResult;
    }

    // `search_documents` is only useful if the model knows what to DO with a
    // row: the description has to name the tools that consume the id.
    if (std.mem.indexOf(u8, search_desc.?, "document_id") == null) {
        std.debug.print("{s} must tell the model what a row carries; got \"{s}\"\n", .{ SEARCH_DOCUMENTS, search_desc.? });
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, search_desc.?, "edit_document") == null) {
        std.debug.print("{s} must point at the tool that consumes its id; got \"{s}\"\n", .{ SEARCH_DOCUMENTS, search_desc.? });
        return error.TestUnexpectedResult;
    }

    // `delete_document` must state that it is irreversible AND point at
    // `edit_document` as the reversible alternative — otherwise the model
    // reaches for delete whenever the user says "fix this note".
    if (std.mem.indexOf(u8, delete_desc.?, "IRREVERSIBLE") == null) {
        std.debug.print("{s} must lead with the irreversibility; got \"{s}\"\n", .{ DELETE_DOCUMENT, delete_desc.? });
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, delete_desc.?, "edit_document") == null) {
        std.debug.print("{s} must name the reversible alternative; got \"{s}\"\n", .{ DELETE_DOCUMENT, delete_desc.? });
        return error.TestUnexpectedResult;
    }

    // `delete_document` takes exactly one argument.
    if (containsIgnoreCase(delete_desc.?, "force")) {
        std.debug.print("{s} grew a confirmation knob; got \"{s}\"\n", .{ DELETE_DOCUMENT, delete_desc.? });
        return error.TestUnexpectedResult;
    }
}

// SEEDED — read-only default-on, irreversible default-off.
test "fresh_agent_is_seeded_with_search_documents_but_not_delete" {
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

    if (!namesContain(tools, SEARCH_DOCUMENTS)) {
        const rendered = try std.mem.join(gpa, ", ", tools);
        defer gpa.free(rendered);
        std.debug.print("{s} should be seeded like add/edit_document; got {s}\n", .{ SEARCH_DOCUMENTS, rendered });
        return error.TestUnexpectedResult;
    }
    if (namesContain(tools, DELETE_DOCUMENT)) {
        const rendered = try std.mem.join(gpa, ", ", tools);
        defer gpa.free(rendered);
        std.debug.print(
            "{s} irreversibly deletes the user's documents and must NOT be seeded into every new agent; got {s}\n",
            .{ DELETE_DOCUMENT, rendered },
        );
        return error.TestUnexpectedResult;
    }
    // The whole seeded set still matches the shared transcription, so this
    // test doubles as the "you forgot default_tools.py" alarm.
    try expectExactSet(tools, &DEFAULT_AGENT_TOOLS);
}

// Registered is not the same as seeded — the user can still tick it. `POST
// /api/agents/:id/tools` validates `tool_name` against
// `UNIFIED_TOOL_REGISTRY` and 400s on anything unknown.
test "delete_document_can_be_enabled_explicitly" {
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
        const before = try agentToolNames(&h, agent_id);
        defer freeNames(before);
        if (namesContain(before, DELETE_DOCUMENT)) {
            std.debug.print("the fresh agent should not start with {s}\n", .{DELETE_DOCUMENT});
            return error.TestUnexpectedResult;
        }
    }

    // 201, not 400 — a 400 would mean the name is not in the registry.
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = DELETE_DOCUMENT }, .{});
        defer gpa.free(body);

        const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
        defer gpa.free(path);

        var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
        r.deinit();
    }

    {
        const after = try agentToolNames(&h, agent_id);
        defer freeNames(after);
        if (!namesContain(after, DELETE_DOCUMENT)) {
            const rendered = try std.mem.join(gpa, ", ", after);
            defer gpa.free(rendered);
            std.debug.print("opt-in did not persist; got {s}\n", .{rendered});
            return error.TestUnexpectedResult;
        }
        // And nothing else moved.
        try expectSortedSet(after, &AGENT_TOOLS_WITH_DELETE);
    }

    // Ticking it off again is a clean DELETE, not a 500.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools/{s}", .{ agent_id, DELETE_DOCUMENT });
        defer gpa.free(path);

        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
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

// `search_documents` reads the `documents` table; prove it is populated.
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
    // guard `search_documents` relies on, exercised over the wire.
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
    // an empty body, so `delete_document`'s "already gone" case and this
    // one agree.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents/{s}", .{ ws_id, doc_id });
        defer gpa.free(path);

        var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
        r.deinit();
    }
}

// `search_documents` has to match an empty body without erroring.
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

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle_lower.len], needle_lower)) return true;
    }
    return false;
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
    _ = containsIgnoreCase;
    _ = nameSlicesEqual;
    _ = DEFAULT_AGENT_TOOLS;
    _ = AGENT_TOOLS_WITH_DELETE;
    _ = DELETE_DOCUMENT;
    _ = SEARCH_DOCUMENTS;
}
