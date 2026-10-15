//! LLM tool: `add_element` — creates a new element on a design page.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Input structure for `add_element` tool. The agent passes `page_id` (from
/// the `set_design_page` response), the element's `name`, `type`, and `html`.
pub const AddElementInput = struct {
    /// The page id (NOT the item_id). The LLM discovers page_ids
    /// via `set_design_page` (the response includes the page id).
    page_id: []const u8 = "",
    /// Human-readable element name. Must be unique within the page.
    /// Must NOT contain '/' or null bytes (the v6 file-backed model
    /// stores the HTML body at `<page_dir>/<sanitized_name>.html`).
    name: []const u8 = "",
    /// Element type — one of: rectangle, ellipse, text, image, frame, group.
    type: []const u8 = "rectangle",
    /// HTML body. Written to
    /// `<workspace_item.path>/.pabrik/design/<page>/<element>.html`.
    html: []const u8 = "",
    /// X position in CSS pixels. Defaults to 0.
    x: ?i64 = null,
    /// Y position in CSS pixels. Defaults to 0.
    y: ?i64 = null,
    /// Width in CSS pixels. Defaults to 200.
    width: ?i64 = null,
    /// Height in CSS pixels. Defaults to 100.
    height: ?i64 = null,
    /// Fill color (CSS color string, e.g. `#ffffff`, `rgba(0,0,0,0.5)`,
    /// `transparent`). Defaults to "" (no fill).
    fill: []const u8 = "",
    /// Rotation in degrees (clockwise). Defaults to 0.
    rotation: ?f64 = null,
    /// Corner radius in CSS pixels (for rectangle only). Defaults to 0.
    corner_radius: ?i64 = null,
    /// Opacity (0.0 = transparent, 1.0 = opaque). Defaults to 1.0.
    opacity: ?f64 = null,
    /// Text content (for `type='text'`). Defaults to "".
    text_content: []const u8 = "",
    /// Text style (JSON-encoded string, e.g.
    /// `{"font":"Inter","size":14}`). Defaults to "".
    text_style: []const u8 = "",
    /// Image URL (for `type='image'`). Defaults to "".
    image_url: []const u8 = "",
    /// Optional FK to an existing `group` or `frame` on the SAME page. When
    /// set, the new element nests under that container instead of landing at
    /// top-level.
    parent_id: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM. The description enumerates the 6
/// valid types, lists the geometry defaults, and tells the LLM that `page_id`
/// comes from a previous `set_design_page` call (NOT from Workspace Context).
pub const add_design_element_tool_system_prompt =
    \\## Add Design Element Tool — Behavior
    \\Use `add_element` to create a new positioned element on a design page.
    \\- Provide `type`, geometry (`x`/`y`/`width`/`height`), and optional HTML body.
    \\- Writes atomically to disk. Discover `page_id` via `set_design_page` first.
    \\
;

pub const add_design_element_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_element",
        .description =
        \\Add a new positioned element to a design page, with a writable HTML body stored on disk. Discover `page_id` via `set_design_page` first; the name must be unique within the page. Returns the element JSON object — the html body itself is omitted, its location is in `file_path`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The page id (NOT the item_id), from a previous `set_design_page` response's `id` attribute.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Human-readable element name (e.g. 'login-card'). Unique within the page; must NOT contain '/' or null bytes.",
                },
                .{
                    .name = "type",
                    .type = "string",
                    .description = "Element type — one of: 'rectangle', 'ellipse', 'text' (HTML text node — set `text_content`), 'image' (raster image — set `image_url`), 'frame' (container that clips children), 'group' (container that does not clip).",
                },
                .{
                    .name = "html",
                    .type = "string",
                    .description = "HTML body for the element, required and non-empty. Written under `<workspace_item.path>/.pabrik/design/<page>/<element>.html`.",
                },
                .{
                    .name = "x",
                    .type = "integer",
                    .description = "X position in CSS pixels (default 0).",
                },
                .{
                    .name = "y",
                    .type = "integer",
                    .description = "Y position in CSS pixels (default 0).",
                },
                .{
                    .name = "width",
                    .type = "integer",
                    .description = "Width in CSS pixels (default 200).",
                },
                .{
                    .name = "height",
                    .type = "integer",
                    .description = "Height in CSS pixels (default 100).",
                },
                .{
                    .name = "fill",
                    .type = "string",
                    .description = "Fill color (CSS color, e.g. '#ffffff', 'transparent'). Defaults to ''.",
                },
                .{
                    .name = "rotation",
                    .type = "number",
                    .description = "Rotation in degrees (clockwise). Defaults to 0.",
                },
                .{
                    .name = "corner_radius",
                    .type = "integer",
                    .description = "Corner radius in CSS pixels (rectangle only). Defaults to 0.",
                },
                .{
                    .name = "opacity",
                    .type = "number",
                    .description = "Opacity (0.0 transparent to 1.0 opaque). Defaults to 1.0.",
                },
                .{
                    .name = "text_content",
                    .type = "string",
                    .description = "Text content (type='text'). Defaults to ''.",
                },
                .{
                    .name = "text_style",
                    .type = "string",
                    .description = "Text style as JSON (e.g. {\"font\":\"Inter\",\"size\":14}). Defaults to ''.",
                },
                .{
                    .name = "image_url",
                    .type = "string",
                    .description = "Image URL (type='image'). Defaults to ''.",
                },
                .{
                    .name = "parent_id",
                    .type = "string",
                    .description = "Optional FK to an existing `group` or `frame` on the SAME page — the new element then nests under that container instead of landing at top-level. Discover the id via `set_design_page` (each element object has an `id`). Leaf types (rectangle, ellipse, text, image) cannot contain children. Omit or pass null for top-level.",
                },
            },
            .required = &.{ "page_id", "name", "type", "html" },
        },
        .system_prompt = add_design_element_tool_system_prompt,
    },
};

