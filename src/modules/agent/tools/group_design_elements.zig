//! LLM tool: `group_elements` — wrap 2+ elements into a new `group` or
//! `frame` parent at the union bounding box of the children.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `group_elements` tool. `page_id` and `child_ids` are
/// required.
pub const GroupElementsInput = struct {
    /// The page id (NOT the item_id). The LLM discovers page_ids
    /// via `set_design_page` (the response includes the page id).
    page_id: []const u8 = "",
    /// Child element ids. Must contain at least 2 ids; a single-element group
    /// is not meaningful (and is rejected by the model layer).
    child_ids: []const []const u8 = &.{},
    /// Name for the new parent element (optional). Defaults to
    /// `"Group"`. Must be unique within the page (the model's on-disk
    /// HTML file is `<page_dir>/<sanitized_name>.html`).
    name: ?[]const u8 = null,
    /// Parent type (optional). One of `"group"` (non-clipping
    /// container) or `"frame"` (clipping container). Defaults to
    /// `"group"`.
    type: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
pub const group_design_elements_tool_system_prompt =
    \\## Group Design Elements Tool — Behavior
    \\Use `group_elements` to wrap 2+ elements into a new group/frame parent.
    \\- The parent's bbox is the union of children. Use `group` for non-clipping, `frame` for clipping.
    \\- All children must be on the same page and not already parented.
    \\
;

pub const group_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "group_elements",
        .description =
        \\Wrap 2 or more existing elements into a new `group` or `frame` parent whose geometry is the UNION bounding box of its children: x = min(child.x), y = min(child.y), width = max(child.x + child.width) - min(child.x), height = max(child.y + child.height) - min(child.y).
        \\
        \\All children must live on the same `page_id` and none may already be parented to another group or frame — nested re-parenting is rejected. Get `page_id` from a fresh `set_design_page` call; that response also carries each element's `id`.
        \\
        \\Returns the new parent's element object plus one `{"id":...,"name":...,"parent_id":...}` object per child.
        \\
        \\On error: re-read `page_id` via `set_design_page`, confirm each child_id is on that page and not already nested, and select at least 2 children.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The page id (NOT the item_id), from the `id` field of a page object in a previous `set_design_page` response. All children must live on this page.",
                },
                .{
                    .name = "child_ids",
                    .type = "array",
                    .description = "List of 2+ element ids to group. Each must be on `page_id` and none may already be parented; discover them via `set_design_page` (each element object has an `id` field).",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Name for the new parent (optional). Defaults to \"Group\"; must be unique within the page.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Parent type (optional): \"group\" (non-clipping container, the default) or \"frame\" (clipping container).",
                },
            },
            .required = &.{ "page_id", "child_ids" },
        },
        .system_prompt = group_design_elements_tool_system_prompt,
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

/// Parse the optional `type` string into an `ElementType` enum. Returns null
/// when the string is null (use the default); returns the parsed enum on
/// success.
fn parseOptionalGroupType(type_str: ?[]const u8) !?design_model.ElementType {
    const t = type_str orelse return null;
    if (std.mem.eql(u8, t, "group")) return .group;
    if (std.mem.eql(u8, t, "frame")) return .frame;
    return error.InvalidGroupType;
}

/// Validate `page_id` is non-empty and has the right `page_`
/// prefix. Returns null when shape is correct, or an error JSON object
/// on mismatch.
fn validatePageIdShape(allocator: std.mem.Allocator, page_id: []const u8) !?[]u8 {
    if (page_id.len == 0) {
        return try errorJSON(allocator, "page_id is required (find it in the `id=\"...\"` attribute of a previous set_design_page response)");
    }
    if (std.mem.startsWith(u8, page_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ITEM id (starts with 'item_'). Pass the PAGE id instead — find it in the `id="..."` attribute of a `set_design_page` response.
        , .{page_id}));
    }
    if (std.mem.startsWith(u8, page_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' looks like an ELEMENT id (starts with 'elem_'). Pass the PAGE id instead.
        , .{page_id}));
    }
    if (!std.mem.startsWith(u8, page_id, "page_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\page_id '{s}' has an unrecognized prefix (expected 'page_'). group_elements expects a page_id from a previous set_design_page response.
        , .{page_id}));
    }
    return null;
}

