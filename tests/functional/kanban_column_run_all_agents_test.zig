// Functional tests for the bulk `run_all_agents` column endpoint. Zig port of
// `tests/functional/kanban_column_run_all_agents_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
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

/// Seed workspace -> kanban -> first column with 3 tasks. Mirrors
/// `_seed_column_with_three_tasks`: returns the workspace, board, column and
/// the three task ids, and asserts the ids are DISTINCT.
fn seedColumnWithThreeTasks(h: *Harness) !Seed {
    const ws_id = try createWorkspace(h, "run-all-ws");
    errdefer gpa.free(ws_id);
    const kanban_id = try createKanban(h, ws_id, "sprint-run-all");
    errdefer gpa.free(kanban_id);
    const col_id = try firstColumnId(h, ws_id, kanban_id);
    errdefer gpa.free(col_id);

    var ids: [3][]u8 = undefined;
    var seeded: usize = 0;
    errdefer for (ids[0..seeded]) |id| gpa.free(id);

    for (0..3) |i| {
        const name = try std.fmt.allocPrint(gpa, "bulk-task-{d}", .{i});
        defer gpa.free(name);
        ids[i] = try createTask(h, ws_id, kanban_id, name, col_id);
        seeded += 1;
    }

    // `len(set(ids)) == 3` — three DISTINCT tasks.
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

/// `POST .../kanban/columns/:col/run_all_agents`. Caller owns the Response.
fn runAllAgents(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    col_id: []const u8,
    expect: []const u16,
) !harness.Response {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/columns/{s}/run_all_agents",
        .{ ws_id, kanban_id, col_id },
    );
    defer gpa.free(path);
    return h.http(io, .POST, path, .{ .json_body = "{}", .expect = expect });
}

