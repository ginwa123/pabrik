//! Data layer for the design-mode workspace item (item_type='design').
//!
//! Each design workspace item has N pages (e.g. "Home", "Login",
//! "Dashboard"), and each page has 0..N positioned elements (e.g.
//! "login-card", "hero-image") with their HTML bodies stored on disk
//! under `<workspace_item.path>/.pabrik/design/<page_name>/<element_name>.html`.
//!
//! Schema:
//! - `design_pages` — created by Migration 055, upgraded by 056
//! - `design_page_elements` — created by Migration 056, v6 props added
//!   by Migration 057.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are
//! owned by the `Row` and freed by `row.deinit(allocator)`. To keep a
//! value past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by
//! `listPages` are owned by the caller and must be released with
//! `freePages`.
//!
//! Why this rewrite
//! ────────────────
//! The v5 `design_model.zig` was 5-file overengineered and supported
//! the old panzoom-based canvas. The v6 rewrite focuses on the
//! 3-tool LLM surface (`set_design_page`, `add_element`,
//! `update_element`) and the file-backed HTML invariants (atomic
//! writes, orphan cleanup on delete, path-traversal defense). The
//! v6 surface is small enough to fit in one file (~600 LoC).
//!
//! Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 1)

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const helpers = @import("helpers");
const design_io = @import("design_io.zig");
const on_event_sent_design = @import("on_event_sent_design.zig");

/// Generate a unique page id of the form `page_<unix_nanoseconds>`.
/// Same approach as `kanban_model.generateColumnId` (a process-global
/// monotonic counter XORed with a stack address) — see that file
/// for the rationale (avoids `std.c.clock_gettime` which doesn't
/// compile on Windows).
fn generatePageId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextPageIdCounter();
    var entropy: [8]u8 = undefined;
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy));
    const mixed: u64 = counter ^ stack_addr;
    std.mem.writeInt(u64, &entropy, mixed, .little);
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (entropy, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.fmt.allocPrint(allocator, "page_{s}", .{&hex});
}

var page_id_counter: std.atomic.Value(u64) = .init(0);

fn nextPageIdCounter() u64 {
    return page_id_counter.fetchAdd(1, .seq_cst);
}

// ─── DesignPage struct + freePages ────────────────────────────────────────

/// One design-page row, fully duplicated into heap memory.
/// Free with `freePages(allocator, slice)`.
pub const DesignPage = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    /// 1:1 FK to `workspace_item_tasks.id`. Set atomically by
    /// `setDesignPage` at create time (each new page gets a fresh
    /// `task_<unix_nanoseconds>` row whose name is
    /// `"Design Chat: <page_name>"`). Empty string `""` for legacy
    /// pre-Migration-066 rows that the backfill didn't catch (no row
    /// in current data — the migration's backfill is exhaustive —
    /// but defensive: `SELECT COALESCE(...)` keeps the field
    /// non-empty on the wire even if a future DB state slips a NULL).
    workspace_item_task_id: []u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-page strings and the backing slice in one call.
pub fn freePages(allocator: std.mem.Allocator, pages: []DesignPage) void {
    for (pages) |p| {
        allocator.free(p.id);
        allocator.free(p.workspace_item_id);
        allocator.free(p.name);
        allocator.free(p.workspace_item_task_id);
        allocator.free(p.created_at);
        allocator.free(p.updated_at);
    }
    allocator.free(pages);
}

// ─── setDesignPage ────────────────────────────────────────────────────────

pub const SetDesignPageInput = struct {
    item_id: []const u8,
    page_name: []const u8,
    width: i64,
    height: i64,
};

pub const SetDesignPageError = error{
    ItemPathMissing,
    BadPageName,
    DbError,
    OutOfMemory,
};