/// Generate an error JSON object `{"error":...}` for the tool
/// dispatcher (detected via the top-level `error` key).
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

/// Parse the `type` string into an `ElementType` enum. Returns the parsed
/// enum on success, or `null` when the string is not one of the 6 valid
/// types.
pub fn parseElementType(type_str: []const u8) ?design_model.ElementType {
    if (std.mem.eql(u8, type_str, "rectangle")) return .rectangle;
    if (std.mem.eql(u8, type_str, "ellipse")) return .ellipse;
    if (std.mem.eql(u8, type_str, "text")) return .text;
    if (std.mem.eql(u8, type_str, "image")) return .image;
    if (std.mem.eql(u8, type_str, "frame")) return .frame;
    if (std.mem.eql(u8, type_str, "group")) return .group;
    return null;
}

/// Canonical element JSON object (keys mirror the old `<element ... />`
/// attributes 1:1; attributes omitted-when-empty become explicit nulls).
pub const ElementJSON = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    type: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    rotation: f64,
    opacity: f64,
    corner_radius: i64,
    fill: ?[]const u8,
    stroke: ?[]const u8,
    text_content: ?[]const u8,
    text_style: ?[]const u8,
    image_url: ?[]const u8,
    file_path: ?[]const u8,
    parent_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Render the canonical element JSON response shape.
pub fn elementToJSON(
    allocator: std.mem.Allocator,
    elem: design_model.DesignElement,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    return try std.json.Stringify.valueAlloc(allocator, ElementJSON{
        .id = try sanitizeControlChars(a, elem.id),
        .page_id = try sanitizeControlChars(a, elem.page_id),
        .name = try sanitizeControlChars(a, elem.name),
        .type = try sanitizeControlChars(a, elem.elem_type),
        .x = elem.x,
        .y = elem.y,
        .width = elem.width,
        .height = elem.height,
        .rotation = elem.rotation,
        .opacity = elem.opacity,
        .corner_radius = elem.corner_radius,
        .fill = try optClean(a, elem.fill),
        .stroke = try optClean(a, elem.stroke),
        .text_content = try optClean(a, elem.text_content),
        .text_style = try optClean(a, elem.text_style),
        .image_url = try optClean(a, elem.image_url),
        .file_path = try optClean(a, elem.file_path),
        .parent_id = try optClean(a, elem.parent_id),
        .created_at = try sanitizeControlChars(a, elem.created_at),
        .updated_at = try sanitizeControlChars(a, elem.updated_at),
    }, .{});
}

