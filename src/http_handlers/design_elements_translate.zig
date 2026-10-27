//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/translate`.
//! Translate (move) a single element by a `(dx, dy)` delta.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body. Both `dx` and `dy` are required.
const TranslateBody = struct {
    dx: ?i64 = null,
    dy: ?i64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message.
pub const DesignElementTranslateError = error{
    ElementIdRequired,
    /// `dx` or `dy` was missing from the body.
    MissingDelta,
    ElementNotFound,
    DbError,
    OutOfMemory,
};

pub const TranslateOutput = struct {
    /// The cascaded set of updated elements (1 element for leaves,
    /// 1 + N for group/frame cascade). Heap-owned; caller frees
    /// with `design_model.freeElements`.
    updated: []design_model.DesignElement,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    page_id: []const u8,
    element_id: []const u8,
    dx: i64,
    dy: i64,
) DesignElementTranslateError!TranslateOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

    // Look up the element so we can decide single-element vs cascade.
    const target = design_model.getElement(allocator, db, element_id) catch
        |err| switch (err) {
            error.ElementNotFound => return error.ElementNotFound,
            else => return error.DbError,
        };
    defer design_model.freeElement(allocator, target);

    // Cascade if the target is a group/frame. The recursive CTE walks DOWN
    // through `parent_id` and updates the whole subtree in one SQL
    // transaction.
    if (std.mem.eql(u8, target.elem_type, "group") or
        std.mem.eql(u8, target.elem_type, "frame"))
    {
        const items = [_]design_model.MoveItem{.{
            .element_id = element_id,
            .dx = dx,
            .dy = dy,
        }};
        const updated = design_model.moveElementsWithDescendantsBatch(
            allocator,
            db,
            .{ .page_id = page_id, .items = &items },
        ) catch |err| switch (err) {
            error.EmptyItems => unreachable, // we just constructed 1 item
            error.PageNotFound => return error.DbError,
            error.ElementNotFound => return error.ElementNotFound,
            else => return error.DbError,
        };
        return .{ .updated = updated };
    }

    // Leaf: just translate the single row.
    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .x = target.x + dx,
        .y = target.y + dy,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch
        return error.DbError;

    // Wrap the single element in a 1-element slice so the response shape is
    // uniform with the cascade path.
    const wrapped = try allocator.alloc(design_model.DesignElement, 1);
    wrapped[0] = element;
    return .{ .updated = wrapped };
}

pub fn designElementsTranslateHandler(
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

    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "page_id required"),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        TranslateBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    const dx = parsed.dx orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "dx is required"),
        });
    };
    const dy = parsed.dy orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "dy is required"),
        });
    };

    const output = useCase(allocator, sqlite_db, page_id, element_id, dx, dy) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.MissingDelta => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.MissingDelta => "dx and dy are both required",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to translate element",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };
    defer design_model.freeElements(allocator, output.updated);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            struct { updated: []const design_model.DesignElement }{ .updated = output.updated },
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

// ===== Tests merged from design_elements_translate_test.zig (2026-09-11
// flatten) ===== Behavioural tests for the `POST .../translate` handler.

const http_handlers = @import("mod.zig");
const migration = @import("../migrations/migration.zig");

const testing = std.testing;
const testing_alloc = testing.allocator;

const TranslateError = http_handlers.designElementsTranslateError;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    page_id: []u8,
    tmpdir_path: []u8,
};

fn teardownTranslateCtx(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing_alloc.free(ctx.item_id);
    testing_alloc.free(ctx.page_id);
    testing_alloc.free(ctx.tmpdir_path);
}

/// Open a fresh in-memory DB and walk every migration in
/// `src/migrations/migration.zig` so the schema matches production exactly.
fn setupTranslateCtx() !TestCtx {
    var threaded = std.Io.Threaded.init(testing_alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
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

    const item_id = try testing_alloc.dupe(u8, "item_translate_test");
    errdefer testing_alloc.free(item_id);
    try db.exec(testing_alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id, tmpdir_path });

    const page_id = try design_model.setDesignPage(testing_alloc, &db, .{
        .item_id = item_id,
        .page_name = "Translate Test",
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

fn insertTranslateElement(
    alloc: std.mem.Allocator,
    db: *database.Db,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    parent_id: []const u8,
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
    const parent_to_bind: []const u8 = if (parent_id.len == 0) "" else parent_id;

    try db.exec(alloc,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height,
        \\    z_index, position, type, rotation,
        \\    fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, '', ?, ?, ?, ?,
        \\    0, 0, ?, 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, elem_type, parent_to_bind });

    return id;
}

test "useCase translates a leaf rectangle by (dx, dy) and returns 1 element" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const rect = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "r", "rectangle", 100, 200, 50, 50, "");
    defer alloc.free(rect);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, rect, 30, -10);
    defer design_model.freeElements(alloc, output.updated);

    try testing.expectEqual(@as(usize, 1), output.updated.len);
    try testing.expectEqual(@as(i64, 130), output.updated[0].x);
    try testing.expectEqual(@as(i64, 190), output.updated[0].y);
    try testing.expect(output.updated[0].id.len > 0);
}