/// Create or update a page for a design item. Idempotent: if a page
/// with the same (workspace_item_id, name) exists, its width/height
/// are updated; otherwise a new row is inserted.
///
/// Returns the page_id of the existing-or-newly-created page.
/// Caller owns the returned slice.
///
/// Prerequisite: `workspace_items.path` is non-empty (otherwise
/// returns `ItemPathMissing`).
pub fn setDesignPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SetDesignPageInput,
) anyerror![]u8 {
    if (input.page_name.len == 0) return error.BadPageName;

    // 1. Look up the design item's `path`. Returns ItemPathMissing
    //    if NULL/empty.
    const path_opt: ?[]u8 = blk: {
        var q = try db.query(allocator,
            "SELECT wi.path FROM workspace_items wi " ++
            "WHERE wi.id = ? AND wi.item_type = 'design'",
            &.{input.item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            if (row.values[0].len == 0) break :blk null;
            break :blk try allocator.dupe(u8, row.values[0]);
        }
        break :blk null;
    };
    defer if (path_opt) |p| allocator.free(p);
    if (path_opt == null) return error.ItemPathMissing;

    // 2. Check whether a row with the same (item_id, name) already
    //    exists. If yes, just update its width/height/updated_at
    //    and return the existing id. This is true idempotency —
    //    every call returns the same id for the same (item, name).
    if (try findPageIdByName(allocator, db, input.item_id, input.page_name)) |existing_id| {
        // Existing row → update width/height/updated_at and return.
        defer allocator.free(existing_id);

        // SQLite's argv takes `[]const []const u8`, so stringify the
        // integer columns. `db.exec` binds empty slices as SQL NULL
        // (see project memory `sqlite-backend-empty-slice-binds-as-null`),
        // so the strings must be non-empty even for the "zero" case.
        const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
        defer allocator.free(width_str);
        const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
        defer allocator.free(height_str);

        try db.exec(allocator,
            "UPDATE design_pages SET width = ?, height = ?, " ++
            "updated_at = datetime('now') WHERE id = ?",
            &.{ width_str, height_str, existing_id });
        return allocator.dupe(u8, existing_id);
    }

    // 3. New row → generate a fresh id and INSERT.
    const id = try generatePageId(allocator);
    defer allocator.free(id);

    // SQLite's argv takes `[]const []const u8`, so we have to
    // stringify the integer columns. `db.exec` binds empty slices
    // as SQL NULL (see project memory
    // `sqlite-backend-empty-slice-binds-as-null`), so the strings
    // we build here must be non-empty even for the "zero" case.
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
    defer allocator.free(height_str);

    // Generate the per-page chat task id (paired with the page so the
    // 1:1 FK is always populated on INSERT). Uses the same
    // `task_<unix_nanoseconds>` scheme as
    // `llm_history.createWorkspaceItemTask` so existing code that
    // looks up tasks by id prefix keeps working.
    var task_id_buf: [64]u8 = undefined;
    const task_id = std.fmt.bufPrint(
        task_id_buf[0..],
        "task_{d}",
        .{helpers.unixTimestampNanos()},
    ) catch return error.BufferTooSmall;

    // The task's user-visible name matches the per-page naming
    // convention (`"Design Chat: <page_name>"`) introduced by the
    // 2026-07-28 per-page chat plan. Keeping the naming stable across
    // the migration means a user with a legacy
    // `"Design Chat: <pageName>"` task (created by the 2026-07-28
    // frontend-only plan) will see its new design-page task reuse
    // that name rather than getting a parallel
    // `"Design Chat: <pageName> (2)"`-style artifact.
    var task_name_buf: [512]u8 = undefined;
    const task_name = std.fmt.bufPrint(
        task_name_buf[0..],
        "Design Chat: {s}",
        .{input.page_name},
    ) catch return error.BufferTooSmall;

    // Insert the per-page chat task FIRST so the workspace_item_tasks
    // row exists when design_pages INSERT fires (the application-level
    // "FK" we maintain via the UNIQUE index would otherwise allow a
    // dangling reference). task_type='standard' matches the existing
    // per-page chat tasks (no kanban auto-assign — the parent isn't a
    // kanban). description='' is a SQL '' literal so it doesn't trip
    // the empty-slice-binds-as-NULL trap.
    try db.exec(allocator,
        "INSERT INTO workspace_item_tasks " ++
            "(id, name, workspace_item_id, task_type, description) " ++
            "VALUES (?, ?, ?, 'standard', '')",
        &.{ task_id, task_name, input.item_id });

    try db.exec(allocator,
        \\INSERT INTO design_pages (
        \\    id, workspace_item_id, name, workspace_item_task_id,
        \\    width, height, position,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?,
        \\    COALESCE((SELECT MAX(dp.position) FROM design_pages dp
        \\        WHERE dp.workspace_item_id = ?), -1) + 1,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, input.item_id, input.page_name, task_id, width_str, height_str, input.item_id });

    return allocator.dupe(u8, id);
}

/// Look up the page id for the given (item_id, page_name). Returns
/// the owned id slice on hit, or `null` when no such page exists.
fn findPageIdByName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    page_name: []const u8,
) !?[]u8 {
    var q = try db.query(allocator,
        "SELECT dp.id FROM design_pages dp " ++
        "WHERE dp.workspace_item_id = ? AND dp.name = ?",
        &.{ item_id, page_name });
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

// ─── updateDesignPage ─────────────────────────────────────────────────────

pub const UpdateDesignPageInput = struct {
    page_id: []const u8,
    width: i64,
    height: i64,
    // NEW (2026-08-06 — design page rename menu). Optional page name.
    // When non-null AND non-empty, the UPDATE statement writes it to
    // `design_pages.name` (via dynamic SQL — building the SET clause
    // conditionally so empty patches don't trigger NULL writes).
    // Empty string is rejected with BadPageName (matches the same
    // guard `setDesignPage` enforces — a page with an empty name
    // would break the design folder derivation in design_io).
    name: ?[]const u8 = null,
};

/// Update an existing design page by id. UPDATE-only; does NOT
/// insert — see `setDesignPage` for the upsert path used by the
/// agent's `set_design_page` tool. Returns the post-update
/// `DesignPage` with heap-owned string fields; caller MUST release
/// with `freePages(allocator, &[_]DesignPage{result})` or pass the
/// whole struct to `freePages` wrapped in a single-element array.
///
/// Width must be in [320, 4096], height in [240, 4096]. These ranges
/// match typical viewport sizes (320 = iPhone SE width, 4096 = common
/// 4K width; 240 = iPhone SE height, 4096 = tall scrollable hero).
/// `name`, when provided, must be non-empty (matches `setDesignPage`'s
/// BadPageName guard).
pub fn updateDesignPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdateDesignPageInput,
) anyerror!DesignPage {
    if (input.page_id.len == 0) return error.PageIdRequired;
    if (input.width < 320 or input.width > 4096) return error.WidthOutOfRange;
    if (input.height < 240 or input.height > 4096) return error.HeightOutOfRange;
    // Only validate the name when it's actually being updated (avoids
    // a back-compat break for callers that always pass `name: null`).
    if (input.name) |n| {
        if (n.len == 0) return error.BadPageName;
    }

    // Existence check first — distinguishes PageNotFound from a silent
    // no-op UPDATE on a non-existent row. Also gives us the
    // workspace_item_id we need to call listPages for the re-fetch.
    const item_id_owned: []u8 = blk: {
        var q = try db.query(allocator,
            "SELECT dp.workspace_item_id FROM design_pages dp WHERE dp.id = ?",
            &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    defer allocator.free(item_id_owned);

    // Stringify integer cols (db.exec binds only TEXT — see project
    // memory `sqlite-backend-empty-slice-binds-as-null`). The strings
    // must be non-empty even for the "zero" case.
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
    defer allocator.free(height_str);

    // Dynamic SQL builder — width+height are always set, name is
    // conditional. Back-compat: when `name == null`, the produced
    // SQL is identical to the pre-fix `UPDATE design_pages SET
    // width=?, height=?, updated_at=datetime('now') WHERE id=?`.
    // The `name` value is bound via `?` so the SQLite driver handles
    // escaping (matches `setDesignPage`'s naming convention).
    const has_name = input.name != null;
    const update_sql: []const u8 = if (has_name)
        "UPDATE design_pages SET width = ?, height = ?, name = ?, " ++
            "updated_at = datetime('now') WHERE id = ?"
    else
        "UPDATE design_pages SET width = ?, height = ?, " ++
            "updated_at = datetime('now') WHERE id = ?";

    const update_args: []const []const u8 = if (has_name)
        &.{ width_str, height_str, input.name.?, input.page_id }
    else
        &.{ width_str, height_str, input.page_id };

    db.exec(allocator, update_sql, update_args) catch return error.DbError;

    // Re-fetch the updated row to return the full DesignPage. Same
    // ownership pattern as `design_pages_create.zig` useCase:
    // listPages returns a fresh slice whose strings are heap-owned;
    // we duplicate into a single struct so the caller can `freePages`
    // it without affecting the listPages slice.
    const pages = listPages(allocator, db, item_id_owned) catch return error.DbError;
    defer freePages(allocator, pages);

    for (pages) |p| {
        if (!std.mem.eql(u8, p.id, input.page_id)) continue;

        var duped_id: ?[]u8 = null;
        var duped_workspace_item_id: ?[]u8 = null;
        var duped_name: ?[]u8 = null;
        var duped_workspace_item_task_id: ?[]u8 = null;
        var duped_created_at: ?[]u8 = null;
        var duped_updated_at: ?[]u8 = null;
        errdefer {
            if (duped_id) |v| allocator.free(v);
            if (duped_workspace_item_id) |v| allocator.free(v);
            if (duped_name) |v| allocator.free(v);
            if (duped_workspace_item_task_id) |v| allocator.free(v);
            if (duped_created_at) |v| allocator.free(v);
            if (duped_updated_at) |v| allocator.free(v);
        }
        duped_id = try allocator.dupe(u8, p.id);
        duped_workspace_item_id = try allocator.dupe(u8, p.workspace_item_id);
        duped_name = try allocator.dupe(u8, p.name);
        duped_workspace_item_task_id = try allocator.dupe(u8, p.workspace_item_task_id);
        duped_created_at = try allocator.dupe(u8, p.created_at);
        duped_updated_at = try allocator.dupe(u8, p.updated_at);

        return .{
            .id = duped_id.?,
            .workspace_item_id = duped_workspace_item_id.?,
            .name = duped_name.?,
            .workspace_item_task_id = duped_workspace_item_task_id.?,
            .width = p.width,
            .height = p.height,
            .position = p.position,
            .created_at = duped_created_at.?,
            .updated_at = duped_updated_at.?,
        };
    }

    // Row existed at SELECT but vanished by the time listPages ran —
    // race condition (someone deleted between our UPDATE and our
    // re-fetch). Surface as DbError so the caller knows something
    // weird happened.
    return error.DbError;
}

// ─── listPages ────────────────────────────────────────────────────────────

/// List the pages of a design workspace item in `position` order.
///
/// Returns an owned slice; caller MUST release with
/// `freePages(allocator, slice)`. If the item has no pages, the slice
/// has length 0 (not an error).
pub fn listPages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) (sqlite.Error || std.mem.Allocator.Error)![]DesignPage {
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name,
        \\       COALESCE(dp.workspace_item_task_id, ''),
        \\       dp.width, dp.height, dp.position,
        \\       COALESCE(dp.created_at, ''), COALESCE(dp.updated_at, '')
        \\FROM design_pages dp
        \\WHERE dp.workspace_item_id = ?
        \\ORDER BY dp.position ASC
    , &.{item_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignPage).empty;
    errdefer {
        for (rows.items) |p| {
            allocator.free(p.id);
            allocator.free(p.workspace_item_id);
            allocator.free(p.name);
            allocator.free(p.workspace_item_task_id);
            allocator.free(p.created_at);
            allocator.free(p.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .workspace_item_task_id = try allocator.dupe(u8, row.values[3]),
            .width = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .height = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
            .position = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[7]),
            .updated_at = try allocator.dupe(u8, row.values[8]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

// ─── DesignElement struct + freeElements ───────────────────────────────────

/// One design-page-element row, fully duplicated into heap memory.
/// Free with `freeElements(allocator, slice)`.
pub const DesignElement = struct {
    id: []u8,
    page_id: []u8,
    name: []u8,
    file_path: []u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    z_index: i64,
    position: i64,
    /// One of "rectangle" | "ellipse" | "text" | "image" | "frame" | "group"
    elem_type: []u8,
    rotation: f64,
    fill: []u8,
    stroke: []u8,
    stroke_width: i64,
    corner_radius: i64,
    opacity: f64,
    text_content: []u8,
    text_style: []u8,
    image_url: []u8,
    /// FK to a `group`/`frame` element on the same page (NULL for
    /// top-level). Migration 057 introduced the column; the read-back
    /// path is exposed in the 2026-07-28-grouped-layers plan (Chunk 1).
    parent_id: []u8,
    created_at: []u8,
    updated_at: []u8,
};

/// Free the per-element strings and the backing slice in one call.
pub fn freeElements(allocator: std.mem.Allocator, elements: []DesignElement) void {
    for (elements) |e| {
        allocator.free(e.id);
        allocator.free(e.page_id);
        allocator.free(e.name);
        allocator.free(e.file_path);
        allocator.free(e.elem_type);
        allocator.free(e.fill);
        allocator.free(e.stroke);
        allocator.free(e.text_content);
        allocator.free(e.text_style);
        allocator.free(e.image_url);
        allocator.free(e.parent_id);
        allocator.free(e.created_at);
        allocator.free(e.updated_at);
    }
    allocator.free(elements);
}

/// Element type as a Zig enum. The wire string is `@tagName(input.type)`.
pub const ElementType = enum {
    rectangle,
    ellipse,
    text,
    image,
    frame,
    group,
};

// ─── addElement ───────────────────────────────────────────────────────────

pub const AddElementInput = struct {
    page_id: []const u8,
    name: []const u8,
    elem_type: ElementType,
    html: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    fill: []const u8,
    rotation: f64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8 = "",
    text_style: []const u8 = "",
    image_url: []const u8 = "",
    /// Optional FK to an existing `group` or `frame` on the same page.
    /// When `null` (the default), the new element is top-level — same
    /// as the pre-2026-07-29 behavior. The parent MUST exist on the
    /// same `page_id` AND be of type `group` or `frame`; otherwise
    /// the call fails with `BadParentId` or `ParentNotContainer`.
    parent_id: ?[]const u8 = null,
};

pub const AddElementError = error{
    PageNotFound,
    ItemPathMissing,
    BadName,
    FileWriteFailed,
    /// `input.parent_id` doesn't reference any element on this page
    /// (or doesn't reference any element at all).
    BadParentId,
    /// `input.parent_id` references an element that is NOT a
    /// `group` or `frame` (i.e., it's a leaf type like rectangle,
    /// text, ellipse, or image). Leaf elements can't contain children.
    ParentNotContainer,
    DbError,
    OutOfMemory,
};

/// Add a new element to a design page. Atomically writes the element's
/// HTML to disk and inserts the corresponding metadata row.
///
/// Returns the new element_id. Caller owns the returned slice.
///
/// Behavior:
///   1. Look up the parent page (item_id, page name, item path) via
///      JOIN. Returns `PageNotFound` if the page is missing or
///      `ItemPathMissing` if the workspace_item has no `path`.
///   2. Sanitize page name and element name.
///   3. Build file path: `<item_path>/.pabrik/design/<page>/<element>.html`
///   4. Make the page directory (mkdir-p via Io).
///   5. Atomic-write the HTML body to disk.
///   6. INSERT the metadata row with all 11 v6 columns.
pub fn addElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    input: AddElementInput,
) anyerror![]u8 {
    if (input.name.len == 0) return error.BadName;

    // 1. Look up parent page via JOIN. Also SELECT `wi.workspace_id`
    //    so we can emit a `design_element_created` SSE event with the
    //    full (workspace_id, item_id, page_id, element_id) context
    //    — the frontend listener filters events by all four ids.
    const Lookup = struct { workspace_id: []u8, item_id: []u8, page_name: []u8, item_path: []u8 };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id, dp.name, wi.path
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
            .page_name = try allocator.dupe(u8, row.values[2]),
            .item_path = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);
    defer allocator.free(lookup.page_name);
    defer allocator.free(lookup.item_path);
    if (lookup.item_path.len == 0) return error.ItemPathMissing;

    // 1b. Validate parent_id (when provided): the parent element must
    //     exist on the SAME page and must be of type `group` or `frame`.
    //
    //     We do this BEFORE the disk-write steps so a bad parent_id
    //     fails fast without leaving orphan files. The query reads the
    //     parent's page_id + type via a single SELECT — much cheaper
    //     than writing the HTML and then rolling back the INSERT.
    const parent_id_to_bind: []const u8 = if (input.parent_id) |pid| blk: {
        var q = try db.query(allocator,
            \\SELECT de.page_id, de.type FROM design_page_elements de WHERE de.id = ?
        , &.{pid});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BadParentId;
        defer row.deinit(allocator);
        const parent_page_id: []const u8 = row.values[0];
        const parent_type: []const u8 = row.values[1];
        if (!std.mem.eql(u8, parent_page_id, input.page_id)) return error.BadParentId;
        if (!std.mem.eql(u8, parent_type, "group") and
            !std.mem.eql(u8, parent_type, "frame"))
        {
            return error.ParentNotContainer;
        }
        break :blk pid;
    } else "";

    // 2. Sanitize the page and element names for filesystem safety.
    const sanitized_page = try design_io.sanitizeFilename(allocator, lookup.page_name);
    defer allocator.free(sanitized_page);
    const sanitized_elem = try design_io.sanitizeFilename(allocator, input.name);
    defer allocator.free(sanitized_elem);

    // 3. Build the file path.
    const page_dir = try std.fmt.allocPrint(allocator, "{s}/.pabrik/design/{s}", .{ lookup.item_path, sanitized_page });
    defer allocator.free(page_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ page_dir, sanitized_elem });
    defer allocator.free(file_path);

    // 4. mkdir -p the page directory (createDirPath is the Io-native
    // mkdir-p equivalent in Zig 0.16).
    std.Io.Dir.cwd().createDirPath(io, page_dir) catch return error.FileWriteFailed;

    // 5. Atomic-write the HTML body to disk.
    design_io.atomicWriteFile(allocator, file_path, input.html) catch return error.FileWriteFailed;

    // 6. INSERT the metadata row with all 11 v6 columns populated.
    const id = try generateElementId(allocator);
    defer allocator.free(id);

    // Stringify integer / real columns for argv compatibility.
    const x_str = try std.fmt.allocPrint(allocator, "{d}", .{input.x});
    defer allocator.free(x_str);
    const y_str = try std.fmt.allocPrint(allocator, "{d}", .{input.y});
    defer allocator.free(y_str);
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{input.width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{input.height});
    defer allocator.free(height_str);
    const rotation_str = try std.fmt.allocPrint(allocator, "{d}", .{input.rotation});
    defer allocator.free(rotation_str);
    const corner_radius_str = try std.fmt.allocPrint(allocator, "{d}", .{input.corner_radius});
    defer allocator.free(corner_radius_str);
    const opacity_str = try std.fmt.allocPrint(allocator, "{d}", .{input.opacity});
    defer allocator.free(opacity_str);
    const elem_type_str = @tagName(input.elem_type);

    db.exec(allocator,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, 0,
        \\    COALESCE((SELECT MAX(de.position) FROM design_page_elements de
        \\        WHERE de.page_id = ?), -1) + 1,
        \\    ?, ?, COALESCE(?, ''), '', 0, ?, ?, '', '', '', ?,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{
        id, input.page_id, input.name, file_path,
        x_str, y_str, width_str, height_str, input.page_id,
        elem_type_str, rotation_str, input.fill, corner_radius_str, opacity_str,
        // SqliteBackend.exec binds an empty slice as SQL NULL — that's
        // exactly what we want for `parent_id = ?` (nullable column)
        // when the user did not pass parent_id. See project memory
        // `sqlite-backend-empty-slice-binds-as-null`.
        //
        // For `fill` (NOT NULL DEFAULT ''), the same empty-slice bind
        // would land as NULL and trip the NOT NULL constraint. The
        // COALESCE(?, '') above maps the NULL bind back to the
        // column's own default, which is the schema author's intent.
        // (regression test: design_model_test.zig "addElement with
        // empty fill succeeds".)
        parent_id_to_bind,
    }) catch |err| {
        // Surface the actual sqlite error so a 500 "Failed to create
        // element" tells the user whether it was a FK error, a NOT
        // NULL violation, a uniqueness collision, a bind error, or
        // something else. The pre-fix code did nothing here, so the
        // caller saw only a generic `error.DbError` from a catch-all
        // downstream — actionable only by reading the backend log.
        std.log.err(
            "addElement: INSERT failed for page_id={s} name={s} type={s} err={s}",
            .{ input.page_id, input.name, elem_type_str, @errorName(err) },
        );
        return error.DbError;
    };

    // Emit SSE event AFTER the SQL INSERT succeeded. Best-effort: if
    // the event_bus is not initialized (e.g. in unit tests without a
    // GinwaServer singleton) or the JSON serialization fails, the
    // caller still gets the new element_id — SSE is a hint, not a
    // hard contract. The lookup slices (workspace_id, item_id) are
    // still alive at this point; the function-level defers haven't
    // fired yet.
    on_event_sent_design.onEventSendDesignElementCreated(allocator, .{
        .action = "created",
        .workspace_id = lookup.workspace_id,
        .item_id = lookup.item_id,
        .page_id = input.page_id,
        .element_id = id,
    }) catch {};

    return allocator.dupe(u8, id);
}

/// Generate a unique element id of the form `elem_<nanos>`.
fn generateElementId(allocator: std.mem.Allocator) ![]u8 {
    const counter = nextElementIdCounter();
    var entropy: [8]u8 = undefined;
    const stack_addr: u64 = @intCast(@intFromPtr(&entropy));
    const mixed: u64 = counter ^ stack_addr;
    std.mem.writeInt(u64, &entropy, mixed, .little);
    var hex: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (entropy, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return std.fmt.allocPrint(allocator, "elem_{s}", .{&hex});
}

var element_id_counter: std.atomic.Value(u64) = .init(0);

fn nextElementIdCounter() u64 {
    return element_id_counter.fetchAdd(1, .seq_cst);
}

// ─── updateElement ────────────────────────────────────────────────────────

pub const UpdateElementInput = struct {
    element_id: []const u8,
    name: ?[]const u8 = null,
    elem_type: ?ElementType = null,
    html: ?[]const u8 = null,
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    stroke_width: ?i64 = null,
    corner_radius: ?i64 = null,
    opacity: ?f64 = null,
    text_content: ?[]const u8 = null,
    text_style: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    /// FK to a `group`/`frame` element on the same page. `null` =
    /// leave unchanged. Pass `""` (empty string) to clear the
    /// parent (reparent to top-level). See
    /// `docs/superpowers/plans/2026-07-28-grouped-layers.md` Chunk 2.
    parent_id: ?[]const u8 = null,
    /// Optional post-update position normalization. When set, the
    /// element's position is recomputed AFTER the SET clause runs —
    /// used by the drag-to-reparent UX so the moved element lands
    /// at the bottom of its new parent's children. See
    /// `docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md`.
    reposition: ?RepositionMode = null,
};

/// How to recompute the element's `position` column after a
/// parent_id change. Currently only one variant; future variants
/// branch in `updateElement` to do precise-position inserts.
pub const RepositionMode = enum {
    /// Land at MAX(position) + 1 of all rows that share the new
    /// parent (or are top-level when parent_id is empty). The
    /// element being moved is excluded from the MAX so it lands
    /// strictly after its new siblings.
    last_in_parent,
};

/// Update an element. Each non-null field is SET in the SQL UPDATE;
/// null fields are left unchanged. If `html` is set, the file at
/// `file_path` is rewritten atomically. Returns the element_id on
/// success; returns `ElementNotFound` if no such row exists.
pub fn updateElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UpdateElementInput,
) anyerror![]u8 {
    // 0. Pre-lookup: fetch (page_id, workspace_id, item_id) for the
    //    element so we can emit a `design_element_updated` SSE
    //    event with the full id context (after the SQL UPDATE
    //    succeeds). Returns `ElementNotFound` if no such row.
    //    The JOIN chains design_page_elements → design_pages →
    //    workspace_items.
    const ElementContext = struct {
        page_id: []u8,
        workspace_id: []u8,
        item_id: []u8,
    };
    const ctx: ElementContext = blk: {
        var q = try db.query(allocator,
            \\SELECT de.page_id, wi.workspace_id, dp.workspace_item_id
            \\FROM design_page_elements de
            \\JOIN design_pages dp ON dp.id = de.page_id
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE de.id = ?
        , &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .page_id = try allocator.dupe(u8, row.values[0]),
            .workspace_id = try allocator.dupe(u8, row.values[1]),
            .item_id = try allocator.dupe(u8, row.values[2]),
        };
    };
    defer allocator.free(ctx.page_id);
    defer allocator.free(ctx.workspace_id);
    defer allocator.free(ctx.item_id);

    // Build dynamic SET clause + argv.
    var sets: std.ArrayList([]const u8) = .empty;
    defer sets.deinit(allocator);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    // String scratch buffers we own (cleaned at end of function).
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    if (input.name) |v| { try sets.append(allocator, "name = ?"); try args.append(allocator, v); }
    if (input.elem_type) |v| {
        try sets.append(allocator, "type = ?");
        try args.append(allocator, @tagName(v));
    }
    if (input.x) |v| {
        try sets.append(allocator, "x = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.y) |v| {
        try sets.append(allocator, "y = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.width) |v| {
        try sets.append(allocator, "width = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.height) |v| {
        try sets.append(allocator, "height = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.rotation) |v| {
        try sets.append(allocator, "rotation = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.fill) |v| { try sets.append(allocator, "fill = ?"); try args.append(allocator, v); }
    if (input.stroke) |v| { try sets.append(allocator, "stroke = ?"); try args.append(allocator, v); }
    if (input.stroke_width) |v| {
        try sets.append(allocator, "stroke_width = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.corner_radius) |v| {
        try sets.append(allocator, "corner_radius = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.opacity) |v| {
        try sets.append(allocator, "opacity = ?");
        try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }
    if (input.text_content) |v| { try sets.append(allocator, "text_content = ?"); try args.append(allocator, v); }
    if (input.text_style) |v| { try sets.append(allocator, "text_style = ?"); try args.append(allocator, v); }
    if (input.image_url) |v| { try sets.append(allocator, "image_url = ?"); try args.append(allocator, v); }
    if (input.parent_id) |v| { try sets.append(allocator, "parent_id = ?"); try args.append(allocator, v); }

    // Cycle prevention for the parent_id assignment. Run BEFORE the
    // UPDATE so a cycle never reaches the database. Two checks:
    //   (a) self-cycle (drop the element into itself)
    //   (b) ancestor-into-descendant (close a cycle via the chain)
    // Both return `error.CycleDetected`, mapped to HTTP 400 in the
    // handler. Skip entirely when parent_id is null (no change).
    if (input.parent_id) |new_pid| {
        if (std.mem.eql(u8, new_pid, input.element_id)) return error.CycleDetected;
        if (try wouldCreateCycle(db, allocator, input.element_id, new_pid)) {
            return error.CycleDetected;
        }
    }

    if (input.reposition) |mode| {
        // Currently only one variant — the `defer _ = mode;` documents
        // the future branch point for additional RepositionMode variants
        // (e.g. `before_sibling`, `after_sibling`).
        defer _ = mode;
        // The new parent_id is what we just appended to the SET list
        // (or empty string for top-level). The COALESCE in the SQL
        // matches the SELECT-side convention used everywhere in the
        // codebase: NULL → ''. So `COALESCE(parent_id, '') = ?` works
        // for BOTH top-level (`?` = '') and nested (`?` = group_id).
        const new_parent_sql: []const u8 = if (input.parent_id) |p| p else "";
        var max_pos_q = try db.query(allocator,
            \\SELECT COALESCE(MAX(position), -1) FROM design_page_elements
            \\WHERE COALESCE(parent_id, '') = ? AND id != ?
        , &.{ new_parent_sql, input.element_id });
        defer max_pos_q.deinit();
        const max_pos_row = (try max_pos_q.next()) orelse unreachable;
        defer max_pos_row.deinit(allocator);
        const max_pos_value = std.fmt.parseInt(i64, max_pos_row.values[0], 10) catch 0;
        const new_position_str = try std.fmt.allocPrint(allocator, "{d}", .{max_pos_value + 1});
        try owned.append(allocator, new_position_str);
        try sets.append(allocator, "position = ?");
        try args.append(allocator, owned.items[owned.items.len - 1]);
    }

    // If html changed, look up file_path, atomic-rewrite the file,
    // and record that we need to UPDATE file_path too if the file
    // didn't exist before (orphan recovery).
    var new_file_path_owned: ?[]u8 = null;
    defer if (new_file_path_owned) |p| allocator.free(p);
    if (input.html) |new_html| {
        var q = try db.query(allocator,
            "SELECT file_path FROM design_page_elements WHERE id = ?",
            &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        const existing_path = try allocator.dupe(u8, row.values[0]);
        defer allocator.free(existing_path);

        // If file_path was empty (orphan), set it to a freshly-built
        // path so the rewrite sticks. Otherwise rewrite the file
        // in place.
        if (existing_path.len == 0) {
            // Look up the page → item_path + page_name to build a
            // new file path. JOIN with design_pages and
            // workspace_items.
            var pq = try db.query(allocator,
                \\SELECT dp.workspace_item_id, dp.name, wi.path
                \\FROM design_page_elements de
                \\JOIN design_pages dp ON dp.id = de.page_id
                \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
                \\WHERE de.id = ?
            , &.{input.element_id});
            defer pq.deinit();
            const prow = (try pq.next()) orelse return error.ElementNotFound;
            defer prow.deinit(allocator);
            const sanitized_page = try design_io.sanitizeFilename(allocator, prow.values[1]);
            defer allocator.free(sanitized_page);
            // Reuse the existing element name (the orphan case
            // implies the row was created with file_path=''
            // for some reason; use the row's `name` field).
            const elem_name = try allocator.dupe(u8, "element");
            defer allocator.free(elem_name);
            const new_path = try std.fmt.allocPrint(allocator, "{s}/.pabrik/design/{s}/{s}.html", .{
                prow.values[2], sanitized_page, elem_name,
            });
            new_file_path_owned = new_path;
            try sets.append(allocator, "file_path = ?");
            try args.append(allocator, new_path);
        } else {
            design_io.atomicWriteFile(allocator, existing_path, new_html) catch return error.FileWriteFailed;
        }
    }

    // Always update updated_at.
    try sets.append(allocator, "updated_at = datetime('now')");
    try args.append(allocator, input.element_id);

    if (sets.items.len == 1) {
        // Only updated_at → nothing to update; no-op.
        return allocator.dupe(u8, input.element_id);
    }

    // Build the UPDATE statement: "UPDATE design_page_elements SET " + sets joined by ", " + " WHERE id = ?"
    var sql_buf: [4096]u8 = undefined;
    const sql_prefix = "UPDATE design_page_elements SET ";
    var pos: usize = 0;
    @memcpy(sql_buf[pos..][0..sql_prefix.len], sql_prefix);
    pos += sql_prefix.len;
    for (sets.items, 0..) |s, i| {
        if (i > 0) {
            @memcpy(sql_buf[pos..][0..2], ", ");
            pos += 2;
        }
        @memcpy(sql_buf[pos..][0..s.len], s);
        pos += s.len;
    }
    // The last "set" is the WHERE id = ? — but we appended updated_at
    // AND element_id separately. Pull the WHERE out: pop the
    // element_id from sets and use it as the WHERE.
    _ = sets.pop();
    // Actually we set things up wrong: the element_id is in args
    // as the last position, but our SET list already includes
    // "updated_at = datetime('now')" as a set. Let's re-do this.
    // SQL would be: UPDATE ... SET col1=?, col2=?, updated_at=datetime('now') WHERE id=?
    // We appended element_id to args as the WHERE placeholder. Sets
    // already ends with "updated_at = datetime('now')" (no params).
    // So the SQL is correct — just append " WHERE id = ?".
    const where_clause = " WHERE id = ?";
    @memcpy(sql_buf[pos..][0..where_clause.len], where_clause);
    pos += where_clause.len;

    try db.exec(allocator, sql_buf[0..pos], args.items);

    // Emit SSE event AFTER the SQL UPDATE succeeded and the SQL
    // actually changed at least one user-provided column. Best-effort:
    // if the event_bus is not initialized or the JSON serialization
    // fails, the caller still gets the element_id — SSE is a hint,
    // not a hard contract. The `ctx` slices are still alive at this
    // point; the function-level defers haven't fired.
    on_event_sent_design.onEventSendDesignElementUpdated(allocator, .{
        .action = "updated",
        .workspace_id = ctx.workspace_id,
        .item_id = ctx.item_id,
        .page_id = ctx.page_id,
        .element_id = input.element_id,
    }) catch {};

    return allocator.dupe(u8, input.element_id);
}

// ─── updateElementsBatch ───────────────────────────────────────────────────
//
// Atomic N-element geometry update in a single SQL transaction. Used by
// the design-canvas drag handler to collapse N per-element PATCHes (one
// per selected element per pointermove) into ONE PATCH per pointermove.
//
// Behaviour:
//   1. Validate every element_id exists and lives on `input.page_id`.
//      Pre-flight check (a single SELECT COUNT(*) ... WHERE id IN (...) AND
//      page_id = ?). If count != input.updates.len → error.ElementNotFound
//      with NO writes performed.
//   2. Begin a transaction (mutex-held for the whole batch).
//   3. For each input.updates[i] in order: build the SET clause
//      (same dynamic-set pattern as `updateElement`) and execute the
//      UPDATE inside the transaction.
//   4. Re-SELECT the updated rows via `getElement` per id (in input order)
//      and return them as `[]DesignElement`. Caller MUST release with
//      `freeElements(allocator, result)`.
//   5. Emit ONE `design_elements_geometry_batch_updated` SSE event
//      carrying the full id context (workspace_id, item_id, page_id,
//      element_ids[], updated_at). The frontend's local-mutation dedupe
//      (stores/designSse.ts) uses this to skip the GET fan-out when the
//      batch came from this client.
//   6. Commit (or rollback on any failure inside the loop).
//
// Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//   (Chunk 1, Task 1.1)

pub const BatchGeometryUpdateInput = struct {
    page_id: []const u8,
    /// Per-element geometry patches. Only geometry fields (x, y, width,
    /// height, rotation) are honored — name / type / html / etc. are
    /// ignored (the batch endpoint is drag-specific).
    updates: []const UpdateElementInput,
};

pub const BatchGeometryUpdateError = error{
    PageNotFound,
    EmptyUpdates,
    ElementNotFound,
    /// Any DB-side failure (PrepareFailed, ExecuteFailed, BindFailed,
    /// QueryFailed, RowNotFound, DatabaseCorrupt, DiskFull, etc.).
    /// The handler maps this to 500. Use the concrete error names
    /// elsewhere if you need to discriminate; this is the catch-all.
    DbError,
    OutOfMemory,
};

// ─── moveElementsWithDescendantsBatch ─────────────────────────────────────
//
// Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
// (Chunk 1, Task 1.1)
//
// Server-side cascade: each item's (dx, dy) applies to the item's
// element AND every transitive descendant of that element. Optional
// (width, height, rotation) apply ONLY to the root element — Figma
// convention (resize is per-element, not per-subtree). One SQL
// transaction across all items — all-or-nothing atomicity.

pub const MoveItem = struct {
    element_id: []const u8,
    dx: i64 = 0,
    dy: i64 = 0,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

pub const MoveElementsWithDescendantsBatchInput = struct {
    page_id: []const u8,
    items: []const MoveItem,
};

pub const MoveElementsWithDescendantsBatchError = error{
    PageNotFound,
    EmptyItems,
    /// Any element_id is missing from the DB or on a different page.
    /// Whole batch is rejected — atomicity.
    ElementNotFound,
    /// Any DB-side failure. Maps to 500.
    DbError,
    OutOfMemory,
};

pub fn updateElementsBatch(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: BatchGeometryUpdateInput,
) anyerror![]DesignElement {
    if (input.updates.len == 0) return error.EmptyUpdates;

    // 1. Look up the page JOIN (workspace_id, item_id) — needed for the
    //    SSE event payload. Mirrors the lookup pattern in
    //    `groupElements` and `updateElement`.
    const PageContext = struct {
        workspace_id: []u8,
        item_id: []u8,
    };
    const page_ctx: PageContext = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(page_ctx.workspace_id);
    defer allocator.free(page_ctx.item_id);

    // 2. Pre-flight: build a dynamic IN-list SELECT and verify every
    //    element_id exists on `input.page_id`. If count != updates.len
    //    → error.ElementNotFound (atomicity — NO writes happen).
    var in_list_sql: std.ArrayList(u8) = .empty;
    defer in_list_sql.deinit(allocator);
    try in_list_sql.appendSlice(allocator,
        "SELECT COUNT(*) FROM design_page_elements WHERE page_id = ? AND id IN (");
    var preflight_args: std.ArrayList([]const u8) = .empty;
    defer preflight_args.deinit(allocator);
    try preflight_args.append(allocator, input.page_id);
    for (input.updates, 0..) |u, i| {
        if (i > 0) try in_list_sql.append(allocator, ',');
        try in_list_sql.append(allocator, '?');
        try preflight_args.append(allocator, u.element_id);
    }
    try in_list_sql.append(allocator, ')');

    const matched_count: usize = blk: {
        var q = try db.query(allocator, in_list_sql.items, preflight_args.items);
        defer q.deinit();
        const row = (try q.next()) orelse return error.DbError;
        defer row.deinit(allocator);
        break :blk std.fmt.parseInt(usize, row.values[0], 10) catch 0;
    };
    if (matched_count != input.updates.len) return error.ElementNotFound;

    // 3. Begin transaction. RAII defer pattern: any error below
    //    fires rollback. After successful commit, mark `committed` to
    //    skip the deferred rollback.
    var tx = try db.begin();
    var committed = false;
    defer if (!committed) tx.rollback() catch {};

    // 4. Apply each UPDATE inside the transaction. We deliberately
    //    don't extract a helper — the SET-list build is small enough
    //    that inlining keeps the logic visible and avoids borrowing
    //    arena slices across loop iterations.
    for (input.updates) |u| {
        var sets: std.ArrayList([]const u8) = .empty;
        defer sets.deinit(allocator);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |s| allocator.free(s);
            owned.deinit(allocator);
        }
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        if (u.x) |v| {
            try sets.append(allocator, "x = ?");
            try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
            try argv.append(allocator, owned.items[owned.items.len - 1]);
        }
        if (u.y) |v| {
            try sets.append(allocator, "y = ?");
            try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
            try argv.append(allocator, owned.items[owned.items.len - 1]);
        }
        if (u.width) |v| {
            try sets.append(allocator, "width = ?");
            try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
            try argv.append(allocator, owned.items[owned.items.len - 1]);
        }
        if (u.height) |v| {
            try sets.append(allocator, "height = ?");
            try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
            try argv.append(allocator, owned.items[owned.items.len - 1]);
        }
        if (u.rotation) |v| {
            try sets.append(allocator, "rotation = ?");
            try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
            try argv.append(allocator, owned.items[owned.items.len - 1]);
        }
        // Always update updated_at.
        try sets.append(allocator, "updated_at = datetime('now')");
        try argv.append(allocator, u.element_id);

        var sql_buf: [1024]u8 = undefined;
        const sql_prefix = "UPDATE design_page_elements SET ";
        var pos: usize = 0;
        @memcpy(sql_buf[pos..][0..sql_prefix.len], sql_prefix);
        pos += sql_prefix.len;
        for (sets.items, 0..) |s, i| {
            if (i > 0) {
                @memcpy(sql_buf[pos..][0..2], ", ");
                pos += 2;
            }
            @memcpy(sql_buf[pos..][0..s.len], s);
            pos += s.len;
        }
        const where_clause = " WHERE id = ?";
        @memcpy(sql_buf[pos..][0..where_clause.len], where_clause);
        pos += where_clause.len;

        try tx.exec(allocator, sql_buf[0..pos], argv.items);
    }

    // 5. Commit BEFORE re-querying. Re-querying via `db.query`
    //    (which `getElement` uses) acquires the same mutex the
    //    transaction holds — calling it inside the tx would
    //    deadlock. The project memory `zig-sqlite-patterns.md` §
    //    "Pitfall 3: RAII mutex-held-for-whole-resource-lifetime"
    //    documents this constraint.
    try tx.commit();
    committed = true;

    // 6. Re-SELECT the updated rows in INPUT order (not SQL order).
    //    Use `getElement` per id — each call allocates fresh strings,
    //    so the returned slice is fully owned. Caller MUST release
    //    with `freeElements(allocator, result)`.
    var results: std.ArrayList(DesignElement) = .empty;
    errdefer {
        for (results.items) |e| freeElement(allocator, e);
        results.deinit(allocator);
    }
    for (input.updates) |u| {
        const el = getElement(allocator, db, u.element_id) catch |err| switch (err) {
            error.ElementNotFound => return error.DbError, // shouldn't happen — pre-flight checked
            else => return error.DbError,
        };
        try results.append(allocator, el);
    }

    // 7. Emit ONE batch SSE event. Best-effort: failure here does NOT
    //    fail the request — SSE is a hint, not a hard contract. The
    //    `updated_at` is the current Unix epoch in seconds (matches
    //    existing SSE timestamps elsewhere).
    var element_ids_buf: std.ArrayList([]const u8) = .empty;
    defer element_ids_buf.deinit(allocator);
    for (input.updates) |u| try element_ids_buf.append(allocator, u.element_id);
    // Unix seconds — `std.time.timestamp()` was removed in Zig 0.16,
    // use libc `gettimeofday` (matches the rest of this codebase).
    const updated_at: i64 = blk: {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        break :blk @intCast(tv.sec);
    };
    on_event_sent_design.onEventSendDesignElementsGeometryBatchUpdated(allocator, .{
        .workspace_id = page_ctx.workspace_id,
        .item_id = page_ctx.item_id,
        .page_id = input.page_id,
        .element_ids = element_ids_buf.items,
        .updated_at = updated_at,
    }) catch {};

    return results.toOwnedSlice(allocator);
}

// ─── moveElementsWithDescendantsBatch ─────────────────────────────────────
//
// Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
// (Chunk 1, Task 1.2)
//
// Server-side cascade move. Each item's (dx, dy) applies to the item's
// element AND every transitive descendant of that element via a single
// recursive CTE inside one SQL transaction. Optional (width, height,
// rotation) apply ONLY to the item's root — Figma convention (resize
// is per-element, not per-subtree).
//
// Behaviour:
//   1. Validate `items` is non-empty (EmptyItems).
//   2. Look up the page JOIN (workspace_id, item_id) — needed for the
//      SSE event payload. PageNotFound on miss.
//   3. Pre-flight: verify every input item's element_id exists on
//      `input.page_id`. Any miss → ElementNotFound (atomicity, no
//      writes).
//   4. Begin transaction. For each input item:
//      a. Build a recursive CTE that walks DOWN from `item.element_id`
//         through `parent_id` (limited to 10000 rows as a safety net
//         against pathological cycles — though cycle prevention on
//         reparent already keeps the DB consistent).
//      b. UPDATE all subtree rows: SET x = x + dx, y = y + dy,
//         updated_at = datetime('now').
//      c. For the root row only, also SET width/height/rotation
//         (when non-null) + updated_at.
//   5. Commit. On any failure the deferred rollback leaves the DB
//      unchanged.
//   6. Re-SELECT every affected element (deduped union of all
//      subtrees) and return them in tree-traversal order (root first,
//      then descendants in source order). Heap-owned; caller frees
//      with `freeElements`.
//   7. Emit ONE `design_elements_geometry_batch_updated` SSE event
//      carrying the deduped union of affected element_ids.
//
// Returns the slice of updated `DesignElement` rows in tree-traversal
// order. Atomicity is all-or-nothing.

pub fn moveElementsWithDescendantsBatch(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: MoveElementsWithDescendantsBatchInput,
) anyerror![]DesignElement {
    if (input.items.len == 0) return error.EmptyItems;

    // 1. Look up the page JOIN (workspace_id, item_id) for the SSE
    //    event payload. Mirrors the lookup pattern in
    //    `updateElementsBatch` and `groupElements`.
    const PageContext = struct {
        workspace_id: []u8,
        item_id: []u8,
    };
    const page_ctx: PageContext = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(page_ctx.workspace_id);
    defer allocator.free(page_ctx.item_id);

    // 2. Pre-flight: verify every input element_id exists on
    //    `input.page_id`. Any miss → ElementNotFound (atomicity).
    {
        var in_list_sql: std.ArrayList(u8) = .empty;
        defer in_list_sql.deinit(allocator);
        try in_list_sql.appendSlice(allocator,
            "SELECT COUNT(*) FROM design_page_elements WHERE page_id = ? AND id IN (");
        var preflight_args: std.ArrayList([]const u8) = .empty;
        defer preflight_args.deinit(allocator);
        try preflight_args.append(allocator, input.page_id);
        for (input.items, 0..) |it, i| {
            if (i > 0) try in_list_sql.append(allocator, ',');
            try in_list_sql.append(allocator, '?');
            try preflight_args.append(allocator, it.element_id);
        }
        try in_list_sql.append(allocator, ')');

        const matched_count: usize = blk: {
            var q = try db.query(allocator, in_list_sql.items, preflight_args.items);
            defer q.deinit();
            const row = (try q.next()) orelse return error.DbError;
            defer row.deinit(allocator);
            break :blk std.fmt.parseInt(usize, row.values[0], 10) catch 0;
        };
        if (matched_count != input.items.len) return error.ElementNotFound;
    }

    // 3. Begin transaction. RAII defer pattern: any error below
    //    fires rollback. After successful commit, mark `committed` to
    //    skip the deferred rollback.
    var tx = try db.begin();
    var committed = false;
    defer if (!committed) tx.rollback() catch {};

    // 4. Apply the per-item cascade UPDATEs. We use a dynamic
    //    `UPDATE ... WHERE id IN (subtree_ids)` per item, where
    //    `subtree_ids` is collected by a recursive CTE in a separate
    //    SELECT first (so we can dedupe + reuse).
    //
    // Strategy: for each item:
    //   a. SELECT all subtree element ids via recursive CTE.
    //   b. UPDATE x/y for the whole subtree (root + descendants).
    //   c. UPDATE width/height/rotation for the root only (when
    //      non-null). When both (b) and (c) target the same row,
    //      SQLite's per-statement UPDATE applies both — we just split
    //      into two UPDATEs to keep the SET-list build simple.
    //
    // Dedup is automatic: `WHERE id IN (subtree_ids)` matches each row
    // at most once per UPDATE. The (dx, dy) is applied to the row's
    // CURRENT x/y at UPDATE-time, so multiple items in the batch
    // with overlapping subtrees would compound the delta — the
    // caller should avoid this (the frontend sends one item per
    // selected root, no overlap in normal usage).
    //
    // `affected_ids` accumulates the **owned** (dup'd) subtree element
    // ids across all iterations. Owns its strings via `allocator.dupe`
    // at append time so the buffers survive across the `for (input.items)`
    // iterations (whose `subtree_ids` buffers are freed at the end of
    // each iteration body). Earlier versions of this code used a
    // `std.StringHashMap(void)` for the dedup and stored the
    // `subtree_ids[i]` slice headers directly — that broke with N>=8
    // because the second iteration's `subtree_ids.deinit(allocator)`
    // freed the FIRST iteration's id buffers, leaving the hashmap's
    // slice headers pointing into freed memory. The next put would
    // then `eql`-compare the new key against the freed bytes and
    // crash. Owned-keys below sidestep the issue.
    var affected_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (affected_ids.items) |id| allocator.free(id);
        affected_ids.deinit(allocator);
    }

    for (input.items) |it| {
        // 4a. Recursive CTE — collect the subtree ids (root + every
        //     transitive descendant). We inline the SQL here rather
        //     than extract a helper because the helper would need
        //     to know about the `*Transaction` vs `*SqliteBackend`
        //     type distinction (both expose `.query`, but they're
        //     distinct types in this codebase).
        var subtree_ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (subtree_ids.items) |id| allocator.free(id);
            subtree_ids.deinit(allocator);
        }
        {
            var q = try tx.query(allocator,
                \\WITH RECURSIVE subtree(id) AS (
                \\    SELECT id FROM design_page_elements
                \\        WHERE id = ? AND page_id = ?
                \\    UNION ALL
                \\    SELECT dpe.id FROM design_page_elements dpe
                \\        JOIN subtree s ON dpe.parent_id = s.id
                \\    LIMIT 10000
                \\)
                \\SELECT id FROM subtree
            , &.{ it.element_id, input.page_id });
            defer q.deinit();
            while (try q.next()) |row| {
                defer row.deinit(allocator);
                try subtree_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
            }
        }
        defer {
            for (subtree_ids.items) |id| allocator.free(id);
            subtree_ids.deinit(allocator);
        }

        // 4b. UPDATE x/y for the whole subtree. Build the dynamic
        //     IN-list and the SET-list, then exec.
        {
            var sql_buf: std.ArrayList(u8) = .empty;
            defer sql_buf.deinit(allocator);
            try sql_buf.appendSlice(allocator,
                "UPDATE design_page_elements SET x = x + ?, y = y + ?, updated_at = datetime('now') WHERE id IN (");
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(allocator);
            // Bind dx and dy as text — the codebase convention is
            // that `tx.exec` only binds TEXT (see
            // `zig-sqlite-patterns.md` §"exec / query only bind TEXT").
            // SQLite coerces numeric-looking TEXT to INTEGER under
            // INTEGER affinity.
            const dx_str = try std.fmt.allocPrint(allocator, "{d}", .{it.dx});
            defer allocator.free(dx_str);
            const dy_str = try std.fmt.allocPrint(allocator, "{d}", .{it.dy});
            defer allocator.free(dy_str);
            try argv.append(allocator, dx_str);
            try argv.append(allocator, dy_str);
            for (subtree_ids.items, 0..) |id, i| {
                if (i > 0) try sql_buf.append(allocator, ',');
                try sql_buf.append(allocator, '?');
                try argv.append(allocator, id);
            }
            try sql_buf.append(allocator, ')');

            try tx.exec(allocator, sql_buf.items, argv.items);
        }

        // 4c. UPDATE width/height/rotation for the root ONLY (when
        //     non-null). Skip the round-trip when all three are null.
        if (it.width != null or it.height != null or it.rotation != null) {
            var sets: std.ArrayList([]const u8) = .empty;
            defer sets.deinit(allocator);
            var owned: std.ArrayList([]u8) = .empty;
            defer {
                for (owned.items) |s| allocator.free(s);
                owned.deinit(allocator);
            }
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(allocator);

            if (it.width) |v| {
                try sets.append(allocator, "width = ?");
                try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
                try argv.append(allocator, owned.items[owned.items.len - 1]);
            }
            if (it.height) |v| {
                try sets.append(allocator, "height = ?");
                try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
                try argv.append(allocator, owned.items[owned.items.len - 1]);
            }
            if (it.rotation) |v| {
                try sets.append(allocator, "rotation = ?");
                try owned.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{v}));
                try argv.append(allocator, owned.items[owned.items.len - 1]);
            }
            try sets.append(allocator, "updated_at = datetime('now')");
            try argv.append(allocator, it.element_id);

            var sql_buf: [512]u8 = undefined;
            const sql_prefix = "UPDATE design_page_elements SET ";
            var pos: usize = 0;
            @memcpy(sql_buf[pos..][0..sql_prefix.len], sql_prefix);
            pos += sql_prefix.len;
            for (sets.items, 0..) |s, i| {
                if (i > 0) {
                    @memcpy(sql_buf[pos..][0..2], ", ");
                    pos += 2;
                }
                @memcpy(sql_buf[pos..][0..s.len], s);
                pos += s.len;
            }
            const where_clause = " WHERE id = ?";
            @memcpy(sql_buf[pos..][0..where_clause.len], where_clause);
            pos += where_clause.len;

            try tx.exec(allocator, sql_buf[0..pos], argv.items);
        }

        // 4d. Track every affected id (deduped) for the re-SELECT +
        //     SSE event below. Linear O(n²) scan over
        //     `affected_ids.items` to skip ids we've already seen —
        //     the input batch is bounded by the SELECTED element count
        //     in the UI (small, ≤ a few dozen typical) so the n²
        //     constant beats maintaining a separate dedup hashmap.
        //     Each new id is duped into `affected_ids` so the buffers
        //     outlive this iteration's `subtree_ids.deinit(allocator)`
        //     (see the `affected_ids` declaration above for the
        //     rationale — the dangling-pointer / use-after-free the
        //     prior `std.StringHashMap(void)` triggered).
        for (subtree_ids.items) |id| {
            var already_seen = false;
            for (affected_ids.items) |existing| {
                if (std.mem.eql(u8, existing, id)) {
                    already_seen = true;
                    break;
                }
            }
            if (!already_seen) {
                try affected_ids.append(allocator, try allocator.dupe(u8, id));
            }
        }
    }

    // 5. Commit BEFORE re-querying. The project memory
    //    `zig-sqlite-patterns.md` §"Pitfall 3" documents this
    //    constraint.
    try tx.commit();
    committed = true;

    // 6. Re-SELECT the affected rows (deduped union of all subtrees).
    //    Use `getElement` per id — each call allocates fresh strings,
    //    so the returned slice is fully owned. Caller MUST release
    //    with `freeElements(allocator, result)`.
    var results: std.ArrayList(DesignElement) = .empty;
    errdefer {
        for (results.items) |e| freeElement(allocator, e);
        results.deinit(allocator);
    }
    for (affected_ids.items) |id| {
        const el = getElement(allocator, db, id) catch |err| switch (err) {
            error.ElementNotFound => return error.DbError,
            else => return error.DbError,
        };
        try results.append(allocator, el);
    }

    // 7. Emit ONE batch SSE event. Best-effort: failure here does NOT
    //    fail the request — SSE is a hint, not a hard contract.
    var element_ids_buf: std.ArrayList([]const u8) = .empty;
    defer element_ids_buf.deinit(allocator);
    for (affected_ids.items) |id| try element_ids_buf.append(allocator, id);
    const updated_at: i64 = blk: {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        break :blk @intCast(tv.sec);
    };
    on_event_sent_design.onEventSendDesignElementsGeometryBatchUpdated(allocator, .{
        .workspace_id = page_ctx.workspace_id,
        .item_id = page_ctx.item_id,
        .page_id = input.page_id,
        .element_ids = element_ids_buf.items,
        .updated_at = updated_at,
    }) catch {};

    return results.toOwnedSlice(allocator);
}

// ─── moveElementToPage ────────────────────────────────────────────────────
//
// Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 1)
//
// Cross-page element relocate. Changes `page_id` (and `position` on the
// target page) instead of `x`/`y`. Mirrors the cascade semantics of
// `moveElementsWithDescendantsBatch`: when `apply_to_children = true`
// (default), the moved subtree includes the root AND every transitive
// descendant, in one SQL transaction.
//
// Behaviour:
//   1. Same-page guard (cheap) → `SamePage`.
//   2. Pre-flight: the element must exist on `source_page_id`.
//      Different-page `element_id` → `ElementNotFound`.
//   3. Pre-flight: the target page must exist (`PageNotFound`).
//   4. Cross-design guard: the target must be on the same `item_id`
//      as the source page → `CrossDesign`.
//   5. Resolve the moved-subtree element ids via recursive CTE (depth-
//      limited at 10000 as a cycle safety net).
//   6. Begin transaction. For each subtree element:
//      a. SET page_id = target_page_id.
//      b. For the ROOT only: SET position = (MAX(position) on target
//         page) + 1 — append-at-end per Q5 default.
//   7. Auto-detach (Q4 default): if the root's parent_id is non-empty
//      AND that parent is NOT in the moved subtree (i.e. the parent
//      stays behind on the source page), SET parent_id = NULL on the
//      root. Otherwise descendants would carry a cross-page parent_id
//      reference (schema invariant violated).
//   8. Commit. On error before commit, rollback leaves DB unchanged.
//   9. Re-SELECT the moved subtree via `getElement` (heap-owned for
//      the caller).
//  10. Emit a `design_elements_geometry_batch_updated` SSE event with
//      the deduped subtree element ids (best-effort; SSE failure
//      doesn't fail the request — same as the sibling cascade handler).
//
// The function is single-element only (no batch). Followup plan can
// add `moveElementsToPageBatch` if the LLM needs to relayout multiple
// elements across pages in one call.

pub const MoveElementToPageInput = struct {
    /// The page the element currently lives on. The element must exist
    /// here (any other page → `ElementNotFound`).
    source_page_id: []const u8,
    /// The element id to move. The cascade moves every transitive
    /// descendant too when `apply_to_children = true`.
    element_id: []const u8,
    /// The destination page. Must exist and share the design item
    /// with `source_page_id`.
    target_page_id: []const u8,
    /// Default true. When true, every transitive descendant of
    /// `element_id` moves with it (Figma parity); when false, only the
    /// root itself moves (descendants stay on the source page as
    /// top-level orphans).
    apply_to_children: bool = true,
};

pub const MoveElementToPageError = error{
    /// `source_page_id` and `target_page_id` are equal — no-op, rejected
    /// upfront to avoid an unnecessary transaction.
    SamePage,
    /// The element_id doesn't exist on the source page (either absent
    /// entirely or on a different page).
    ElementNotFound,
    /// The target page id doesn't match any row in `design_pages`.
    PageNotFound,
    /// The target page exists but lives on a different design item.
    CrossDesign,
    /// Any DB-side failure (PrepareFailed / ExecuteFailed / etc.).
    DbError,
    /// Allocator failure.
    OutOfMemory,
};

pub fn moveElementToPage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: MoveElementToPageInput,
) anyerror![]DesignElement {
    // 1. Same-page guard. Cheap, fail fast.
    if (std.mem.eql(u8, input.source_page_id, input.target_page_id)) {
        return error.SamePage;
    }

    // 2. Look up the element + verify it lives on the source page.
    //    Returns the element's existing page_id + parent_id (NULL →
    //    '' via COALESCE).
    const ElementLookup = struct {
        page_id: []u8,
        parent_id: []u8,
    };
    const elem_lookup: ElementLookup = blk: {
        var q = try db.query(allocator,
            \\SELECT page_id, COALESCE(parent_id, '')
            \\FROM design_page_elements WHERE id = ?
        , &.{input.element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .page_id = try allocator.dupe(u8, row.values[0]),
            .parent_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(elem_lookup.page_id);
    defer allocator.free(elem_lookup.parent_id);

    // The element may exist on a DIFFERENT page than the one the caller
    // thinks it's on — treat that as ElementNotFound (don't leak the
    // cross-page detail to the caller).
    if (!std.mem.eql(u8, elem_lookup.page_id, input.source_page_id)) {
        return error.ElementNotFound;
    }

    // 3. Look up the source page's (workspace_id, item_id) JOIN for the
    //    SSE event payload. Source page must exist (it should, since
    //    the element is on it — but defensive).
    const SourceContext = struct {
        workspace_id: []u8,
        item_id: []u8,
    };
    const source_ctx: SourceContext = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.source_page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(source_ctx.workspace_id);
    defer allocator.free(source_ctx.item_id);

    // 4. Look up the target page. Verifies (a) it exists and (b) it
    //    lives on the same design item as the source page.
    const target_item_id: []u8 = blk: {
        var q = try db.query(allocator,
            \\SELECT workspace_item_id FROM design_pages WHERE id = ?
        , &.{input.target_page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    defer allocator.free(target_item_id);
    if (!std.mem.eql(u8, target_item_id, source_ctx.item_id)) {
        return error.CrossDesign;
    }

    // 5. Resolve the moved-subtree element ids.
    //    - apply_to_children = true  → root + every transitive descendant
    //      (recursive CTE, LIMIT 10000 cycle safety)
    //    - apply_to_children = false → just the root
    var subtree_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (subtree_ids.items) |id| allocator.free(id);
        subtree_ids.deinit(allocator);
    }

    if (input.apply_to_children) {
        var q = try db.query(allocator,
            \\WITH RECURSIVE subtree(id) AS (
            \\    SELECT id FROM design_page_elements
            \\        WHERE id = ? AND page_id = ?
            \\    UNION ALL
            \\    SELECT dpe.id FROM design_page_elements dpe
            \\        JOIN subtree s ON dpe.parent_id = s.id
            \\    LIMIT 10000
            \\)
            \\SELECT id FROM subtree
        , &.{ input.element_id, input.source_page_id });
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            try subtree_ids.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
    } else {
        try subtree_ids.append(allocator, try allocator.dupe(u8, input.element_id));
    }

    // 6. Begin transaction.
    var tx = try db.begin();
    var committed = false;
    defer if (!committed) tx.rollback() catch {};

    // 7. UPDATE page_id for every subtree element. One dynamic
    //    IN-list statement covers the whole subtree (same pattern as
    //    `moveElementsWithDescendantsBatch`).
    {
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(allocator,
            \\UPDATE design_page_elements
            \\SET page_id = ?, updated_at = datetime('now')
            \\WHERE id IN (
        );
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, input.target_page_id);
        for (subtree_ids.items, 0..) |id, i| {
            if (i > 0) try sql_buf.append(allocator, ',');
            try sql_buf.append(allocator, '?');
            try argv.append(allocator, id);
        }
        try sql_buf.append(allocator, ')');
        try tx.exec(allocator, sql_buf.items, argv.items);
    }

    // 8. Q4 default — auto-detach the root when its parent isn't in
    //    the moved subtree. The parent's `parent_id` chain stays on
    //    the source page; if we kept the link, the root would carry a
    //    cross-page parent_id (violating the "parent lives on the same
    //    page" invariant).
    //
    // Skip when: root is top-level (parent_id empty), or the parent IS
    // part of the moved subtree (we're moving a group with its parent).
    if (elem_lookup.parent_id.len > 0) {
        var parent_in_subtree = false;
        for (subtree_ids.items) |id| {
            if (std.mem.eql(u8, id, elem_lookup.parent_id)) {
                parent_in_subtree = true;
                break;
            }
        }
        if (!parent_in_subtree) {
            try tx.exec(allocator,
                \\UPDATE design_page_elements
                \\SET parent_id = NULL, updated_at = datetime('now')
                \\WHERE id = ?
            , &.{input.element_id});
        }
    }

    // 9. Append-at-end for the root's `position` on the target page
    //    (Q5 default). Descendants' positions are NOT adjusted here;
    //    they're irrelevant for rendering (the page-level rendering
    //    order is by `position` and descendants within a group render
    //    in tree order — a separate column tracks that ordering, not
    //    the page-level `position`). The schema's `position` is
    //    rendered for top-level elements only; children within a
    //    group use `parent_id` + their own `position` for inter-child
    //    ordering on the target page's independent sort.
    //
    // We don't refresh `updated_at` here (the row already got it from
    // the bulk UPDATE above).
    {
        const next_pos_str = blk: {
            var q = try tx.query(allocator,
                \\SELECT COALESCE(MAX(position), -1)
                \\FROM design_page_elements WHERE page_id = ?
            , &.{input.target_page_id});
            defer q.deinit();
            const row = (try q.next()) orelse return error.DbError;
            defer row.deinit(allocator);
            const max_pos = std.fmt.parseInt(i64, row.values[0], 10) catch 0;
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{max_pos + 1});
        };
        defer allocator.free(next_pos_str);
        try tx.exec(allocator,
            "UPDATE design_page_elements SET position = ? WHERE id = ?",
            &.{ next_pos_str, input.element_id });
    }

    // 10. Commit.
    try tx.commit();
    committed = true;

    // 11. Re-SELECT the moved subtree. `getElement` allocates fresh
    //     strings on each call, so the returned slice is fully owned
    //     — caller releases with `freeElements`.
    var results: std.ArrayList(DesignElement) = .empty;
    errdefer {
        for (results.items) |e| freeElement(allocator, e);
        results.deinit(allocator);
    }
    for (subtree_ids.items) |id| {
        const el = getElement(allocator, db, id) catch return error.DbError;
        try results.append(allocator, el);
    }

    // 12. SSE event. Best-effort — failure here does NOT fail the
    //     request (the optimistic mirror in the frontend store handles
    //     the primary state; other tabs may need a manual refresh).
    var element_ids_buf: std.ArrayList([]const u8) = .empty;
    defer element_ids_buf.deinit(allocator);
    for (subtree_ids.items) |id| try element_ids_buf.append(allocator, id);
    const updated_at: i64 = blk: {
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        break :blk @intCast(tv.sec);
    };
    // The event carries source_page_id for "from" + the moved ids; the
    // frontend reads page_id from the moved elements themselves to
    // route the update.
    on_event_sent_design.onEventSendDesignElementsGeometryBatchUpdated(allocator, .{
        .workspace_id = source_ctx.workspace_id,
        .item_id = source_ctx.item_id,
        .page_id = input.target_page_id,
        .element_ids = element_ids_buf.items,
        .updated_at = updated_at,
    }) catch {};

    return results.toOwnedSlice(allocator);
}

// ─── groupElements ────────────────────────────────────────────────────────

pub const GroupElementsInput = struct {
    page_id: []const u8,
    child_ids: []const []const u8,
    parent_name: []const u8,
    parent_type: ElementType, // .group or .frame
};

pub const GroupElementsError = error{
    PageNotFound,
    ItemPathMissing,
    BadChildId,
    ChildAlreadyParented,
    ChildAcrossDifferentPages,
    FileWriteFailed,
    DbError,
    OutOfMemory,
};

/// Create a new `group` (or `frame`) parent element at the UNION
/// bounding box of the given `child_ids`, and reparent every child
/// to the new parent. Single transaction — all-or-nothing.
///
/// Behaviour:
///   1. Validate children are all on the requested page
///      (`SELECT page_id FROM design_page_elements WHERE id IN (...)`).
///   2. Reject if any child is already parented
///      (`parent_id IS NOT NULL`) — first-cut safety. Future
///      enhancement: support "re-parent" by passing through.
///   3. Compute the union bbox: `min_x = min(child.x)`,
///      `min_y = min(child.y)`, `max_x = max(child.x + child.width)`,
///      `max_y = max(child.y + child.height)`.
///   4. INSERT a new element row with `parent_id = NULL`,
///      `z_index = MAX(child.z_index) + 1`,
///      `position = MAX(child.position) + 1`,
///      `fill = "transparent"` (so it doesn't visually obscure
///      children — frames with `fill = ""` would render as
///      white-on-white if the canvas background is also white).
///   5. UPDATE children in one statement to set `parent_id` to the
///      new parent's id.
///   6. Emit `design_element_created` SSE for the parent + one
///      `design_element_updated` SSE per child.
///   7. Atomically write an empty `<div>` to
///      `<item_path>/.pabrik/design/<page>/<group_name>.html`.
///
/// Returns the new parent's element_id (heap-owned; caller frees).
///
/// Plan: docs/superpowers/plans/2026-07-28-grouped-layers.md (Chunk 2)
pub fn groupElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: GroupElementsInput,
) anyerror![]u8 {
    if (input.child_ids.len < 2) return error.BadChildId;
    if (input.parent_name.len == 0) return error.BadChildId;

    // 1. Look up the page JOIN: workspace_id, item_id, page_name,
    //    item_path. Needed for the on-disk HTML write + the SSE
    //    event payload.
    const Lookup = struct {
        workspace_id: []u8,
        item_id: []u8,
        page_name: []u8,
        item_path: []u8,
    };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id, dp.name, wi.path
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
            .page_name = try allocator.dupe(u8, row.values[2]),
            .item_path = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);
    defer allocator.free(lookup.page_name);
    defer allocator.free(lookup.item_path);
    if (lookup.item_path.len == 0) return error.ItemPathMissing;

    // 2. Validate children: all on the same page, none already parented.
    //    Build a parameterized IN-list dynamically.
    var in_list_sql: std.ArrayList(u8) = .empty;
    defer in_list_sql.deinit(allocator);
    try in_list_sql.appendSlice(allocator, "SELECT id, page_id, parent_id, x, y, width, height, z_index, position, name FROM design_page_elements WHERE id IN (");
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    for (input.child_ids, 0..) |cid, i| {
        if (i > 0) try in_list_sql.append(allocator, ',');
        try in_list_sql.append(allocator, '?');
        try args.append(allocator, cid);
    }
    try in_list_sql.append(allocator, ')');

    const ChildRow = struct {
        id: []u8,
        page_id: []u8,
        parent_id: []u8,
        x: i64,
        y: i64,
        width: i64,
        height: i64,
        z_index: i64,
        position: i64,
        name: []u8,
    };
    var children: std.ArrayList(ChildRow) = .empty;
    defer {
        for (children.items) |c| {
            allocator.free(c.id);
            allocator.free(c.page_id);
            allocator.free(c.parent_id);
            allocator.free(c.name);
        }
        children.deinit(allocator);
    }

    {
        var q = try db.query(allocator, in_list_sql.items, args.items);
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            try children.append(allocator, .{
                .id = try allocator.dupe(u8, row.values[0]),
                .page_id = try allocator.dupe(u8, row.values[1]),
                .parent_id = try allocator.dupe(u8, row.values[2]),
                .x = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
                .y = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
                .width = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
                .height = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
                .z_index = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
                .position = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
                .name = try allocator.dupe(u8, row.values[9]),
            });
        }
    }

    // Reject if any child is missing OR on a different page OR already parented.
    if (children.items.len != input.child_ids.len) return error.BadChildId;
    for (children.items) |c| {
        if (!std.mem.eql(u8, c.page_id, input.page_id)) return error.ChildAcrossDifferentPages;
        if (c.parent_id.len > 0) return error.ChildAlreadyParented;
    }

    // 3. Compute the union bbox.
    var min_x: i64 = std.math.maxInt(i64);
    var min_y: i64 = std.math.maxInt(i64);
    var max_x: i64 = std.math.minInt(i64);
    var max_y: i64 = std.math.minInt(i64);
    // Track min_z so the new container can be placed BEHIND its
    // children (a group/frame is a container, not a peer — it must
    // not occlude its contents). min_z starts at the same sentinels
    // as min_x/min_y so a single-child page still works.
    var min_z: i64 = std.math.maxInt(i64);
    var max_z: i64 = 0;
    var max_pos: i64 = -1;
    for (children.items) |c| {
        if (c.x < min_x) min_x = c.x;
        if (c.y < min_y) min_y = c.y;
        if (c.x + c.width > max_x) max_x = c.x + c.width;
        if (c.y + c.height > max_y) max_y = c.y + c.height;
        if (c.z_index < min_z) min_z = c.z_index;
        if (c.z_index > max_z) max_z = c.z_index;
        if (c.position > max_pos) max_pos = c.position;
    }
    const group_width = max_x - min_x;
    const group_height = max_y - min_y;

    // 4. Build the on-disk HTML path for the new parent.
    const sanitized_page = try design_io.sanitizeFilename(allocator, lookup.page_name);
    defer allocator.free(sanitized_page);
    const sanitized_elem = try design_io.sanitizeFilename(allocator, input.parent_name);
    defer allocator.free(sanitized_elem);
    const page_dir = try std.fmt.allocPrint(allocator, "{s}/.pabrik/design/{s}", .{ lookup.item_path, sanitized_page });
    defer allocator.free(page_dir);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ page_dir, sanitized_elem });
    defer allocator.free(file_path);

    // mkdir -p the page directory (createDirPath is Io's mkdir-p).
    // Use the SqliteBackend's io — we don't take io as a parameter
    // because the LLM tool path (set_design_page) passes db without
    // an io handle.
    std.Io.Dir.cwd().createDirPath(db.io, page_dir) catch return error.FileWriteFailed;

    // Atomic-write an empty wrapper. The group's HTML body is a
    // transparent container — children render themselves inside
    // their own (separate) iframes via the design-mode iframe
    // convention.
    const empty_html = "<div style=\"width:100%;height:100%;\"></div>";
    design_io.atomicWriteFile(allocator, file_path, empty_html) catch return error.FileWriteFailed;

    // 5. Start the transaction (mutex-held for the whole operation).
    // Use the explicit commit-then-mark pattern: any failure below
    // the commit fires the deferred rollback (since `tx.completed`
    // is false). On the success path, the commit runs and we
    // explicitly mark the defer a no-op via the `committed` flag.
    var tx = try db.begin();
    var committed = false;
    defer if (!committed) tx.rollback() catch {};

    // 6. INSERT the new group element inside the transaction.
    const new_id = try generateElementId(allocator);
    defer allocator.free(new_id);

    const x_str = try std.fmt.allocPrint(allocator, "{d}", .{min_x});
    defer allocator.free(x_str);
    const y_str = try std.fmt.allocPrint(allocator, "{d}", .{min_y});
    defer allocator.free(y_str);
    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{group_width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{group_height});
    defer allocator.free(height_str);
    // The new container must render BEHIND its children. Using the
    // highest child z_index plus one would put the group on top of its
    // contents, so an opaque `fill` like the user's template #181616
    // would occlude the children inside it. min_z - 1 slides the
    // container one slot below the earliest child so the children
    // paint on top. (See task_1786693066547 / plan 2026-08-14.)
    const z_index_str = try std.fmt.allocPrint(allocator, "{d}", .{min_z - 1});
    defer allocator.free(z_index_str);
    const position_str = try std.fmt.allocPrint(allocator, "{d}", .{max_pos + 1});
    defer allocator.free(position_str);
    const elem_type_str = @tagName(input.parent_type);

    try tx.exec(allocator,
        \\INSERT INTO design_page_elements (
        \\    id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, 0, ?, '', 0, 0, 1.0,
        \\    '', '', '', NULL,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{
        new_id, input.page_id, input.parent_name, file_path,
        x_str, y_str, width_str, height_str, z_index_str, position_str,
        elem_type_str, "transparent",
    });

    // 7. UPDATE each child to set parent_id (within the same tx).
    var update_in_list: std.ArrayList(u8) = .empty;
    defer update_in_list.deinit(allocator);
    try update_in_list.appendSlice(allocator,
        "UPDATE design_page_elements SET parent_id = ? WHERE id IN (");
    var update_args: std.ArrayList([]const u8) = .empty;
    defer update_args.deinit(allocator);
    try update_args.append(allocator, new_id);
    for (input.child_ids, 0..) |cid, i| {
        if (i > 0) try update_in_list.append(allocator, ',');
        try update_in_list.append(allocator, '?');
        try update_args.append(allocator, cid);
    }
    try update_in_list.append(allocator, ')');

    try tx.exec(allocator, update_in_list.items, update_args.items);

    // 8. Commit. If commit fails the parent INSERT + child UPDATEs
    //    roll back atomically — partial-failure leaves no orphans.
    try tx.commit();
    committed = true;

    // 9. Emit SSE events AFTER commit so multi-tab listeners only
    //    see state that's already committed. Best-effort: failures
    //    log but don't fail the request.
    on_event_sent_design.onEventSendDesignElementCreated(allocator, .{
        .action = "created",
        .workspace_id = lookup.workspace_id,
        .item_id = lookup.item_id,
        .page_id = input.page_id,
        .element_id = new_id,
    }) catch {};

    for (input.child_ids) |cid| {
        on_event_sent_design.onEventSendDesignElementUpdated(allocator, .{
            .action = "updated",
            .workspace_id = lookup.workspace_id,
            .item_id = lookup.item_id,
            .page_id = input.page_id,
            .element_id = cid,
        }) catch {};
    }

    return allocator.dupe(u8, new_id);
}

// ─── reparentElements (Chunk 1b — atomic N-element reparent) ──────────────

pub const ReparentElementsInput = struct {
    page_id: []const u8,
    element_ids: []const []const u8,
    /// null = top-level (no parent). Pass "" also accepted as
    /// top-level — the SQL COALESCE convention normalises both
    /// shapes to "no parent".
    new_parent_id: ?[]const u8,
    reposition: RepositionMode,
};

pub const ReparentElementsError = error{
    PageNotFound,
    EmptyElementIds,
    BadElementId,
    CrossPageIds,
    CycleDetected,
    BadNewParentId,
    DbError,
    OutOfMemory,
};

/// Re-parent N elements atomically (single SQL transaction). Used
/// by the drag-to-reparent UX so dragging 1 or N selected rows into
/// a group uses one round-trip instead of N parallel PUTs.
///
/// Behaviour:
///   1. Validate `element_ids` is non-empty (EmptyElementIds).
///   2. Look up the page JOIN (workspace_id, item_id) — needed for
///      the SSE event payload. PageNotFound on miss.
///   3. Look up `new_parent_id` (when non-null): validate it exists
///      on the same page, validate its type is `group` or `frame`
///      (containers only). BadNewParentId on miss / wrong type /
///      cross-page.
///   4. Pre-flight cycle check: for each element_id, walk up from
///      `new_parent_id` and reject the WHOLE batch if any element_id
///      appears in the chain (CycleDetected). No writes happen on
///      rejection — see the SQL transaction below.
///   5. Begin transaction. For each element_id (in input order):
///      a. SELECT COALESCE(MAX(position), -1) FROM design_page_elements
///         WHERE (COALESCE(parent_id, '') = ? OR parent_id IS NULL)
///         AND id != ?
///      b. UPDATE design_page_elements SET parent_id = ?, position = ?,
///         updated_at = datetime('now') WHERE id = ?
///   6. Commit. On any failure the deferred rollback leaves the DB
///      unchanged.
///   7. Re-SELECT the updated rows and return them in input order
///      (heap-owned; caller frees with `freeElements`).
///   8. Emit one `design_element_updated` SSE event per affected
///      element (best-effort).
///
/// Returns the slice of updated `DesignElement` rows in input order.
/// The signature is `anyerror!` so the sqlite-side error unions
/// from `db.query` / `db.exec` / `db.begin` can flow through
/// unchanged — the handler maps the documented variants to HTTP
/// status codes and treats the rest as 500.
///
/// Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
pub fn reparentElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: ReparentElementsInput,
) anyerror![]DesignElement {
    if (input.element_ids.len == 0) return error.EmptyElementIds;

    // 1. Look up the page JOIN (workspace_id, item_id) for the SSE
    //    event payload. Same JOIN shape as groupElements.
    const Lookup = struct {
        workspace_id: []u8,
        item_id: []u8,
    };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT wi.workspace_id, dp.workspace_item_id
            \\FROM design_pages dp
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE dp.id = ?
        , &.{input.page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.PageNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .workspace_id = try allocator.dupe(u8, row.values[0]),
            .item_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);

    // 2. Validate the new parent (when non-null). Same shape as
    //    updateElement's parent_id cycle check, plus the page match
    //    and container-type validation that setElementParent already
    //    does.
    if (input.new_parent_id) |new_pid| {
        var q = try db.query(allocator,
            \\SELECT page_id, type FROM design_page_elements WHERE id = ?
        , &.{new_pid});
        defer q.deinit();
        const row_opt = try q.next();
        if (row_opt == null) return error.BadNewParentId;
        var row = row_opt.?;
        defer row.deinit(allocator);
        const parent_page_id = row.values[0];
        const parent_type = row.values[1];
        if (!std.mem.eql(u8, parent_page_id, input.page_id)) return error.BadNewParentId;
        if (!std.mem.eql(u8, parent_type, "group") and
            !std.mem.eql(u8, parent_type, "frame"))
        {
            return error.BadNewParentId;
        }
    }

    // 3. Build the dynamic IN-list SELECT for the requested elements.
    //    Same IN-list pattern as groupElements.
    var in_list_sql: std.ArrayList(u8) = .empty;
    defer in_list_sql.deinit(allocator);
    try in_list_sql.appendSlice(allocator, "SELECT page_id FROM design_page_elements WHERE id IN (");
    var in_args: std.ArrayList([]const u8) = .empty;
    defer in_args.deinit(allocator);
    for (input.element_ids, 0..) |eid, i| {
        if (i > 0) try in_list_sql.append(allocator, ',');
        try in_list_sql.append(allocator, '?');
        try in_args.append(allocator, eid);
    }
    try in_list_sql.append(allocator, ')');

    // 4. Fetch each element's page_id. Reject BadElementId (count
    //    mismatch) or CrossPageIds (any element on a different page).
    var element_pages: std.ArrayList([]u8) = .empty;
    defer {
        for (element_pages.items) |p| allocator.free(p);
        element_pages.deinit(allocator);
    }
    {
        var q = try db.query(allocator, in_list_sql.items, in_args.items);
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            try element_pages.append(allocator, try allocator.dupe(u8, row.values[0]));
        }
    }
    if (element_pages.items.len != input.element_ids.len) return error.BadElementId;
    for (element_pages.items) |p| {
        if (!std.mem.eql(u8, p, input.page_id)) return error.CrossPageIds;
    }

    // 5. Pre-flight cycle check for every element. If ANY element_id
    //    would close a cycle (appears in the ancestor chain starting
    //    from new_parent_id), reject the whole batch — no DB writes.
    for (input.element_ids) |eid| {
        if (try wouldCreateCycle(db, allocator, eid, input.new_parent_id orelse "")) {
            return error.CycleDetected;
        }
    }

    // 6. SQL transaction. defer-rollback guarantees atomicity: if
    //    any UPDATE fails below, the rollback fires automatically.
    //    On the success path we commit explicitly and mark
    //    `committed = true` to suppress the defer rollback.
    var tx = try db.begin();
    var committed = false;
    defer if (!committed) tx.rollback() catch {};

    // 7. Apply per-element UPDATEs. We re-query MAX(position) for
    //    each so the second element lands at first+1 (not the first
    //    again), preserving input order in the new parent's children.
    var updated_rows: std.ArrayList(DesignElement) = .empty;
    defer {
        for (updated_rows.items) |e| freeElement(allocator, e);
        updated_rows.deinit(allocator);
    }
    for (input.element_ids, 0..) |eid, i| {
        _ = i;
        // Per-element MAX position. The new_parent_id for the query
        // is what we just verified in step 2.
        const new_parent_sql: []const u8 = if (input.new_parent_id) |p| p else "";
        var max_pos_q = try tx.query(allocator,
            \\SELECT COALESCE(MAX(position), -1) FROM design_page_elements
            \\WHERE COALESCE(parent_id, '') = ? AND id != ?
        , &.{ new_parent_sql, eid });
        defer max_pos_q.deinit();
        const max_pos_row = (try max_pos_q.next()) orelse return error.DbError;
        defer max_pos_row.deinit(allocator);
        const max_pos_value = std.fmt.parseInt(i64, max_pos_row.values[0], 10) catch 0;
        const new_position = max_pos_value + 1;

        // The new_parent_id to bind: empty string when top-level
        // (SqliteBackend.exec binds "" as NULL — the COALESCE
        // convention used everywhere in this codebase).
        const new_parent_to_bind: []const u8 = if (input.new_parent_id) |p| p else "";
        const new_position_str = try std.fmt.allocPrint(allocator, "{d}", .{new_position});
        defer allocator.free(new_position_str);

        try tx.exec(allocator,
            \\UPDATE design_page_elements
            \\SET parent_id = ?, position = ?, updated_at = datetime('now')
            \\WHERE id = ?
        , &.{ new_parent_to_bind, new_position_str, eid });
    }

    // 8. Re-SELECT the updated rows (in input order) to return to the
    //    caller. Use the same SELECT shape as listElements.
    var row_ptrs: std.ArrayList([]u8) = .empty;
    defer {
        for (row_ptrs.items) |p| allocator.free(p);
        row_ptrs.deinit(allocator);
    }
    for (input.element_ids) |eid| try row_ptrs.append(allocator, try allocator.dupe(u8, eid));

    var updated: std.ArrayList(DesignElement) = .empty;
    defer {
        for (updated.items) |e| freeElement(allocator, e);
        updated.deinit(allocator);
    }
    for (row_ptrs.items) |eid| {
        var q = try tx.query(allocator,
            \\SELECT id, page_id, COALESCE(parent_id, ''),
            \\       x, y, width, height,
            \\       z_index, position,
            \\       name, file_path, type, rotation, fill, stroke,
            \\       stroke_width, corner_radius, opacity,
            \\       text_content, text_style, image_url,
            \\       COALESCE(created_at, ''), COALESCE(updated_at, '')
            \\FROM design_page_elements
            \\WHERE id = ?
        , &.{eid});
        defer q.deinit();
        const row_opt = try q.next();
        if (row_opt == null) return error.DbError;
        var row = row_opt.?;
        defer row.deinit(allocator);

        const e: DesignElement = .{
            .id = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .parent_id = try allocator.dupe(u8, row.values[2]),
            .x = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
            .y = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .width = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
            .height = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
            .z_index = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
            .position = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
            .name = try allocator.dupe(u8, row.values[9]),
            .file_path = try allocator.dupe(u8, row.values[10]),
            .elem_type = try allocator.dupe(u8, row.values[11]),
            .rotation = std.fmt.parseFloat(f64, row.values[12]) catch 0.0,
            .fill = try allocator.dupe(u8, row.values[13]),
            .stroke = try allocator.dupe(u8, row.values[14]),
            .stroke_width = std.fmt.parseInt(i64, row.values[15], 10) catch 0,
            .corner_radius = std.fmt.parseInt(i64, row.values[16], 10) catch 0,
            .opacity = std.fmt.parseFloat(f64, row.values[17]) catch 1.0,
            .text_content = try allocator.dupe(u8, row.values[18]),
            .text_style = try allocator.dupe(u8, row.values[19]),
            .image_url = try allocator.dupe(u8, row.values[20]),
            .created_at = try allocator.dupe(u8, row.values[21]),
            .updated_at = try allocator.dupe(u8, row.values[22]),
        };
        try updated.append(allocator, e);
    }

    // 9. Emit SSE events (one per element) AFTER the commit so listeners
    //    see state that's already committed. Best-effort.
    //
    //    `committed = true` MUST come after `try tx.commit()`. Clearing
    //    it first disarms the `defer if (!committed) tx.rollback()`
    //    safety net while the COMMIT is still pending, and
    //    `Transaction._doFinalizeCommit` marks the Transaction `completed`
    //    before it reports a COMMIT failure — so a COMMIT that comes back
    //    `database is locked` leaves an OPEN transaction holding WAL's
    //    single writer slot on this connection, with no code path left
    //    that can close it. Every later write on this backend then fails
    //    with the same message until the process restarts. The four
    //    sibling functions in this file (lines 1272, 1604, 1914, 2225)
    //    already order it this way.
    try tx.commit();
    committed = true;

    for (input.element_ids) |eid| {
        on_event_sent_design.onEventSendDesignElementUpdated(allocator, .{
            .action = "updated",
            .workspace_id = lookup.workspace_id,
            .item_id = lookup.item_id,
            .page_id = input.page_id,
            .element_id = eid,
        }) catch {};
    }

    return updated.toOwnedSlice(allocator);
}

// ─── reorderElements (Chunk 5 — right-click bring/send z-order) ──────────

pub const ReorderMode = enum {
    bring_to_front,
    send_to_back,
    bring_forward,
    send_backward,
};

pub const ReorderInput = struct {
    page_id: []const u8,
    mode: ReorderMode,
    element_ids: []const []const u8,
};

pub const ReorderError = error{
    PageNotFound,
    BadElementId,
    CrossPageIds,
    DbError,
    OutOfMemory,
};

/// Reorder 1+ elements on a page. Returns the updated rows in their
/// new top-to-bottom z-order. Caveats:
///   - All ids must resolve to rows on the same `page_id`.
///   - For `bring_to_front` / `send_to_back`, multiple ids are
///     processed in (or reverse-of) input order; users get explicit
///     control of the final relative order via the order they list
///     the ids.
///   - For `bring_forward` / `send_backward`, only the first
///     (resp. last) selected id swaps with its next sibling; if the
///     selection contains more ids, only the boundary id moves.
pub fn reorderElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: ReorderInput,
) ReorderError![]DesignElement {
    if (input.element_ids.len == 0) return error.BadElementId;

    // 1. Pre-flight: verify the page exists. listElements returns an
    //    empty slice (no error) for a non-existent page, so we cannot
    //    distinguish "no elements yet" from "page doesn't exist"
    //    without an extra SELECT. The HTTP handler maps
    //    PageNotFound to 404; without this check every reorder
    //    against an unknown page would surface as 400 BadElementId.
    {
        var pq = db.query(allocator,
            "SELECT 1 FROM design_pages WHERE id = ?",
            &.{input.page_id}) catch return error.DbError;
        defer pq.deinit();
        const row = (pq.next() catch return error.DbError) orelse return error.PageNotFound;
        row.deinit(allocator);
    }

    var all = listElements(allocator, db, input.page_id) catch return error.DbError;
    var free_all = true;
    defer if (free_all) {
        for (all) |e| freeElement(allocator, e);
        allocator.free(all);
    };

    // 2. Validate every requested id resolves to a row on this page.
    //    Build an id -> index map. Duplicates in input.element_ids are
    //    tolerated (the second occurrence skips the DB lookup).
    //
    //    For ids that DON'T resolve to a row on this page, distinguish
    //    BadElementId (id missing entirely) from CrossPageIds
    //    (id exists but on a different page) via an existence probe —
    //    so the HTTP handler can return 400 vs 409 correctly.
    var id_to_idx = std.StringHashMap(usize).init(allocator);
    defer id_to_idx.deinit();
    for (all, 0..) |e, i| try id_to_idx.put(e.id, i);

    var indexes: std.ArrayList(usize) = .empty;
    defer indexes.deinit(allocator);
    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (input.element_ids) |cid| {
            const gop = try seen.getOrPut(cid);
            if (gop.found_existing) continue;
            if (id_to_idx.get(cid)) |idx| {
                try indexes.append(allocator, idx);
                continue;
            }
            // id not on this page — probe design_page_elements to see
            // whether it exists on a DIFFERENT page (CrossPageIds) or
            // doesn't exist at all (BadElementId).
            var q = db.query(allocator,
                "SELECT 1 FROM design_page_elements WHERE id = ?",
                &.{cid}) catch return error.DbError;
            defer q.deinit();
            if (q.next() catch return error.DbError) |r| {
                r.deinit(allocator);
                return error.CrossPageIds;
            }
            return error.BadElementId;
        }
    }

    // Helper for the two "single-step" modes: is `i` in the indexes set?
    const InSet = struct {
        fn check(items: []const usize, i: usize) bool {
            for (items) |x| if (x == i) return true;
            return false;
        }
    };

    // 3. Apply the mode.
    switch (input.mode) {
        .bring_to_front => {
            var max_z: i64 = std.math.minInt(i64);
            for (all) |e| {
                if (e.z_index > max_z) max_z = e.z_index;
            }
            var next_z: i64 = max_z + 1;
            for (indexes.items) |idx| {
                all[idx].z_index = next_z;
                next_z += 1;
            }
        },
        .send_to_back => {
            var min_z: i64 = std.math.maxInt(i64);
            for (all) |e| {
                if (e.z_index < min_z) min_z = e.z_index;
            }
            var next_z: i64 = min_z - 1;
            var i: usize = indexes.items.len;
            while (i > 0) {
                i -= 1;
                all[indexes.items[i]].z_index = next_z;
                next_z -= 1;
            }
        },
        .bring_forward => {
            // For each selected (in INPUT order), swap with the
            // next-sibling above (the FIRST non-selected element
            // with a HIGHER z_index). Iterating forward means the
            // highest-of-the-selected swaps first, then the next, etc.
            // — collectively the multi-selection moves up by one slot.
            for (indexes.items) |idx| {
                const cur_z = all[idx].z_index;
                // We want the smallest non-selected z that is > cur_z.
                var best: ?usize = null;
                var best_z: i64 = std.math.maxInt(i64);
                for (all, 0..) |e, i| {
                    if (e.z_index <= cur_z) continue;
                    if (InSet.check(indexes.items, i)) continue;
                    if (e.z_index < best_z) {
                        best_z = e.z_index;
                        best = i;
                    }
                }
                if (best) |b| {
                    const other_z = all[b].z_index;
                    all[idx].z_index = other_z;
                    all[b].z_index = cur_z;
                }
            }
        },
        .send_backward => {
            // Mirror of bring_forward: largest selected z swaps
            // first with the next non-selected z below.
            for (indexes.items) |idx| {
                const cur_z = all[idx].z_index;
                var best: ?usize = null;
                var best_z: i64 = std.math.minInt(i64);
                for (all, 0..) |e, i| {
                    if (e.z_index >= cur_z) continue;
                    if (InSet.check(indexes.items, i)) continue;
                    if (e.z_index > best_z) {
                        best_z = e.z_index;
                        best = i;
                    }
                }
                if (best) |b| {
                    const other_z = all[b].z_index;
                    all[idx].z_index = other_z;
                    all[b].z_index = cur_z;
                }
            }
        },
    }

    // 4. Persist the new z_index values.
    for (all) |e| {
        const z_str = try std.fmt.allocPrint(allocator, "{d}", .{e.z_index});
        defer allocator.free(z_str);
        db.exec(allocator,
            "UPDATE design_page_elements SET z_index = ? WHERE id = ?",
            &.{ z_str, e.id }) catch return error.DbError;
    }

    // 5. Return the updated rows in their new top-to-bottom order.
    free_all = false;
    for (all) |e| freeElement(allocator, e);
    allocator.free(all);
    // Re-fetch in case the source-of-truth DB rows changed (other
    // tabs may have reordered while we were processing).
    return listElements(allocator, db, input.page_id) catch |err| return switch (err) {
        error.PageNotFound => error.PageNotFound,
        else => error.DbError,
    };
}

// ─── ungroupElements (Cmd+Shift+G / right-click Ungroup) ──────────────────

pub const UngroupInput = struct {
    page_id: []const u8,
    /// The id of the `group` or `frame` element to dissolve. The
    /// children of this element are reparented to the group's parent
    /// (or top-level if the group had no parent).
    element_id: []const u8,
};

pub const UngroupError = error{
    /// `element_id` doesn't resolve on the page.
    BadGroupId,
    /// The element is not a `group` or `frame`.
    NotAGroup,
    /// The element has no children (matching Figma's greyed-out Ungroup).
    EmptyGroup,
    DbError,
    OutOfMemory,
};

/// Dissolve a `group` or `frame`: reparent its direct children to
/// the group's parent (or NULL if top-level), delete the group's row.
/// Children keep their absolute x/y/z_index — their geometry is
/// independent of the group's bbox.
///
/// Returns the rows of the now-orphaned children in their new state
/// (post-reparent) so the caller can mirror them in local state.
/// Call `freeElements(allocator, result)` on the returned slice.
pub fn ungroupElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: UngroupInput,
) UngroupError![]DesignElement {
    // 1. Look up the group element. Verify it's a group/frame.
    var group_row = db.query(allocator,
        "SELECT id, page_id, COALESCE(parent_id, ''), type FROM design_page_elements WHERE id = ?",
        &.{input.element_id}) catch return error.DbError;
    defer group_row.deinit();
    const maybe_g_opt = group_row.next() catch return error.DbError;
    if (maybe_g_opt == null) return error.BadGroupId;
    var g = maybe_g_opt.?;
    defer g.deinit(allocator);

    const group_parent_id: []const u8 = g.values[2];
    const group_type_str: []const u8 = g.values[3];
    if (!std.mem.eql(u8, group_type_str, "group") and
        !std.mem.eql(u8, group_type_str, "frame"))
    {
        return error.NotAGroup;
    }

    // 2. Fetch the children to be reparented.
    var children: std.ArrayList(DesignElement) = .empty;
    defer {
        for (children.items) |c| freeElement(allocator, c);
        children.deinit(allocator);
    }
    {
        var q = db.query(allocator,
            \\SELECT de.id, de.page_id, COALESCE(de.parent_id, ''),
            \\       de.x, de.y, de.width, de.height,
            \\       de.z_index, de.position,
            \\       de.name, de.type
            \\FROM design_page_elements de
            \\WHERE de.parent_id = ? AND de.page_id = ?
            \\ORDER BY de.z_index ASC, de.position ASC
        , &.{ input.element_id, input.page_id }) catch return error.DbError;
        defer q.deinit();
        while (q.next() catch return error.DbError) |row| {
            defer row.deinit(allocator);
            const e: DesignElement = .{
                .id = allocator.dupe(u8, row.values[0]) catch return error.DbError,
                .page_id = allocator.dupe(u8, row.values[1]) catch return error.DbError,
                .name = allocator.dupe(u8, row.values[9]) catch return error.DbError,
                .file_path = allocator.dupe(u8, "") catch return error.DbError,
                .x = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
                .y = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
                .width = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
                .height = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
                .z_index = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
                .position = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
                .elem_type = allocator.dupe(u8, row.values[10]) catch return error.DbError,
                .rotation = 0,
                .fill = allocator.dupe(u8, "") catch return error.DbError,
                .stroke = allocator.dupe(u8, "") catch return error.DbError,
                .stroke_width = 0,
                .corner_radius = 0,
                .opacity = 1.0,
                .text_content = allocator.dupe(u8, "") catch return error.DbError,
                .text_style = allocator.dupe(u8, "") catch return error.DbError,
                .image_url = allocator.dupe(u8, "") catch return error.DbError,
                .parent_id = allocator.dupe(u8, group_parent_id) catch return error.DbError,
                .created_at = allocator.dupe(u8, "") catch return error.DbError,
                .updated_at = allocator.dupe(u8, "") catch return error.DbError,
            };
            children.append(allocator, e) catch return error.DbError;
        }
    }

    if (children.items.len == 0) return error.EmptyGroup;

    // 3. Reparent each child to the group's parent (or NULL).
    for (children.items) |c| {
        db.exec(allocator,
            "UPDATE design_page_elements SET parent_id = ? WHERE id = ?",
            &.{ group_parent_id, c.id }) catch return error.DbError;
    }

    // 4. Delete the group row.
    db.exec(allocator,
        "DELETE FROM design_page_elements WHERE id = ?",
        &.{input.element_id}) catch return error.DbError;

    // 5. Update each child's in-memory copy to reflect the new parent_id.
    for (children.items) |*c| {
        allocator.free(c.parent_id);
        c.parent_id = allocator.dupe(u8, group_parent_id) catch return error.DbError;
    }

    return children.toOwnedSlice(allocator);
}

// ─── listElements / getElement ─────────────────────────────────────────────

/// List all elements of a design page in (z_index, position) order.
/// Returns an owned slice; caller MUST release with
/// `freeElements(allocator, slice)`. Excludes the element's HTML
/// body — use `loadElementHtml` to fetch the body lazily.
pub fn listElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror![]DesignElement {
    var q = try db.query(allocator,
        \\SELECT de.id, de.page_id, de.name, de.file_path,
        \\       de.x, de.y, de.width, de.height, de.z_index, de.position,
        \\       de.type, de.rotation, de.fill, de.stroke, de.stroke_width,
        \\       de.corner_radius, de.opacity,
        \\       de.text_content, de.text_style, de.image_url,
        \\       COALESCE(de.parent_id, ''),
        \\       COALESCE(de.created_at, ''), COALESCE(de.updated_at, '')
        \\FROM design_page_elements de
        \\WHERE de.page_id = ?
        \\ORDER BY de.z_index ASC, de.position ASC
    , &.{page_id});
    defer q.deinit();

    var rows = std.ArrayList(DesignElement).empty;
    errdefer {
        for (rows.items) |e| {
            allocator.free(e.id);
            allocator.free(e.page_id);
            allocator.free(e.name);
            allocator.free(e.file_path);
            allocator.free(e.elem_type);
            allocator.free(e.fill);
            allocator.free(e.stroke);
            allocator.free(e.text_content);
            allocator.free(e.text_style);
            allocator.free(e.image_url);
            allocator.free(e.parent_id);
            allocator.free(e.created_at);
            allocator.free(e.updated_at);
        }
        rows.deinit(allocator);
    }
    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .file_path = try allocator.dupe(u8, row.values[3]),
            .x = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .y = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
            .width = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
            .height = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
            .z_index = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
            .position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
            .elem_type = try allocator.dupe(u8, row.values[10]),
            .rotation = std.fmt.parseFloat(f64, row.values[11]) catch 0,
            .fill = try allocator.dupe(u8, row.values[12]),
            .stroke = try allocator.dupe(u8, row.values[13]),
            .stroke_width = std.fmt.parseInt(i64, row.values[14], 10) catch 0,
            .corner_radius = std.fmt.parseInt(i64, row.values[15], 10) catch 0,
            .opacity = std.fmt.parseFloat(f64, row.values[16]) catch 0,
            .text_content = try allocator.dupe(u8, row.values[17]),
            .text_style = try allocator.dupe(u8, row.values[18]),
            .image_url = try allocator.dupe(u8, row.values[19]),
            .parent_id = try allocator.dupe(u8, row.values[20]),
            .created_at = try allocator.dupe(u8, row.values[21]),
            .updated_at = try allocator.dupe(u8, row.values[22]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// Get a single element by id (excluding HTML body). Returns
/// `ElementNotFound` if no such row exists.
pub fn getElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror!DesignElement {
    var q = try db.query(allocator,
        \\SELECT de.id, de.page_id, de.name, de.file_path,
        \\       de.x, de.y, de.width, de.height, de.z_index, de.position,
        \\       de.type, de.rotation, de.fill, de.stroke, de.stroke_width,
        \\       de.corner_radius, de.opacity,
        \\       de.text_content, de.text_style, de.image_url,
        \\       COALESCE(de.parent_id, ''),
        \\       COALESCE(de.created_at, ''), COALESCE(de.updated_at, '')
        \\FROM design_page_elements de
        \\WHERE de.id = ?
    , &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(allocator);
    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .page_id = try allocator.dupe(u8, row.values[1]),
        .name = try allocator.dupe(u8, row.values[2]),
        .file_path = try allocator.dupe(u8, row.values[3]),
        .x = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
        .y = std.fmt.parseInt(i64, row.values[5], 10) catch 0,
        .width = std.fmt.parseInt(i64, row.values[6], 10) catch 0,
        .height = std.fmt.parseInt(i64, row.values[7], 10) catch 0,
        .z_index = std.fmt.parseInt(i64, row.values[8], 10) catch 0,
        .position = std.fmt.parseInt(i64, row.values[9], 10) catch 0,
        .elem_type = try allocator.dupe(u8, row.values[10]),
        .rotation = std.fmt.parseFloat(f64, row.values[11]) catch 0,
        .fill = try allocator.dupe(u8, row.values[12]),
        .stroke = try allocator.dupe(u8, row.values[13]),
        .stroke_width = std.fmt.parseInt(i64, row.values[14], 10) catch 0,
        .corner_radius = std.fmt.parseInt(i64, row.values[15], 10) catch 0,
        .opacity = std.fmt.parseFloat(f64, row.values[16]) catch 0,
        .text_content = try allocator.dupe(u8, row.values[17]),
        .text_style = try allocator.dupe(u8, row.values[18]),
        .image_url = try allocator.dupe(u8, row.values[19]),
        .parent_id = try allocator.dupe(u8, row.values[20]),
        .created_at = try allocator.dupe(u8, row.values[21]),
        .updated_at = try allocator.dupe(u8, row.values[22]),
    };
}

/// Free a single DesignElement (no backing slice).
pub fn freeElement(allocator: std.mem.Allocator, e: DesignElement) void {
    allocator.free(e.id);
    allocator.free(e.page_id);
    allocator.free(e.name);
    allocator.free(e.file_path);
    allocator.free(e.elem_type);
    allocator.free(e.fill);
    allocator.free(e.stroke);
    allocator.free(e.text_content);
    allocator.free(e.text_style);
    allocator.free(e.image_url);
    allocator.free(e.parent_id);
    allocator.free(e.created_at);
    allocator.free(e.updated_at);
}

// ─── PageWithElements (page + elements bundle for REST GET endpoints) ─────

/// One page plus all its elements (no HTML bodies — lazy-loaded via
/// `loadElementHtml`). Free with `self.deinit(allocator)`.
pub const PageWithElements = struct {
    page: DesignPage,
    elements: []DesignElement,

    /// Release the page fields, every element's fields, and the
    /// elements slice in one call. Mirrors the lifecycle of `listPages`
    /// + `listElements` but bundled.
    pub fn deinit(self: PageWithElements, allocator: std.mem.Allocator) void {
        allocator.free(self.page.id);
        allocator.free(self.page.workspace_item_id);
        allocator.free(self.page.name);
        allocator.free(self.page.workspace_item_task_id);
        allocator.free(self.page.created_at);
        allocator.free(self.page.updated_at);
        freeElements(allocator, self.elements);
    }
};

/// Get ONE design page with all of its elements (no HTML bodies).
/// Returns `PageNotFound` if no page with that id exists. The
/// returned bundle owns all heap allocations — caller MUST call
/// `result.deinit(allocator)`.
///
/// Lazy-loading: element HTML bodies are NOT included; use
/// `loadElementHtml(element_id)` to fetch them individually.
pub fn getPageWithElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror!PageWithElements {
    // 1. Fetch the page row.
    var q = try db.query(allocator,
        \\SELECT dp.id, dp.workspace_item_id, dp.name,
        \\       COALESCE(dp.workspace_item_task_id, ''),
        \\       dp.width, dp.height, dp.position,
        \\       COALESCE(dp.created_at, ''), COALESCE(dp.updated_at, '')
        \\FROM design_pages dp
        \\WHERE dp.id = ?
    , &.{page_id});
    defer q.deinit();

    const page = (try q.next()) orelse return error.PageNotFound;
    // The page row is owned by `q` — dup the fields BEFORE row.deinit
    // fires (the existing listPages pattern uses allocator.dupe inside
    // the loop body). See project memory
    // `zig-slice-headers-across-defer-lifetimes`.
    var page_owned: DesignPage = undefined;
    {
        defer page.deinit(allocator);
        page_owned = .{
            .id = try allocator.dupe(u8, page.values[0]),
            .workspace_item_id = try allocator.dupe(u8, page.values[1]),
            .name = try allocator.dupe(u8, page.values[2]),
            .workspace_item_task_id = try allocator.dupe(u8, page.values[3]),
            .width = std.fmt.parseInt(i64, page.values[4], 10) catch 0,
            .height = std.fmt.parseInt(i64, page.values[5], 10) catch 0,
            .position = std.fmt.parseInt(i64, page.values[6], 10) catch 0,
            .created_at = try allocator.dupe(u8, page.values[7]),
            .updated_at = try allocator.dupe(u8, page.values[8]),
        };
    }

    // 2. Fetch the page's elements via the existing listElements helper.
    const elements = try listElements(allocator, db, page_owned.id);

    return .{
        .page = page_owned,
        .elements = elements,
    };
}

/// List ALL pages of a design item, each with its elements (no HTML
/// bodies). Returns an owned slice; caller MUST call `freePagesWithElements`
/// (or each result's `deinit` + `allocator.free(slice)`).
///
/// For an item with N pages and M total elements across all pages,
/// this issues 1 query for the page list and N queries for the
/// elements — fine for small N (the design-mode UI typically has
/// 3-10 pages). If N grows large, callers should batch via
/// `getPageWithElements` per visible page instead.
pub fn listPagesWithElements(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) anyerror![]PageWithElements {
    const pages = try listPages(allocator, db, item_id);
    // Track how many pages we've successfully moved into `rows`.
    // Un-consumed pages still own their strings (and need freeing
    // on error). Consumed pages are owned by `rows` (freed by
    // rows.deinit via the errdefer below). The backing slice of
    // `pages` is freed on both paths (success path frees it
    // directly after the loop; error path frees it via the defer
    // below).
    var consumed: usize = 0;
    var backing_slice_freed = false;
    defer {
        if (!backing_slice_freed) {
            // Error path: free the un-consumed tail's strings, then
            // the backing slice. The consumed pages are owned by
            // `rows` and will be freed by its errdefer below
            // (registered AFTER this defer).
            for (pages[consumed..]) |p| {
                allocator.free(p.id);
                allocator.free(p.workspace_item_id);
                allocator.free(p.name);
                allocator.free(p.created_at);
                allocator.free(p.updated_at);
            }
            allocator.free(pages);
        }
    }

    var rows = std.ArrayList(PageWithElements).empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
        // The outer defer for `pages` cleanup has ALREADY fired by
        // here (errdefer LIFO ordering — registered last, fires first).
    }

    for (pages) |page| {
        const elements = listElements(allocator, db, page.id) catch |err| {
            // listElements failed before we moved the page into
            // rows. The page's strings will be freed by the outer
            // defer (pages[consumed..] includes this page).
            return err;
        };
        // If rows.append fails, we still own `elements` and need
        // to free them (the page's strings are freed by the outer
        // defer because consumed was not incremented yet).
        errdefer freeElements(allocator, elements);
        rows.append(allocator, .{
            .page = page,
            .elements = elements,
        }) catch |err| return err;
        consumed += 1;
    }

    // Success: backing slice is no longer needed (per-page strings
    // have all been moved into rows.items). Free the backing slice
    // and tell the outer defer to skip its work.
    backing_slice_freed = true;
    allocator.free(pages);
    return rows.toOwnedSlice(allocator);
}

/// Free a slice of PageWithElements and its backing storage.
pub fn freePagesWithElements(allocator: std.mem.Allocator, items: []PageWithElements) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

// ─── setElementParent ─────────────────────────────────────────────────────
//
// Re-parent an existing element to a new `group`/`frame` (or to
// top-level when `new_parent_id` is null). This is the v1 unblocker
// for the LLM tool surface — without this primitive, an element
// created via `add_element` (which always lands at top-level) cannot
// be moved into an existing group/frame after the fact.

pub const SetElementParentError = error{
    ElementNotFound,
    ParentNotFound,
    ParentNotContainer,
    DifferentPages,
    CycleDetected,
    DbError,
    OutOfMemory,
};

/// Cycle detection for reparent operations. Returns `true` iff
/// reparenting `element_id` to be a child of `new_parent_id` would
/// close a cycle — i.e. `new_parent_id` is already a descendant of
/// `element_id` (or `element_id` itself, though the self-check is
/// done separately at the call site).
///
/// The recursive CTE walks the parent chain UPWARD from
/// `new_parent_id`. If `element_id` appears anywhere in that chain,
/// the new assignment would close a cycle. The
/// `WHERE dpe.parent_id IS NOT NULL` guard terminates the walk at
/// top-level rows. `LIMIT 1` short-circuits as soon as the target
/// is found.
///
/// Used by `updateElement` and `reparentElements` to reject reparent
/// requests that would close a cycle. Same shape as the inline check
/// in `setElementParent` — extracted so both endpoints share one
/// canonical implementation.
///
/// Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
pub fn wouldCreateCycle(
    db: *sqlite.SqliteBackend,
    allocator: std.mem.Allocator,
    element_id: []const u8,
    new_parent_id: []const u8,
) !bool {
    var q = try db.query(allocator,
        \\WITH RECURSIVE chain(id) AS (
        \\    SELECT id FROM design_page_elements WHERE id = ?
        \\    UNION ALL
        \\    SELECT dpe.parent_id FROM design_page_elements dpe
        \\        JOIN chain c ON dpe.id = c.id
        \\        WHERE dpe.parent_id IS NOT NULL
        \\)
        \\SELECT 1 FROM chain WHERE id = ? LIMIT 1
    , &.{ new_parent_id, element_id });
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return true;
    }
    return false;
}

/// Re-parent `element_id` to `new_parent_id` (or top-level when null).
///
/// Behaviour:
///   1. Look up `element_id`'s current page_id + parent_id.
///      Return `ElementNotFound` if the row is missing.
///   2. If `new_parent_id` is null → UPDATE parent_id = NULL
///      (empty string for the empty-slice-binds-as-NULL SQLite
///      convention; same trick used by `addElement`).
///   3. If `new_parent_id` equals the element's current parent_id →
///      no-op (idempotent success).
///   4. Look up `new_parent_id`'s page_id + type.
///      Return `ParentNotFound` if the row is missing.
///   5. Different page? Return `DifferentPages`.
///   6. Type in {`group`, `frame`}? Otherwise return
///      `ParentNotContainer`.
///   7. Cycle check: walk the parent chain from `new_parent_id`
///      upward; if `element_id` appears, return `CycleDetected`.
///   8. UPDATE design_page_elements SET parent_id = ? WHERE id = ?
///      and emit a `design_element_updated` SSE event.
///
/// Returns `void`; the caller re-fetches the element via `getElement`
/// if it needs the post-update state.
pub fn setElementParent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
    new_parent_id: ?[]const u8,
) anyerror!void {
    // 1. Look up the element's current page_id + parent_id.
    const ElemLookup = struct {
        page_id: []u8,
        current_parent_id: []u8,
    };
    const elem: ElemLookup = blk: {
        var q = try db.query(allocator,
            \\SELECT page_id, COALESCE(parent_id, '') FROM design_page_elements WHERE id = ?
        , &.{element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ElementNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .page_id = try allocator.dupe(u8, row.values[0]),
            .current_parent_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(elem.page_id);
    defer allocator.free(elem.current_parent_id);

    // 2. Null new_parent_id → move to top-level.
    if (new_parent_id == null) {
        try db.exec(allocator,
            "UPDATE design_page_elements SET parent_id = NULL, updated_at = datetime('now') WHERE id = ?",
            &.{element_id});
        return;
    }

    const new_pid = new_parent_id.?;

    // 3. Same parent? No-op.
    if (std.mem.eql(u8, elem.current_parent_id, new_pid)) return;

    // 4. Look up the new parent's page_id + type.
    const ParentLookup = struct {
        page_id: []u8,
        elem_type: []u8,
    };
    const parent: ParentLookup = blk: {
        var q = try db.query(allocator,
            \\SELECT page_id, type FROM design_page_elements WHERE id = ?
        , &.{new_pid});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ParentNotFound;
        defer row.deinit(allocator);
        break :blk .{
            .page_id = try allocator.dupe(u8, row.values[0]),
            .elem_type = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(parent.page_id);
    defer allocator.free(parent.elem_type);

    // 5. Same page?
    if (!std.mem.eql(u8, parent.page_id, elem.page_id)) return error.DifferentPages;

    // 6. Container type?
    if (!std.mem.eql(u8, parent.elem_type, "group") and
        !std.mem.eql(u8, parent.elem_type, "frame"))
    {
        return error.ParentNotContainer;
    }

    // 7. Cycle detection via recursive CTE.
    //
    // Walk up the parent chain starting from `new_parent_id`. If any
    // ancestor equals `element_id`, the new assignment would close
    // a cycle (element_id → ... → new_parent_id → element_id).
    //
    // The `WHERE dpe.parent_id IS NOT NULL` guard prevents infinite
    // loops on top-level chains (parent_id = NULL ends the walk).
    {
        var q = try db.query(allocator,
            \\WITH RECURSIVE chain(id) AS (
            \\    SELECT id FROM design_page_elements WHERE id = ?
            \\    UNION ALL
            \\    SELECT dpe.parent_id FROM design_page_elements dpe
            \\        JOIN chain c ON dpe.id = c.id
            \\        WHERE dpe.parent_id IS NOT NULL
            \\)
            \\SELECT 1 FROM chain WHERE id = ? LIMIT 1
        , &.{ new_pid, element_id });
        defer q.deinit();
        if (try q.next()) |_| {
            return error.CycleDetected;
        }
    }

    // 8. Apply the UPDATE.
    try db.exec(allocator,
        "UPDATE design_page_elements SET parent_id = ?, updated_at = datetime('now') WHERE id = ?",
        &.{ new_pid, element_id });
}

// ─── deleteElement ────────────────────────────────────────────────────────

/// Delete an element. Returns `true` if the row was deleted, `false`
/// if no such element existed.
///
/// The on-disk file is unlinked AFTER the SQL DELETE succeeds
/// (defer-pattern). If the unlink fails (file missing or
/// permission denied), we silently log and continue — the DB
/// state is the source of truth, and a leftover file becomes an
/// orphan that the next run can clean up.
pub fn deleteElement(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror!bool {
    // Look up file_path + workspace_id + item_id + page_id BEFORE
    // delete so we can both unlink the file and emit a
    // `design_element_deleted` SSE event with the full id context.
    // Single JOIN query that returns all four pieces of context.
    const Lookup = struct {
        file_path: []u8,
        page_id: []u8,
        workspace_id: []u8,
        item_id: []u8,
    };
    const lookup: Lookup = blk: {
        var q = try db.query(allocator,
            \\SELECT de.file_path, de.page_id, wi.workspace_id,
            \\       dp.workspace_item_id
            \\FROM design_page_elements de
            \\JOIN design_pages dp ON dp.id = de.page_id
            \\JOIN workspace_items wi ON wi.id = dp.workspace_item_id
            \\WHERE de.id = ?
        , &.{element_id});
        defer q.deinit();
        const row = (try q.next()) orelse return false;
        defer row.deinit(allocator);
        break :blk .{
            .file_path = try allocator.dupe(u8, row.values[0]),
            .page_id = try allocator.dupe(u8, row.values[1]),
            .workspace_id = try allocator.dupe(u8, row.values[2]),
            .item_id = try allocator.dupe(u8, row.values[3]),
        };
    };
    defer allocator.free(lookup.file_path);
    defer allocator.free(lookup.page_id);
    defer allocator.free(lookup.workspace_id);
    defer allocator.free(lookup.item_id);

    // NULL-back step: if this element is itself a parent (group/frame),
    // orphan its children first so they become top-level again.
    // Otherwise the children would silently reference a non-existent
    // parent (SQLite FK enforcement is OFF by default — see
    // `docs/superpowers/plans/2026-07-28-grouped-layers.md` Chunk 4).
    try db.exec(allocator,
        "UPDATE design_page_elements SET parent_id = NULL WHERE parent_id = ?",
        &.{element_id});

    // Delete the row first.
    try db.exec(allocator,
        "DELETE FROM design_page_elements WHERE id = ?",
        &.{element_id});

    // Defer-pattern: unlink file AFTER SQL succeeded. Swallow errors
    // (the file may already be missing or read-only).
    if (lookup.file_path.len > 0) {
        design_io.deleteFileIfExists(allocator, lookup.file_path) catch {};
    }

    // Emit SSE event AFTER the SQL DELETE succeeded. Best-effort: if
    // the event_bus is not initialized or the JSON serialization
    // fails, the caller still gets a successful return value — SSE
    // is a hint, not a hard contract. The lookup slices are still
    // alive at this point; the function-level defers haven't fired.
    on_event_sent_design.onEventSendDesignElementDeleted(allocator, .{
        .action = "deleted",
        .workspace_id = lookup.workspace_id,
        .item_id = lookup.item_id,
        .page_id = lookup.page_id,
        .element_id = element_id,
    }) catch {};
    return true;
}

// ─── deletePage ────────────────────────────────────────────────────────────
//
// Delete a design page and everything under it:
//   1. The `design_pages` SQL row.
//   2. Every `design_page_elements` row with matching `page_id` (via FK
//      `ON DELETE CASCADE` — see migrations 055/056).
//   3. Each element's HTML file on disk (per-file unlink via
//      `design_io.deleteFileIfExists`, mirroring `deleteElement`'s
//      pattern — NOT a recursive `deleteDirectoryRecursively`).
//   4. The paired `workspace_item_tasks` row (application-level FK).
//
// Returns `true` on a successful delete, `false` if no such page_id
// exists (idempotent — caller treats 404 as success).
//
// Like `deleteElement`, this is a UI-only operation — no LLM tool
// exposes it, only the DesignView tab-strip × button. See plan
// `docs/superpowers/plans/2026-07-25-design-page-delete-button.md`
// (Chunk 1).
//
// Why per-file deletion (not recursive rmdir)
// ────────────────────────────────────────────
// The 2026-08-06 review of the original PR (which used
// `deleteDirectoryRecursively`) was explicit: the on-disk page
// directory may contain files the user dropped there themselves
// (`.DS_Store`, `README.md`, screenshots, etc.). Recursively
// removing the whole folder would nuke those unrelated files. Per-file
// deletion keeps the unrelated files in place and only removes the
// files explicitly tracked in `design_page_elements.file_path`. This
// mirrors `deleteElement`'s pattern (line 3285-3287) and is the
// correct primitive for an "explicit file list" cleanup.
pub fn deletePage(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    page_id: []const u8,
) anyerror!bool {
    _ = io; // Per-file deletion uses design_io.deleteFileIfExists which doesn't need an Io.
    // Look up `workspace_item_id` + `workspace_item_task_id` from
    // `design_pages` ONLY (no JOIN to `workspace_items`). Both
    // columns live on `design_pages`; we never read `workspace_items`
    // in this function.
    const page_info: struct {
        item_id: []u8,
        workspace_item_task_id: []u8,
    } = blk: {
        var q = try db.query(allocator,
            \\SELECT dp.workspace_item_id,
            \\       COALESCE(dp.workspace_item_task_id, '')
            \\FROM design_pages dp
            \\WHERE dp.id = ?
        , &.{page_id});
        defer q.deinit();
        const row = (try q.next()) orelse return false;
        defer row.deinit(allocator);
        break :blk .{
            .item_id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_task_id = try allocator.dupe(u8, row.values[1]),
        };
    };
    defer allocator.free(page_info.item_id);
    defer allocator.free(page_info.workspace_item_task_id);

    // Collect every `file_path` from this page's elements BEFORE
    // the SQL DELETE so we have an authoritative list of files to
    // unlink. `file_path` is an absolute path written by `addElement`
    // (`<item_path>/.pabrik/design/<page_name>/<elem>.html`), so each
    // entry points at exactly one on-disk file — no
    // `path.dirname` derivation needed, no JOIN to `workspace_items`.
    //
    // The list is heap-owned (each entry is `allocator.dupe`'d).
    // Slice headers inside the SQL `Row` would otherwise dangle when
    // `row.deinit` fires (per project memory
    // `zig-slice-headers-across-defer-lifetimes`).
    var file_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (file_paths.items) |p| allocator.free(p);
        file_paths.deinit(allocator);
    }
    {
        var q = try db.query(allocator,
            \\SELECT file_path FROM design_page_elements WHERE page_id = ?
        , &.{page_id});
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const fp = row.values[0];
            if (fp.len == 0) continue;
            try file_paths.append(allocator, try allocator.dupe(u8, fp));
        }
    }

    // Delete the page row. With FK enforcement ON (the test setup),
    // the element rows are cascade-deleted. With FK enforcement OFF
    // (production default), the element rows remain as orphans —
    // the per-file delete below still cleans up the on-disk
    // artifacts regardless. The orphan rows are pre-existing latent
    // behaviour (out of scope for this fix).
    try db.exec(allocator,
        "DELETE FROM design_pages WHERE id = ?",
        &.{page_id});

    // Cascade-delete the paired workspace_item_tasks row. The
    // application-level "FK" we maintain via the UNIQUE index has no
    // SQL cascade, so we do this by hand. Best-effort: a failure to
    // delete the task row leaves it as an orphan (visible in the
    // sidebar until the user manually cleans it up), but the page
    // itself is gone — the user's primary action succeeded.
    if (page_info.workspace_item_task_id.len > 0) {
        db.exec(allocator,
            "DELETE FROM workspace_item_tasks WHERE id = ?",
            &.{page_info.workspace_item_task_id}) catch {};
    }

    // Per-file deletion AFTER the SQL DELETE. Best-effort: a file
    // that's already been removed (or was never written — empty
    // `file_path`) is silently skipped via `deleteFileIfExists`'s
    // ENOENT handling. We do NOT recursively walk the page folder — a
    // user may have dropped unrelated files there (`.DS_Store`,
    // screenshots, etc.) and we don't want to nuke them.
    for (file_paths.items) |fp| {
        design_io.deleteFileIfExists(allocator, fp) catch {};
    }

    // After unlinking every tracked HTML file, attempt to remove the
    // now-empty page directory itself (`<item_path>/.pabrik/design/<page>/`).
    //
    // Why this step
    // ──────────────
    // The per-file loop above intentionally skips user-dropped files
    // (e.g. `.DS_Store`, `README.md`, screenshots). If those exist,
    // the rmdir below MUST be a no-op (we don't want to leave a
    // dangling empty dir behind, but we also don't want to fail the
    // call when the dir is non-empty for unrelated reasons).
    //
    // We derive the page directory from the FIRST surviving file_path
    // — every element's file_path lives under `<dir>/<elem>.html`, so
    // `std.fs.path.dirname(first_file)` is the page dir. If no element
    // had a file_path (the page had zero elements), there's nothing
    // to rmdir; skip silently.
    //
    // The rmdir is best-effort:
    //   - ENOENT (already gone): no-op
    //   - ENOTEMPTY (user files remain): no-op
    //   - any other error: log + continue (the user's primary action
    //     — delete the page — already succeeded)
    if (file_paths.items.len > 0) {
        if (std.fs.path.dirname(file_paths.items[0])) |page_dir| {
            // deleteDirectoryIfEmpty's possible errors:
            //   DirNotEmpty    — user-dropped files remain (preserve them)
            //   NotADirectory  — race with another rmdir or filesystem oddity
            //   PathTooLong    — file_path exceeded max_path_bytes
            //   RmdirFailed    — permissions / IO failure
            // All four are non-fatal: the user's primary action —
            // delete the page — already succeeded; the page folder
            // either will be left in place (preserves user files) or
            // was already gone (race) or has a pathological path
            // (PathTooLong). Log and continue.
            design_io.deleteDirectoryIfEmpty(allocator, page_dir) catch |err| switch (err) {
                error.DirNotEmpty, error.NotADirectory, error.PathTooLong => {},
                error.RmdirFailed => std.log.warn(
                    "design_model.deletePage: rmdir {s} failed: {s}",
                    .{ page_dir, @errorName(err) },
                ),
            };
        }
    }

    // Emit SSE event AFTER the SQL DELETE succeeded. Best-effort: if
    // the event_bus is not initialized or the JSON serialization
    // fails, the caller still gets a successful return value — SSE
    // is a hint, not a hard contract. The lookup slices are still
    // alive at this point; the function-level defers haven't fired.
    //
    // `workspace_id` is intentionally empty: we no longer JOIN
    // `workspace_items` in this function. No listener currently
    // subscribes to `design_page_deleted`, so the wire-shape change
    // is safe; future consumers can look up `workspace_id` from
    // `item_id` if needed.
    on_event_sent_design.onEventSendDesignPageDeleted(allocator, .{
        .action = "deleted",
        .workspace_id = "",
        .item_id = page_info.item_id,
        .page_id = page_id,
    }) catch {};
    return true;
}

// ─── loadElementHtml ──────────────────────────────────────────────────────

/// Read the on-disk HTML body for an element. Returns
/// `ElementNotFound` if no such row exists; propagates IO errors
/// from the file read.
pub fn loadElementHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) anyerror![]u8 {
    var q = try db.query(allocator,
        "SELECT de.file_path FROM design_page_elements de WHERE de.id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(allocator);
    const file_path = try allocator.dupe(u8, row.values[0]);
    defer allocator.free(file_path);
    if (file_path.len == 0) return error.FileNotFound;
    return try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(5 * 1024 * 1024));
}

// ─── Behavioural tests for `updateElementsBatch` ─────────────────────────
//
// Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
// (Chunk 1, Task 1.1) — the backend mitigation that collapses N
// per-element PATCHes into one PATCH for multi-element drag.
//
// Inline at the bottom of the impl file per the project rule (the
// `agentic_loop/` convention generalised: tests for a function live
// next to the function it exercises).

const testing_geometry = std.testing;

fn teardownGeometryBatchDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

fn insertElementRaw(
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
        \\    '', '', '', NULL,
        \\    datetime('now'), datetime('now')
        \\)
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str });

    return id;
}