/// Assert the three id lists cover EXACTLY `ids` (the Python
/// `union == set(ids)`), printing the body on failure.
fn expectBulkCoversExactly(doc: *const harness.Json, body: []const u8, ids: []const []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for ([_][]const u8{ "started", "skipped", "failed" }) |key| {
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

/// Require `doc["<key>"] is True` (identity against the JSON boolean).
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
// Test 1: start_agent on task-1 first
// ============================================================================

// Precondition for the bulk split: task-1 starts cleanly (-> 200).
test "start_agent_on_task1_first" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    var r = try startAgent(&h, seed.ws_id, seed.kanban_id, seed.ids[0], &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTrue(&doc, "success", r.body);
    const session_id = doc.str("session_id") orelse {
        std.debug.print("start_agent response has no `session_id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(seed.ids[0], session_id);
    const status = doc.str("status") orelse {
        std.debug.print("start_agent response has no `status`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("triggered", status);
}

// ============================================================================
// Test 2: bulk run covers all three with a started/skipped split
// ============================================================================

// POST run_all_agents -> 200 with started/skipped/failed covering all 3.
// task-1 already owns a worker (started above), so it must land in `skipped`
// while the worker is in-flight.
test "run_all_agents_started_skipped_split" {
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

    var r = try runAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectTrue(&doc, "success", r.body);
    const column_id = doc.str("column_id") orelse {
        std.debug.print("bulk response has no `column_id`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(seed.col_id, column_id);
    for ([_][]const u8{ "started", "skipped", "failed" }) |key| {
        if (doc.array(key) == null) {
            std.debug.print("expected list for `{s}`: {s}\n", .{ key, r.body });
            return error.TestUnexpectedResult;
        }
    }

    try expectBulkCoversExactly(&doc, r.body, seed.idSlice());

    // task-1 is covered by the started/skipped split (never silently
    // dropped into `failed` alone — the union check above is the hard
    // gate; this pins the split explicitly).
    if (!try listHas(&doc, "skipped", seed.ids[0]) and
        !try listHas(&doc, "started", seed.ids[0]))
    {
        std.debug.print(
            "task-1 {s} must be in skipped (worker in-flight) or started (worker drained): {s}\n",
            .{ seed.ids[0], r.body },
        );
        return error.TestUnexpectedResult;
    }

    // The two idle tasks should have been started (at least one of them —
    // the other may be skipped if the first bulk call raced a worker write).
    const started_len = (doc.array("started") orelse return error.TestUnexpectedResult).items.len;
    if (started_len < 1) {
        std.debug.print("expected >=1 started, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: re-POST is safe
// ============================================================================

// Second POST -> still 200 with the same 3-id coverage (no 409/500).
test "run_all_agents_repost_safe" {
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
        var first = try runAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
        defer first.deinit();
        var first_doc = try first.json();
        defer first_doc.deinit();
        try expectTrue(&first_doc, "success", first.body);
    }

    var second = try runAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
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

// POST run_all_agents on a bogus column -> 404 `column not found`.
test "run_all_agents_unknown_column_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    var r = try runAllAgents(&h, seed.ws_id, seed.kanban_id, "col_does_not_exist", &.{404});
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
// Test 5: single-task GET unshadowed
// ============================================================================

// GET .../tasks/:task_id still returns the single task (not the list).
test "single_task_get_unshadowed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

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

    {
        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks",
            .{ seed.ws_id, seed.kanban_id },
        );
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{
            .params = &.{.{ .name = "limit", .value = "100" }},
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        // Python: `listed.get("tasks", listed if isinstance(listed, list) else [])`.
        const tasks = doc.array("tasks") orelse switch (doc.value().*) {
            .array => |a| a,
            else => {
                std.debug.print("list response carries neither `tasks` nor a bare array: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };

        var found: usize = 0;
        for (tasks.items) |row| {
            const obj = switch (row) {
                .object => |o| o,
                else => continue,
            };
            const id = switch (obj.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            for (seed.ids) |want| {
                if (std.mem.eql(u8, want, id)) found += 1;
            }
        }
        if (found != seed.ids.len) {
            std.debug.print(
                "list must contain all {d} seeded tasks, found {d}: {s}\n",
                .{ seed.ids.len, found, r.body },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 6: run_all_agents never corrupts selected_profile_model wire shape
// ============================================================================

// After `run_all_agents`, `GET /api/llm/session/:id` (and
// `.../messages?limit=1`) must carry `selected_profile_model` as a JSON
// string (or null/absent) — never a byte array like `[170, 170, ...]`.
test "run_all_agents_preserves_profile_string_wire" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var seed = try seedColumnWithThreeTasks(&h);
    defer seed.deinit();

    // Positive control: pin a profile on task-0's session row.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{seed.ids[0]});
        defer gpa.free(path);
        var r = try h.http(io, .PUT, path, .{
            .json_body = "{\"selected_profile_model\":\"900ribu\"}",
            .expect = &.{200},
        });
        defer r.deinit();
    }

    {
        var r = try runAllAgents(&h, seed.ws_id, seed.kanban_id, seed.col_id, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        try expectTrue(&doc, "success", r.body);
    }

    // Poll the detail endpoint: workers persist asynchronously, so the
    // corruption (if present) lands after the POST returns.
    var saw_pinned: bool = false;
    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() + 10_000;
    while (true) {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{seed.ids[0]});
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{ 200, 404 } });
        defer r.deinit();
        if (r.status == 200) {
            var doc = try r.json();
            defer doc.deinit();
            if (doc.get("selected_profile_model")) |v| {
                switch (v) {
                    .string => |s| {
                        if (std.mem.eql(u8, s, "900ribu")) saw_pinned = true;
                    },
                    .null => {},
                    else => {
                        std.debug.print(
                            "selected_profile_model must be string-or-null, got {s}: {s}\n",
                            .{ @tagName(v), r.body },
                        );
                        return error.TestUnexpectedResult;
                    },
                }
            }
            // Raw-body guard: the poisoned wire shape is a JSON array.
            if (std.mem.indexOf(u8, r.body, "\"selected_profile_model\":[") != null) {
                std.debug.print("wire carries byte-array profile: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            }
        }
        if (saw_pinned) break;
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= deadline) break;
        std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
    }
    if (!saw_pinned) {
        std.debug.print("pinned profile 900ribu never observed on task-0 detail\n", .{});
        return error.TestUnexpectedResult;
    }

    // Messages endpoint for task-0: same type contract.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{seed.ids[0]});
        defer gpa.free(path);
        const params = [1]Harness.Param{.{ .name = "limit", .value = "1" }};
        var r = try h.http(io, .GET, path, .{ .params = &params, .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.get("selected_profile_model")) |v| {
            switch (v) {
                .string => {},
                .null => {},
                else => {
                    std.debug.print(
                        "messages selected_profile_model must be string-or-null, got {s}: {s}\n",
                        .{ @tagName(v), r.body },
                    );
                    return error.TestUnexpectedResult;
                },
            }
        }
        if (std.mem.indexOf(u8, r.body, "\"selected_profile_model\":[") != null) {
            std.debug.print("messages wire carries byte-array profile: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // Sibling tasks (no profile pinned): still never an array.
    for (seed.ids[1..]) |tid| {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{tid});
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{ 200, 404 } });
        defer r.deinit();
        if (r.status == 200) {
            var doc = try r.json();
            defer doc.deinit();
            if (doc.get("selected_profile_model")) |v| {
                switch (v) {
                    .string => {},
                    .null => {},
                    else => {
                        std.debug.print(
                            "sibling {s} profile must be string-or-null, got {s}: {s}\n",
                            .{ tid, @tagName(v), r.body },
                        );
                        return error.TestUnexpectedResult;
                    },
                }
            }
            if (std.mem.indexOf(u8, r.body, "\"selected_profile_model\":[") != null) {
                std.debug.print("sibling {s} wire carries byte-array profile: {s}\n", .{ tid, r.body });
                return error.TestUnexpectedResult;
            }
        }
    }
}
