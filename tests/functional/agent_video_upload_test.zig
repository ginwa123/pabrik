// Functional tests for full video upload to LLM (Migration 090). Zig port of
// `tests/functional/agent_video_upload_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// Small base64 stubs — the backend never decodes these.
const MP4 = "data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDE=";
const WEBM = "data:video/webm;base64,GkXfo59ChoEBQveBAULygQRC84E";
const MOV = "data:video/quicktime;base64,AAAAIGZ0eXBxdCA=";

// ============================================================================
// Helpers
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
}

/// `POST /api/workspaces {"name": ...}` → the new workspace's id. Owned.
fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("workspace create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST /api/workspaces/<ws>/items/kanban {"name", "path"}` → item id.
/// Owned.
fn createKanban(h: *Harness, workspace_id: []const u8) ![]u8 {
    const board_path = try harness.harnessPath(gpa, h.temp_dir, &.{"video-test"});
    defer gpa.free(board_path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "board",
        .path = board_path,
    }, .{});
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

/// `POST .../kanban/tasks` → the WHOLE response body, owned. `expect`
/// carries the status so the two 400 cases reuse this helper.
fn createTaskBody(
    h: *Harness,
    ws: []const u8,
    kb: []const u8,
    json_body: []const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/kanban/tasks",
        .{ ws, kb },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `PUT .../tasks/<task_id>` → the whole response body, owned.
fn updateTaskBody(
    h: *Harness,
    ws: []const u8,
    kb: []const u8,
    task_id: []const u8,
    json_body: []const u8,
    expect: []const u16,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws, kb, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{ .json_body = json_body, .expect = expect });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET .../tasks/<task_id>` → the WHOLE `{"task": {...}}` body. Owned.
fn getTaskBody(h: *Harness, ws: []const u8, kb: []const u8, task_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws, kb, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET .../tasks/<task_id>/media` → the WHOLE media body, owned. The lazy
/// media payload (media-flags change).
fn getTaskMediaBody(h: *Harness, ws: []const u8, kb: []const u8, task_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/media",
        .{ ws, kb, task_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `body["task"]["id"]` from an owned create/update response. Owned.
fn taskId(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const task = doc.object("task") orelse {
        std.debug.print("no `task` in: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("task has no `id`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("task `id` is not a string: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// `body["session"]["id"]` from an owned task-create response. Owned.
fn sessionId(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const session = doc.object("session") orelse {
        std.debug.print("no `session` in: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    const id = switch (session.get("id") orelse {
        std.debug.print("session has no `id`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => {
            std.debug.print("session `id` is not a string: {s}\n", .{body});
            return error.TestUnexpectedResult;
        },
    };
    return gpa.dupe(u8, id);
}

/// Poll session messages until a user row appears (async worker drain), then
/// report whether any user row's `video_url` contains `needle`.
fn userMessageHasVideo(h: *Harness, session_id: []const u8, needle: []const u8, timeout_s: f64) !bool {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/messages", .{session_id});
    defer gpa.free(path);

    const deadline = std.Io.Timestamp.now(io, .awake).toMilliseconds() +
        @as(i64, @intFromFloat(timeout_s * 1000.0));

    var saw_user_row = false;
    var hit = false;
    while (true) {
        var r = try h.http(io, .GET, path, .{
            // `params` values are percent-encoded by the harness; none of
            // these three need escaping, so they land verbatim.
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
            std.debug.print("messages response has no `messages`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        for (msgs.items) |m| {
            const o = switch (m) {
                .object => |x| x,
                else => continue,
            };
            const role = switch (o.get("role") orelse continue) {
                .string => |x| x,
                else => continue,
            };
            if (!std.mem.eql(u8, role, "user")) continue;
            saw_user_row = true;
            const video = switch (o.get("video_url") orelse continue) {
                .string => |x| x,
                else => continue,
            };
            if (std.mem.indexOf(u8, video, needle) != null) hit = true;
        }
        if (saw_user_row) break;
        if (std.Io.Timestamp.now(io, .awake).toMilliseconds() > deadline) break;
        std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    }

    if (!saw_user_row) {
        std.debug.print("no user message ever landed for session {s}\n", .{session_id});
        return error.TestUnexpectedResult;
    }
    if (!hit) {
        std.debug.print("no user message carries \"{s}\" in its video_url\n", .{needle});
    }
    return hit;
}

/// Python `assert obj[key] is True` — strict.
fn expectTrue(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!got) {
        std.debug.print("{s}: `{s}` is false, expected true\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] is False` — strict.
fn expectFalse(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (got) {
        std.debug.print("{s}: `{s}` is true, expected false\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert obj[key] == want` for a string field.
fn expectStr(obj: std.json.ObjectMap, key: []const u8, want: []const u8, ctx: []const u8) !void {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    const got = switch (v) {
        .string => |x| x,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: `{s}` = \"{s}\", expected \"{s}\"\n", .{ ctx, key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// Python `assert key not in obj` — prints the sorted key list on
/// failure, exactly as `sorted(task)` did.
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
// Tests
// ============================================================================

// Create with a video -> the flag is set and `/media` round-trips it.
test "create_task_with_mp4_echoes_video_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "clip",
        .video_urls = MP4,
    }, .{});
    defer gpa.free(body);

    const resp_raw = try createTaskBody(&h, ws, kb, body, &.{201});
    defer gpa.free(resp_raw);

    {
        var doc = try parseJson(resp_raw);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{resp_raw});
            return error.TestUnexpectedResult;
        };
        // The create response carries the flag, not the payload — asserting
        // `task["video_urls"]` here is what broke when the media-flags change
        // moved the full string to the lazy /media route.
        try expectTrue(task, "is_have_video", "create response task");
        try expectKeyAbsent(task, "video_urls", "create response should stay flag-only");
    }

    const tid = try taskId(resp_raw);
    defer gpa.free(tid);

    {
        const media_raw = try getTaskMediaBody(&h, ws, kb, tid);
        defer gpa.free(media_raw);
        var doc = try parseJson(media_raw);
        defer doc.deinit();
        const map = switch (doc.value().*) {
            .object => |o| o,
            else => {
                std.debug.print("media response is not an object: {s}\n", .{media_raw});
                return error.TestUnexpectedResult;
            },
        };
        try expectStr(map, "video_urls", MP4, "media response");
    }

    // GET-by-id keeps the same flag-only contract.
    {
        const row_raw = try getTaskBody(&h, ws, kb, tid);
        defer gpa.free(row_raw);
        var doc = try parseJson(row_raw);
        defer doc.deinit();
        const row = doc.object("task") orelse {
            std.debug.print("task GET returned no `task`: {s}\n", .{row_raw});
            return error.TestUnexpectedResult;
        };
        try expectTrue(row, "is_have_video", "task GET");
        try expectKeyAbsent(row, "video_urls", "task GET should stay flag-only");
    }
}

// Three data URLs join with `||` and survive the round-trip intact.
test "create_task_with_multiple_video_mimes" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const joined = try std.fmt.allocPrint(gpa, "{s}||{s}||{s}", .{ MP4, WEBM, MOV });
    defer gpa.free(joined);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "clips",
        .video_urls = joined,
    }, .{});
    defer gpa.free(body);

    const resp_raw = try createTaskBody(&h, ws, kb, body, &.{201});
    defer gpa.free(resp_raw);
    {
        var doc = try parseJson(resp_raw);
        defer doc.deinit();
        const task = doc.object("task") orelse {
            std.debug.print("expected task object, got: {s}\n", .{resp_raw});
            return error.TestUnexpectedResult;
        };
        try expectTrue(task, "is_have_video", "create response task");
    }
    const tid = try taskId(resp_raw);
    defer gpa.free(tid);

    const media_raw = try getTaskMediaBody(&h, ws, kb, tid);
    defer gpa.free(media_raw);
    var doc = try parseJson(media_raw);
    defer doc.deinit();
    const map = switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("media response is not an object: {s}\n", .{media_raw});
            return error.TestUnexpectedResult;
        },
    };
    try expectStr(map, "video_urls", joined, "media response");
}

// An image mime in the video column is a 400 — the wrong column.
test "create_task_rejects_image_mime_in_video_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "wrong-col",
        .video_urls = "data:image/png;base64,iVBORw0=",
    }, .{});
    defer gpa.free(body);

    const rejected = try createTaskBody(&h, ws, kb, body, &.{400});
    defer gpa.free(rejected);
}

// `video/ogg` is a real mime that is not on the allowlist.
test "create_task_rejects_disallowed_video_mime" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "ogg",
        .video_urls = "data:video/ogg;base64,T2dnUw==",
    }, .{});
    defer gpa.free(body);

    const rejected = try createTaskBody(&h, ws, kb, body, &.{400});
    defer gpa.free(rejected);
}

// PUT sets the payload, PUT "" clears it, and the flag tracks both.
test "update_task_sets_and_clears_video_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const create_body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "patchme",
    }, .{});
    defer gpa.free(create_body);

    const resp_raw = try createTaskBody(&h, ws, kb, create_body, &.{201});
    defer gpa.free(resp_raw);
    const tid = try taskId(resp_raw);
    defer gpa.free(tid);

    // Bare: no video, no flag.
    {
        const media_raw = try getTaskMediaBody(&h, ws, kb, tid);
        defer gpa.free(media_raw);
        var doc = try parseJson(media_raw);
        defer doc.deinit();
        const map = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        try expectStr(map, "video_urls", "", "media before any PUT");
    }
    {
        const row_raw = try getTaskBody(&h, ws, kb, tid);
        defer gpa.free(row_raw);
        var doc = try parseJson(row_raw);
        defer doc.deinit();
        const row = doc.object("task") orelse {
            std.debug.print("task GET returned no `task`: {s}\n", .{row_raw});
            return error.TestUnexpectedResult;
        };
        try expectFalse(row, "is_have_video", "task GET before any PUT");
    }

    {
        const put_body = try std.json.Stringify.valueAlloc(gpa, .{ .video_urls = MP4 }, .{});
        defer gpa.free(put_body);
        const put_raw = try updateTaskBody(&h, ws, kb, tid, put_body, &.{200});
        defer gpa.free(put_raw);
    }
    {
        const media_raw = try getTaskMediaBody(&h, ws, kb, tid);
        defer gpa.free(media_raw);
        var doc = try parseJson(media_raw);
        defer doc.deinit();
        const map = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        try expectStr(map, "video_urls", MP4, "media after PUT");
    }
    {
        const row_raw = try getTaskBody(&h, ws, kb, tid);
        defer gpa.free(row_raw);
        var doc = try parseJson(row_raw);
        defer doc.deinit();
        const row = doc.object("task") orelse {
            std.debug.print("task GET returned no `task`: {s}\n", .{row_raw});
            return error.TestUnexpectedResult;
        };
        try expectTrue(row, "is_have_video", "task GET after PUT");
    }

    // Empty string clears (SQL '' literal — must NOT 500 on NOT NULL).
    {
        const clear_body = try std.json.Stringify.valueAlloc(gpa, .{ .video_urls = "" }, .{});
        defer gpa.free(clear_body);
        const cleared = try updateTaskBody(&h, ws, kb, tid, clear_body, &.{200});
        defer gpa.free(cleared);
    }
    {
        const media_raw = try getTaskMediaBody(&h, ws, kb, tid);
        defer gpa.free(media_raw);
        var doc = try parseJson(media_raw);
        defer doc.deinit();
        const map = switch (doc.value().*) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        try expectStr(map, "video_urls", "", "media after empty PUT");
    }
    {
        const row_raw = try getTaskBody(&h, ws, kb, tid);
        defer gpa.free(row_raw);
        var doc = try parseJson(row_raw);
        defer doc.deinit();
        const row = doc.object("task") orelse {
            std.debug.print("task GET returned no `task`: {s}\n", .{row_raw});
            return error.TestUnexpectedResult;
        };
        try expectFalse(row, "is_have_video", "task GET after empty PUT");
    }
}

