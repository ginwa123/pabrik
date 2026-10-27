//! LLM tool: `move_design_element` — translates an existing design element by
//! a `(dx, dy)` delta.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `move_design_element` tool.
pub const MoveDesignElementInput = struct {
    /// The element id to translate. Must exist on the active page.
    element_id: []const u8 = "",
    /// X translation delta (design-px). Cascades to descendants when
    /// `apply_to_children = true`.
    dx: i64 = 0,
    /// Y translation delta (design-px). Cascades to descendants when
    /// `apply_to_children = true`.
    dy: i64 = 0,
    /// Optional. Applies ONLY to the root element (not descendants).
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    /// Default true. Pass false to move a single element only (skip
    /// the backend's recursive CTE cascade).
    apply_to_children: bool = true,
};

/// Top-level tool definition for the LLM.
pub const move_design_element_tool_system_prompt =
    \\## Move Design Element Tool — Behavior
    \\Use `move_design_element` to translate an element by `dx`/`dy` (cascades to descendants by default).
    \\- Use for moving a whole group or a single leaf. Set `apply_to_children=false` to move only the root.
    \\
;

pub const move_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "move_design_element",
        .description =
        \\Translate an existing design element by a (dx, dy) delta in one atomic batch PATCH. The `element_id` must reference an element on the active page; dx and dy are mandatory (a zero delta is valid for a pure resize).
        \\
        \\Discover ids via `set_design_page` — each element object's `id` field carries the id.
        \\
        \\On error: re-verify `element_id` via `set_design_page`; if a huge cascade leaves the canvas, use `update_design_element` with explicit x/y instead.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to translate (NOT a page_id or workspace_id); from the `id` field of a `set_design_page` element object.",
                },
                .{
                    .name = "dx",
                    .type = "number",
                    .description = "X delta in design-px. Cascades when apply_to_children=true.",
                },
                .{
                    .name = "dy",
                    .type = "number",
                    .description = "Y delta in design-px. Cascades when apply_to_children=true.",
                },
                .{
                    .name = "apply_to_children",
                    .type = "boolean",
                    .description = "Default true: the delta cascades to every transitive descendant, so a `group`/`frame` moves its whole subtree (Figma parity). Pass false to move that element only.",
                },
                .{
                    .name = "width",
                    .type = "number",
                    .description = "New width (root only — resize never cascades).",
                },
                .{
                    .name = "height",
                    .type = "number",
                    .description = "New height (root only — resize never cascades).",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "New rotation in degrees (root only — resize never cascades).",
                },
            },
            .required = &.{ "element_id", "dx", "dy" },
        },
        .system_prompt = move_design_element_tool_system_prompt,
    },
};

/// Generate an error JSON object (replaces the old per-tool XML escape +
/// error envelope helpers).
/// Generate an error JSON object `{"error":...}` for the tool dispatcher.
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees it.
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return try errorJSON(allocator, error_msg);
}

