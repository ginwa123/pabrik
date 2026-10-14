// Functional tests for the create_session user-message fix. Zig port of
// `tests/functional/kanban_create_session_user_message_test.py` (same test
// names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// A pair of stub base64 image URLs (deliberately short — the llm_history
// column stores the full data URL string, but we only need to assert "the
// value passed in is the value stored").
const PNG_DATA_URL_1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg==";
const JPEG_DATA_URL_2 = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwA/wA/8H//2Q==";

// ============================================================================
// Helpers — wire
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`. A `harness.Json` aliases the
/// `Response` body it was parsed from, so a helper may not RETURN one.
/// Helpers below return owned bytes and each test parses locally.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// The string at `key`, or a hard failure naming the field.
fn objectStr(o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse {
        std.debug.print("missing `{s}` in response object\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("`{s}` is not a string\n", .{key});
            return error.TestUnexpectedResult;
        },
    };
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
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, id);
}

/// The wire body of `POST .../kanban/tasks`. `image_urls` is the array of
/// base64 data URLs the user pasted in the kanban detail editor.
const TaskBody = struct {
    mode: []const u8,
    name: []const u8,
    description: []const u8,
    image_urls: ?[]const u8 = null,
    queue_message: ?[]const u8 = null,
    is_auto_retry_until_stop: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
};

/// POST `/workspaces/:ws/items/:kanban/kanban/tasks`. Returns the WHOLE
/// response body, owned.
fn createTask(h: *Harness, ws: []const u8, kanban: []const u8, body: TaskBody) ![]u8 {
    const encoded = try std.json.Stringify.valueAlloc(gpa, body, .{ .emit_null_optional_fields = false });
    defer gpa.free(encoded);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws, kanban },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = encoded, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `_create_task_via_kanban_endpoint` — the shape the dialog sends. For
/// `create_and_run` the backend requires a non-empty `queue_message`
/// (validation lives in kanban_tasks_create.zig:127-135 — 400 otherwise).
fn createTaskViaKanbanEndpoint(
    h: *Harness,
    ws: []const u8,
    kanban: []const u8,
    name: []const u8,
    description: []const u8,
    mode: []const u8,
    image_urls: ?[]const u8,
) ![]u8 {
    const auto_queue = if (std.mem.eql(u8, mode, "create_and_run"))
        (if (description.len > 0)
            try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ name, description })
        else
            try gpa.dupe(u8, name))
    else
        null;
    defer if (auto_queue) |q| gpa.free(q);

    return createTask(h, ws, kanban, .{
        .mode = mode,
        .name = name,
        .description = description,
        .image_urls = image_urls,
        .queue_message = auto_queue,
    });
}

/// `resp["task"]["id"]` — owned.
fn taskIdOf(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("create response missing 'task': {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("create response task has no id: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/llm/session/:id/messages` — the llm_history rows, newest
/// first by default; we ask for created_at ASC to mirror the chat
/// render order. Returns the WHOLE response body, owned.
fn getSessionMessages(h: *Harness, session_id: []const u8) ![]u8 {
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
    return gpa.dupe(u8, r.body);
}

/// How many `messages` entries carry `role == "user"`. The bug under test is
/// specifically about a MISSING user-role row, so this is the count every
/// assertion is about.
fn userRoleCount(doc: *const harness.Json) !usize {
    const messages = doc.array("messages") orelse {
        std.debug.print("expected messages list, got: {s}\n", .{@tagName(doc.value().*)});
        return error.TestUnexpectedResult;
    };
    var n: usize = 0;
    for (messages.items) |m| {
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role == .string and std.mem.eql(u8, role.string, "user")) n += 1;
    }
    return n;
}

/// The value of `key` on the `n`-th user-role message. BORROWED from
/// `doc`, which the caller owns for the whole borrow.
fn userRoleValue(doc: *const harness.Json, n: usize, key: []const u8) ?std.json.Value {
    const messages = doc.array("messages") orelse return null;
    var seen: usize = 0;
    for (messages.items) |m| {
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        if (seen == n) return m.object.get(key);
        seen += 1;
    }
    return null;
}