/// Clean an optional free-text field: empty becomes null, otherwise the
/// control-char-sanitized copy owned by the caller's arena.
fn optClean(allocator: std.mem.Allocator, s: []const u8) !?[]u8 {
    if (s.len == 0) return null;
    return try sanitizeControlChars(allocator, s);
}

/// Validate `page_id` is non-empty and has the right `page_` prefix.
/// Returns null when shape is correct, or an error JSON object on mismatch.
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
            \\page_id '{s}' has an unrecognized prefix (expected 'page_'). add_element expects a page_id from a previous set_design_page response, not a free-form string.
        , .{page_id}));
    }
    return null;
}

/// Validate `name` is non-empty and contains no illegal characters.
fn validateNameShape(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (name.len == 0) {
        return try errorJSON(allocator, "name is required");
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return try errorJSON(allocator, "name must not contain '/' (it becomes a filename)");
    }
    if (std.mem.indexOfScalar(u8, name, 0) != null) {
        return try errorJSON(allocator, "name must not contain null bytes");
    }
    return null;
}

/// Validate `html` is non-empty. The DB stores `html` separately on
/// disk, so an empty body would create an orphan `<element>` row with
/// a zero-byte file.
fn validateHtmlShape(allocator: std.mem.Allocator, html: []const u8) !?[]u8 {
    if (html.len == 0) {
        return try errorJSON(allocator, "html is required (the element's HTML body — write something)");
    }
    return null;
}

/// Validate `parent_id` (when provided) has the right shape — starts with
/// `elem_`. The deeper validation (same page, type in {`group`, `frame`})
/// runs in `design_model.addElement` once the DB is consulted.
fn validateParentIdShape(allocator: std.mem.Allocator, parent_id: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, parent_id, "elem_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\parent_id '{s}' has an unrecognized prefix (expected 'elem_'). add_element expects an element id from a previous set_design_page response, not a free-form string.
        , .{parent_id}));
    }
    return null;
}

/// Execute the `add_element` tool. Returns a JSON string for the LLM.
pub fn executeAddElementToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    input: AddElementInput,
) ![]u8 {
    // 0. Input validation (shape only — DB validation runs after).
    if (try validatePageIdShape(allocator, input.page_id)) |e| return e;
    if (try validateNameShape(allocator, input.name)) |e| return e;
    if (try validateHtmlShape(allocator, input.html)) |e| return e;
    if (input.parent_id) |pid| {
        if (try validateParentIdShape(allocator, pid)) |e| return e;
    }

    // 1. Parse the type string into the ElementType enum. Returns a
    // structured error when the type is not one of the 6 valid values — the
    // LLM is told all 6 in the description so it can self-correct.
    const elem_type = parseElementType(input.type) orelse {
        return try errorJSON(allocator, "type must be one of: rectangle, ellipse, text, image, frame, group");
    };

    // 2. Resolve defaults.
    const x = input.x orelse 0;
    const y = input.y orelse 0;
    const width = input.width orelse 200;
    const height = input.height orelse 100;
    const rotation = input.rotation orelse 0.0;
    const corner_radius = input.corner_radius orelse 0;
    const opacity = input.opacity orelse 1.0;

    // 3. Call addElement (atomically writes the HTML to disk and inserts the
    // metadata row).
    const fill_for_db: []const u8 = if (input.fill.len == 0) "transparent" else input.fill;
    const element_id = design_model.addElement(allocator, db, io, .{
        .page_id = input.page_id,
        .name = input.name,
        .elem_type = elem_type,
        .html = input.html,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .fill = fill_for_db,
        .rotation = rotation,
        .corner_radius = corner_radius,
        .opacity = opacity,
        .text_content = input.text_content,
        .text_style = input.text_style,
        .image_url = input.image_url,
        .parent_id = input.parent_id,
    }) catch |err| switch (err) {
        error.PageNotFound => return try errorJSON(allocator, "page_id does not match any design page — call set_design_page first"),
        error.ItemPathMissing => return try errorJSON(allocator, "the design item has no path; set one via AddDesignDialog"),
        error.BadName => return try errorJSON(allocator, "name is invalid (empty or contains illegal characters)"),
        error.FileWriteFailed => return try errorJSON(allocator, "could not write the HTML file to disk (permission denied or out of space)"),
        error.BadParentId => return try errorJSON(allocator, "parent_id does not reference any design element on this page — call set_design_page first"),
        error.ParentNotContainer => return try errorJSON(allocator, "parent_id points to a leaf-type element (rectangle/ellipse/text/image); only `group` or `frame` can contain children"),
        else => return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: addElement failed: {s}", .{@errorName(err)})),
    };
    defer allocator.free(element_id);

    // 4. Re-fetch the full element via getElement so the LLM gets
    //    the canonical state (with file_path, timestamps, etc.).
    const elem = design_model.getElement(allocator, db, element_id) catch |err| {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: getElement failed: {s}", .{@errorName(err)}));
    };
    defer design_model.freeElement(allocator, elem);

    return try elementToJSON(allocator, elem);
}

