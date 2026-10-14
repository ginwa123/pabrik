// Workspace-level routines (Migration 084) wire contract. Zig port of
// `tests/functional/workspace_routines_test.py` (same test names, same
// order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// JSON accessors
// ============================================================================

fn rootObj(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    return switch (doc.value().*) {
        .object => |o| o,
        else => {
            std.debug.print("{s}: root is not a JSON object\n", .{ctx});
            return error.TestUnexpectedResult;
        },
    };
}

fn strAt(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) ![]const u8 {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            std.debug.print("{s}: `{s}` is not a string\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

fn boolAt(obj: std.json.ObjectMap, key: []const u8, ctx: []const u8) !bool {
    const v = obj.get(key) orelse {
        std.debug.print("{s}: missing `{s}`\n", .{ ctx, key });
        return error.TestUnexpectedResult;
    };
    return switch (v) {
        .bool => |b| b,
        else => {
            std.debug.print("{s}: `{s}` is not a bool\n", .{ ctx, key });
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `r.json().get("error", "")` with a case-insensitive substring
/// assertion: any ONE of `needles` must appear (both sides lowercased).
fn expectErrorContains(body: []const u8, needles: []const []const u8, ctx: []const u8) !void {
    var doc: harness.Json = .{ .parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        body,
        .{ .allocate = .alloc_always },
    ) };
    defer doc.deinit();
    const msg = try strAt(try rootObj(&doc, ctx), "error", ctx);
    const hay = try std.ascii.allocLowerString(gpa, msg);
    defer gpa.free(hay);
    for (needles) |needle| {
        const n = try std.ascii.allocLowerString(gpa, needle);
        defer gpa.free(n);
        if (std.mem.indexOf(u8, hay, n) != null) return;
    }
    std.debug.print("{s}: error = \"{s}\", expected one of the needles\n", .{ ctx, msg });
    return error.TestUnexpectedResult;
}

// ============================================================================
// Owned-document plumbing
// ============================================================================

/// An owned response body PLUS its parse, so a helper can hand a
/// document to its caller without the body dying underneath it.
const OwnedDoc = struct {
    bytes: []u8,
    doc: harness.Json,

    pub fn deinit(self: *OwnedDoc) void {
        self.doc.deinit();
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Parse owned bytes into a self-contained `OwnedDoc`.
fn parseOwned(bytes: []u8) !OwnedDoc {
    return .{
        .bytes = bytes,
        .doc = .{ .parsed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            bytes,
            .{ .allocate = .alloc_always },
        ) },
    };
}

/// Issue a request and hand back an owned, self-contained document.
/// `.alloc_always` is what makes this legal: no string in the returned tree
/// borrows `r.body`, which is freed before the caller sees it.
fn requestDoc(h: *Harness, method: harness.HttpMethod, path: []const u8, opts: harness.Harness.HttpOptions) !OwnedDoc {
    var r = try h.http(io, method, path, opts);
    defer r.deinit();
    return parseOwned(try gpa.dupe(u8, r.body));
}

// ============================================================================
// Fixtures (mirror the Python module-level helpers)
// ============================================================================

/// Python `_create_workspace` → the new workspace's id. Owned.
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

/// The per-suite project path every item is created under. Derived from the
/// harness tempdir — a literal `/tmp/...` would be rejected on Windows, where
/// `isAbsolute` is platform-relative.
fn projectPath(h: *Harness) ![]u8 {
    return harness.harnessPath(gpa, h.temp_dir, &.{"routine-test"});
}

/// Python `_create_routine`.
fn createRoutine(h: *Harness, ws_id: []const u8, name: []const u8, path: []const u8, instruction: ?[]const u8, schedule: ?[]const u8) !OwnedDoc {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .path = path,
        .instruction = instruction,
        .schedule = schedule,
    }, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/routine", .{ws_id});
    defer gpa.free(url);

    return requestDoc(h, .POST, url, .{ .json_body = body, .expect = &.{201} });
}

/// The `item.id` of a create-routine response. Borrows `created`.
fn createdItemId(created: *const OwnedDoc, ctx: []const u8) ![]const u8 {
    const item = created.doc.object("item") orelse {
        std.debug.print("{s}: response has no `item`: {s}\n", .{ ctx, created.bytes });
        return error.TestUnexpectedResult;
    };
    return strAt(item, "id", ctx);
}

/// The `routine` object of any routine response. Borrows `doc`.
fn routineObj(doc: *const harness.Json, ctx: []const u8) !std.json.ObjectMap {
    // `doc` was parsed with `.allocate = .alloc_always`, so rendering the
    // whole tree here would print a copy rather than the wire bytes;
    // the key absence is the diagnostic worth having.
    return doc.object("routine") orelse {
        std.debug.print("{s}: response has no `routine` object\n", .{ctx});
        return error.TestUnexpectedResult;
    };
}

/// Python `_create_agent` → the new agent item's id. Owned.
fn createAgent(h: *Harness, ws_id: []const u8) ![]u8 {
    const path = try projectPath(h);
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "agent",
        .path = path,
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/agent", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const item = doc.object("item") orelse {
        std.debug.print("agent create returned no `item`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const id = strAt(item, "id", "agent create") catch |err| {
        std.debug.print("agent create item has no id: {s}\n", .{r.body});
        return err;
    };
    return gpa.dupe(u8, id);
}

/// Python `_create_folder` → the new folder item's id. Owned.
fn createFolder(h: *Harness, ws_id: []const u8) ![]u8 {
    const path = try projectPath(h);
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "folder",
        .item_type = "folder",
        .path = path,
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("folder create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST .../items/<item>/tasks {"name": ...}` → the new task's id. Owned.
fn createPlainTask(h: *Harness, ws_id: []const u8, item_id: []const u8, name: []const u8) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("task create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

// ============================================================================
// CREATE
// ============================================================================

test "create_routine_happy_path" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, "do things", "0 9 * * *");
    defer created.deinit();

    const item = created.doc.object("item") orelse {
        std.debug.print("create response has no `item`: {s}\n", .{created.bytes});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("routine", try strAt(item, "item_type", "created item"));

    const routine = try routineObj(&created.doc, "create response");
    try testing.expectEqualStrings(
        try strAt(item, "id", "created item"),
        try strAt(routine, "id", "created routine"),
    );
    try testing.expectEqualStrings("do things", try strAt(routine, "instruction", "created routine"));
    try testing.expectEqualStrings("0 9 * * *", try strAt(routine, "schedule", "created routine"));

    // A scheduled routine must carry a computed next_run_at.
    const next = try strAt(routine, "next_run_at", "created routine");
    if (next.len == 0) {
        std.debug.print("next_run_at should be set for a scheduled routine: {s}\n", .{created.bytes});
        return error.TestUnexpectedResult;
    }
}

test "create_routine_bad_cron_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "bad",
        .path = path,
        .schedule = "not a cron",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/routine", .{ws_id});
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"cron"}, "bad cron create");
}

test "create_routine_empty_name_or_path_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    const url = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items/routine", .{ws_id});
    defer gpa.free(url);

    // Whitespace-only name.
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .name = "   ",
            .path = path,
        }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
        defer r.deinit();
    }

    // Empty path.
    {
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .name = "x",
            .path = "",
        }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
        defer r.deinit();
    }
}

