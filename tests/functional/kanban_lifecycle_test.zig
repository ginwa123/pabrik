// Functional tests for kanban lifecycle. Zig port of
// `tests/functional/kanban_lifecycle_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// HTTP helpers
// ============================================================================

/// Python `_create_workspace`. Owned.
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

/// Python `_create_kanban`. Returns the new kanban item id (owned).
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/kanban",
        .{workspace_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("create kanban response is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    const item_val = root.get("item") orelse {
        std.debug.print("created kanban response missing 'item' envelope: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const item = switch (item_val) {
        .object => |o| o,
        else => {
            std.debug.print("'item' envelope is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    const item_type = switch (item.get("item_type") orelse {
        std.debug.print("created kanban item has no item_type: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, item_type, "kanban")) {
        std.debug.print("created item should be type 'kanban', got '{s}'\n", .{item_type});
        return error.TestUnexpectedResult;
    }
    const id = switch (item.get("id") orelse return error.TestUnexpectedResult) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (std.mem.indexOf(u8, id, "item_") != 0) {
        std.debug.print("created item id should start with 'item_', got '{s}'\n", .{id});
        return error.TestUnexpectedResult;
    }
    // The envelope also returns the 3 freshly-seeded default columns -
    // sanity-check the contract is honoured (not part of the bug fix,
    // but cheap to assert and catches regressions).
    switch (root.get("columns") orelse {
        std.debug.print("created kanban envelope should include a 'columns' list, got {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .array => {},
        else => {
            std.debug.print("created kanban envelope should include a 'columns' list, got {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    }
    return gpa.dupe(u8, id);
}

/// `GET .../kanban/columns` → the parsed `{columns:[...]}` document.
fn listColumnsDoc(h: *Harness, workspace_id: []const u8, kanban_id: []const u8) !harness.Json {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return .{
        .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            r.body,
            .{ .allocate = .alloc_always },
        ),
    };
}

/// Python `_add_column`. Returns the WHOLE body (owned).
fn addColumn(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    position: ?i64,
) ![]u8 {
    // `emit_null_optional_fields = false` is what makes an absent
    // `position` OMITTED rather than `"position": null` - Python only
    // added the key when the caller passed one.
    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{ .name = name, .position = position },
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Python `_add_task`. Returns the WHOLE body (owned).
fn addTask(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    column_id: ?[]const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{ .name = name, .column_id = column_id },
        .{ .emit_null_optional_fields = false },
    );
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Python `_list_tasks` → the parsed `{tasks:[...]}` document. Owned and
/// self-contained (see `listColumnsDoc`).
fn listTasksDoc(h: *Harness, workspace_id: []const u8, kanban_id: []const u8) !harness.Json {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{
        .params = &.{.{ .name = "limit", .value = "100" }},
        .expect = &.{200},
    });
    defer r.deinit();
    return .{
        .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            r.body,
            .{ .allocate = .alloc_always },
        ),
    };
}

/// Python `body.get("tasks", body if isinstance(body, list) else [])`: the
/// `tasks` array if the root is an object carrying one, the root itself if
/// the root is already a list, else empty.
fn tasksArray(doc: *const harness.Json, ctx: []const u8) !std.json.Array {
    const empty: std.json.Array = .{ .items = &.{}, .capacity = 0, .allocator = gpa };
    return switch (doc.value().*) {
        .array => |a| a,
        .object => |o| {
            const v = o.get("tasks") orelse return empty;
            return switch (v) {
                .array => |a| a,
                else => empty,
            };
        },
        else => {
            std.debug.print("{s}: unexpected tasks payload\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// The `columns` array of a `listColumnsDoc` document. Borrows `doc`.
fn columnsArray(doc: *const harness.Json, ctx: []const u8) !std.json.Array {
    const root = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not an object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
    const v = root.get("columns") orelse {
        std.debug.print("{s}: no `columns` array\n", .{ctx});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .array => |a| a,
        else => {
            std.debug.print("{s}: `columns` is not an array\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// The root object of a parsed JSON document.
fn rootObj(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

fn objectAt(arr: std.json.Array, idx: usize, ctx: []const u8) !std.json.ObjectMap {
    return switch (arr.items[idx]) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: entry {d} is not an object\n", .{ ctx, idx });
            return error.TestUnexpectedResult;
        },
    };
}

fn strAt(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) ![]const u8 {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

fn expectStartsWith(s: []const u8, prefix: []const u8, ctx: []const u8) !void {
    if (std.mem.indexOf(u8, s, prefix) != 0) {
        std.debug.print("{s}: \"{s}\" does not start with \"{s}\"\n", .{ ctx, s, prefix });
        return error.TestUnexpectedResult;
    }
}

/// True when `arr` carries an entry whose `key` equals `want`.
fn arrayHasField(arr: std.json.Array, key: []const u8, want: []const u8) bool {
    for (arr.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const v = switch (obj.get(key) orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, v, want)) return true;
    }
    return false;
}

/// Python `r.json().get("success", True) is True` — an ABSENT `success`
/// key counts as success; a present one must be `true`.
fn successOrAbsent(doc: *const harness.Json, ctx: []const u8) !bool {
    const v = doc.get("success") orelse return true;
    return switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `success` is not a bool\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Python `sorted(c["name"] for c in cols)` rendered as one comparable
/// string. Owned.
fn sortedNamesCsv(arr: std.json.Array) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (arr.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const v = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try names.append(gpa, v);
    }
    std.mem.sort([]const u8, names.items, {}, strLessThan);
    return std.mem.join(gpa, ",", names.items);
}

comptime {
    // Body-analysis barrier: an unreferenced fn body is never
    // type-checked, so a stdlib rename inside one hides until a caller
    // appears.
    _ = createWorkspace;
    _ = createKanban;
    _ = listColumnsDoc;
    _ = addColumn;
    _ = addTask;
    _ = listTasksDoc;
    _ = columnsArray;
    _ = tasksArray;
    _ = rootObj;
    _ = objectAt;
    _ = strAt;
    _ = expectStartsWith;
    _ = arrayHasField;
    _ = sortedNamesCsv;
    _ = successOrAbsent;
}

// ============================================================================
// Test 1: kanban create seeds 3 default columns
// ============================================================================

// POST /items/kanban creates 3 default columns (todo/in_progress/done).
test "create_kanban_seeds_three_default_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-1");
    defer gpa.free(kanban_id);

    var doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer doc.deinit();
    const cols = try columnsArray(&doc, "seeded columns");
    if (cols.items.len != 3) {
        std.debug.print("expected 3 default columns, got {d}\n", .{cols.items.len});
        return error.TestUnexpectedResult;
    }
    // The default names are typically: todo, in_progress, done
    // (in some order). Just verify we have 3 distinct columns.
    var distinct: usize = 0;
    for (cols.items, 0..) |m, i| {
        const obj = switch (m) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const name = try strAt(obj, "name", "seeded column");
        var seen = false;
        for (cols.items[0..i]) |prev| {
            const p = switch (prev) {
                .object => |o| o,
                else => continue,
            };
            const pn = switch (p.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, pn, name)) seen = true;
        }
        if (!seen) distinct += 1;
    }
    if (distinct != 3) {
        std.debug.print("expected 3 distinct column names, got {d}\n", .{distinct});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: add a 4th column
// ============================================================================

// Append a 4th column, list now has 4.
test "add_fourth_column" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    const new_col_body = try addColumn(&h, ws_id, kanban_id, "backlog", null);
    defer gpa.free(new_col_body);
    var new_col_doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, new_col_body, .{}) };
    defer new_col_doc.deinit();
    const new_col_id = try strAt(try rootObj(&new_col_doc, "new column"), "id", "new column");
    const new_col_id_dup = try gpa.dupe(u8, new_col_id);
    defer gpa.free(new_col_id_dup);
    try expectStartsWith(new_col_id, "col_", "new column id");
    try std.testing.expectEqualStrings("backlog", try strAt(try rootObj(&new_col_doc, "new column"), "name", "new column"));

    var doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer doc.deinit();
    const cols = try columnsArray(&doc, "columns after append");
    if (cols.items.len != 4) {
        std.debug.print("expected 4 columns, got {d}\n", .{cols.items.len});
        return error.TestUnexpectedResult;
    }
    if (!arrayHasField(cols, "id", new_col_id_dup)) {
        std.debug.print("appended column {s} missing from list\n", .{new_col_id_dup});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: add 12 tasks across 4 columns
// ============================================================================

// 4 columns x 3 tasks each = 12 tasks total.
test "add_twelve_tasks_across_four_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    {
        const extra = try addColumn(&h, ws_id, kanban_id, "backlog", null);
        gpa.free(extra);
    }
    var cols_doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer cols_doc.deinit();
    const cols = try columnsArray(&cols_doc, "4 columns");
    if (cols.items.len != 4) {
        std.debug.print("expected 4 columns, got {d}\n", .{cols.items.len});
        return error.TestUnexpectedResult;
    }

    var created: usize = 0;
    for (cols.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const col_name = try strAt(obj, "name", "column for tasks");
        const col_id = try strAt(obj, "id", "column for tasks");
        for (0..3) |j| {
            const task_name = try std.fmt.allocPrint(gpa, "{s}-task-{d}", .{ col_name, j });
            defer gpa.free(task_name);
            const task_body = try addTask(&h, ws_id, kanban_id, task_name, col_id);
            defer gpa.free(task_body);

            var task_doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, task_body, .{}) };
            defer task_doc.deinit();
            const task_id = try strAt(try rootObj(&task_doc, "created task"), "id", "created task");
            try expectStartsWith(task_id, "task_", "created task id");
            created += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 12), created);

    var tasks_doc = try listTasksDoc(&h, ws_id, kanban_id);
    defer tasks_doc.deinit();
    const tasks = try tasksArray(&tasks_doc, "tasks after seeding");
    if (tasks.items.len < 12) {
        std.debug.print("expected at least 12 tasks, got {d}\n", .{tasks.items.len});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: move task across columns
// ============================================================================

// Create task under col-A, move to col-B, verify presence/absence.
test "move_task_across_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    var cols_doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer cols_doc.deinit();
    const cols = try columnsArray(&cols_doc, "columns for move");
    if (cols.items.len < 2) {
        std.debug.print("need 2 seeded columns, got {d}\n", .{cols.items.len});
        return error.TestUnexpectedResult;
    }
    const col_a_obj = try objectAt(cols, 0, "columns for move");
    const col_b_obj = try objectAt(cols, 1, "columns for move");
    const col_a = try gpa.dupe(u8, try strAt(col_a_obj, "id", "col a"));
    defer gpa.free(col_a);
    const col_b = try gpa.dupe(u8, try strAt(col_b_obj, "id", "col b"));
    defer gpa.free(col_b);

    const task_body = try addTask(&h, ws_id, kanban_id, "movable", col_a);
    defer gpa.free(task_body);
    const task_id = blk: {
        var task_doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, task_body, .{}) };
        defer task_doc.deinit();
        break :blk try gpa.dupe(u8, try strAt(try rootObj(&task_doc, "movable task"), "id", "movable task"));
    };
    defer gpa.free(task_id);

    {
        const move_body = try std.json.Stringify.valueAlloc(gpa, .{
            .column_id = col_b,
            .position = 0,
        }, .{});
        defer gpa.free(move_body);
        const move_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks/{s}/move",
            .{ ws_id, kanban_id, task_id },
        );
        defer gpa.free(move_path);
        var r = try h.http(io, .PATCH, move_path, .{ .json_body = move_body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const root = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const success = switch (root.get("success") orelse return error.TestUnexpectedResult) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        };
        if (!success) {
            std.debug.print("move response success=false: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(col_b, try strAt(root, "column_id", "move response"));
    }

    // The task is now under col_b (verify by listing tasks and checking
    // the column_id field).
    var tasks_doc = try listTasksDoc(&h, ws_id, kanban_id);
    defer tasks_doc.deinit();
    const tasks = try tasksArray(&tasks_doc, "tasks after move");
    var moved: ?std.json.ObjectMap = null;
    for (tasks.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, task_id)) {
            moved = obj;
            break;
        }
    }
    const moved_obj = moved orelse {
        std.debug.print("task '{s}' not found after move\n", .{task_id});
        return error.TestUnexpectedResult;
    };
    const got_col = moved_obj.get("kanban_column_id") orelse {
        std.debug.print("moved task has no kanban_column_id\n", .{});
        return error.TestUnexpectedResult;
    };
    const got_col_s = switch (got_col) {
        .string => |s| s,
        else => {
            std.debug.print("task should be in col_b '{s}', got a non-string\n", .{col_b});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got_col_s, col_b)) {
        std.debug.print("task should be in col_b '{s}', got '{s}'\n", .{ col_b, got_col_s });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: move task to same column is idempotent
// ============================================================================

// Moving a task to the column it's already in is a no-op.
test "move_task_to_same_column_is_idempotent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    var cols_doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer cols_doc.deinit();
    const cols = try columnsArray(&cols_doc, "columns for idempotent move");
    const col_a_obj = try objectAt(cols, 0, "columns for idempotent move");
    const col_a = try gpa.dupe(u8, try strAt(col_a_obj, "id", "col a"));
    defer gpa.free(col_a);

    const task_body = try addTask(&h, ws_id, kanban_id, "stay", col_a);
    defer gpa.free(task_body);
    const task_id = blk: {
        var task_doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, task_body, .{}) };
        defer task_doc.deinit();
        break :blk try gpa.dupe(u8, try strAt(try rootObj(&task_doc, "stay task"), "id", "stay task"));
    };
    defer gpa.free(task_id);

    // Move to same column twice.
    const move_body = try std.json.Stringify.valueAlloc(gpa, .{
        .column_id = col_a,
        .position = 0,
    }, .{});
    defer gpa.free(move_body);
    const move_path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/move",
        .{ ws_id, kanban_id, task_id },
    );
    defer gpa.free(move_path);

    for (0..2) |round| {
        var r = try h.http(io, .PATCH, move_path, .{ .json_body = move_body, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const root = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const success = switch (root.get("success") orelse return error.TestUnexpectedResult) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        };
        if (!success) {
            std.debug.print("move round {d}: success=false: {s}\n", .{ round, r.body });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 6: delete column moves tasks to NULL (orphans)
// ============================================================================

// Delete a column: tasks get kanban_column_id=NULL (or stay but without the
// column).
test "delete_column_orphans_tasks" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    // Add a 4th column (no tasks), delete it, verify it's gone.
    const extra_body = try addColumn(&h, ws_id, kanban_id, "doomed", null);
    defer gpa.free(extra_body);
    const extra_id = blk: {
        var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, extra_body, .{}) };
        defer doc.deinit();
        break :blk try gpa.dupe(u8, try strAt(try rootObj(&doc, "doomed column"), "id", "doomed column"));
    };
    defer gpa.free(extra_id);

    {
        var before = try listColumnsDoc(&h, ws_id, kanban_id);
        defer before.deinit();
        const arr = try columnsArray(&before, "columns before delete");
        if (!arrayHasField(arr, "id", extra_id)) {
            std.debug.print("newly added column missing before delete\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    {
        const del_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
            .{ ws_id, kanban_id, extra_id },
        );
        defer gpa.free(del_path);
        var r = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const root = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const success = switch (root.get("success") orelse return error.TestUnexpectedResult) {
            .bool => |b| b,
            else => return error.TestUnexpectedResult,
        };
        if (!success) {
            std.debug.print("delete column success=false: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        var after_doc = try listColumnsDoc(&h, ws_id, kanban_id);
        defer after_doc.deinit();
        const cols_after = try columnsArray(&after_doc, "columns after delete");
        if (arrayHasField(cols_after, "id", extra_id)) {
            std.debug.print("deleted column '{s}' still in list\n", .{extra_id});
            return error.TestUnexpectedResult;
        }
        if (cols_after.items.len != 3) {
            std.debug.print("expected 3 columns after delete, got {d}\n", .{cols_after.items.len});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 7: pin a task
// ============================================================================

// POST /pin flips is_pinned to true; GET shows it as pinned.
test "pin_task" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    var cols_doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer cols_doc.deinit();
    const cols = try columnsArray(&cols_doc, "columns for pin");
    const col0 = try objectAt(cols, 0, "columns for pin");
    const col0_id = try gpa.dupe(u8, try strAt(col0, "id", "pin column"));
    defer gpa.free(col0_id);

    const task_body = try addTask(&h, ws_id, kanban_id, "pin-me", col0_id);
    defer gpa.free(task_body);
    const task_id = blk: {
        var task_doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, task_body, .{}) };
        defer task_doc.deinit();
        break :blk try gpa.dupe(u8, try strAt(try rootObj(&task_doc, "pin task"), "id", "pin task"));
    };
    defer gpa.free(task_id);

    {
        const pin_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks/{s}/pin",
            .{ ws_id, kanban_id, task_id },
        );
        defer gpa.free(pin_path);
        var r = try h.http(io, .POST, pin_path, .{
            .json_body = "{\"is_pinned\":true}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        // Response shape varies (the handler returns the new
        // pinned_position): `success` defaults to True when absent, or
        // the body carries `new_pos`.
        const success_default = blk: {
            const v = doc.get("success") orelse break :blk true;
            break :blk switch (v) {
                .bool => |b| b,
                else => false,
            };
        };
        const has_new_pos = doc.get("new_pos") != null;
        if (!success_default and !has_new_pos) {
            std.debug.print("unexpected pin response: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // Verify the task is now pinned (re-fetch and check).
    var tasks_doc = try listTasksDoc(&h, ws_id, kanban_id);
    defer tasks_doc.deinit();
    const tasks = try tasksArray(&tasks_doc, "tasks after pin");
    var pinned: ?std.json.ObjectMap = null;
    for (tasks.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, task_id)) {
            pinned = obj;
            break;
        }
    }
    const pinned_obj = pinned orelse {
        std.debug.print("task '{s}' not found after pin\n", .{task_id});
        return error.TestUnexpectedResult;
    };
    const is_pinned = pinned_obj.get("is_pinned") orelse {
        std.debug.print("pinned task has no is_pinned\n", .{});
        return error.TestUnexpectedResult;
    };
    const flag = switch (is_pinned) {
        .bool => |b| b,
        else => {
            std.debug.print("task should be pinned, got a non-bool is_pinned\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    if (!flag) {
        std.debug.print("task should be pinned, got is_pinned=false\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: copy kanban spec from another kanban
// ============================================================================

// Create kanban-A with 4 columns, kanban-B with 1, copy A's spec
// to B (replace mode), B now has 4 columns matching A.
test "copy_kanban_spec_replaces_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_a = try createKanban(&h, ws_id, "source");
    defer gpa.free(kanban_a);
    const kanban_b = try createKanban(&h, ws_id, "target");
    defer gpa.free(kanban_b);

    // Source: 3 default columns + 1 added = 4.
    {
        const extra = try addColumn(&h, ws_id, kanban_a, "extra-col", null);
        gpa.free(extra);
    }
    var a_doc = try listColumnsDoc(&h, ws_id, kanban_a);
    defer a_doc.deinit();
    const cols_a = try columnsArray(&a_doc, "source columns");
    if (cols_a.items.len != 4) {
        std.debug.print("expected source to have 4 columns, got {d}\n", .{cols_a.items.len});
        return error.TestUnexpectedResult;
    }

    // Target: 3 default columns (no additions).
    {
        var b_doc = try listColumnsDoc(&h, ws_id, kanban_b);
        defer b_doc.deinit();
        const cols_b = try columnsArray(&b_doc, "target columns before copy");
        if (cols_b.items.len != 3) {
            std.debug.print("expected target to have 3 columns, got {d}\n", .{cols_b.items.len});
            return error.TestUnexpectedResult;
        }
    }

    // Copy A -> B (replace mode).
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{ .mode = "replace" }, .{});
        defer gpa.free(body);
        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/copy_spec_from/{s}",
            .{ ws_id, kanban_b, kanban_a },
        );
        defer gpa.free(path);
        var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{200} });
        defer r.deinit();
        // The response shape may vary; just assert success (absent
        // counts as success, exactly like Python's
        // `r.json().get("success", True) is True`).
        var doc = try r.json();
        defer doc.deinit();
        if (!try successOrAbsent(&doc, "copy_spec response")) {
            std.debug.print("copy_spec response success=false: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // B should now have 4 columns matching A.
    var b_after_doc = try listColumnsDoc(&h, ws_id, kanban_b);
    defer b_after_doc.deinit();
    const cols_b_after = try columnsArray(&b_after_doc, "target columns after copy");
    if (cols_b_after.items.len != 4) {
        std.debug.print("expected B to have 4 columns after copy, got {d}\n", .{cols_b_after.items.len});
        return error.TestUnexpectedResult;
    }
    const a_names = try sortedNamesCsv(cols_a);
    defer gpa.free(a_names);
    const b_names = try sortedNamesCsv(cols_b_after);
    defer gpa.free(b_names);
    if (!std.mem.eql(u8, a_names, b_names)) {
        std.debug.print("column names should match: A={s}, B={s}\n", .{ a_names, b_names });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 9: delete kanban item leaves columns as orphans
// ============================================================================

// Delete the kanban item; columns become orphans (no FK CASCADE).
test "delete_kanban_item_orphans_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    // Confirm we have 3 columns before delete.
    {
        var doc = try listColumnsDoc(&h, ws_id, kanban_id);
        defer doc.deinit();
        const cols = try columnsArray(&doc, "columns before item delete");
        if (cols.items.len != 3) {
            std.debug.print("expected 3 columns before delete, got {d}\n", .{cols.items.len});
            return error.TestUnexpectedResult;
        }
    }

    // Delete the item.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}", .{ ws_id, kanban_id });
        defer gpa.free(path);
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (!try successOrAbsent(&doc, "delete item response")) {
            std.debug.print("delete item success=false: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // Columns persist as orphans (current behavior - see header comment).
    var after_doc = try listColumnsDoc(&h, ws_id, kanban_id);
    defer after_doc.deinit();
    const cols_after = try columnsArray(&after_doc, "orphan columns after item delete");
    if (cols_after.items.len != 3) {
        std.debug.print("expected 3 orphan columns, got {d}\n", .{cols_after.items.len});
        return error.TestUnexpectedResult;
    }
}
