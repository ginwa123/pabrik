//! Wire test: `pabrik headless documents expand` and a real `POST /api/llm/session` both resolve `/document-<id>` through the SAME function, against an isolated …

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const BODY = "# Release plan\n\n- ship the composer picker\n- keep the body\n";

fn createWorkspace(h: *Harness, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/workspaces", .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse return error.TestUnexpectedResult;
    return gpa.dupe(u8, id);
}

fn createKanban(h: *Harness, workspace_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/kanban", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse return error.TestUnexpectedResult;
    const id = (item.get("id") orelse return error.TestUnexpectedResult).string;
    return gpa.dupe(u8, id);
}

/// The task id IS the session id, which is what resolves the workspace.
fn createTask(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = "slash document expansion",
    }, .{ .emit_null_optional_fields = false });
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
    const task = doc.object("task") orelse return error.TestUnexpectedResult;
    const id = (task.get("id") orelse return error.TestUnexpectedResult).string;
    return gpa.dupe(u8, id);
}

const Run = struct {
    result: harness.RunResult,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    fn json(self: *Run) !*const std.json.Value {
        if (self.parsed == null) {
            self.parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.result.stdout, .{});
        }
        return &self.parsed.?.value;
    }

    fn deinit(self: *Run) void {
        if (self.parsed) |*p| p.deinit();
        self.result.deinit(gpa);
    }
};

fn documents(h: *Harness, argv: []const []const u8, expect_ok: bool) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &.{ "headless", "documents" });
    try full.appendSlice(gpa, argv);

    var result = try harness.runPabrikCommand(io, gpa, h.temp_dir, full.items, 60_000);

    if (expect_ok and result.exit_code != 0) {
        std.debug.print(
            "headless documents failed ({?d})\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.exit_code, result.stdout, result.stderr },
        );
        result.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    return .{ .result = result };
}

fn stringField(value: *const std.json.Value, key: []const u8) ![]const u8 {
    return (value.object.get(key) orelse return error.TestUnexpectedResult).string;
}

fn intField(value: *const std.json.Value, key: []const u8) !i64 {
    return (value.object.get(key) orelse return error.TestUnexpectedResult).integer;
}

test "headless documents expand: a /document- token becomes the document body" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "slash-doc-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "slash-doc-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "reference a document");
    defer gpa.free(session);

    var add = try documents(&h, &.{
        "doc-add", "--session", session, "--title", "Release plan", "--content", BODY,
    }, true);
    defer add.deinit();
    const added = try add.json();
    const data = added.object.get("data") orelse return error.TestUnexpectedResult;
    const doc_id = try gpa.dupe(u8, try stringField(&data, "id"));
    defer gpa.free(doc_id);

    const message = try std.fmt.allocPrint(gpa, "summarize /document-{s}", .{doc_id});
    defer gpa.free(message);

    var run = try documents(&h, &.{ "expand", "--session", session, "--message", message }, true);
    defer run.deinit();
    const expanded = try run.json();

    try testing.expectEqual(@as(i64, 1), try intField(expanded, "loaded_count"));
    try testing.expectEqual(@as(usize, 0), expanded.object.get("unknown").?.array.items.len);
    try testing.expectEqualStrings(message, expanded.object.get("message").?.string[0..message.len]);
    try testing.expect(std.mem.indexOf(u8, expanded.object.get("message").?.string, "<slash_documents>") != null);
    try testing.expect(std.mem.indexOf(u8, expanded.object.get("message").?.string, "Release plan") != null);
    try testing.expect(std.mem.indexOf(u8, expanded.object.get("message").?.string, "ship the composer picker") != null);
}

test "headless documents expand: a /document- id that names nothing stays literal and is reported" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "slash-doc-miss-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "slash-doc-miss-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "reference a missing document");
    defer gpa.free(session);

    const message = "read /document-doc_missing please";
    var run = try documents(&h, &.{ "expand", "--session", session, "--message", message }, true);
    defer run.deinit();
    const expanded = try run.json();

    try testing.expectEqual(@as(i64, 0), try intField(expanded, "loaded_count"));
    try testing.expectEqualStrings(message, try stringField(expanded, "message"));
    const unknown = expanded.object.get("unknown").?.array.items;
    try testing.expectEqual(@as(usize, 1), unknown.len);
    try testing.expectEqualStrings("doc_missing", unknown[0].string);
}

fn sendBody(session_id: []const u8, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .session_id = session_id,
        .queue_message = message,
        .cwd_session = "",
        .allowed_tools = "all",
        .image_urls = "",
        .selected_profile_model = "",
        .is_auto_retry_until_stop = "",
    }, .{});
}

fn userContentContaining(h: *Harness, session_id: []const u8, needle: []const u8) !?[]u8 {
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

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages") orelse return null;
    for (messages.array.items) |message| {
        const role = message.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        const content = message.object.get("content") orelse continue;
        if (content != .string) continue;
        if (std.mem.indexOf(u8, content.string, needle) == null) continue;
        return try gpa.dupe(u8, content.string);
    }
    return null;
}

test "a send on POST /api/llm/session hands the model the document body" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "slash-doc-send-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "slash-doc-send-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "send a document reference");
    defer gpa.free(session);

    var add = try documents(&h, &.{
        "doc-add", "--session", session, "--title", "Release plan", "--content", BODY,
    }, true);
    defer add.deinit();
    const added = try add.json();
    const data = added.object.get("data") orelse return error.TestUnexpectedResult;
    const doc_id = try gpa.dupe(u8, try stringField(&data, "id"));
    defer gpa.free(doc_id);

    const message = try std.fmt.allocPrint(gpa, "summarize /document-{s}", .{doc_id});
    defer gpa.free(message);

    const body = try sendBody(session, message);
    defer gpa.free(body);
    {
        var sent = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 201, 500 },
        });
        defer sent.deinit();
    }

    var wire: ?[]u8 = null;
    defer if (wire) |w| gpa.free(w);
    for (0..60) |_| {
        if (try userContentContaining(&h, session, "<slash_documents>")) |content| {
            wire = content;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
    }

    const got = wire orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, got, message));
    try testing.expect(std.mem.indexOf(u8, got, "<slash_documents>") != null);
    try testing.expect(std.mem.indexOf(u8, got, "title=\"Release plan\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "ship the composer picker") != null);
}
