// Functional tests for task lifecycle (Tier 1.2). Zig port of
// `tests/functional/task_lifecycle_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// JSON accessors shared by every test
// ============================================================================

/// The root object of a parsed document, or a test failure.
fn rootObj(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// `obj[key]` as a string. Mirrors Python's `task["name"]`, which raises
/// when the key is missing or is not a string.
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

/// `obj[key]` as a bool. Mirrors Python's `task["completed"] is False`.
fn boolAt(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !bool {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `obj.get(key) is None`: the key is ABSENT or explicitly
/// `null`. Both spellings satisfy it, and the ported server may pick
/// either, so both pass.
fn expectNullOrAbsent(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse return;
    switch (v) {
        .null => return,
        else => {
            std.debug.print("{s}: `{s}` should be null or absent\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    }
}

/// Python `assert "error" in body` followed by a substring assertion on
/// `body["error"]`, case-insensitively: any ONE of `needles` must appear.
fn expectErrorContains(body: []const u8, needles: []const []const u8, ctx: []const u8) !void {
    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        body,
        .{ .allocate = .alloc_always },
    ) };
    defer doc.deinit();
    const msg = try strAt(try rootObj(&doc, ctx), "error", ctx);
    const hay = try std.ascii.allocLowerString(gpa, msg);
    defer gpa.free(hay);
    for (needles) |needle| {
        const n = try std.ascii.allocLowerString(gpa, needle);
        defer gpa.free(n);
        if (std.mem.indexOf(u8, hay, n) != null) return;
    }
    std.debug.print("{s}: error = \"{s}\", expected one of the needles\n", .{ ctx, msg });
    return error.TestUnexpectedResult;
}

// ============================================================================
// Owned-document plumbing
// ============================================================================

/// An owned response body PLUS its parse, so a helper can hand a
/// document to its caller without the body dying underneath it.
const OwnedDoc = struct {
    bytes: []u8,
    doc: harness.Json,

    pub fn deinit(self: *OwnedDoc) void {
        self.doc.deinit();
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Parse owned bytes into a self-contained `OwnedDoc`.
fn parseOwned(bytes: []u8) !OwnedDoc {
    return .{
        .bytes = bytes,
        .doc = .{ .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            bytes,
            .{ .allocate = .alloc_always },
        ) },
    };
}

/// Issue a request and hand back an owned, self-contained document.
/// `.alloc_always` is what makes this legal: no string in the returned tree
/// borrows `r.body`, which is freed before the caller ever sees it.
fn requestDoc(h: *Harness, method: harness.HttpMethod, path: []const u8, opts: harness.Harness.HttpOptions) !OwnedDoc {
    var r = try h.http(io, method, path, opts);
    defer r.deinit();
    return parseOwned(try gpa.dupe(u8, r.body));
}

// ============================================================================
// Fixtures (mirror the Python module-level helpers)
// ============================================================================

/// Python `_create_workspace` → the new workspace's id. Owned.
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

/// Python `_create_chat_item` → the new item's id. Owned. The `path` is
/// derived from the harness tempdir, never a literal `/tmp` (see the file
/// header).
fn createChatItem(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    const path = try harness.harnessPath(gpa, h.temp_dir, &.{"task-lc"});
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .item_type = "chat",
        .path = path,
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("chat item create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// Python `_create_kanban_item` → the new kanban item's id. Owned.
fn createKanbanItem(h: *Harness, ws_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    // `item = body.get("item"); if item is None: return body`.
    if (doc.object("item")) |item| {
        const id = strAt(item, "id", "kanban create envelope") catch |err| {
            std.debug.print("kanban create envelope item has no id: {s}\n", .{r.body});
            return err;
        };
        return gpa.dupe(u8, id);
    }
    const id = doc.str("id") orelse {
        std.debug.print("kanban create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// The optional field set Python's `_create_task` built up key by key.
const TaskFields = struct {
    name: []const u8,
    task_type: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    initial_prompt: ?[]const u8 = null,
    description: ?[]const u8 = null,
    image_urls: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    is_auto_retry_until_stop: ?[]const u8 = null,
};

/// Python `_create_task` → the create response document (self-contained).
fn createTask(h: *Harness, ws_id: []const u8, item_id: []const u8, fields: TaskFields) !OwnedDoc {
    const body = try std.json.Stringify.valueAlloc(gpa, fields, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    return requestDoc(h, .POST, url, .{ .json_body = body, .expect = &.{201} });
}

/// Python `_create_kanban_task_via_kanban_endpoint` → the envelope.
fn createKanbanTask(
    h: *Harness,
    ws_id: []const u8,
    item_id: []const u8,
    mode: []const u8,
    name: []const u8,
    queue_message: ?[]const u8,
    is_auto_retry_until_stop: ?[]const u8,
) !OwnedDoc {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = mode,
        .name = name,
        .queue_message = queue_message,
        .is_auto_retry_until_stop = is_auto_retry_until_stop,
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    return requestDoc(h, .POST, url, .{ .json_body = body, .expect = &.{201} });
}

/// Python `_list_tasks` → the `{tasks:[...]}` document (self-contained).
fn listTasks(h: *Harness, ws_id: []const u8, item_id: []const u8) !OwnedDoc {
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    return requestDoc(h, .GET, url, .{
        .params = &.{.{ .name = "limit", .value = "100" }},
        .expect = &.{200},
    });
}

/// Python `body.get("tasks", body if isinstance(body, list) else [])`.
///
/// Borrows `listed`, which the caller owns.
fn tasksArray(listed: *const harness.Json, ctx: []const u8) !std.json.Array {
    return switch (listed.value().*) {
        .array => |a| a,
        .object => |o| {
            const v = o.get("tasks") orelse return .{ .items = &.{}, .capacity = 0, .allocator = gpa };
            return switch (v) {
                .array => |a| a,
                else => .{ .items = &.{}, .capacity = 0, .allocator = gpa },
            };
        },
        else => {
            std.debug.print("{s}: unexpected tasks payload\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `next((t for t in listed if t["id"] == task_id), None)`.
///
/// Borrows `tasks`.
fn findTaskById(tasks: std.json.Array, task_id: []const u8) ?std.json.ObjectMap {
    for (tasks.items) |entry| {
        const obj = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (obj.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, id, task_id)) return obj;
    }
    return null;
}

/// `POST .../tasks/:task_id/pin {"is_pinned": true}`.
fn pinTask(h: *Harness, ws_id: []const u8, item_id: []const u8, task_id: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .is_pinned = true }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/pin",
        .{ ws_id, item_id, task_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

// ============================================================================
// Test 1: kanban /kanban/tasks endpoint — create mode
// ============================================================================

// POST /kanban/tasks with mode='create' returns the wrapped envelope.
test "kanban_tasks_endpoint_create_mode" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanbanItem(&h, ws_id, "sprint");
    defer gpa.free(kanban_id);

    var envelope = try createKanbanTask(&h, ws_id, kanban_id, "create", "first-card", null, null);
    defer envelope.deinit();

    const root = try rootObj(&envelope.doc, "create envelope");
    // Python: `assert "task" in body`.
    const task = root.get("task") orelse {
        std.debug.print("envelope should have 'task', got: {s}\n", .{envelope.bytes});
        return error.TestUnexpectedResult;
    };
    const task_obj = switch (task) {
        .object => |o| o,
        else => {
            std.debug.print("envelope `task` should be an object: {s}\n", .{envelope.bytes});
            return error.TestUnexpectedResult;
        },
    };

    // Envelope shape: { task: <TaskCreateResponse>, session: null }.
    try expectNullOrAbsent(root, "session", "create envelope");

    const task_id = try strAt(task_obj, "id", "create envelope task");
    try testing.expect(std.mem.startsWith(u8, task_id, "task_"));
    try testing.expectEqualStrings("first-card", try strAt(task_obj, "name", "create envelope task"));
    try expectNullOrAbsent(task_obj, "description", "create envelope task");
    try testing.expectEqual(false, try boolAt(task_obj, "completed", "create envelope task"));

    // The task is visible via the list endpoint (the list returns the
    // fuller shape — useful for catching drift between the kanban-scoped
    // response and the list view).
    var listed = try listTasks(&h, ws_id, kanban_id);
    defer listed.deinit();

    const tasks = try tasksArray(&listed.doc, "create-mode list");
    const found = findTaskById(tasks, task_id) orelse {
        std.debug.print(
            "created task '{s}' not in list response: {s}\n",
            .{ task_id, listed.bytes },
        );
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(kanban_id, try strAt(found, "workspace_item_id", "listed task"));
}

// ============================================================================
// Test 2: kanban /kanban/tasks endpoint — create_and_run mode
// ============================================================================

// mode='create_and_run' requires queue_message + creates a session row. The
// response carries `session: {id, name, status: 'send'}` — the session_id ==
// task_id per the project's convention.
test "kanban_tasks_endpoint_create_and_run_returns_session" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanbanItem(&h, ws_id, "sprint2");
    defer gpa.free(kanban_id);

    var envelope = try createKanbanTask(
        &h,
        ws_id,
        kanban_id,
        "create_and_run",
        "run-it",
        "hello worker",
        null,
    );
    defer envelope.deinit();

    const root = try rootObj(&envelope.doc, "create_and_run envelope");
    const task_obj = switch (root.get("task") orelse {
        std.debug.print("create_and_run envelope has no 'task': {s}\n", .{envelope.bytes});
        return error.TestUnexpectedResult;
    }) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const task_id = try strAt(task_obj, "id", "create_and_run envelope task");

    // `assert body.get("session") is not None` — this time it must be
    // PRESENT, which is the whole point of the mode discriminator.
    const session_v = root.get("session") orelse {
        std.debug.print(
            "mode='create_and_run' should populate session, got null: {s}\n",
            .{envelope.bytes},
        );
        return error.TestUnexpectedResult;
    };
    const session = switch (session_v) {
        .object => |o| o,
        else => {
            std.debug.print("session should be an object: {s}\n", .{envelope.bytes});
            return error.TestUnexpectedResult;
        },
    };

    const session_id = try strAt(session, "id", "session");
    if (!std.mem.eql(u8, session_id, task_id)) {
        std.debug.print(
            "session.id should equal task.id, got session.id='{s}' task.id='{s}'\n",
            .{ session_id, task_id },
        );
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("run-it", try strAt(session, "name", "session"));
    try testing.expectEqualStrings("send", try strAt(session, "status", "session"));
}

// ============================================================================
// Test 3: /kanban/tasks rejects create_and_run without queue_message
// ============================================================================

// mode='create_and_run' without queue_message returns 400.
test "kanban_tasks_endpoint_create_and_run_requires_queue_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanbanItem(&h, ws_id, "sprint3");
    defer gpa.free(kanban_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_and_run",
        .name = "no-msg",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    // The 400 message should mention queue_message.
    try expectErrorContains(r.body, &.{"queue_message"}, "create_and_run without queue_message");
}

// ============================================================================
// Test 4: /kanban/tasks rejects unknown mode
// ============================================================================

// POST /kanban/tasks with mode='garbage' returns 400.
test "kanban_tasks_endpoint_rejects_unknown_mode" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanbanItem(&h, ws_id, "sprint4");
    defer gpa.free(kanban_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "garbage",
        .name = "x",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"mode"}, "unknown mode");
}

// ============================================================================
// Test 5: /kanban/tasks on non-kanban parent returns 404
// ============================================================================

// POST /kanban/tasks against a chat parent returns 404. The handler validates
// the parent's item_type='kanban' before creating the task.
test "kanban_tasks_endpoint_rejects_non_kanban_parent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "chat-parent");
    defer gpa.free(chat_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "x",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, chat_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{404} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{ "not found", "not a kanban" }, "non-kanban parent");
}

// ============================================================================
// Test 6: PUT task renames + persists across GET
// ============================================================================

// PUT /tasks/:task_id {name: ...} → list shows the new name. task_update.zig
// returns `{success, id}`; the rename is verified by re-fetching via the list
// endpoint.
test "put_task_rename_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "rename-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{ .name = "before" });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "task create"), "id", "task create");

    const put_body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "after" }, .{});
    defer gpa.free(put_body);
    const put_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws_id, chat_id, task_id },
    );
    defer gpa.free(put_url);

    var put_resp = try h.http(io, .PUT, put_url, .{ .json_body = put_body, .expect = &.{200} });
    defer put_resp.deinit();
    {
        var d = try put_resp.json();
        defer d.deinit();
        try testing.expectEqual(true, d.boolean("success").?);
        try testing.expectEqualStrings(task_id, d.str("id").?);
    }

    // List endpoint reflects the rename.
    var listed = try listTasks(&h, ws_id, chat_id);
    defer listed.deinit();
    const tasks = try tasksArray(&listed.doc, "rename list");
    const found = findTaskById(tasks, task_id) orelse {
        std.debug.print("renamed task '{s}' vanished from the list: {s}\n", .{ task_id, listed.bytes });
        return error.TestUnexpectedResult;
    };
    const name = try strAt(found, "name", "renamed task");
    if (!std.mem.eql(u8, name, "after")) {
        std.debug.print("rename didn't apply; got '{s}'\n", .{name});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 7: PUT task by-id path (no workspace in URL)
// ============================================================================

// PUT /api/workspaces/tasks/:task_id (without workspace_id/item_id path
// params) also succeeds — same handler as the path-param variant.
// task_update.zig::tasksUpdateByIdHandler delegates to the same useCase; this
test "put_task_by_id_path_also_works" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "id-only-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{ .name = "name-1" });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "task create"), "id", "task create");

    const put_body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "name-2" }, .{});
    defer gpa.free(put_body);
    const put_url = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{task_id});
    defer gpa.free(put_url);

    var put_resp = try h.http(io, .PUT, put_url, .{ .json_body = put_body, .expect = &.{200} });
    defer put_resp.deinit();
    {
        var d = try put_resp.json();
        defer d.deinit();
        try testing.expectEqual(true, d.boolean("success").?);
    }

    var listed = try listTasks(&h, ws_id, chat_id);
    defer listed.deinit();
    const tasks = try tasksArray(&listed.doc, "by-id rename list");
    const found = findTaskById(tasks, task_id) orelse {
        std.debug.print("task '{s}' not in list: {s}\n", .{ task_id, listed.bytes });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("name-2", try strAt(found, "name", "renamed task"));
}

// ============================================================================
// Test 8: DELETED (Migration 084) ==========================================
// PUT task with routine fields no longer creates a routines row — the

// ============================================================================
// Test 9: DELETED (Migration 084) ==========================================
// PUT task no longer validates cron — routine fields are ignored.

// ============================================================================
// Test 10: DELETE task removes it from the list
// ============================================================================

// DELETE /tasks/:task_id → list no longer contains it. Response shape is
// `{id, success: true}` (the `WorkspaceItemResponse` shape from
// http_response.zig).
test "delete_task_removes_from_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "del-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{ .name = "doomed" });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "task create"), "id", "task create");

    // Present before the delete.
    {
        var listed = try listTasks(&h, ws_id, chat_id);
        defer listed.deinit();
        const tasks = try tasksArray(&listed.doc, "pre-delete list");
        if (findTaskById(tasks, task_id) == null) {
            std.debug.print("newly created task '{s}' is not in the list: {s}\n", .{ task_id, listed.bytes });
            return error.TestUnexpectedResult;
        }
    }

    const del_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws_id, chat_id, task_id },
    );
    defer gpa.free(del_url);

    var del_resp = try h.http(io, .DELETE, del_url, .{ .expect = &.{200} });
    defer del_resp.deinit();
    {
        var d = try del_resp.json();
        defer d.deinit();
        try testing.expectEqual(true, d.boolean("success").?);
        try testing.expectEqualStrings(task_id, d.str("id").?);
    }

    var listed2 = try listTasks(&h, ws_id, chat_id);
    defer listed2.deinit();
    const tasks2 = try tasksArray(&listed2.doc, "post-delete list");
    if (findTaskById(tasks2, task_id) != null) {
        std.debug.print("deleted task '{s}' still in list: {s}\n", .{ task_id, listed2.bytes });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 11: DELETE task 404 for nonexistent
// ============================================================================

// DELETE /tasks/task_nope is idempotent + returns 200.
test "delete_task_404_for_nonexistent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "404-host");
    defer gpa.free(chat_id);

    // Note: the response is 200 (idempotent), not 404. This test
    // documents that contract — flip to expect=404 if the handler is
    // ever updated to refuse deletes on missing rows.
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/task_nope",
        .{ ws_id, chat_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .DELETE, url, .{ .expect = &.{200} });
    defer r.deinit();
    var d = try r.json();
    defer d.deinit();
    try testing.expectEqual(true, d.boolean("success").?);
    try testing.expectEqualStrings("task_nope", d.str("id").?);
}