test "useCase translates a group and CASCADES the delta to its descendants (the user's bug-fix requirement)" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    // Layout: group G (x=50, y=100) — type='group' child1 c1 (x=60, y=110,
    // parent=G) — type='rectangle' child2 c2 (x=200, y=200, parent=G) —
    // type='rectangle'
    const group = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "g", "group", 50, 100, 200, 200, "");
    defer alloc.free(group);
    const child1 = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "c1", "rectangle", 60, 110, 30, 30, group);
    defer alloc.free(child1);
    const child2 = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "c2", "rectangle", 200, 200, 30, 30, group);
    defer alloc.free(child2);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, group, 100, 50);
    defer design_model.freeElements(alloc, output.updated);

    // Should return group + 2 children = 3 elements.
    try testing.expectEqual(@as(usize, 3), output.updated.len);

    // Build a map of id → updated row for stable assertions.
    var found_g: bool = false;
    var found_c1: bool = false;
    var found_c2: bool = false;
    for (output.updated) |el| {
        if (std.mem.eql(u8, el.id, group)) {
            try testing.expectEqual(@as(i64, 150), el.x);
            try testing.expectEqual(@as(i64, 150), el.y);
            found_g = true;
        } else if (std.mem.eql(u8, el.id, child1)) {
            try testing.expectEqual(@as(i64, 160), el.x);
            try testing.expectEqual(@as(i64, 160), el.y);
            found_c1 = true;
        } else if (std.mem.eql(u8, el.id, child2)) {
            try testing.expectEqual(@as(i64, 300), el.x);
            try testing.expectEqual(@as(i64, 250), el.y);
            found_c2 = true;
        }
    }
    try testing.expect(found_g);
    try testing.expect(found_c1);
    try testing.expect(found_c2);

    // DB-level confirmation: every cascaded row moved by the delta.
    try testing.expectEqual(@as(i64, 150), try readX(alloc, &ctx.db, group));
    try testing.expectEqual(@as(i64, 160), try readX(alloc, &ctx.db, child1));
    try testing.expectEqual(@as(i64, 300), try readX(alloc, &ctx.db, child2));
}

test "useCase cascades to grandchildren (depth 2)" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const outer = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "outer", "group", 0, 0, 200, 200, "");
    defer alloc.free(outer);
    const inner = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "inner", "group", 50, 50, 100, 100, outer);
    defer alloc.free(inner);
    const leaf = try insertTranslateElement(alloc, &ctx.db, ctx.page_id, "leaf", "rectangle", 70, 70, 30, 30, inner);
    defer alloc.free(leaf);

    const output = try http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, outer, 5, 7);
    defer design_model.freeElements(alloc, output.updated);

    try testing.expectEqual(@as(usize, 3), output.updated.len);

    try testing.expectEqual(@as(i64, 5), try readX(alloc, &ctx.db, outer));
    try testing.expectEqual(@as(i64, 55), try readX(alloc, &ctx.db, inner));
    try testing.expectEqual(@as(i64, 75), try readX(alloc, &ctx.db, leaf));
}

test "useCase returns ElementNotFound for an unknown element_id" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const result = http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, "elem_does_not_exist", 0, 0);
    try testing.expectError(error.ElementNotFound, result);
}

test "useCase returns ElementIdRequired for an empty element_id" {
    const alloc = testing_alloc;
    var ctx = try setupTranslateCtx();
    defer teardownTranslateCtx(&ctx);

    const result = http_handlers.designElementsTranslateUseCase(alloc, &ctx.db, ctx.page_id, "", 0, 0);
    try testing.expectError(error.ElementIdRequired, result);
}

fn readX(alloc: std.mem.Allocator, db: *database.Db, id: []const u8) !i64 {
    var q = try db.query(alloc, "SELECT x FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse unreachable;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}