/// Validate `child_ids` is non-empty, has at least 2 elements, and
/// every entry has the right `elem_` prefix. Returns null when shape
/// is correct, or an error JSON object on mismatch.
fn validateChildIdsShape(allocator: std.mem.Allocator, child_ids: []const []const u8) !?[]u8 {
    if (child_ids.len == 0) {
        return try errorJSON(allocator, "child_ids is required and must contain at least 2 element ids (a single-element group is not meaningful)");
    }
    if (child_ids.len < 2) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\child_ids must contain at least 2 element ids (got {d}). Select more elements before grouping.
        , .{child_ids.len}));
    }
    for (child_ids) |cid| {
        if (cid.len == 0) {
            return try errorJSON(allocator, "child_ids contains an empty string; every entry must be a non-empty element id");
        }
        if (std.mem.startsWith(u8, cid, "page_")) {
            return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like a PAGE id (starts with 'page_'). Pass the ELEMENT id instead — find it in the `id` field of an element object in a `set_design_page` response.
            , .{cid}));
        }
        if (std.mem.startsWith(u8, cid, "item_")) {
            return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' looks like an ITEM id (starts with 'item_'). Pass the ELEMENT id instead.
            , .{cid}));
        }
        if (!std.mem.startsWith(u8, cid, "elem_")) {
            return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
                \\child_ids entry '{s}' has an unrecognized prefix (expected 'elem_'). group_elements expects element ids from a previous set_design_page response.
            , .{cid}));
        }
    }
    return null;
}

/// Render the parent element XML block.
pub const ParentJSON = struct {
    id: []const u8,
    name: []const u8,
    type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    parent_id: ?[]const u8,
};

/// JSON child object: minimal shape (id, name, parent_id) — the LLM
/// doesn't need the child's geometry here because that information is
/// unchanged by the grouping operation.
pub const ChildJSON = struct {
    id: []const u8,
    name: []const u8,
    parent_id: ?[]const u8,
};

fn parentToJSON(allocator: std.mem.Allocator, elem: design_model.DesignElement) !ParentJSON {
    return .{
        .id = try sanitizeControlChars(allocator, elem.id),
        .name = try sanitizeControlChars(allocator, elem.name),
        .type = try sanitizeControlChars(allocator, elem.elem_type),
        .x = elem.x,
        .y = elem.y,
        .width = elem.width,
        .height = elem.height,
        // The new parent is a top-level element — parent_id is always
        // null for the root.
        .parent_id = null,
    };
}

fn childToJSON(allocator: std.mem.Allocator, elem: design_model.DesignElement) !ChildJSON {
    return .{
        .id = try sanitizeControlChars(allocator, elem.id),
        .name = try sanitizeControlChars(allocator, elem.name),
        .parent_id = try optClean(allocator, elem.parent_id),
    };
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}