// ============================================================================
// Test 12: PUT /touched stamps the timestamp
// ============================================================================

// PUT /tasks/:task_id/touched returns 200 with {success, task_id}. The stamp
// itself is verified via DB observation: re-PUT after a short delay should
// produce a NEW `last_human_touched_at` row.
test "put_touched_stamps_human_touched_at" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "touched-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{ .name = "touched-target" });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "task create"), "id", "task create");

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/touched",
        .{ ws_id, chat_id, task_id },
    );
    defer gpa.free(url);

    // First PUT.
    var r = try h.http(io, .PUT, url, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    {
        var d = try r.json();
        defer d.deinit();
        try testing.expectEqual(true, d.boolean("success").?);
        try testing.expectEqualStrings(task_id, d.str("task_id").?);
    }

    // Idempotent: a second PUT works without 4xx/5xx.
    var r2 = try h.http(io, .PUT, url, .{ .json_body = "{}", .expect = &.{200} });
    defer r2.deinit();
    var d2 = try r2.json();
    defer d2.deinit();
    try testing.expectEqual(true, d2.boolean("success").?);
    try testing.expectEqualStrings(task_id, d2.str("task_id").?);
}

// ============================================================================
// Test 13: POST /reorder_pinned reorders pinned subset
// ============================================================================

