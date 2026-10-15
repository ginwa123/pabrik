// Functional tests for Migration 092 — lightweight task list/get payload +
// lazy media endpoint.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// Tiny valid PNG header (1x1 transparent pixel, base64). Small enough
// to keep the wire payload trivial but a real `data:image/png;base64,`
// prefix so `image_urls` validation accepts it.
const PNG_DATA_URL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

// The second data URL `create_with_multiple_images_preserves_order_in_media`
// appends after the `||` join, and the value `put_image_urls_sets_flag`
// writes over the PNG.
const JPEG_DATA_URL = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD//2Q==";

// ============================================================================
// Helpers
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`. A `harness.Json` aliases the
/// `Response` body it was parsed from, so a helper may not RETURN one (the
/// body dies with the response).
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

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
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
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

/// `POST .../kanban/tasks` with `mode: "create_session"` — mirrors the
/// frontend's "Create task" button (no agent run). Returns the WHOLE
/// response body, owned; the caller parses the `task` object out of it.
fn createTaskBody(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    description: []const u8,
    image_urls: ?[]const u8,
) ![]u8 {
    // `image_urls` is OMITTED (not sent as `""`) when the caller passes
    // null — the Python helper used two separate literals, and the
    // server distinguishes "no key" from "empty key".
    var body: []u8 = undefined;
    if (image_urls) |urls| {
        body = try std.json.Stringify.valueAlloc(gpa, .{
            .mode = "create_session",
            .name = name,
            .description = description,
            .image_urls = urls,
        }, .{});
    } else {
        body = try std.json.Stringify.valueAlloc(gpa, .{
            .mode = "create_session",
            .name = name,
            .description = description,
        }, .{});
    }
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `_create_task_with_image`: the frontend joins the array with `||`
/// before sending, so `image_urls_joined` is one string.
fn createTaskWithImage(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    image_urls_joined: []const u8,
) ![]u8 {
    return createTaskBody(h, workspace_id, kanban_id, "img task", "", image_urls_joined);
}

/// `GET .../tasks?limit=10` — the paginated list the kanban board uses.
/// Owned body.
fn listTasksBody(h: *Harness, workspace_id: []const u8, kanban_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{
        // `params` values are percent-encoded by the harness; `10` has
        // nothing to escape, so it lands verbatim.
        .params = &.{.{ .name = "limit", .value = "10" }},
        .expect = &.{200},
    });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET .../tasks/:task_id` → the whole `{task: {...}}` body. Owned.
