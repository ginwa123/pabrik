//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/move-batch`.
//! Server-side cascade move.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const gserverz = pabrikcore.gserverz;
const design_model = @import("../agentic_loop/design_model.zig");
const http_response = @import("http_response.zig");

/// HTTP request body for move-batch. Each `items[i]`'s `(dx, dy)`
/// cascades to the element + every transitive descendant. Optional
/// fields apply only to the root.
const MoveBatchBody = struct {
    items: []const MoveItemWire = &.{},
};

const MoveItemWire = struct {
    element_id: []const u8 = "",
    dx: i64 = 0,
    dy: i64 = 0,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code via a single exhaustive switch.
pub const DesignElementsMoveBatchError = error{
    /// `items` array was empty — would result in a no-op transaction.
    /// Maps to 400.
    EmptyItems,
    /// `design_model.moveElementsWithDescendantsBatch` returned
    /// `PageNotFound` — the `:page_id` path param doesn't resolve.
    /// Maps to 404.
    PageNotFound,
    /// One or more `element_id` values didn't resolve on the page.
    /// Whole batch is rejected — no partial writes.
    /// Maps to 404.
    ElementNotFound,
    /// A wire item had an empty `element_id`.
    /// Maps to 400.
    BadItem,
    /// Any DB-level failure (PrepareFailed, ExecuteFailed, BindFailed,
    /// QueryFailed, RowNotFound, DatabaseCorrupt, DiskFull, etc.).
    /// Maps to 500.
    DbError,
    /// `allocator.dupe` / `std.json.Stringify.valueAlloc` failed while
    /// building the response body. Maps to 500.
    OutOfMemory,
};

/// Output of the move-batch use-case. Heap-owned; caller releases
/// `updated` via `design_model.freeElements(allocator, updated)`.
pub const MoveBatchOutput = struct {
    updated: []design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

pub const UseCaseInput = struct {
    page_id: []const u8,
    items: []const design_model.MoveItem,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: UseCaseInput,
) DesignElementsMoveBatchError!MoveBatchOutput {
    if (input.items.len == 0) return error.EmptyItems;

    const updated = design_model.moveElementsWithDescendantsBatch(allocator, db, .{
        .page_id = input.page_id,
        .items = input.items,
    }) catch |err| switch (err) {
        error.EmptyItems => return error.EmptyItems,
        error.PageNotFound => return error.PageNotFound,
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };

    return .{ .updated = updated };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsMoveBatchHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate the page_id path param. Empty → 400.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "page_id required"),
        });
    }

    // 2. Validate body presence + JSON shape.
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Request body required"),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(
        MoveBatchBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    // 3. Translate the wire body's `MoveItemWire[]` into
    //    `design_model.MoveItem[]`. Reuse the model struct so the
    //    use-case layer doesn't have to invent its own.
    var inputs_buf: std.ArrayList(design_model.MoveItem) = .empty;
    defer inputs_buf.deinit(allocator);
    for (parsed.items) |it| {
        // Empty element_id → 400 with an explicit message (the model
        // would also reject these as ElementNotFound, but a clearer
        // 400 here helps the frontend debug its batch construction).
        if (it.element_id.len == 0) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try makeErrorJson(allocator, "element_id is required for every item"),
            });
        }
        inputs_buf.append(allocator, .{
            .element_id = it.element_id,
            .dx = it.dx,
            .dy = it.dy,
            .width = it.width,
            .height = it.height,
            .rotation = it.rotation,
        }) catch return error.OutOfMemory;
    }

    // 4. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .items = inputs_buf.items,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.EmptyItems => 400,
            error.BadItem => 400,
            error.PageNotFound => 404,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.EmptyItems => "items array must contain at least one element",
            error.BadItem => "element_id is required for every item",
            error.PageNotFound => "Page not found",
            error.ElementNotFound => "One or more element_ids not found on this page",
            error.DbError => "Failed to move elements",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };

    // 5. Build the success response (200 OK).
    defer {
        design_model.freeElements(allocator, output.updated);
    }

    const mapped = try allocator.alloc(http_response.DesignElementResponse, output.updated.len);
    defer allocator.free(mapped);
    for (output.updated, 0..) |e, i| mapped[i] = http_response.makeDesignElementResponse(e);

    const Wrapper = struct {
        updated: []const http_response.DesignElementResponse,
    };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            Wrapper{ .updated = mapped },
            .{},
        ),
    });
}

