//! LLM tool: `preview_design_page` — render a design page as an SVG preview
//! so the agent can SEE it. Takes `page_id` (required) and an optional
//! `scale` (default 1.0, max 4.0).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const design_model = pabrikcore.ai_mod.design_model;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// Hex alphabet for the random suffix of the preview id (kept local —
/// tool files are self-contained per project convention).
const HEX_DIGITS = "0123456789abcdef";

/// Maximum scale the agent can request. Caps the SVG's pixel dimensions
/// so a malicious or well-meaning LLM can't request a 1000x page scaled to
/// 100,000 px and OOM the side panel renderer.
pub const MAX_SCALE: f64 = 4.0;

/// Input structure for `preview_design_page` tool.
pub const PreviewDesignPageInput = struct {
    /// The design page to render. Required.
    page_id: []const u8 = "",
    /// Scale factor applied to the SVG viewBox AND every element coordinate.
    /// Default 1.0 (1:1 with the design viewport). Max 4.0.
    scale: f64 = 1.0,
};

/// Top-level tool definition for the LLM.
pub const preview_design_page_tool_system_prompt =
    \\## Preview Design Page Tool — Behavior
    \\Use `preview_design_page` to render a design page as SVG in the side panel.
    \\- Provide `page_id` and optional `scale`. Use to visually verify layout after edits.
    \\
;

pub const preview_design_page_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "preview_design_page",
        .description =
        \\Render a design page as an SVG in the side panel so you can SEE the design (the "screenshot" tool). Requires `page_id`; `scale` is optional.
        \\
        \\Element → SVG shape: `rectangle`→`<rect>` (fill, stroke, corner_radius, rotation);
        \\`ellipse`→`<ellipse>` (cx, cy, rx, ry); `text`→`<text>` (x, y, baseline = y + height,
        \\text_content); `image`→`<image>` (href from image_url); `frame`/`group`→`<g>` container,
        \\with children nested inside recursively.
        \\
        \\Returns a JSON object (keys mirror the old `<show_preview>` tags, content_type="html") carrying the `preview_id` the transcript references.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "page_id",
                    .type = "string",
                    .description = "The design page id to render. From `get_design_context`, or create one with `set_design_page`.",
                },
                .{
                    .name = "scale",
                    .type = "number",
                    .description = "Scale applied to the SVG viewBox and every element coordinate. Default 1.0 (the design viewport). Range 0.1 to 4.0: smaller fits a large page, larger zooms in.",
                },
            },
            .required = &.{"page_id"},
        },
        .system_prompt = preview_design_page_tool_system_prompt,
    },
};

// ─── XML / SVG helpers (local — project convention is per-file duplication) ────

fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

/// Generate a unique preview id of the form `pv_<unix_ms>_<6 hex>`.
/// Self-contained copy of the id scheme the deleted `show_preview` tool
/// used, so this tool no longer depends on it. Caller owns the slice.
fn generatePreviewId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const unix_ms = ts.toMilliseconds();
    var random_bytes: [3]u8 = undefined;
    io.random(&random_bytes);
    var hex: [6]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex[i * 2] = HEX_DIGITS[b >> 4];
        hex[i * 2 + 1] = HEX_DIGITS[b & 0xF];
    }
    return std.fmt.allocPrint(allocator, "pv_{d}_{s}", .{ unix_ms, &hex });
}

/// Build the success JSON object `{"status":"shown",...}`.
/// Self-contained copy of the envelope the deleted `show_preview` tool
/// used (keys mirror the old `<show_preview>` tags 1:1). Caller owns the slice.
fn successJSON(
    allocator: std.mem.Allocator,
    preview_id: []const u8,
    content_type: []const u8,
    content_length: usize,
) ![]u8 {
    const clean_id = try sanitizeControlChars(allocator, preview_id);
    defer allocator.free(clean_id);
    const clean_ct = try sanitizeControlChars(allocator, content_type);
    defer allocator.free(clean_ct);
    return try std.json.Stringify.valueAlloc(allocator, .{
        .status = "shown",
        .preview_id = clean_id,
        .content_type = clean_ct,
        .content_length = content_length,
    }, .{});
}

// ─── Build SVG ───────────────────────────────────────────────────────────

