//! The agent's `add_document` / `edit_document` must persist the BODY, which
//! lives in the object store (Migration 144 dropped the column). Drives the
//! real binary through the agent loop's own dispatch, then reads back over HTTP.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

const BODY_V1 = "# Release plan\n\n- ship the object store\n- keep the body\n";
const BODY_V2 = "# Release plan v2\n\n- the body survives an edit\n";

// ============================================================================
// Helpers
// ============================================================================

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

/// `POST .../kanban/tasks` with `mode: "create_session"` — the plain "Create
/// task" button. The task id IS the session id, which is what resolves the
/// workspace for the document tools.
fn createTask(h: *Harness, workspace_id: []const u8, kanban_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .mode = "create_session",
        .name = name,
        .description = "document body round trip",
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
    const task = doc.object("task") orelse {
        std.debug.print("task create returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = switch (task.get("id") orelse {
        std.debug.print("task create has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
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
    const v = value.object.get(key) orelse {
        std.debug.print("object has no `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => error.TestUnexpectedResult,
    };
}

/// The tool envelope nests the payload under `data`.
fn toolData(run: *Run) !std.json.Value {
    const root = try run.json();
    return root.object.get("data") orelse {
        std.debug.print("tool envelope has no `data`: {s}\n", .{run.result.stdout});
        return error.TestUnexpectedResult;
    };
}

fn expectBody(actual: []const u8, want: []const u8, what: []const u8) !void {
    if (std.mem.eql(u8, actual, want)) return;
    const shown = try harness.debugString(gpa, actual);
    defer gpa.free(shown);
    const expected = try harness.debugString(gpa, want);
    defer gpa.free(expected);
    std.debug.print("{s}: body = \"{s}\", expected \"{s}\"\n", .{ what, shown, expected });
    return error.TestUnexpectedResult;
}

/// `GET /api/workspaces/<ws>/documents/<id>` → the body the sidebar reads.
fn httpBody(h: *Harness, workspace_id: []const u8, document_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/documents/{s}",
        .{ workspace_id, document_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const document = doc.object("document") orelse {
        std.debug.print("document GET has no `document`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const content = switch (document.get("content") orelse {
        std.debug.print("document GET has no `content`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }) {
        .string => |s| s,
        else => return error.TestUnexpectedResult,
    };
    return gpa.dupe(u8, content);
}

// ============================================================================
// Tests
// ============================================================================

test "agent add_document persists the body and every read path returns it" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "doc-body-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "doc-body-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "write a document");
    defer gpa.free(session);

    // 1. The agent tool, through the real dispatch.
    var add = try documents(&h, &.{
        "doc-add", "--session", session, "--title", "Release plan", "--content", BODY_V1,
    }, true);
    defer add.deinit();
    const added = try toolData(&add);
    const doc_id = try gpa.dupe(u8, try stringField(&added, "id"));
    defer gpa.free(doc_id);
    try testing.expect(doc_id.len > 0);
    try testing.expectEqualStrings(ws, try stringField(&added, "workspace_id"));
    try expectBody(try stringField(&added, "content"), BODY_V1, "add_document echo");

    // 2. Read back through the store, body included.
    var got = try documents(&h, &.{ "doc-get", "--session", session, "--document", doc_id }, true);
    defer got.deinit();
    const fetched = try got.json();
    try expectBody(try stringField(fetched, "content"), BODY_V1, "doc-get");
    // The body is an OBJECT, not a column: a row with no key has no body.
    const key = try stringField(fetched, "content_key");
    try testing.expect(key.len > 0);
    try testing.expect(std.mem.startsWith(u8, key, "ws/"));

    // 3. The path the sidebar reads.
    const over_http = try httpBody(&h, ws, doc_id);
    defer gpa.free(over_http);
    try expectBody(over_http, BODY_V1, "GET /documents/:id");
}

test "agent edit_document replaces the body and the new body is what reads back" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "doc-edit-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "doc-edit-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "edit a document");
    defer gpa.free(session);

    var add = try documents(&h, &.{
        "doc-add", "--session", session, "--title", "Plan", "--content", BODY_V1,
    }, true);
    defer add.deinit();
    const added = try toolData(&add);
    const doc_id = try gpa.dupe(u8, try stringField(&added, "id"));
    defer gpa.free(doc_id);

    var edit = try documents(&h, &.{
        "doc-edit", "--session", session, "--document", doc_id, "--content", BODY_V2,
    }, true);
    defer edit.deinit();
    const edited = try toolData(&edit);
    try expectBody(try stringField(&edited, "content"), BODY_V2, "edit_document echo");
    // The title was omitted, so it must have survived the patch.
    try testing.expectEqualStrings("Plan", try stringField(&edited, "title"));

    var got = try documents(&h, &.{ "doc-get", "--session", session, "--document", doc_id }, true);
    defer got.deinit();
    try expectBody(try stringField(try got.json(), "content"), BODY_V2, "doc-get after edit");

    const over_http = try httpBody(&h, ws, doc_id);
    defer gpa.free(over_http);
    try expectBody(over_http, BODY_V2, "GET /documents/:id after edit");
}

test "agent add_document refuses a body it cannot store instead of writing an empty document" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws = try createWorkspace(&h, "doc-nostore-ws");
    defer gpa.free(ws);
    const kanban = try createKanban(&h, ws, "doc-nostore-board");
    defer gpa.free(kanban);
    const session = try createTask(&h, ws, kanban, "no store");
    defer gpa.free(session);

    // A session that resolves to no workspace is the one refusal this CLI can
    // reach without breaking the object store: the tool must fail loudly and
    // write nothing, never return a document whose body is empty.
    var refused = try documents(&h, &.{
        "doc-add", "--session", "sess_not_a_workspace", "--title", "Nowhere", "--content", BODY_V1,
    }, false);
    defer refused.deinit();
    try testing.expect(refused.result.exit_code != 0);
    try testing.expectEqualStrings("", refused.result.stdout);

    // And the workspace really has no document.
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/documents", .{ws});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const documents_json = doc.array("documents") orelse {
        std.debug.print("list has no `documents` array: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 0), documents_json.items.len);
}

comptime {
    _ = createWorkspace;
    _ = createKanban;
    _ = createTask;
    _ = documents;
    _ = stringField;
    _ = toolData;
    _ = expectBody;
    _ = httpBody;
    _ = BODY_V1;
    _ = BODY_V2;
}