// A plain http:// URL is not a data URL and must be refused.
test "update_task_rejects_http_url_in_video_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const create_body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create",
        .name = "patchbad",
    }, .{});
    defer gpa.free(create_body);

    const resp_raw = try createTaskBody(&h, ws, kb, create_body, &.{201});
    defer gpa.free(resp_raw);
    const tid = try taskId(resp_raw);
    defer gpa.free(tid);

    const put_body = try std.json.Stringify.valueAlloc(gpa, .{
        .video_urls = "http://example.com/x.mp4",
    }, .{});
    defer gpa.free(put_body);

    const rejected = try updateTaskBody(&h, ws, kb, tid, put_body, &.{400});
    defer gpa.free(rejected);
}

// Synchronous path: mode=create_session writes the user row inline.
test "create_session_with_video_urls_attaches_them_to_user_message" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = "Bug with clip",
        .description = "See the attached clip",
        .video_urls = MP4,
    }, .{});
    defer gpa.free(body);

    const resp_raw = try createTaskBody(&h, ws, kb, body, &.{201});
    defer gpa.free(resp_raw);
    // For mode=create_session the task id IS the session id.
    const sid = try taskId(resp_raw);
    defer gpa.free(sid);

    if (!try userMessageHasVideo(&h, sid, MP4, 15.0)) {
        return error.TestUnexpectedResult;
    }
}

