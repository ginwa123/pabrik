//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/ungroup`.
//!
//! Dissolve a `group` or `frame` element: reparent its children to
//! the group's parent (or NULL if the group was top-level), then
//! delete the group row. Children keep their absolute x/y — their
//! geometry is independent of the group's bbox.
//!
//! Body: `{ element_id: "elem_g" }`.
//!
//! Response 200: `{ orphaned: <DesignElementResponse>[] }` (the
//! newly-top-level children in their new state).
//!
//! Errors:
//!   - 400 BadGroupId, NotAGroup, EmptyGroup
//!   - 404 PageNotFound
//!   - 500 DbError, OutOfMemory
//!
//! Plan: docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md
//! (Chunk 9 deferred item, now landing)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

const UngroupBody = struct {
    element_id: []const u8,
};

pub fn designElementsUngroupHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UngroupBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    const orphaned = design_model.ungroupElements(allocator, sqlite_db, .{
        .page_id = page_id,
        .element_id = parsed.element_id,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.BadGroupId => 400,
            error.NotAGroup => 400,
            error.EmptyGroup => 400,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.BadGroupId => "element_id is invalid or does not exist on this page",
            error.NotAGroup => "element must be a group or frame",
            error.EmptyGroup => "group has no children — nothing to ungroup",
            error.DbError => "Failed to ungroup elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer {
        for (orphaned) |c| design_model.freeElement(allocator, c);
        allocator.free(orphaned);
    }

    const Response = struct {
        orphaned: []const http_response.DesignElementResponse,
    };
    const mapped = try allocator.alloc(http_response.DesignElementResponse, orphaned.len);
    defer allocator.free(mapped);
    for (orphaned, 0..) |c, i| mapped[i] = http_response.makeDesignElementResponse(c);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .orphaned = mapped },
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_ungroup_test.zig (2026-09-11 flatten) =====
// Behavioural tests for `design_model.ungroupElements` and the
// `POST /ungroup` HTTP handler contract.
// 
// Plan: docs/superpowers/specs/2026-07-29-design-right-click-group-menu.md

const testing = std.testing;
const sqlite = pabrikcore.sqlite;

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    alloc: std.mem.Allocator,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 100, height INTEGER NOT NULL DEFAULT 100,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle',
        \\    rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '',
        \\    stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0,
        \\    opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '',
        \\    text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '',
        \\    parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES ('item_t1', 'ws_t1', 'design', '/tmp')",
        &.{});
    try db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name) " ++
        "VALUES ('page_t1', 'item_t1', 'Test Page')",
        &.{});
    return .{ .db = db, .threaded = threaded, .alloc = alloc };
}