const testing = std.testing;

fn expectJSONFloat(v: std.json.Value, want: f64) !void {
    const got: f64 = switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.NotANumber,
    };
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

fn expectJSONError(alloc: std.mem.Allocator, s: []const u8, needle: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const err_val = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(err_val == .string);
    try testing.expect(contains(err_val.string, needle));
}

fn expectNoJSONError(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, s, .{});
    errdefer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("error") == null);
    return parsed;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── ElementType parser ───────────────────────────────────────────────────

test "parseElementType accepts all 6 valid types" {
    try testing.expect(parseElementType("rectangle") == .rectangle);
    try testing.expect(parseElementType("ellipse") == .ellipse);
    try testing.expect(parseElementType("text") == .text);
    try testing.expect(parseElementType("image") == .image);
    try testing.expect(parseElementType("frame") == .frame);
    try testing.expect(parseElementType("group") == .group);
}

test "parseElementType returns null for invalid types" {
    try testing.expect(parseElementType("box") == null);
    try testing.expect(parseElementType("circle") == null);
    try testing.expect(parseElementType("Rectangle") == null); // case-sensitive
    try testing.expect(parseElementType("") == null);
    try testing.expect(parseElementType("div") == null);
}

// ─── JSON serialization ──────────────────────────────────────────────────

test "elementToJSON renders element with all v6 fields" {
    const alloc = testing.allocator;
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "login-card"),
        .file_path = try alloc.dupe(u8, "/tmp/.pabrik/design/Login/login-card.html"),
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 15.0,
        .fill = try alloc.dupe(u8, "#22c55e"),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 8,
        .opacity = 0.85,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, "2026-07-08 10:00:00"),
        .updated_at = try alloc.dupe(u8, "2026-07-08 10:00:00"),
    };
    defer design_model.freeElement(alloc, elem);

    const json = try elementToJSON(alloc, elem);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("elem_xyz", obj.get("id").?.string);
    try testing.expectEqualStrings("page_abc", obj.get("page_id").?.string);
    try testing.expectEqualStrings("login-card", obj.get("name").?.string);
    try testing.expectEqualStrings("rectangle", obj.get("type").?.string);
    try testing.expectEqual(@as(i64, 100), obj.get("x").?.integer);
    try testing.expectEqual(@as(i64, 200), obj.get("y").?.integer);
    try testing.expectEqual(@as(i64, 400), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 300), obj.get("height").?.integer);
    try testing.expectEqualStrings("#22c55e", obj.get("fill").?.string);
    try expectJSONFloat(obj.get("rotation").?, 15.0);
    try expectJSONFloat(obj.get("opacity").?, 0.85);
    try testing.expectEqual(@as(i64, 8), obj.get("corner_radius").?.integer);
    try testing.expectEqualStrings("/tmp/.pabrik/design/Login/login-card.html", obj.get("file_path").?.string);
    try testing.expectEqualStrings("2026-07-08 10:00:00", obj.get("created_at").?.string);
    try testing.expectEqualStrings("2026-07-08 10:00:00", obj.get("updated_at").?.string);
    // Empty-string inputs become explicit nulls.
    try testing.expect(obj.get("stroke").? == .null);
    try testing.expect(obj.get("text_content").? == .null);
    try testing.expect(obj.get("text_style").? == .null);
    try testing.expect(obj.get("image_url").? == .null);
    try testing.expect(obj.get("parent_id").? == .null);
}

