//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch`.
//! ⚠️ DEPRECATED — replaced by `POST .../elements/move-batch` (server- side

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const gserverz = pabrikcore.gserverz;
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for batch-geometry-update. Each `updates[i]` is a
/// partial geometry patch — only the listed fields are SET in the SQL UPDATE;
/// null fields are left unchanged.
const BatchBody = struct {
    updates: []const SingleUpdate = &.{},
};

const SingleUpdate = struct {
    element_id: []const u8 = "",
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code via a single exhaustive switch.
pub const DesignElementGeometryBatchError = error{
    /// `updates` array was empty — would result in a no-op transaction.
    /// Maps to 400.
    EmptyUpdates,
    /// `design_model.updateElementsBatch` returned `PageNotFound` —
    /// the `:page_id` path param doesn't resolve.
    /// Maps to 404.
    PageNotFound,
    /// One or more `element_id` values didn't resolve on the page.
    /// Whole batch is rejected — no partial writes.
    /// Maps to 404.
    ElementNotFound,
    /// Any DB-level failure (PrepareFailed, ExecuteFailed, BindFailed,
    /// QueryFailed, RowNotFound, DatabaseCorrupt, DiskFull, etc.).
    /// Maps to 500.
    DbError,
    /// `allocator.dupe` / `std.json.Stringify.valueAlloc` failed while
    /// building the response body. Maps to 500.
    OutOfMemory,
};

/// Output of the batch-geometry-update use-case. Heap-owned; caller
/// releases `updated` via `freeElements(allocator, updated)`.
pub const UpdateGeometryBatchOutput = struct {
    updated: []design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

pub const UseCaseInput = struct {
    page_id: []const u8,
    updates: []const design_model.UpdateElementInput,
};

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: UseCaseInput,
) DesignElementGeometryBatchError!UpdateGeometryBatchOutput {
    if (input.updates.len == 0) return error.EmptyUpdates;

    const updated = design_model.updateElementsBatch(allocator, db, .{
        .page_id = input.page_id,
        .updates = input.updates,
    }) catch |err| switch (err) {
        error.EmptyUpdates => return error.EmptyUpdates,
        error.PageNotFound => return error.PageNotFound,
        error.ElementNotFound => return error.ElementNotFound,
        else => return error.DbError,
    };

    return .{ .updated = updated };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsGeometryBatchHandler(
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
        BatchBody,
        allocator,
        req.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try makeErrorJson(allocator, "Invalid JSON body"),
        });
    };

    // 3. Translate the wire body's `SingleUpdate[]` into
    //    `design_model.UpdateElementInput[]`. Reuse the model struct so
    //    the use-case layer doesn't have to invent its own.
    var inputs_buf: std.ArrayList(design_model.UpdateElementInput) = .empty;
    defer inputs_buf.deinit(allocator);
    for (parsed.updates) |u| {
        // Empty element_id → 400 with an explicit message (the model
        // would also reject these as ElementNotFound, but a clearer
        // 400 here helps the frontend debug its batch construction).
        if (u.element_id.len == 0) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try makeErrorJson(allocator, "element_id is required for every update"),
            });
        }
        inputs_buf.append(allocator, .{
            .element_id = u.element_id,
            .x = u.x,
            .y = u.y,
            .width = u.width,
            .height = u.height,
            .rotation = u.rotation,
        }) catch return error.OutOfMemory;
    }

    // 4. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .updates = inputs_buf.items,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.EmptyUpdates => 400,
            error.PageNotFound => 404,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.EmptyUpdates => "updates array must contain at least one element",
            error.PageNotFound => "Page not found",
            error.ElementNotFound => "One or more element_ids not found on this page",
            error.DbError => "Failed to update element geometries",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try makeErrorJson(allocator, message),
        });
    };

    // 4. Build the success response (200 OK).
    defer {
        design_model.freeElements(allocator, output.updated);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            struct { updated: []const design_model.DesignElement }{ .updated = output.updated },
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

// ─── Behavioural tests for the `POST .../elements/geometry-batch` handler ─

const testing_handler = std.testing;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
};

fn teardownHandlerBatchDb(ctx: *TestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
    testing_handler.allocator.free(ctx.item_id);
    testing_handler.allocator.free(ctx.item_path);
}

fn insertHandlerElementRaw(
    alloc: std.mem.Allocator,
    db: *database.Db,
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
        \\    '', '', '', NULL,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str });

    return id;
}

fn setupHandlerDbAndItem() !TestCtx {
    const alloc = testing_handler.allocator;
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
        \\    created_at TIMESTAMP,
        \\    updated_at TIMESTAMP,
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
        \\    created_at TIMESTAMP, updated_at TIMESTAMP,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing_handler.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_handler.io, &tmpdir_buf);
    const tmpdir_path = try testing_handler.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_geometry_batch_handler";
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

test "useCase rejects empty updates with EmptyUpdates (no DB call)" {
    const result = useCase(testing_handler.allocator, undefined, .{
        .page_id = "page_test",
        .updates = &.{},
    });
    try testing_handler.expectError(error.EmptyUpdates, result);
}

test "useCase returns updated rows in input order on success" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerDbAndItem();
    defer teardownHandlerBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Handler Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertHandlerElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertHandlerElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);

    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 111 },
            .{ .element_id = b, .x = 222 },
        },
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 2), output.updated.len);
    try testing_handler.expectEqualStrings(a, output.updated[0].id);
    try testing_handler.expectEqualStrings(b, output.updated[1].id);
    try testing_handler.expectEqual(@as(i64, 111), output.updated[0].x);
    try testing_handler.expectEqual(@as(i64, 222), output.updated[1].x);
}

test "useCase returns PageNotFound when page_id does not exist" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerDbAndItem();
    defer teardownHandlerBatchDb(&ctx);

    const result = useCase(alloc, &ctx.db, .{
        .page_id = "page_does_not_exist",
        .updates = &.{.{ .element_id = "elem_anything", .x = 1 }},
    });
    try testing_handler.expectError(error.PageNotFound, result);
}

test "useCase returns ElementNotFound when any element_id is missing (no partial writes)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerDbAndItem();
    defer teardownHandlerBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Atomicity Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertHandlerElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    var pre_a_x: i64 = 0;
    {
        const all = try design_model.listElements(alloc, &ctx.db, page_id);
        defer design_model.freeElements(alloc, all);
        for (all) |el| {
            if (std.mem.eql(u8, el.id, a)) pre_a_x = el.x;
        }
    }

    const result = useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 999 },
            .{ .element_id = "elem_missing", .x = 1 },
        },
    });
    try testing_handler.expectError(error.ElementNotFound, result);

    const post = try design_model.listElements(alloc, &ctx.db, page_id);
    defer design_model.freeElements(alloc, post);
    try testing_handler.expectEqual(@as(usize, 1), post.len);
    try testing_handler.expectEqual(pre_a_x, post[0].x);
}

test "useCase accepts a single-element batch (N=1)" {
    const alloc = testing_handler.allocator;
    var ctx = try setupHandlerDbAndItem();
    defer teardownHandlerBatchDb(&ctx);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "N=1 Test",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertHandlerElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    const output = try useCase(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .x = 777 }},
    });
    defer design_model.freeElements(alloc, output.updated);

    try testing_handler.expectEqual(@as(usize, 1), output.updated.len);
    try testing_handler.expectEqualStrings(a, output.updated[0].id);
    try testing_handler.expectEqual(@as(i64, 777), output.updated[0].x);
}