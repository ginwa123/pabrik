// Functional tests for kanban advanced (Tier 1.3). Zig port of
// `tests/functional/kanban_advanced_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

fn boot() !Harness {
    return Harness.boot(io, gpa, .{});
}

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

/// Create a kanban and return the ITEM id (owned). The response envelope is
/// `{item, columns}`; the id is unwrapped from `item` here.
fn createKanban(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":{f}}}", .{std.json.fmt(name, .{})});
    defer gpa.free(body);
    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("missing `item` envelope in kanban-create response\n", .{});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            std.debug.print("created item has no string `id`\n", .{});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// One kanban column, copied out of a response so it outlives the body.
const Column = struct {
    id: []u8,
    name: []u8,

    fn deinit(self: *Column) void {
        gpa.free(self.id);
        gpa.free(self.name);
        self.* = undefined;
    }
};

fn freeColumns(cols: []Column) void {
    for (cols) |*c| c.deinit();
    gpa.free(cols);
}

fn objectId(v: std.json.Value) ?[]const u8 {
    const o = switch (v) {
        .object => |oo| oo,
        else => return null,
    };
    return switch (o.get("id") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
}

fn objectName(v: std.json.Value) ?[]const u8 {
    const o = switch (v) {
        .object => |oo| oo,
        else => return null,
    };
    return switch (o.get("name") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
}

/// Copy the `columns` array of a response into owned `Column`s, in wire
/// order (position order IS the contract several tests below assert).
fn columnsFrom(doc: *const harness.Json) ![]Column {
    const arr = doc.array("columns") orelse {
        std.debug.print("response has no `columns` array\n", .{});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList(Column) = .empty;
    errdefer {
        for (out.items) |*c| c.deinit();
        out.deinit(gpa);
    }
    for (arr.items) |item| {
        const id = objectId(item) orelse {
            std.debug.print("column entry has no string `id`\n", .{});
            return error.TestUnexpectedResult;
        };
        const name = objectName(item) orelse "";
        try out.append(gpa, .{ .id = try gpa.dupe(u8, id), .name = try gpa.dupe(u8, name) });
    }
    return out.toOwnedSlice(gpa);
}

/// `GET .../kanban/columns` → the board's columns (owned, in order).
fn listColumns(h: *Harness, ws_id: []const u8, kanban_id: []const u8) ![]Column {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);
    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return columnsFrom(&doc);
}

/// `POST .../kanban/columns` → the new column (owned). `position` null omits
/// the key, so the backend appends at `MAX(position) + 1`.
fn addColumn(h: *Harness, ws_id: []const u8, kanban_id: []const u8, name: []const u8, position: ?i64) !Column {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    if (position) |p| try body.writer.print(",\"position\":{d}", .{p});
    try body.writer.writeAll("}");
    const payload = try body.toOwnedSlice();
    defer gpa.free(payload);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = payload, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("column-create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    };
    return .{ .id = try gpa.dupe(u8, id), .name = try gpa.dupe(u8, doc.str("name") orelse "") };
}

/// `POST .../tasks` → the new task id (owned). `tags` is a JSON STRING
/// carrying a JSON array (`'["bug"]'`), which is why it goes through
/// `encodeJsonString` rather than being interpolated.
fn addTask(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    column_id: ?[]const u8,
    tags: ?[]const u8,
) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, &body.writer);
    if (column_id) |c| {
        try body.writer.writeAll(",\"column_id\":");
        try std.json.Stringify.encodeJsonString(c, .{}, &body.writer);
    }
    if (tags) |t| {
        try body.writer.writeAll(",\"tags\":");
        try std.json.Stringify.encodeJsonString(t, .{}, &body.writer);
    }
    try body.writer.writeAll("}");
    const payload = try body.toOwnedSlice();
    defer gpa.free(payload);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/tasks", .{ ws_id, kanban_id });
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = payload, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("task-create response has no `id`\n", .{});
        return error.TestUnexpectedResult;
    });
}