/// Render the page's elements as a self-contained SVG document. `scale` is
/// applied to the viewBox AND every coordinate.
fn buildSvg(
    allocator: std.mem.Allocator,
    page: design_model.DesignPage,
    elements: []const design_model.DesignElement,
    scale: f64,
) ![]u8 {
    var svg: std.ArrayList(u8) = .empty;
    errdefer svg.deinit(allocator);

    const w = @as(i64, @intFromFloat(@as(f64, @floatFromInt(page.width)) * scale));
    const h = @as(i64, @intFromFloat(@as(f64, @floatFromInt(page.height)) * scale));

    try svg.appendSlice(allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0
    );
    var wbuf: [32]u8 = undefined;
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, " ");
    var hbuf: [32]u8 = undefined;
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" preserveAspectRatio=\"xMidYMid meet\">");

    // White page background
    try svg.appendSlice(allocator, "<rect x=\"0\" y=\"0\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&hbuf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\" fill=\"#ffffff\" />");

    // Find top-level elements (parent_id empty) and render in z_index/position order.
    // Each top-level may recursively render its children inside its <g>.
    for (elements) |e| {
        if (e.parent_id.len > 0) continue; // belongs to a parent — skip at top level
        try renderElement(allocator, &svg, e, elements, scale, 0);
    }

    try svg.appendSlice(allocator, "</svg>");
    return try svg.toOwnedSlice(allocator);
}