test "elementToJSON renders explicit nulls for empty optional fields" {
    const alloc = testing.allocator;
    const elem = design_model.DesignElement{
        .id = try alloc.dupe(u8, "elem_xyz"),
        .page_id = try alloc.dupe(u8, "page_abc"),
        .name = try alloc.dupe(u8, "card"),
        .file_path = try alloc.dupe(u8, "/tmp/card.html"),
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 100,
        .z_index = 0,
        .position = 0,
        .elem_type = try alloc.dupe(u8, "rectangle"),
        .rotation = 0.0,
        .fill = try alloc.dupe(u8, ""),
        .stroke = try alloc.dupe(u8, ""),
        .stroke_width = 0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = try alloc.dupe(u8, ""),
        .text_style = try alloc.dupe(u8, ""),
        .image_url = try alloc.dupe(u8, ""),
        .parent_id = try alloc.dupe(u8, ""),
        .created_at = try alloc.dupe(u8, ""),
        .updated_at = try alloc.dupe(u8, ""),
    };
    defer design_model.freeElement(alloc, elem);

    const json = try elementToJSON(alloc, elem);
    defer alloc.free(json);

    // Empty strings become explicit nulls (never omitted, never "").
    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("fill").? == .null);
    try testing.expect(obj.get("stroke").? == .null);
    try testing.expect(obj.get("text_content").? == .null);
    try testing.expect(obj.get("text_style").? == .null);
    try testing.expect(obj.get("image_url").? == .null);
    try testing.expect(obj.get("parent_id").? == .null);
    try testing.expect(obj.get("file_path").? != .null);
}

test "errorJSON on bad page_id returns an error object" {
    const alloc = testing.allocator;
    const json = try errorJSON(alloc, "page_id is required");
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id is required");
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

fn setupDbWithPage() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
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
    // Use the stack buffer directly (don't dupe — `db.exec` copies the slice
    // internally). The `tmp` dir is reclaimed by the OS at process exit
    // (acceptable for test-suite use, per design_model_test.zig's precedent).
    const tmpdir_path: []const u8 = tmpdir_buf[0..tmpdir_len];

    const item_id_str = "item_design_1";
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
        "VALUES (?, 'ws_test', 'design', 'Test Design', ?)", &.{ item_id_str, tmpdir_path });

    const page_id_str = "page_test_1";
    try db.exec(alloc, "INSERT INTO design_pages (id, workspace_item_id, name, width, height, position) " ++
        "VALUES (?, ?, 'Login', 1440, 1024, 0)", &.{ page_id_str, item_id_str });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = try alloc.dupe(u8, item_id_str),
        .page_id = try alloc.dupe(u8, page_id_str),
    };
}

test "executeAddElementToString creates an element with default geometry" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "login-card",
        .type = "rectangle",
        .html = "<div>Hello</div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("login-card", obj.get("name").?.string);
    try testing.expectEqualStrings("rectangle", obj.get("type").?.string);
    // Defaults: x=0, y=0, width=200, height=100
    try testing.expectEqual(@as(i64, 0), obj.get("x").?.integer);
    try testing.expectEqual(@as(i64, 0), obj.get("y").?.integer);
    try testing.expectEqual(@as(i64, 200), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 100), obj.get("height").?.integer);
    try expectJSONFloat(obj.get("opacity").?, 1.0);
    try expectJSONFloat(obj.get("rotation").?, 0.0);
    try testing.expect(obj.get("file_path").? != .null);
}

test "executeAddElementToString respects explicit geometry" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "login-button",
        .type = "rectangle",
        .html = "<button>Sign in</button>",
        .x = 120,
        .y = 520,
        .width = 120,
        .height = 40,
        .fill = "#22c55e",
        .corner_radius = 8,
        .opacity = 0.95,
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);

    var parsed = try expectNoJSONError(alloc, json);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("login-button", obj.get("name").?.string);
    try testing.expectEqual(@as(i64, 120), obj.get("x").?.integer);
    try testing.expectEqual(@as(i64, 520), obj.get("y").?.integer);
    try testing.expectEqual(@as(i64, 120), obj.get("width").?.integer);
    try testing.expectEqual(@as(i64, 40), obj.get("height").?.integer);
    try testing.expectEqualStrings("#22c55e", obj.get("fill").?.string);
    try testing.expectEqual(@as(i64, 8), obj.get("corner_radius").?.integer);
    try expectJSONFloat(obj.get("opacity").?, 0.95);
}