fn getTaskBody(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    task_id: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ workspace_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET .../tasks/:task_id/media` → the whole media map. Owned.
fn getMediaBody(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    task_id: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/media",
        .{ workspace_id, kanban_id, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `PUT /api/workspaces/tasks/:task_id {"image_urls": ...}` → 200.
fn putImageUrls(h: *Harness, task_id: []const u8, image_urls: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{task_id});
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .image_urls = image_urls }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// `PUT ...` asserting ONLY that it was REJECTED (400 or 413). The
/// status itself is part of the contract but the set is the assertion,
/// so `expect` names both.
fn putImageUrlsExpectingRejection(h: *Harness, task_id: []const u8, image_urls: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{task_id});
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .image_urls = image_urls }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{ 400, 413 } });
    defer r.deinit();
}

/// Python `assert isinstance(task, dict)` — the root must be an object.
fn requireObject(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: expected a JSON object at the root\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `task["id"]` → owned.
fn requireStr(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) ![]u8 {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const s = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, s);
}

/// Python `obj.get(key) is True` / `is False`.
fn expectBool(obj: std.json.ObjectMap, key: []const u8, want: bool, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: `{s}` is absent (must be the bool {any})\n", .{ ctx, key, want });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got != want) {
        std.debug.print("{s}: `{s}` = {any}, expected {any}\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj.get(key) == want` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const got = try requireStr(obj, key, ctx);
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert key not in obj` — the perf win under test. Prints the
/// sorted key list on failure, exactly as `sorted(task)` did.
fn expectKeyAbsent(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    if (obj.get(key) != null) {
        const rendered = try renderKeys(obj);
        defer gpa.free(rendered);
        std.debug.print("{s}: must NOT carry `{s}`; keys = [{s}]\n", .{ ctx, key, rendered });
        return error.TestUnexpectedResult;
    }
}

/// Comma-joined keys, sorted.
fn renderKeys(obj: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = obj.iterator();
    while (it.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLessThan);
    return std.mem.join(gpa, ", ", keys.items);
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ============================================================================
// Test 1: create → flags on the wire, media via the lazy endpoint
// ============================================================================

// Create with an image → create/list/get carry is_have_image=true (and
// NO image_urls field — the perf win); the media endpoint returns the
// persisted column.
test "create_with_image_returns_flag_and_media_endpoint_serves_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const created = try createTaskWithImage(&h, ws_id, kanban_id, PNG_DATA_URL);
    defer gpa.free(created);
    {
        var doc = try parseJson(created);
        defer doc.deinit();

        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        try expectBool(task, "is_have_image", true, "create response task");
        try expectKeyAbsent(task, "image_urls", "create response task");

        const task_id = try requireStr(task, "id", "create response task");
        defer gpa.free(task_id);

        // The list endpoint the board actually calls.
        {
            const list_raw = try listTasksBody(&h, ws_id, kanban_id);
            defer gpa.free(list_raw);
            var list = try parseJson(list_raw);
            defer list.deinit();

            const tasks = list.array("tasks") orelse {
                std.debug.print("expected tasks list, got: {s}\n", .{list_raw});
                return error.TestUnexpectedResult;
            };
            if (tasks.items.len != 1) {
                std.debug.print("expected 1 task, got {d}: {s}\n", .{ tasks.items.len, list_raw });
                return error.TestUnexpectedResult;
            }
            const row = switch (tasks.items[0]) {
                .object => |o| o,
                else => {
                    std.debug.print("task list entry is not an object: {s}\n", .{list_raw});
                    return error.TestUnexpectedResult;
                },
            };
            try expectBool(row, "is_have_image", true, "task list row");
            try expectBool(row, "is_have_video", false, "task list row");
            try expectKeyAbsent(row, "image_urls", "task list row");
        }

        // The single-task GET carries the same flag-only shape.
        {
            const single_raw = try getTaskBody(&h, ws_id, kanban_id, task_id);
            defer gpa.free(single_raw);
            var single = try parseJson(single_raw);
            defer single.deinit();

            const single_task = single.object("task") orelse {
                std.debug.print("task GET returned no `task`: {s}\n", .{single_raw});
                return error.TestUnexpectedResult;
            };
            try expectBool(single_task, "is_have_image", true, "task GET");
            try expectKeyAbsent(single_task, "image_urls", "task GET");
        }

        // ... and the lazy media route carries the dropped strings.
        {
            const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
            defer gpa.free(media_raw);
            var media = try parseJson(media_raw);
            defer media.deinit();

            // The media map IS the root (there is no wrapper).
            const map = try requireObject(&media, "media response");
            try expectStr(map, "image_urls", PNG_DATA_URL, "media response");
            try expectStr(map, "video_urls", "", "media response");
        }
    }
}

// Multiple images are stored as the `||`-joined string in send order;
// the media endpoint returns them verbatim.
test "create_with_multiple_images_preserves_order_in_media" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const joined = try std.fmt.allocPrint(gpa, "{s}||{s}", .{ PNG_DATA_URL, JPEG_DATA_URL });
    defer gpa.free(joined);

    const created = try createTaskWithImage(&h, ws_id, kanban_id, joined);
    defer gpa.free(created);
    const task_id = blk: {
        var doc = try parseJson(created);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        break :blk try requireStr(task, "id", "create response task");
    };
    defer gpa.free(task_id);

    const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
    defer gpa.free(media_raw);
    var media = try parseJson(media_raw);
    defer media.deinit();

    const map = try requireObject(&media, "media response");
    try expectStr(map, "image_urls", joined, "media response");
}

// A task created without images reports is_have_image=false and the
// media endpoint returns empty sentinels.
test "create_without_image_reports_no_media" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    // No `image_urls` KEY at all — not `""`. The two cases are
    // different on the wire and the server must treat them the same.
    const created = try createTaskBody(&h, ws_id, kanban_id, "no img", "", null);
    defer gpa.free(created);
    const task_id = blk: {
        var doc = try parseJson(created);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        try expectBool(task, "is_have_image", false, "create response task");
        break :blk try requireStr(task, "id", "create response task");
    };
    defer gpa.free(task_id);

    {
        const list_raw = try listTasksBody(&h, ws_id, kanban_id);
        defer gpa.free(list_raw);
        var list = try parseJson(list_raw);
        defer list.deinit();

        const tasks = list.array("tasks") orelse {
            std.debug.print("expected tasks list, got: {s}\n", .{list_raw});
            return error.TestUnexpectedResult;
        };
        if (tasks.items.len != 1) {
            std.debug.print("expected 1 task, got {d}: {s}\n", .{ tasks.items.len, list_raw });
            return error.TestUnexpectedResult;
        }
        const row = switch (tasks.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("task list entry is not an object: {s}\n", .{list_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectBool(row, "is_have_image", false, "task list row");
    }

    const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
    defer gpa.free(media_raw);
    var media = try parseJson(media_raw);
    defer media.deinit();

    const map = try requireObject(&media, "media response");
    try expectStr(map, "image_urls", "", "media response");
    try expectStr(map, "video_urls", "", "media response");
}

// An unknown task id on the media route is a 404 — the body is not
// asserted, only the status, exactly as in Python.
test "media_endpoint_404_for_unknown_task" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/no_such_task/media",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
    defer r.deinit();
}

// ============================================================================
// Test 2: PUT updates + clears the flag
// ============================================================================

// `PUT /api/workspaces/tasks/:task_id` with `image_urls` persists the
// new value and flips the flag (the media endpoint serves it).
test "put_image_urls_sets_flag" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const created = try createTaskWithImage(&h, ws_id, kanban_id, PNG_DATA_URL);
    defer gpa.free(created);
    const task_id = blk: {
        var doc = try parseJson(created);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        break :blk try requireStr(task, "id", "create response task");
    };
    defer gpa.free(task_id);

    try putImageUrls(&h, task_id, JPEG_DATA_URL);

    {
        const list_raw = try listTasksBody(&h, ws_id, kanban_id);
        defer gpa.free(list_raw);
        var list = try parseJson(list_raw);
        defer list.deinit();

        const tasks = list.array("tasks") orelse {
            std.debug.print("expected tasks list, got: {s}\n", .{list_raw});
            return error.TestUnexpectedResult;
        };
        if (tasks.items.len != 1) {
            std.debug.print("expected 1 task, got {d}: {s}\n", .{ tasks.items.len, list_raw });
            return error.TestUnexpectedResult;
        }
        const row = switch (tasks.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("task list entry is not an object: {s}\n", .{list_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectBool(row, "is_have_image", true, "task list row after PUT");
    }

    const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
    defer gpa.free(media_raw);
    var media = try parseJson(media_raw);
    defer media.deinit();

    const map = try requireObject(&media, "media response after PUT");
    try expectStr(map, "image_urls", JPEG_DATA_URL, "media response after PUT");
}

// `PUT` with `image_urls: ''` clears the column and the flag.
test "put_empty_image_urls_clears_flag" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const created = try createTaskWithImage(&h, ws_id, kanban_id, PNG_DATA_URL);
    defer gpa.free(created);
    const task_id = blk: {
        var doc = try parseJson(created);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        break :blk try requireStr(task, "id", "create response task");
    };
    defer gpa.free(task_id);

    // The empty string is LOAD-BEARING here: it is the "clear" signal,
    // distinct from omitting the key.
    try putImageUrls(&h, task_id, "");

    {
        const list_raw = try listTasksBody(&h, ws_id, kanban_id);
        defer gpa.free(list_raw);
        var list = try parseJson(list_raw);
        defer list.deinit();

        const tasks = list.array("tasks") orelse {
            std.debug.print("expected tasks list, got: {s}\n", .{list_raw});
            return error.TestUnexpectedResult;
        };
        if (tasks.items.len != 1) {
            std.debug.print("expected 1 task, got {d}: {s}\n", .{ tasks.items.len, list_raw });
            return error.TestUnexpectedResult;
        }
        const row = switch (tasks.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("task list entry is not an object: {s}\n", .{list_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectBool(row, "is_have_image", false, "task list row after empty PUT");
    }

    const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
    defer gpa.free(media_raw);
    var media = try parseJson(media_raw);
    defer media.deinit();

    const map = try requireObject(&media, "media response after empty PUT");
    try expectStr(map, "image_urls", "", "media response after empty PUT");
}

// A malformed data URL is rejected with 400 (or 413 for the size
// guard) and the stored value — and the flag — are untouched.
test "put_invalid_image_urls_rejected_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-img-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-img");
    defer gpa.free(kanban_id);

    const created = try createTaskWithImage(&h, ws_id, kanban_id, PNG_DATA_URL);
    defer gpa.free(created);
    const task_id = blk: {
        var doc = try parseJson(created);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{created});
            return error.TestUnexpectedResult;
        };
        break :blk try requireStr(task, "id", "create response task");
    };
    defer gpa.free(task_id);

    try putImageUrlsExpectingRejection(&h, task_id, "not-a-data-url");

    {
        const list_raw = try listTasksBody(&h, ws_id, kanban_id);
        defer gpa.free(list_raw);
        var list = try parseJson(list_raw);
        defer list.deinit();

        const tasks = list.array("tasks") orelse {
            std.debug.print("expected tasks list, got: {s}\n", .{list_raw});
            return error.TestUnexpectedResult;
        };
        if (tasks.items.len != 1) {
            std.debug.print("expected 1 task, got {d}: {s}\n", .{ tasks.items.len, list_raw });
            return error.TestUnexpectedResult;
        }
        const row = switch (tasks.items[0]) {
            .object => |o| o,
            else => {
                std.debug.print("task list entry is not an object: {s}\n", .{list_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectBool(row, "is_have_image", true, "task list row after rejected PUT");
    }

    const media_raw = try getMediaBody(&h, ws_id, kanban_id, task_id);
    defer gpa.free(media_raw);
    var media = try parseJson(media_raw);
    defer media.deinit();

    const map = try requireObject(&media, "media response after rejected PUT");
    try expectStr(map, "image_urls", PNG_DATA_URL, "media response after rejected PUT");
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTaskBody;
    _ = createTaskWithImage;
    _ = listTasksBody;
    _ = getTaskBody;
    _ = getMediaBody;
    _ = putImageUrls;
    _ = putImageUrlsExpectingRejection;
    _ = requireObject;
    _ = requireStr;
    _ = expectBool;
    _ = expectStr;
    _ = expectKeyAbsent;
    _ = renderKeys;
}
