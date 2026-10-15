// Functional tests for the Agent-Routines mirror (Migration 087). Zig port of
// `tests/functional/agent_routines_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

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

/// `POST /api/workspaces/<ws>/items/routine {"name", "path"}` → item id.
/// Owned.
fn createRoutine(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const routine_path = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-routines-test"});
    defer gpa.free(routine_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = routine_path,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/routine", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("routine create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("routine create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("routine create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban {"name": ...}` → item id. Owned.
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("kanban create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/workspaces/<ws>/items/<item>/agent_routine` → the WHOLE
/// body as OWNED bytes.
fn bundleBody(h: *Harness, workspace_id: []const u8, item_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/agent_routine",
        .{ workspace_id, item_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Issue a request under `/api/agent-routines/<routine>/<suffix>` and
/// return the body as OWNED bytes. `expect` names the accepted statuses
/// because the suite asserts on 201 / 200 / 400 / 409 in the same shape.
fn routineCall(
    h: *Harness,
    method: harness.HttpMethod,
    routine_id: []const u8,
    suffix: []const u8,
    json_body: ?[]const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/agent-routines/{s}/{s}", .{ routine_id, suffix });
    defer gpa.free(path);

    var r = try h.http(io, method, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `obj["id"]` from an owned row body. Owned.
fn rowId(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("row has no `id`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// Python `obj[key] == want` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `obj[key] == want` for an integer field.
fn expectInt(obj: std.json.ObjectMap, key: []const u8, want: i64, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .integer => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not an integer\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {d}, expected {d}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `obj.get(key) == []` — the key must be PRESENT and empty. An
/// absent key is Python's `None`, which is not `[]`, so `orelse` (not a
/// defaulted empty array) is what makes "the field vanished" fail here.
fn expectEmptyArray(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}` (must be an empty array)\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const arr = switch (v) {
        .array => |a| a,
        else => {
            std.debug.print("{s}: `{s}` is not an array\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (arr.items.len != 0) {
        std.debug.print("{s}: `{s}` has {d} entries, expected 0\n", .{ ctx, key, arr.items.len });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert "needle" in obj["error"].lower()`.
fn expectErrorContains(obj: std.json.ObjectMap, needle: []const u8) !void {
    const v = obj.get("error") orelse {
        std.debug.print("error response has no `error` key\n", .{});
        return error.TestUnexpectedResult;
    };
    const msg = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("`error` is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (std.ascii.indexOfIgnoreCase(msg, needle) == null) {
        std.debug.print("error \"{s}\" does not contain \"{s}\" (case-insensitive)\n", .{ msg, needle });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// Fresh routine is born configured (seeded row) with zero tools.
test "bundle_get_fresh_routine_is_seeded" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "bare");
    defer gpa.free(routine_id);

    const bundle_raw = try bundleBody(&h, ws_id, routine_id);
    defer gpa.free(bundle_raw);
    var doc = try parseJson(bundle_raw);
    defer doc.deinit();

    const bundle = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("bundle is not a JSON object: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    const routine = bundle.get("agent_routine") orelse {
        std.debug.print("bundle has no `agent_routine`: {s}\n", .{bundle_raw});
        return error.TestUnexpectedResult;
    };
    const routine_obj = switch (routine) {
        .object => |o| o,
        else => {
            std.debug.print("`agent_routine` is not an object: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(routine_obj, "id", routine_id, "bundle agent_routine");

    // An EMPTY allowlist means "all tools" (kanban D5 semantics), so a
    // fresh routine seeds none of its own.
    try expectEmptyArray(bundle, "tools", "bundle");
    try expectEmptyArray(bundle, "knowledges", "bundle");
    try expectEmptyArray(bundle, "system_prompts", "bundle");
}

// GET on kanban-type item -> 400 ItemNotRoutine (route scoping).
test "bundle_get_kanban_type_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "kanban");
    defer gpa.free(kanban_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/agent_routine",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{400} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const obj = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("400 body is not a JSON object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    try expectErrorContains(obj, "not a routine");
}

// PATCH description '' persists as '' (empty-slice-as-NULL regression).
test "bundle_update_description_round_trips_empty" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/agent_routine",
        .{ ws_id, routine_id },
    );
    defer gpa.free(path);

    const body =
        \\{"description":""}
    ;
    var r = try h.http(io, .PATCH, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const routine = doc.object("agent_routine") orelse {
        std.debug.print("PATCH response has no `agent_routine`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try expectStr(routine, "description", "", "PATCH agent_routine");
}

// POST knowledge with file_path='' + content -> row persists inline.
test "knowledge_create_inline_content" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "Notes",
        .content = "inline body",
    }, .{});
    defer gpa.free(body);

    const row_raw = try routineCall(&h, .POST, routine_id, "knowledge", body, &.{201});
    defer gpa.free(row_raw);

    var doc = try parseJson(row_raw);
    defer doc.deinit();
    const row = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("knowledge create did not return an object: {s}\n", .{row_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(row, "file_path", "", "created knowledge");
    try expectStr(row, "content", "inline body", "created knowledge");
    try expectInt(row, "position", 0, "created knowledge");
}

// PATCH knowledge file_path='' + content set (text-mode save).
test "knowledge_patch_mode_switch" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    // Seed a FILE-BACKED row first: the switch only means something when
    // the row changes from one source kind to the other.
    const seed_path = try harness.harnessPath(gpa, h.temp_dir, &.{ "agent-routines-test", "switch.md" });
    defer gpa.free(seed_path);

    const create_body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = seed_path,
        .label = "Switch",
    }, .{});
    defer gpa.free(create_body);

    const created_raw = try routineCall(&h, .POST, routine_id, "knowledge", create_body, &.{201});
    defer gpa.free(created_raw);
    const kid = try rowId(created_raw);
    defer gpa.free(kid);

    const patch_body = try std.json.Stringify.valueAlloc(gpa, .{
        .label = "Switched to text",
        .content = "inline body",
        .file_path = "",
    }, .{});
    defer gpa.free(patch_body);

    const knowledge_suffix = try std.fmt.allocPrint(gpa, "knowledge/{s}", .{kid});
    defer gpa.free(knowledge_suffix);

    const updated_raw = try routineCall(&h, .PATCH, routine_id, knowledge_suffix, patch_body, &.{200});
    defer gpa.free(updated_raw);

    var doc = try parseJson(updated_raw);
    defer doc.deinit();
    const updated = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("knowledge PATCH did not return an object: {s}\n", .{updated_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(updated, "file_path", "", "patched knowledge");
    try expectStr(updated, "content", "inline body", "patched knowledge");
}

// PATCH /knowledge/reorder reaches the reorder handler (route order).
test "knowledge_reorder_not_shadowed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body_a = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "A",
        .content = "a",
    }, .{});
    defer gpa.free(body_a);
    const body_b = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "B",
        .content = "b",
    }, .{});
    defer gpa.free(body_b);

    const first_raw = try routineCall(&h, .POST, routine_id, "knowledge", body_a, &.{201});
    defer gpa.free(first_raw);
    const first = try rowId(first_raw);
    defer gpa.free(first);

    const second_raw = try routineCall(&h, .POST, routine_id, "knowledge", body_b, &.{201});
    defer gpa.free(second_raw);
    const second = try rowId(second_raw);
    defer gpa.free(second);

    // ordered_ids[0] takes the HIGHEST position -> first in DESC order.
    // If route shadowing bit, this would 404 ("knowledge row not found",
    // captured by :knowledge_id="reorder") instead of {ok:true}.
    const reorder_body = try std.fmt.allocPrint(
        gpa,
        "{{\"ordered_ids\":[\"{s}\",\"{s}\"]}}",
        .{ second, first },
    );
    defer gpa.free(reorder_body);

    {
        const ok_raw = try routineCall(&h, .PATCH, routine_id, "knowledge/reorder", reorder_body, &.{200});
        defer gpa.free(ok_raw);
    }

    const bundle_raw = try bundleBody(&h, ws_id, routine_id);
    defer gpa.free(bundle_raw);
    var doc = try parseJson(bundle_raw);
    defer doc.deinit();

    const bundle = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("bundle is not a JSON object: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    const arr = bundle.get("knowledges") orelse {
        std.debug.print("bundle has no `knowledges`: {s}\n", .{bundle_raw});
        return error.TestUnexpectedResult;
    };
    const knowledges = switch (arr) {
        .array => |a| a,
        else => {
            std.debug.print("`knowledges` is not an array: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    if (knowledges.items.len != 2) {
        std.debug.print(
            "expected 2 knowledges after reorder, got {d}: {s}\n",
            .{ knowledges.items.len, bundle_raw },
        );
        return error.TestUnexpectedResult;
    }
    const want = [2][]const u8{ second, first };
    for (knowledges.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("knowledge row is not an object: {s}\n", .{bundle_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectStr(o, "id", want[i], "reordered knowledges");
    }
}

// DELETE knowledge removes the row; bundle no longer lists it.
test "knowledge_delete_scoped" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .file_path = "",
        .label = "Gone",
        .content = "x",
    }, .{});
    defer gpa.free(body);

    const created_raw = try routineCall(&h, .POST, routine_id, "knowledge", body, &.{201});
    defer gpa.free(created_raw);
    const kid = try rowId(created_raw);
    defer gpa.free(kid);

    {
        const suffix = try std.fmt.allocPrint(gpa, "knowledge/{s}", .{kid});
        defer gpa.free(suffix);
        const gone_raw = try routineCall(&h, .DELETE, routine_id, suffix, null, &.{200});
        defer gpa.free(gone_raw);
    }

    const bundle_raw = try bundleBody(&h, ws_id, routine_id);
    defer gpa.free(bundle_raw);
    var doc = try parseJson(bundle_raw);
    defer doc.deinit();

    const bundle = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("bundle is not a JSON object: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    const arr = bundle.get("knowledges") orelse {
        std.debug.print("bundle has no `knowledges`: {s}\n", .{bundle_raw});
        return error.TestUnexpectedResult;
    };
    const knowledges = switch (arr) {
        .array => |a| a,
        else => {
            std.debug.print("`knowledges` is not an array: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        },
    };
    for (knowledges.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const id = switch (o.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, kid)) {
            std.debug.print("deleted knowledge {s} is still in the bundle\n", .{kid});
            return error.TestUnexpectedResult;
        }
    }
}

// POST prompt gets position 0; title-only PATCH keeps content.
test "system_prompt_post_then_title_patch" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const create_body = try std.json.Stringify.valueAlloc(gpa, .{
        .title = "Persona",
        .content = "You are a helper.",
    }, .{});
    defer gpa.free(create_body);

    const created_raw = try routineCall(&h, .POST, routine_id, "system_prompt", create_body, &.{201});
    defer gpa.free(created_raw);
    {
        var doc = try parseJson(created_raw);
        defer doc.deinit();
        const created = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("system_prompt create did not return an object: {s}\n", .{created_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectInt(created, "position", 0, "created system prompt");
    }
    const pid = try rowId(created_raw);
    defer gpa.free(pid);

    const patch_body = try std.json.Stringify.valueAlloc(gpa, .{ .title = "Renamed" }, .{});
    defer gpa.free(patch_body);

    const prompt_suffix = try std.fmt.allocPrint(gpa, "system_prompt/{s}", .{pid});
    defer gpa.free(prompt_suffix);

    const updated_raw = try routineCall(&h, .PATCH, routine_id, prompt_suffix, patch_body, &.{200});
    defer gpa.free(updated_raw);

    var doc = try parseJson(updated_raw);
    defer doc.deinit();
    const updated = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("system_prompt PATCH did not return an object: {s}\n", .{updated_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(updated, "title", "Renamed", "patched system prompt");
    // The title-only PATCH must NOT wipe the body.
    try expectStr(updated, "content", "You are a helper.", "patched system prompt");
}

// POST unknown tool_name -> 400 (registry validation).
test "tools_enable_unknown_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = "no_such_tool_xyz" }, .{});
    defer gpa.free(body);

    const raw = try routineCall(&h, .POST, routine_id, "tools", body, &.{400});
    defer gpa.free(raw);

    var doc = try parseJson(raw);
    defer doc.deinit();
    const obj = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("400 body is not a JSON object: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    // Python: `assert r.json().get("error")` — truthy, i.e. a NON-EMPTY
    // string. An absent or empty `error` fails.
    const msg = switch (obj.get("error") orelse {
        std.debug.print("400 body has no `error` key: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }) {
        .string => |x| x,
        else => {
            std.debug.print("`error` is not a string: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    if (msg.len == 0) {
        std.debug.print("`error` is empty: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

// POST same tool twice -> 409 on the duplicate.
test "tools_enable_duplicate_returns_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = "read_file" }, .{});
    defer gpa.free(body);

    {
        const first = try routineCall(&h, .POST, routine_id, "tools", body, &.{201});
        defer gpa.free(first);
    }
    {
        const dup = try routineCall(&h, .POST, routine_id, "tools", body, &.{409});
        defer gpa.free(dup);
    }
}

// Enabled tools appear in LIST and the bundle; DELETE removes them.
test "tools_list_and_delete" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-routines-ws");
    defer gpa.free(ws_id);
    const routine_id = try createRoutine(&h, ws_id, "routine");
    defer gpa.free(routine_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .tool_name = "read_file" }, .{});
    defer gpa.free(body);

    {
        const created = try routineCall(&h, .POST, routine_id, "tools", body, &.{201});
        defer gpa.free(created);
    }

    {
        const listed_raw = try routineCall(&h, .GET, routine_id, "tools", null, &.{200});
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("tools LIST did not return an object: {s}\n", .{listed_raw});
                return error.TestUnexpectedResult;
            },
        };
        // `["read_file"]` — exactly one element, that element.
        const arr = listed.get("tools") orelse {
            std.debug.print("tools LIST has no `tools`: {s}\n", .{listed_raw});
            return error.TestUnexpectedResult;
        };
        const tools = switch (arr) {
            .array => |a| a,
            else => {
                std.debug.print("`tools` is not an array: {s}\n", .{listed_raw});
                return error.TestUnexpectedResult;
            },
        };
        if (tools.items.len != 1) {
            std.debug.print("expected 1 enabled tool, got {d}: {s}\n", .{ tools.items.len, listed_raw });
            return error.TestUnexpectedResult;
        }
        const name = switch (tools.items[0]) {
            .string => |x| x,
            else => {
                std.debug.print("tool entry is not a string: {s}\n", .{listed_raw});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqualStrings("read_file", name);
    }

    {
        const bundle_raw = try bundleBody(&h, ws_id, routine_id);
        defer gpa.free(bundle_raw);
        var doc = try parseJson(bundle_raw);
        defer doc.deinit();
        const bundle = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("bundle is not a JSON object: {s}\n", .{bundle_raw});
                return error.TestUnexpectedResult;
            },
        };
        const arr = bundle.get("tools") orelse {
            std.debug.print("bundle has no `tools`: {s}\n", .{bundle_raw});
            return error.TestUnexpectedResult;
        };
        const tools = switch (arr) {
            .array => |a| a,
            else => {
                std.debug.print("`tools` is not an array: {s}\n", .{bundle_raw});
                return error.TestUnexpectedResult;
            },
        };
        if (tools.items.len != 1) {
            std.debug.print("bundle expected 1 enabled tool, got {d}: {s}\n", .{ tools.items.len, bundle_raw });
            return error.TestUnexpectedResult;
        }
        const name = switch (tools.items[0]) {
            .string => |x| x,
            else => {
                std.debug.print("bundle tool entry is not a string: {s}\n", .{bundle_raw});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqualStrings("read_file", name);
    }

    {
        const deleted_raw = try routineCall(&h, .DELETE, routine_id, "tools/read_file", null, &.{200});
        defer gpa.free(deleted_raw);
    }

    {
        const listed_raw = try routineCall(&h, .GET, routine_id, "tools", null, &.{200});
        defer gpa.free(listed_raw);
        var doc = try parseJson(listed_raw);
        defer doc.deinit();
        const listed = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("tools LIST did not return an object: {s}\n", .{listed_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectEmptyArray(listed, "tools", "tools LIST after DELETE");
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = createWorkspace;
    _ = createRoutine;
    _ = createKanban;
    _ = bundleBody;
    _ = routineCall;
    _ = rowId;
    _ = expectStr;
    _ = expectInt;
    _ = expectEmptyArray;
    _ = expectErrorContains;
}