test "executeAddElementToString accepts all 6 element types" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const types = [_][]const u8{ "rectangle", "ellipse", "text", "image", "frame", "group" };
    for (types, 0..) |t, i| {
        const name = try std.fmt.allocPrint(alloc, "elem-{s}-{d}", .{ t, i });
        defer alloc.free(name);
        const input = AddElementInput{
            .page_id = s.page_id,
            .name = name,
            .type = t,
            .html = "<div></div>",
        };
        const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
        defer alloc.free(json);
        var parsed = try expectNoJSONError(alloc, json);
        defer parsed.deinit();
        // Verify the type appears in the response (the wire format is
        // the "type" key of the element object).
        try testing.expectEqualStrings(t, parsed.value.object.get("type").?.string);
    }
}

test "executeAddElementToString returns error JSON on invalid type" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "x",
        .type = "box", // not one of the 6 valid types
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "type must be one of");
}

test "executeAddElementToString returns error JSON when page_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = "",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id");
}

test "executeAddElementToString returns error JSON when page_id has wrong prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = "elem_1782442554112",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "elem_");
}

test "executeAddElementToString accepts parent_id (nests new element under existing frame)" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    // Add a parent frame first.
    const parent_json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), .{
        .page_id = s.page_id,
        .name = "login-card",
        .type = "frame",
        .html = "<div></div>",
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .fill = "#ffffff",
    });
    defer alloc.free(parent_json);

    // Extract the parent's element id from the response JSON object.
    var parent_parsed = try expectNoJSONError(alloc, parent_json);
    defer parent_parsed.deinit();
    const parent_elem_id = parent_parsed.value.object.get("id").?.string;
    try testing.expect(std.mem.startsWith(u8, parent_elem_id, "elem_"));

    // Add a child rectangle with parent_id pointing to the frame.
    const child_input = AddElementInput{
        .page_id = s.page_id,
        .name = "login-button",
        .type = "rectangle",
        .html = "<button>Sign in</button>",
        .x = 120,
        .y = 520,
        .width = 120,
        .height = 40,
        .fill = "#22c55e",
        .parent_id = parent_elem_id,
    };
    const child_json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), child_input);
    defer alloc.free(child_json);
    // Response JSON must include the parent_id key (the LLM needs
    // to confirm the nesting took effect).
    var child_parsed = try expectNoJSONError(alloc, child_json);
    defer child_parsed.deinit();
    try testing.expectEqualStrings(parent_elem_id, child_parsed.value.object.get("parent_id").?.string);
}

test "executeAddElementToString rejects parent_id with invalid prefix" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
        .parent_id = "page_does_not_start_with_elem",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "parent_id");
}

test "executeAddElementToString returns error JSON when name is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "name");
}

test "executeAddElementToString returns error JSON when name contains '/'" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "card/sub",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "/");
}

test "executeAddElementToString returns error JSON when html is empty" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = s.page_id,
        .name = "x",
        .type = "rectangle",
        .html = "",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "html");
}

test "executeAddElementToString returns PageNotFound error when page_id doesn't exist" {
    const alloc = testing.allocator;
    var s = try setupDbWithPage();
    defer s.threaded.deinit();
    defer s.db.deinit();
    defer alloc.free(s.item_id);
    defer alloc.free(s.page_id);

    const input = AddElementInput{
        .page_id = "page_does_not_exist",
        .name = "x",
        .type = "rectangle",
        .html = "<div></div>",
    };
    const json = try executeAddElementToString(alloc, &s.db, s.threaded.io(), input);
    defer alloc.free(json);
    try expectJSONError(alloc, json, "page_id");
}

// Exec adapter — merged from `add_design_element.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
pub fn execAddElement(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        AddElementInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_element", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // addElement needs Io for the mkdir-p + atomic file write of the
    // HTML body. ctx.io is the per-request Io runtime.
    const inner = executeAddElementToString(
        ctx.allocator,
        ctx.db,
        ctx.io,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_element", tc.function.arguments, false, err_msg, "");
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
        const output = try wrapToolOutput(ctx.allocator, "add_element", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "add_element", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

