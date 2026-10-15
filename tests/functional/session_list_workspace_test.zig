// Workspace-scoped session list + session-detail workspace_id (wire). Zig
// port of `tests/functional/session_list_workspace_test.py` (same test names,
// same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// Monotonic milliseconds (`.awake`, not the wall clock — an NTP step
/// must not extend a poll deadline).
fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

// ============================================================================
// Helpers (mirror agent_workspace_history_test.zig)
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
    return gpa.dupe(u8, doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    });
}

/// Kanban item WITH a `path` — the path is what the cwd-matching scope
/// resolver prefix-matches plain-chat cwds against.
fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8, path: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = path,
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("kanban create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, switch (item.get("id") orelse {
        std.debug.print("kanban create item has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("kanban create item id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    });
}

/// POST mode='create_session' — session.id == task.id (the exact
/// task→session→workspace join the scope resolver reads).
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

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ workspace_id, kanban_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("task create returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, switch (task.get("id") orelse {
        std.debug.print("task create returned a task with no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task create id is not a string: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        },
    });
}

/// Poll `GET /api/llm/session/:id` until the row exists (200). Also exercises
/// the detail route on every seed: 404 while the async insert is still in
/// flight, 200 once landed.
fn waitForSession(h: *Harness, session_id: []const u8, timeout_ms: i64) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);

    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        var r = try h.http(io, .GET, path, .{
            .expect = &.{ 200, 404 },
            .assert_status = false,
        });
        defer r.deinit();
        if (r.status == 200) {
            var doc = try r.json();
            defer doc.deinit();
            const echoed = doc.str("session_id") orelse {
                std.debug.print("session detail has no `session_id`: {s}\n", .{r.body});
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, echoed, session_id)) {
                std.debug.print("detail echoed '{s}', expected '{s}'\n", .{ echoed, session_id });
                return error.TestUnexpectedResult;
            }
            return;
        }
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    std.debug.print(
        "session {s} did not appear within {d}s\n",
        .{ session_id, @divTrunc(timeout_ms, 1000) },
    );
    return error.TestUnexpectedResult;
}

/// Plain chat via POST /api/llm/session. `cwd_session` is the body field
/// `session_create.zig` reads for the working directory.
fn createPlainSession(h: *Harness, name: []const u8, cwd: []const u8) ![]u8 {
    const suffix = try harness.randomSuffix(gpa);
    defer gpa.free(suffix);
    // `randomSuffix` formats a u64 with `{x}`, which DROPS leading zeros,
    // so the result is 1..16 hex characters rather than always 16. Truncating
    // with a constant slice therefore panics on roughly 1-in-16 runs.
    const hex = suffix[0..@min(16, suffix.len)];
    const sid = try std.fmt.allocPrint(gpa, "sess_test_{s}", .{hex});
    // `errdefer`, NOT `defer`: this slice IS the return value, so a plain
    // `defer` frees it before the caller ever reads it (and `Seed.deinit`
    // then frees it a second time).
    errdefer gpa.free(sid);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .session_id = sid,
        .session_name = name,
        .cwd_session = cwd,
    }, .{});
    defer gpa.free(body);

    // Strict 201, as the Python original: the response is inspected
    // immediately below, so a 500 would fail anyway — and failing at the
    // status check names the status rather than the echo mismatch.
    var r = try h.http(io, .POST, "/api/llm/session", .{
        .json_body = body,
        .expect = &.{201},
    });
    defer r.deinit();
    {
        var doc = try r.json();
        defer doc.deinit();
        const echoed = doc.str("id") orelse {
            std.debug.print("plain session create returned no id: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, echoed, sid)) {
            std.debug.print("create echoed '{s}', expected '{s}'\n", .{ echoed, sid });
            return error.TestUnexpectedResult;
        }
    }

    try waitForSession(h, sid, 5_000);
    return sid;
}

/// `GET /api/llm/session` with `params`. The caller owns the
/// `Response` and MUST keep it alive for any `Json` parsed from it.
fn listSessions(h: *Harness, params: []const harness.Harness.Param) !harness.Response {
    return h.http(io, .GET, "/api/llm/session", .{ .params = params, .expect = &.{200} });
}