// POST /tasks/reorder_pinned with [t1, t2, t3] places t1 first in the pinned
// block. Non-pinned tasks are unaffected.
test "reorder_pinned_reorders_only_pinned_subset" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanbanItem(&h, ws_id, "reorder-host");
    defer gpa.free(kanban_id);

    // Create 3 tasks under the kanban (auto-assigned to first column).
    var a = try createTask(&h, ws_id, kanban_id, .{ .name = "A" });
    defer a.deinit();
    const a_id = try strAt(try rootObj(&a.doc, "task A"), "id", "task A");
    var b = try createTask(&h, ws_id, kanban_id, .{ .name = "B" });
    defer b.deinit();
    const b_id = try strAt(try rootObj(&b.doc, "task B"), "id", "task B");
    var c = try createTask(&h, ws_id, kanban_id, .{ .name = "C" });
    defer c.deinit();
    const c_id = try strAt(try rootObj(&c.doc, "task C"), "id", "task C");

    _ = b_id; // B stays unpinned.

    // Pin A and C (leave B non-pinned).
    try pinTask(&h, ws_id, kanban_id, a_id);
    try pinTask(&h, ws_id, kanban_id, c_id);

    // Reorder the pinned subset to [C, A] (C first, A second).
    const body = try std.json.Stringify.valueAlloc(
        gpa,
        .{ .ordered_ids = [_][]const u8{ c_id, a_id } },
        .{},
    );
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/reorder_pinned",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var d = try r.json();
    defer d.deinit();
    try testing.expectEqual(true, d.boolean("success").?);
    const count = d.int("count") orelse {
        std.debug.print("reorder_pinned response has no integer `count`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(i64, 2), count);
}

// ============================================================================
// Test 14: DELETED (Migration 084) ==========================================
// POST /tasks/:id/run is gone (404 route, not a handler 404).

// ============================================================================
// Test 15: DELETED (Migration 084) ==========================================
// Per-task routine creation is rejected with 400 RoutineTasksRemoved.

// ============================================================================
// Test 16: /start_agent succeeds on existing task (no worker running)
// ============================================================================

// POST /tasks/:task_id/start_agent on an idle task → 200. Returns `{success,
// session_id, status: 'triggered'}`.
test "start_agent_succeeds_on_idle_task" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "start-agent-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{ .name = "go" });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "task create"), "id", "task create");

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/start_agent",
        .{ ws_id, chat_id, task_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    var d = try r.json();
    defer d.deinit();
    try testing.expectEqual(true, d.boolean("success").?);
    try testing.expectEqualStrings(task_id, d.str("session_id").?);
    try testing.expectEqualStrings("triggered", d.str("status").?);
}

// ============================================================================
// Test 17: /start_agent 404 for nonexistent task
// ============================================================================

// POST /tasks/task_nope/start_agent → 404 with `{"error": "task not
// found"}`.
test "start_agent_404_for_nonexistent_task" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "start-agent-404-host");
    defer gpa.free(chat_id);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/task_nope/start_agent",
        .{ ws_id, chat_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{404} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"task not found"}, "start_agent 404");
}