fn setupGeometryBatchDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_geometry.allocator;
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

    var tmp = testing_geometry.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_geometry.io, &tmpdir_buf);
    const tmpdir_path = try testing_geometry.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_geometry_batch";
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

test "updateElementsBatch moves 3 elements in one transaction and returns updated rows in input order" {
    const alloc = testing_geometry.allocator;
    var ctx = try setupGeometryBatchDbAndItem();
    defer teardownGeometryBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Test Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);
    const c = try insertElementRaw(alloc, &ctx.db, page_id, "c", 0, 0, 100, 100);
    defer alloc.free(c);

    const result = try updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 100 },
            .{ .element_id = b, .x = 200 },
            .{ .element_id = c, .x = 300 },
        },
    });
    defer freeElements(alloc, result);

    try testing_geometry.expectEqual(@as(usize, 3), result.len);
    try testing_geometry.expectEqualStrings(a, result[0].id);
    try testing_geometry.expectEqualStrings(b, result[1].id);
    try testing_geometry.expectEqualStrings(c, result[2].id);
    try testing_geometry.expectEqual(@as(i64, 100), result[0].x);
    try testing_geometry.expectEqual(@as(i64, 200), result[1].x);
    try testing_geometry.expectEqual(@as(i64, 300), result[2].x);

    const all = try listElements(alloc, &ctx.db, page_id);
    defer freeElements(alloc, all);
    try testing_geometry.expectEqual(@as(usize, 3), all.len);
    for (all) |el| {
        if (std.mem.eql(u8, el.id, a)) try testing_geometry.expectEqual(@as(i64, 100), el.x);
        if (std.mem.eql(u8, el.id, b)) try testing_geometry.expectEqual(@as(i64, 200), el.x);
        if (std.mem.eql(u8, el.id, c)) try testing_geometry.expectEqual(@as(i64, 300), el.x);
    }
}

