// Renaming a chat from the sidebar context menu — "Workspace not found". Zig
// port of `tests/functional/task_rename_id_route_auth_test.py` (same test
// names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// Issue a request WITHOUT a status assertion — the caller asserts.
fn rawHttp(
    h: *Harness,
    method: harness.HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    cookie: ?[]const u8,
) !harness.Response {
    var extra: [1]harness.Header = undefined;
    const n: usize = if (cookie) |c| blk: {
        extra[0] = .{ .name = "Cookie", .value = c };
        break :blk 1;
    } else 0;
    return h.http(io, method, path, .{
        .json_body = body,
        .extra_headers = extra[0..n],
        .assert_status = false,
    });
}

/// Boot a harness with `--auth` (Python `_boot_auth`).
fn bootAuth() !Harness {
    return Harness.boot(io, gpa, .{ .extra_args = &.{"--auth"} });
}

/// Run `pabrik create-admin` against the harness HOME.
fn createAdmin(home: []const u8, email: []const u8, password: []const u8, force: bool) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "create-admin", "--email", email, "--password", password });
    if (force) try argv.append(gpa, "--force");

    var r = try harness.runPabrikCommand(io, gpa, home, argv.items, 30_000);
    defer r.deinit(gpa);
    if (r.exit_code == null or r.exit_code.? != 0) {
        std.debug.print("create-admin failed: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }
}

/// Log in and return the session token (Python `_login`).
/// `split("pabrik_session=", 1)[1].split(";", 1)[0].strip()`: the token is
/// the text BETWEEN the name and the next `;`.
fn login(h: *Harness, email: []const u8, password: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"email\":\"{s}\",\"password\":\"{s}\"}}",
        .{ email, password },
    );
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/auth/login", .{
        .json_body = body,
        .assert_status = false,
    });
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("login failed (status={d}): {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    const set_cookie = r.header("Set-Cookie") orelse "";
    if (std.mem.indexOf(u8, set_cookie, "pabrik_session=") == null) {
        std.debug.print("login sent no pabrik_session cookie: {s}\n", .{set_cookie});
        return error.TestUnexpectedResult;
    }
    var attrs = std.mem.splitSequence(u8, set_cookie, ";");
    const first_attr = attrs.next() orelse return error.TestUnexpectedResult;
    const raw_token = harness.afterFirst(first_attr, "pabrik_session=") orelse
        return error.TestUnexpectedResult;
    return gpa.dupe(u8, std.mem.trim(u8, raw_token, " \t\r\n"));
}

/// `pabrik_session=<token>` — the header value the frontend sends.
fn cookieFor(token: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "pabrik_session={s}", .{token});
}

/// The workspace → kanban → task (+ session) triple. Every string is
/// owned; the caller frees them through `deinit`.
const Seed = struct {
    ws_id: []u8,
    item_id: []u8,
    task_id: []u8,

    fn deinit(self: *Seed) void {
        gpa.free(self.ws_id);
        gpa.free(self.item_id);
        gpa.free(self.task_id);
        self.* = undefined;
    }
};