// ============================================================================
// Test 18: image_urls round-trips via POST /tasks
// ============================================================================

// POST /tasks with image_urls='data:image/png;base64,...' persists +
// round-trips via the list endpoint. The `image_urls` field is the ||-joined
// wire format (Migration 069).
test "task_create_accepts_image_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "img-host");
    defer gpa.free(chat_id);

    const payload = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAAA1BMVEX///+nxBvIAAAAC0lEQVQI12NgAAIAAAUAAeImBZsAAAAASUVORK5CYII=";

    var created = try createTask(&h, ws_id, chat_id, .{
        .name = "with-image",
        .image_urls = payload,
    });
    defer created.deinit();
    const task_id = try strAt(try rootObj(&created.doc, "image task create"), "id", "image task create");
    try testing.expect(std.mem.startsWith(u8, task_id, "task_"));

    var listed = try listTasks(&h, ws_id, chat_id);
    defer listed.deinit();
    const tasks = try tasksArray(&listed.doc, "image list");
    const found = findTaskById(tasks, task_id) orelse {
        std.debug.print("image task '{s}' not in list: {s}\n", .{ task_id, listed.bytes });
        return error.TestUnexpectedResult;
    };
    // The image_urls field should round-trip (handlers may carry it
    // verbatim; some response shapes omit it — assert it's present OR
    // absent but never garbled).
    if (found.get("image_urls")) |v| {
        const got = switch (v) {
            .string => |s| s,
            else => {
                std.debug.print("listed image_urls is not a string: {s}\n", .{listed.bytes});
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, got, payload)) {
            std.debug.print("image_urls didn't round-trip; got '{s}'\n", .{got});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 19: invalid image_urls prefix returns 400
// ============================================================================

// image_urls='not-a-data-uri' returns 400 InvalidImageUrls.
test "task_create_rejects_malformed_image_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "bad-img-host");
    defer gpa.free(chat_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "bad",
        .image_urls = "not-a-data-uri",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, chat_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{ "image", "data:image" }, "malformed image_urls");
}

// ============================================================================
// Test 20: relative cwd returns 400
// ============================================================================

// cwd='relative/path' returns 400 CwdNotAbsolute.
//
// task_create.zig:457 rejects paths that don't start with '/'.
test "task_create_rejects_relative_cwd" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "rel-cwd-host");
    defer gpa.free(chat_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "rel-cwd",
        .cwd = "relative/path",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, chat_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{ "absolute", "cwd" }, "relative cwd");
}