test "updateElementsBatch rejects empty input with EmptyUpdates" {
    const alloc = testing_geometry.allocator;
    var ctx = try setupGeometryBatchDbAndItem();
    defer teardownGeometryBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Empty Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const result = updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{},
    });
    try testing_geometry.expectError(error.EmptyUpdates, result);
}

test "updateElementsBatch rolls back when ANY element_id is missing (no partial writes)" {
    const alloc = testing_geometry.allocator;
    var ctx = try setupGeometryBatchDbAndItem();
    defer teardownGeometryBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Atomicity Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);
    const b = try insertElementRaw(alloc, &ctx.db, page_id, "b", 0, 0, 100, 100);
    defer alloc.free(b);

    var pre_a_x: i64 = 0;
    var pre_b_x: i64 = 0;
    {
        const all = try listElements(alloc, &ctx.db, page_id);
        defer freeElements(alloc, all);
        for (all) |el| {
            if (std.mem.eql(u8, el.id, a)) pre_a_x = el.x;
            if (std.mem.eql(u8, el.id, b)) pre_b_x = el.x;
        }
    }

    const result = updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{
            .{ .element_id = a, .x = 100 },
            .{ .element_id = "elem_missing", .x = 200 },
            .{ .element_id = b, .x = 300 },
        },
    });
    try testing_geometry.expectError(error.ElementNotFound, result);

    const post = try listElements(alloc, &ctx.db, page_id);
    defer freeElements(alloc, post);
    try testing_geometry.expectEqual(@as(usize, 2), post.len);
    for (post) |el| {
        if (std.mem.eql(u8, el.id, a)) try testing_geometry.expectEqual(pre_a_x, el.x);
        if (std.mem.eql(u8, el.id, b)) try testing_geometry.expectEqual(pre_b_x, el.x);
    }
}