/// `GET /api/llm/session/:id/messages?limit=1` → `selected_profile_model`.
/// This is the exact endpoint the chatview reads on session open.
fn getSessionSelectedProfile(h: *Harness, session_id: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);

    // Up to ~3s (30 x 0.1s) — the Python's budget, verbatim.
    for (0..30) |_| {
        var r = try h.http(io, .GET, path, .{
            .params = &.{.{ .name = "limit", .value = "1" }},
            .expect = &.{200},
        });
        defer r.deinit();

        var doc = try r.json();
        defer doc.deinit();

        const cell = doc.get("selected_profile_model") orelse {
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            continue;
        };
        switch (cell) {
            .string => |s| return try gpa.dupe(u8, s),
            .null => {},
            else => {
                std.debug.print("selected_profile_model is neither a string nor null\n", .{});
                return error.TestUnexpectedResult;
            },
        }
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    return null; // "value never became non-null" — the bug
}

// ============================================================================
// Helpers — sqlite3 CLI
// ============================================================================

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// Skip unless a `sqlite3` CLI is present and speaks `-json`.
fn requireSqlite3Cli() !void {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-json", ":memory:", "SELECT 1 AS probe;" },
    }) catch |err| {
        std.debug.print("sqlite3 CLI unavailable ({s}); skipping DB assertions\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    if (code == null or code.? != 0 or std.mem.indexOf(u8, res.stdout, "\"probe\"") == null) {
        std.debug.print("sqlite3 CLI lacks -json support (rc={?}); skipping DB assertions\n", .{code});
        return error.SkipZigTest;
    }
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try out.writer.writeByte('\'');
        try out.writer.writeByte(c);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