test "create_routine_without_schedule_is_manual_only" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "manual", path, "run me by hand", null);
    defer created.deinit();

    const routine = try routineObj(&created.doc, "manual create");
    try testing.expectEqualStrings("", try strAt(routine, "schedule", "manual routine"));
    try testing.expectEqualStrings("", try strAt(routine, "next_run_at", "manual routine"));
}

// ============================================================================
// GET
// ============================================================================

test "get_bundle_returns_routine" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, "hi", "*/5 * * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "get bundle");

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const routine = try routineObj(&doc, "routine bundle");
    try testing.expectEqualStrings("hi", try strAt(routine, "instruction", "routine bundle"));
    try testing.expectEqualStrings("*/5 * * * *", try strAt(routine, "schedule", "routine bundle"));
    try testing.expectEqual(true, try boolAt(routine, "enabled", "routine bundle"));
}

test "get_on_agent_item_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const agent_id = try createAgent(&h, ws_id);
    defer gpa.free(agent_id);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, agent_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"not a routine"}, "agent item routine GET");
}

test "get_missing_item_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/does-not-exist/routine",
        .{ws_id},
    );
    defer gpa.free(url);

    var r = try h.http(io, .GET, url, .{ .expect = &.{404} });
    defer r.deinit();
}

// ============================================================================
// PATCH
// ============================================================================