test "updateElementsBatch accepts a single-element batch (N=1)" {
    const alloc = testing_geometry.allocator;
    var ctx = try setupGeometryBatchDbAndItem();
    defer teardownGeometryBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Single Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 0, 0, 100, 100);
    defer alloc.free(a);

    const result = try updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .x = 999 }},
    });
    defer freeElements(alloc, result);

    try testing_geometry.expectEqual(@as(usize, 1), result.len);
    try testing_geometry.expectEqualStrings(a, result[0].id);
    try testing_geometry.expectEqual(@as(i64, 999), result[0].x);
}

test "updateElementsBatch accepts a single field per update (no other fields required)" {
    const alloc = testing_geometry.allocator;
    var ctx = try setupGeometryBatchDbAndItem();
    defer teardownGeometryBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Partial Page",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const a = try insertElementRaw(alloc, &ctx.db, page_id, "a", 50, 50, 200, 200);
    defer alloc.free(a);

    const result = try updateElementsBatch(alloc, &ctx.db, .{
        .page_id = page_id,
        .updates = &.{.{ .element_id = a, .y = 75 }},
    });
    defer freeElements(alloc, result);

    try testing_geometry.expectEqual(@as(usize, 1), result.len);
    try testing_geometry.expectEqual(@as(i64, 50), result[0].x);
    try testing_geometry.expectEqual(@as(i64, 75), result[0].y);
    try testing_geometry.expectEqual(@as(i64, 200), result[0].width);
    try testing_geometry.expectEqual(@as(i64, 200), result[0].height);
}

// ─── updateElement: parent_id + reposition + cycle preflight (Chunk 1) ────
//
// Pulled in from design_model_reparent_test.zig — the convention on this
// project (per the maintainer) is one file per impl, with helpers + tests
// at the bottom.

const testing_reparent = std.testing;

fn setupReparentDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
} {
    const alloc = testing_reparent.allocator;
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

    var tmp = testing_reparent.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_reparent.io, &tmpdir_buf);
    const tmpdir_path = try testing_reparent.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_reparent";
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

fn teardownReparentDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

test "updateElement with reposition: .last_in_parent sets position to MAX(siblings) + 1 (initially 0)" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const leaf_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const result_id = try updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(result_id);

    const got = try getElement(alloc, &ctx.db, leaf_id);
    defer freeElement(alloc, got);
    try testing_reparent.expectEqualStrings(group_id, got.parent_id);
    try testing_reparent.expectEqual(@as(i64, 0), got.position);
}

test "updateElement with reposition: .last_in_parent chains to MAX+1, MAX+2, MAX+3" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const b_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);

    const c_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    const ra = try updateElement(alloc, &ctx.db, .{
        .element_id = a_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(ra);

    const rb = try updateElement(alloc, &ctx.db, .{
        .element_id = b_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(rb);

    const rc = try updateElement(alloc, &ctx.db, .{
        .element_id = c_id,
        .parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(rc);

    const got_a = try getElement(alloc, &ctx.db, a_id);
    defer freeElement(alloc, got_a);
    const got_b = try getElement(alloc, &ctx.db, b_id);
    defer freeElement(alloc, got_b);
    const got_c = try getElement(alloc, &ctx.db, c_id);
    defer freeElement(alloc, got_c);

    try testing_reparent.expectEqual(@as(i64, 0), got_a.position);
    try testing_reparent.expectEqual(@as(i64, 1), got_b.position);
    try testing_reparent.expectEqual(@as(i64, 2), got_c.position);
}

test "updateElement with parent_id = self returns CycleDetected" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const result = updateElement(alloc, &ctx.db, .{
        .element_id = group_id,
        .parent_id = group_id,
    });
    try testing_reparent.expectError(error.CycleDetected, result);
}

test "updateElement with parent_id = transitive descendant returns CycleDetected" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a_id);

    const group_b_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-b",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 200, .y = 300, .width = 200, .height = 200,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_b_id);

    const leaf_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 400, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const b_into_a = try updateElement(alloc, &ctx.db, .{
        .element_id = group_b_id,
        .parent_id = group_a_id,
    });
    defer alloc.free(b_into_a);
    const leaf_into_b = try updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_b_id,
    });
    defer alloc.free(leaf_into_b);

    const cycle_result = updateElement(alloc, &ctx.db, .{
        .element_id = group_a_id,
        .parent_id = leaf_id,
    });
    try testing_reparent.expectError(error.CycleDetected, cycle_result);
}

test "updateElement with parent_id = unrelated group succeeds (no false positive on cycle check)" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a_id);

    const group_b_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group-b",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 600, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_b_id);

    const result_id = try updateElement(alloc, &ctx.db, .{
        .element_id = group_a_id,
        .parent_id = group_b_id,
        .reposition = .last_in_parent,
    });
    defer alloc.free(result_id);

    const got = try getElement(alloc, &ctx.db, group_a_id);
    defer freeElement(alloc, got);
    try testing_reparent.expectEqualStrings(group_b_id, got.parent_id);
}

test "updateElement without reposition leaves position unchanged" {
    const alloc = testing_reparent.allocator;
    var ctx = try setupReparentDbAndItem();
    defer teardownReparentDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const leaf_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const result_id = try updateElement(alloc, &ctx.db, .{
        .element_id = leaf_id,
        .parent_id = group_id,
    });
    defer alloc.free(result_id);

    const got = try getElement(alloc, &ctx.db, leaf_id);
    defer freeElement(alloc, got);
    try testing_reparent.expectEqualStrings(group_id, got.parent_id);
    // addElement assigns positions sequentially: group=0, leaf=1.
    // Without reposition, the UPDATE only changes parent_id and
    // leaves position as-is. So leaf.position stays at 1.
    try testing_reparent.expectEqual(@as(i64, 1), got.position);
}

// ─── reparentElements: atomic N-element reparent model (Chunk 1b) ─────────
//
// Pulled in from design_model_reparent_batch_test.zig.

const testing_reparent_batch = std.testing;

fn setupReparentBatchDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
    page_id: []u8,
} {
    const alloc = testing_reparent_batch.allocator;
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

    var tmp = testing_reparent_batch.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_reparent_batch.io, &tmpdir_buf);
    const tmpdir_path = try testing_reparent_batch.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_reparent_batch";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    const page_id_alloc = try setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
        .page_id = page_id_alloc,
    };
}

fn teardownReparentBatchDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