/// Render a single child block.
pub fn executeGroupElementsToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GroupElementsInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validatePageIdShape(allocator, input.page_id)) |e| return e;
    if (try validateChildIdsShape(allocator, input.child_ids)) |e| return e;

    // 1.
    const parsed_type = parseOptionalGroupType(input.type) catch |err| {
        if (err == error.InvalidGroupType) {
            return try errorJSON(allocator, "type must be one of: group, frame");
        }
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: parseOptionalGroupType failed: {s}", .{@errorName(err)}));
    };

    // 2. Apply the Figma defaults (name="Group", type=group).
    const parent_name: []const u8 = if (input.name) |n| (if (n.len == 0) "Group" else n) else "Group";
    const parent_type: design_model.ElementType = parsed_type orelse .group;

    // 3. Call groupElements. Returns the new element_id on success;
    //    errors are mapped to wire XML below.
    const new_id = design_model.groupElements(allocator, db, .{
        .page_id = input.page_id,
        .child_ids = input.child_ids,
        .parent_name = parent_name,
        .parent_type = parent_type,
    }) catch |err| switch (err) {
        error.PageNotFound => return try errorJSON(allocator, "page_id does not match any design page — call set_design_page first"),
        error.BadChildId => return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "child_id is invalid — one of the child_ids ({s}) does not match any design element. Re-fetch the page via set_design_page to get fresh ids.", .{input.child_ids[0]})),
        error.ChildAcrossDifferentPages => return try errorJSON(allocator, "one of the child_ids lives on a different page than page_id. All children must be on the same page as the new parent"),
        error.ChildAlreadyParented => return try errorJSON(allocator, "one of the child_ids is already parented to another group or frame. group_elements does not support nested re-parenting in the first cut"),
        error.ItemPathMissing => return try errorJSON(allocator, "the design item has no path; set one via the design item dialog"),
        error.FileWriteFailed => return try errorJSON(allocator, "could not write the group HTML file to disk (permission denied or out of space)"),
        else => return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: groupElements failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(new_id);

    // 4. Re-fetch the parent + each reparented child so the response
    //    carries the canonical state (with timestamps + parent_id).
    const parent = design_model.getElement(allocator, db, new_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(parent) failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent_json = try parentToJSON(a, parent);
    var children: std.ArrayList(ChildJSON) = .empty;
    for (input.child_ids) |cid| {
        const child = design_model.getElement(allocator, db, cid) catch |err| {
            return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement(child='{s}') failed: {s}", .{ cid, @errorName(err) }));
        };
        defer design_model.freeElement(allocator, child);
        try children.append(a, try childToJSON(a, child));
    }
    return try std.json.Stringify.valueAlloc(allocator, .{
        .parent = parent_json,
        .children = children.items,
    }, .{});
}

const testing = std.testing;
fn expectJSONError(alloc: std.mem.Allocator, str: []const u8, needle: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, str, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(err_val == .string);
    try testing.expect(contains(err_val.string, needle));
}

fn expectNoJSONError(alloc: std.mem.Allocator, str: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, str, .{});
    errdefer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("error") == null);
    return parsed;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── JSON serialization ──────────────────────────────────────────────────

test "errorJSON on missing field returns an error object" {
    const alloc = testing.allocator;
    const json = try errorJSON(alloc, "page_id is required");
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id is required");
}

test "errorJSONOwned takes ownership and frees the message" {
    const alloc = testing.allocator;
    const msg = try alloc.dupe(u8, "child_ids must be at least 2 elements");
    const json = try errorJSONOwned(alloc, msg);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "child_ids must be at least 2 elements");
    // msg has been freed by errorJSONOwned — using `msg` here would
    // be UAF. The test passes by virtue of the closure capturing the
    // allocation lifecycle.
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the v6 design schema + one page + three
/// rectangle elements ("card-a", "card-b", "card-c") all on the same page.
/// Returns the DB handle + page_id so tests can call group_elements on them.
fn setupDbWithThreeElements() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
    element_a: []u8,
    element_b: []u8,
    element_c: []u8,
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
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_group_1";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)", &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_group_1";
    try db.exec(alloc, "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)", &.{ page_id_str, item_id_str });

    const element_a_str = "elem_a";
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-a', '/tmp/a.html', 10, 20, 100, 50, 0, 0, 'rectangle', '#ffffff')", &.{ element_a_str, page_id_str });

    const element_b_str = "elem_b";
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-b', '/tmp/b.html', 200, 300, 100, 50, 1, 1, 'rectangle', '#ffffff')", &.{ element_b_str, page_id_str });

    const element_c_str = "elem_c";
    try db.exec(alloc, "INSERT INTO design_page_elements (id, page_id, name, file_path, x, y, width, height, z_index, position, type, fill) " ++
        "VALUES (?, ?, 'card-c', '/tmp/c.html', 400, 600, 100, 50, 2, 2, 'rectangle', '#ffffff')", &.{ element_c_str, page_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
        .element_a = try alloc.dupe(u8, element_a_str),
        .element_b = try alloc.dupe(u8, element_b_str),
        .element_c = try alloc.dupe(u8, element_c_str),
    };
}