// Local helper — mirrors `http_response.makeErrorResponse` but avoids
// the cross-import. The handler is the only caller; the helper is here
// so the response-building block stays small.
fn makeErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(
        allocator,
        struct { @"error": []const u8 }{ .@"error" = message },
        .{},
    );
}

// ─── Behavioural tests for the `POST .../elements/move-batch` handler ────

const testing_handler = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn teardownHandlerMoveBatchDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing_handler.allocator.free(ctx.item_id);
    testing_handler.allocator.free(ctx.item_path);
}

fn insertHandlerMoveBatchElement(
    alloc: std.mem.Allocator,
    db: *database.Db,
    page_id: []const u8,
    name: []const u8,
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

    // Bind empty string as NULL parent_id (the project's COALESCE
    // convention — see `design_model.zig::setElementParent` step 2).
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
        \\    0, 0, 'rectangle', 0,
        \\    '', '', 0, 0, 1.0,
        \\    '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, parent_to_bind });

    return id;
}

fn setupHandlerMoveBatchDb() !TestCtx {
    const alloc = testing_handler.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: database.Db = .{};
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
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '')
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    UNIQUE (workspace_item_id, name),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '',
        \\    x INTEGER NOT NULL DEFAULT 0, y INTEGER NOT NULL DEFAULT 0,
        \\    width INTEGER NOT NULL DEFAULT 375, height INTEGER NOT NULL DEFAULT 667,
        \\    z_index INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        \\    type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\    fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\    stroke_width INTEGER NOT NULL DEFAULT 0,
        \\    corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\    text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\    image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing_handler.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_handler.io, &tmpdir_buf);
    const tmpdir_path = try testing_handler.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_move_batch_handler";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

test "useCase rejects empty items with EmptyItems (no DB call)" {
    const result = useCase(testing_handler.allocator, undefined, .{
        .page_id = "page_test",
        .items = &.{},
    });
    try testing_handler.expectError(error.EmptyItems, result);
}

test "useCase returns updated rows in tree-traversal order on success" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Handler Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "g", 0, 0, 100, 100, "");
    defer alloc.free(group);
    const child1 = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "c1", 10, 10, 50, 50, group);
    defer alloc.free(child1);
    const child2 = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "c2", 60, 60, 50, 50, group);
    defer alloc.free(child2);

    const items = [_]design_model.MoveItem{.{ .element_id = group, .dx = 100, .dy = 50 }};
    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .items = &items,
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 3), output.updated.len);
    // Group first, then children in source order.
    try testing_handler.expectEqualStrings(group, output.updated[0].id);
    try testing_handler.expectEqualStrings(child1, output.updated[1].id);
    try testing_handler.expectEqualStrings(child2, output.updated[2].id);
}

test "useCase returns PageNotFound when page_id does not exist" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const items = [_]design_model.MoveItem{.{ .element_id = "elem_anything", .dx = 1, .dy = 0 }};
    const result = useCase(alloc, &ctx.db, .{
        .page_id = "page_does_not_exist",
        .items = &items,
    });
    try testing_handler.expectError(error.PageNotFound, result);
}

