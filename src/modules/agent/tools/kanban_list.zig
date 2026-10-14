const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;

/// One column summary row in the kanban tool output. Mirrors
/// `kanban_model.KanbanColumn` field-for-field so the LLM sees the
/// same shape it would see from the HTTP endpoint (minus the
/// `created_at` audit field, which the LLM doesn't need).
pub const ColumnSummary = struct {
    id: []const u8,
    name: []const u8,
    position: i64,
    /// Number of tasks currently in this column. Computed from the
    /// task list (1 query each, joined client-side) so the LLM can
    /// answer "is anything in 'done'?" without a follow-up tool call.
    task_count: u32,
};

/// One task summary row in the kanban tool output. `column_id` and
/// `column_name` are null when the task is unassigned (its column
/// was deleted — see `kanban_model.deleteColumn` which sets
/// `kanban_column_id = NULL`).
pub const TaskSummary = struct {
    id: []const u8,
    name: []const u8,
    column_id: ?[]const u8,
    column_name: ?[]const u8,
    position: i64,
};

/// One task row read directly from the DB. `kanban_column_id` may be
/// an empty string when the task is unassigned (the DB column is
/// nullable). Internal — freed with `freeKanbanTaskRows`.
pub const KanbanTaskRow = struct {
    id: []u8,
    name: []u8,
    kanban_column_id: []u8,
    kanban_position: i64,
};

pub fn freeKanbanTaskRows(allocator: std.mem.Allocator, rows: []KanbanTaskRow) void {
    for (rows) |r| {
        allocator.free(r.id);
        allocator.free(r.name);
        allocator.free(r.kanban_column_id);
    }
    allocator.free(rows);
}

/// Input structure for kanban_list tool.
///
/// The agent should pass `workspace_id` + `item_id` from the active
/// chat context (injected by the frontend into the system prompt —
/// see `BuildWorkspaceContext` in
/// `src/ai_workflow/tui/prompts_build_messages_for_agent_prompt.zig`). The
/// LLM is told in the description that the active kanban is
/// discoverable from the chat's workspace context.
pub const KanbanListInput = struct {
    /// The workspace that owns the kanban item. Injected from chat
    /// context (the "active workspace_id" in the system prompt's
    /// `## Workspace Context` section).
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. Injected from chat context when
    /// the user is viewing a kanban.
    item_id: []const u8 = "",
    /// Optional: when set, only return tasks assigned to this column.
    /// Useful for "list tasks in 'done' column" queries.
    column_id: ?[]const u8 = null,
    /// Optional: max tasks to return. Default 20, max 100. Use with offset for pagination.
    limit: ?u32 = null,
    /// Optional: offset for pagination. Default 0. Use with limit to page through large boards.
    offset: ?u32 = null,
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// says the workspace_id + item_id come from the active chat's
/// workspace context.
pub const kanban_list_tool_system_prompt =
    \\## Kanban List Tool — Behavior
    \\Use `kanban_list` to list kanban board structure: columns and tasks.
    \\- Call first to discover `task_id` and `column_id` before moving a task.
    \\- Requires `workspace_id` + `item_id` from Workspace Context.
    \\
;

pub const kanban_list_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "kanban_list",
        .description =
        \\List a kanban board's structure: every column (with its task count) and every task (with its column assignment + position). Use it for "what's in the done column?" or to discover a task's id before `kanban_move_task`.
        \\
        \\`workspace_id` and `item_id` come from the `## Workspace Context` section of the system prompt — the kanban being viewed is the entry marked `*(this task)*`. Ids are the backtick-quoted value after `id: ` (e.g. `item_1782313125507292140`) and are the canonical lookup key: never pass the human-readable name, which matches zero rows. If there is no Workspace Context section, ask the user for the kanban's id.
        \\
        \\`column_id` narrows the task list to one column; omit it for all tasks. Paging: `limit` (default 20, max 100) and `offset` (default 0) — check `total_count` and `has_more` in the response.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban — the active workspace_id in the system prompt's `## Workspace Context` section.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name): the backtick-quoted id after `id: ` in the Workspace Context listing (e.g. `item_1782313125507292140`).",
                },
                .{
                    .name = "column_id",
                    .type = "string",
                    .description = "Optional: only return tasks in this specific column. Omit to get all tasks.",
                },
                .{
                    .name = "limit",
                    .type = "integer",
                    .description = "Optional: max tasks to return. Default 20, max 100.",
                },
                .{
                    .name = "offset",
                    .type = "integer",
                    .description = "Optional: offset for pagination. Default 0.",
                },
            },
            .required = &.{ "workspace_id", "item_id" },
        },
        .system_prompt = kanban_list_tool_system_prompt,
    },
};