test "patch_instruction_keeps_schedule" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, "0 9 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "patch instruction");

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .instruction = "do other things",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const routine = try routineObj(&doc, "patch instruction");
    try testing.expectEqualStrings("do other things", try strAt(routine, "instruction", "patched routine"));
    try testing.expectEqualStrings("0 9 * * *", try strAt(routine, "schedule", "patched routine"));
    if ((try strAt(routine, "next_run_at", "patched routine")).len == 0) {
        std.debug.print("next_run_at should survive an instruction-only patch: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

test "patch_schedule_recomputes_next_run_at" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, "0 9 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "patch schedule");

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .schedule = "*/5 * * * *",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const routine = try routineObj(&doc, "patch schedule");
    try testing.expectEqualStrings("*/5 * * * *", try strAt(routine, "schedule", "patched routine"));
    if ((try strAt(routine, "next_run_at", "patched routine")).len == 0) {
        std.debug.print("next_run_at should be recomputed for a new schedule: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

test "patch_clear_schedule_nulls_next_run_at" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, "0 9 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "clear schedule");

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .schedule = "" }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const routine = try routineObj(&doc, "clear schedule");
    try testing.expectEqualStrings("", try strAt(routine, "schedule", "patched routine"));
    try testing.expectEqualStrings("", try strAt(routine, "next_run_at", "patched routine"));
}

test "patch_disable_nulls_next_run_at" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, "0 9 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "disable routine");

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .enabled = false }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const routine = try routineObj(&doc, "disable routine");
    try testing.expectEqual(false, try boolAt(routine, "enabled", "patched routine"));
    try testing.expectEqualStrings("", try strAt(routine, "next_run_at", "patched routine"));
}

test "patch_bad_cron_returns_400" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, null);
    defer created.deinit();
    const item_id = try createdItemId(&created, "bad cron patch");

    const body = try std.json.Stringify.valueAlloc(gpa, .{ .schedule = "bogus" }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .PATCH, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"cron"}, "bad cron patch");
}

// ============================================================================
// RUN
// ============================================================================

test "run_fires_routine" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, "go", "0 0 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "run routine");

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routines/{s}/run",
        .{ ws_id, item_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try testing.expectEqual(true, doc.boolean("success").?);
    try testing.expectEqualStrings(item_id, doc.str("session_id").?);
    try testing.expectEqualStrings("firing", doc.str("status").?);
}

test "run_disabled_routine_returns_409" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, "0 0 * * *");
    defer created.deinit();
    const item_id = try createdItemId(&created, "disabled run");

    const patch_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(patch_url);
    const patch_body = try std.json.Stringify.valueAlloc(gpa, .{ .enabled = false }, .{});
    defer gpa.free(patch_body);
    var pr = try h.http(io, .PATCH, patch_url, .{ .json_body = patch_body, .expect = &.{200} });
    defer pr.deinit();

    const run_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routines/{s}/run",
        .{ ws_id, item_id, item_id },
    );
    defer gpa.free(run_url);

    var r = try h.http(io, .POST, run_url, .{ .json_body = "{}", .expect = &.{409} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"disabled"}, "disabled routine run");
}

test "run_unknown_routine_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, null);
    defer created.deinit();
    const item_id = try createdItemId(&created, "unknown routine run");

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routines/does-not-exist/run",
        .{ ws_id, item_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{404} });
    defer r.deinit();
}

test "run_routine_under_wrong_item_returns_404" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var first = try createRoutine(&h, ws_id, "first", path, null, null);
    defer first.deinit();
    const first_id = try createdItemId(&first, "first routine");

    var second = try createRoutine(&h, ws_id, "second", path, null, null);
    defer second.deinit();
    const second_id = try createdItemId(&second, "second routine");

    // The routine belongs to `first`, so running it under `second`
    // must not resolve.
    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routines/{s}/run",
        .{ ws_id, second_id, first_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{404} });
    defer r.deinit();
}

// ============================================================================
// CASCADE
// ============================================================================

test "delete_item_cascades_routine" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    var created = try createRoutine(&h, ws_id, "nightly", path, null, null);
    defer created.deinit();
    const item_id = try createdItemId(&created, "cascade delete");

    const del_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, item_id },
    );
    defer gpa.free(del_url);
    var dr = try h.http(io, .DELETE, del_url, .{ .expect = &.{200} });
    defer dr.deinit();

    // Item gone → routine bundle 404s (FK cascade wiped the row).
    const get_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(get_url);
    var gr = try h.http(io, .GET, get_url, .{ .expect = &.{404} });
    defer gr.deinit();
}