fn teardown(s: *@TypeOf(setupDb() catch @panic("setupDb failed in the design_elements_ungroup test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn insertGroup(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, type) " ++
        "VALUES (?, ?, ?, 'group')",
        &.{ id, page_id, id });
}

fn insertChild(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, id: []const u8, parent_id: []const u8, x: i64, y: i64) !void {
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    try db.exec(alloc,
        "INSERT INTO design_page_elements (id, page_id, name, type, parent_id, x, y) " ++
        "VALUES (?, ?, ?, 'rectangle', ?, ?, ?)",
        &.{ id, page_id, id, parent_id, x_str, y_str });
}

fn readParentId(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !?[]u8 {
    var q = try db.query(alloc,
        "SELECT COALESCE(parent_id, '<NULL>') FROM design_page_elements WHERE id = ?",
        &.{id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "<NULL>")) return null;
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

fn rowExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !bool {
    var q = try db.query(alloc, "SELECT 1 FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return true;
    }
    return false;
}

fn countChildrenOf(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, parent_id: []const u8) !usize {
    var q = try db.query(alloc, "SELECT COUNT(*) FROM design_page_elements WHERE parent_id = ?", &.{parent_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try std.fmt.parseInt(usize, row.values[0], 10);
    }
    return 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "ungroupElements reparents children to top-level and deletes the group" {
    var s = try setupDb();
    defer teardown(&s);
    try insertGroup(s.alloc, &s.db, "page_t1", "g");
    try insertChild(s.alloc, &s.db, "page_t1", "a", "g", 10, 20);
    try insertChild(s.alloc, &s.db, "page_t1", "b", "g", 100, 200);

    const result = try design_model.ungroupElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .element_id = "g",
    });
    defer {
        for (result) |c| design_model.freeElement(s.alloc, c);
        s.alloc.free(result);
    }

    // Group row deleted.
    try testing.expectEqual(false, try rowExists(s.alloc, &s.db, "g"));
    // Both children present.
    try testing.expectEqual(true, try rowExists(s.alloc, &s.db, "a"));
    try testing.expectEqual(true, try rowExists(s.alloc, &s.db, "b"));
    // Both children now have NULL parent_id (top-level).
    const ap = try readParentId(s.alloc, &s.db, "a");
    defer if (ap) |p| s.alloc.free(p);
    try testing.expectEqual(@as(?[]u8, null), ap);
    const bp = try readParentId(s.alloc, &s.db, "b");
    defer if (bp) |p| s.alloc.free(p);
    try testing.expectEqual(@as(?[]u8, null), bp);
    // Result has 2 elements.
    try testing.expectEqual(@as(usize, 2), result.len);
}

test "ungroupElements reparents to the group's parent when nested" {
    var s = try setupDb();
    defer teardown(&s);
    try insertGroup(s.alloc, &s.db, "page_t1", "outer");
    try insertGroup(s.alloc, &s.db, "page_t1", "inner");
    try insertChild(s.alloc, &s.db, "page_t1", "a", "inner", 10, 10);

    // Set outer's parent_id via direct UPDATE (cheaper than re-running
    // the test schema with nested-group support).
    try s.db.exec(s.alloc,
        "UPDATE design_page_elements SET parent_id = 'outer' WHERE id = 'inner'",
        &.{});

    const result = try design_model.ungroupElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .element_id = "inner",
    });
    defer {
        for (result) |c| design_model.freeElement(s.alloc, c);
        s.alloc.free(result);
    }

    // inner is deleted.
    try testing.expectEqual(false, try rowExists(s.alloc, &s.db, "inner"));
    // 'a' is now under 'outer' (the outer's children count went from 1
    // — the inner group — to 1 — element 'a' — i.e. net children of
    // outer stays 1).
    try testing.expectEqual(@as(usize, 1), try countChildrenOf(s.alloc, &s.db, "outer"));
    const ap = try readParentId(s.alloc, &s.db, "a");
    defer if (ap) |p| s.alloc.free(p);
    try expectStringContainsOne(ap orelse "", "outer");
}

fn expectStringContainsOne(haystack: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "ungroupElements returns EmptyGroup when the group has no children" {
    var s = try setupDb();
    defer teardown(&s);
    try insertGroup(s.alloc, &s.db, "page_t1", "lonely");
    const result = design_model.ungroupElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .element_id = "lonely",
    });
    try testing.expectError(error.EmptyGroup, result);
    // The empty group should still exist (no destructive side-effects).
    try testing.expectEqual(true, try rowExists(s.alloc, &s.db, "lonely"));
}

test "ungroupElements returns NotAGroup when the element is a rectangle" {
    var s = try setupDb();
    defer teardown(&s);
    // Insert a non-group element.
    try s.db.exec(s.alloc,
        "INSERT INTO design_page_elements (id, page_id, name, type) " ++
        "VALUES ('notgroup', 'page_t1', 'notgroup', 'rectangle')",
        &.{});
    const result = design_model.ungroupElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .element_id = "notgroup",
    });
    try testing.expectError(error.NotAGroup, result);
}

test "ungroupElements returns BadGroupId when the element does not exist" {
    var s = try setupDb();
    defer teardown(&s);
    const result = design_model.ungroupElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .element_id = "ghost",
    });
    try testing.expectError(error.BadGroupId, result);
}