/// Read all tasks for a kanban item from the DB. Includes
/// `kanban_column_id` + `kanban_position` (the HTTP endpoint
/// `GET /tasks` does NOT include these — see project memory
/// `pabrik-image-urls-vs-image-url` for the parallel image_url
/// situation). The list is ordered by (column_id, position) so the
/// LLM sees tasks in board-reading order.
///
/// Caller owns the returned slice and must release it with
/// `freeKanbanTaskRows`.
pub fn countKanbanTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: ?[]const u8,
) !u32 {
    if (column_id) |cid| {
        var q = try db.query(allocator,
            \\SELECT COUNT(*)
            \\FROM workspace_item_tasks t
            \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
            \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
        , &.{ workspace_item_id, cid });
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        }
        return 0;
    } else {
        var q = try db.query(allocator,
            \\SELECT COUNT(*)
            \\FROM workspace_item_tasks t
            \\WHERE t.workspace_item_id = ?
        , &.{workspace_item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        }
        return 0;
    }
}

pub fn listKanbanTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: ?[]const u8,
    limit: ?u32,
    offset: ?u32,
) ![]KanbanTaskRow {
    // Build query with optional column filter + pagination
    var q = if (column_id) |cid| blk: {
        if (limit) |lim| {
            const off = offset orelse 0;
            var lim_buf: [16]u8 = undefined;
            var off_buf: [16]u8 = undefined;
            const lim_str = std.fmt.bufPrint(&lim_buf, "{d}", .{lim}) catch "20";
            const off_str = std.fmt.bufPrint(&off_buf, "{d}", .{off}) catch "0";
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
                \\LIMIT ? OFFSET ?
            , &.{ workspace_item_id, cid, lim_str, off_str });
        } else {
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
            , &.{ workspace_item_id, cid });
        }
    } else blk: {
        if (limit) |lim| {
            const off = offset orelse 0;
            var lim_buf: [16]u8 = undefined;
            var off_buf: [16]u8 = undefined;
            const lim_str = std.fmt.bufPrint(&lim_buf, "{d}", .{lim}) catch "20";
            const off_str = std.fmt.bufPrint(&off_buf, "{d}", .{off}) catch "0";
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
                \\LIMIT ? OFFSET ?
            , &.{ workspace_item_id, lim_str, off_str });
        } else {
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
            , &.{workspace_item_id});
        }
    };
    defer q.deinit();

    var rows = std.ArrayList(KanbanTaskRow).empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.id);
            allocator.free(r.name);
            allocator.free(r.kanban_column_id);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        const pos = std.fmt.parseInt(i64, row.values[3], 10) catch -1;
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .kanban_column_id = try allocator.dupe(u8, row.values[2]),
            .kanban_position = pos,
        });
    }
    return try rows.toOwnedSlice(allocator);
}