test "manual_only_routine_never_auto_fires" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const path = try projectPath(&h);
    defer gpa.free(path);

    // A schedule-less routine has NULL next_run_at so the scheduler's
    // due-scan (`next_run_at <= now`) can never match it — only the
    // manual run endpoint fires it.
    var created = try createRoutine(&h, ws_id, "manual", path, null, null);
    defer created.deinit();
    const item_id = try createdItemId(&created, "manual-only routine");

    const get_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routine",
        .{ ws_id, item_id },
    );
    defer gpa.free(get_url);

    {
        var r = try h.http(io, .GET, get_url, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const routine = try routineObj(&doc, "manual-only routine");
        try testing.expectEqualStrings("", try strAt(routine, "next_run_at", "manual-only routine"));
    }

    // ...but manual run still works.
    const run_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/routines/{s}/run",
        .{ ws_id, item_id, item_id },
    );
    defer gpa.free(run_url);
    var r = try h.http(io, .POST, run_url, .{ .json_body = "{}", .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    try testing.expectEqual(true, doc.boolean("success").?);
}

// ============================================================================
// DELETION PROOFS
// ============================================================================

test "old_global_routines_list_is_gone" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/routines", .{ .expect = &.{404} });
    defer r.deinit();
}

test "old_per_task_run_endpoint_is_gone" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const folder_id = try createFolder(&h, ws_id);
    defer gpa.free(folder_id);
    const task_id = try createPlainTask(&h, ws_id, folder_id, "plain task");
    defer gpa.free(task_id);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}/run",
        .{ ws_id, folder_id, task_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = "{}", .expect = &.{404} });
    defer r.deinit();
}

test "create_task_with_routine_type_is_rejected" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const folder_id = try createFolder(&h, ws_id);
    defer gpa.free(folder_id);

    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = "sneaky routine",
        .task_type = "routine",
        .schedule = "* * * * *",
        .initial_prompt = "x",
    }, .{});
    defer gpa.free(body);

    const url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks",
        .{ ws_id, folder_id },
    );
    defer gpa.free(url);

    var r = try h.http(io, .POST, url, .{ .json_body = body, .expect = &.{400} });
    defer r.deinit();

    try expectErrorContains(r.body, &.{"routine"}, "task_type=routine create");
}

test "put_task_with_routine_fields_is_plain_update" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "ws-routines");
    defer gpa.free(ws_id);
    const folder_id = try createFolder(&h, ws_id);
    defer gpa.free(folder_id);
    const task_id = try createPlainTask(&h, ws_id, folder_id, "plain task");
    defer gpa.free(task_id);

    // Old clients sending schedule/initial_prompt get a 200 plain task
    // update (unknown fields ignored) — the task stays standard.
    const put_body = try std.json.Stringify.valueAlloc(gpa, .{
        .schedule = "*/5 * * * *",
        .initial_prompt = "stale client",
        .enabled = true,
    }, .{});
    defer gpa.free(put_body);

    const put_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws_id, folder_id, task_id },
    );
    defer gpa.free(put_url);

    var pr = try h.http(io, .PUT, put_url, .{ .json_body = put_body, .expect = &.{200} });
    defer pr.deinit();

    const get_url = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/tasks/{s}",
        .{ ws_id, folder_id, task_id },
    );
    defer gpa.free(get_url);

    var r = try h.http(io, .GET, get_url, .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const task = doc.object("task") orelse {
        std.debug.print("single-task GET returned no `task`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("standard", try strAt(task, "task_type", "plain-updated task"));
    if (task.get("routine") != null) {
        std.debug.print("task still carries a `routine` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Body-analysis barrier
// ============================================================================

comptime {
    _ = rootObj;
    _ = strAt;
    _ = boolAt;
    _ = expectErrorContains;
    _ = parseOwned;
    _ = requestDoc;
    _ = createWorkspace;
    _ = projectPath;
    _ = createRoutine;
    _ = createdItemId;
    _ = routineObj;
    _ = createAgent;
    _ = createFolder;
    _ = createPlainTask;
}