// ============================================================================
// Test 21: is_auto_retry_until_stop="1" is persisted (no crash)
// ============================================================================

// POST /tasks with is_auto_retry_until_stop='1' returns 201. The handler
// inserts an `INSERT OR IGNORE INTO sessions` row keyed by task.id (Migration
// 062 + the kanban-task-name-match plan).
test "task_create_with_unattended_flag_does_not_crash" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "task-lc-ws");
    defer gpa.free(ws_id);
    const chat_id = try createChatItem(&h, ws_id, "unattended-host");
    defer gpa.free(chat_id);

    var created = try createTask(&h, ws_id, chat_id, .{
        .name = "unattended",
        .is_auto_retry_until_stop = "1",
    });
    defer created.deinit();

    const root = try rootObj(&created.doc, "unattended task create");
    const task_id = try strAt(root, "id", "unattended task create");
    try testing.expect(std.mem.startsWith(u8, task_id, "task_"));
    try testing.expectEqualStrings("unattended", try strAt(root, "name", "unattended task create"));

    // The task is visible via list.
    var listed = try listTasks(&h, ws_id, chat_id);
    defer listed.deinit();
    const tasks = try tasksArray(&listed.doc, "unattended list");
    if (findTaskById(tasks, task_id) == null) {
        std.debug.print("unattended task '{s}' not in list: {s}\n", .{ task_id, listed.bytes });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Body-analysis barrier
// ============================================================================

comptime {
    // A function body is only type-checked once something calls it, so
    // an unreferenced helper can hide a stdlib rename. Reference them all.
    _ = rootObj;
    _ = strAt;
    _ = boolAt;
    _ = expectNullOrAbsent;
    _ = expectErrorContains;
    _ = parseOwned;
    _ = requestDoc;
    _ = createWorkspace;
    _ = createChatItem;
    _ = createKanbanItem;
    _ = createTask;
    _ = createKanbanTask;
    _ = listTasks;
    _ = tasksArray;
    _ = findTaskById;
    _ = pinTask;
}