/// Resolve a column name to its id via a case-insensitive trimmed
/// match. Returns the first match or null. Used by
/// `executeKanbanListToJSON` to populate `column_name` in the
/// task summary output.
fn resolveColumnIdToName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !?[]u8 {
    var q = try db.query(
        allocator,
        "SELECT kc.name FROM kanban_columns kc WHERE kc.workspace_item_id = ? AND kc.id = ?",
        &.{ workspace_item_id, column_id },
    );
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Execute the kanban_list tool. Returns a JSON string for the LLM.
///
/// Response shape (the `data` field that `wrapToolOutput` puts inside
/// `<tool>...<data>...</data></tool>`):
///   {"workspace_id":...,"item_id":...,
///    "columns":[{"id":...,"name":...,"position":...,"task_count":...}, ...],
///    "tasks":[{"id":...,"name":...,
///               "column_id":... (or null when unassigned),
///               "column_name":... (or null when unassigned),
///               "position":...}, ...],
///    "total_count":...,"limit":...,"offset":...,"has_more":...,
///    "hint":... (or null)}
///
/// Error cases (encoded as {"error":...} so the LLM sees a structured failure):
///   - workspace_id or item_id is empty
///   - item_id has a known-wrong prefix (task_/col_/ws_), with a
///     self-correcting hint pointing at the Workspace Context listing
///   - item_id is well-formed (starts with "item_") but no matching
///     workspace_item of type 'kanban' exists
///   - The kanban exists but has 0 columns: a friendly hint (NOT an error)
///     so the LLM can distinguish "wrong item_id" from "empty board"
///   - DB read failure: {"error":"DB: ..."}
pub fn executeKanbanListToJSON(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: KanbanListInput,
) ![]u8 {
    // 1. Validate shape (catches task_id/col_id/ws_id passed as item_id).
    //    Returns either null (shape OK) or an owned error JSON slice.
    if (try validateItemIdShape(allocator, input.item_id, input.workspace_id)) |err_xml| {
        return err_xml;
    }

    // 2. Validate the item exists in the DB AND is a kanban. The shape
    //    check above only inspects the prefix; this catches typos and
    //    cross-item-type confusion (e.g., passing a folder's item_id
    //    to kanban_list). When the item doesn't exist, return a clear
    //    error so the LLM can re-fetch the workspace context.
    const exists = itemExists(allocator, db, input.item_id) catch |err| {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: itemExists failed: {s}", .{@errorName(err)}));
    };
    if (!exists) {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' matches no workspace_item (or the item isn't a kanban). Verify the id from the Workspace Context listing — the active kanban (if any) is the one marked `*(this task)*`.
        , .{input.item_id}));
    }

    // 3. Read columns (sorted by position).
    const cols = pabrikcore.ai_mod.kanban_model.listColumns(allocator, db, input.item_id) catch |err| {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listColumns failed: {s}", .{@errorName(err)}));
    };
    defer pabrikcore.ai_mod.kanban_model.freeColumns(allocator, cols);

    // 4. If the kanban is well-formed but legitimately has no columns
    //    (user deleted them all), surface that as a structured hint so
    //    the LLM can distinguish from "wrong item_id". Empty XML
    //    without this hint looks identical to the bug we're fixing.
    //    Note: NOT wrapped in <error> — the kanban is valid, just empty.
    const empty_board_hint: ?[]u8 = if (cols.len == 0) blk: {
        const h = try std.fmt.allocPrint(allocator,
            \\This kanban item has no columns (0 columns). The user may have deleted all columns, or the kanban was just created and columns haven't been seeded yet. Ask the user, or call kanban_list with a different item_id.
        , .{});
        break :blk h;
    } else null;
    defer if (empty_board_hint) |h| allocator.free(h);

    // 5. Pagination: clamp limit/offset, fetch total + page
    const effective_limit: u32 = blk: {
        const raw = input.limit orelse 20;
        if (raw == 0) break :blk 20;
        if (raw > 100) break :blk 100;
        break :blk raw;
    };
    const effective_offset: u32 = input.offset orelse 0;

    const total_count = countKanbanTasks(allocator, db, input.item_id, input.column_id) catch 0;

    // 6. Read tasks (paginated, optionally filtered by column_id)
    const task_rows = listKanbanTasks(allocator, db, input.item_id, input.column_id, effective_limit, effective_offset) catch |err| {
        return errorJSONOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listTasks failed: {s}", .{@errorName(err)}));
    };
    defer freeKanbanTaskRows(allocator, task_rows);

    // 7. Build column summary array (with task_count = total per column)
    var column_summaries = std.ArrayList(ColumnSummary).empty;
    defer column_summaries.deinit(allocator);
    for (cols) |c| {
        const count = countKanbanTasks(allocator, db, input.item_id, c.id) catch 0;
        try column_summaries.append(allocator, .{
            .id = c.id,
            .name = c.name,
            .position = c.position,
            .task_count = count,
        });
    }

    // 8. Build task summary array (already filtered + paginated at DB level)
    const filtered: []const KanbanTaskRow = task_rows;

    var task_summaries = std.ArrayList(TaskSummary).empty;
    defer task_summaries.deinit(allocator);
    // Track every allocated col_name so we can free them all AFTER
    // toJSON() reads the task_summaries. The earlier version of this
    // code used `defer if (col_name) |n| allocator.free(n);` INSIDE
    // the for-loop, but Zig's `defer` fires at the end of the
    // iteration block — so the slice was freed BEFORE toJSON was
    // called, leaving `task_summaries` with dangling pointers. The
    // AI then read freed memory (Zig debug allocator's 0xAA free-fill
    // pattern shows up in the column_name) and interpreted the
    // garbled output as "empty board". See project memory
    // `zig-slice-headers-across-defer-lifetimes.md`.
    var col_names_owned = std.ArrayList([]u8).empty;
    defer {
        for (col_names_owned.items) |n| allocator.free(n);
        col_names_owned.deinit(allocator);
    }
    for (filtered) |t| {
        const col_id: ?[]const u8 = if (t.kanban_column_id.len > 0) t.kanban_column_id else null;
        const col_name: ?[]const u8 = if (col_id) |cid| blk: {
            const name = resolveColumnIdToName(allocator, db, input.item_id, cid) catch null;
            if (name) |n| {
                col_names_owned.append(allocator, n) catch {
                    allocator.free(n);
                    break :blk @as(?[]const u8, null);
                };
            }
            break :blk if (name) |n| n else null;
        } else null;
        try task_summaries.append(allocator, .{
            .id = t.id,
            .name = t.name,
            .column_id = col_id,
            .column_name = col_name,
            .position = t.kanban_position,
        });
    }

    // 9. Render the JSON payload with pagination metadata. The
    // empty-board hint rides along as the "hint" key (null otherwise).
    const has_more = (effective_offset + @as(u32, @intCast(task_summaries.items.len)) < total_count);
    return toJSON(allocator, input.workspace_id, input.item_id, column_summaries.items, task_summaries.items, total_count, effective_limit, effective_offset, has_more, empty_board_hint);
}

