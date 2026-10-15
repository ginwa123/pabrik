// Kanban task descriptions are unlimited (no 5000-char cap). Zig port of
// `tests/functional/kanban_task_long_description_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The cap the frontend used to enforce. Every description below must exceed
/// it — Python asserted `len(long_desc) > 5000` as a "test bug" guard so a
/// typo'd multiplier cannot silently turn the suite into a test of nothing.
const OLD_FRONTEND_CAP: usize = 5000;

/// `text` repeated `times` times, owned by the caller.
fn repeat(text: []const u8, times: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (0..times) |_| {
        buf.writer.writeAll(text) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice();
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id.
fn createWorkspace(h: *Harness) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "kanban-long-desc-ws" }, .{});
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

/// `POST /api/workspaces/<ws>/items/kanban` → the kanban item's id.
fn createKanban(h: *Harness, workspace_id: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "sprint-long-desc" }, .{});
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

/// `POST /api/workspaces/<ws>/items/<kanban>/kanban/tasks` with the
/// frontend's `mode: "create_session"` shape → the new task's id.
fn createTask(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, name: []const u8, description: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = description,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/kanban/tasks", .{ workspace_id, kanban_id });
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

/// `GET /api/workspaces/<ws>/items/<kanban>/tasks/<task>` → the description
/// field, owned.
fn taskDescription(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, task_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/{s}/tasks/{s}", .{ workspace_id, kanban_id, task_id });
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `body["task"]["description"]`.
    const task = doc.object("task") orelse {
        std.debug.print("task GET returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const desc = switch (task.get("description") orelse {
        std.debug.print("task GET task has no `description`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task GET description is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, desc);
}

/// `PUT /api/workspaces/tasks/<task_id> {"description": ...}` — the
/// edit-mode Save. Python asserted only the status (200); so does this.
fn updateTaskDescription(h: *Harness, task_id: []const u8, description: []const u8) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .description = description }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{task_id});
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

// A description 4x the old 5000 cap persists and reads back intact.
test "create_task_with_20000_char_description_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    // "lorem ipsum dolor sit amet. " * 715 — 28 chars, ~20 020 bytes.
    const long_desc = try repeat("lorem ipsum dolor sit amet. ", 715);
    defer gpa.free(long_desc);

    if (long_desc.len <= OLD_FRONTEND_CAP) {
        std.debug.print("test bug: description must exceed the old cap\n", .{});
        return error.TestUnexpectedResult;
    }

    const task_id = try createTask(&h, ws_id, kanban_id, "long desc task", long_desc);
    defer gpa.free(task_id);

    const read_back = try taskDescription(&h, ws_id, kanban_id, task_id);
    defer gpa.free(read_back);
    try testing.expectEqualStrings(long_desc, read_back);
}

// PUT (edit-mode Save) also accepts descriptions past the old cap.
test "update_task_with_20000_char_description_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h);
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id);
    defer gpa.free(kanban_id);

    const task_id = try createTask(&h, ws_id, kanban_id, "update me", "short");
    defer gpa.free(task_id);

    // "updated body. " * 1400 — 14 chars, ~19 600 bytes.
    const long_desc = try repeat("updated body. ", 1400);
    defer gpa.free(long_desc);
    if (long_desc.len <= OLD_FRONTEND_CAP) {
        std.debug.print("test bug: description must exceed the old cap\n", .{});
        return error.TestUnexpectedResult;
    }

    try updateTaskDescription(&h, task_id, long_desc);

    const read_back = try taskDescription(&h, ws_id, kanban_id, task_id);
    defer gpa.free(read_back);
    try testing.expectEqualStrings(long_desc, read_back);
}
