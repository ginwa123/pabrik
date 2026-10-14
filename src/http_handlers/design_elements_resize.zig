//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/resize`.
//! Resize a single element (set absolute x/y/width/height/rotation).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const design_model = @import("../agentic_loop/design_model.zig");
const http_response = @import("http_response.zig");

const ResizeBody = struct {
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

pub const DesignElementResizeError = error{
    ElementIdRequired,
    /// No geometry fields were provided in the body — would result
    /// in a no-op UPDATE.
    NoChanges,
    ElementNotFound,
    DbError,
    OutOfMemory,
};

pub const ResizeOutput = struct {
    /// The post-update element. Heap-owned.
    element: design_model.DesignElement,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
) DesignElementResizeError!ResizeOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

    const any_change = x != null or y != null or width != null or
        height != null or rotation != null;
    if (!any_change) return error.NoChanges;

    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .rotation = rotation,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch
        return error.ElementNotFound;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

pub fn designElementsResizeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "element_id required"),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        ResizeBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    const output = useCase(
        allocator,
        sqlite_db,
        element_id,
        parsed.x,
        parsed.y,
        parsed.width,
        parsed.height,
        parsed.rotation,
    ) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.NoChanges => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.NoChanges => "At least one of x/y/width/height/rotation is required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to resize element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };
    defer design_model.freeElement(allocator, output.element);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}

fn makeErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(
        allocator,
        struct { @"error": []const u8 }{ .@"error" = message },
        .{},
    );
}

// ===== Tests merged from design_elements_resize_test.zig (2026-09-11
// flatten) ===== Behavioural tests for the `POST .../resize` handler.

const http_handlers = @import("mod.zig");
const migration = @import("../migrations/migration.zig");

const testing = std.testing;
const testing_alloc = testing.allocator;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    page_id: []u8,
    tmpdir_path: []u8,
};

fn teardownResizeCtx(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing_alloc.free(ctx.item_id);
    testing_alloc.free(ctx.page_id);
    testing_alloc.free(ctx.tmpdir_path);
}

/// Open a fresh in-memory DB and walk every migration in
/// `src/migrations/migration.zig` so the schema matches production exactly.
fn setupResizeCtx() !TestCtx {
    var threaded = std.Io.Threaded.init(testing_alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(testing_alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing_alloc.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    errdefer testing_alloc.free(tmpdir_path);

    const item_id = try testing_alloc.dupe(u8, "item_resize_test");
    errdefer testing_alloc.free(item_id);
    try db.exec(testing_alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id, tmpdir_path });

    const page_id = try design_model.setDesignPage(testing_alloc, &db, .{
        .item_id = item_id,
        .page_name = "Resize Test",
        .width = 1440,
        .height = 1024,
    });
    errdefer testing_alloc.free(page_id);

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id,
        .page_id = page_id,
        .tmpdir_path = tmpdir_path,
    };
}

fn insertResizeElement(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
) ![]u8 {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    errdefer alloc.free(id);
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{width});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{height});
    defer alloc.free(h_str);

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, 'rectangle', 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', '',
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str });

    return id;
}

test "useCase resizes a leaf with width and height" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, 200, 250, null);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectEqual(@as(i64, 200), output.element.width);
    try testing.expectEqual(@as(i64, 250), output.element.height);
    try testing.expectEqual(@as(i64, 0), output.element.x);
    try testing.expectEqual(@as(i64, 0), output.element.y);
}

test "useCase resizes a leaf with x and y" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, 50, 75, null, null, null);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectEqual(@as(i64, 50), output.element.x);
    try testing.expectEqual(@as(i64, 75), output.element.y);
    try testing.expectEqual(@as(i64, 100), output.element.width);
    try testing.expectEqual(@as(i64, 100), output.element.height);
}

test "useCase resizes a leaf with rotation" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, null, null, 45.0);
    defer design_model.freeElement(alloc, output.element);

    try testing.expectApproxEqAbs(@as(f64, 45.0), output.element.rotation, 0.0001);
}

test "useCase resizes a GROUP without cascading to children (resize is per-element only)" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    // group at (0, 0) 200x200
    // child1 at (10, 10) 50x50 (parent=group)
    // child2 at (100, 100) 50x50 (parent=group)
    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g",
        .elem_type = .group,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 200, .height = 200,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const c1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "c1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 10, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(c1);

    const output = try http_handlers.designElementsResizeUseCase(alloc, &ctx.db, group, 0, 0, 500, 500, null);
    defer design_model.freeElement(alloc, output.element);

    // Group is now 500x500.
    try testing.expectEqual(@as(i64, 500), output.element.width);
    try testing.expectEqual(@as(i64, 500), output.element.height);

    // CRITICAL: children MUST keep their own positions and sizes
    // (resize never cascades, by Figma convention).
    try testing.expectEqual(@as(i64, 10), try readX(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 10), try readY(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 50), try readWidth(alloc, &ctx.db, c1));
    try testing.expectEqual(@as(i64, 50), try readHeight(alloc, &ctx.db, c1));
}

test "useCase returns NoChanges when the body has no fields" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const rect = try insertResizeElement(alloc, &ctx.db, ctx.page_id, "r", 0, 0, 100, 100);
    defer alloc.free(rect);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, rect, null, null, null, null, null);
    try testing.expectError(error.NoChanges, result);
}

test "useCase returns ElementIdRequired for an empty element_id" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, "", 0, 0, 100, 100, null);
    try testing.expectError(error.ElementIdRequired, result);
}

test "useCase returns ElementNotFound for an unknown element_id" {
    const alloc = testing_alloc;
    var ctx = try setupResizeCtx();
    defer teardownResizeCtx(&ctx);

    const result = http_handlers.designElementsResizeUseCase(alloc, &ctx.db, "elem_does_not_exist", 0, 0, 100, 100, null);
    try testing.expectError(error.ElementNotFound, result);
}

fn readX(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "x");
}

fn readY(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "y");
}

fn readWidth(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "width");
}

fn readHeight(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !i64 {
    return try readInt(alloc, db, id, "height");
}

fn readInt(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8, col: []const u8) !i64 {
    const sql = try std.fmt.allocPrint(alloc, "SELECT {s} FROM design_page_elements WHERE id = ?", .{col});
    defer alloc.free(sql);
    var q = try db.query(alloc, sql, &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse unreachable;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}