test "executeGroupElementsToString wraps two elements into a parent with union bbox" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    // Parent rendered with the union bbox (10, 20, 290, 330).
    const parent = obj.get("parent").?.object;
    try testing.expectEqualStrings("Group", parent.get("name").?.string);
    try testing.expectEqualStrings("group", parent.get("type").?.string);
    try testing.expectEqual(@as(i64, 10), parent.get("x").?.integer);
    try testing.expectEqual(@as(i64, 20), parent.get("y").?.integer);
    try testing.expectEqual(@as(i64, 290), parent.get("width").?.integer);
    try testing.expectEqual(@as(i64, 330), parent.get("height").?.integer);
    try testing.expect(parent.get("parent_id").? == .null);
    const parent_id = parent.get("id").?.string;
    try testing.expect(std.mem.startsWith(u8, parent_id, "elem_"));
    // Both children rendered with parent_id pointing to the new parent.
    const children = obj.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqualStrings("elem_a", children[0].object.get("id").?.string);
    try testing.expectEqualStrings("elem_b", children[1].object.get("id").?.string);
    try testing.expectEqualStrings("card-a", children[0].object.get("name").?.string);
    try testing.expectEqualStrings("card-b", children[1].object.get("name").?.string);
    try testing.expectEqualStrings(parent_id, children[0].object.get("parent_id").?.string);
    try testing.expectEqualStrings(parent_id, children[1].object.get("parent_id").?.string);
}

test "executeGroupElementsToString honours custom name and type=frame" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_b, s.element_c },
        .name = "Kanban-view",
        .type = "frame",
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const parent = parsed.value.object.get("parent").?.object;
    try testing.expectEqualStrings("Kanban-view", parent.get("name").?.string);
    try testing.expectEqualStrings("frame", parent.get("type").?.string);
    // Union bbox of (200,300,500,650) and (400,600,500,650) →
    // (200, 300, 300, 350).
    try testing.expectEqual(@as(i64, 200), parent.get("x").?.integer);
    try testing.expectEqual(@as(i64, 300), parent.get("y").?.integer);
    try testing.expectEqual(@as(i64, 300), parent.get("width").?.integer);
    try testing.expectEqual(@as(i64, 350), parent.get("height").?.integer);
}

test "executeGroupElementsToString returns error JSON when page_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = "",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id");
}

test "executeGroupElementsToString returns error JSON when child_ids is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{},
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "child_ids");
}

test "executeGroupElementsToString returns error JSON when child_ids has only 1 element" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{s.element_a},
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "child_ids");
}

test "executeGroupElementsToString returns error JSON when type is invalid" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
        .type = "rectangle",
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "type must be one of");
}

test "executeGroupElementsToString returns error JSON when page_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = "page_does_not_exist",
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id");
}

test "executeGroupElementsToString returns error JSON when a child_id does not exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, "elem_does_not_exist" },
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "child_id is invalid");
}

test "executeGroupElementsToString returns error JSON when a child is already parented" {
    const alloc = testing.allocator;
    var s = try setupDbWithThreeElements();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);
    defer alloc.free(s.element_a);
    defer alloc.free(s.element_b);
    defer alloc.free(s.element_c);

    // Pre-parent element_b to a non-existent parent (still parented
    // in the DB). The model rejects children whose parent_id is set.
    try s.db.exec(alloc, "UPDATE design_page_elements SET parent_id = 'elem_orphan' WHERE id = ?", &.{s.element_b});

    const input = GroupElementsInput{
        .page_id = s.page_id,
        .child_ids = &.{ s.element_a, s.element_b },
    };
    const json = try executeGroupElementsToString(alloc, &s.db, input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "parented");
}

// Exec adapter — merged from `group_design_elements.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
pub fn execGroupElements(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        GroupElementsInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "group_elements", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // group_elements doesn't need Io (groupElements handles its own
    // mkdir-p via the SqliteBackend's io).
    const inner = executeGroupElementsToString(
        ctx.allocator,
        ctx.db,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "group_elements", tc.function.arguments, false, err_msg, "");
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
        const output = try wrapToolOutput(ctx.allocator, "group_elements", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "group_elements", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