/// One task in the kanban tool output. Keys mirror the old `<task>`
/// child tags 1:1; `column_id`/`column_name` are explicit nulls when the
/// task is unassigned (instead of empty tags).
pub const TaskJSON = struct {
    id: []const u8,
    name: []const u8,
    column_id: ?[]const u8,
    column_name: ?[]const u8,
    position: i64,
};

/// Success payload for `kanban_list`. Tag names from the old `<kanban>`
/// envelope become keys 1:1; repeated elements are arrays; the
/// empty-board hint is an explicit null when absent.
pub const KanbanListJSON = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    columns: []const ColumnSummary,
    tasks: []const TaskJSON,
    total_count: u32,
    limit: u32,
    offset: u32,
    has_more: bool,
    hint: ?[]const u8,
};

/// Error payload for `kanban_list`.
pub const KanbanListError = struct {
    @"error": []const u8,
};

/// Serialize the kanban structure to a JSON string for the LLM.
/// Caller owns the returned slice.
pub fn toJSON(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    item_id: []const u8,
    columns: []const ColumnSummary,
    tasks: []const TaskSummary,
    total_count: u32,
    limit: u32,
    offset: u32,
    has_more: bool,
    hint: ?[]const u8,
) ![]u8 {
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |b| allocator.free(b);
        owned.deinit(allocator);
    }

    var clean_columns = try allocator.alloc(ColumnSummary, columns.len);
    defer allocator.free(clean_columns);
    for (columns, 0..) |c, i| {
        const name = try sanitizeControlChars(allocator, c.name);
        try owned.append(allocator, name);
        clean_columns[i] = .{
            .id = c.id,
            .name = name,
            .position = c.position,
            .task_count = c.task_count,
        };
    }

    var clean_tasks = try allocator.alloc(TaskJSON, tasks.len);
    defer allocator.free(clean_tasks);
    for (tasks, 0..) |t, i| {
        const name = try sanitizeControlChars(allocator, t.name);
        try owned.append(allocator, name);
        var clean_col_name: ?[]const u8 = null;
        if (t.column_name) |cn| {
            const clean = try sanitizeControlChars(allocator, cn);
            try owned.append(allocator, clean);
            clean_col_name = clean;
        }
        clean_tasks[i] = .{
            .id = t.id,
            .name = name,
            .column_id = t.column_id,
            .column_name = clean_col_name,
            .position = t.position,
        };
    }

    var clean_hint: ?[]const u8 = null;
    if (hint) |h| {
        const clean = try sanitizeControlChars(allocator, h);
        try owned.append(allocator, clean);
        clean_hint = clean;
    }

    return std.json.Stringify.valueAlloc(allocator, KanbanListJSON{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .columns = clean_columns,
        .tasks = clean_tasks,
        .total_count = total_count,
        .limit = limit,
        .offset = offset,
        .has_more = has_more,
        .hint = clean_hint,
    }, .{});
}

