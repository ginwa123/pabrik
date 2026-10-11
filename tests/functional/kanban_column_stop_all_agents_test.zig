//
// Functional tests for the bulk `stop_all_agents` column endpoint.
//
// Mirror of `kanban_column_run_all_agents_test.zig` with the direction
// flipped: run-all starts idle workers, stop-all cancels running ones.
//
// Wire under test:
//   POST /api/workspaces/:ws/items/:item/kanban/columns/:col/stop_all_agents
//     -> 200 {"success":true,"column_id":...,"stopped":[...],"skipped":[...],"failed":[...]}
//     -> 404 {"error":"column not found"} for unknown columns.
//
// The tests replay the exact frontend flow against a real binary
// (fresh binary, isolated tmpdir HOME, harness auto-picks a port != 8081):
//
//   1. seed workspace -> kanban item -> first column with 3 tasks.
//   2. start_agent on task-1 first (-> 200 triggered, so task-1 owns a worker).
//   3. POST stop_all_agents -> 200 with a stopped/skipped split covering all 3
//      (task-1 lands in `stopped` while its worker is in-flight; if the worker
//      already drained it may land in `skipped` — either way it must be
//      covered by the union of the three lists).
//   4. re-POST stop_all_agents -> still 200 (safe / idempotent envelope;
//      second time every worker is already cancelled, so all 3 land in
//      `stopped` or `skipped` — the union gate is the hard assertion).
//   5. unknown column -> 404.
//   6. GET .../tasks/:task_id single route still works (route-order guard:
//      the new POST literal was registered in the columns family, never under
//      /tasks/:task_id, so neither the single GET nor the list GET is shadowed).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers (mirrors kanban_column_run_all_agents_test.zig)
// ============================================================================

/// The seeded workspace / board / column / three task ids.
const Seed = struct {
    ws_id: []u8,
    kanban_id: []u8,
    col_id: []u8,
    /// Exactly three, in creation order — `ids[0]` is "task-1".
    ids: [3][]u8,

    fn deinit(self: *Seed) void {
        gpa.free(self.ws_id);
        gpa.free(self.kanban_id);
        gpa.free(self.col_id);
        for (self.ids) |id| gpa.free(id);
        self.* = undefined;
    }

    fn idSlice(self: *const Seed) []const []const u8 {
        return self.ids[0..];
    }
};

/// `POST /api/workspaces` → the new workspace's id. Caller frees.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("workspace create response has no string `id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