/// workspace → kanban item → task(+session). Mirrors the frontend's seed
/// path.
fn seedWorkspaceItemTask(h: *Harness, cookie: []const u8, name: []const u8) !Seed {
    // Each id is duped INSIDE the block that owns the response it was
    // read from: a `harness.Json` aliases the response body, so an id
    // carried out of the block would point at freed memory.
    const ws_id = blk: {
        const body = "{\"name\":\"rename-ws\"}";
        var r = try rawHttp(h, .POST, "/api/workspaces", body, cookie);
        defer r.deinit();
        if (r.status != 201) {
            std.debug.print("workspace create returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const id = doc.str("id") orelse {
            std.debug.print("workspace create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    errdefer gpa.free(ws_id);

    const item_id = blk: {
        const body = "{\"name\":\"sprint-rename\"}";
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{ws_id});
        defer gpa.free(path);

        var r = try rawHttp(h, .POST, path, body, cookie);
        defer r.deinit();
        if (r.status != 201) {
            std.debug.print("kanban create returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const item = doc.object("item") orelse {
            std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const id = switch (item.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        break :blk try gpa.dupe(u8, id);
    };
    errdefer gpa.free(item_id);

    const task_id = blk: {
        const body = try std.fmt.allocPrint(
            gpa,
            "{{\"mode\":\"create_session\",\"name\":\"{s}\",\"description\":\"desc\"}}",
            .{name},
        );
        defer gpa.free(body);

        const path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/tasks",
            .{ ws_id, item_id },
        );
        defer gpa.free(path);

        var r = try rawHttp(h, .POST, path, body, cookie);
        defer r.deinit();
        if (r.status != 201) {
            std.debug.print("task create returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("task create returned no `task`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const t_id = switch (task.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const session_obj = doc.object("session") orelse {
            std.debug.print("task create returned no `session`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const s_id = switch (session_obj.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        // task.id IS the session id (Migration 052 dropped the column).
        if (!std.mem.eql(u8, t_id, s_id)) {
            std.debug.print("task.id '{s}' != session.id '{s}'\n", .{ t_id, s_id });
            return error.TestUnexpectedResult;
        }
        break :blk try gpa.dupe(u8, t_id);
    };

    return .{ .ws_id = ws_id, .item_id = item_id, .task_id = task_id };
}

/// `GET .../tasks/<task_id>` → the task's `name`, owned.
fn taskName(h: *Harness, cookie: []const u8, ws_id: []const u8, item_id: []const u8, task_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws_id, item_id, task_id },
    );
    defer gpa.free(path);

    var r = try rawHttp(h, .GET, path, null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("task GET returned {d}: {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
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
            std.debug.print("task GET name is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, name);
}

/// `GET /api/llm/session/<id>` → the session's `name`, owned.
fn sessionName(h: *Harness, cookie: []const u8, session_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    var r = try rawHttp(h, .GET, path, null, cookie);
    defer r.deinit();
    if (r.status != 200) {
        std.debug.print("session GET returned {d}: {s}\n", .{ r.status, r.body });
        return error.TestUnexpectedResult;
    }
    var doc = try r.json();
    defer doc.deinit();
    const name = switch (doc.get("name") orelse {
        std.debug.print("session GET returned no `name`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("session name is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, name);
}

// ============================================================================
// Tests
// ============================================================================

// The context menu's wire body must rename, not 404, when --auth is on.
test "id_only_rename_works_with_auth_on" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "rename@example.com", "supersecret123", false);
    const token = try login(&h, "rename@example.com", "supersecret123");
    defer gpa.free(token);
    const cookie = try cookieFor(token);
    defer gpa.free(cookie);

    var seed = try seedWorkspaceItemTask(&h, cookie, "Investigate settings bug");
    defer seed.deinit();

    {
        const body = "{\"name\":\"AFTER RENAME\"}";
        const path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{seed.task_id});
        defer gpa.free(path);

        var r = try rawHttp(&h, .PUT, path, body, cookie);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("rename returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("success") != true) {
            std.debug.print("rename did not report success: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        const name = try taskName(&h, cookie, seed.ws_id, seed.item_id, seed.task_id);
        defer gpa.free(name);
        if (!std.mem.eql(u8, name, "AFTER RENAME")) {
            std.debug.print("task name after rename = '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    {
        const name = try sessionName(&h, cookie, seed.task_id);
        defer gpa.free(name);
        if (!std.mem.eql(u8, name, "AFTER RENAME")) {
            std.debug.print("session name after rename = '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

// Pins the exact failure: a stale `workspace_id` param must not 404 a rename.
// Asserted on the response BODY so a regression names itself instead of
// reading as "some 404 happened".
test "id_only_rename_is_not_a_workspace_lookup" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "stray@example.com", "supersecret123", false);
    const token = try login(&h, "stray@example.com", "supersecret123");
    defer gpa.free(token);
    const cookie = try cookieFor(token);
    defer gpa.free(cookie);

    var seed = try seedWorkspaceItemTask(&h, cookie, "Investigate settings bug");
    defer seed.deinit();

    const body = "{\"name\":\"no stray param\"}";
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{seed.task_id});
    defer gpa.free(path);

    var r = try rawHttp(&h, .PUT, path, body, cookie);
    defer r.deinit();

    if (r.status == 404) {
        std.debug.print("rename 404'd: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, r.body, "Workspace not found") != null) {
        std.debug.print(
            "the auth middleware read a `workspace_id` param the id-only route " ++
                "never declared — a failed earlier route pattern leaked it: {s}\n",
            .{r.body},
        );
        return error.TestUnexpectedResult;
    }
}

// Moving the id-only route earlier must not weaken the workspace guard.
test "scoped_rename_still_isolated_between_users" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootAuth();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    try createAdmin(h.temp_dir, "owner@example.com", "supersecret123", false);
    const owner_token = try login(&h, "owner@example.com", "supersecret123");
    defer gpa.free(owner_token);
    const owner = try cookieFor(owner_token);
    defer gpa.free(owner);

    var seed = try seedWorkspaceItemTask(&h, owner, "Investigate settings bug");
    defer seed.deinit();

    const scoped_path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ seed.ws_id, seed.item_id, seed.task_id },
    );
    defer gpa.free(scoped_path);

    // Owner's own workspace: the scoped PUT still resolves and renames.
    {
        var r = try rawHttp(&h, .PUT, scoped_path, "{\"name\":\"SCOPED RENAME\"}", owner);
        defer r.deinit();
        if (r.status != 200) {
            std.debug.print("scoped rename returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }
    {
        const name = try taskName(&h, owner, seed.ws_id, seed.item_id, seed.task_id);
        defer gpa.free(name);
        if (!std.mem.eql(u8, name, "SCOPED RENAME")) {
            std.debug.print("task name after scoped rename = '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    }

    // A second user must not be able to reach it by raw id.
    try createAdmin(h.temp_dir, "intruder@example.com", "supersecret123", true);
    const intruder_token = try login(&h, "intruder@example.com", "supersecret123");
    defer gpa.free(intruder_token);
    const intruder = try cookieFor(intruder_token);
    defer gpa.free(intruder);

    {
        var r = try rawHttp(&h, .PUT, scoped_path, "{\"name\":\"HIJACKED\"}", intruder);
        defer r.deinit();
        if (r.status != 404) {
            std.debug.print("foreign scoped rename returned {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }
    {
        const name = try taskName(&h, owner, seed.ws_id, seed.item_id, seed.task_id);
        defer gpa.free(name);
        if (!std.mem.eql(u8, name, "SCOPED RENAME")) {
            std.debug.print("the intruder's rename landed: '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

// Auth-off (the default dev setup) keeps renaming — the fix is not auth-specific.
test "id_only_rename_with_auth_off" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_body = "{\"name\":\"rename-ws\"}";
    var ws_r = try h.http(io, .POST, "/api/workspaces", .{
        .json_body = ws_body,
        .expect = &.{201},
    });
    defer ws_r.deinit();
    var ws_doc = try ws_r.json();
    defer ws_doc.deinit();
    const ws_id = blk: {
        const id = ws_doc.str("id") orelse {
            std.debug.print("workspace create returned no id: {s}\n", .{ws_r.body});
            return error.TestUnexpectedResult;
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(ws_id);

    const kanban_path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/kanban",
        .{ws_id},
    );
    defer gpa.free(kanban_path);
    const item_id = blk: {
        var r = try h.http(io, .POST, kanban_path, .{
            .json_body = "{\"name\":\"sprint-rename\"}",
            .expect = &.{201},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const item = doc.object("item") orelse {
            std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const id = switch (item.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(item_id);

    const task_id = blk: {
        const create_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/kanban/tasks",
            .{ ws_id, item_id },
        );
        defer gpa.free(create_path);

        var r = try h.http(io, .POST, create_path, .{
            .json_body =
            \\{"mode":"create_session","name":"auth off chat"}
            ,
            .expect = &.{201},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("task create returned no `task`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const id = switch (task.get("id") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        break :blk try gpa.dupe(u8, id);
    };
    defer gpa.free(task_id);

    {
        const put_path = try std.fmt.allocPrint(gpa, "/api/workspaces/tasks/{s}", .{task_id});
        defer gpa.free(put_path);

        var r = try h.http(io, .PUT, put_path, .{
            .json_body = "{\"name\":\"AFTER RENAME\"}",
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (doc.boolean("success") != true) {
            std.debug.print("auth-off rename did not report success: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    {
        const get_path = try std.fmt.allocPrint(
            gpa,
            "/api/workspaces/{s}/items/{s}/tasks/{s}",
            .{ ws_id, item_id, task_id },
        );
        defer gpa.free(get_path);

        var r = try h.http(io, .GET, get_path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("task GET returned no `task`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const name = switch (task.get("name") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, name, "AFTER RENAME")) {
            std.debug.print("auth-off task name after rename = '{s}'\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}