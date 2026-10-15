// Workspace-scoped chat history: `read_workspace_session` replaces
// `search_history`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers (mirror command_tool_test.py / agent_kanbans_test.py)
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

/// `POST /api/workspaces/<ws>/items/agent` → the agent item's id. Owned.
fn createAgent(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const agent_path = try harness.harnessPath(gpa, h.temp_dir, &.{"agent-workspace-history-test"});
    defer gpa.free(agent_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = agent_path,
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/agent",
        .{workspace_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    // Python: `r.json()["item"]["id"]`.
    const item = doc.object("item") orelse {
        std.debug.print("agent create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (item.get("id") orelse {
        std.debug.print("agent create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("agent create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban` → the kanban item's id. Owned.
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

/// `POST /api/workspaces/<ws>/items/<kanban>/kanban/tasks` with `mode:
/// "create_session"` — mirrors the frontend's plain "Create task" button.
/// Seeds session.id == task.id + one user message → the new task's id. Owned.
fn createTask(
    h: *Harness,
    workspace_id: []const u8,
    kanban_id: []const u8,
    name: []const u8,
    description: []const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = description,
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

/// The USER messages of a session: how many there are, and their
/// contents joined by a space (Python's
/// `" ".join(str(m.get("content", "")) for m in ...)`).
const UserMessages = struct {
    count: usize,
    body: []u8,

    fn deinit(self: *UserMessages) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// `GET /api/llm/session/<id>/messages`, filtered to `role == "user"`.
fn userMessages(h: *Harness, session_id: []const u8) !UserMessages {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/llm/session/{s}/messages",
        .{session_id},
    );
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
        std.debug.print("expected messages list, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
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
        count += 1;
        const content: []const u8 = switch (obj.get("content") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };
        out.writer.writeAll(content) catch return error.OutOfMemory;
        out.writer.writeAll(" ") catch return error.OutOfMemory;
    }
    return .{ .count = count, .body = try out.toOwnedSlice() };
}

/// `GET /api/agent-tools/registry` → the equipped tool names, owned.
/// Python's `_registry_names`, including its "fixture broken?" guard.
fn registryNames(h: *Harness) ![][]u8 {
    var r = try h.http(io, .GET, "/api/agent-tools/registry", .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();

    const tools = doc.array("tools") orelse {
        std.debug.print("registry returned no `tools` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (tools.items) |t| {
        const obj = switch (t) {
            .object => |o| o,
            else => {
                std.debug.print("registry entry is not an object: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        const name = switch (obj.get("name") orelse {
            std.debug.print("registry entry has no name: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("registry entry name is not a string: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            },
        };
        try names.append(gpa, try gpa.dupe(u8, name));
    }

    // Python: `assert len(names) >= 1, "registry returned 0 tools"`.
    if (names.items.len == 0) {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
        std.debug.print("registry returned 0 tools - fixture broken?\n", .{});
        return error.TestUnexpectedResult;
    }
    return names.toOwnedSlice(gpa);
}

fn freeNames(names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Comma-joined tool names, for a failure message (Python's `{names!r}`).
fn renderNames(names: []const []u8) ![]u8 {
    return std.mem.join(gpa, ", ", names);
}

// ============================================================================
// Tests
// ============================================================================

// The equipped surface is `read_workspace_session` ONLY — the old name
// must never appear again (any spelling).
test "registry_exposes_new_tool_no_old_name" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const names = try registryNames(&h);
    defer freeNames(names);

    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "read_workspace_session")) found = true;
    }
    if (!found) {
        const rendered = try renderNames(names);
        defer gpa.free(rendered);
        std.debug.print("registry missing 'read_workspace_session'; got [{s}]\n", .{rendered});
        return error.TestUnexpectedResult;
    }

    const banned = [_][]const u8{ "search_history", "SearchHistory", "search-history" };
    for (banned) |b| {
        for (names) |n| {
            if (std.mem.eql(u8, n, b)) {
                const rendered = try renderNames(names);
                defer gpa.free(rendered);
                std.debug.print("registry still exposes '{s}'; got [{s}]\n", .{ b, rendered });
                return error.TestUnexpectedResult;
            }
            // `assert not any(banned in n for n in names)`.
            if (std.mem.indexOf(u8, n, b) != null) {
                const rendered = try renderNames(names);
                defer gpa.free(rendered);
                std.debug.print("registry has a tool name containing '{s}'; got [{s}]\n", .{ b, rendered });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// DELETE/POST/DELETE /api/agents/:id/tools round-trips the new name
// (it ships as a default, so DELETE first, like `command`).
test "enable_disable_round_trip" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-history");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "history-agent");
    defer gpa.free(agent_id);

    // DELETE .../tools/read_workspace_session → { "ok": true }
    const del_path = try std.fmt.allocPrint(
        gpa,
        "/api/agents/{s}/tools/read_workspace_session",
        .{agent_id},
    );
    defer gpa.free(del_path);
    {
        var r = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("first DELETE did not report ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // POST .../tools { "tool_name": "read_workspace_session" } → echo
    {
        const body =
            \\{"tool_name":"read_workspace_session"}
        ;
        const post_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
        defer gpa.free(post_path);

        var r = try h.http(io, .POST, post_path, .{
            .json_body = body,
            .expect = &.{201},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const got = doc.str("tool_name") orelse {
            std.debug.print("POST tools returned no tool_name: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got, "read_workspace_session")) {
            std.debug.print("POST tools echoed '{s}'\n", .{got});
            return error.TestUnexpectedResult;
        }
    }

    // DELETE again → { "ok": true }
    {
        var r = try h.http(io, .DELETE, del_path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("ok") != true) {
            std.debug.print("second DELETE did not report ok: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// POST `search_history` now 400s (no longer equipped).
test "legacy_name_rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-history");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id, "history-agent");
    defer gpa.free(agent_id);

    const body =
        \\{"tool_name":"search_history"}
    ;
    const post_path = try std.fmt.allocPrint(gpa, "/api/agents/{s}/tools", .{agent_id});
    defer gpa.free(post_path);

    var r = try h.http(io, .POST, post_path, .{
        .json_body = body,
        .expect = &.{400},
    });
    defer r.deinit();
}

// Two workspaces, three tasks: session.id == task.id in each, with
// disjoint user messages. This is the exact join (task → session →
// workspace) the tool scopes on.
test "tasks_seed_disjoint_sessions_per_workspace" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // --- workspace A: two tasks ---
    const ws_a = try createWorkspace(&h, "ws-a");
    defer gpa.free(ws_a);
    const kanban_a = try createKanban(&h, ws_a, "sprint-a");
    defer gpa.free(kanban_a);
    const task_a1 = try createTask(
        &h,
        ws_a,
        kanban_a,
        "Fix login bug",
        "alpha workspace login failure",
    );
    defer gpa.free(task_a1);
    const task_a2 = try createTask(
        &h,
        ws_a,
        kanban_a,
        "Login page polish",
        "alpha workspace login styling",
    );
    defer gpa.free(task_a2);

    // --- workspace B: one task ---
    const ws_b = try createWorkspace(&h, "ws-b");
    defer gpa.free(ws_b);
    const kanban_b = try createKanban(&h, ws_b, "sprint-b");
    defer gpa.free(kanban_b);
    const task_b1 = try createTask(
        &h,
        ws_b,
        kanban_b,
        "Deploy checklist",
        "beta workspace deployment steps",
    );
    defer gpa.free(task_b1);

    // session.id == task.id (the invariant workspace_scope joins on):
    // each seeded session carries at least one user message.
    {
        const tasks = [_][]const u8{ task_a1, task_a2, task_b1 };
        for (tasks) |t| {
            var msgs = try userMessages(&h, t);
            defer msgs.deinit();
            if (msgs.count < 1) {
                std.debug.print("task '{s}' seeded no user message\n", .{t});
                return error.TestUnexpectedResult;
            }
        }
    }

    // Content is per-session disjoint: the beta session's message
    // mentions deployment, the alpha sessions mention login.
    {
        var msgs_b = try userMessages(&h, task_b1);
        defer msgs_b.deinit();
        if (std.mem.indexOf(u8, msgs_b.body, "deployment") == null) {
            std.debug.print("beta session lost its seed: '{s}'\n", .{msgs_b.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        const tasks = [_][]const u8{ task_a1, task_a2 };
        for (tasks) |t| {
            var msgs_a = try userMessages(&h, t);
            defer msgs_a.deinit();
            if (std.mem.indexOf(u8, msgs_a.body, "login") == null) {
                std.debug.print("alpha session lost its seed: '{s}'\n", .{msgs_a.body});
                return error.TestUnexpectedResult;
            }
            if (std.mem.indexOf(u8, msgs_a.body, "deployment") != null) {
                std.debug.print(
                    "cross-workspace content leak over HTTP: '{s}'\n",
                    .{msgs_a.body},
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}