/// Validate `element_id` is non-empty and has the right `elem_` prefix.
/// Returns null when shape is correct, or an error JSON object on mismatch.
fn validateElementIdShape(allocator: std.mem.Allocator, element_id: []const u8) !?[]u8 {
    if (element_id.len == 0) {
        return try errorJSON(allocator, "element_id is required (find it in the `id` field of an element object in a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, element_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{element_id}));
    }
    if (std.mem.startsWith(u8, element_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
        , .{element_id}));
    }
    if (!std.mem.startsWith(u8, element_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). move_design_element expects an element id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `move_design_element` tool. Returns a JSON string for the LLM.
pub fn executeMoveDesignElementToString(
    allocator: std.mem.Allocator,
    db: *database.Db,
    input: MoveDesignElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Read the element's current position (always required — even
    //    when apply_to_children=false, the per-element path needs the
    //    OLD x/y to compute the new x/y).
    const current = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return switch (err) {
            error.ElementNotFound => try errorJSON(allocator, "element_id does not reference any design element — call set_design_page first"),
            else => try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)})),
        };
    };
    defer design_model.freeElement(allocator, current);

    // 2a. Cascade path (default). Build a single-item batch for the
    //     recursive CTE.
    if (input.apply_to_children) {
        const item = design_model.MoveItem{
            .element_id = input.element_id,
            .dx = input.dx,
            .dy = input.dy,
            .width = input.width,
            .height = input.height,
            .rotation = input.rotation,
        };
        const items = [_]design_model.MoveItem{item};

        // We need the page_id for the cascade — fetch it from the row
        // we already have in `current`.
        const updated = design_model.moveElementsWithDescendantsBatch(allocator, db, .{
            .page_id = current.page_id,
            .items = &items,
        }) catch |err| {
            return switch (err) {
                error.EmptyItems => try errorJSON(allocator, "items array was empty (this is an internal error — should not happen with a single item)"),
                error.ElementNotFound => try errorJSON(allocator, "element_id does not reference any design element — call set_design_page first"),
                error.PageNotFound => try errorJSON(allocator, "page_id does not reference any design page (this is an internal error — the page should exist if the element exists)"),
                else => try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveElementsWithDescendantsBatch failed: {s}", .{@errorName(err)})),
            };
        };
        defer allocator.free(updated);
        for (updated) |e| design_model.freeElement(allocator, e);

        return try renderSuccessJSON(allocator, updated);
    }

    // 2b. Single-element path (apply_to_children = false). Use the
    //     existing per-element translation by computing the new x/y
    //     from the current x/y + dx/dy.
    const new_x = current.x + input.dx;
    const new_y = current.y + input.dy;

    const inner_id = try design_model.updateElement(allocator, db, .{
        .element_id = input.element_id,
        .x = new_x,
        .y = new_y,
        .width = input.width,
        .height = input.height,
        .rotation = input.rotation,
    });
    defer allocator.free(inner_id);

    // Re-fetch the element to confirm the new state.
    const after = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, after);

    const single: []const design_model.DesignElement = &[_]design_model.DesignElement{after};
    return try renderSuccessJSON(allocator, single);
}

/// Render the success JSON response. Lists every cascaded element id + their
/// new x/y.
pub const UpdatedElementJSON = struct {
    id: []const u8,
    x: i64,
    y: i64,
};

fn renderSuccessJSON(
    allocator: std.mem.Allocator,
    updated: []const design_model.DesignElement,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(UpdatedElementJSON) = .empty;
    for (updated) |e| {
        try out.append(a, .{
            .id = try sanitizeControlChars(a, e.id),
            .x = e.x,
            .y = e.y,
        });
    }
    return try std.json.Stringify.valueAlloc(allocator, .{ .updated = out.items }, .{});
}

const testing = std.testing;


fn setupDbAndItem() !struct {
    db: database.Db,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing.allocator;
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
        \\        type TEXT NOT NULL DEFAULT 'rectangle', rotation REAL NOT NULL DEFAULT 0,
        \\        fill TEXT NOT NULL DEFAULT '', stroke TEXT NOT NULL DEFAULT '',
        \\        stroke_width INTEGER NOT NULL DEFAULT 0,
        \\        corner_radius INTEGER NOT NULL DEFAULT 0, opacity REAL NOT NULL DEFAULT 1.0,
        \\        text_content TEXT NOT NULL DEFAULT '', text_style TEXT NOT NULL DEFAULT '',
        \\        image_url TEXT NOT NULL DEFAULT '', parent_id TEXT,
        \\        created_at DATETIME, updated_at DATETIME,
        \\        FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_move_element_tool";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)", &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);
    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

fn teardownDb(db: *database.Db, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn readX(
    alloc: std.mem.Allocator,
    db: *database.Db,
    element_id: []const u8,
) !i64 {
    var q = try db.query(alloc, "SELECT x FROM design_page_elements WHERE id = ?", &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

test "executeMoveDesignElementToString with apply_to_children=true (default) cascades dx/dy to descendants" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "MoveTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50,
        .y = 100,
        .width = 300,
        .height = 200,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(group);

    const child1 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 70,
        .y = 110,
        .width = 30,
        .height = 30,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child1);

    const child2 = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200,
        .y = 200,
        .width = 30,
        .height = 30,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child2);

    // Call with apply_to_children omitted (defaults to true).
    const json = try executeMoveDesignElementToString(
        alloc,
        &ctx.db,
        .{ .element_id = group, .dx = 100, .dy = 50 },
    );
    defer alloc.free(json);

    // Tool response shape: `{"updated":[{"id":...,"x":...,"y":...}, ...]}`.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const updated = parsed.value.object.get("updated").?.array.items;
    // Group + 2 children cascaded.
    try testing.expectEqual(@as(usize, 3), updated.len);
    // No error key.
    try testing.expect(parsed.value.object.get("error") == null);

    // DB cascade verified — group + children all moved by (100, 50).
    try testing.expectEqual(@as(i64, 150), try readX(alloc, &ctx.db, group));
    try testing.expectEqual(@as(i64, 170), try readX(alloc, &ctx.db, child1));
    try testing.expectEqual(@as(i64, 300), try readX(alloc, &ctx.db, child2));
}