fn findColumn(cols: []const Column, id: []const u8) ?usize {
    for (cols, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, id)) return i;
    }
    return null;
}

fn countName(cols: []const Column, name: []const u8) usize {
    var n: usize = 0;
    for (cols) |c| {
        if (std.mem.eql(u8, c.name, name)) n += 1;
    }
    return n;
}

/// The `error` string of an error response, or an error.
fn errorMessage(doc: *const harness.Json) ![]const u8 {
    return doc.str("error") orelse {
        std.debug.print("error response has no `error` key\n", .{});
        return error.TestUnexpectedResult;
    };
}

/// Does `haystack` contain `needle`, case-insensitively?
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ============================================================================
// Test 1: PATCH column renames it
// ============================================================================

// PATCH /columns/:col_id {name: 'new'} → the board envelope `{columns,
// count}` comes back so the frontend can re-render without a GET.
test "patch_column_renames_it" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint1");
    defer gpa.free(kanban_id);

    const cols = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols);
    if (cols.len == 0) {
        std.debug.print("a fresh kanban has no columns\n", .{});
        return error.TestUnexpectedResult;
    }
    const target_id = cols[0].id;

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
        .{ ws_id, kanban_id, target_id },
    );
    defer gpa.free(url);
    {
        var r = try h.http(io, .PATCH, url, .{
            .json_body = "{\"name\":\"renamed-col\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("columns") == null or doc.get("count") == null) {
            std.debug.print("PATCH response envelope missing `columns` or `count`\n", .{});
            return error.TestUnexpectedResult;
        }
        const count = doc.int("count") orelse {
            std.debug.print("PATCH response `count` is not an integer\n", .{});
            return error.TestUnexpectedResult;
        };
        if (count != @as(i64, @intCast(cols.len))) {
            std.debug.print("PATCH count={d}, expected {d}\n", .{ count, cols.len });
            return error.TestUnexpectedResult;
        }
    }

    // Re-list and verify the rename is persisted.
    const cols_after = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols_after);
    const idx = findColumn(cols_after, target_id) orelse {
        std.debug.print("column {s} vanished after rename\n", .{target_id});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, cols_after[idx].name, "renamed-col")) {
        std.debug.print("rename didn't persist; got \"{s}\"\n", .{cols_after[idx].name});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: PATCH column with empty body returns 400
// ============================================================================

// PATCH /columns/:col_id {} → 400. `kanban_columns_update.zig` returns
// `error.NothingToUpdate` when all three fields are absent and the
// handler maps that to 400.
test "patch_column_rejects_empty_body" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint2");
    defer gpa.free(kanban_id);

    const cols = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols);
    if (cols.len == 0) {
        std.debug.print("a fresh kanban has no columns\n", .{});
        return error.TestUnexpectedResult;
    }

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
        .{ ws_id, kanban_id, cols[0].id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = "{}", .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const msg = try errorMessage(&doc);
    if (!containsIgnoreCase(msg, "at least one") and !containsIgnoreCase(msg, "required")) {
        std.debug.print("400 message should mention `at least one` / `required`; got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: PATCH column with {position: N} reorders within the board
// ============================================================================

// PATCH /columns/:col_id {position: 0} moves the column to the top.
test "patch_column_reorders_within_board" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint3");
    defer gpa.free(kanban_id);

    var extra = try addColumn(&h, ws_id, kanban_id, "movable", null);
    defer extra.deinit();

    const cols_before = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols_before);
    if (!std.mem.eql(u8, cols_before[cols_before.len - 1].id, extra.id)) {
        std.debug.print("new column should be at the end; last is \"{s}\", wanted \"{s}\"\n", .{
            cols_before[cols_before.len - 1].id, extra.id,
        });
        return error.TestUnexpectedResult;
    }

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
        .{ ws_id, kanban_id, extra.id },
    );
    defer gpa.free(url);
    {
        var r = try h.http(io, .PATCH, url, .{
            .json_body = "{\"position\":0}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const count = doc.int("count") orelse {
            std.debug.print("PATCH response `count` is not an integer\n", .{});
            return error.TestUnexpectedResult;
        };
        if (count != @as(i64, @intCast(cols_before.len))) {
            std.debug.print("PATCH count={d}, expected {d}\n", .{ count, cols_before.len });
            return error.TestUnexpectedResult;
        }
    }

    // Re-list: the extra column is now first.
    const cols_after = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols_after);
    if (!std.mem.eql(u8, cols_after[0].id, extra.id)) {
        std.debug.print("position=0 didn't move the column to the top; first is \"{s}\"\n", .{cols_after[0].id});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 4: DELETE column with tasks still assigned returns 409
// ============================================================================

// DELETE /columns/:col_id with 1+ tasks assigned → 409, and the message
// names the task count.
test "delete_column_with_tasks_returns_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint4");
    defer gpa.free(kanban_id);

    const cols = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols);
    if (cols.len == 0) {
        std.debug.print("a fresh kanban has no columns\n", .{});
        return error.TestUnexpectedResult;
    }
    const target_id = try gpa.dupe(u8, cols[0].id);
    defer gpa.free(target_id);

    // Create 2 tasks under the target column.
    {
        const t = try addTask(&h, ws_id, kanban_id, "stuck-1", target_id, null);
        defer gpa.free(t);
    }
    {
        const t = try addTask(&h, ws_id, kanban_id, "stuck-2", target_id, null);
        defer gpa.free(t);
    }

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
        .{ ws_id, kanban_id, target_id },
    );
    defer gpa.free(url);

    {
        var r = try h.http(io, .DELETE, url, .{ .expect = &.{409} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const msg = try errorMessage(&doc);
        if (std.mem.indexOf(u8, msg, "Cannot delete column") == null) {
            std.debug.print("409 message should start with 'Cannot delete column', got \"{s}\"\n", .{msg});
            return error.TestUnexpectedResult;
        }
        if (std.mem.indexOf(u8, msg, "2 task") == null) {
            std.debug.print("409 message should mention the task count (2), got \"{s}\"\n", .{msg});
            return error.TestUnexpectedResult;
        }
    }

    // The column is still in the list (the 409 prevented the delete).
    const cols_after = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols_after);
    if (findColumn(cols_after, target_id) == null) {
        std.debug.print("column {s} should still exist after the 409\n", .{target_id});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: DELETE column succeeds when empty
// ============================================================================

// DELETE /columns/:col_id on an EMPTY column → 200 {success, column_id}. This
// complements `test_delete_column_orphans_tasks` (in
// kanban_lifecycle_test.py) by pinning the SUCCESS path.
test "delete_empty_column_succeeds" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint5");
    defer gpa.free(kanban_id);

    var empty = try addColumn(&h, ws_id, kanban_id, "empty", null);
    defer empty.deinit();

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}",
        .{ ws_id, kanban_id, empty.id },
    );
    defer gpa.free(url);
    {
        var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const success = doc.boolean("success") orelse {
            std.debug.print("delete response has no boolean `success`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (!success) {
            std.debug.print("expected success=true on the delete response\n", .{});
            return error.TestUnexpectedResult;
        }
        const column_id = doc.str("column_id") orelse "";
        if (!std.mem.eql(u8, column_id, empty.id)) {
            std.debug.print("delete response column_id=\"{s}\", expected \"{s}\"\n", .{ column_id, empty.id });
            return error.TestUnexpectedResult;
        }
    }

    // The column is gone from the list.
    const cols_after = try listColumns(&h, ws_id, kanban_id);
    defer freeColumns(cols_after);
    if (findColumn(cols_after, empty.id) != null) {
        std.debug.print("column {s} still present after a successful delete\n", .{empty.id});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 6: GET /kanban/tags returns empty for a fresh kanban
// ============================================================================

// A freshly-created kanban has no tasks → /tags returns an empty list
// and `has_more: false`.
test "kanban_tags_list_empty_for_no_tasks" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "tagless");
    defer gpa.free(kanban_id);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tags",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tags = doc.array("tags") orelse {
        std.debug.print("tags response has no `tags` array\n", .{});
        return error.TestUnexpectedResult;
    };
    if (tags.items.len != 0) {
        std.debug.print("empty kanban should have no tags, got {d}\n", .{tags.items.len});
        return error.TestUnexpectedResult;
    }
    const has_more = doc.boolean("has_more") orelse {
        std.debug.print("tags response has no boolean `has_more`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (has_more) {
        std.debug.print("empty kanban should have has_more=false\n", .{});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: GET /kanban/tags returns the distinct tag set
// ============================================================================

// 6 tasks across 3 tags → /tags returns 3 unique tags (not 6), and the
// per-tag `count` reflects usage.
test "kanban_tags_list_returns_distinct_tag_set" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "tagful");
    defer gpa.free(kanban_id);

    // 6 tasks: 2 with ["bug"], 2 with ["urgent"], 2 with ["wip"].
    const TagCase = struct { prefix: []const u8, tags: []const u8 };
    const cases = [_]TagCase{
        .{ .prefix = "bug-", .tags = "[\"bug\"]" },
        .{ .prefix = "urgent-", .tags = "[\"urgent\"]" },
        .{ .prefix = "wip-", .tags = "[\"wip\"]" },
    };
    for (cases) |c| {
        for (0..2) |i| {
            const name = try std.fmt.allocPrint(gpa, "{s}{d}", .{ c.prefix, i });
            defer gpa.free(name);
            const t = try addTask(&h, ws_id, kanban_id, name, null, c.tags);
            defer gpa.free(t);
        }
    }

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tags",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{
        // Percent-encoded by the harness; never pre-encoded here.
        .params = &.{.{ .name = "limit", .value = "50" }},
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tags = doc.array("tags") orelse {
        std.debug.print("tags response has no `tags` array\n", .{});
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{ "bug", "urgent", "wip" }) |want| {
        var found = false;
        for (tags.items) |item| {
            const n = objectName(item) orelse continue;
            if (std.mem.eql(u8, n, want)) found = true;
        }
        if (!found) {
            std.debug.print("expected `{s}` in the distinct tag set\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
    if (tags.items.len != 3) {
        std.debug.print("expected 3 distinct tags, got {d}\n", .{tags.items.len});
        return error.TestUnexpectedResult;
    }

    // Each suggestion carries a `count`; the tag used twice has
    // count >= 2 (the "did the join even fire" case).
    for (tags.items) |item| {
        const n = objectName(item) orelse continue;
        if (!std.mem.eql(u8, n, "bug")) continue;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const count = switch (obj.get("count") orelse std.json.Value{ .null = {} }) {
            .integer => |v| v,
            else => {
                std.debug.print("`bug` suggestion has no integer `count`\n", .{});
                return error.TestUnexpectedResult;
            },
        };
        if (count < 2) {
            std.debug.print("`bug` should have count>=2, got {d}\n", .{count});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 8: copy_spec_from merge (append) mode keeps existing columns
// ============================================================================

// POST /copy_spec_from/:source with {mode: 'append'} preserves the
// target's existing columns AND appends the source's — 3 + 3 = 6, with
// each source name now appearing twice.
test "copy_spec_from_append_keeps_existing_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const src = try createKanban(&h, ws_id, "source");
    defer gpa.free(src);
    const tgt = try createKanban(&h, ws_id, "target");
    defer gpa.free(tgt);

    const src_cols_before = try listColumns(&h, ws_id, src);
    defer freeColumns(src_cols_before);
    if (src_cols_before.len != 3) {
        std.debug.print("expected 3 default columns on the source, got {d}\n", .{src_cols_before.len});
        return error.TestUnexpectedResult;
    }

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/copy_spec_from/{s}",
        .{ ws_id, tgt, src },
    );
    defer gpa.free(url);
    {
        var r = try h.http(io, .POST, url, .{
            .json_body = "{\"mode\":\"append\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const count = doc.int("count") orelse {
            std.debug.print("copy_spec response has no integer `count`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (count != 6) {
            std.debug.print("expected 6 columns after append (3 + 3), got {d}\n", .{count});
            return error.TestUnexpectedResult;
        }
    }

    // The names match: each of the 3 source column names appears twice.
    const tgt_cols_after = try listColumns(&h, ws_id, tgt);
    defer freeColumns(tgt_cols_after);
    if (tgt_cols_after.len != 6) {
        std.debug.print("expected 6 target columns, got {d}\n", .{tgt_cols_after.len});
        return error.TestUnexpectedResult;
    }
    for (src_cols_before) |src_col| {
        const n = countName(tgt_cols_after, src_col.name);
        if (n != 2) {
            std.debug.print("expected \"{s}\" to appear twice after append, got {d}\n", .{ src_col.name, n });
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 9: copy_spec_from 404 when the source does not exist
// ============================================================================

// POST /copy_spec_from/item_nope → 404.
test "copy_spec_from_404_for_nonexistent_source" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const tgt = try createKanban(&h, ws_id, "target-no-source");
    defer gpa.free(tgt);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/copy_spec_from/item_nope",
        .{ ws_id, tgt },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{
        .json_body = "{\"mode\":\"replace\"}",
        .expect = &.{404},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const msg = try errorMessage(&doc);
    if (!containsIgnoreCase(msg, "not found") and !containsIgnoreCase(msg, "kanban")) {
        std.debug.print("404 message should mention `not found` / `kanban`; got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 10: copy_spec_from rejects a self-copy
// ============================================================================

// POST /copy_spec_from/<self> → 400. `kanban_copy_spec.zig` treats
// `item_id == source_item_id` as a self-copy and returns
// `error.SourceItemIdRequired`.
test "copy_spec_from_rejects_self_copy" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const kanban = try createKanban(&h, ws_id, "self-copy-attempt");
    defer gpa.free(kanban);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/copy_spec_from/{s}",
        .{ ws_id, kanban, kanban },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{
        .json_body = "{\"mode\":\"replace\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const msg = try errorMessage(&doc);
    if (!containsIgnoreCase(msg, "differ") and !containsIgnoreCase(msg, "source")) {
        std.debug.print("400 message should mention `differ` / `source`; got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 11: copy_spec_from rejects an invalid mode
// ============================================================================

// POST /copy_spec_from/:source with {mode: 'garbage'} → 400.
test "copy_spec_from_rejects_invalid_mode" {
    try harness.requirePabrikBin(io, gpa);
    var h = try boot();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-adv-ws");
    defer gpa.free(ws_id);
    const src = try createKanban(&h, ws_id, "source-bad-mode");
    defer gpa.free(src);
    const tgt = try createKanban(&h, ws_id, "target-bad-mode");
    defer gpa.free(tgt);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/copy_spec_from/{s}",
        .{ ws_id, tgt, src },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{
        .json_body = "{\"mode\":\"garbage\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const msg = try errorMessage(&doc);
    if (!containsIgnoreCase(msg, "mode")) {
        std.debug.print("400 message should mention `mode`; got \"{s}\"\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = boot;
    _ = createWorkspace;
    _ = createKanban;
    _ = columnsFrom;
    _ = listColumns;
    _ = addColumn;
    _ = addTask;
    _ = findColumn;
    _ = countName;
    _ = errorMessage;
    _ = containsIgnoreCase;
    _ = objectId;
    _ = objectName;
    _ = Column.deinit;
    _ = freeColumns;
    _ = Harness.boot;
}
