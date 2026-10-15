// Functional tests for workspace items full CRUD. Zig port of
// `tests/functional/workspace_items_test.py` (same test names, same order).

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers — wire
// ============================================================================

/// Parse OWNED bytes into a `harness.Json`. A `harness.Json` aliases the
/// `Response` body it was parsed from, so a helper may not RETURN one.
/// Helpers below return owned bytes and each test parses locally.
fn parseJson(bytes: []const u8) !harness.Json {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) };
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

/// `POST /api/workspaces/<ws>/items` → the WHOLE response body, owned.
fn createItem(
    h: *Harness,
    workspace_id: []const u8,
    name: []const u8,
    item_type: []const u8,
    path: []const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .item_type = item_type,
        .path = path,
    }, .{});
    defer gpa.free(body);

    const req = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items",
        .{workspace_id},
    );
    defer gpa.free(req);

    var r = try h.http(io, .POST, req, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// The id inside a create/get item body. Owned.
fn itemIdOf(body: []const u8) ![]u8 {
    var doc = try parseJson(body);
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("item body has no id: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `GET /api/workspaces/<ws>/items/<item_id>` → the whole body, owned.
fn getItem(h: *Harness, workspace_id: []const u8, item_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ workspace_id, item_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// `GET /api/workspaces/<ws>/items` → the whole body, owned. The Python
/// accepted EITHER `{items: [...]}` or a bare list and raised on anything
/// else; `itemArray` below preserves that.
fn listItems(h: *Harness, workspace_id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}/items", .{workspace_id});
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();
    return gpa.dupe(u8, r.body);
}

/// Python `_list_items`: unwrap `{"items": [...]}` or accept a bare list.
fn itemArray(raw: []const u8) !std.json.Array {
    var doc = try parseJson(raw);
    defer doc.deinit();
    return switch (doc.value().*) {
        .object => |o| blk: {
            const v = o.get("items") orelse {
                std.debug.print("unexpected items response shape: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            };
            break :blk switch (v) {
                .array => |a| a,
                else => {
                    std.debug.print("unexpected items response shape: {s}\n", .{raw});
                    return error.TestUnexpectedResult;
                },
            };
        },
        .array => |a| a,
        else => {
            std.debug.print("unexpected items response shape: {s}\n", .{raw});
            return error.TestUnexpectedResult;
        },
    };
}

/// Python `i.get("is_default") == 1` — an integer, a bool or the decimal
/// string. Anything else (including null) is False.
fn isDefaultFlag(v: ?std.json.Value) bool {
    const c = v orelse return false;
    return switch (c) {
        .integer => |n| n == 1,
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "1"),
        else => false,
    };
}

/// `POST .../items/<design_id>/design/pages` → the page id. Owned.
fn createDesignPage(
    h: *Harness,
    workspace_id: []const u8,
    design_id: []const u8,
    name: []const u8,
) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .width = @as(u32, 1440),
        .height = @as(u32, 1024),
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages",
        .{ workspace_id, design_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const id = doc.str("id") orelse {
        std.debug.print("design page create returned no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    return gpa.dupe(u8, id);
}

/// `POST .../design/pages/<page_id>/elements` → 201, body ignored.
fn addDesignElement(
    h: *Harness,
    workspace_id: []const u8,
    design_id: []const u8,
    page_id: []const u8,
    name: []const u8,
    html: []const u8,
) !void {
    const body = try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .type = "rectangle",
        .html = html,
        .fill = "#000000",
        .x = @as(i64, 0),
        .y = @as(i64, 0),
        .width = @as(u32, 100),
        .height = @as(u32, 100),
    }, .{});
    defer gpa.free(body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}/design/pages/{s}/elements",
        .{ workspace_id, design_id, page_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .POST, path, .{ .json_body = body, .expect = &.{201} });
    defer r.deinit();
}

/// True iff `path` names an existing file or directory.
fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Python `list(design_root.rglob("*.html"))` — how many `.html` files live
/// anywhere under `root`. `Dir.Walker` order is undefined, but the test only
/// counts, so the difference from `rglob`'s sorted order is unobservable.
fn countHtmlFiles(root: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".html")) continue;
        n += 1;
    }
    return n;
}

/// A per-test on-disk directory OUTSIDE the harness tempdir. Python's
/// `item_workspace_path` fixture returned pytest's `tmp_path / "item"` — a
/// SIBLING of the harness tempdir, never a child of it.
const Scratch = struct {
    /// The scratch root. Deleted by `deinit`.
    root: []u8,
    /// `<root>/item` — the path design items point at.
    dir: []u8,

    /// ORDER MATTERS: cleanup runs FIRST (it reads `root`), then the two
    /// frees. Getting this backwards reads freed memory inside the
    /// safety gate, which prints a refusal and leaks the fixture.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
        gpa.free(self.dir);
        self.* = undefined;
    }
};