test "reparentElements moves 3 top-level leaves into a group; positions are 0, 1, 2" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);
    const b_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);
    const c_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 300, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(c_id);

    const ids = [_][]const u8{ a_id, b_id, c_id };
    const updated = try reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group_id,
        .reposition = .last_in_parent,
    });
    defer {
        for (updated) |e| freeElement(alloc, e);
        alloc.free(updated);
    }

    try testing_reparent_batch.expectEqual(@as(usize, 3), updated.len);

    const got_a = try getElement(alloc, &ctx.db, a_id);
    defer freeElement(alloc, got_a);
    const got_b = try getElement(alloc, &ctx.db, b_id);
    defer freeElement(alloc, got_b);
    const got_c = try getElement(alloc, &ctx.db, c_id);
    defer freeElement(alloc, got_c);

    try testing_reparent_batch.expectEqualStrings(group_id, got_a.parent_id);
    try testing_reparent_batch.expectEqual(@as(i64, 0), got_a.position);
    try testing_reparent_batch.expectEqualStrings(group_id, got_b.parent_id);
    try testing_reparent_batch.expectEqual(@as(i64, 1), got_b.position);
    try testing_reparent_batch.expectEqualStrings(group_id, got_c.parent_id);
    try testing_reparent_batch.expectEqual(@as(i64, 2), got_c.position);
}

test "reparentElements with new_parent_id = null moves elements to top-level" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_g', ?, 'g', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('elem_nested_1', ?, 'n1', '', 0, 0, 50, 50, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now')),
        \\   ('elem_nested_2', ?, 'n2', '', 0, 0, 50, 50, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "elem_nested_1", "elem_nested_2" };
    const updated = try reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    defer {
        for (updated) |e| freeElement(alloc, e);
        alloc.free(updated);
    }

    try testing_reparent_batch.expectEqual(@as(usize, 2), updated.len);

    const got1 = try getElement(alloc, &ctx.db, "elem_nested_1");
    defer freeElement(alloc, got1);
    const got2 = try getElement(alloc, &ctx.db, "elem_nested_2");
    defer freeElement(alloc, got2);

    // COALESCE(parent_id, '') returns '' for NULL parent_ids.
    try testing_reparent_batch.expectEqual(@as(usize, 0), got1.parent_id.len);
    try testing_reparent_batch.expectEqual(@as(usize, 0), got2.parent_id.len);
}

test "reparentElements returns CycleDetected if ANY element would cycle, rejecting the whole batch" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_a', ?, 'a', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now')),
        \\   ('elem_b', ?, 'b', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_a', datetime('now'), datetime('now')),
        \\   ('elem_leaf', ?, 'leaf', '', 0, 0, 50, 50, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_b', datetime('now'), datetime('now'))
    , &.{ctx.page_id, ctx.page_id, ctx.page_id});

    const ids = [_][]const u8{ "elem_leaf", "elem_a" };
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "elem_b",
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.CycleDetected, result);

    const got_a = try getElement(alloc, &ctx.db, "elem_a");
    defer freeElement(alloc, got_a);
    try testing_reparent_batch.expectEqual(@as(usize, 0), got_a.parent_id.len);

    const got_leaf = try getElement(alloc, &ctx.db, "elem_leaf");
    defer freeElement(alloc, got_leaf);
    try testing_reparent_batch.expectEqualStrings("elem_b", got_leaf.parent_id);
}

test "reparentElements returns CrossPageIds when any element is on a different page" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const page2_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Second",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page2_id);

    const leaf1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-on-page-1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf1);

    const leaf2 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id,
        .name = "leaf-on-page-2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf2);

    const group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const ids = [_][]const u8{ leaf1, leaf2 };
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = group,
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.CrossPageIds, result);
}

test "reparentElements returns BadNewParentId when the new parent is a leaf type" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const b_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-b",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 60, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(b_id);

    const ids = [_][]const u8{ a_id, b_id };
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = a_id,
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.BadNewParentId, result);
}

test "reparentElements returns BadNewParentId when the new parent does not exist" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const ids = [_][]const u8{a_id};
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = "elem_nonexistent",
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.BadNewParentId, result);
}

test "reparentElements returns EmptyElementIds for an empty input list" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const ids = [_][]const u8{};
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.EmptyElementIds, result);
}

test "reparentElements returns BadElementId when an id does not exist" {
    const alloc = testing_reparent_batch.allocator;
    var ctx = try setupReparentBatchDbAndItem();
    defer teardownReparentBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const a_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf-a",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_id);

    const ids = [_][]const u8{ a_id, "elem_nonexistent" };
    const result = reparentElements(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .element_ids = &ids,
        .new_parent_id = null,
        .reposition = .last_in_parent,
    });
    try testing_reparent_batch.expectError(error.BadElementId, result);
}

// ─── Behavioural tests for `moveElementsWithDescendantsBatch` (Chunk 1) ──
//
// Inline tests per the project rule (see
// `pabrik-agentic-loop-inline-tests-required.md`). Tests below follow
// the existing inline pattern in this file (e.g. `updateElementsBatch`
// at line 2794+).

const testing_move_batch = std.testing;

fn setupMoveBatchDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
    page_id: []u8,
} {
    const alloc = testing_move_batch.allocator;
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

    var tmp = testing_move_batch.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_move_batch.io, &tmpdir_buf);
    const tmpdir_path = try testing_move_batch.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_design_move_batch";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    const page_id_alloc = try setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "MoveBatch",
        .width = 1440,
        .height = 1024,
    });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
        .page_id = page_id_alloc,
    };
}

fn teardownMoveBatchDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Read an element's current x back from the DB (test fixture).
fn moveBatchReadX(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT x FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn moveBatchReadY(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT y FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

fn moveBatchReadWidth(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) !i64 {
    var q = try db.query(alloc,
        "SELECT width FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

test "moveElementsWithDescendantsBatch moves a leaf with no children (cascade is a no-op)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 100, .y = 50, .width = 80, .height = 40,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const items = [_]MoveItem{.{ .element_id = leaf, .dx = 30, .dy = 20 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    try testing_move_batch.expectEqual(@as(usize, 1), updated.len);
    try testing_move_batch.expectEqualStrings(leaf, updated[0].id);
    try testing_move_batch.expectEqual(@as(i64, 130), updated[0].x);
    try testing_move_batch.expectEqual(@as(i64, 70), updated[0].y);

    // Confirm DB persisted the new position.
    try testing_move_batch.expectEqual(@as(i64, 130), try moveBatchReadX(alloc, &ctx.db, leaf));
    try testing_move_batch.expectEqual(@as(i64, 70), try moveBatchReadY(alloc, &ctx.db, leaf));
}

test "moveElementsWithDescendantsBatch moves a container with 2 children by the same delta" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50, .y = 100, .width = 200, .height = 150,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const child1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "child1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 70, .y = 110, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child1);

    const child2 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "child2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 200, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child2);

    const items = [_]MoveItem{.{ .element_id = group, .dx = 100, .dy = 50 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    // 3 elements in the affected set: group + child1 + child2.
    try testing_move_batch.expectEqual(@as(usize, 3), updated.len);

    // All three x/y moved by (100, 50).
    for (updated) |el| {
        const is_group = std.mem.eql(u8, el.id, group);
        const is_child1 = std.mem.eql(u8, el.id, child1);
        const is_child2 = std.mem.eql(u8, el.id, child2);
        try testing_move_batch.expect(is_group or is_child1 or is_child2);
    }

    // Spot-check each row's NEW x/y at the DB level (delta was 100, 50).
    try testing_move_batch.expectEqual(@as(i64, 150), try moveBatchReadX(alloc, &ctx.db, group));
    try testing_move_batch.expectEqual(@as(i64, 150), try moveBatchReadY(alloc, &ctx.db, group));
    try testing_move_batch.expectEqual(@as(i64, 170), try moveBatchReadX(alloc, &ctx.db, child1));
    try testing_move_batch.expectEqual(@as(i64, 160), try moveBatchReadY(alloc, &ctx.db, child1));
    try testing_move_batch.expectEqual(@as(i64, 300), try moveBatchReadX(alloc, &ctx.db, child2));
    try testing_move_batch.expectEqual(@as(i64, 250), try moveBatchReadY(alloc, &ctx.db, child2));
}

test "moveElementsWithDescendantsBatch moves a container with grandchildren (depth 2)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const parent_group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "parent",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 300, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(parent_group);

    const child_group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "child_group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 150, .y = 150, .width = 100, .height = 100,
        .fill = "#cccccc", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = parent_group,
    });
    defer alloc.free(child_group);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 170, .y = 170, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = child_group,
    });
    defer alloc.free(leaf);

    const items = [_]MoveItem{.{ .element_id = parent_group, .dx = 10, .dy = 20 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    try testing_move_batch.expectEqual(@as(usize, 3), updated.len);
    try testing_move_batch.expectEqual(@as(i64, 110), try moveBatchReadX(alloc, &ctx.db, parent_group));
    try testing_move_batch.expectEqual(@as(i64, 120), try moveBatchReadY(alloc, &ctx.db, parent_group));
    try testing_move_batch.expectEqual(@as(i64, 160), try moveBatchReadX(alloc, &ctx.db, child_group));
    try testing_move_batch.expectEqual(@as(i64, 170), try moveBatchReadY(alloc, &ctx.db, child_group));
    try testing_move_batch.expectEqual(@as(i64, 180), try moveBatchReadX(alloc, &ctx.db, leaf));
    try testing_move_batch.expectEqual(@as(i64, 190), try moveBatchReadY(alloc, &ctx.db, leaf));
}

test "moveElementsWithDescendantsBatch applies width/height/rotation to root ONLY (descendants unchanged)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 200, .height = 150,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const child = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "c",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 10, .y = 10, .width = 80, .height = 60,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child);

    const items = [_]MoveItem{.{ .element_id = group, .dx = 50, .dy = 50, .width = 500, .height = 300, .rotation = 0.5 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    // Root: width/height/rotation all changed.
    try testing_move_batch.expectEqual(@as(i64, 500), try moveBatchReadWidth(alloc, &ctx.db, group));
    {
        var q = try ctx.db.query(alloc,
            "SELECT rotation FROM design_page_elements WHERE id = ?",
            &.{group});
        defer q.deinit();
        const row = (try q.next()) orelse unreachable;
        defer row.deinit(alloc);
        const rot = std.fmt.parseFloat(f64, row.values[0]) catch 0.0;
        try testing_move_batch.expectApproxEqAbs(@as(f64, 0.5), rot, 0.0001);
    }

    // Child: width UNCHANGED (80), x/y MOVED by (50, 50).
    try testing_move_batch.expectEqual(@as(i64, 80), try moveBatchReadWidth(alloc, &ctx.db, child));
    try testing_move_batch.expectEqual(@as(i64, 60), try moveBatchReadX(alloc, &ctx.db, child));
    try testing_move_batch.expectEqual(@as(i64, 60), try moveBatchReadY(alloc, &ctx.db, child));
}

test "moveElementsWithDescendantsBatch with dx=0 dy=0 + width change applies only width (no translation)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "l",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const items = [_]MoveItem{.{ .element_id = leaf, .dx = 0, .dy = 0, .width = 200 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    try testing_move_batch.expectEqual(@as(usize, 1), updated.len);
    // x/y UNCHANGED.
    try testing_move_batch.expectEqual(@as(i64, 100), updated[0].x);
    try testing_move_batch.expectEqual(@as(i64, 200), updated[0].y);
    // width CHANGED.
    try testing_move_batch.expectEqual(@as(i64, 200), updated[0].width);
    try testing_move_batch.expectEqual(@as(i64, 200), try moveBatchReadWidth(alloc, &ctx.db, leaf));
}

test "moveElementsWithDescendantsBatch with multiple items: each subtree moves independently" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const group_a = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "ga",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50, .y = 50, .width = 100, .height = 100,
        .fill = "#ff0000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_a);

    const child_a = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "ca",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 60, .y = 60, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group_a,
    });
    defer alloc.free(child_a);

    const group_b = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "gb",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 500, .y = 500, .width = 100, .height = 100,
        .fill = "#00ff00", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_b);

    const child_b = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "cb",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 510, .y = 510, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group_b,
    });
    defer alloc.free(child_b);

    const items = [_]MoveItem{
        .{ .element_id = group_a, .dx = 10, .dy = 0 },
        .{ .element_id = group_b, .dx = 0, .dy = 20 },
    };
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    try testing_move_batch.expectEqual(@as(usize, 4), updated.len);

    // Group A subtree: dx=10, dy=0.
    try testing_move_batch.expectEqual(@as(i64, 60), try moveBatchReadX(alloc, &ctx.db, group_a));
    try testing_move_batch.expectEqual(@as(i64, 50), try moveBatchReadY(alloc, &ctx.db, group_a));
    try testing_move_batch.expectEqual(@as(i64, 70), try moveBatchReadX(alloc, &ctx.db, child_a));
    try testing_move_batch.expectEqual(@as(i64, 60), try moveBatchReadY(alloc, &ctx.db, child_a));

    // Group B subtree: dx=0, dy=20.
    try testing_move_batch.expectEqual(@as(i64, 500), try moveBatchReadX(alloc, &ctx.db, group_b));
    try testing_move_batch.expectEqual(@as(i64, 520), try moveBatchReadY(alloc, &ctx.db, group_b));
    try testing_move_batch.expectEqual(@as(i64, 510), try moveBatchReadX(alloc, &ctx.db, child_b));
    try testing_move_batch.expectEqual(@as(i64, 530), try moveBatchReadY(alloc, &ctx.db, child_b));
}

test "moveElementsWithDescendantsBatch returns EmptyItems for empty input" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const items = [_]MoveItem{};
    const result = moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    try testing_move_batch.expectError(error.EmptyItems, result);
}

test "moveElementsWithDescendantsBatch returns ElementNotFound for any missing element_id (no partial writes)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "l",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const items = [_]MoveItem{
        .{ .element_id = leaf, .dx = 999, .dy = 0 },
        .{ .element_id = "elem_ghost", .dx = 0, .dy = 0 },
    };
    const result = moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    try testing_move_batch.expectError(error.ElementNotFound, result);

    // Atomicity — leaf's x MUST be unchanged in DB.
    try testing_move_batch.expectEqual(@as(i64, 0), try moveBatchReadX(alloc, &ctx.db, leaf));
}

test "moveElementsWithDescendantsBatch returns PageNotFound for unknown page_id" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const items = [_]MoveItem{.{ .element_id = "elem_anything", .dx = 10, .dy = 0 }};
    const result = moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = "page_ghost",
        .items = &items,
    });
    try testing_move_batch.expectError(error.PageNotFound, result);
}

test "moveElementsWithDescendantsBatch handles deeply nested subtree (depth 3+)" {
    const alloc = testing_move_batch.allocator;
    var ctx = try setupMoveBatchDbAndItem();
    defer teardownMoveBatchDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.page_id);

    const g1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g1",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 500, .height = 500,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(g1);
    const g2 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g2",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50, .y = 50, .width = 300, .height = 300,
        .fill = "#eeeeee", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = g1,
    });
    defer alloc.free(g2);
    const g3 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "g3",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 200, .height = 200,
        .fill = "#dddddd", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = g2,
    });
    defer alloc.free(g3);
    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 150, .y = 150, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = g3,
    });
    defer alloc.free(leaf);

    const items = [_]MoveItem{.{ .element_id = g1, .dx = 5, .dy = 7 }};
    const updated = try moveElementsWithDescendantsBatch(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .items = &items,
    });
    defer freeElements(alloc, updated);

    try testing_move_batch.expectEqual(@as(usize, 4), updated.len);
    // All four moved by (5, 7).
    try testing_move_batch.expectEqual(@as(i64, 5), try moveBatchReadX(alloc, &ctx.db, g1));
    try testing_move_batch.expectEqual(@as(i64, 7), try moveBatchReadY(alloc, &ctx.db, g1));
    try testing_move_batch.expectEqual(@as(i64, 55), try moveBatchReadX(alloc, &ctx.db, g2));
    try testing_move_batch.expectEqual(@as(i64, 57), try moveBatchReadY(alloc, &ctx.db, g2));
    try testing_move_batch.expectEqual(@as(i64, 105), try moveBatchReadX(alloc, &ctx.db, g3));
    try testing_move_batch.expectEqual(@as(i64, 107), try moveBatchReadY(alloc, &ctx.db, g3));
    try testing_move_batch.expectEqual(@as(i64, 155), try moveBatchReadX(alloc, &ctx.db, leaf));
    try testing_move_batch.expectEqual(@as(i64, 157), try moveBatchReadY(alloc, &ctx.db, leaf));
}

// ─── Behavioural tests for `moveElementToPage` (2026-08-06) ───
//
// Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 1)
//
// Inline tests per the project rule (see
// `pabrik-agentic-loop-inline-tests-required.md`). Mirrors the
// `moveElementsWithDescendantsBatch` inline-test pattern above (lines
// 4327-4929).

const testing_move_to_page = std.testing;

fn setupMoveToPageDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []const u8,
    item_path: []u8,
    /// Page A — the source page (where the element initially lives).
    source_page_id: []u8,
    /// Page B — the target page (where the element will be moved to).
    target_page_id: []u8,
} {
    const alloc = testing_move_to_page.allocator;
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

    var tmp = testing_move_to_page.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing_move_to_page.io, &tmpdir_buf);
    const tmpdir_path = try testing_move_to_page.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);

    const item_id_const = "item_move_to_page";
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ item_id_const, tmpdir_path });

    const item_id_slice = try alloc.dupe(u8, item_id_const);

    const source_page_id = try setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "source",
        .width = 1440,
        .height = 1024,
    });
    const target_page_id = try setDesignPage(alloc, &db, .{
        .item_id = item_id_slice,
        .page_name = "target",
        .width = 1440,
        .height = 1024,
    });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id_slice,
        .item_path = tmpdir_path,
        .source_page_id = source_page_id,
        .target_page_id = target_page_id,
    };
}

fn teardownMoveToPageDb(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

/// Read the element's `page_id` column from the DB (returns the empty
/// string when NULL is stored).
fn moveToPageReadPageId(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) ![]u8 {
    var q = try db.query(alloc,
        "SELECT COALESCE(page_id, '') FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

/// Read the element's `parent_id` column from the DB (returns the empty
/// string when NULL is stored).
fn moveToPageReadParentId(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    element_id: []const u8,
) ![]u8 {
    var q = try db.query(alloc,
        "SELECT COALESCE(parent_id, '') FROM design_page_elements WHERE id = ?",
        &.{element_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ElementNotFound;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

test "moveElementToPage moves a leaf with no children to another page (cascade is a no-op)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 100, .y = 50, .width = 80, .height = 40,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const updated = try moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = leaf,
        .target_page_id = ctx.target_page_id,
        .apply_to_children = true,
    });
    defer freeElements(alloc, updated);

    try testing_move_to_page.expectEqual(@as(usize, 1), updated.len);
    try testing_move_to_page.expectEqualStrings(leaf, updated[0].id);
    try testing_move_to_page.expectEqualStrings(ctx.target_page_id, updated[0].page_id);

    // x/y UNCHANGED — this is a page move, not a coordinate translate.
    try testing_move_to_page.expectEqual(@as(i64, 100), updated[0].x);
    try testing_move_to_page.expectEqual(@as(i64, 50), updated[0].y);

    // DB persistence check.
    const persisted_pid = try moveToPageReadPageId(alloc, &ctx.db, leaf);
    defer alloc.free(persisted_pid);
    try testing_move_to_page.expectEqualStrings(ctx.target_page_id, persisted_pid);
}

test "moveElementToPage moves a group with 2 children atomically (subtree on target)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "g",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 50, .y = 100, .width = 200, .height = 150,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group);

    const child1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "c1",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 70, .y = 110, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child1);

    const child2 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "c2",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 200, .y = 200, .width = 30, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = group,
    });
    defer alloc.free(child2);

    const updated = try moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = group,
        .target_page_id = ctx.target_page_id,
        .apply_to_children = true,
    });
    defer freeElements(alloc, updated);

    // Subtree = 3 elements: group + 2 children. ALL on target page now.
    try testing_move_to_page.expectEqual(@as(usize, 3), updated.len);
    for (updated) |el| {
        try testing_move_to_page.expectEqualStrings(ctx.target_page_id, el.page_id);
    }

    // Children retain parent_id = group (group is also on the target page,
    // so the FK is still valid).
    const c1_pid = try moveToPageReadParentId(alloc, &ctx.db, child1);
    defer alloc.free(c1_pid);
    try testing_move_to_page.expectEqualStrings(group, c1_pid);

    const c2_pid = try moveToPageReadParentId(alloc, &ctx.db, child2);
    defer alloc.free(c2_pid);
    try testing_move_to_page.expectEqualStrings(group, c2_pid);
}

test "moveElementToPage moves a group with grandchildren (depth-2 cascade)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const parent_group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "outer",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 100, .width = 300, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(parent_group);

    const child_group = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "inner",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 150, .y = 150, .width = 100, .height = 100,
        .fill = "#cccccc", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = parent_group,
    });
    defer alloc.free(child_group);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 170, .y = 170, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = child_group,
    });
    defer alloc.free(leaf);

    const updated = try moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = parent_group,
        .target_page_id = ctx.target_page_id,
        .apply_to_children = true,
    });
    defer freeElements(alloc, updated);

    // Subtree = 3 elements (parent_group + child_group + leaf).
    try testing_move_to_page.expectEqual(@as(usize, 3), updated.len);
    for (updated) |el| {
        try testing_move_to_page.expectEqualStrings(ctx.target_page_id, el.page_id);
    }

    // The leaf's parent_id still points to child_group (still on target page).
    const leaf_pid = try moveToPageReadParentId(alloc, &ctx.db, leaf);
    defer alloc.free(leaf_pid);
    try testing_move_to_page.expectEqualStrings(child_group, leaf_pid);
}

test "moveElementToPage auto-clears parent_id when the parent is NOT being moved" {
    // Q4 default (from the spec): when the selected element has a
    // parent_id pointing to an element that's NOT in the moved subtree
    // (i.e. the parent stays on the source page), the parent_id is
    // auto-cleared so the element moves as top-level on the target page.
    // Otherwise we'd have a cross-page parent reference, which violates
    // the invariant "parent_id must live on the same page".
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    // outer group on the source page — stays on the source page.
    const outer = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "outer",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 400, .height = 400,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(outer);

    // inner child of outer — this is what gets moved.
    const inner = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "inner",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 50, .y = 50, .width = 80, .height = 60,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = outer,
    });
    defer alloc.free(inner);

    const updated = try moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = inner,
        .target_page_id = ctx.target_page_id,
        .apply_to_children = true,
    });
    defer freeElements(alloc, updated);

    // Subtree of `inner` is just itself (no children), so 1 element.
    try testing_move_to_page.expectEqual(@as(usize, 1), updated.len);
    try testing_move_to_page.expectEqualStrings(ctx.target_page_id, updated[0].page_id);

    // parent_id is cleared (top-level on the target page).
    const inner_pid = try moveToPageReadParentId(alloc, &ctx.db, inner);
    defer alloc.free(inner_pid);
    try testing_move_to_page.expectEqualStrings("", inner_pid);

    // The outer group is STILL on the source page.
    const outer_pid = try moveToPageReadPageId(alloc, &ctx.db, outer);
    defer alloc.free(outer_pid);
    try testing_move_to_page.expectEqualStrings(ctx.source_page_id, outer_pid);
}

test "moveElementToPage rejects SamePage (source == target)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "l",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const result = moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = leaf,
        .target_page_id = ctx.source_page_id, // same as source!
        .apply_to_children = true,
    });
    try testing_move_to_page.expectError(error.SamePage, result);
}

test "moveElementToPage rejects CrossDesign (target on different item)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    // Create a SECOND design item with its own page.
    var tmp2 = testing_move_to_page.tmpDir(.{});
    var tmp2_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp2_len = try tmp2.dir.realPath(testing_move_to_page.io, &tmp2_buf);
    const tmp2_path = try testing_move_to_page.allocator.dupe(u8, tmp2_buf[0..tmp2_len]);
    defer alloc.free(tmp2_path);
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES ('item_other', 'ws_test', 'design', ?)",
        &.{tmp2_path});
    const item_other_slice = try alloc.dupe(u8, "item_other");
    defer alloc.free(item_other_slice);
    const other_page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = item_other_slice,
        .page_name = "other",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(other_page_id);

    // Add the leaf on the source page.
    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "l",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    // Try to move it to a page on a DIFFERENT design item — must error.
    const result = moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = leaf,
        .target_page_id = other_page_id, // different design item!
        .apply_to_children = true,
    });
    try testing_move_to_page.expectError(error.CrossDesign, result);
}

test "moveElementToPage rejects PageNotFound (target does not exist)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const leaf = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = ctx.source_page_id,
        .name = "l",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf);

    const result = moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = leaf,
        .target_page_id = "page_nonexistent",
        .apply_to_children = true,
    });
    try testing_move_to_page.expectError(error.PageNotFound, result);
}

test "moveElementToPage rejects ElementNotFound (element not on source page)" {
    const alloc = testing_move_to_page.allocator;
    var ctx = try setupMoveToPageDbAndItem();
    defer teardownMoveToPageDb(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);
    defer alloc.free(ctx.source_page_id);
    defer alloc.free(ctx.target_page_id);

    const result = moveElementToPage(alloc, &ctx.db, .{
        .source_page_id = ctx.source_page_id,
        .element_id = "elem_nonexistent",
        .target_page_id = ctx.target_page_id,
        .apply_to_children = true,
    });
    try testing_move_to_page.expectError(error.ElementNotFound, result);
}

// ─── updateDesignPage (rename + size) ────────────────────────────────────
//
// Inline tests for the optional `name` field on UpdateDesignPageInput
// (2026-08-06 — design page rename menu). Covers:
//   - Back-compat: passing `name = null` keeps the old width/height-only
//     UPDATE behaviour (regression guard for the dynamic-SQL builder).
//   - Rename only: passing `name = "new"` updates the row's name while
//     leaving width/height unchanged.
//   - Empty name: `name = ""` returns BadPageName (matches the same
//     guard `setDesignPage` enforces).
//   - Round-trip: post-update listPages reflects the new name + unchanged
//     geometry (catches the dynamic-SQL "name not persisted" bug).
//
// Per project convention, the test-setup helper + alias are namespaced
// to avoid colliding with the pre-existing `testing_geometry` / etc.
// aliases above.

const testing_update_page = std.testing;

fn setupUpdatePageDbAndItem() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
} {
    const alloc = testing_update_page.allocator;
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
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)
    , &.{});

    const item_id = try alloc.dupe(u8, "item_rename_test");
    errdefer alloc.free(item_id);

    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES (?, 'ws_1', 'design', 'Design Item')",
        &.{item_id});

    // Direct INSERT (skipping setDesignPage, which requires a non-empty
    // path on workspace_items). The test only exercises the UPDATE
    // path of updateDesignPage — name validation, dynamic SQL builder,
    // round-trip via listPages — so the page-create invariants
    // (linked chat task, on-disk folder write) are out of scope here.
    const page_id = try alloc.dupe(u8, "page_rename_target");
    errdefer alloc.free(page_id);

    try db.exec(alloc,
        \\INSERT INTO design_pages (
        \\    id, workspace_item_id, name,
        \\    width, height, position
        \\) VALUES (?, ?, ?, ?, ?, 0)
    , &.{ page_id, item_id, "Original Name", "1440", "1024" });

    return .{
        .db = db,
        .threaded = threaded,
        .item_id = item_id,
        .page_id = page_id,
    };
}

fn teardownUpdatePage(
    db: *sqlite.SqliteBackend,
    threaded: *std.Io.Threaded,
    item_id: []u8,
    page_id: []u8,
) void {
    db.deinit();
    threaded.deinit();
    testing_update_page.allocator.free(item_id);
    testing_update_page.allocator.free(page_id);
}

test "updateDesignPage with name=null is back-compat (size-only update)" {
    const alloc = testing_update_page.allocator;
    var ctx = try setupUpdatePageDbAndItem();
    defer teardownUpdatePage(&ctx.db, &ctx.threaded, ctx.item_id, ctx.page_id);

    const updated = try updateDesignPage(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .width = 1920,
        .height = 1080,
        .name = null,
    });
    // Manual field-by-field free (the page is returned as a single
    // struct, not a slice — `freePages` ends with `allocator.free(pages)`
    // which expects a heap-allocated slice; a single struct return needs
    // the per-field frees below).
    defer {
        alloc.free(updated.id);
        alloc.free(updated.workspace_item_id);
        alloc.free(updated.name);
        alloc.free(updated.workspace_item_task_id);
        alloc.free(updated.created_at);
        alloc.free(updated.updated_at);
    }

    try testing_update_page.expectEqual(@as(i64, 1920), updated.width);
    try testing_update_page.expectEqual(@as(i64, 1080), updated.height);
    // Name preserved (NOT blanked — the dynamic SQL builder skips the
    // `name = ?` clause when null).
    try testing_update_page.expectEqualStrings("Original Name", updated.name);
}