// The async path: create_and_run queues a message, and the worker drains
// it into llm_history with the video attached.
test "chat_send_with_video_urls_persists_to_session_messages" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "video-ws");
    defer gpa.free(ws);
    const kb = try createKanban(&h, ws);
    defer gpa.free(kb);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_and_run",
        .name = "watch this",
        .description = "see attached",
        .queue_message = "watch this",
        .video_urls = MP4,
    }, .{});
    defer gpa.free(body);

    const resp_raw = try createTaskBody(&h, ws, kb, body, &.{201});
    defer gpa.free(resp_raw);
    const sid = try sessionId(resp_raw);
    defer gpa.free(sid);

    if (!try userMessageHasVideo(&h, sid, MP4, 15.0)) {
        return error.TestUnexpectedResult;
    }
}

// `POST /api/llm/session` with `video_urls` — no workspace at all.
test "chat_send_direct_with_video_urls" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .queue_message = "look",
        .video_urls = MP4,
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const sid = doc.str("id") orelse {
        std.debug.print("session create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    if (!try userMessageHasVideo(&h, sid, MP4, 15.0)) {
        return error.TestUnexpectedResult;
    }
}

// Regression: session_create rejected bodies > 1 MB with 413. A real 1.8 MB
// mp4 base64-encodes to ~2.4 MB of JSON.
test "chat_send_with_2mb_video_body_is_accepted" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    // `"A" * (2 * 1024 * 1024)` inside the data URL — base64 text, not
    // decoded media, so the payload stays honest at 2 MB.
    const big: usize = 2 * 1024 * 1024;
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    payload.writer.writeAll("data:video/mp4;base64,") catch return error.OutOfMemory;
    {
        const block = [_]u8{'A'} ** 4096;
        var written: usize = 0;
        while (written < big) : (written += block.len) {
            payload.writer.writeAll(&block) catch return error.OutOfMemory;
        }
    }
    const video_urls = payload.toOwnedSlice() catch return error.OutOfMemory;
    defer gpa.free(video_urls);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .queue_message = "big clip",
        .video_urls = video_urls,
    }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/llm/session", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const sid = doc.str("id") orelse {
        std.debug.print("session create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };

    if (!try userMessageHasVideo(&h, sid, "data:video/mp4;base64,", 15.0)) {
        return error.TestUnexpectedResult;
    }
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = createWorkspace;
    _ = createKanban;
    _ = createTaskBody;
    _ = updateTaskBody;
    _ = getTaskBody;
    _ = getTaskMediaBody;
    _ = taskId;
    _ = sessionId;
    _ = userMessageHasVideo;
    _ = expectTrue;
    _ = expectFalse;
    _ = expectStr;
    _ = expectKeyAbsent;
    _ = renderKeys;
}
