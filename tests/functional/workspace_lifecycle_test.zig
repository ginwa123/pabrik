// Functional tests for workspace lifecycle. Zig port of
// `tests/functional/workspace_lifecycle_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// POST /api/workspaces → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `assert "id" in body` and `assert body["id"].startswith("ws_")`.
    const id = doc.str("id") orelse {
        std.debug.print("workspace create response missing id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.startsWith(u8, id, "ws_")) {
        std.debug.print("workspace id should start with 'ws_', got '{s}': {s}\n", .{ id, r.body });
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, id);
}

/// POST /api/workspaces/:wid/items → the new item's id. Owned.
fn createItem(h: *Harness, workspace_id: []const u8, name: []const u8, item_type: []const u8, path: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"{s}\",\"item_type\":\"{s}\",\"path\":\"{s}\"}}",
        .{ name, item_type, path },
    );
    defer gpa.free(body);

    const p = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{workspace_id});
    defer gpa.free(p);

    var r = try h.http(io, .POST, p, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // Python asserted the `item_` prefix plus an echo of name and item_type on
    // the create response. All three are wire contract, so all three stay.
    const id = doc.str("id") orelse {
        std.debug.print("item create response missing id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.startsWith(u8, id, "item_")) {
        std.debug.print("item id should start with 'item_', got '{s}': {s}\n", .{ id, r.body });
        return error.TestUnexpectedResult;
    }
    const got_name = doc.str("name") orelse {
        std.debug.print("item create response missing name: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_name, name)) {
        std.debug.print("item create echoed name '{s}', sent '{s}': {s}\n", .{ got_name, name, r.body });
        return error.TestUnexpectedResult;
    }
    const got_type = doc.str("item_type") orelse {
        std.debug.print("item create response missing item_type: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_type, item_type)) {
        std.debug.print("item create echoed item_type '{s}', sent '{s}': {s}\n", .{ got_type, item_type, r.body });
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, id);
}

/// What `GET /api/workspaces/:wid/items` yielded, reduced to the numbers and
/// flags the assertions read.
const ItemsSummary = struct {
    /// Every row, including the workspace's DEFAULT project.
    total: usize,
    /// Rows that are NOT the default project — the ones the test created.
    created: usize,
    /// Rows carrying `is_default == 1`.
    defaults: usize,
    /// `item_type` of the first default row. Null when there is no default.
    default_item_type: ?[]u8,
    /// The distinct `item_type`s among the created rows.
    types: [][]u8,

    fn deinit(self: *ItemsSummary) void {
        if (self.default_item_type) |t| gpa.free(t);
        for (self.types) |t| gpa.free(t);
        gpa.free(self.types);
        self.* = undefined;
    }

    /// Does one of the created rows carry `item_type == t`?
    fn hasType(self: *const ItemsSummary, t: []const u8) bool {
        for (self.types) |have| {
            if (std.mem.eql(u8, have, t)) return true;
        }
        return false;
    }
};

/// GET /api/workspaces/:wid/items, summarised. Caller `deinit`s.
fn listItems(h: *Harness, workspace_id: []const u8) !ItemsSummary {
    const p = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{workspace_id});
    defer gpa.free(p);

    var r = try h.http(io, .GET, p, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // Python accepted `{"items": [...]}` OR a bare list. The handler emits the
    // object form (`makeWorkspaceItemListObjectResponse`), but both are
    // tolerated so a future wire reshape does not read as a regression here.
    const arr = switch (doc.value().*) {
        .array => |a| a,
        .object => blk: {
            const inner = doc.array("items") orelse {
                std.debug.print("unexpected items response shape: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            };
            break :blk inner;
        },
        else => {
            std.debug.print("unexpected items response shape: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };

    var types: std.ArrayList([]u8) = .empty;
    errdefer {
        for (types.items) |t| gpa.free(t);
        types.deinit(gpa);
    }

    var out = ItemsSummary{
        .total = arr.items.len,
        .created = 0,
        .defaults = 0,
        .default_item_type = null,
        .types = &.{},
    };
    errdefer out.deinit();

    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("item row is not an object: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        // A missing `is_default` reads as 0 (a non-default row), which is the
        // same default the server's own `WorkspaceItemFullResponse` declares.
        const is_default: i64 = switch (o.get("is_default") orelse std.json.Value{ .integer = 0 }) {
            .integer => |n| n,
            else => 0,
        };
        const item_type = switch (o.get("item_type") orelse {
            std.debug.print("item row has no item_type: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("item_type is not a string: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };

        if (is_default == 1) {
            out.defaults += 1;
            if (out.default_item_type == null) out.default_item_type = try gpa.dupe(u8, item_type);
            continue;
        }
        out.created += 1;
        var seen = false;
        for (types.items) |have| {
            if (std.mem.eql(u8, have, item_type)) {
                seen = true;
                break;
            }
        }
        if (!seen) types.append(gpa, try gpa.dupe(u8, item_type)) catch return error.OutOfMemory;
    }

    out.types = try types.toOwnedSlice(gpa);
    return out;
}

/// One row of `GET /api/workspaces`. Owned.
const WorkspaceRow = struct {
    id: []u8,
    name: []u8,

    fn deinit(self: *WorkspaceRow) void {
        gpa.free(self.id);
        gpa.free(self.name);
    }
};

/// Free a `WorkspaceRow` slice.
fn freeRows(rows: []WorkspaceRow) void {
    for (rows) |*r| r.deinit();
    gpa.free(rows);
}

/// GET /api/workspaces as owned rows. Python's `_list_workspaces`.
fn listWorkspaces(h: *Harness, include_items: bool) ![]WorkspaceRow {
    const flag = if (include_items) "true" else "false";
    var r = try h.http(io, .GET, "/api/workspaces", .{
        .params = &.{.{ .name = "is_include_items", .value = flag }},
        .expect = &.{200},
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const arr = doc.array("workspaces") orelse {
        std.debug.print("workspaces list has no `workspaces` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const rows = try gpa.alloc(WorkspaceRow, arr.items.len);
    errdefer freeRows(rows);
    for (arr.items, 0..) |item, i| {
        const o = switch (item) {
            .object => |m| m,
            else => {
                std.debug.print("workspace row {d} is not an object\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        const id = switch (o.get("id") orelse {
            std.debug.print("workspace row {d} has no id\n", .{i});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("workspace row {d} id is not a string\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        const name = switch (o.get("name") orelse {
            std.debug.print("workspace row {d} has no name\n", .{i});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("workspace row {d} name is not a string\n", .{i});
                return error.TestUnexpectedResult;
            },
        };
        rows[i] = .{ .id = try gpa.dupe(u8, id), .name = try gpa.dupe(u8, name) };
    }
    return rows;
}

// ============================================================================
// Test 1: create returns 201 with a `ws_` id
// ============================================================================

// POST /api/workspaces returns 201 + an id starting with ws_.
test "create_workspace_returns_201_with_id" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // The Python helper asserted the `ws_` prefix inside itself; the id is
    // returned here, and the NAME echo is asserted here because that is the
    // one thing this test exists to pin.
    const id = try createWorkspace(&h, "create-test");
    defer gpa.free(id);

    {
        var r = try h.http(io, .GET, "/api/workspaces", .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        const arr = doc.array("workspaces") orelse {
            std.debug.print("workspaces list has no `workspaces` array: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        var found = false;
        for (arr.items) |item| {
            const o = switch (item) {
                .object => |m| m,
                else => continue,
            };
            const w_id = switch (o.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, w_id, id)) continue;
            found = true;
            const name = switch (o.get("name") orelse {
                std.debug.print("created workspace has no name: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => {
                    std.debug.print("workspace name is not a string: {s}\n", .{r.body});
                    return error.TestUnexpectedResult;
                },
            };
            if (!std.mem.eql(u8, name, "create-test")) {
                std.debug.print("created workspace named '{s}', sent 'create-test': {s}\n", .{ name, r.body });
                return error.TestUnexpectedResult;
            }
        }
        if (!found) {
            std.debug.print("created workspace {s} missing from the list: {s}\n", .{ id, r.body });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 2: list includes every created workspace
// ============================================================================

// Create 3 workspaces, list, assert all 3 are present with right names.
test "list_workspaces_returns_created" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const wanted = [_][]const u8{ "alpha", "beta", "gamma" };
    for (wanted) |name| {
        const id = try createWorkspace(&h, name);
        gpa.free(id);
    }

    const listed = try listWorkspaces(&h, true);
    defer freeRows(listed);

    for (wanted) |name| {
        var found = false;
        for (listed) |w| {
            if (std.mem.eql(u8, w.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("expected '{s}' in the list, got:", .{name});
            for (listed) |w| std.debug.print(" {s}", .{w.name});
            std.debug.print("\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 3: an empty name is a failure, and the body says why
// ============================================================================

// POST with {"name": ""} returns 500 (a bug, should be 400).
test "create_workspace_rejects_empty_name" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Accept either 400 (after fix) or 500 (current bug) — assert the
    // response indicates failure, not success.
    const body = "{\"name\":\"\"}";
    var r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = body,
        .expect = &.{ 400, 500 },
    });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `assert "error" in body`.
    if (doc.get("error") == null) {
        std.debug.print("empty-name error should include an error field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: a missing name is a 400
// ============================================================================

// POST with {} returns 400.
test "create_workspace_rejects_missing_name" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = "{}", .expect = &.{400} });
    defer r.deinit();
}

// ============================================================================
// Test 5: rename round-trips
// ============================================================================

// Create, PUT new name, GET shows the new name.
test "update_workspace_name_round_trips" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "before-rename");
    defer gpa.free(ws_id);

    {
        const put_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_id});
        defer gpa.free(put_path);
        var r = try h.http(io, .PUT, put_path, .{
            .json_body = "{\"name\":\"after-rename\"}",
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("PUT response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqualStrings("after-rename", doc.str("name") orelse {
            std.debug.print("PUT response has no string `name`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    const listed = try listWorkspaces(&h, true);
    defer freeRows(listed);

    var found = false;
    for (listed) |w| {
        if (!std.mem.eql(u8, w.id, ws_id)) continue;
        found = true;
        if (!std.mem.eql(u8, w.name, "after-rename")) {
            std.debug.print("workspace {s} listed as '{s}', expected 'after-rename'\n", .{ ws_id, w.name });
            return error.TestUnexpectedResult;
        }
        break;
    }
    if (!found) {
        std.debug.print("workspace {s} not in list after rename\n", .{ws_id});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: seven mixed-type items, plus the automatic default project
// ============================================================================

// 3 chat + 2 kanban + 2 design items; all 7 are listed back.
test "create_seven_items_of_mixed_types" {
    try harness.requirePabrikBin(io, gpa);

    // pytest's `tmp_path` was a SIBLING of the harness tempdir, never a child
    // of it — `makeScratchDir` gives the suite its own `pabrik-fix-`
    // namespace that the orphan reaper (which only matches `pabrik-func-`)
    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` is registered FIRST so it runs LAST —
    // `cleanupExtraDir` reads `scratch` to delete it.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base_path = try harness.harnessPath(gpa, scratch, &.{"item"});
    defer gpa.free(base_path);
    try std.Io.Dir.cwd().createDirPath(io, base_path);

    const login_path = try std.fmt.allocPrint(gpa, "{s}/login", .{base_path});
    defer gpa.free(login_path);
    try std.Io.Dir.cwd().createDirPath(io, login_path);
    const dashboard_path = try std.fmt.allocPrint(gpa, "{s}/dashboard", .{base_path});
    defer gpa.free(dashboard_path);
    try std.Io.Dir.cwd().createDirPath(io, dashboard_path);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-test");
    defer gpa.free(ws_id);

    const ItemSpec = struct { name: []const u8, kind: []const u8, path: []const u8 };
    const to_create = [_]ItemSpec{
        .{ .name = "alpha-chat", .kind = "chat", .path = base_path },
        .{ .name = "beta-chat", .kind = "chat", .path = base_path },
        .{ .name = "gamma-chat", .kind = "chat", .path = base_path },
        .{ .name = "sprint-1", .kind = "kanban", .path = base_path },
        .{ .name = "sprint-2", .kind = "kanban", .path = base_path },
        .{ .name = "login-page", .kind = "design", .path = login_path },
        .{ .name = "dashboard-page", .kind = "design", .path = dashboard_path },
    };

    var created: usize = 0;
    for (to_create) |spec| {
        const id = try createItem(&h, ws_id, spec.name, spec.kind, spec.path);
        gpa.free(id);
        created += 1;
    }
    try testing.expectEqual(@as(usize, 7), created);

    // 8, not 7: Migration 094 gives every workspace a DEFAULT project (an
    // `agent` item rooted at $HOME).
    var items = try listItems(&h, ws_id);
    defer items.deinit();

    if (items.defaults != 1) {
        std.debug.print("expected exactly one default project, got {d}\n", .{items.defaults});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 7), items.created);

    // All three types present among the created rows.
    if (!items.hasType("chat") or !items.hasType("kanban") or !items.hasType("design")) {
        std.debug.print("expected all 3 item types among the created rows\n", .{});
        return error.TestUnexpectedResult;
    }
    // And the default is an agent, which is what makes the New Chat action a
    // single tap on both clients rather than a two-step picker.
    const def_type = items.default_item_type orelse {
        std.debug.print("the default project row has no item_type\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, def_type, "agent")) {
        std.debug.print("default project item_type is '{s}', expected 'agent'\n", .{def_type});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: deleting a workspace leaves its items as orphans
// ============================================================================

// Delete behavior: the workspace is removed, items become orphans.
test "delete_workspace_orphans_items" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` is registered FIRST so it runs LAST.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base_path = try harness.harnessPath(gpa, scratch, &.{"item"});
    defer gpa.free(base_path);
    try std.Io.Dir.cwd().createDirPath(io, base_path);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "delete-test");
    defer gpa.free(ws_id);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const name = try std.fmt.allocPrint(gpa, "item-{d}", .{i});
        defer gpa.free(name);
        const id = try createItem(&h, ws_id, name, "chat", base_path);
        gpa.free(id);
    }

    // +1: the workspace's DEFAULT project (Migration 094), created with the
    // workspace. It orphans along with the rest — the cascade gap documented
    // in this test's header applies to it like any other item.
    {
        var before = try listItems(&h, ws_id);
        defer before.deinit();
        try testing.expectEqual(@as(usize, 4), before.total);
    }

    {
        const del_path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_id});
        defer gpa.free(del_path);
        var r = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("DELETE response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    // Workspace is gone from the list.
    {
        const listed = try listWorkspaces(&h, true);
        defer freeRows(listed);
        for (listed) |w| {
            if (std.mem.eql(u8, w.id, ws_id)) {
                std.debug.print("deleted workspace {s} still in list\n", .{ws_id});
                return error.TestUnexpectedResult;
            }
        }
    }

    // Items persist as orphans (current behavior — see header comment).
    // 4 = the 3 created + the workspace's DEFAULT project (Migration 094),
    // which orphaned with them.
    var after = try listItems(&h, ws_id);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 4), after.total);
    if (after.defaults != 1) {
        std.debug.print("the default project should orphan with the rest; defaults={d}\n", .{after.defaults});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: reorder changes the listed position
// ============================================================================

// Create 3 workspaces, reorder to [c, a, b], list comes back in that order.
// The reorder endpoint assigns positions such that `ORDER BY position DESC`
// returns the input order. The first id in `ordered_ids` ends up at the top.
test "reorder_workspaces_changes_position" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const a_id = try createWorkspace(&h, "alpha");
    defer gpa.free(a_id);
    const b_id = try createWorkspace(&h, "beta");
    defer gpa.free(b_id);
    const c_id = try createWorkspace(&h, "gamma");
    defer gpa.free(c_id);

    {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"ordered_ids\":[\"{s}\",\"{s}\",\"{s}\"]}}",
            .{ c_id, a_id, b_id },
        );
        defer gpa.free(body);
        var r = try h.http(io, .POST, "/api/workspaces/reorder", .{
            .json_body = body,
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();
        try testing.expectEqual(true, doc.boolean("success") orelse {
            std.debug.print("reorder response has no bool `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
        try testing.expectEqual(@as(i64, 3), doc.int("count") orelse {
            std.debug.print("reorder response has no integer `count`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        });
    }

    const listed = try listWorkspaces(&h, false);
    defer freeRows(listed);

    // The reorder places c first, a second, b third. Only the PREFIX is
    // checked: other workspaces (if any) may follow it.
    const want = [_][]const u8{ c_id, a_id, b_id };
    if (listed.len < want.len) {
        std.debug.print("listed only {d} workspaces, expected at least {d}\n", .{ listed.len, want.len });
        return error.TestUnexpectedResult;
    }
    for (want, 0..) |expected, i| {
        if (!std.mem.eql(u8, listed[i].id, expected)) {
            std.debug.print(
                "reordered workspaces should be [c, a, b]; position {d} is {s} ('{s}'), expected {s}\n",
                .{ i, listed[i].id, listed[i].name, expected },
            );
            return error.TestUnexpectedResult;
        }
    }
}

comptime {
    _ = createWorkspace;
    _ = createItem;
    _ = listItems;
    _ = listWorkspaces;
    _ = freeRows;
}
