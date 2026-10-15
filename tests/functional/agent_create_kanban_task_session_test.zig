// Functional tests for agent-tool/HTTP parity on kanban task session seeding.
// Zig port of `tests/functional/agent_create_kanban_task_session_test.py`
// (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Owned copies of the fields the two tests read off the create response.
/// Python's `_create_task` handed the whole parsed body back to the caller.
const TaskCreate = struct {
    task_id: []u8,
    session_id: ?[]u8,
    session_status: ?[]u8,

    fn deinit(self: *TaskCreate) void {
        gpa.free(self.task_id);
        if (self.session_id) |v| gpa.free(v);
        if (self.session_status) |v| gpa.free(v);
        self.* = undefined;
    }
};

/// The `content` of every user-role `llm_history` row, in wire order.
const UserMsgs = struct {
    items: [][]u8,

    fn deinit(self: *UserMsgs) void {
        for (self.items) |it| gpa.free(it);
        gpa.free(self.items);
        self.* = undefined;
    }

    /// Print the contents the way the Python assertion's `{user_msgs!r}`
    /// did, so a failure is readable without a debugger.
    fn dump(self: *const UserMsgs) void {
        std.debug.print("  got {d} user row(s):", .{self.items.len});
        for (self.items, 0..) |c, i| {
            std.debug.print("{s}\"{s}\"", .{ if (i == 0) " " else ", ", c });
        }
        std.debug.print("\n", .{});
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
        std.debug.print("workspace create response has no string `id`\n", .{});
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
        std.debug.print("kanban create response has no `item` object\n", .{});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, switch (item.get("id") orelse {
        std.debug.print("kanban create response has no item.id\n", .{});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create response item.id is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    });
}

/// POST `mode='create_session'` — the frontend's plain `Create task` button
/// (no agent run).
fn createTask(
    h: *Harness,
    ws_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    description: []const u8,
    extra: ?[]const u8,
) !TaskCreate {
    const body = if (extra) |e|
        try std.fmt.allocPrint(
            gpa,
            "{{\"mode\":\"create_session\",\"name\":\"{s}\",\"description\":\"{s}\",{s}}}",
            .{ name, description, e },
        )
    else
        try std.fmt.allocPrint(
            gpa,
            "{{\"mode\":\"create_session\",\"name\":\"{s}\",\"description\":\"{s}\"}}",
            .{ name, description },
        );
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws_id, kanban_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const task = doc.object("task") orelse {
        std.debug.print("create response missing `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const task_id = try gpa.dupe(u8, switch (task.get("id") orelse {
        std.debug.print("create response has no task.id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("create response task.id is not a string\n", .{});
            return error.TestUnexpectedResult;
        },
    });
    errdefer gpa.free(task_id);

    // A missing `session` envelope is the regression this suite exists
    // for, so it is `null` here rather than an error — each test decides.
    var session_id: ?[]u8 = null;
    var session_status: ?[]u8 = null;
    if (doc.object("session")) |session| {
        if (session.get("id")) |v| switch (v) {
            .string => |s| session_id = try gpa.dupe(u8, s),
            else => {},
        };
        if (session.get("status")) |v| switch (v) {
            .string => |s| session_status = try gpa.dupe(u8, s),
            else => {},
        };
    }

    return .{
        .task_id = task_id,
        .session_id = session_id,
        .session_status = session_status,
    };
}

/// `GET /api/llm/session/{id}/messages` filtered to `role == "user"`.
fn userRoleMessages(h: *Harness, session_id: []const u8) !UserMsgs {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{
        .params = &.{
            .{ .name = "sort_by", .value = "created_at" },
            .{ .name = "direction", .value = "asc" },
            .{ .name = "limit", .value = "100" },
        },
        .expect = &.{200},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const msgs = doc.array("messages") orelse {
        std.debug.print("expected a `messages` list, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |it| gpa.free(it);
        out.deinit(gpa);
    }
    for (msgs.items) |m| {
        const obj = switch (m) {
            .object => |o| o,
            else => continue,
        };
        const role = switch (obj.get("role") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, role, "user")) continue;
        const content = switch (obj.get("content") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, content));
    }

    // `toOwnedSlice` hands ownership over; no `defer out.deinit(gpa)`.
    return .{ .items = try out.toOwnedSlice(gpa) };
}

// ============================================================================
// Test 1: plain create seeds session + user message
// ============================================================================

// The exact regression the agent tool had: no flag/profile must still
// yield a session row and one user message.
test "plain_create_seeds_session_and_user_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ckt-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-ckt");
    defer gpa.free(kanban_id);

    var created = try createTask(&h, ws_id, kanban_id, "Agent card", "do the thing", null);
    defer created.deinit();

    const session_id = created.session_id orelse {
        std.debug.print("create_session response missing `session`\n", .{});
        return error.TestUnexpectedResult;
    };
    // `session.id` must match `task.id` (task.id == session.id).
    if (!std.mem.eql(u8, session_id, created.task_id)) {
        std.debug.print(
            "session.id should match task.id, got \"{s}\" vs \"{s}\"\n",
            .{ session_id, created.task_id },
        );
        return error.TestUnexpectedResult;
    }
    const status = created.session_status orelse {
        std.debug.print("session envelope has no `status`\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("idle", status);

    var msgs = try userRoleMessages(&h, created.task_id);
    defer msgs.deinit();
    if (msgs.items.len != 1) {
        msgs.dump();
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("Agent card\n\ndo the thing", msgs.items[0]);
}

// ============================================================================
// Test 2: flag + profile still bound
// ============================================================================

// Unattended flag + profile must land on the seeded session row (and the
// user message must still be seeded).
test "create_with_flag_and_profile_binds_session_columns" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "agent-ckt-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-ckt");
    defer gpa.free(kanban_id);

    var created = try createTask(
        &h,
        ws_id,
        kanban_id,
        "Overnight card",
        "run while I sleep",
        "\"is_auto_retry_until_stop\":\"1\",\"selected_profile_model\":\"code\"",
    );
    defer created.deinit();

    const session_id = created.session_id orelse {
        std.debug.print("create_session response missing `session`\n", .{});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(created.task_id, session_id);

    var msgs = try userRoleMessages(&h, created.task_id);
    defer msgs.deinit();
    if (msgs.items.len != 1) {
        msgs.dump();
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("Overnight card\n\nrun while I sleep", msgs.items[0]);
}