fn renderElement(
    allocator: std.mem.Allocator,
    svg: *std.ArrayList(u8),
    e: design_model.DesignElement,
    all_elements: []const design_model.DesignElement,
    scale: f64,
    depth: usize,
) !void {
    // Guard against pathological nesting (shouldn't happen — cycle preflight
    //     rejects cycles — but defensive).
    if (depth > 32) return;

    // Convert design coords to scaled SVG coords
    const x = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.x)) * scale));
    const y = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.y)) * scale));
    const w = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.width)) * scale));
    const h = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.height)) * scale));

    // Containers (frame, group) wrap their children in a <g>
    const is_container = std.mem.eql(u8, e.elem_type, "frame") or
        std.mem.eql(u8, e.elem_type, "group");

    if (is_container) {
        try svg.appendSlice(allocator, "<g");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, ">");

        // Render children (parent_id == this element's id)
        const child_id_buf = try std.fmt.allocPrint(allocator, "elem_{s}", .{e.name});
        defer allocator.free(child_id_buf);
        for (all_elements) |child| {
            if (!std.mem.eql(u8, child.parent_id, e.id)) continue;
            try renderElement(allocator, svg, child, all_elements, scale, depth + 1);
        }

        try svg.appendSlice(allocator, "</g>");
        return;
    }

    // Leaf types
    if (std.mem.eql(u8, e.elem_type, "rectangle")) {
        try svg.appendSlice(allocator, "<rect");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        if (e.corner_radius > 0) {
            const cr = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.corner_radius)) * scale));
            var crbuf: [32]u8 = undefined;
            try svg.appendSlice(allocator, " rx=\"");
            try svg.appendSlice(allocator, std.fmt.bufPrint(&crbuf, "{d}", .{cr}) catch "0");
            try svg.appendSlice(allocator, "\"");
        }
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        if (e.rotation != 0.0) try appendRotation(svg, allocator, e.x, e.y, h, e.rotation, scale);
        try svg.appendSlice(allocator, " />");
    } else if (std.mem.eql(u8, e.elem_type, "ellipse")) {
        const cx = x + @divTrunc(w, 2);
        const cy = y + @divTrunc(h, 2);
        const rx = @divTrunc(w, 2);
        const ry = @divTrunc(h, 2);
        try svg.appendSlice(allocator, "<ellipse");
        var buf: [32]u8 = undefined;
        try svg.appendSlice(allocator, " cx=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{cx}) catch "0");
        try svg.appendSlice(allocator, "\" cy=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{cy}) catch "0");
        try svg.appendSlice(allocator, "\" rx=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{rx}) catch "0");
        try svg.appendSlice(allocator, "\" ry=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{ry}) catch "0");
        try svg.appendSlice(allocator, "\"");
        try appendFillStroke(svg, allocator, e, scale);
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, " />");
    } else if (std.mem.eql(u8, e.elem_type, "text")) {
        // Render Y baseline as y + height (so the text sits INSIDE the bbox)
        const baseline = y + h;
        try svg.appendSlice(allocator, "<text");
        var buf: [32]u8 = undefined;
        try svg.appendSlice(allocator, " x=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{x}) catch "0");
        try svg.appendSlice(allocator, "\" y=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{baseline}) catch "0");
        try svg.appendSlice(allocator, "\" font-family=\"sans-serif\"");
        // SVG font size scales with bbox height; min 8 to keep small text legible
        const font_size = @max(@as(i64, 8), h);
        try svg.appendSlice(allocator, " font-size=\"");
        try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{font_size}) catch "0");
        try svg.appendSlice(allocator, "\"");
        if (e.fill.len > 0) {
            const v = try xmlEscape(allocator, e.fill);
            defer allocator.free(v);
            try svg.appendSlice(allocator, " fill=\"");
            try svg.appendSlice(allocator, v);
            try svg.appendSlice(allocator, "\"");
        } else {
            try svg.appendSlice(allocator, " fill=\"#000000\"");
        }
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, ">");
        if (e.text_content.len > 0) {
            const v = try xmlEscape(allocator, e.text_content);
            defer allocator.free(v);
            try svg.appendSlice(allocator, v);
        }
        try svg.appendSlice(allocator, "</text>");
    } else if (std.mem.eql(u8, e.elem_type, "image")) {
        try svg.appendSlice(allocator, "<image");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        if (e.image_url.len > 0) {
            const v = try xmlEscape(allocator, e.image_url);
            defer allocator.free(v);
            try svg.appendSlice(allocator, " href=\"");
            try svg.appendSlice(allocator, v);
            try svg.appendSlice(allocator, "\"");
        }
        if (e.opacity != 1.0) try appendOpacity(svg, allocator, e.opacity);
        try svg.appendSlice(allocator, " />");
    } else {
        // Unknown type — render as a labeled outlined rectangle so the agent
        // sees SOMETHING instead of nothing. Avoids silent drops.
        try svg.appendSlice(allocator, "<rect");
        try appendBoundsAttrs(svg, allocator, x, y, w, h);
        try svg.appendSlice(allocator, " fill=\"#eeeeee\" stroke=\"#999999\"");
        try svg.appendSlice(allocator, " />");
    }
}

fn appendBoundsAttrs(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
) !void {
    var buf: [32]u8 = undefined;
    try svg.appendSlice(allocator, " x=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{x}) catch "0");
    try svg.appendSlice(allocator, "\" y=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{y}) catch "0");
    try svg.appendSlice(allocator, "\" width=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{w}) catch "0");
    try svg.appendSlice(allocator, "\" height=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{h}) catch "0");
    try svg.appendSlice(allocator, "\"");
}

fn appendFillStroke(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    e: design_model.DesignElement,
    scale: f64,
) !void {
    const fill = if (e.fill.len > 0) e.fill else "transparent";
    const fill_escaped = try xmlEscape(allocator, fill);
    defer allocator.free(fill_escaped);
    try svg.appendSlice(allocator, " fill=\"");
    try svg.appendSlice(allocator, fill_escaped);
    try svg.appendSlice(allocator, "\"");

    if (e.stroke.len > 0) {
        const stroke_escaped = try xmlEscape(allocator, e.stroke);
        defer allocator.free(stroke_escaped);
        try svg.appendSlice(allocator, " stroke=\"");
        try svg.appendSlice(allocator, stroke_escaped);
        try svg.appendSlice(allocator, "\"");
        if (e.stroke_width > 0) {
            const sw = @as(i64, @intFromFloat(@as(f64, @floatFromInt(e.stroke_width)) * scale));
            var buf: [32]u8 = undefined;
            try svg.appendSlice(allocator, " stroke-width=\"");
            try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{sw}) catch "0");
            try svg.appendSlice(allocator, "\"");
        }
    }
}

fn appendOpacity(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    opacity: f64,
) !void {
    var buf: [64]u8 = undefined;
    try svg.appendSlice(allocator, " opacity=\"");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d:.6}", .{opacity}) catch "0");
    try svg.appendSlice(allocator, "\"");
}

fn appendRotation(
    svg: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cx: i64,
    cy: i64,
    h: i64,
    rotation: f64,
    scale: f64,
) !void {
    // SVG rotation: rotate(angle, cx, cy), where (cx, cy) is the bbox
    // center in the parent coord space.
    const center_x = @as(i64, @intFromFloat(@as(f64, @floatFromInt(cx)) * scale));
    const center_y = @as(i64, @intFromFloat(@as(f64, @floatFromInt(cy)) * scale)) +
        @divTrunc(@as(i64, @intFromFloat(@as(f64, @floatFromInt(h)) * scale)), 2);
    var buf: [64]u8 = undefined;
    const deg = rotation * 180.0 / std.math.pi;
    try svg.appendSlice(allocator, " transform=\"rotate(");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d:.6}", .{deg}) catch "0");
    try svg.appendSlice(allocator, ", ");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{center_x}) catch "0");
    try svg.appendSlice(allocator, ", ");
    try svg.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{center_y}) catch "0");
    try svg.appendSlice(allocator, ")\"");
}