/// The `session_id` of every row in `sessions[]`, as OWNED strings. Borrowed
/// JSON cannot outlive the `Response` it was parsed from, so this duplicates.
fn collectSessionIds(doc: *const harness.Json) ![][]u8 {
    const sessions = doc.array("sessions") orelse {
        std.debug.print("session list has no `sessions` array\n", .{});
        return error.TestUnexpectedResult;
    };
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    for (sessions.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const sid = switch (o.get("session_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try gpa.dupe(u8, sid));
    }
    return out.toOwnedSlice(gpa);
}

fn freeIds(ids: [][]u8) void {
    for (ids) |id| gpa.free(id);
    gpa.free(ids);
}

/// Order-independent set equality — Python's `ids == {a, b, c}`.
fn setEquals(got: []const []u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, w)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn containsId(ids: []const []u8, id: []const u8) bool {
    for (ids) |g| {
        if (std.mem.eql(u8, g, id)) return true;
    }
    return false;
}

/// Render ids for a failure message (Python's `{sorted(ids)!r}`).
fn renderIds(ids: []const []u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    for (ids, 0..) |id, i| {
        if (i > 0) buf.writer.writeAll(", ") catch return error.OutOfMemory;
        buf.writer.print("'{s}'", .{id}) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice();
}

/// Assert the Python `_list_sessions` shape: `sessions` is a list and
/// `total` is an int.
fn listShapeIsSane(doc: *const harness.Json) !void {
    if (doc.array("sessions") == null) {
        std.debug.print("bad list shape: `sessions` is not an array\n", .{});
        return error.TestUnexpectedResult;
    }
    if (doc.int("total") == null) {
        std.debug.print("missing integer `total`\n", .{});
        return error.TestUnexpectedResult;
    }
}

/// The two workspaces' seeded ids. Owned; `deinit` releases them.
const Seed = struct {
    ws_a: []u8,
    ws_b: []u8,
    task_a1: []u8,
    task_a2: []u8,
    plain_a: []u8,
    task_b1: []u8,

    fn deinit(self: *Seed) void {
        gpa.free(self.ws_a);
        gpa.free(self.ws_b);
        gpa.free(self.task_a1);
        gpa.free(self.task_a2);
        gpa.free(self.plain_a);
        gpa.free(self.task_b1);
        self.* = undefined;
    }
};

/// Two workspaces with disjoint sessions: A: task_a1 + task_a2 (task-linked)
/// + plain_a (cwd under A's item path) -> 3 sessions B: task_b1 (task-linked)
/// -> 1 session The item paths are derived from `h.temp_dir`; see the header
fn seed(h: *Harness) !Seed {
    const proj_a = try harness.harnessPath(gpa, h.temp_dir, &.{"proj/a"});
    defer gpa.free(proj_a);
    const proj_a_sub = try harness.harnessPath(gpa, h.temp_dir, &.{"proj/a/sub"});
    defer gpa.free(proj_a_sub);
    const proj_b = try harness.harnessPath(gpa, h.temp_dir, &.{"proj/b"});
    defer gpa.free(proj_b);

    var out: Seed = .{
        .ws_a = undefined,
        .ws_b = undefined,
        .task_a1 = undefined,
        .task_a2 = undefined,
        .plain_a = undefined,
        .task_b1 = undefined,
    };
    errdefer out.deinit();

    out.ws_a = try createWorkspace(h, "scoped-ws-a");
    const kanban_a = try createKanban(h, out.ws_a, "sprint-a", proj_a);
    defer gpa.free(kanban_a);
    out.task_a1 = try createTask(h, out.ws_a, kanban_a, "Alpha one", "alpha workspace first task");
    out.task_a2 = try createTask(h, out.ws_a, kanban_a, "Alpha two", "alpha workspace second task");
    out.plain_a = try createPlainSession(h, "plain-under-a", proj_a_sub);

    out.ws_b = try createWorkspace(h, "scoped-ws-b");
    const kanban_b = try createKanban(h, out.ws_b, "sprint-b", proj_b);
    defer gpa.free(kanban_b);
    out.task_b1 = try createTask(h, out.ws_b, kanban_b, "Beta one", "beta workspace only task");

    return out;
}

// ============================================================================
// Tests: GET /api/llm/session?workspace_id=...
// ============================================================================

// Leak test: workspace_id=A returns A's 2 task sessions + the
// cwd-matched plain chat, never B's id, and total == 3 (the count query
// must carry the same filter — total must NOT stay global).
test "workspace_a_scope_includes_tasks_and_cwd_chat_excludes_b" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    var r = try listSessions(&h, &.{
        .{ .name = "workspace_id", .value = ids.ws_a },
        .{ .name = "limit", .value = "50" },
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try listShapeIsSane(&doc);

    const got = try collectSessionIds(&doc);
    defer freeIds(got);

    const want = [_][]const u8{ ids.task_a1, ids.task_a2, ids.plain_a };
    if (!setEquals(got, &want)) {
        const seen = try renderIds(got);
        defer gpa.free(seen);
        std.debug.print("workspace A scope wrong: [{s}]\n", .{seen});
        return error.TestUnexpectedResult;
    }
    if (containsId(got, ids.task_b1)) {
        std.debug.print("workspace B's session {s} leaked into A\n", .{ids.task_b1});
        return error.TestUnexpectedResult;
    }
    const total = doc.int("total").?;
    if (total != 3) {
        std.debug.print("total must match the scope, got {d}\n", .{total});
        return error.TestUnexpectedResult;
    }
}

test "workspace_b_scope_returns_only_b" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    var r = try listSessions(&h, &.{
        .{ .name = "workspace_id", .value = ids.ws_b },
        .{ .name = "limit", .value = "50" },
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try listShapeIsSane(&doc);

    const got = try collectSessionIds(&doc);
    defer freeIds(got);

    const want = [_][]const u8{ids.task_b1};
    if (!setEquals(got, &want)) {
        const seen = try renderIds(got);
        defer gpa.free(seen);
        std.debug.print("workspace B scope wrong: [{s}]\n", .{seen});
        return error.TestUnexpectedResult;
    }
    const total = doc.int("total").?;
    if (total != 1) {
        std.debug.print("total must be 1, got {d}\n", .{total});
        return error.TestUnexpectedResult;
    }
}

test "unknown_workspace_id_fails_closed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    var r = try listSessions(&h, &.{
        .{ .name = "workspace_id", .value = "nope" },
        .{ .name = "limit", .value = "50" },
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try listShapeIsSane(&doc);

    const sessions = doc.array("sessions").?;
    if (sessions.items.len != 0) {
        std.debug.print("unknown scope must be empty, got {d} sessions\n", .{sessions.items.len});
        return error.TestUnexpectedResult;
    }
    const total = doc.int("total").?;
    if (total != 0) {
        std.debug.print("unknown scope total must be 0, got {d}\n", .{total});
        return error.TestUnexpectedResult;
    }

    const got = try collectSessionIds(&doc);
    defer freeIds(got);
    if (containsId(got, ids.task_a1)) {
        std.debug.print("unknown scope still returned {s}\n", .{ids.task_a1});
        return error.TestUnexpectedResult;
    }
}

// `workspace_id=` (present but empty) must NOT behave like the param
// being absent — fail closed instead of leaking the global list (guards
// the `IN ()` / empty-bind bug classes).
test "empty_workspace_id_fails_closed" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    var r = try listSessions(&h, &.{
        .{ .name = "workspace_id", .value = "" },
        .{ .name = "limit", .value = "50" },
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try listShapeIsSane(&doc);

    const sessions = doc.array("sessions").?;
    if (sessions.items.len != 0) {
        std.debug.print("empty scope must be empty, got {d} sessions\n", .{sessions.items.len});
        return error.TestUnexpectedResult;
    }
    const total = doc.int("total").?;
    if (total != 0) {
        std.debug.print("empty scope total must be 0, got {d}\n", .{total});
        return error.TestUnexpectedResult;
    }
}

// Global back-compat: without the param the list is unscoped.
test "absent_workspace_id_returns_all_sessions" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    var r = try listSessions(&h, &.{.{ .name = "limit", .value = "50" }});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try listShapeIsSane(&doc);

    const got = try collectSessionIds(&doc);
    defer freeIds(got);

    const want = [_][]const u8{ ids.task_a1, ids.task_a2, ids.plain_a, ids.task_b1 };
    if (!setEquals(got, &want)) {
        const seen = try renderIds(got);
        defer gpa.free(seen);
        std.debug.print("global list wrong: [{s}]\n", .{seen});
        return error.TestUnexpectedResult;
    }
    const total = doc.int("total").?;
    if (total != 4) {
        std.debug.print("global total must be 4, got {d}\n", .{total});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests: GET /api/llm/session/:session_id -> workspace_id
// ============================================================================

// Detail workspace_id: task-linked session -> A, cwd-matched plain
// chat -> A, session outside every workspace -> null.
test "session_detail_returns_owning_workspace_id" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    // A chat whose cwd matches no workspace item at all.
    const elsewhere = try harness.harnessPath(gpa, h.temp_dir, &.{"elsewhere"});
    defer gpa.free(elsewhere);
    const outside = try createPlainSession(&h, "outside-chat", elsewhere);
    defer gpa.free(outside);

    const pairs = [_]struct { sid: []const u8, ws: []const u8 }{
        .{ .sid = ids.task_a1, .ws = ids.ws_a },
        .{ .sid = ids.plain_a, .ws = ids.ws_a },
    };
    for (pairs) |p| {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{p.sid});
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const echoed = doc.str("session_id") orelse {
            std.debug.print("detail has no `session_id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, echoed, p.sid)) {
            std.debug.print("detail echoed '{s}', expected '{s}'\n", .{ echoed, p.sid });
            return error.TestUnexpectedResult;
        }
        const got_ws = doc.str("workspace_id") orelse {
            std.debug.print(
                "session {s} must resolve to a workspace; got no `workspace_id`: {s}\n",
                .{ p.sid, r.body },
            );
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got_ws, p.ws)) {
            std.debug.print(
                "session {s} resolved to workspace '{s}', expected '{s}'\n",
                .{ p.sid, got_ws, p.ws },
            );
            return error.TestUnexpectedResult;
        }
    }

    // Outside every workspace -> JSON null, NOT the empty string and NOT
    // a missing key.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{outside});
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const echoed = doc.str("session_id") orelse {
            std.debug.print("detail has no `session_id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, echoed, outside)) {
            std.debug.print("detail echoed '{s}', expected '{s}'\n", .{ echoed, outside });
            return error.TestUnexpectedResult;
        }
        const ws = doc.get("workspace_id") orelse {
            std.debug.print(
                "session outside every workspace must carry a null `workspace_id`: {s}\n",
                .{r.body},
            );
            return error.TestUnexpectedResult;
        };
        switch (ws) {
            .null => {},
            else => {
                std.debug.print(
                    "session outside every workspace must be null, got {s}: {s}\n",
                    .{ @tagName(ws), r.body },
                );
                return error.TestUnexpectedResult;
            },
        }
    }
}

// ============================================================================
// Test: GET /api/workspaces -> items_count
// ============================================================================

/// `items_count` of the workspace row with `id == ws_id`. Borrowed from
/// `doc`.
fn workspaceItemsCount(doc: *const harness.Json, ws_id: []const u8) !i64 {
    const arr = doc.array("workspaces") orelse {
        std.debug.print("workspace list has no `workspaces` array\n", .{});
        return error.TestUnexpectedResult;
    };
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const id = switch (o.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, id, ws_id)) continue;
        // The `orelse { ... }.integer` spelling does not parse — a block
        // expression followed by a field access needs its own parens, and
        // the switch form reads better anyway.
        return switch (o.get("items_count") orelse {
            std.debug.print("workspace {s} has no `items_count`\n", .{ws_id});
            return error.TestUnexpectedResult;
        }) {
            .integer => |i| i,
            else => {
                std.debug.print("workspace {s}: `items_count` is not an integer\n", .{ws_id});
                return error.TestUnexpectedResult;
            },
        };
    }
    std.debug.print("workspace {s} is missing from the list\n", .{ws_id});
    return error.TestUnexpectedResult;
}

/// Cross-check the badge against the authoritative list rather than trusting
/// it: `GET /api/workspaces/<id>/items` must report the same `count`, and
/// exactly one of its rows must be the system default (`is_default == 1`,
fn assertWorkspaceItems(h: *Harness, ws_id: []const u8, expected: i64) !void {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const count = doc.int("count") orelse {
        std.debug.print("{s}: items list has no integer `count`: {s}\n", .{ ws_id, r.body });
        return error.TestUnexpectedResult;
    };
    if (count != expected) {
        std.debug.print("{s}: expected items count {d}, got {d}\n", .{ ws_id, expected, count });
        return error.TestUnexpectedResult;
    }

    const items = doc.array("items") orelse {
        std.debug.print("{s}: items list has no `items` array: {s}\n", .{ ws_id, r.body });
        return error.TestUnexpectedResult;
    };
    var defaults: usize = 0;
    for (items.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        // `is_default` is 0/1 on the wire, not a JSON boolean — the
        // same contract `default_workspace_provisioning_test.zig` pins.
        const is_default = switch (o.get("is_default") orelse continue) {
            .integer => |i| i,
            else => continue,
        };
        if (is_default != 1) continue;
        defaults += 1;
        const item_type = switch (o.get("item_type") orelse {
            std.debug.print("{s}: default item has no `item_type`\n", .{ws_id});
            return error.TestUnexpectedResult;
        }) {
            .string => |s| s,
            else => {
                std.debug.print("{s}: default item `item_type` is not a string\n", .{ws_id});
                return error.TestUnexpectedResult;
            },
        };
        if (!std.mem.eql(u8, item_type, "agent")) {
            std.debug.print("{s}: default item_type is '{s}', expected 'agent'\n", .{ ws_id, item_type });
            return error.TestUnexpectedResult;
        }
    }
    if (defaults != 1) {
        std.debug.print("{s}: expected exactly 1 default item, found {d}\n", .{ ws_id, defaults });
        return error.TestUnexpectedResult;
    }
}

// Every workspace row carries `items_count` (its workspace_items row count),
// whether or not is_include_items fetches the rows.
test "workspaces_list_carries_items_count" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var ids = try seed(&h);
    defer ids.deinit();

    const empty_ws = try createWorkspace(&h, "no-items-ws");
    defer gpa.free(empty_ws);

    // One seeded kanban per workspace, plus the default.
    const expected: i64 = 2;
    // The "no items" workspace has only the default.
    const expected_empty: i64 = 1;

    {
        var r = try h.http(io, .GET, "/api/workspaces", .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const a = try workspaceItemsCount(&doc, ids.ws_a);
        if (a != expected) {
            std.debug.print("{s}: items_count must be {d}, got {d}\n", .{ ids.ws_a, expected, a });
            return error.TestUnexpectedResult;
        }
        const b = try workspaceItemsCount(&doc, ids.ws_b);
        if (b != expected) {
            std.debug.print("{s}: items_count must be {d}, got {d}\n", .{ ids.ws_b, expected, b });
            return error.TestUnexpectedResult;
        }
        const e = try workspaceItemsCount(&doc, empty_ws);
        if (e != expected_empty) {
            std.debug.print(
                "{s}: items_count must be {d}, got {d}\n",
                .{ empty_ws, expected_empty, e },
            );
            return error.TestUnexpectedResult;
        }
    }

    // Cross-check against the authoritative list rather than trusting the
    // badge: the count and the rows must agree, and there must be
    // exactly one default among them.
    try assertWorkspaceItems(&h, ids.ws_a, expected);
    try assertWorkspaceItems(&h, ids.ws_b, expected);
    try assertWorkspaceItems(&h, empty_ws, expected_empty);

    // Same badge with the items skipped (lazy-load path).
    {
        var r = try h.http(io, .GET, "/api/workspaces", .{
            .params = &.{.{ .name = "is_include_items", .value = "false" }},
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();

        const a = try workspaceItemsCount(&doc, ids.ws_a);
        if (a != expected) {
            std.debug.print(
                "lazy path: {s}: items_count must be {d}, got {d}\n",
                .{ ids.ws_a, expected, a },
            );
            return error.TestUnexpectedResult;
        }
        const e = try workspaceItemsCount(&doc, empty_ws);
        if (e != expected_empty) {
            std.debug.print(
                "lazy path: {s}: items_count must be {d}, got {d}\n",
                .{ empty_ws, expected_empty, e },
            );
            return error.TestUnexpectedResult;
        }

        const arr = doc.array("workspaces").?;
        for (arr.items) |item| {
            const o = switch (item) {
                .object => |m| m,
                else => {
                    std.debug.print("workspace row is not an object\n", .{});
                    return error.TestUnexpectedResult;
                },
            };
            const items = o.get("items") orelse {
                std.debug.print("workspace row has no `items` array\n", .{});
                return error.TestUnexpectedResult;
            };
            const list = switch (items) {
                .array => |maybe_items| maybe_items,
                else => {
                    std.debug.print("workspace `items` is not an array\n", .{});
                    return error.TestUnexpectedResult;
                },
            };
            if (list.items.len != 0) {
                std.debug.print(
                    "is_include_items=false must return empty items arrays; got {d}\n",
                    .{list.items.len},
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = nowMs;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTask;
    _ = waitForSession;
    _ = createPlainSession;
    _ = listSessions;
    _ = collectSessionIds;
    _ = freeIds;
    _ = setEquals;
    _ = containsId;
    _ = renderIds;
    _ = listShapeIsSane;
    _ = Seed.deinit;
    _ = seed;
    _ = workspaceItemsCount;
    _ = assertWorkspaceItems;
}
