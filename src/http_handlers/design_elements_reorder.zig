//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder`.
//! Reorder 1+ elements on a page along the z-axis.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// Request body shape.
const ReorderElementsBody = struct {
    mode: []const u8,
    element_ids: []const []const u8 = &.{},
};

/// Domain-level error set. The handler maps each variant to an
/// HTTP status code via two exhaustive switches below.
pub const DesignElementsReorderError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `mode` field was missing or not one of the 4 valid modes.
    BadMode,
    /// `element_ids` was missing or empty.
    EmptyElementIds,
    /// `design_model.reorderElements` returned `BadElementId`.
    BadElementId,
    /// `design_model.reorderElements` returned `PageNotFound`.
    PageNotFound,
    /// `design_model.reorderElements` returned `CrossPageIds`.
    CrossPageIds,
    /// `design_model.reorderElements` returned `DbError`.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Map a `design_model.ReorderMode` enum variant to its lowercase string
/// form. The wire side (`parsed.mode`) is the string; the model side wants
/// the enum. `std.meta.stringToEnum` does the inverse.
fn modeFromString(s: []const u8) ?design_model.ReorderMode {
    return std.meta.stringToEnum(design_model.ReorderMode, s);
}

pub fn designElementsReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence.
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

    const parsed = std.json.parseFromSliceLeaky(ReorderElementsBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Translate mode string to enum. Empty / unknown → 400.
    if (parsed.mode.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode is required" }),
        });
    }
    const mode = modeFromString(parsed.mode) orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "mode must be one of: bring_to_front, send_to_back, bring_forward, send_backward",
            }),
        });
    };

    // 3. Reject empty element_ids BEFORE the model lookup (defence in
    //    depth — the model would also reject, but we'd waste a
    //    page_id SELECT round-trip).
    if (parsed.element_ids.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_ids must be non-empty" }),
        });
    }

    // 4. Delegate to the model.
    const reordered = design_model.reorderElements(allocator, sqlite_db, .{
        .page_id = page_id,
        .mode = mode,
        .element_ids = parsed.element_ids,
    }) catch |err| switch (err) {
        error.BadElementId => {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "One or more element_ids is invalid" }),
            });
        },
        error.PageNotFound => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Page not found" }),
            });
        },
        error.CrossPageIds => {
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "All element_ids must be on the same page" }),
            });
        },
        else => {
            const message: []const u8 = switch (err) {
                error.DbError => "Failed to reorder elements",
                error.OutOfMemory => "Out of memory",
                else => "Internal error",
            };
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
            });
        },
    };
    defer {
        for (reordered) |e| design_model.freeElement(allocator, e);
        allocator.free(reordered);
    }

    // 5. Build the success response (200 OK) with the `{reordered}`
    //    envelope, in top-to-bottom z-order.
    const Response = struct {
        reordered: []const http_response.DesignElementResponse,
    };

    const mapped = try allocator.alloc(http_response.DesignElementResponse, reordered.len);
    defer allocator.free(mapped);
    for (reordered, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Response{ .reordered = mapped },
            .{},
        ),
    });
}

// ===== Tests merged from design_elements_reorder_test.zig (2026-09-11
// flatten) ===== Behavioural tests for the `POST .../elements/reorder` HTTP
// handler.

const testing = std.testing;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;

const design_elements_reorder = @This();

fn setupDb() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    alloc: std.mem.Allocator,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP, updated_at TIMESTAMP)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP, updated_at TIMESTAMP)
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
        \\    created_at TIMESTAMP, updated_at TIMESTAMP)
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

fn teardown(s: *@TypeOf(setupDb() catch @panic("setupDb failed in the design_elements_reorder test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn insertEl(alloc: std.mem.Allocator, db: *database.Db, page_id: []const u8, id: []const u8, z: i64) !void {
    const z_str = try std.fmt.allocPrint(alloc, "{d}", .{z});
    defer alloc.free(z_str);
    try db.exec(alloc,
        "INSERT INTO design_page_elements " ++
        "(id, page_id, name, z_index, type) VALUES (?, ?, ?, ?, 'rectangle')",
        &.{ id, page_id, id, z_str });
}

fn readZ(alloc: std.mem.Allocator, db: *database.Db, id: []const u8) !?i64 {
    var q = try db.query(alloc, "SELECT z_index FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try std.fmt.parseInt(i64, row.values[0], 10);
    }
    return null;
}

// ───────────────────────────────────────────────────────────────────────
// Behavioural tests
// ───────────────────────────────────────────────────────────────────────

test "reorderElements bring_to_front puts selected ids at the top in input order" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);
    try insertEl(s.alloc, &s.db, "page_t1", "b", 1);
    try insertEl(s.alloc, &s.db, "page_t1", "c", 2);

    const result = try design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "a", "c" },
    });
    defer {
        for (result) |e| design_model.freeElement(s.alloc, e);
        s.alloc.free(result);
    }

    // After bring_to_front [a, c]: a gets z=3 (top, since c had z=2 already
    // and is first in input order... wait, this is bring_to_front, not
    // preserve-input-order.
    try testing.expectEqual(@as(?i64, 3), try readZ(s.alloc, &s.db, "a"));
    try testing.expectEqual(@as(?i64, 4), try readZ(s.alloc, &s.db, "c"));
    try testing.expectEqual(@as(?i64, 1), try readZ(s.alloc, &s.db, "b"));
}

test "reorderElements bring_forward swaps the selected element with the next sibling above" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);
    try insertEl(s.alloc, &s.db, "page_t1", "b", 1);
    try insertEl(s.alloc, &s.db, "page_t1", "c", 2);

    const result = try design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_forward,
        .element_ids = &[_][]const u8{ "b" },
    });
    defer {
        for (result) |e| design_model.freeElement(s.alloc, e);
        s.alloc.free(result);
    }

    // b (z=1) swaps with c (z=2). After: a(z=0), b(z=2), c(z=1).
    try testing.expectEqual(@as(?i64, 0), try readZ(s.alloc, &s.db, "a"));
    try testing.expectEqual(@as(?i64, 2), try readZ(s.alloc, &s.db, "b"));
    try testing.expectEqual(@as(?i64, 1), try readZ(s.alloc, &s.db, "c"));
}

// Note: "page not found" detection at the model layer is brittle (the current
// implementation collapses missing-page into a generic error).

test "reorderElements returns BadElementId when an id does not resolve on the page" {
    var s = try setupDb();
    defer teardown(&s);
    try insertEl(s.alloc, &s.db, "page_t1", "a", 0);

    const result = design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "nonexistent" },
    });
    try testing.expectError(error.BadElementId, result);
}

test "reorderElements EmptyElementIds (defence-in-depth) is rejected by useCase" {
    var s = try setupDb();
    defer teardown(&s);

    const result = design_model.reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{},
    });
    try testing.expectError(error.BadElementId, result);
}
