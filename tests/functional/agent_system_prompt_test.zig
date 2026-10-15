// Functional tests for the agent_system_prompt CRUD wire.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// `POST /api/agents/:agent_id/system_prompt` body.
const CreateBody = struct {
    title: []const u8,
    content: []const u8,
};

/// `POST /api/workspaces/:ws/items/agent` body (`CreateAgentBody`).
const AgentBody = struct {
    name: []const u8,
    path: []const u8,
};

// ============================================================================
// Helpers (Python `_create_workspace` / `_create_agent` / `_create_prompt` /
// `_get_bundle`)

/// `_create_workspace` — create a fresh workspace, return its OWNED id.
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

/// `_create_agent` — create an Agent workspace item, return its OWNED id
/// (= `workspace_item.id` per the agents/workspace_items 1-1 invariant).
fn createAgent(h: *Harness, workspace_id: []const u8) ![]u8 {
    const path = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-system-prompt-test"});
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, AgentBody{
        .name = "asp-agent",
        .path = path,
    }, .{});
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
    const id_val = item.get("id") orelse {
        std.debug.print("agent item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (id_val) {
        .string => |sv| sv,
        else => {
            std.debug.print("agent item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `_create_prompt` — POST a create; the caller owns the `Response`. The
/// Python returned `r.json()`, which in Zig would be a borrowed `Json`.
fn createPrompt(
    h: *Harness,
    agent_id: []const u8,
    title: []const u8,
    content: []const u8,
    expect: []const u16,
) !harness.Response {
    const body = try std.json.Stringify.valueAlloc(gpa, CreateBody{
        .title = title,
        .content = content,
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt", .{agent_id});
    defer gpa.free(url);

    return h.http(io, .POST, url, .{ .json_body = body, .expect = expect });
}

/// `_get_bundle` — `GET /api/workspaces/:ws/items/:id/agent`.
fn getBundle(h: *Harness, workspace_id: []const u8, item_id: []const u8) !harness.Response {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/agent",
        .{ workspace_id, item_id },
    );
    defer gpa.free(url);
    return h.http(io, .GET, url, .{ .expect = &.{200} });
}

/// The `position` of the system-prompt row `prompt_id` inside a bundle body,
/// or a test failure. Python built `{p["id"]: p["position"] ...}` and indexed
/// it.
fn bundlePosition(bundle_body: []const u8, prompt_id: []const u8) !i64 {
    var doc: harness.Json = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bundle_body, .{}),
    };
    defer doc.deinit();

    const prompts = doc.array("system_prompts") orelse {
        std.debug.print("bundle has no `system_prompts` array: {s}\n", .{bundle_body});
        return error.TestUnexpectedResult;
    };
    for (prompts.items) |v| {
        const obj = switch (v) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        if (!std.mem.eql(u8, id, prompt_id)) continue;
        const pos_val = obj.get("position");
        if (pos_val == null) {
            std.debug.print("row {s} has no `position` field: {s}\n", .{ prompt_id, bundle_body });
            return error.TestUnexpectedResult;
        }
        const pos = switch (pos_val.?) {
            .integer => |i| i,
            else => {
                std.debug.print("row {s} has no integer `position`: {s}\n", .{ prompt_id, bundle_body });
                return error.TestUnexpectedResult;
            },
        };
        return pos;
    }
    std.debug.print("row {s} is not in the bundle: {s}\n", .{ prompt_id, bundle_body });
    return error.TestUnexpectedResult;
}

/// Whether `prompt_id` appears among the bundle's `system_prompts` ids.
fn bundleContains(bundle_body: []const u8, prompt_id: []const u8) !bool {
    var doc: harness.Json = .{
        .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bundle_body, .{}),
    };
    defer doc.deinit();

    const prompts = doc.array("system_prompts") orelse {
        std.debug.print("bundle has no `system_prompts` array: {s}\n", .{bundle_body});
        return error.TestUnexpectedResult;
    };
    for (prompts.items) |v| {
        const obj = switch (v) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        if (std.mem.eql(u8, id, prompt_id)) return true;
    }
    return false;
}

// ============================================================================
// TestCreateSystemPrompt
// ============================================================================

// CREATE — 201 with the stored row, at position 0.
test "create_returns_201_with_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    var r = try createPrompt(&h, agent_id, "Persona", "You are a pirate.", &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const id = doc.str("id") orelse "";
    if (!std.mem.startsWith(u8, id, "asp_")) {
        std.debug.print("bad id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    const row_agent = doc.str("agent_id") orelse {
        std.debug.print("row has no agent_id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(agent_id, row_agent);
    try testing.expectEqualStrings("Persona", doc.str("title") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("You are a pirate.", doc.str("content") orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(i64, 0), doc.int("position") orelse return error.TestUnexpectedResult);
}

// The second row lands at position 1 — positions are assigned in order.
test "second_row_gets_position_1" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    {
        var first = try createPrompt(&h, agent_id, "A", "body a", &.{201});
        defer first.deinit();
    }
    var r = try createPrompt(&h, agent_id, "B", "body b", &.{201});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(@as(i64, 1), doc.int("position") orelse return error.TestUnexpectedResult);
}

// VALIDATE — empty content is a 400 with an error envelope.
test "empty_content_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    var r = try createPrompt(&h, agent_id, "T", "", &.{400});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("expected error envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// VALIDATE — whitespace-only content is a 400 too (the trim, not just
// the length check, is what rejects it).
test "whitespace_content_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    var r = try createPrompt(&h, agent_id, "T", "   \n\t ", &.{400});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("expected error envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// UNKNOWN — an agent id that does not exist is a 404, not a 500.
test "unknown_agent_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try createPrompt(&h, "ws_item_404", "T", "C", &.{404});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("expected error envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// TestUpdateSystemPrompt
// ============================================================================

// UPDATE — PATCH title + content, both change on the wire.
test "patch_updates_title_and_content" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    const row_id = blk: {
        var row = try createPrompt(&h, agent_id, "Old", "old body", &.{201});
        defer row.deinit();
        var row_doc = try row.json();
        defer row_doc.deinit();
        const id = row_doc.str("id") orelse {
            std.debug.print("create returned no id: {s}\n", .{row.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(row_id);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/{s}", .{ agent_id, row_id });
    defer gpa.free(url);
    var r = try h.http(io, .PATCH, url, .{
        .json_body = "{\"title\":\"New\",\"content\":\"new body\"}",
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqualStrings("New", doc.str("title") orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("new body", doc.str("content") orelse return error.TestUnexpectedResult);
}

// EMPTYSTR — `content: ""` is legal and must NOT become SQL NULL. Regression:
// `SqliteBackend.exec` binds `""` as SQL NULL, which trips `content`'s NOT
// NULL constraint without `COALESCE(?, '')`.
test "patch_empty_string_content_is_legal_not_null" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    const row_id = blk: {
        var row = try createPrompt(&h, agent_id, "Keep", "body", &.{201});
        defer row.deinit();
        var row_doc = try row.json();
        defer row_doc.deinit();
        const id = row_doc.str("id") orelse {
            std.debug.print("create returned no id: {s}\n", .{row.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(row_id);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/{s}", .{ agent_id, row_id });
    defer gpa.free(url);
    var r = try h.http(io, .PATCH, url, .{
        .json_body = "{\"content\":\"\"}",
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const content = doc.str("content") orelse {
        std.debug.print("no content field on the PATCH result: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("", content);
    try testing.expectEqualStrings("Keep", doc.str("title") orelse return error.TestUnexpectedResult);
}

// UNKNOWN — PATCHing a row that does not exist is a 404.
test "patch_unknown_row_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/asp_404", .{agent_id});
    defer gpa.free(url);
    // The Python made the call and discarded the response — the 404 IS
    // the assertion (`expect=404` raises in the harness).
    var r = try h.http(io, .PATCH, url, .{
        .json_body = "{\"title\":\"X\"}",
        .expect = &.{404},
    });
    defer r.deinit();
}

// ============================================================================
// TestDeleteSystemPrompt
// ============================================================================

// DELETE — 200 {ok:true}, and the row disappears from the bundle.
test "delete_removes_row_from_bundle" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    const row_id = blk: {
        var row = try createPrompt(&h, agent_id, "Doomed", "bye", &.{201});
        defer row.deinit();
        var row_doc = try row.json();
        defer row_doc.deinit();
        const id = row_doc.str("id") orelse {
            std.debug.print("create returned no id: {s}\n", .{row.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(row_id);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/{s}", .{ agent_id, row_id });
    defer gpa.free(url);
    {
        var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("ok") orelse return error.TestUnexpectedResult);
    }

    var bundle = try getBundle(&h, ws, agent_id);
    defer bundle.deinit();
    if (try bundleContains(bundle.body, row_id)) {
        std.debug.print("deleted row {s} is still in the bundle: {s}\n", .{ row_id, bundle.body });
        return error.TestUnexpectedResult;
    }
}

// DELETE of a row that was never there is a no-op 200, not a 404 — the
// frontend's list does not race the server on this.
test "delete_unknown_row_is_noop_200" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/asp_404", .{agent_id});
    defer gpa.free(url);
    var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(true, doc.boolean("ok") orelse return error.TestUnexpectedResult);
}

// ============================================================================
// TestReorderSystemPrompt
// ============================================================================

// REORDER — reversing the list renumbers `position` to match.
test "reorder_updates_positions" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    // Owned ids: the PATCH body below outlives the responses that minted
    // them, and the bundle assertions outlive everything.
    var id_a = try createPrompt(&h, agent_id, "A", "body a", &.{201});
    defer id_a.deinit();
    const a = blk: {
        var d = try id_a.json();
        defer d.deinit();
        const s = d.str("id") orelse return error.TestUnexpectedResult;
        break :blk try gpa.dupe(u8, s);
    };
    defer gpa.free(a);

    var id_b = try createPrompt(&h, agent_id, "B", "body b", &.{201});
    defer id_b.deinit();
    const b = blk: {
        var d = try id_b.json();
        defer d.deinit();
        const s = d.str("id") orelse return error.TestUnexpectedResult;
        break :blk try gpa.dupe(u8, s);
    };
    defer gpa.free(b);

    var id_c = try createPrompt(&h, agent_id, "C", "body c", &.{201});
    defer id_c.deinit();
    const c = blk: {
        var d = try id_c.json();
        defer d.deinit();
        const s = d.str("id") orelse return error.TestUnexpectedResult;
        break :blk try gpa.dupe(u8, s);
    };
    defer gpa.free(c);

    // Reverse: C first (highest position), then B, then A.
    {
        const url = try std.fmt.allocPrint(gpa, "/api/agents/{s}/system_prompt/reorder", .{agent_id});
        defer gpa.free(url);
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"ordered_ids\":[\"{s}\",\"{s}\",\"{s}\"]}}",
            .{ c, b, a },
        );
        defer gpa.free(body);
        var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
    }

    var bundle = try getBundle(&h, ws, agent_id);
    defer bundle.deinit();

    const pos_c = try bundlePosition(bundle.body, c);
    if (pos_c != 2) {
        std.debug.print("C should be position 2, got {d}: {s}\n", .{ pos_c, bundle.body });
        return error.TestUnexpectedResult;
    }
    const pos_b = try bundlePosition(bundle.body, b);
    if (pos_b != 1) {
        std.debug.print("B should be position 1, got {d}: {s}\n", .{ pos_b, bundle.body });
        return error.TestUnexpectedResult;
    }
    const pos_a = try bundlePosition(bundle.body, a);
    if (pos_a != 0) {
        std.debug.print("A should be position 0, got {d}: {s}\n", .{ pos_a, bundle.body });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// TestGetBundleIncludesSystemPrompts
// ============================================================================

// BUNDLE — a fresh agent carries `system_prompts: []`, PRESENT and empty
// (the frontend renders an empty-state list off this exact key).
test "fresh_agent_has_empty_system_prompts_array" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    var bundle = try getBundle(&h, ws, agent_id);
    defer bundle.deinit();
    var doc = try bundle.json();
    defer doc.deinit();

    const prompts = doc.array("system_prompts") orelse {
        std.debug.print("fresh agent should have an empty system_prompts array: {s}\n", .{bundle.body});
        return error.TestUnexpectedResult;
    };
    if (prompts.items.len != 0) {
        std.debug.print("fresh agent should have an empty system_prompts array: {s}\n", .{bundle.body});
        return error.TestUnexpectedResult;
    }
}

// BUNDLE — a created row is listed by the bundle, with its own id.
test "bundle_lists_created_rows" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "asp-ws");
    defer gpa.free(ws);
    const agent_id = try createAgent(&h, ws);
    defer gpa.free(agent_id);

    var created = try createPrompt(&h, agent_id, "Listed", "shown in bundle", &.{201});
    defer created.deinit();
    const row_id = blk: {
        var d = try created.json();
        defer d.deinit();
        const s = d.str("id") orelse {
            std.debug.print("create returned no id: {s}\n", .{created.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, s);
    };
    defer gpa.free(row_id);

    var bundle = try getBundle(&h, ws, agent_id);
    defer bundle.deinit();
    var doc = try bundle.json();
    defer doc.deinit();

    const prompts = doc.array("system_prompts") orelse {
        std.debug.print("bundle has no system_prompts array: {s}\n", .{bundle.body});
        return error.TestUnexpectedResult;
    };
    if (prompts.items.len != 1) {
        std.debug.print("expected exactly 1 row in the bundle, got {d}: {s}\n", .{ prompts.items.len, bundle.body });
        return error.TestUnexpectedResult;
    }
    const first = switch (prompts.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const listed = switch (first.get("id") orelse return error.TestUnexpectedResult) {
        .string => |sv| sv,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings(row_id, listed);
}