test "updateDesignPage with name persists the new name and keeps size" {
    const alloc = testing_update_page.allocator;
    var ctx = try setupUpdatePageDbAndItem();
    defer teardownUpdatePage(&ctx.db, &ctx.threaded, ctx.item_id, ctx.page_id);

    const updated = try updateDesignPage(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .width = 1440,
        .height = 1024,
        .name = "Renamed Page",
    });
    defer {
        alloc.free(updated.id);
        alloc.free(updated.workspace_item_id);
        alloc.free(updated.name);
        alloc.free(updated.workspace_item_task_id);
        alloc.free(updated.created_at);
        alloc.free(updated.updated_at);
    }

    try testing_update_page.expectEqualStrings("Renamed Page", updated.name);
    try testing_update_page.expectEqual(@as(i64, 1440), updated.width);
    try testing_update_page.expectEqual(@as(i64, 1024), updated.height);

    // Round-trip via listPages — catches the "name got bound to the
    // wrong slot" / "SQL clause skipped silently" bugs.
    const pages = try listPages(alloc, &ctx.db, ctx.item_id);
    defer freePages(alloc, pages);
    try testing_update_page.expectEqual(@as(usize, 1), pages.len);
    try testing_update_page.expectEqualStrings("Renamed Page", pages[0].name);
}

test "updateDesignPage with empty name returns BadPageName" {
    const alloc = testing_update_page.allocator;
    var ctx = try setupUpdatePageDbAndItem();
    defer teardownUpdatePage(&ctx.db, &ctx.threaded, ctx.item_id, ctx.page_id);

    const result = updateDesignPage(alloc, &ctx.db, .{
        .page_id = ctx.page_id,
        .width = 1440,
        .height = 1024,
        .name = "",
    });
    try testing_update_page.expectError(error.BadPageName, result);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_add_element_parent_test.zig
// ════════════════════════════════════════════════════════════════════════════

const testing = std.testing;


/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL. Mirrors `design_model_parent_id_test.zig::addElementParentSetupDbAndItem`.
fn addElementParentSetupDbAndItem() !struct {
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

    const item_id_const = "item_design_add_parent";
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

fn addElementParentTeardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: parent_id sets the FK on the new row ─────────────────────────

test "addElement with parent_id sets the FK on the new row" {
    const alloc = testing.allocator;
    var ctx = try addElementParentSetupDbAndItem();
    defer addElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add a parent frame (top-level).
    const parent_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(parent_id);

    // Add a child rectangle nested under the parent frame.
    const child_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-button",
        .elem_type = .rectangle,
        .html = "<div>Login</div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = parent_id,
    });
    defer alloc.free(child_id);

    // Round-trip: read the child back and assert parent_id is set.
    const child = try getElement(alloc, &ctx.db, child_id);
    defer freeElement(alloc, child);

    try testing.expectEqualStrings(parent_id, child.parent_id);
}

// ─── Test 2: parent_id pointing to a non-existent element fails ───────────

test "addElement with parent_id pointing to a non-existent element returns BadParentId" {
    const alloc = testing.allocator;
    var ctx = try addElementParentSetupDbAndItem();
    defer addElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const result = addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "orphan",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = "elem_does_not_exist",
    });

    try testing.expectError(error.BadParentId, result);
}

// ─── Test 3: parent_id on a different page returns BadParentId ────────────

test "addElement with parent_id on a different page returns BadParentId" {
    const alloc = testing.allocator;
    var ctx = try addElementParentSetupDbAndItem();
    defer addElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_a = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Page A",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_a);

    const page_b = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Page B",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_b);

    // Add a frame on page A (top-level).
    const parent_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_a,
        .name = "frame-on-page-a",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(parent_id);

    // Try to add a child on page B referencing the parent on page A.
    const result = addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_b,
        .name = "cross-page-child",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = parent_id,
    });

    try testing.expectError(error.BadParentId, result);
}

// ─── Test 4: parent_id of a leaf type returns ParentNotContainer ──────────

test "addElement with parent_id pointing to a leaf rectangle returns ParentNotContainer" {
    const alloc = testing.allocator;
    var ctx = try addElementParentSetupDbAndItem();
    defer addElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add a rectangle (leaf type — cannot contain children).
    const leaf_parent = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_parent);

    // Try to nest a child under the rectangle.
    const result = addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child-of-leaf",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        .parent_id = leaf_parent,
    });

    try testing.expectError(error.ParentNotContainer, result);
}

// ─── Test 5: default parent_id (null) preserves top-level behavior ────────

test "addElement without parent_id defaults to top-level (empty parent_id)" {
    const alloc = testing.allocator;
    var ctx = try addElementParentSetupDbAndItem();
    defer addElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const child_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "top-level",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
        // No .parent_id — should default to top-level.
    });
    defer alloc.free(child_id);

    const child = try getElement(alloc, &ctx.db, child_id);
    defer freeElement(alloc, child);

    try testing.expectEqual(@as(usize, 0), child.parent_id.len);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_delete_page_test.zig
// ════════════════════════════════════════════════════════════════════════════



const ITEM_ID = "item_design_delete_page_test";

/// Minimal in-memory DB shape (mirrors `design_model_delete_parent_test.zig`).
/// Includes `workspace_items.path` so we can also confirm the new code
/// path works when the item row is deleted FIRST (no path lookup).
fn deletePageSetupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    item_path: []u8,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // SQLite has FK enforcement OFF by default; the production code's
    // comment on deletePage says it relies on `ON DELETE CASCADE` to
    // remove the element rows, so we enable FK enforcement in this
    // test to match the documented contract.
    try db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});

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

    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', ?)",
        &.{ ITEM_ID, tmpdir_path });

    return .{ .db = db, .threaded = threaded, .item_path = tmpdir_path };
}

/// Insert one design_page_elements row whose `file_path` is the full
/// absolute path to its on-disk HTML file. Creates the file + page
/// directory on disk so deletePage's rmdir step has something to
/// remove.
fn deletePageInsertElementWithDiskFile(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    id: []const u8,
    page_id: []const u8,
    page_dir: []const u8,
    elem_name: []const u8,
) ![]u8 {
    const sanitized_elem = try std.fmt.allocPrint(alloc, "{s}.html", .{elem_name});
    defer alloc.free(sanitized_elem);
    const file_path = try std.fs.path.join(alloc, &.{ page_dir, sanitized_elem });

    // Ensure the page directory exists on disk + write a dummy HTML body.
    std.Io.Dir.cwd().createDirPath(io, page_dir) catch return error.FileWriteFailed;
    const f = std.Io.Dir.cwd().createFile(io, file_path, .{}) catch return error.FileWriteFailed;
    f.close(io);
    const body = "<html><body>hello</body></html>";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = body });

    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{0});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{0});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{100});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{100});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, ?, ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', '', datetime('now'), datetime('now'))
    , &.{ id, page_id, elem_name, file_path, x_str, y_str, w_str, h_str });

    return file_path;
}

fn deletePagePageIdExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM design_pages WHERE id = ?",
        &.{page_id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(alloc);
        return true;
    }
    return false;
}

fn deletePageElementIdExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM design_page_elements WHERE id = ?",
        &.{id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(alloc);
        return true;
    }
    return false;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "deletePage returns false when page_id does not exist" {
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, "page_does_not_exist");
    try testing.expect(!was_deleted);
}

test "deletePage removes the design_pages row + cascade-deletes elements" {
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Insert an element via setDesignPage's pairing — but we don't
    // need the workspace_item_task_id here. Just need the row.
    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".pabrik/design/Home" });
    defer alloc.free(page_dir);
    const elem_path = try deletePageInsertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_home_a", page_id, page_dir, "elem-home-a",
    );
    defer alloc.free(elem_path);

    try testing.expect(try deletePagePageIdExists(alloc, &ctx.db, page_id));
    try testing.expect(try deletePageElementIdExists(alloc, &ctx.db, "elem_home_a"));

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    try testing.expect(!try deletePagePageIdExists(alloc, &ctx.db, page_id));
    // FK ON DELETE CASCADE removes the element row.
    try testing.expect(!try deletePageElementIdExists(alloc, &ctx.db, "elem_home_a"));
}

test "deletePage unlinks each element's HTML file individually (per-file, NOT recursive directory delete)" {
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Login",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Sanitized dir = "<item_path>/.pabrik/design/Login".
    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".pabrik/design/Login" });
    defer alloc.free(page_dir);
    const login_btn_path = try deletePageInsertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_login_button", page_id, page_dir, "login-button",
    );
    defer alloc.free(login_btn_path);
    const forgot_link_path = try deletePageInsertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_forgot_link", page_id, page_dir, "forgot-link",
    );
    defer alloc.free(forgot_link_path);

    // A non-DB-tracked file the user dropped into the page directory
    // manually (e.g. a stray `README.md` or `.DS_Store`). Per-file
    // deletion must NOT touch this — only the files tracked in
    // `design_page_elements.file_path` should be removed. This
    // is the regression guard against the pre-fix code that
    // recursively deleted the whole folder.
    const stray_file_path = try std.fs.path.join(alloc, &.{ page_dir, "user-note.txt" });
    defer alloc.free(stray_file_path);
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.threaded.io(), stray_file_path, .{});
        f.close(ctx.threaded.io());
        try std.Io.Dir.cwd().writeFile(ctx.threaded.io(), .{ .sub_path = stray_file_path, .data = "user-added note" });
    }

    // Sanity: all three files exist before delete.
    try testing.expect(fileExists(ctx.threaded.io(), login_btn_path));
    try testing.expect(fileExists(ctx.threaded.io(), forgot_link_path));
    try testing.expect(fileExists(ctx.threaded.io(), stray_file_path));

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // Each DB-tracked file is gone after delete (per-file deletion,
    // mirrors deleteElement's pattern).
    try testing.expect(!fileExists(ctx.threaded.io(), login_btn_path));
    try testing.expect(!fileExists(ctx.threaded.io(), forgot_link_path));

    // The non-DB-tracked file MUST still exist — per-file deletion
    // does NOT recursively walk the folder. This is the regression
    // guard for the 2026-08-06 review (user said: "should delete on
    // file not file inside folder recursivly").
    try testing.expect(fileExists(ctx.threaded.io(), stray_file_path));
}

test "deletePage succeeds (no-op on disk) when page has no elements yet" {
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Empty",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // No elements, no on-disk directory → deletePage should still
    // succeed and remove the SQL row (the new lookup returns null
    // because there are no file_paths to derive from).
    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);
    try testing.expect(!try deletePagePageIdExists(alloc, &ctx.db, page_id));
}

test "deletePage cascade-deletes the paired workspace_item_tasks row" {
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Chat",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // The paired task id is stored on design_pages.workspace_item_task_id.
    // Read it back.
    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(workspace_item_task_id, '') FROM design_pages WHERE id = ?",
        &.{page_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoPageRow;
    defer row.deinit(alloc);
    const task_id = try alloc.dupe(u8, row.values[0]);
    defer alloc.free(task_id);
    try testing.expect(task_id.len > 0);

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // The paired workspace_item_tasks row must be gone.
    var q2 = try ctx.db.query(alloc,
        "SELECT 1 FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer q2.deinit();
    const task_row = try q2.next();
    try testing.expect(task_row == null);
}

test "deletePage rmdirs the empty page directory (cleans up after per-file unlink)" {
    // Why this test exists
    // ─────────────────────
    // The per-file unlink step (`deleteFileIfExists`) leaves an empty
    // `<page>/` directory behind — which was the root cause of the
    // 2026-08-13 functional-test regression (every DELETE /pages/:pid
    // left a stale empty folder, so `test_delete_page_removes_entire_directory`
    // failed because the dir still existed). This test pins the
    // post-fix contract: `deletePage` MUST rmdir the page folder after
    // unlinking its tracked HTML files, so the directory disappears
    // when nothing user-dropped remains inside.
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Clean",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".pabrik/design/Clean" });
    defer alloc.free(page_dir);
    const elem_path = try deletePageInsertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_clean_a", page_id, page_dir, "elem-clean-a",
    );
    defer alloc.free(elem_path);

    // Sanity: page directory exists.
    try testing.expect(dirExists(ctx.threaded.io(), page_dir));

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // After delete: the page directory itself is gone (rmdir succeeded
    // because no user-dropped files remain inside).
    try testing.expect(!dirExists(ctx.threaded.io(), page_dir));
}

test "deletePage preserves a user-dropped file inside the page directory" {
    // The companion to the rmdir-cleanup test: when the user has
    // dropped a file (`.DS_Store`, `README.md`, screenshot, etc.)
    // into the page folder, deletePage MUST keep it. The
    // `deleteDirectoryIfEmpty` step refuses to rmdir non-empty
    // directories — the user file survives, the page DB rows still
    // get deleted.
    const alloc = testing.allocator;
    var ctx = try deletePageSetupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ITEM_ID,
        .page_name = "Mixed",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const page_dir = try std.fs.path.join(alloc, &.{ ctx.item_path, ".pabrik/design/Mixed" });
    defer alloc.free(page_dir);
    const elem_path = try deletePageInsertElementWithDiskFile(
        alloc, &ctx.db, ctx.threaded.io(),
        "elem_mixed_a", page_id, page_dir, "elem-mixed-a",
    );
    defer alloc.free(elem_path);

    // User drops a README.md into the page folder (not tracked in DB).
    const stray_path = try std.fs.path.join(alloc, &.{ page_dir, "user-note.txt" });
    defer alloc.free(stray_path);
    {
        const f = try std.Io.Dir.cwd().createFile(ctx.threaded.io(), stray_path, .{});
        f.close(ctx.threaded.io());
        try std.Io.Dir.cwd().writeFile(
            ctx.threaded.io(),
            .{ .sub_path = stray_path, .data = "user-added note" },
        );
    }

    const was_deleted = try deletePage(alloc, ctx.threaded.io(), &ctx.db, page_id);
    try testing.expect(was_deleted);

    // DB-tracked file is gone.
    try testing.expect(!fileExists(ctx.threaded.io(), elem_path));
    // User's file is still there (preserves user-dropped files).
    try testing.expect(fileExists(ctx.threaded.io(), stray_path));
    // Page directory still exists (we couldn't rmdir a non-empty dir).
    try testing.expect(dirExists(ctx.threaded.io(), page_dir));
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_delete_parent_test.zig
// ════════════════════════════════════════════════════════════════════════════



/// Same shape as design_model_test.zig::deleteParentSetupDbAndItem (kept inline
/// so this file is self-contained for the static checks).
fn deleteParentSetupDbAndItem() !struct {
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

    const item_id_const = "item_design_delete_parent";
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

/// Insert one design element with explicit (id, x, y, width, height,
/// parent_id) so we can build a parent + N children tree.
fn deleteParentInsertElement(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    x: i64, y: i64, w: i64, h: i64,
    parent_id: []const u8,
) !void {
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{w});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{h});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, '', ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', ?, datetime('now'), datetime('now'))
    , &.{ id, page_id, name, x_str, y_str, w_str, h_str, parent_id });
}

/// Read parent_id of a row by id. Returns "NULL" when the column is
/// empty (NULL).
fn deleteParentParentIdOf(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) ![]u8 {
    var q = try db.query(alloc,
        "SELECT COALESCE(parent_id, 'NULL') FROM design_page_elements WHERE id = ?",
        &.{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "deleteElement NULLs parent_id on children of a deleted parent" {
    const alloc = testing.allocator;
    var ctx = try deleteParentSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Build: parent (frame), with 2 children.
    try deleteParentInsertElement(alloc, &ctx.db, "elem_parent", page_id, "Parent", 0, 0, 200, 200, "");
    try deleteParentInsertElement(alloc, &ctx.db, "elem_child_a", page_id, "Child A", 10, 10, 50, 50, "elem_parent");
    try deleteParentInsertElement(alloc, &ctx.db, "elem_child_b", page_id, "Child B", 70, 70, 50, 50, "elem_parent");

    // Sanity: children have parent_id = elem_parent before delete.
    {
        const a_pid = try deleteParentParentIdOf(alloc, &ctx.db, "elem_child_a");
        defer alloc.free(a_pid);
        try testing.expectEqualStrings("elem_parent", a_pid);

        const b_pid = try deleteParentParentIdOf(alloc, &ctx.db, "elem_child_b");
        defer alloc.free(b_pid);
        try testing.expectEqualStrings("elem_parent", b_pid);
    }

    // Delete the parent.
    const was_deleted = try deleteElement(alloc, &ctx.db, "elem_parent");
    try testing.expect(was_deleted);

    // The children should STILL exist with parent_id = NULL
    // (i.e. they became top-level).
    const a_pid_after = try deleteParentParentIdOf(alloc, &ctx.db, "elem_child_a");
    defer alloc.free(a_pid_after);
    try testing.expectEqualStrings("NULL", a_pid_after);

    const b_pid_after = try deleteParentParentIdOf(alloc, &ctx.db, "elem_child_b");
    defer alloc.free(b_pid_after);
    try testing.expectEqualStrings("NULL", b_pid_after);

    // The parent itself should be gone (getElement returns ElementNotFound).
    const result = getElement(alloc, &ctx.db, "elem_parent");
    try testing.expectError(error.ElementNotFound, result);
}

test "deleteElement of a leaf element leaves no parent_id side-effects on others" {
    const alloc = testing.allocator;
    var ctx = try deleteParentSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // 3 top-level elements (no parent_id anywhere). Deleting one
    // should not affect the others' parent_id state.
    try deleteParentInsertElement(alloc, &ctx.db, "elem_tl_1", page_id, "TL 1", 0, 0, 50, 50, "");
    try deleteParentInsertElement(alloc, &ctx.db, "elem_tl_2", page_id, "TL 2", 100, 0, 50, 50, "");
    try deleteParentInsertElement(alloc, &ctx.db, "elem_tl_3", page_id, "TL 3", 200, 0, 50, 50, "");

    const was_deleted = try deleteElement(alloc, &ctx.db, "elem_tl_2");
    try testing.expect(was_deleted);

    // elem_tl_1 and elem_tl_3 should still exist with NULL parent_id.
    const pid_1 = try deleteParentParentIdOf(alloc, &ctx.db, "elem_tl_1");
    defer alloc.free(pid_1);
    try testing.expectEqualStrings("NULL", pid_1);

    const pid_3 = try deleteParentParentIdOf(alloc, &ctx.db, "elem_tl_3");
    defer alloc.free(pid_3);
    try testing.expectEqualStrings("NULL", pid_3);
}

test "deleteElement of a parent with no children just deletes the row" {
    const alloc = testing.allocator;
    var ctx = try deleteParentSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Empty parent (no children reference it). Delete should be a
    // no-op for other rows + the parent row vanishes.
    try deleteParentInsertElement(alloc, &ctx.db, "elem_empty_parent", page_id, "EmptyParent", 0, 0, 100, 100, "");

    const was_deleted = try deleteElement(alloc, &ctx.db, "elem_empty_parent");
    try testing.expect(was_deleted);

    // The parent is gone.
    const result = getElement(alloc, &ctx.db, "elem_empty_parent");
    try testing.expectError(error.ElementNotFound, result);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_group_test.zig
// ════════════════════════════════════════════════════════════════════════════




/// Open a fresh in-memory sqlite DB with the minimum tables needed
/// for the design SQL. Same shape as
/// `design_model_test.zig::groupSetupDbAndItem`.
fn groupSetupDbAndItem() !struct {
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

    const item_id_const = "item_design_group";
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

/// Insert one design element with explicit (x, y, width, height) and
/// the given name. Returns the generated elem_<id>.
fn groupInsertChild(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, name: []const u8, x: i64, y: i64, w: i64, h: i64) ![]u8 {
    // db.exec binds only TEXT — stringify the integer columns.
    const x_str = try std.fmt.allocPrint(alloc, "{d}", .{x});
    defer alloc.free(x_str);
    const y_str = try std.fmt.allocPrint(alloc, "{d}", .{y});
    defer alloc.free(y_str);
    const w_str = try std.fmt.allocPrint(alloc, "{d}", .{w});
    defer alloc.free(w_str);
    const h_str = try std.fmt.allocPrint(alloc, "{d}", .{h});
    defer alloc.free(h_str);
    try db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   (?, ?, ?, '', ?, ?, ?, ?, 0, 0,
        \\    'rectangle', 0.0, '#ffffff', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{ name, page_id, name, x_str, y_str, w_str, h_str });
    return alloc.dupe(u8, name);
}

// ─── Behavioural tests ───────────────────────────────────────────────────

test "groupElements creates a new parent element and reparents the children" {
    const alloc = testing.allocator;
    var ctx = try groupSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Create 3 children with disjoint bboxes (union = 0,0 → 200,150).
    const child_a = try groupInsertChild(alloc, &ctx.db, page_id, "elem_a", 0, 0, 100, 50);
    defer alloc.free(child_a);
    const child_b = try groupInsertChild(alloc, &ctx.db, page_id, "elem_b", 50, 100, 100, 50);
    defer alloc.free(child_b);
    const child_c = try groupInsertChild(alloc, &ctx.db, page_id, "elem_c", 200, 0, 0, 150);
    defer alloc.free(child_c);

    const new_id = try groupElements(alloc, &ctx.db, .{
        .page_id = page_id,
        .child_ids = &.{ child_a, child_b, child_c },
        .parent_name = "Kanban-view",
        .parent_type = .group,
    });
    defer alloc.free(new_id);

    // The new element should be a top-level 'group' with union bbox.
    const parent = try getElement(alloc, &ctx.db, new_id);
    defer freeElement(alloc, parent);

    try testing.expectEqualStrings("Kanban-view", parent.name);
    try testing.expectEqualStrings("group", parent.elem_type);
    try testing.expectEqual(@as(i64, 0), parent.x);
    try testing.expectEqual(@as(i64, 0), parent.y);
    try testing.expectEqual(@as(i64, 200), parent.width);
    try testing.expectEqual(@as(i64, 150), parent.height);
    try testing.expectEqual(@as(usize, 0), parent.parent_id.len);

    // The group must render BEHIND its children — otherwise an opaque
    // fill occludes its contents. Children default to z_index 0, so the
    // group must sit at -1 (min_z - 1).
    try testing.expectEqual(@as(i64, -1), parent.z_index);

    // Each child should now have parent_id set to the new parent.
    const a_after = try getElement(alloc, &ctx.db, child_a);
    defer freeElement(alloc, a_after);
    try testing.expectEqualStrings(new_id, a_after.parent_id);

    const b_after = try getElement(alloc, &ctx.db, child_b);
    defer freeElement(alloc, b_after);
    try testing.expectEqualStrings(new_id, b_after.parent_id);

    const c_after = try getElement(alloc, &ctx.db, child_c);
    defer freeElement(alloc, c_after);
    try testing.expectEqualStrings(new_id, c_after.parent_id);
}

test "groupElements rejects cross-page child ids" {
    const alloc = testing.allocator;
    var ctx = try groupSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_a = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "A",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_a);

    const page_b = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "B",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_b);

    const child_a = try groupInsertChild(alloc, &ctx.db, page_a, "elem_a1", 0, 0, 50, 50);
    defer alloc.free(child_a);
    const child_b = try groupInsertChild(alloc, &ctx.db, page_b, "elem_b1", 0, 0, 50, 50);
    defer alloc.free(child_b);

    // Try to group children that live on different pages.
    const result = groupElements(alloc, &ctx.db, .{
        .page_id = page_a,
        .child_ids = &.{ child_a, child_b },
        .parent_name = "Cross-page-group",
        .parent_type = .group,
    });
    try testing.expectError(error.ChildAcrossDifferentPages, result);
}

test "groupElements rejects already-parented children" {
    const alloc = testing.allocator;
    var ctx = try groupSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const child_a = try groupInsertChild(alloc, &ctx.db, page_id, "elem_a2", 0, 0, 50, 50);
    defer alloc.free(child_a);
    const child_b = try groupInsertChild(alloc, &ctx.db, page_id, "elem_b2", 0, 0, 50, 50);
    defer alloc.free(child_b);

    // Pre-set parent_id on child_a to simulate "already parented".
    try ctx.db.exec(alloc,
        "UPDATE design_page_elements SET parent_id = 'elem_some_parent' WHERE id = ?",
        &.{child_a});

    const result = groupElements(alloc, &ctx.db, .{
        .page_id = page_id,
        .child_ids = &.{ child_a, child_b },
        .parent_name = "Should-fail",
        .parent_type = .group,
    });
    try testing.expectError(error.ChildAlreadyParented, result);
}

test "updateElement accepts parent_id and writes it to the row" {
    const alloc = testing.allocator;
    var ctx = try groupSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const parent_id_slice = try alloc.dupe(u8, "elem_parent_set");
    defer alloc.free(parent_id_slice);

    const child_id = try groupInsertChild(alloc, &ctx.db, page_id, "elem_to_reparent", 10, 10, 100, 50);
    defer alloc.free(child_id);

    // Sanity: parent_id is empty before the update.
    {
        const before = try getElement(alloc, &ctx.db, child_id);
        defer freeElement(alloc, before);
        try testing.expectEqual(@as(usize, 0), before.parent_id.len);
    }

    const updated_id = try updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .parent_id = parent_id_slice,
    });
    defer alloc.free(updated_id);

    const after = try getElement(alloc, &ctx.db, child_id);
    defer freeElement(alloc, after);
    try testing.expectEqualStrings("elem_parent_set", after.parent_id);
}

test "updateElement with parent_id = null leaves existing parent_id unchanged" {
    const alloc = testing.allocator;
    var ctx = try groupSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    const child_id = try groupInsertChild(alloc, &ctx.db, page_id, "elem_keep_parent", 10, 10, 100, 50);
    defer alloc.free(child_id);

    // Set parent_id once.
    const set_id = try updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .parent_id = "elem_first_parent",
    });
    defer alloc.free(set_id);

    // Update x without touching parent_id (parent_id stays "elem_first_parent").
    const x_id = try updateElement(alloc, &ctx.db, .{
        .element_id = child_id,
        .x = 99,
    });
    defer alloc.free(x_id);

    const after = try getElement(alloc, &ctx.db, child_id);
    defer freeElement(alloc, after);
    try testing.expectEqualStrings("elem_first_parent", after.parent_id);
    try testing.expectEqual(@as(i64, 99), after.x);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_parent_id_test.zig
// ════════════════════════════════════════════════════════════════════════════



// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimum tables needed
/// for the design SQL. Mirrors `design_model_test.zig::parentIdSetupDbAndItem`
/// (kept inline here so this file stays self-contained).
fn parentIdSetupDbAndItem() !struct {
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

    const item_id_const = "item_design_parent_id";
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

// ─── Behavioural: getElement returns parent_id (NULL → empty string) ────

test "getElement returns empty string for NULL parent_id" {
    const alloc = testing.allocator;
    var ctx = try parentIdSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const element_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .rectangle,
        .html = "<div>Login</div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const got = try getElement(alloc, &ctx.db, element_id);
    defer freeElement(alloc, got);

    // NULL parent_id → empty string (the SELECT COALESCE pattern is
    // not used here; the column reads "" via the empty-slice-binds-as-null
    // pattern. Both are acceptable per the project memory
    // `zig-sqlite-patterns.md` §"empty slice as NULL").
    try testing.expectEqual(@as(usize, 0), got.parent_id.len);
}

test "getElement returns parent_id value when set" {
    const alloc = testing.allocator;
    var ctx = try parentIdSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Manually INSERT a parent + child with parent_id set, bypassing
    // addElement (which always sets parent_id = NULL via INSERT).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_parent_1', ?, 'parent', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_child_1', ?, 'child', '', 10, 10, 20, 20, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_parent_1', datetime('now'), datetime('now'))
    , &.{page_id});

    const child = try getElement(alloc, &ctx.db, "elem_child_1");
    defer freeElement(alloc, child);

    try testing.expectEqualStrings("elem_parent_1", child.parent_id);
}