test "useCase returns ElementNotFound when any element_id is missing (no partial writes)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Atomicity Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "a", 0, 0, 50, 50, "");
    defer alloc.free(a);

    // Snapshot a's x before the failing batch.
    var pre_a_x: i64 = 0;
    {
        var q = try ctx.db.query(alloc,
            "SELECT x FROM design_page_elements WHERE id = ?",
            &.{a});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        pre_a_x = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }

    const items = [_]design_model.MoveItem{
        .{ .element_id = a, .dx = 999, .dy = 0 },
        .{ .element_id = "elem_missing", .dx = 0, .dy = 0 },
    };
    const result = useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .items = &items,
    });
    try testing_handler.expectError(error.ElementNotFound, result);

    // Atomicity — a's x MUST be unchanged.
    {
        var q = try ctx.db.query(alloc,
            "SELECT x FROM design_page_elements WHERE id = ?",
            &.{a});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const post_a_x = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        try testing_handler.expectEqual(pre_a_x, post_a_x);
    }
}

test "useCase accepts a single-item batch with width/height/rotation (applies to root only)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Extras Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "g", 0, 0, 100, 100, "");
    defer alloc.free(group);
    const child = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "c", 10, 10, 50, 50, group);
    defer alloc.free(child);

    const items = [_]design_model.MoveItem{
        .{ .element_id = group, .dx = 50, .dy = 50, .width = 500, .height = 300, .rotation = 0.5 },
    };
    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .items = &items,
    });
    defer design_model.freeElements(alloc, output.updated);

    // Group gets translated + resized.
    try testing_handler.expectEqual(@as(i64, 50), output.updated[0].x);
    try testing_handler.expectEqual(@as(i64, 50), output.updated[0].y);
    try testing_handler.expectEqual(@as(i64, 500), output.updated[0].width);
    try testing_handler.expectEqual(@as(i64, 300), output.updated[0].height);

    // Child gets translated but NOT resized.
    try testing_handler.expectEqual(@as(i64, 60), output.updated[1].x);
    try testing_handler.expectEqual(@as(i64, 60), output.updated[1].y);
    try testing_handler.expectEqual(@as(i64, 50), output.updated[1].width);
}

test "useCase accepts dx=0 dy=0 with width change (no translation, just resize)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Resize-Only Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "l", 100, 200, 50, 50, "");
    defer alloc.free(leaf);

    const items = [_]design_model.MoveItem{.{ .element_id = leaf, .dx = 0, .dy = 0, .width = 200 }};
    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .items = &items,
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 1), output.updated.len);
    // x/y UNCHANGED.
    try testing_handler.expectEqual(@as(i64, 100), output.updated[0].x);
    try testing_handler.expectEqual(@as(i64, 200), output.updated[0].y);
    // width CHANGED.
    try testing_handler.expectEqual(@as(i64, 200), output.updated[0].width);
}

test "useCase handles deeply nested subtree (depth 3)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerMoveBatchDb();
    defer teardownHandlerMoveBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Depth Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const g1 = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "g1", 0, 0, 500, 500, "");
    defer alloc.free(g1);
    const g2 = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "g2", 50, 50, 300, 300, g1);
    defer alloc.free(g2);
    const g3 = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "g3", 100, 100, 200, 200, g2);
    defer alloc.free(g3);
    const leaf = try insertHandlerMoveBatchElement(alloc, &ctx.db, page_id, "leaf", 150, 150, 50, 50, g3);
    defer alloc.free(leaf);

    const items = [_]design_model.MoveItem{.{ .element_id = g1, .dx = 5, .dy = 7 }};
    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .items = &items,
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 4), output.updated.len);
    // All four cascaded by the same delta.
    try testing_handler.expectEqual(@as(i64, 5), output.updated[0].x);
    try testing_handler.expectEqual(@as(i64, 7), output.updated[0].y);
    try testing_handler.expectEqual(@as(i64, 55), output.updated[1].x);
    try testing_handler.expectEqual(@as(i64, 57), output.updated[1].y);
    try testing_handler.expectEqual(@as(i64, 105), output.updated[2].x);
    try testing_handler.expectEqual(@as(i64, 107), output.updated[2].y);
    try testing_handler.expectEqual(@as(i64, 155), output.updated[3].x);
    try testing_handler.expectEqual(@as(i64, 157), output.updated[3].y);
}