test "executeMoveDesignElementToString with apply_to_children=false moves ONLY the root element" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "SingleMoveTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 100,
        .y = 100,
        .width = 50,
        .height = 50,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const json = try executeMoveDesignElementToString(
        alloc,
        &ctx.db,
        .{ .element_id = leaf, .dx = 30, .dy = 20, .apply_to_children = false },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const updated = parsed.value.object.get("updated").?.array.items;
    try testing.expectEqual(@as(usize, 1), updated.len);
    try testing.expectEqualStrings(leaf, updated[0].object.get("id").?.string);
    try testing.expectEqual(@as(i64, 130), updated[0].object.get("x").?.integer);
    try testing.expectEqual(@as(i64, 120), updated[0].object.get("y").?.integer);
    try testing.expect(parsed.value.object.get("error") == null);

    try testing.expectEqual(@as(i64, 130), try readX(alloc, &ctx.db, leaf));
}

test "executeMoveDesignElementToString with width/height/rotation applies to root only (never cascades)" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "ExtrasTest",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "g",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 150,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(group);

    const child = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10,
        .y = 10,
        .width = 80,
        .height = 60,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child);

    const json = try executeMoveDesignElementToString(
        alloc,
        &ctx.db,
        .{
            .element_id = group,
            .dx = 0,
            .dy = 0,
            .width = 500,
            .height = 300,
            .rotation = 0.5,
        },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);

    // Group resized in DB.
    {
        var q = try ctx.db.query(alloc, "SELECT width, height, rotation FROM design_page_elements WHERE id = ?", &.{group});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const w = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        const h = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
        const r = std.fmt.parseFloat(f64, row.values[2]) catch 0.0;
        try testing.expectEqual(@as(i64, 500), w);
        try testing.expectEqual(@as(i64, 300), h);
        try testing.expectApproxEqAbs(@as(f64, 0.5), r, 0.0001);
    }

    // Child width UNCHANGED.
    {
        var q = try ctx.db.query(alloc, "SELECT width FROM design_page_elements WHERE id = ?", &.{child});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const cw = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
        try testing.expectEqual(@as(i64, 80), cw);
    }
}

test "executeMoveDesignElementToString returns an error object for non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const json = try executeMoveDesignElementToString(
        alloc,
        &ctx.db,
        .{ .element_id = "elem_ghost", .dx = 10, .dy = 0 },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "element_id does not reference"));
}

test "executeMoveDesignElementToString returns an error object for invalid element_id prefix" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardownDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const json = try executeMoveDesignElementToString(
        alloc,
        &ctx.db,
        .{ .element_id = "page_something", .dx = 10, .dy = 0 },
    );
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "PAGE id"));
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
pub fn execMoveDesignElement(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        MoveDesignElementInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // move_design_element doesn't need Io for the cascade path (no
    // disk writes); the same DB-only signature as set_element_parent.
    const inner = executeMoveDesignElementToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect {{"error":...}} and surface it as a tool failure (so the
    // LLM sees `success=false` rather than a successful wrapper around
    // an error body).
    const json_err_msg: ?[]u8 = blk: {
        const inner_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk null;
        defer inner_parsed.deinit();
        if (inner_parsed.value != .object) break :blk null;
        const e = inner_parsed.value.object.get("error") orelse break :blk null;
        if (e != .string) break :blk null;
        break :blk try ctx.allocator.dupe(u8, e.string);
    };
    if (json_err_msg) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "move_design_element", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