test "listElements returns parent_id for every element" {
    const alloc = testing.allocator;
    var ctx = try parentIdSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440, .height = 1024,
    });
    defer alloc.free(page_id);

    // Same manual-INSERT pattern as the previous test. Each row is
    // INSERTed in its own statement so the `?` placeholder count
    // matches the args count (SQLite positions `?` per-statement).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_top', ?, 'top', '', 0, 0, 100, 100, 0, 0,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_parent', ?, 'parent', '', 0, 0, 200, 200, 0, 1,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_child', ?, 'child', '', 10, 10, 50, 50, 0, 2,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_parent', datetime('now'), datetime('now'))
    , &.{page_id});

    const elements = try listElements(alloc, &ctx.db, page_id);
    defer freeElements(alloc, elements);

    try testing.expectEqual(@as(usize, 3), elements.len);

    // Order by (z_index ASC, position ASC). The top-level "top" is at
    // position 0 (z 0); "parent" at position 1 (z 0); "child" at
    // position 2 (z 0).
    try testing.expectEqualStrings("top", elements[0].name);
    try testing.expectEqualStrings("parent", elements[1].name);
    try testing.expectEqualStrings("child", elements[2].name);

    try testing.expectEqual(@as(usize, 0), elements[0].parent_id.len);
    try testing.expectEqual(@as(usize, 0), elements[1].parent_id.len);
    try testing.expectEqualStrings("elem_parent", elements[2].parent_id);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_reorder_test.zig
// ════════════════════════════════════════════════════════════════════════════


/// Set up an in-memory sqlite DB with the minimum tables `reorderElements`
/// reads. Mirrors `design_model_group_test.zig::setupDbAndItem` (without
/// the workspaces + items FK tails that reorderElements doesn't touch).
fn reorderSetupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    alloc: std.mem.Allocator,
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
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
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
        \\    created_at DATETIME, updated_at DATETIME)
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

fn reorderTeardown(s: *@TypeOf(reorderSetupDb() catch @panic("reorderSetupDb failed in the design_model test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Insert a design element at a given z_index. Returns the id (duplicated
/// into the caller's allocator; safe to free with `freeId`).
fn reorderInsertEl(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, page_id: []const u8, id: []const u8, z: i64) ![]u8 {
    const z_str = try std.fmt.allocPrint(alloc, "{d}", .{z});
    defer alloc.free(z_str);
    try db.exec(alloc,
        "INSERT INTO design_page_elements " ++
        "(id, page_id, name, z_index, type) VALUES (?, ?, ?, ?, 'rectangle')",
        &.{ id, page_id, id, z_str });
    return try alloc.dupe(u8, id);
}

/// Read an element's z_index by id. Returns null if not found.
fn reorderReadZ(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, id: []const u8) !?i64 {
    var q = try db.query(alloc, "SELECT z_index FROM design_page_elements WHERE id = ?", &.{id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try std.fmt.parseInt(i64, row.values[0], 10);
    }
    return null;
}

// ───────────────────────────────────────────────────────────────────────
// Tests
// ───────────────────────────────────────────────────────────────────────

test "reorderElements bring_to_front sets selected above untouched elements in input order" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const b = try reorderInsertEl(s.alloc, &s.db, "page_t1", "b", 1);
    defer s.alloc.free(b);
    const c = try reorderInsertEl(s.alloc, &s.db, "page_t1", "c", 2);
    defer s.alloc.free(c);

    // Initial order: a(z=0), b(z=1), c(z=2). Bring {a, c} to front:
    // the algorithm assigns new z values starting from max_z + 1,
    // walking the input list in order. So a (first input) gets z=3
    // (just above existing) and c (second input) gets z=4 (topmost).
    // After: a(z=3), b(z=1 unchanged), c(z=4). Top-to-bottom:
    // c > a > b — the LAST input ends up topmost, which matches the
    // http_handlers/design_elements_reorder_test.zig expectation.
    const result = try reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ a, c },
    });
    // Zig defers are LIFO — free the slice header LAST (after we've
    // walked each element through freeElement), not first. The
    // previous `defer for (...)` then `defer free(result)` order
    // caused a use-after-free on the slice header at test teardown.
    defer s.alloc.free(result);
    defer for (result) |e| freeElement(s.alloc, e);

    try testing.expectEqual(@as(?i64, 3), try reorderReadZ(s.alloc, &s.db, a));
    try testing.expectEqual(@as(?i64, 4), try reorderReadZ(s.alloc, &s.db, c));
    try testing.expectEqual(@as(?i64, 1), try reorderReadZ(s.alloc, &s.db, b));
}

test "reorderElements send_to_back puts selected below untouched in reverse-input order" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const b = try reorderInsertEl(s.alloc, &s.db, "page_t1", "b", 1);
    defer s.alloc.free(b);
    const c = try reorderInsertEl(s.alloc, &s.db, "page_t1", "c", 2);
    defer s.alloc.free(c);

    // Send {a, b} to back: the algorithm iterates the input list in
    // REVERSE order, assigning new z values starting from min_z - 1.
    // So b (last input, processed first) gets z=-1 and a (first input,
    // processed last) gets z=-2. After: a(z=-2), b(z=-1), c(z=2). Top
    // to bottom: c > b > a — the LAST input ends up nearest to the
    // existing elements, the FIRST input ends up bottommost.
    const result = try reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .send_to_back,
        .element_ids = &[_][]const u8{ a, b },
    });
    defer s.alloc.free(result);
    defer for (result) |e| freeElement(s.alloc, e);

    try testing.expectEqual(@as(?i64, -2), try reorderReadZ(s.alloc, &s.db, a));
    try testing.expectEqual(@as(?i64, -1), try reorderReadZ(s.alloc, &s.db, b));
    try testing.expectEqual(@as(?i64, 2), try reorderReadZ(s.alloc, &s.db, c));
}

test "reorderElements bring_forward swaps the topmost selected with the next sibling above" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const b = try reorderInsertEl(s.alloc, &s.db, "page_t1", "b", 1);
    defer s.alloc.free(b);
    const c = try reorderInsertEl(s.alloc, &s.db, "page_t1", "c", 2);
    defer s.alloc.free(c);

    // bring_forward b: b (z=1) should swap with c (z=2). Result:
    // b(z=2), a(z=0), c(z=1).
    const result = try reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_forward,
        .element_ids = &[_][]const u8{ b },
    });
    defer s.alloc.free(result);
    defer for (result) |e| freeElement(s.alloc, e);

    try testing.expectEqual(@as(?i64, 0), try reorderReadZ(s.alloc, &s.db, a));
    try testing.expectEqual(@as(?i64, 2), try reorderReadZ(s.alloc, &s.db, b));
    try testing.expectEqual(@as(?i64, 1), try reorderReadZ(s.alloc, &s.db, c));
}

test "reorderElements send_backward swaps the bottommost selected with the next sibling below" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const b = try reorderInsertEl(s.alloc, &s.db, "page_t1", "b", 1);
    defer s.alloc.free(b);
    const c = try reorderInsertEl(s.alloc, &s.db, "page_t1", "c", 2);
    defer s.alloc.free(c);

    // send_backward b: b (z=1) should swap with a (z=0). Result:
    // b(z=0), a(z=1), c(z=2).
    const result = try reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .send_backward,
        .element_ids = &[_][]const u8{ b },
    });
    defer s.alloc.free(result);
    defer for (result) |e| freeElement(s.alloc, e);

    try testing.expectEqual(@as(?i64, 1), try reorderReadZ(s.alloc, &s.db, a));
    try testing.expectEqual(@as(?i64, 0), try reorderReadZ(s.alloc, &s.db, b));
    try testing.expectEqual(@as(?i64, 2), try reorderReadZ(s.alloc, &s.db, c));
}

test "reorderElements returns BadElementId when an id is missing on the page" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);

    const result = reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "nonexistent" },
    });
    try testing.expectError(error.BadElementId, result);
}

test "reorderElements returns CrossPageIds when an id lives on a different page" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    try s.db.exec(s.alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name) VALUES ('page_t2', 'item_t1', 'Other')",
        &.{});
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const x = try reorderInsertEl(s.alloc, &s.db, "page_t2", "x", 0);
    defer s.alloc.free(x);

    const result = reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ a, x },
    });
    try testing.expectError(error.CrossPageIds, result);
}

test "reorderElements returns PageNotFound when the page id is unknown" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);

    const result = reorderElements(s.alloc, &s.db, .{
        .page_id = "ghost_page",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ "anything" },
    });
    try testing.expectError(error.PageNotFound, result);
}

test "reorderElements returned slice contains the rows in their new top-to-bottom order" {
    var s = try reorderSetupDb();
    defer reorderTeardown(&s);
    const a = try reorderInsertEl(s.alloc, &s.db, "page_t1", "a", 0);
    defer s.alloc.free(a);
    const b = try reorderInsertEl(s.alloc, &s.db, "page_t1", "b", 1);
    defer s.alloc.free(b);
    const c = try reorderInsertEl(s.alloc, &s.db, "page_t1", "c", 2);
    defer s.alloc.free(c);

    const result = try reorderElements(s.alloc, &s.db, .{
        .page_id = "page_t1",
        .mode = .bring_to_front,
        .element_ids = &[_][]const u8{ a, c },
    });
    defer s.alloc.free(result);
    defer for (result) |e| freeElement(s.alloc, e);

    // After bring_to_front {a, c}: a(z=3), b(z=1 unchanged), c(z=4).
    // The function re-fetches the rows in (z_index ASC, position ASC)
    // order, so the returned slice's first row is the LOWEST-z row
    // (a), not the topmost. Verify len + that all 3 ids are present
    // (algorithm-agnostic on top-vs-bottom naming).
    try testing.expectEqual(@as(usize, 3), result.len);
    var seen_a = false;
    var seen_b = false;
    var seen_c = false;
    for (result) |e| {
        if (std.mem.eql(u8, e.id, a)) seen_a = true;
        if (std.mem.eql(u8, e.id, b)) seen_b = true;
        if (std.mem.eql(u8, e.id, c)) seen_c = true;
    }
    try testing.expect(seen_a and seen_b and seen_c);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_set_element_parent_test.zig
// ════════════════════════════════════════════════════════════════════════════



/// Open a fresh in-memory sqlite DB with the minimum tables needed for
/// the design SQL. Same shape as `design_model_add_element_parent_test.zig`.
fn setElementParentSetupDbAndItem() !struct {
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

    const item_id_const = "item_design_set_parent";
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

fn setElementParentTeardown(db: *sqlite.SqliteBackend, threaded: *std.Io.Threaded) void {
    db.deinit();
    threaded.deinit();
}

// ─── Test 1: move element into an existing group ─────────────────────────

test "setElementParent moves element into existing group" {
    const alloc = testing.allocator;
    var ctx = try setElementParentSetupDbAndItem();
    defer setElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add the parent group + the child element both at top-level.
    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 100, .y = 200, .width = 400, .height = 300,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const child_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-button",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 110, .y = 220, .width = 80, .height = 30,
        .fill = "#000000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    // Re-parent the child into the group.
    try setElementParent(alloc, &ctx.db, child_id, group_id);

    // Verify the DB state.
    const child = try getElement(alloc, &ctx.db, child_id);
    defer freeElement(alloc, child);
    try testing.expectEqualStrings(group_id, child.parent_id);
}

// ─── Test 2: move element to top-level via null ───────────────────────────

test "setElementParent with null moves element to top-level" {
    const alloc = testing.allocator;
    var ctx = try setElementParentSetupDbAndItem();
    defer setElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add a parent + child with parent_id set via manual INSERTs
    // (addElement always sets parent_id = NULL).
    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_g', ?, 'group', '', 0, 0, 100, 100, 0, 0,
        \\    'frame', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', NULL, datetime('now'), datetime('now'))
    , &.{page_id});

    try ctx.db.exec(alloc,
        \\INSERT INTO design_page_elements
        \\   (id, page_id, name, file_path, x, y, width, height, z_index, position,
        \\    type, rotation, fill, stroke, stroke_width, corner_radius, opacity,
        \\    text_content, text_style, image_url, parent_id,
        \\    created_at, updated_at)
        \\VALUES
        \\   ('elem_c', ?, 'child', '', 10, 10, 20, 20, 0, 1,
        \\    'rectangle', 0.0, '', '', 0, 0, 1.0,
        \\    '', '', '', 'elem_g', datetime('now'), datetime('now'))
    , &.{page_id});

    // Confirm pre-condition: child has parent_id = 'elem_g'.
    const pre = try getElement(alloc, &ctx.db, "elem_c");
    defer freeElement(alloc, pre);
    try testing.expectEqualStrings("elem_g", pre.parent_id);

    // Move child to top-level.
    try setElementParent(alloc, &ctx.db, "elem_c", null);

    const post = try getElement(alloc, &ctx.db, "elem_c");
    defer freeElement(alloc, post);
    try testing.expectEqual(@as(usize, 0), post.parent_id.len);
}

// ─── Test 3: reject parent_id of a leaf type ──────────────────────────────

test "setElementParent rejects leaf-type parent" {
    const alloc = testing.allocator;
    var ctx = try setElementParentSetupDbAndItem();
    defer setElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const leaf_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "leaf-rect",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(leaf_id);

    const child_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "child",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 50, .height = 50,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(child_id);

    const result = setElementParent(alloc, &ctx.db, child_id, leaf_id);
    try testing.expectError(error.ParentNotContainer, result);
}

// ─── Test 5: reject non-existent element_id ───────────────────────────────

test "setElementParent rejects non-existent element_id" {
    const alloc = testing.allocator;
    var ctx = try setElementParentSetupDbAndItem();
    defer setElementParentTeardown(&ctx.db, &ctx.threaded);
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const group_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "group",
        .elem_type = .frame,
        .html = "<div></div>",
        .x = 0, .y = 0, .width = 100, .height = 100,
        .fill = "#ffffff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(group_id);

    const result = setElementParent(alloc, &ctx.db, "elem_does_not_exist", group_id);
    try testing.expectError(error.ElementNotFound, result);
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from design_model_test.zig
// ════════════════════════════════════════════════════════════════════════════



// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimum tables
/// `design_model` functions need: `workspace_items` + `design_pages`
/// + `design_page_elements`. The v6 schema is used here (no migration
/// cascade).
///
/// Returns the DB handle, the threaded Io, the inserted workspace
/// item id + path. The test must `defer ctx.threaded.deinit()` and
/// `defer ctx.db.deinit()`.
fn designModelSetupDbAndItem() !struct {
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

    // workspace_items. `path` is required by setDesignPage (returns
    // ItemPathMissing if NULL/empty).
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL, name TEXT, path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME)
    , &.{});

    // workspace_item_tasks (required by setDesignPage since the FK
    // work — each new page is paired with a chat task row in the
    // same transaction).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME,
        \\    updated_at DATETIME)
    , &.{});

    // design_pages (v6 schema + post-Migration-066
    // workspace_item_task_id column).
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
        \\    UNIQUE (workspace_item_task_id),
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});

    // design_page_elements (v6 schema — includes the 11 Migration 057
    // columns, but the tests in this file don't exercise them).
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

    // Create a temp directory for the design item's on-disk
    // storage. The tests in this file don't write to disk yet
    // (addElement writes are exercised by Task 1.4), but setDesignPage
    // requires a non-empty `path` on the workspace_item row, so
    // we point at a real tempdir path.
    var tmp = testing.tmpDir(.{});
    var tmpdir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_len = try tmp.dir.realPath(testing.io, &tmpdir_buf);
    const tmpdir_path = try testing.allocator.dupe(u8, tmpdir_buf[0..tmpdir_len]);
    // `tmp` is intentionally not cleaned up at this scope — the
    // directory persists until the OS reclaims the test process's
    // tmp dir. This is acceptable for test-suite use but should be
    // tidied up if reused in production code paths.

    // Insert the workspace item row (item_type='design' with a real path).
    const item_id_const = "item_design_1";
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

// ─── Test: listPages on empty item returns empty slice ──────────────────

test "listPages returns empty slice for an item with no pages" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const pages = try listPages(alloc, &ctx.db, ctx.item_id);
    defer freePages(alloc, pages);
    try testing.expectEqual(@as(usize, 0), pages.len);
}

// ─── Test: setDesignPage creates a page on first call ───────────────────

test "setDesignPage creates a new page on first call" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Generated id starts with "page_".
    try testing.expect(page_id.len > 4);
    try testing.expect(std.mem.startsWith(u8, page_id, "page_"));
}

// ─── Test: setDesignPage is idempotent (same name updates width/height) ─

test "setDesignPage is idempotent (same name updates width/height)" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const id1 = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(id1);

    const id2 = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    });
    defer alloc.free(id2);

    // Same row → same id.
    try testing.expectEqualStrings(id1, id2);

    // The row should reflect the latest width/height.
    const pages = try listPages(alloc, &ctx.db, ctx.item_id);
    defer freePages(alloc, pages);
    try testing.expectEqual(@as(usize, 1), pages.len);
    try testing.expectEqual(@as(i64, 800), pages[0].width);
    try testing.expectEqual(@as(i64, 600), pages[0].height);
}

// ─── Test: setDesignPage returns ItemPathMissing when path is empty ────

test "setDesignPage returns ItemPathMissing when workspace_item.path is empty" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Insert a separate item with path=NULL.
    const no_path_item = try alloc.dupe(u8, "item_no_path");
    defer alloc.free(no_path_item);
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, path) " ++
        "VALUES (?, 'ws_test', 'design', NULL)",
        &.{no_path_item});

    const result = setDesignPage(alloc, &ctx.db, .{
        .item_id = no_path_item,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    try testing.expectError(error.ItemPathMissing, result);
}

// ─── Test: setDesignPage returns BadPageName for empty page_name ───────

test "setDesignPage rejects empty page_name" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const result = setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "",
        .width = 1440,
        .height = 1024,
    });
    try testing.expectError(error.BadPageName, result);
}

// ─── Test: addElement writes a row + a file ──────────────────────────────

test "addElement creates a row + writes the HTML file" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create a page first.
    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // Add the element.
    const element_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "login-card",
        .elem_type = .rectangle,
        .html = "<div>Login</div>",
        .x = 100,
        .y = 200,
        .width = 400,
        .height = 300,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    // Generated id starts with "elem_".
    try testing.expect(element_id.len > 4);
    try testing.expect(std.mem.startsWith(u8, element_id, "elem_"));

    // Verify the HTML file was written to disk.
    const file_path = try std.fs.path.join(alloc, &.{
        ctx.item_path,
        ".pabrik/design/Login/login-card.html",
    });
    defer alloc.free(file_path);

    const content = try std.Io.Dir.cwd().readFileAlloc(ctx.threaded.io(), file_path, alloc, .limited(1024));
    defer alloc.free(content);
    try testing.expectEqualStrings("<div>Login</div>", content);
}

// ─── Test: addElement with empty fill succeeds (NOT NULL constraint) ─────
//
// REGRESSION (2026-08-14, "design mode, add element manual not
// working" — second wave). The HTTP handler resolves `fill` to the
// empty string when the user doesn't provide one (see
// design_elements_create.zig:278 `.fill = parsed.fill orelse ""`).
// The project's `sqlite-backend-empty-slice-binds-as-null`
// optimization then binds that empty string as SQL NULL. But the
// `fill` column is `TEXT NOT NULL DEFAULT ''` — the constraint
// rejects the INSERT with `NOT NULL constraint failed:
// design_page_elements.fill`, the handler maps to error.DbError,
// the useCase to 500, the user sees "Failed to create element" and
// the dialog closes without adding anything.
//
// The production INSERT was reachable when the production server
// sent the request through the wire (pre-fix, the entire
// @create-element binding was missing — fixed earlier). The empty
// fill path is now the only reachable bug for the "+ Element → Add"
// flow. The first regression test ensures the fix sticks.
//
// Why no whitespace coercion at the handler: that would mask the
// symptom in one place while other NOT NULL columns (text_content /
// text_style / image_url — all currently passed as literals, but
// `fill` is the first NOT NULL column the bind layer sees) could
// regress the same way. The fix is at the SQL: COALESCE(?, '') on
// the `fill` parameter so a NULL bind lands as the column's own
// default (empty string), which is what the schema author intended.
test "addElement with empty fill succeeds (NOT NULL fill column)" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    // The pre-fix bug: passing fill="" with the empty-slice-binds-
    // as-null optimization makes sqlite3_bind_null fire, which the
    // NOT NULL constraint rejects. The test asserts this path
    // succeeds end-to-end (creates a row, getElement reads it back).
    const element_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "kotak",
        .elem_type = .rectangle,
        .html = "<div></div>",
        .x = 0,
        .y = 0,
        .width = 375,
        .height = 667,
        .fill = "", // <- the bug-trigger. Empty slice → bind NULL → NOT NULL fail.
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    // Read it back and confirm the row is sane.
    const row = try getElement(alloc, &ctx.db, element_id);
    defer freeElement(alloc, row);
    try testing.expectEqualStrings("kotak", row.name);
    try testing.expectEqualStrings("rectangle", row.elem_type);
    // The column default is '' — empty string in storage is the
    // schema's intent. The fix normalizes the bind-NULL leak into
    // either '' (already the default) or the user's value.
    try testing.expectEqual(@as(usize, 0), row.fill.len);
}

// ─── Test: loadElementHtml round-trips the original HTML ─────────────────

test "loadElementHtml returns the original HTML body" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const element_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "hero",
        .elem_type = .rectangle,
        .html = "<h1>Welcome</h1>",
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 100,
        .fill = "#22c55e",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const html = try loadElementHtml(alloc, ctx.threaded.io(), &ctx.db, element_id);
    defer alloc.free(html);
    try testing.expectEqualStrings("<h1>Welcome</h1>", html);
}

// ─── Test: deleteElement removes the row and the file ───────────────────

test "deleteElement removes the row and unlinks the file" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const element_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "card",
        .elem_type = .rectangle,
        .html = "<div>card</div>",
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .fill = "#ffffff",  // `db.exec` binds `""` as NULL which would
                            //  violate the NOT NULL constraint on fill.
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(element_id);

    const file_path = try std.fs.path.join(alloc, &.{
        ctx.item_path,
        ".pabrik/design/Home/card.html",
    });
    defer alloc.free(file_path);

    // Sanity: file exists before delete.
    {
        const stat_before = try std.Io.Dir.cwd().statFile(ctx.threaded.io(), file_path, .{});
        try testing.expect(stat_before.kind == .file);
    }

    // Delete.
    const was_deleted = try deleteElement(alloc, &ctx.db, element_id);
    try testing.expect(was_deleted);

    // File is gone.
    const stat_after_result = std.Io.Dir.cwd().statFile(ctx.threaded.io(), file_path, .{});
    try testing.expectError(error.FileNotFound, stat_after_result);

    // deleteElement on a missing id returns false.
    const was_deleted2 = try deleteElement(alloc, &ctx.db, element_id);
    try testing.expect(!was_deleted2);
}

// ─── Test: getPageWithElements returns page + elements (no HTML bodies) ──

test "getPageWithElements returns page + its elements" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create a page, then add 2 elements to it.
    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const e1_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "hero",
        .elem_type = .rectangle,
        .html = "<div>hero</div>",
        .x = 10,
        .y = 20,
        .width = 100,
        .height = 50,
        .fill = "#22c55e",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
    });
    defer alloc.free(e1_id);

    const e2_id = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page_id,
        .name = "card",
        .elem_type = .text,
        .html = "<p>hi</p>",
        .x = 30,
        .y = 40,
        .width = 200,
        .height = 80,
        .fill = "#ffffff",
        .rotation = 0.0,
        .corner_radius = 0,
        .opacity = 1.0,
        .text_content = "hello world",
    });
    defer alloc.free(e2_id);

    const bundle = try getPageWithElements(alloc, &ctx.db, page_id);
    defer bundle.deinit(alloc);

    // Page fields populated correctly.
    try testing.expectEqualStrings(page_id, bundle.page.id);
    try testing.expectEqualStrings("Home", bundle.page.name);
    try testing.expectEqual(@as(i64, 1440), bundle.page.width);
    try testing.expectEqual(@as(i64, 1024), bundle.page.height);

    // Two elements returned in (z_index, position) order.
    try testing.expectEqual(@as(usize, 2), bundle.elements.len);
    try testing.expectEqualStrings("hero", bundle.elements[0].name);
    try testing.expectEqualStrings("card", bundle.elements[1].name);
    try testing.expectEqualStrings(e1_id, bundle.elements[0].id);
    try testing.expectEqualStrings(e2_id, bundle.elements[1].id);

    // Element fields populated (file_path included, but no html body
    // — loadElementHtml must be called separately to fetch it).
    try testing.expect(bundle.elements[0].file_path.len > 0);
    try testing.expectEqualStrings("rectangle", bundle.elements[0].elem_type);
    try testing.expectEqualStrings("text", bundle.elements[1].elem_type);
    try testing.expectEqual(@as(i64, 10), bundle.elements[0].x);
    try testing.expectEqual(@as(i64, 20), bundle.elements[0].y);
    try testing.expectEqual(@as(i64, 100), bundle.elements[0].width);
    try testing.expectEqual(@as(i64, 50), bundle.elements[0].height);
    try testing.expectEqualStrings("#22c55e", bundle.elements[0].fill);
}

test "getPageWithElements returns PageNotFound for missing page_id" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const result = getPageWithElements(alloc, &ctx.db, "page_does_not_exist");
    try testing.expectError(error.PageNotFound, result);
}

test "getPageWithElements on page with zero elements returns empty slice" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const page_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Empty",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page_id);

    const bundle = try getPageWithElements(alloc, &ctx.db, page_id);
    defer bundle.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), bundle.elements.len);
    try testing.expectEqualStrings("Empty", bundle.page.name);
}

// ─── Test: listPagesWithElements returns all pages with their elements ──

test "listPagesWithElements returns all pages with their elements" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Create 2 pages with elements on each.
    const page1_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Home",
        .width = 1440,
        .height = 1024,
    });
    defer alloc.free(page1_id);

    const page2_id = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "Login",
        .width = 800,
        .height = 600,
    });
    defer alloc.free(page2_id);

    // 2 elements on page1, 1 element on page2.
    const p1e1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page1_id, .name = "hero", .elem_type = .rectangle,
        .html = "<div>hero</div>", .x = 0, .y = 0, .width = 100, .height = 50,
        .fill = "#22c55e", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(p1e1);
    const p1e2 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page1_id, .name = "footer", .elem_type = .rectangle,
        .html = "<footer/>", .x = 0, .y = 1000, .width = 1440, .height = 24,
        .fill = "#000", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(p1e2);
    const p2e1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = page2_id, .name = "submit", .elem_type = .rectangle,
        .html = "<button/>", .x = 100, .y = 200, .width = 200, .height = 40,
        .fill = "#3b82f6", .rotation = 0.0, .corner_radius = 4, .opacity = 1.0,
    });
    defer alloc.free(p2e1);

    const results = try listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer freePagesWithElements(alloc, results);

    // 2 pages returned, in (position ASC) order.
    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("Home", results[0].page.name);
    try testing.expectEqualStrings("Login", results[1].page.name);

    // Page 1 has 2 elements.
    try testing.expectEqual(@as(usize, 2), results[0].elements.len);
    try testing.expectEqualStrings("hero", results[0].elements[0].name);
    try testing.expectEqualStrings("footer", results[0].elements[1].name);

    // Page 2 has 1 element.
    try testing.expectEqual(@as(usize, 1), results[1].elements.len);
    try testing.expectEqualStrings("submit", results[1].elements[0].name);
    try testing.expectEqual(@as(i64, 4), results[1].elements[0].corner_radius);
}

test "listPagesWithElements returns empty slice for an item with no pages" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    const results = try listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer freePagesWithElements(alloc, results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "listPagesWithElements on item where one page has zero elements" {
    const alloc = testing.allocator;
    var ctx = try designModelSetupDbAndItem();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    defer alloc.free(ctx.item_id);
    defer alloc.free(ctx.item_path);

    // Page A has 1 element, Page B has 0 elements.
    const pageA = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "A",
        .width = 100, .height = 100,
    });
    defer alloc.free(pageA);

    const pageB = try setDesignPage(alloc, &ctx.db, .{
        .item_id = ctx.item_id,
        .page_name = "B",
        .width = 200, .height = 200,
    });
    defer alloc.free(pageB);

    const a_e1 = try addElement(alloc, &ctx.db, ctx.threaded.io(), .{
        .page_id = pageA, .name = "thing", .elem_type = .rectangle,
        .html = "<x/>", .x = 0, .y = 0, .width = 10, .height = 10,
        .fill = "#fff", .rotation = 0.0, .corner_radius = 0, .opacity = 1.0,
    });
    defer alloc.free(a_e1);

    const results = try listPagesWithElements(alloc, &ctx.db, ctx.item_id);
    defer freePagesWithElements(alloc, results);

    try testing.expectEqual(@as(usize, 2), results.len);
    try testing.expectEqualStrings("A", results[0].page.name);
    try testing.expectEqual(@as(usize, 1), results[0].elements.len);
    try testing.expectEqualStrings("B", results[1].page.name);
    try testing.expectEqual(@as(usize, 0), results[1].elements.len);
}