/// Generate an error JSON payload. Used when input validation or
/// the DB read fails. Mirrors the `xmlError` pattern in
/// `set_git_worktree.zig` / `add_skill.zig`.
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, KanbanListError{
        .@"error" = clean,
    }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees
/// it on any path. Used to avoid leaks when the caller's message
/// is an `allocPrint` result (can't `defer` across a `return`).
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);
    return errorJSON(allocator, error_msg);
}

/// Parsed shape of `executeKanbanListToJSON` output, for tests.
pub const KanbanListOutput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    columns: []ColumnSummary,
    tasks: []TaskJSON,
    total_count: u32,
    limit: u32,
    offset: u32,
    has_more: bool,
    hint: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Detect the three known LLM id-confusion mistakes (task_id,
/// column_id, workspace_id passed where item_id was expected). Returns
/// null when the shape looks correct, or a structured error XML
/// describing the exact mistake + the canonical id source.
///
/// This runs BEFORE the DB query so the LLM gets a fast, typed
/// error instead of a silent empty board. Empty input is also
/// caught here (mirrors the existing "workspace_id and item_id are
/// required" guard) so the LLM gets one consistent error path.
///
/// The mistake hints deliberately show the canonical id source
/// ("see Workspace Context", "item_id: `item_...`") so the LLM can
/// self-correct on the next call.
pub fn validateItemIdShape(
    allocator: std.mem.Allocator,
    item_id: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (item_id.len == 0 or workspace_id.len == 0) {
        return try errorJSON(allocator, "workspace_id and item_id are required");
    }
    // The DB-generated ids use these prefixes (see workspace_items_create.zig's
    // generateItemId, workspace_item_tasks_create.zig, kanban_model.generateColumnId,
    // workspaces_create.zig). Anything with the wrong prefix is a shape mistake.
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "col_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a COLUMN id (starts with 'col_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "ws_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a WORKSPACE id (starts with 'ws_'). You probably swapped workspace_id and item_id. The KANBAN's item_id starts with 'item_' — find it next to the literal text `item_id: ` in the Workspace Context listing.
        , .{item_id}));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorJSONOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Workspace-scoped tools expect a kanban item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}

/// Verify the item_id corresponds to a real `workspace_items` row of
/// type 'kanban'. Returns true if the row exists AND is a kanban,
/// false if it doesn't exist OR is a different item_type. Used to
/// distinguish "item_id is well-formed but doesn't exist" from
/// "item_id is well-formed, exists, but has no columns (degenerate
/// empty board)" so the LLM gets a different error message in each
/// case.
///
/// Cheap query (indexed PK lookup). Called only AFTER
/// `validateItemIdShape` passes, so we know the input has the
/// correct `item_` prefix.
fn itemExists(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) !bool {
    var q = try db.query(allocator, "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban' LIMIT 1", &.{item_id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(allocator);
        return true;
    }
    return false;
}

const testing = std.testing;
const kanban_list = @import("kanban_list.zig");
const kanban_model = pabrikcore.ai_mod.kanban_model;
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── JSON serialization behavioral tests (no DB required) ───────────────

test "toJSON on empty lists produces empty arrays and null hint" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = &[_]kanban_list.TaskSummary{};
    const json = try kanban_list.toJSON(alloc, "ws_1", "item_1", cols, tasks, 0, 20, 0, false, null);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ws_1", parsed.value.workspace_id);
    try std.testing.expectEqualStrings("item_1", parsed.value.item_id);
    // No columns or tasks for empty lists
    try std.testing.expectEqual(@as(usize, 0), parsed.value.columns.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tasks.len);
    try std.testing.expect(parsed.value.hint == null);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "toJSON renders column summaries with id/name/position/task_count" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_todo", .name = "todo", .position = 0, .task_count = 2 },
        .{ .id = "col_done", .name = "done", .position = 1, .task_count = 1 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const json = try kanban_list.toJSON(alloc, "ws_1", "item_1", &cols, tasks, 0, 20, 0, false, null);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.columns.len);
    try std.testing.expectEqualStrings("col_todo", parsed.value.columns[0].id);
    try std.testing.expectEqualStrings("todo", parsed.value.columns[0].name);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.columns[0].position);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.columns[0].task_count);
    try std.testing.expectEqualStrings("done", parsed.value.columns[1].name);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.columns[1].task_count);
}