fn makeItemDir() !Scratch {
    const root = try harness.makeScratchDir(gpa);
    errdefer gpa.free(root);
    const dir = try harness.harnessPath(gpa, root, &.{"item"});
    errdefer gpa.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return .{ .root = root, .dir = dir };
}

// ============================================================================
// Test 1: GET /api/workspaces/:id round-trips the created fields
// ============================================================================

// POST then GET-by-id; assert name, id, and timestamps round-trip. The
// handler returns `{"id":..., "name":..., "created_at":...,
// "updated_at":...}`.
test "get_workspace_by_id_returns_full_record" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "get-by-id");
    defer gpa.free(ws_id);

    const path = try std.fmt.allocPrint(gpa, "/api/workspaces/{s}", .{ws_id});
    defer gpa.free(path);
    var r = try h.http(io, .GET, path, .{ .expect = &.{200} });
    defer r.deinit();

    // The body must contain real workspace data, not 0xAA bytes (the
    // classic symptom of a use-after-free on the row's arena).
    if (std.mem.indexOfScalar(u8, r.body, 0xAA) != null) {
        const shown = try harness.debugString(gpa, r.body);
        defer gpa.free(shown);
        std.debug.print(
            "GET workspace body contains 0xAA bytes (use-after-free in " ++
                "workspace_get.zig::useCase):\n  body = '{s}'\n",
            .{shown},
        );
        return error.TestUnexpectedResult;
    }

    var doc = try r.json();
    defer doc.deinit();

    const got_id = doc.str("id") orelse {
        std.debug.print("GET workspace has no id: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_id, ws_id)) {
        std.debug.print("id should round-trip, got '{s}' (expected '{s}')\n", .{ got_id, ws_id });
        return error.TestUnexpectedResult;
    }
    const got_name = doc.str("name") orelse {
        std.debug.print("GET workspace has no name: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got_name, "get-by-id")) {
        std.debug.print("name should round-trip, got '{s}'\n", .{got_name});
        return error.TestUnexpectedResult;
    }
    // Timestamps come back as non-empty strings (datetime('now') default).
    for ([_][]const u8{ "created_at", "updated_at" }) |field| {
        const v = doc.str(field) orelse {
            std.debug.print("{s} should be a non-empty string, got: <absent>\n", .{field});
            return error.TestUnexpectedResult;
        };
        if (v.len == 0) {
            std.debug.print("{s} should be a non-empty string, got: ''\n", .{field});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 2: GET /api/workspaces/:id returns 404 with consistent body shape
// ============================================================================

// GET ws_nope returns 404 with body `{"error": "..."}`.
//
// workspace_get.zig:104-108 sends `{"error":"Workspace not found"}`.
test "get_workspace_by_id_404_for_nonexistent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/workspaces/ws_nope", .{ .expect = &.{404} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const err_msg = doc.str("error") orelse {
        std.debug.print("404 should include an 'error' field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, err_msg, "Workspace not found") == null) {
        std.debug.print(
            "404 error message should mention 'Workspace not found', got '{s}'\n",
            .{err_msg},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 3: GET item-by-id returns the right item_type + path for each
// ============================================================================

// Create chat + kanban + design; GET each by id; verify item_type. The wire
// shape is `WorkspaceItemGetResponse` — fields are all nullable except `id,
// workspace_id, item_type`.
test "get_item_by_id_returns_mixed_item_types" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var scratch = try makeItemDir();
    defer scratch.deinit();
    const item_dir = scratch.dir;

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);

    const Kinds = struct { label: []const u8, kind: []const u8 };
    const kinds = [_]Kinds{
        .{ .label = "chat-item", .kind = "chat" },
        .{ .label = "kanban-item", .kind = "kanban" },
        .{ .label = "design-item", .kind = "design" },
    };

    var created_ids: [kinds.len][]u8 = undefined;
    for (kinds, 0..) |k, i| {
        const raw = try createItem(&h, ws_id, k.label, k.kind, item_dir);
        defer gpa.free(raw);
        created_ids[i] = try itemIdOf(raw);
    }
    defer for (created_ids) |id| gpa.free(id);

    for (kinds, 0..) |k, i| {
        const raw = try getItem(&h, ws_id, created_ids[i]);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();

        const got_id = doc.str("id") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_id, created_ids[i])) {
            std.debug.print("id mismatch: got '{s}', want '{s}'\n", .{ got_id, created_ids[i] });
            return error.TestUnexpectedResult;
        }
        const got_type = doc.str("item_type") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_type, k.kind)) {
            std.debug.print(
                "item_type mismatch for {s}: expected '{s}', got '{s}'\n",
                .{ created_ids[i], k.kind, got_type },
            );
            return error.TestUnexpectedResult;
        }
        const got_ws = doc.str("workspace_id") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_ws, ws_id)) {
            std.debug.print("workspace_id mismatch: got '{s}', want '{s}'\n", .{ got_ws, ws_id });
            return error.TestUnexpectedResult;
        }
        // The path round-trips (the create handler persists it for all
        // three types — chat/kanban typically ignore it client-side but
        // the column accepts it).
        const got_path = doc.str("path") orelse {
            std.debug.print(
                "path round-trip mismatch for {s}: expected '{s}', got <absent>\n",
                .{ k.kind, item_dir },
            );
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got_path, item_dir)) {
            std.debug.print(
                "path round-trip mismatch for {s}: expected '{s}', got '{s}'\n",
                .{ k.kind, item_dir, got_path },
            );
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 4: GET item-by-id 404 for nonexistent
// ============================================================================

// GET item_nope returns 404 with `{"error": "..."}`.
// workspace_items_get.zig:64-77 maps `WorkspaceItemNotFound` -> 404 with
// message "Workspace item not found".
test "get_item_by_id_404_for_nonexistent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/item_nope",
        .{ws_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const err_msg = doc.str("error") orelse {
        std.debug.print("404 should include an 'error' field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, err_msg, "Workspace item not found") == null) {
        std.debug.print("404 error should mention 'Workspace item not found', got '{s}'\n", .{err_msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 5: PUT item renames it; name round-trips through GET
// ============================================================================

// PUT {name: "new"} -> GET returns the new name; DB column updated.
test "update_item_name_round_trips" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    const created_raw = try createItem(&h, ws_id, "before-rename", "chat", base);
    defer gpa.free(created_raw);
    const item_id = try itemIdOf(created_raw);
    defer gpa.free(item_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, item_id },
    );
    defer gpa.free(path);

    const put_body = try std.json.Stringify.valueAlloc(gpa, .{ .name = "after-rename" }, .{});
    defer gpa.free(put_body);
    var put = try h.http(io, .PUT, path, .{ .json_body = put_body, .expect = &.{200} });
    defer put.deinit();

    {
        var doc = try put.json();
        defer doc.deinit();
        // The PUT response is the same `WorkspaceItemGetResponse` shape.
        const got_id = doc.str("id") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_id, item_id)) {
            std.debug.print("PUT response id '{s}' != created id '{s}'\n", .{ got_id, item_id });
            return error.TestUnexpectedResult;
        }
        // The PUT response does NOT echo the new `name` value — the
        // handler always returns `name: null`.
        const name_cell = doc.get("name") orelse return error.TestUnexpectedResult;
        if (name_cell != .null) {
            std.debug.print(
                "PUT response should leave name as null (the frontend " ++
                    "re-fetches via GET)\n",
                .{},
            );
            return error.TestUnexpectedResult;
        }
    }

    // GET-by-id reflects the rename.
    {
        const raw = try getItem(&h, ws_id, item_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const got_name = doc.str("name") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_name, "after-rename")) {
            std.debug.print("GET should show the new name, got '{s}'\n", .{got_name});
            return error.TestUnexpectedResult;
        }
    }

    // The list endpoint also reflects the rename.
    {
        const raw = try listItems(&h, ws_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const items = try itemArray(raw);
        var found = false;
        for (items.items) |it| {
            if (it != .object) continue;
            const id = switch (it.object.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, id, item_id)) continue;
            found = true;
            const nm = switch (it.object.get("name") orelse {
                std.debug.print("listed item has no name: {s}\n", .{raw});
                return error.TestUnexpectedResult;
            }) {
                .string => |s| s,
                else => return error.TestUnexpectedResult,
            };
            if (!std.mem.eql(u8, nm, "after-rename")) {
                std.debug.print("list should show the new name, got '{s}'\n", .{nm});
                return error.TestUnexpectedResult;
            }
            break;
        }
        if (!found) {
            std.debug.print("item {s} missing from list after rename\n", .{item_id});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 6: PUT with empty name returns 400
// ============================================================================

// PUT {name: ""} -> 400. workspace_items_update.zig:99-132 documents the
// strict contract: if the `name` key is PRESENT but the value is null/empty,
// reject with `name must be a non-empty string when present`.
test "update_item_name_rejects_empty" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    const created_raw = try createItem(&h, ws_id, "to-be-renamed", "chat", base);
    defer gpa.free(created_raw);
    const item_id = try itemIdOf(created_raw);
    defer gpa.free(item_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, item_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{
        .json_body = "{\"name\":\"\"}",
        .expect = &.{400},
    });
    defer r.deinit();
    {
        var doc = try r.json();
        defer doc.deinit();
        const err_msg = doc.str("error") orelse {
            std.debug.print("400 should include an 'error' field, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        const lowered = try std.ascii.allocLowerString(gpa, err_msg);
        defer gpa.free(lowered);
        if (std.mem.indexOf(u8, lowered, "name") == null) {
            std.debug.print("empty-name error should mention 'name', got: '{s}'\n", .{err_msg});
            return error.TestUnexpectedResult;
        }
    }

    // The original name is preserved (handler rejects before any DB write).
    {
        const raw = try getItem(&h, ws_id, item_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const got_name = doc.str("name") orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, got_name, "to-be-renamed")) {
            std.debug.print("original name should be preserved, got '{s}'\n", .{got_name});
            return error.TestUnexpectedResult;
        }
    }
}

// ============================================================================
// Test 7: PUT with empty body returns 400
// ============================================================================

// PUT {} -> 400. workspace_items_update.zig:156-161 enforces "at least one of
// item_type, name, or path is required". A bare PUT that sends nothing is a
// no-op that must NOT silently succeed.
test "update_item_rejects_empty_body" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    const created_raw = try createItem(&h, ws_id, "doomed-empty-put", "chat", base);
    defer gpa.free(created_raw);
    const item_id = try itemIdOf(created_raw);
    defer gpa.free(item_id);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, item_id },
    );
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{ .json_body = "{}", .expect = &.{400} });
    defer r.deinit();

    var doc = try r.json();
    defer doc.deinit();
    const err_msg = doc.str("error") orelse {
        std.debug.print("400 should include an 'error' field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    const lowered = try std.ascii.allocLowerString(gpa, err_msg);
    defer gpa.free(lowered);
    if (std.mem.indexOf(u8, lowered, "name") == null and
        std.mem.indexOf(u8, lowered, "path") == null and
        std.mem.indexOf(u8, lowered, "item_type") == null)
    {
        std.debug.print(
            "empty-body error should mention updatable field, got: '{s}'\n",
            .{err_msg},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 8: PUT 404 for nonexistent item
// ============================================================================

// PUT /items/item_nope -> 404 (the item-existence pre-check fires).
test "update_item_404_for_nonexistent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/item_nope",
        .{ws_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .PUT, path, .{
        .json_body = "{\"name\":\"anything\"}",
        .expect = &.{404},
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const err_msg = doc.str("error") orelse {
        std.debug.print("404 should include an 'error' field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, err_msg, "Workspace item not found") == null) {
        std.debug.print("404 error should mention 'Workspace item not found', got '{s}'\n", .{err_msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 9: DELETE removes the item from the list + GET returns 404
// ============================================================================

// DELETE -> /items no longer contains it; GET-by-id is now 404. The handler
// returns `{id, success: true}` (the `WorkspaceItemResponse` shape from
// http_response.zig:6).
test "delete_item_removes_from_list" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    const created_raw = try createItem(&h, ws_id, "doomed", "chat", base);
    defer gpa.free(created_raw);
    const item_id = try itemIdOf(created_raw);
    defer gpa.free(item_id);

    {
        const raw = try listItems(&h, ws_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        if (!listContains(raw, item_id)) {
            std.debug.print("created item '{s}' is not in the list: {s}\n", .{ item_id, raw });
            return error.TestUnexpectedResult;
        }
    }

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, item_id },
    );
    defer gpa.free(path);

    {
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const ok = doc.boolean("success") orelse {
            std.debug.print("DELETE response has no `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!ok) {
            std.debug.print("DELETE response success should be true: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        const got_id = doc.str("id") orelse {
            std.debug.print("DELETE response has no `id`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!std.mem.eql(u8, got_id, item_id)) {
            std.debug.print("DELETE response id '{s}' != '{s}'\n", .{ got_id, item_id });
            return error.TestUnexpectedResult;
        }
    }

    // List no longer contains it.
    {
        const raw = try listItems(&h, ws_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        if (listContains(raw, item_id)) {
            std.debug.print("deleted item '{s}' still in list: {s}\n", .{ item_id, raw });
            return error.TestUnexpectedResult;
        }
    }

    // GET-by-id is now 404 (proves the DB row is gone, not just hidden
    // from the list).
    {
        var r = try h.http(io, .GET, path, .{ .expect = &.{404} });
        defer r.deinit();
    }
}

// ============================================================================
// Test 10: DELETE 404 for nonexistent
// ============================================================================

// DELETE /items/item_nope -> 404 with body shape.
test "delete_item_404_for_nonexistent" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/item_nope",
        .{ws_id},
    );
    defer gpa.free(path);

    var r = try h.http(io, .DELETE, path, .{ .expect = &.{404} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    const err_msg = doc.str("error") orelse {
        std.debug.print("404 should include an 'error' field, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, err_msg, "Workspace item not found") == null) {
        std.debug.print("404 error should mention 'Workspace item not found', got '{s}'\n", .{err_msg});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 11: POST /reorder changes item display order
// ============================================================================

// Create 7 items of mixed types; POST reorder with a permuted list; assert
// the list endpoint returns them in the new order.
// workspace_items_reorder.zig:124-127 documents the position formula:
test "reorder_items_changes_display_order" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    // Create 7 items with deterministic names so we can identify them.
    var ids: [7][]u8 = undefined;
    for (0..7) |i| {
        const label = try std.fmt.allocPrint(gpa, "item-{d}", .{i});
        defer gpa.free(label);
        const kind: []const u8 = if (i % 2 == 0) "chat" else "kanban";
        const raw = try createItem(&h, ws_id, label, kind, base);
        defer gpa.free(raw);
        ids[i] = try itemIdOf(raw);
    }
    defer for (ids) |id| gpa.free(id);

    // Capture the ACTUAL returned order from /items.
    const initial_raw = try listItems(&h, ws_id);
    defer gpa.free(initial_raw);
    {
        var doc = try parseJson(initial_raw);
        defer doc.deinit();
        const arr = try itemArray(initial_raw);

        // The workspace also carries its DEFAULT project (Migration 094),
        // which this test did not create. Exclude it by flag so the
        // comparison is about the seven items under test.
        var default_items: usize = 0;
        for (arr.items) |it| {
            if (it != .object) continue;
            if (isDefaultFlag(it.object.get("is_default"))) default_items += 1;
        }
        if (default_items != 1) {
            std.debug.print(
                "expected one default project, got {d}: {s}\n",
                .{ default_items, initial_raw },
            );
            return error.TestUnexpectedResult;
        }
        for (ids) |id| {
            if (!listContains(initial_raw, id)) {
                std.debug.print(
                    "created ids should match listed ids.\n  created: {s}\n  listed body: {s}\n",
                    .{ id, initial_raw },
                );
                return error.TestUnexpectedResult;
            }
        }
    }

    // Reorder to [item-6, item-0, item-3, item-2, item-1, item-5, item-4].
    const perm = [_]usize{ 6, 0, 3, 2, 1, 5, 4 };
    var new_order: [7][]u8 = undefined;
    for (perm, 0..) |src, i| new_order[i] = ids[src];

    var ordered_json: std.Io.Writer.Allocating = .init(gpa);
    defer ordered_json.deinit();
    try ordered_json.writer.writeAll("{\"ordered_ids\":[");
    for (new_order, 0..) |id, i| {
        if (i > 0) try ordered_json.writer.writeAll(",");
        try std.json.Stringify.value(id, .{}, &ordered_json.writer);
    }
    try ordered_json.writer.writeAll("]}");
    const reorder_body = try ordered_json.toOwnedSlice();
    defer gpa.free(reorder_body);

    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/reorder",
        .{ws_id},
    );
    defer gpa.free(path);

    {
        var r = try h.http(io, .POST, path, .{
            .json_body = reorder_body,
            .expect = &.{200},
        });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const ok = doc.boolean("success") orelse {
            std.debug.print("reorder response has no `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!ok) {
            std.debug.print("reorder response success should be true: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
        const count = doc.int("count") orelse {
            std.debug.print("reorder response has no integer `count`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (count != 7) {
            std.debug.print("expected count=7, got {d}: {s}\n", .{ count, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // The list endpoint returns items in `position DESC` order, so
    // ordered_ids[0] is at the top.
    {
        const raw = try listItems(&h, ws_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        const arr = try itemArray(raw);

        var got: std.ArrayList([]const u8) = .empty;
        defer got.deinit(gpa);
        for (arr.items) |it| {
            if (it != .object) continue;
            if (isDefaultFlag(it.object.get("is_default"))) continue;
            const id = switch (it.object.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            try got.append(gpa, id);
        }
        if (got.items.len != 7) {
            std.debug.print("expected 7 reordered items, got {d}: {s}\n", .{ got.items.len, raw });
            return error.TestUnexpectedResult;
        }
        for (got.items, 0..) |id, i| {
            if (!std.mem.eql(u8, id, new_order[i])) {
                std.debug.print(
                    "reorder didn't apply at position {d}: got '{s}', want '{s}'\n",
                    .{ i, id, new_order[i] },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ============================================================================
// Test 12: DELETE design item cascade-removes on-disk .pabrik/design/
// ============================================================================

// Design item with 3 pages x 2 elements -> DELETE item ->
// `<path>/.pabrik/design/` directory is gone.
// workspace_items_delete.zig:77-97 documents the on-disk cleanup: for design
test "delete_design_item_cascade_removes_html_files" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var scratch = try makeItemDir();
    defer scratch.deinit();
    const item_dir = scratch.dir;

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);

    const design_raw = try createItem(&h, ws_id, "design-to-delete", "design", item_dir);
    defer gpa.free(design_raw);
    const design_id = try itemIdOf(design_raw);
    defer gpa.free(design_id);

    // Create 3 pages x 2 elements = 6 on-disk HTML files.
    for (0..3) |i| {
        const page_label = try std.fmt.allocPrint(gpa, "Page{d}", .{i});
        defer gpa.free(page_label);
        const pid = try createDesignPage(&h, ws_id, design_id, page_label);
        defer gpa.free(pid);
        for (0..2) |j| {
            const elem_label = try std.fmt.allocPrint(gpa, "elem-{d}-{d}", .{ i, j });
            defer gpa.free(elem_label);
            const html = try std.fmt.allocPrint(gpa, "<div>page {d} element {d}</div>", .{ i, j });
            defer gpa.free(html);
            try addDesignElement(&h, ws_id, design_id, pid, elem_label, html);
        }
    }

    const design_root = try harness.harnessPath(gpa, item_dir, &.{ ".pabrik", "design" });
    defer gpa.free(design_root);

    // Verify the on-disk design folder exists with 6 .html files.
    if (!pathExists(design_root)) {
        std.debug.print("design folder should exist before delete at {s}\n", .{design_root});
        return error.TestUnexpectedResult;
    }
    const html_count = try countHtmlFiles(design_root);
    if (html_count != 6) {
        std.debug.print(
            "expected 6 .html files before delete, got {d} under {s}\n",
            .{ html_count, design_root },
        );
        return error.TestUnexpectedResult;
    }

    // DELETE the design item.
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, design_id },
    );
    defer gpa.free(path);
    {
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        const ok = doc.boolean("success") orelse {
            std.debug.print("DELETE response has no `success`: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        };
        if (!ok) {
            std.debug.print("DELETE response success should be true: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }

    // The on-disk design folder is gone (cascade-rmdir).
    if (pathExists(design_root)) {
        const left = try countHtmlFiles(design_root);
        std.debug.print(
            "design folder {s} should be gone after item delete ({d} .html file(s) left behind)\n",
            .{ design_root, left },
        );
        return error.TestUnexpectedResult;
    }

    // The DB row is also gone (verified via list).
    const raw = try listItems(&h, ws_id);
    defer gpa.free(raw);
    var doc = try parseJson(raw);
    defer doc.deinit();
    if (listContains(raw, design_id)) {
        std.debug.print("deleted design item '{s}' still in list: {s}\n", .{ design_id, raw });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Test 13: DELETE chat item doesn't touch sibling items
// ============================================================================

// 5 items of mixed types; DELETE chat item #3; the other 4 are untouched (no
// FK cascade surprise, no orphan rows that the API forgets about).
test "delete_chat_item_does_not_touch_other_items" {
    try harness.requirePabrikBin(io, gpa);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const ws_id = try createWorkspace(&h, "items-crud-ws");
    defer gpa.free(ws_id);
    const base = try harness.harnessPath(gpa, h.temp_dir, &.{"pabrik-items-crud"});
    defer gpa.free(base);

    const Seed = struct { label: []const u8, kind: []const u8 };
    const seeds = [_]Seed{
        .{ .label = "alpha", .kind = "chat" },
        .{ .label = "bravo", .kind = "kanban" },
        .{ .label = "charlie-target", .kind = "chat" },
        .{ .label = "delta", .kind = "kanban" },
        .{ .label = "echo", .kind = "chat" },
    };

    var ids: [seeds.len][]u8 = undefined;
    for (seeds, 0..) |seed, i| {
        const raw = try createItem(&h, ws_id, seed.label, seed.kind, base);
        defer gpa.free(raw);
        ids[i] = try itemIdOf(raw);
    }
    defer for (ids) |id| gpa.free(id);

    const target_index: usize = 2;
    const target_id = ids[target_index];

    // Delete the chat item.
    const path = try std.fmt.allocPrint(
        gpa,
        "/api/workspaces/{s}/items/{s}",
        .{ ws_id, target_id },
    );
    defer gpa.free(path);
    {
        var r = try h.http(io, .DELETE, path, .{ .expect = &.{200} });
        defer r.deinit();
    }

    // The other 4 items are still present and GET-able.
    {
        const raw = try listItems(&h, ws_id);
        defer gpa.free(raw);
        var doc = try parseJson(raw);
        defer doc.deinit();
        for (ids, 0..) |id, i| {
            if (i == target_index) continue;
            if (!listContains(raw, id)) {
                std.debug.print(
                    "sibling item '{s}' (type='{s}') missing from list after sibling delete\n",
                    .{ id, seeds[i].kind },
                );
                return error.TestUnexpectedResult;
            }
            // GET-by-id still works (the DB row is intact).
            const got_raw = try getItem(&h, ws_id, id);
            defer gpa.free(got_raw);
            var got_doc = try parseJson(got_raw);
            defer got_doc.deinit();
            const got_id = got_doc.str("id") orelse return error.TestUnexpectedResult;
            if (!std.mem.eql(u8, got_id, id)) {
                std.debug.print("sibling GET id mismatch: '{s}' != '{s}'\n", .{ got_id, id });
                return error.TestUnexpectedResult;
            }
            const got_kind = got_doc.str("item_type") orelse return error.TestUnexpectedResult;
            if (!std.mem.eql(u8, got_kind, seeds[i].kind)) {
                std.debug.print(
                    "sibling GET item_type mismatch: got '{s}', want '{s}'\n",
                    .{ got_kind, seeds[i].kind },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Python `any(i["id"] == id for i in _list_items(...))`.
fn listContains(raw: []const u8, id: []const u8) bool {
    const arr = itemArray(raw) catch return false;
    for (arr.items) |it| {
        if (it != .object) continue;
        const n = switch (it.object.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, n, id)) return true;
    }
    return false;
}

comptime {
    // Body-analysis barrier — see `harness.zig`'s note: an unreferenced
    // function body is never type-checked, so a stdlib rename inside one
    // stays invisible until a caller appears.
    _ = parseJson;
    _ = createWorkspace;
    _ = createItem;
    _ = itemIdOf;
    _ = getItem;
    _ = listItems;
    _ = itemArray;
    _ = isDefaultFlag;
    _ = createDesignPage;
    _ = addDesignElement;
    _ = pathExists;
    _ = countHtmlFiles;
    _ = makeItemDir;
    _ = Scratch.deinit;
    _ = listContains;
}