/// Run one statement against the harness's agent.db, return stdout (owned).
fn sqliteRun(db_path: []const u8, sql: []const u8) ![]u8 {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "-cmd", ".timeout 5000", "-json", db_path, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Read `sessions.is_auto_retry_until_stop` straight from the DB. Used to
/// prove the unattended flag itself is NOT lost by the gating fix (it must
/// land on the step-5 full INSERT instead of the useCase's bare INSERT).
const Flag = union(enum) {
    missing,
    null_,
    text: []u8,
    number: i64,
    other,

    fn deinit(self: *Flag) void {
        switch (self.*) {
            .text => |s| gpa.free(s),
            else => {},
        }
        self.* = undefined;
    }

    /// Owned; the caller frees. Every shape renders, because a failure
    /// message that has to guess is worse than one that allocates.
    fn render(self: *const Flag, alloc: std.mem.Allocator) ![]u8 {
        return switch (self.*) {
            .missing => alloc.dupe(u8, "<no row>"),
            .null_ => alloc.dupe(u8, "<null>"),
            .text => |s| alloc.dupe(u8, s),
            .number => |n| std.fmt.allocPrint(alloc, "{d}", .{n}),
            .other => alloc.dupe(u8, "<other type>"),
        };
    }

    /// Python: `flag in ("1", 1)`.
    fn isOne(self: *const Flag) bool {
        return switch (self.*) {
            .text => |s| std.mem.eql(u8, s, "1"),
            .number => |n| n == 1,
            else => false,
        };
    }
};

fn readAutoRetryFlag(temp_dir: []const u8, session_id: []const u8) !Flag {
    const db = try harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
    defer gpa.free(db);
    const lit = try sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = {s}",
        .{lit},
    );
    defer gpa.free(sql);

    const out = try sqliteRun(db, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return .missing;
    const o = switch (arr.items[0]) {
        .object => |m| m,
        else => return error.TestUnexpectedResult,
    };
    return switch (o.get("is_auto_retry_until_stop") orelse return .missing) {
        .string => |v| .{ .text = try gpa.dupe(u8, v) },
        .integer => |v| .{ .number = v },
        .float => |v| .{ .number = @intFromFloat(v) },
        .null => .null_,
        else => .other,
    };
}

// ============================================================================
// Test 1: create_session WITH description inserts one user-role row
// ============================================================================

// Regression for task_1787213354784_1.
test "create_session_with_description_inserts_user_role_row" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);
    const description = "Steps:\n1. Open file\n2. Read code\n3. Find root cause";

    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Investigate X bug",
        description,
        "create_session",
        null,
    );
    defer gpa.free(resp);

    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);
    if (!std.mem.startsWith(u8, task_id, "task_")) {
        std.debug.print("task id should start with task_, got '{s}'\n", .{task_id});
        return error.TestUnexpectedResult;
    }

    // mode='create_session' returns session.status='idle' (vs 'send' for
    // create_and_run — the wire discriminator the frontend uses).
    {
        var doc = try parseJson(resp);
        defer doc.deinit();
        const session = doc.object("session") orelse {
            std.debug.print("create_session response missing 'session': {s}\n", .{resp});
            return error.TestUnexpectedResult;
        };
        const sid = try objectStr(session, "id");
        if (!std.mem.eql(u8, sid, task_id)) {
            std.debug.print(
                "session.id should match task.id, got session.id='{s}' vs task.id='{s}'\n",
                .{ sid, task_id },
            );
            return error.TestUnexpectedResult;
        }
        const status = try objectStr(session, "status");
        if (!std.mem.eql(u8, status, "idle")) {
            std.debug.print(
                "create_session should return status='idle' (no agent triggered), got '{s}'\n",
                .{status},
            );
            return error.TestUnexpectedResult;
        }
    }

    const raw = try getSessionMessages(&h, task_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const n = try userRoleCount(&doc);
    if (n != 1) {
        std.debug.print(
            "expected exactly 1 user-role llm_history row, got {d}: {s}\n",
            .{ n, raw },
        );
        return error.TestUnexpectedResult;
    }

    const expected_content = try std.fmt.allocPrint(
        gpa,
        "Investigate X bug\n\n{s}",
        .{description},
    );
    defer gpa.free(expected_content);

    const actual = userRoleValue(&doc, 0, "content") orelse {
        std.debug.print("user-role row has no `content`: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    };
    const actual_s = switch (actual) {
        .string => |s| s,
        else => {
            std.debug.print("user-role `content` is not a string: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, actual_s, expected_content)) {
        std.debug.print(
            "user-role row content should match wire 'name\\n\\ndescription':\n" ++
                "  expected: '{s}'\n  actual:   '{s}'\n",
            .{ expected_content, actual_s },
        );
        return error.TestUnexpectedResult;
    }

    // The message must carry the standard llm_history fields.
    {
        const role = userRoleValue(&doc, 0, "role") orelse return error.TestUnexpectedResult;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) {
            std.debug.print("inserted row must have role='user': {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
        const sid = userRoleValue(&doc, 0, "session_id") orelse return error.TestUnexpectedResult;
        if (sid != .string or !std.mem.eql(u8, sid.string, task_id)) {
            std.debug.print("inserted row must have session_id == task.id: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 2: create_session EMPTY description STILL inserts a user row
// ============================================================================

// Regression for the empty-description bug (task_1787757006639_2).
test "create_session_with_empty_description_inserts_user_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);

    // The EXACT wire the dialog sends when the user types a title and
    // no description — KanbanView.handleCreateTaskSave forwards an
    // empty description verbatim (no trim, no fallback).
    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Title-only task",
        "",
        "create_session",
        null,
    );
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    const raw = try getSessionMessages(&h, task_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const n = try userRoleCount(&doc);
    if (n != 1) {
        std.debug.print(
            "title-only task must get EXACTLY 1 user-role row (the " ++
                "`description.len > 0` gate is the bug), got {d}: {s}\n",
            .{ n, raw },
        );
        return error.TestUnexpectedResult;
    }

    const actual = userRoleValue(&doc, 0, "content") orelse return error.TestUnexpectedResult;
    const actual_s = switch (actual) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    if (!std.mem.eql(u8, actual_s, "Title-only task\n\n")) {
        std.debug.print(
            "title-only user-role row should have content = name + '\\n\\n':\n" ++
                "  expected: 'Title-only task\\n\\n'\n  actual:   '{s}'\n",
            .{actual_s},
        );
        return error.TestUnexpectedResult;
    }

    const role = userRoleValue(&doc, 0, "role") orelse return error.TestUnexpectedResult;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) {
        std.debug.print("inserted row must have role='user': {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
    const sid = userRoleValue(&doc, 0, "session_id") orelse return error.TestUnexpectedResult;
    if (sid != .string or !std.mem.eql(u8, sid.string, task_id)) {
        std.debug.print("inserted row must have session_id == task.id: {s}\n", .{raw});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: image attachments are persisted on the user message
// ============================================================================

// Image attachments from the kanban detail dialog must land on the user-role
// llm_history row's `image_url` column, so the chatview can render thumbnails
// inline.
test "create_session_with_image_urls_attaches_them_to_user_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);
    const description = "See the attached screenshots";

    // `"|".join(image_urls)` — the wire shape.
    const joined = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ PNG_DATA_URL_1, JPEG_DATA_URL_2 });
    defer gpa.free(joined);

    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Bug with screenshots",
        description,
        "create_session",
        joined,
    );
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    const raw = try getSessionMessages(&h, task_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const n = try userRoleCount(&doc);
    if (n != 1) {
        std.debug.print(
            "expected exactly 1 user-role llm_history row, got {d}: {s}\n",
            .{ n, raw },
        );
        return error.TestUnexpectedResult;
    }

    // image_url is the `|`-joined concatenation of the input data URLs.
    {
        const cell = userRoleValue(&doc, 0, "image_url") orelse {
            std.debug.print("user-role row has no `image_url`: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        };
        const got = switch (cell) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, got, joined)) {
            std.debug.print(
                "user-role row's image_url should carry the joined input data URLs:\n" ++
                    "  expected: '{s}'\n  actual:   '{s}'\n",
                .{ joined, got },
            );
            return error.TestUnexpectedResult;
        }
    }

    // The text content is still the wire-format concatenation.
    {
        const cell = userRoleValue(&doc, 0, "content") orelse return error.TestUnexpectedResult;
        const got = switch (cell) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        const want = try std.fmt.allocPrint(gpa, "Bug with screenshots\n\n{s}", .{description});
        defer gpa.free(want);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print(
                "user-role row's content should match the wire format: expected '{s}', got '{s}'\n",
                .{ want, got },
            );
            return error.TestUnexpectedResult;
        }
    }

    // The task itself still carries the description (the pre-existing
    // path must not have regressed).
    {
        var create_doc = try parseJson(resp);
        defer create_doc.deinit();
        const task = create_doc.object("task") orelse return error.TestUnexpectedResult;
        const d = switch (task.get("description") orelse return error.TestUnexpectedResult) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, d, description)) {
            std.debug.print("task.description should round-trip: got '{s}'\n", .{d});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 4: image-only (empty description) still inserts a row
// ============================================================================

// The new contract fires on `description.len > 0 OR image_urls.len > 0` —
// title-only tasks with attached images must still get a user-role row
// (otherwise the chatview would land on an empty session and the user's
test "create_session_with_image_urls_only_still_inserts_user_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);

    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "Screenshots only",
        "",
        "create_session",
        PNG_DATA_URL_1,
    );
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    const raw = try getSessionMessages(&h, task_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();

    const n = try userRoleCount(&doc);
    if (n != 1) {
        std.debug.print(
            "image-only task should still get 1 user-role row (gate is " ++
                "`description.len > 0 OR image_urls_wire.len > 0`), got {d}: {s}\n",
            .{ n, raw },
        );
        return error.TestUnexpectedResult;
    }

    {
        const cell = userRoleValue(&doc, 0, "content") orelse return error.TestUnexpectedResult;
        const got = switch (cell) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, got, "Screenshots only\n\n")) {
            std.debug.print(
                "image-only user message should have name as content (with the " ++
                    "`\\n\\n` separator and an empty description), got '{s}'\n",
                .{got},
            );
            return error.TestUnexpectedResult;
        }
    }
    {
        const cell = userRoleValue(&doc, 0, "image_url") orelse return error.TestUnexpectedResult;
        const got = switch (cell) {
            .string => |s| s,
            else => return error.TestUnexpectedResult,
        };
        if (!std.mem.eql(u8, got, PNG_DATA_URL_1)) {
            std.debug.print("image_url should be the input data URL, got '{s}'\n", .{got});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Profile persistence (regression: task_1787494153778_2)
// ============================================================================

// Regression for task_1787494153778_2 ("wrong profile select"). The dialog
// ALWAYS sends is_auto_retry_until_stop ('0' or '1').
test "create_session_persists_selected_profile_model" {
    try harness.requirePabrikBin(io, gpa);
    try requireSqlite3Cli();
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);

    const resp = try createTask(&h, ws_id, kanban_id, .{
        .mode = "create_session",
        .name = "Profile persistence check",
        .description = "dialog wire with unattended on",
        // The bug's trigger: the dialog ALWAYS includes this field.
        .is_auto_retry_until_stop = "1",
        // The harness's stub profile — the only profile name that
        // exists in the test HOME's config.json.
        .selected_profile_model = "stub",
    });
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    const got = (try getSessionSelectedProfile(&h, task_id)) orelse {
        std.debug.print(
            "selected_profile_model lost on create_session wire! expected " ++
                "'stub', got <null after 3s of polling>.\n",
            .{},
        );
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, "stub")) {
        std.debug.print(
            "selected_profile_model lost on create_session wire! expected 'stub', got '{s}'\n",
            .{got},
        );
        return error.TestUnexpectedResult;
    }

    // And the unattended flag must NOT be lost by the gating — it now lands
    // via the step-5 full INSERT instead of the useCase's bare one.
    var flag = try readAutoRetryFlag(h.temp_dir, task_id);
    defer flag.deinit();
    if (!flag.isOne()) {
        const shown = try flag.render(gpa);
        defer gpa.free(shown);
        std.debug.print(
            "is_auto_retry_until_stop should be '1' (persisted by the " ++
                "step-5 full INSERT), got '{s}'\n",
            .{shown},
        );
        return error.TestUnexpectedResult;
    }
}

// Same regression for the 'Create task & run agent' button
// (mode='create_and_run') — same bare-INSERT PK race, same fix.
test "create_and_run_persists_selected_profile_model" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);

    const resp = try createTask(&h, ws_id, kanban_id, .{
        .mode = "create_and_run",
        .name = "Profile persistence run",
        .description = "dialog wire with unattended on",
        .queue_message = "Profile persistence run\n\ndialog wire with unattended on",
        .is_auto_retry_until_stop = "1",
        .selected_profile_model = "stub",
    });
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    const got = (try getSessionSelectedProfile(&h, task_id)) orelse {
        std.debug.print("selected_profile_model lost on create_and_run wire! expected 'stub', got <null>\n", .{});
        return error.TestUnexpectedResult;
    };
    defer gpa.free(got);
    if (!std.mem.eql(u8, got, "stub")) {
        std.debug.print(
            "selected_profile_model lost on create_and_run wire! expected 'stub', got '{s}'\n",
            .{got},
        );
        return error.TestUnexpectedResult;
    }
}

// Control: no selected_profile_model on the wire → GET returns '' (the
// COALESCE-on-NULL shape), NOT a stale value. Guards against a
// regression where the fix accidentally leaks a default into the column.
test "create_session_without_profile_stays_empty" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "kanban-csum-ws");
    defer gpa.free(ws_id);
    const kanban_id = try createKanban(&h, ws_id, "sprint-csum");
    defer gpa.free(kanban_id);

    const resp = try createTaskViaKanbanEndpoint(
        &h,
        ws_id,
        kanban_id,
        "No profile task",
        "",
        "create_session",
        null,
    );
    defer gpa.free(resp);
    const task_id = try taskIdOf(resp);
    defer gpa.free(task_id);

    // Python: `assert got in ("", None)` — BOTH are accepted, because the
    // helper itself returns None when the value never became non-null.
    const got = try getSessionSelectedProfile(&h, task_id);
    defer if (got) |g| gpa.free(g);
    if (got) |g| {
        if (g.len != 0) {
            std.debug.print(
                "no-profile create should leave selected_profile_model empty, got '{s}'\n",
                .{g},
            );
            return error.TestUnexpectedResult;
        }
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = objectStr;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTask;
    _ = createTaskViaKanbanEndpoint;
    _ = taskIdOf;
    _ = getSessionMessages;
    _ = userRoleCount;
    _ = userRoleValue;
    _ = getSessionSelectedProfile;
    _ = exitCode;
    _ = requireSqlite3Cli;
    _ = parseSqliteJson;
    _ = sqlLit;
    _ = sqliteRun;
    _ = readAutoRetryFlag;
    _ = Flag.deinit;
    _ = Flag.render;
    _ = Flag.isOne;
}