test "toJSON renders task summaries with explicit-null column_id/column_name" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = [_]kanban_list.TaskSummary{
        .{ .id = "t_a", .name = "Task A", .column_id = "col_todo", .column_name = "todo", .position = 0 },
        .{ .id = "t_b", .name = "Task B", .column_id = null, .column_name = null, .position = -1 },
    };
    const json = try kanban_list.toJSON(alloc, "ws_1", "item_1", cols, &tasks, 2, 20, 0, false, null);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("t_a", parsed.value.tasks[0].id);
    try std.testing.expectEqualStrings("Task A", parsed.value.tasks[0].name);
    try std.testing.expectEqualStrings("col_todo", parsed.value.tasks[0].column_id orelse "");
    try std.testing.expectEqualStrings("todo", parsed.value.tasks[0].column_name orelse "");
    // Unassigned task has explicit null column_id/column_name (NOT absent).
    try std.testing.expect(parsed.value.tasks[1].column_id == null);
    try std.testing.expect(parsed.value.tasks[1].column_name == null);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.total_count);
}

test "toJSON keeps raw characters in column + task names" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_x", .name = "in <review>", .position = 0, .task_count = 0 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const json = try kanban_list.toJSON(alloc, "ws_1", "item_1", &cols, tasks, 0, 20, 0, false, null);
    defer alloc.free(json);
    // Raw text needs no escaping in JSON — parse and compare verbatim.
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("in <review>", parsed.value.columns[0].name);
}

test "errorJSON on missing field returns parsed error payload" {
    const alloc = testing.allocator;
    const json = try kanban_list.errorJSON(alloc, "workspace_id and item_id are required");
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListError, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("workspace_id and item_id are required", parsed.value.@"error");
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the kanban tables + a kanban
/// workspace item + 3 default columns (todo/in progress/done).
///
/// Returns the db + threaded as a value (not a pointer) so the
/// caller can `var s = try setupDb();` and pass `&s.db` to
/// non-const-`*SqliteBackend` parameters — exactly the pattern from
/// `kanban_model_test.zig`. Returns an unnamed struct so the
/// caller's `var s` infers the fields.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspaces
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // workspace_items
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // kanban_columns (mirrors Migration 051)
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // workspace_item_tasks (post-Migration-072: no kanban_column_id or
    // kanban_position columns — those live in the `kanban` join table)
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  session_id TEXT,
        \\  task_type TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    // Insert one workspace + one kanban item + 3 columns.
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_1', 'ws_1', 'kanban', 'Sprint board')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_todo', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_ip', 'item_1', 'in progress', 1)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_done', 'item_1', 'done', 2)", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "listKanbanTasks returns all tasks with column + position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Two tasks in todo, one in done, one unassigned.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t4', 'item_1', 'Task 4 unassigned', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});
    // t4 has no kanban row — unassigned (the LEFT JOIN surfaces this as
    // empty kanban_column_id in the JSON output)

    const rows = try kanban_list.listKanbanTasks(alloc, &s.db, "item_1", null, null, null);
    defer kanban_list.freeKanbanTaskRows(alloc, rows);

    try testing.expectEqual(@as(usize, 4), rows.len);
    // Unassigned task has empty kanban_column_id (the COALESCE
    // maps NULL → '').
    var unassigned_found = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.id, "t4")) {
            try testing.expectEqual(@as(usize, 0), r.kanban_column_id.len);
            try testing.expectEqual(@as(i64, -1), r.kanban_position);
            unassigned_found = true;
        }
    }
    try testing.expect(unassigned_found);
}

test "executeKanbanListToJSON returns columns with task_count" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // 2 in todo, 1 in done.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.columns.len);
    // todo has 2 tasks
    try std.testing.expectEqualStrings("col_todo", parsed.value.columns[0].id);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.columns[0].task_count);
    // in progress has 0 tasks
    try std.testing.expectEqualStrings("col_ip", parsed.value.columns[1].id);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.columns[1].task_count);
    // done has 1 task
    try std.testing.expectEqualStrings("col_done", parsed.value.columns[2].id);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.columns[2].task_count);
}

test "executeKanbanListToJSON with column_id filter returns only that column's tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .column_id = "col_todo",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);

    // Both todo tasks should appear
    try testing.expect(contains(json, "\"name\":\"Task 1\""));
    try testing.expect(contains(json, "\"name\":\"Task 2\""));
    // Done task should NOT appear
    try testing.expect(!contains(json, "\"name\":\"Task 3\""));
}