/// `POST /api/workspaces/{ws}/items/kanban` → the new board's id.
/// Caller frees.
fn createKanban(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name});
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(path);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create response has no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, switch (item.get("id") orelse {
        std.debug.print("kanban create response has no item.id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create item.id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    });
}

/// `GET .../kanban/columns` → the FIRST seeded column's id. Caller frees.
fn firstColumnId(h: *Harness, ws_id: []const u8, kanban_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const cols = doc.array("columns") orelse {
        std.debug.print("columns response has no `columns` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (cols.items.len < 1) {
        std.debug.print("expected seeded columns, got none: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, switch (cols.items[0]) {
        .object => |o| switch (o.get("id") orelse {
            std.debug.print("first column has no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("first column id is not a string: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        },
        else => {
            std.debug.print("first column entry is not an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    });
}

/// `POST .../tasks` → the new task's id. Caller frees.
fn createTask(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    column_id: []const u8,
) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"name\":\"{s}\",\"column_id\":\"{s}\"}}",
        .{ name, column_id },
    );
    defer gpa.free(body);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);
    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("task create response has no string `id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.startsWith(u8, id, "task_")) {
        std.debug.print("unexpected task shape (id \"{s}\"): {s}\n", .{ id, r.body });
        return error.TestUnexpectedResult;
    }
    return gpa.dupe(u8, id);
}

/// Seed workspace -> kanban -> first column with 3 tasks.
fn seedColumnWithThreeTasks(h: *Harness) !Seed {
    const ws_id = try createWorkspace(h, "stop-all-ws");
    errdefer gpa.free(ws_id);
    const kanban_id = try createKanban(h, ws_id, "sprint-stop-all");
    errdefer gpa.free(kanban_id);
    const col_id = try firstColumnId(h, ws_id, kanban_id);
    errdefer gpa.free(col_id);

    var ids: [3][]u8 = undefined;
    var seeded: usize = 0;
    errdefer for (ids[0..seeded]) |id| gpa.free(id);

    for (0..3) |i| {
        const name = try std.fmt.allocPrint(gpa, "bulk-stop-task-{d}", .{i});
        defer gpa.free(name);
        ids[i] = try createTask(h, ws_id, kanban_id, name, col_id);
        seeded += 1;
    }

    for (0..3) |i| {
        for (i + 1..3) |j| {
            if (std.mem.eql(u8, ids[i], ids[j])) {
                std.debug.print("expected 3 distinct tasks, got \"{s}\" twice\n", .{ids[i]});
                return error.TestUnexpectedResult;
            }
        }
    }

    return .{ .ws_id = ws_id, .kanban_id = kanban_id, .col_id = col_id, .ids = ids };
}

/// `POST .../tasks/:task_id/start_agent`. Caller owns the Response.
fn startAgent(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    task_id: []const u8,
    expect: []const u16,
) !harness.Response {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/start_agent",
        .{ ws_id, kanban_id, task_id },
    );
    defer gpa.free(path);
    return h.http(io, .POST, path, .{ .json_body = "{}", .expect = expect });
}

/// `POST .../kanban/columns/:col/stop_all_agents`. Caller owns the Response.
fn stopAllAgents(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    col_id: []const u8,
    expect: []const u16,
) !harness.Response {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}/stop_all_agents",
        .{ ws_id, kanban_id, col_id },
    );
    defer gpa.free(path);
    return h.http(io, .POST, path, .{ .json_body = "{}", .expect = expect });
}

/// Assert the three id lists cover EXACTLY `ids`.
fn expectBulkCoversExactly(doc: *const harness.Json, body: []const u8, ids: []const []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for ([_][]const u8{ "stopped", "skipped", "failed" }) |key| {
        const arr = doc.array(key) orelse {
            std.debug.print("expected list for `{s}`, got: {s}\n", .{ key, body });
            return error.TestUnexpectedResult;
        };
        for (arr.items) |v| switch (v) {
            .string => |s| try seen.put(gpa, s, {}),
            else => {
                std.debug.print("`{s}` carries a non-string id: {s}\n", .{ key, body });
                return error.TestUnexpectedResult;
            },
        };
    }
    if (seen.count() != ids.len) {
        std.debug.print("bulk must cover all {d} tasks, got {d} distinct ids: {s}\n", .{
            ids.len, seen.count(), body,
        });
        return error.TestUnexpectedResult;
    }
    for (ids) |id| {
        if (!seen.contains(id)) {
            std.debug.print("bulk missed task {s}: {s}\n", .{ id, body });
            return error.TestUnexpectedResult;
        }
    }
}

/// Is `id` in the array at `key`?
fn listHas(doc: *const harness.Json, key: []const u8, id: []const u8) !bool {
    const arr = doc.array(key) orelse {
        std.debug.print("expected list for `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    for (arr.items) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, id)) return true;
        },
        else => {},
    };
    return false;
}

/// Require `doc["<key>"] is True`.
fn expectTrue(doc: *const harness.Json, key: []const u8, body: []const u8) !void {
    const v = doc.boolean(key) orelse {
        std.debug.print("expected boolean `{s}`: {s}\n", .{ key, body });
        return error.TestUnexpectedResult;
    };
    if (!v) {
        std.debug.print("expected `{s}` to be true: {s}\n", .{ key, body });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 1: stop on an idle column covers all three as skipped
// ============================================================================

test "stop_all_agents_idle_column_all_skipped" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    // No worker started anywhere: every task must land in `skipped`
    // (idle, no worker row) — the positive control that the skipped
    // branch is reachable on the wire, not just in unit tests.
    var r = try stopAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTrue(&doc, "success", r.body);
    const column_id = doc.str("column_id") orelse {
        std.debug.print("bulk response has no `column_id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(seed.col_id, column_id);
    try expectBulkCoversExactly(&doc, r.body, seed.idSlice());

    const skipped = doc.array("skipped") orelse return error.TestUnexpectedResult;
    if (skipped.items.len != 3) {
        std.debug.print("idle column must skip all 3, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: bulk stop covers all three with a stopped/skipped split
// ============================================================================

test "stop_all_agents_stopped_skipped_split" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    {
        var started = try startAgent(&h, seed.ws_id, seed.kanban_id, seed.ids[0], &.{200});
        defer started.deinit();
    }

    var r = try stopAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTrue(&doc, "success", r.body);
    const column_id = doc.str("column_id") orelse {
        std.debug.print("bulk response has no `column_id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(seed.col_id, column_id);
    for ([_][]const u8{ "stopped", "skipped", "failed" }) |key| {
        if (doc.array(key) == null) {
            std.debug.print("expected list for `{s}`: {s}\n", .{ key, r.body });
            return error.TestUnexpectedResult;
        }
    }

    try expectBulkCoversExactly(&doc, r.body, seed.idSlice());

    // task-1 owned a worker: it must be in `stopped` (worker in-flight)
    // or `skipped` (worker already drained) — never silently dropped.
    if (!try listHas(&doc, "stopped", seed.ids[0]) and
        !try listHas(&doc, "skipped", seed.ids[0]))
    {
        std.debug.print(
            "task-1 {s} must be in stopped (worker in-flight) or skipped (worker drained): {s}\n",
            .{ seed.ids[0], r.body },
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: re-POST is safe
// ============================================================================

test "stop_all_agents_repost_safe" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    {
        var started = try startAgent(&h, seed.ws_id, seed.kanban_id, seed.ids[0], &.{200});
        defer started.deinit();
    }
    {
        var first = try stopAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
        defer first.deinit();
        var first_doc = try first.json();
        defer first_doc.deinit();
        try expectTrue(&first_doc, "success", first.body);
    }

    var second = try stopAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
    defer second.deinit();
    var doc = try second.json();
    defer doc.deinit();

    try expectTrue(&doc, "success", second.body);
    const column_id = doc.str("column_id") orelse {
        std.debug.print("bulk response has no `column_id`: {s}\n", .{second.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(seed.col_id, column_id);
    try expectBulkCoversExactly(&doc, second.body, seed.idSlice());
}

// ============================================================================
// Test 4: unknown column -> 404
// ============================================================================

test "stop_all_agents_unknown_column_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    var r = try stopAllAgents(&h, seed.ws_id, seed.kanban_id, "col_does_not_exist", &.{404});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("404 body has no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.ascii.indexOfIgnoreCase(message, "column not found") == null) {
        std.debug.print("expected \"column not found\", got: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: single-task GET unshadowed + run_all still resolves
// ============================================================================

test "stop_all_agents_single_task_get_unshadowed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    // The single-task GET must still return the task envelope (the new
    // POST literal lives in the columns family, never under /tasks/:id).
    {
        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks/{s}",
            .{ seed.ws_id, seed.kanban_id, seed.ids[0] },
        );
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const task = doc.object("task") orelse {
            std.debug.print("expected task envelope, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const id = switch (task.get("id") orelse {
            std.debug.print("task envelope has no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("task envelope id is not a string: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expectEqualStrings(seed.ids[0], id);
    }

    // The sibling run_all_agents literal must still resolve (the two
    // column bulk routes coexist — neither shadows the other).
    {
        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/columns/{s}/run_all_agents",
            .{ seed.ws_id, seed.kanban_id, seed.col_id },
        );
        defer gpa.free(path);
        var r = try h.http(io, .POST, path, .{ .json_body = "{}", .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectTrue(&doc, "success", r.body);
    }
}