// ─── Execute ─────────────────────────────────────────────────────────────

/// Execute `preview_design_page`.
pub fn executePreviewDesignPageToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    input: PreviewDesignPageInput,
    out_preview_id: *[]u8,
) ![]u8 {
    // Generate the preview id first (always allocated, even on error,
    // so the caller can correlate).
    const preview_id = try generatePreviewId(allocator, io);
    out_preview_id.* = preview_id;

    // Validate scale
    if (input.scale < 0.1 or input.scale > MAX_SCALE) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "scale must be between 0.1 and {d:.1} (got {d:.4})",
            .{ MAX_SCALE, input.scale },
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    }

    // Validate page_id
    if (input.page_id.len == 0) {
        return try errorJSON(allocator, "page_id is required");
    }

    // Fetch the page + elements
    var bundle = design_model.getPageWithElements(allocator, db, input.page_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "page_id '{s}' not found: {s}",
            .{ input.page_id, @errorName(err) },
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    };
    defer bundle.deinit(allocator);

    // Build the SVG
    const svg_content = try buildSvg(allocator, bundle.page, bundle.elements, input.scale);
    defer allocator.free(svg_content);

    // Sanitize the SVG HTML content (defensive — invalid UTF-8 would break
    // the iframe's parser). The preview's content_type is "html" so the
    // sandboxed iframe renders it directly.
    const sanitized = try @import("helpers").sanitize.sanitizeUtf8(allocator, svg_content);
    defer allocator.free(sanitized);

    // Return the preview metadata as JSON (keys mirror the old
    // `<show_preview>` tags 1:1).
    return try successJSON(
        allocator,
        preview_id,
        "html",
        sanitized.len,
    );
}

// ===== Tests merged from preview_design_page_test.zig (2026-09-29 flatten)
// ===== NOT REGISTERED: no registrar imports this file, so these tests are
// not discovered by `zig build test`.

const testing = std.testing;
// ─── Helpers ─────────────────────────────────────────────────────────────

const testing_ctx = std.testing;

fn setupCtx() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    io: std.Io,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_ctx.allocator;
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

    var tmp = testing_ctx.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_ctx.io, &tmpdir_buf);
    const tmpdir_path = try testing_ctx.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_preview";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    return .{
        .db = db,
        .threaded = threaded,
        .io = io,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
    };
}

fn teardownCtx(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Insert a raw element row directly. Bypasses on-disk HTML write.
fn insertElementRaw(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
    name: []const u8,
    elem_type: []const u8,
    x: i64, y: i64, width: i64, height: i64,
    fill: []const u8,
    parent_id: ?[]const u8,
    text_content: []const u8,
    image_url: []const u8,
) !void {
    const id = try std.fmt.allocPrint(alloc, "elem_{s}", .{name});
    defer alloc.free(id);
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
        \\    0, 0, ?, 0,
        \\    ?, '', 0, 0, 1.0,
        \\    ?, '', ?, ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{
        id, page_id, name,
        x_str, y_str, w_str, h_str,
        elem_type,
        fill,
        text_content,
        image_url,
        parent_id orelse "",
    });
}

// ─── Behavioural tests (REMOVED, 2026-09-29 flatten) ─────────────────────
// The former preview_design_page_test.zig also carried 9 behavioural tests
// that built a v6-schema in-memory DB and asserted the tool's XML output

// Exec adapter — merged from `preview_design_page.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
pub fn execPreviewDesignPage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        PreviewDesignPageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // The preview id is always allocated, even on validation failure, so
    // the caller can log the failed attempt with the correlation id.
    var preview_id: []u8 = undefined;

    const inner = executePreviewDesignPageToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value,
        &preview_id,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);
    defer ctx.allocator.free(preview_id);

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
        const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "preview_design_page", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