test "executeKanbanListToJSON returns error JSON when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "workspace_id and item_id are required"));
}

// Regression test for the use-after-free bug fixed in this branch.
// Before the fix, `defer if (col_name) |n| allocator.free(n);` inside
// the for-loop fired at the end of EACH iteration — so the col_name
// slice was freed BEFORE toJSON() was called, leaving task_summaries
// with dangling pointers. The AI then read the freed memory (Zig's
// 0xAA debug-allocator free-fill pattern) and interpreted the garbled
// output as "empty board".
//
// This test inserts a task assigned to a column and asserts the
// rendered JSON contains the real column_name, not 0xAA bytes.
test "executeKanbanListToJSON column_name is real bytes (use-after-free regression)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // setupDb() inserts 3 default columns (todo/in progress/done).
    // Add one task assigned to the "in progress" column.
    try s.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type)
        \\VALUES ('t_uaf', 'item_1', 'Task Under Test', 'standard')
    , &.{});
    try s.db.exec(alloc,
        \\INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
        \\VALUES ('t_uaf', 'col_ip', 0)
    , &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);

    // The task's column_name must be the literal string "in progress",
    // not freed/garbled memory. If the use-after-free bug recurs, the
    // slice would point at Zig's 0xAA free-fill pattern.
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("in progress", parsed.value.tasks[0].column_name orelse "");
    try std.testing.expectEqualStrings("col_ip", parsed.value.tasks[0].column_id orelse "");

    // Defensive: assert the rendered JSON does NOT contain the 0xAA
    // free-fill byte (octal 252 = 0xAA). If it does, the slice
    // header is pointing at freed memory.
    try testing.expect(std.mem.indexOfScalar(u8, json, 0xAA) == null);
}

// ─── Input validation tests (4 mistake shapes + empty-board hint) ──────

test "executeKanbanListToJSON returns error JSON when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // AI confused task_id (from kanban_move_task input) with item_id.
    // listColumns will silently return 0 rows; we want validation to
    // catch this BEFORE the query runs.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "task_1782442569739",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "item_id"));
    try testing.expect(contains(json, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(json, "item_"));
}

test "executeKanbanListToJSON returns error JSON when item_id looks like a column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "col_1782442554112968570",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "col_"));
}

test "executeKanbanListToJSON returns error JSON when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "ws_1",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"error\":"));
}

test "executeKanbanListToJSON returns error JSON when item_id matches no workspace_item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Valid shape (starts with item_) but the row doesn't exist.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_does_not_exist",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "no workspace_item"));
}

test "executeKanbanListToJSON returns empty-board hint (not error) when item_id is valid but has no columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert a kanban item with NO columns (degenerate case — user
    // deleted all of them).
    try s.db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_empty', 'ws_1', 'kanban', 'Empty board')", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_empty",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    // NOT an error — the kanban genuinely has no columns. Just an
    // empty "columns" array + a friendly hint.
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.@"error" == null);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.columns.len);
    // Hint: "no columns" so the LLM can distinguish from a wrong-id case.
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.hint orelse "", "no columns") != null);
}

test "executeKanbanListToJSON default limit caps at 20" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert 30 tasks
    for (0..30) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    // Default limit 20 => only 20 tasks in JSON, but total_count 30
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 30), parsed.value.total_count);
    try std.testing.expectEqual(@as(u32, 20), parsed.value.limit);
    try std.testing.expect(parsed.value.has_more);
    try std.testing.expectEqual(@as(usize, 20), parsed.value.tasks.len);
}

test "executeKanbanListToJSON limit=5 returns 5 tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..10) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 5,
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 10), parsed.value.total_count);
    try std.testing.expectEqual(@as(u32, 5), parsed.value.limit);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.tasks.len);
}

test "executeKanbanListToJSON offset paginates" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..10) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 5,
        .offset = 5,
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 5), parsed.value.offset);
    try std.testing.expect(!parsed.value.has_more);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.tasks.len);
}

test "executeKanbanListToJSON limit >100 clamped to 100" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..5) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 200,
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    try testing.expect(contains(json, "\"limit\":100"));
}

test "executeKanbanListToJSON offset beyond total returns empty tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 10,
        .offset = 100,
    };
    const json = try kanban_list.executeKanbanListToJSON(alloc, &s.db, input);
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(kanban_list.KanbanListOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.total_count);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tasks.len);
    try std.testing.expect(!parsed.value.has_more);
}
