// Functional tests for the single-task GET endpoint. Zig port of
// `tests/functional/kanban_task_get_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers (mirror the Python module-level functions)
// ============================================================================

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = body,
        .expect = &.{201},
    });
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

/// `POST /api/workspaces/<ws>/items/<kanban>/kanban/tasks` with
/// `mode: "create_session"` — mirrors the frontend's "Create task"
/// button (no agent run) → the new task's id. Owned.
fn createTask(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = "desc",
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `r.json()["task"]["id"]`.
    const task = doc.object("task") orelse {
        std.debug.print("task create returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("task create returned a task with no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task create id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// The `error` field of a task GET response, owned. Python's
/// `body.get("error", "")` — an absent key reads as the empty string.
fn getTaskError(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    task_id: []const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ workspace_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const msg = doc.str("error") orelse "";
    return gpa.dupe(u8, msg);
}

/// The single-task GET body, parsed in the CALLER's scope. Returns owned
/// bytes — the caller parses them itself, because a `harness.Json` built here
/// would alias a `Response` body this frame already freed.
fn getTaskBody(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, task_id: []const u8, expect: []const u16) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ workspace_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// The task object's `name`, owned.
fn taskName(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, task_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ workspace_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("task GET returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const name = switch (task.get("name") orelse {
        std.debug.print("task GET task has no `name`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task GET task name is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, name);
}

/// Assert every key in `keys` is present on `obj` (Python's
/// `assert "tags" in task`).
fn expectKeysPresent(obj: std.json.ObjectMap, keys: []const []const u8, label: []const u8) !void {
    for (keys) |k| {
        if (obj.get(k) == null) {
            const rendered = try renderKeys(obj);
            defer gpa.free(rendered);
            std.debug.print("{s} is missing the `{s}` field; keys = [{s}]\n", .{ label, k, rendered });
            return error.TestUnexpectedResult;
        }
    }
}

/// Assert no key in `keys` is present on `obj` (Python's
/// `assert "image_urls" not in task, sorted(task)`).
fn expectKeysAbsent(obj: std.json.ObjectMap, keys: []const []const u8, label: []const u8) !void {
    for (keys) |k| {
        if (obj.get(k) != null) {
            const rendered = try renderKeys(obj);
            defer gpa.free(rendered);
            std.debug.print("{s} still carries the `{s}` field; keys = [{s}]\n", .{ label, k, rendered });
            return error.TestUnexpectedResult;
        }
    }
}

/// Comma-joined keys, sorted — the failure-message shape Python's
/// `sorted(task)` produced.
fn renderKeys(obj: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return std.mem.join(gpa, ", ", keys.items);
}

/// Parse owned bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// Assert `obj[key]` is the string `want`.
fn expectEqualFieldString(obj: std.json.ObjectMap, key: []const u8, want: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("response is missing the `{s}` field\n", .{key});
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 1: happy path — full task shape
// ============================================================================

// Create → GET by id → 200 `{ task }` with the fields the detail dialog
// reads (name, description, tags, unattended flag, images).
test "get_task_by_id_returns_full_task" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    const task_id = try createTask(&h, ws_id, kanban_id, "my task");
    defer gpa.free(task_id);

    const body = try getTaskBody(&h, ws_id, kanban_id, task_id, &.{200});
    defer gpa.free(body);
    var doc = try parseJson(body);
    defer doc.deinit();

    // Python: `task = body.get("task"); assert isinstance(task, dict)`.
    const task = doc.object("task") orelse {
        std.debug.print("expected task object, got: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };

    try expectEqualFieldString(task, "id", task_id);
    try expectEqualFieldString(task, "name", "my task");
    try expectEqualFieldString(task, "description", "desc");
    try expectEqualFieldString(task, "workspace_item_id", kanban_id);

    // Fields the dialog renders — must be present in the single-task
    // response exactly as in the list response.
    try expectKeysPresent(task, &.{
        "tags",
        "is_auto_retry_until_stop",
        "kanban_column_id",
        "needs_human_review",
    }, "the single-task response");

    // media-flags change: the task body is flag-only.
    try expectKeysPresent(task, &.{ "is_have_image", "is_have_video" }, "the single-task response");
    try expectKeysAbsent(task, &.{ "image_urls", "video_urls" }, "the single-task response");
}

// The lazy `/media` route carries the full strings the task body dropped.
test "get_task_media_endpoint_returns_lazy_payloads" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    const task_id = try createTask(&h, ws_id, kanban_id, "my task");
    defer gpa.free(task_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/media",
        .{ ws_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Python: `set(media) == {"image_urls", "video_urls"}`. The body IS
    // the media map (there is no wrapper), so read the ROOT object —
    // `doc.object(key)` looks a key up inside the root.
    const media = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("media route did not return an object: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    if (media.count() != 2 or media.get("image_urls") == null or media.get("video_urls") == null) {
        const rendered = try renderKeys(media);
        defer gpa.free(rendered);
        std.debug.print("media route keys = [{s}], expected exactly image_urls + video_urls\n", .{rendered});
        return error.TestUnexpectedResult;
    }

    // No media was ever attached, so both are the empty string — not
    // null and not a 404. A task row must always exist before the media
    // route is asked about it.
    try expectEqualFieldString(media, "image_urls", "");
    try expectEqualFieldString(media, "video_urls", "");
}

// `/media` for a task that does not exist → 404, same as the task route.
test "get_task_media_unknown_id_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/task_does_not_exist/media",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const msg = doc.str("error") orelse "";
    if (std.mem.indexOf(u8, msg, "task not found") == null) {
        std.debug.print("media 404 body: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 2: unknown task → 404
// ============================================================================

test "get_task_unknown_id_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    const msg = try getTaskError(&h, ws_id, kanban_id, "task_does_not_exist", &.{404});
    defer gpa.free(msg);
    if (std.mem.indexOf(u8, msg, "task not found") == null) {
        std.debug.print("404 body did not say `task not found`: {s}\n", .{msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: item scoping — task under another kanban → 404
// ============================================================================

// A task under kanban B must NOT be readable through kanban A's
// path — the DB fn scopes by BOTH workspace_item_id and task id.
test "get_task_scoped_to_parent_item" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_a = try createKanban(&h, ws_id, "board-a");
    defer gpa.free(kanban_a);
    const kanban_b = try createKanban(&h, ws_id, "board-b");
    defer gpa.free(kanban_b);

    const task_id = try createTask(&h, ws_id, kanban_b, "on board b");
    defer gpa.free(task_id);

    // Wrong item in the path → 404.
    {
        const msg = try getTaskError(&h, ws_id, kanban_a, task_id, &.{404});
        defer gpa.free(msg);
        if (std.mem.indexOf(u8, msg, "task not found") == null) {
            std.debug.print("wrong-item read did not 404 `task not found`: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        }
    }

    // Correct item → 200.
    const name = try taskName(&h, ws_id, kanban_b, task_id);
    defer gpa.free(name);
    try testing.expectEqualStrings("on board b", name);
}

// ============================================================================
// Test 4: empty task_id → 400 (empty-slice-as-NULL guard)
// ============================================================================

test "get_task_empty_id_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    // A trailing-slash URL yields an empty :task_id capture; the
    // handler must 400 BEFORE any DB call (SqliteBackend binds "" as
    // SQL NULL).
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{400} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const msg = doc.str("error") orelse "";
    if (std.mem.indexOf(u8, msg, "task_id required") == null) {
        std.debug.print("empty-task_id 400 body: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: list route still works (route-order shadowing guard)
// ============================================================================

// matchRoute walks routes in registration order — the list route
// must still match after the single-task route was registered.
test "list_route_not_shadowed_by_single_task_route" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-get-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-get");
    defer gpa.free(kanban_id);

    {
        const t1 = try createTask(&h, ws_id, kanban_id, "t1");
        defer gpa.free(t1);
    }
    {
        const t2 = try createTask(&h, ws_id, kanban_id, "t2");
        defer gpa.free(t2);
    }

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{
        .params = &.{.{ .name = "limit", .value = "100" }},
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const tasks = doc.array("tasks") orelse {
        std.debug.print("list route returned no `tasks` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (tasks.items.len != 2) {
        std.debug.print("expected 2 tasks from list route, got {d}: {s}\n", .{ tasks.items.len, r.body });
        return error.TestUnexpectedResult;
    }
}
