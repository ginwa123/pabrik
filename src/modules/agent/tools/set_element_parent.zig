//! LLM tool: `set_element_parent` — re-parents an existing design element to
//! a new `group`/`frame` parent, or back to top-level via `null`.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `set_element_parent` tool. Both fields are required.
/// Pass `null` for `new_parent_id` to move the element back to top-level (the
/// inverse of nesting).
pub const SetElementParentInput = struct {
    /// The element id to re-parent. Must exist on the active page.
    element_id: []const u8 = "",
    /// The new parent's element id. Must reference a `group` or
    /// `frame` on the SAME page as `element_id`. Pass `null` to move
    /// the element to top-level (parent_id cleared).
    new_parent_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const set_element_parent_tool_system_prompt =
    \\## Set Element Parent Tool — Behavior
    \\Use `set_element_parent` to re-parent an element to a group/frame or back to top-level (null).
    \\- Use to fix nesting after creation. The new parent must be a `group` or `frame` on the same page.
    \\
;

pub const set_element_parent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_element_parent",
        .description =
        \\Re-parent an existing design element into a `group` or `frame`, or back to top-level — the inverse of `add_element`'s `parent_id`, for fixing an element that landed at the wrong nesting level.
        \\
        \\The `element_id` must reference an element on the active page. The `new_parent_id` must reference a `group` or `frame` on the SAME page — leaf types (rectangle, ellipse, text, image) cannot contain children and are rejected with `ParentNotContainer`. Pass `new_parent_id = null` for top-level (clears parent_id).
        \\
        \\Discover ids via `set_design_page` (element objects carry `id` and `parent_id`).
        \\
        \\On error, re-verify both ids with `set_design_page` — `ParentNotContainer` means `new_parent_id` is the wrong type or on another page.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "element_id",
                    .type = "string",
                    .description = "The element id to re-parent (NOT a page_id or workspace_id). From the `id` field of an element object in a previous `set_design_page` response.",
                },
                .{
                    .name = "new_parent_id",
                    .type = "string",
                    .description = "The new parent's element id (a `group` or `frame` on the same page), or null for top-level.",
                },
            },
            .required = &.{"element_id"},
        },
        .system_prompt = set_element_parent_tool_system_prompt,
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
            \\element_id '{s}' has an unrecognized prefix (expected 'elem_'). set_element_parent expects an element id from a previous set_design_page response, not a free-form string.
        , .{element_id}));
    }
    return null;
}

/// Execute the `set_element_parent` tool. Returns a JSON string for the LLM.
pub fn executeSetElementParentToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetElementParentInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validateElementIdShape(allocator, input.element_id)) |e| return e;

    // 1. Delegate to design_model.setElementParent. The model layer
    //    handles parent existence, type check, cycle detection, and
    //    the actual UPDATE.
    design_model.setElementParent(allocator, db, input.element_id, input.new_parent_id) catch |err| {
        return switch (err) {
            error.ElementNotFound => try errorJSON(allocator, "element_id does not reference any design element — call set_design_page first"),
            error.ParentNotFound => try errorJSON(allocator, "new_parent_id does not reference any design element — call set_design_page first"),
            error.ParentNotContainer => try errorJSON(allocator, "new_parent_id points to a leaf-type element (rectangle/ellipse/text/image); only `group` or `frame` can contain children"),
            error.DifferentPages => try errorJSON(allocator, "element and new_parent are on different pages; re-parenting across pages is not supported"),
            error.CycleDetected => try errorJSON(allocator, "cycle detected: new_parent is a descendant of element_id (would create a cycle in the group hierarchy)"),
            else => try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: setElementParent failed: {s}", .{@errorName(err)})),
        };
    };

    // 2. Re-fetch the element so the LLM gets the canonical state
    //    (with the new parent_id reflected).
    const elem = design_model.getElement(allocator, db, input.element_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, elem);

    // 3. Render the response JSON, re-using the element renderer from
    //    add_design_element.zig (parsed back into a value so the response
    //    is built via serialization, never string-concat).
    const elem_json = try pabrikcore.add_design_element.elementToJSON(allocator, elem);
    defer allocator.free(elem_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, elem_json, .{});
    defer parsed.deinit();
    return try std.json.Stringify.valueAlloc(allocator, .{ .element = parsed.value }, .{});
}

const testing = std.testing;


/// Open a fresh in-memory sqlite DB with the v6 design schema. Same
/// shape as the other test files (`setupDbAndItem`) — copied locally
/// for self-containment.
fn setupDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
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

    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_set_parent_tool";
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

fn teardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Test 1: happy path — re-parent into an existing frame ───────────────

test "executeSetElementParentToString moves element into existing group" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-button",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110,
        .y = 220,
        .width = 80,
        .height = 30,
        .fill = "#000000",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(child_id);

    // Call the LLM tool.
    const json = try executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = group_id,
    });
    defer alloc.free(json);
    // Tool response shape: `{"element":{...,"parent_id":"elem_..."}}`.
    // It must NOT contain an `error` key on the happy path.
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("error") == null);
    const el = parsed.value.object.get("element").?.object;
    try testing.expectEqualStrings(child_id, el.get("id").?.string);
    try testing.expectEqualStrings(group_id, el.get("parent_id").?.string);

    // Verify the DB state directly (round-trip via design_model).
    const got = try design_model.getElement(alloc, &ctx.db, child_id);
    defer design_model.freeElement(alloc, got);
    try testing.expectEqualStrings(group_id, got.parent_id);
}

// ─── Test 2: reject leaf-type parent ──────────────────────────────────────

test "executeSetElementParentToString rejects leaf-type parent" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 50,
        .height = 50,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const child_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 50,
        .height = 50,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(child_id);

    const json = try executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = child_id,
        .new_parent_id = leaf_id,
    });
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "group")); // error mentions "group or frame"
}

// ─── Test 3: reject non-existent element_id ──────────────────────────────

test "executeSetElementParentToString rejects non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const json = try executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_does_not_exist",
        .new_parent_id = group_id,
    });
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "element_id"));
}

// ─── Test 4: invalid element_id prefix returns a JSON error ───────────────

test "executeSetElementParentToString rejects element_id with invalid prefix" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const json = try executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "not_elem_anything",
        .new_parent_id = "elem_anything",
    });
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(contains(err_val.string, "element_id"));
}

// ─── Test 5: set_element_parent to null moves element to top-level ─────

test "executeSetElementParentToString with null moves element to top-level" {
    const alloc = testing.allocator;
    var ctx = try setupDbAndItem();
    defer teardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try design_model.setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try design_model.addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(group_id);

    // Create a child with parent_id = group_id via direct SQL
    // (addElement always sets parent_id = NULL).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_inner', ?, 'inner', '', 10, 10, 20, 20, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', ?, datetime('now'), datetime('now'))
    , &.{ page_id, group_id });

    // Call set_element_parent with null.
    const json = try executeSetElementParentToString(alloc, &ctx.db, .{
        .element_id = "elem_inner",
        .new_parent_id = null,
    });
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);
    try testing.expect(parsed.value.object.get("element").?.object.get("parent_id").? == .null);

    // Verify DB state.
    const got = try design_model.getElement(alloc, &ctx.db, "elem_inner");
    defer design_model.freeElement(alloc, got);
    try testing.expectEqual(@as(usize, 0), got.parent_id.len);
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
pub fn execSetElementParent(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        SetElementParentInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // set_element_parent doesn't need Io (no disk writes).
    const inner = executeSetElementParentToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, "");
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
        const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "set_element_parent", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

