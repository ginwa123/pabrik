//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;

/// Default page size when the client doesn't pass `limit`.
const DEFAULT_PAGE_SIZE: u32 = 20;

/// Maximum page size (guards against a client asking for a million rows).
const MAX_PAGE_SIZE: u32 = 100;

/// Default sort field when the client doesn't pass `sort_by`.
/// `updated_at` is the default because that's what the user wants
/// to see (most recently renamed/updated task on top).
const DEFAULT_SORT_FIELD: llm_history.TaskSortField = .updated_at;

/// Default sort direction when the client doesn't pass `direction`.
/// `desc` matches the existing "newest first" behavior.
const DEFAULT_SORT_DIRECTION: llm_history.TaskSortDirection = .desc;

pub const TasksListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `std.json.Stringify.valueAlloc` / `makeWorkspaceItemTaskListResponse`
    /// can fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const TasksListInput = struct {
    item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: llm_history.TaskSortField,
    sort_direction: llm_history.TaskSortDirection,
    /// Per-column pagination filter (kanban-per-column-pagination,
    /// 2026-08-06).
    column_id: ?[]const u8,
    /// Optional case-insensitive substring filter applied at the SQL level
    /// against `name`, `description`, `tags`. Null / empty → no filter
    /// (matches the historical behaviour).
    q: ?[]const u8,
};

pub const TasksListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Parse the query string into the typed input. Defaults + clamping +
/// enum-from-string parsing all happen here. Kept as a free function so the
/// use-case body stays focused on the DB work.
fn parseInput(query: anytype) TasksListInput {
    const limit_str = query.get("limit") orelse "20";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_PAGE_SIZE;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_PAGE_SIZE
    else if (limit_parsed > MAX_PAGE_SIZE)
        MAX_PAGE_SIZE
    else
        limit_parsed;

    const sort_by_str = query.get("sort_by") orelse "updated_at";
    const sort_field = llm_history.enumFromString(llm_history.TaskSortField, sort_by_str) catch DEFAULT_SORT_FIELD;

    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.TaskSortDirection, direction_str) catch DEFAULT_SORT_DIRECTION;

    // Optional cursor — null when absent or empty. The cursor is the
    // "<sort_value>|<id>" pair from the previous page's next_cursor.
    // We forward it raw to the DB fn which knows how to split it.
    const cursor_raw = query.get("cursor");
    const cursor: ?[]const u8 = if (cursor_raw) |c| (if (c.len == 0) null else c) else null;

    // Optional q (search) — null when absent or empty. Empty string is
    // treated identically to "no q param" so the URL ?q= (empty value)
    // behaves the same as no q at all.
    const q_raw = query.get("q");
    const q: ?[]const u8 = if (q_raw) |q_val| (if (q_val.len == 0) null else q_val) else null;

    // Optional column_id (per-column pagination, 2026-08-06). Same
    // null-or-empty semantics as `q`: an empty `?column_id=` is
    // identical to omitting the param.
    const column_id_raw = query.get("column_id");
    const column_id: ?[]const u8 = if (column_id_raw) |c| (if (c.len == 0) null else c) else null;

    return .{
        .item_id = "", // set by the handler (path param)
        .limit = limit,
        .cursor = cursor,
        .sort_field = sort_field,
        .sort_direction = sort_direction,
        .column_id = column_id,
        .q = q,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    io: std.Io,
    input: TasksListInput,
) TasksListError!TasksListResult {
    const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(
        allocator,
        db,
        input.item_id,
        input.limit,
        input.cursor,
        input.sort_field,
        input.sort_direction,
        input.column_id,
        input.q,
    ) catch return error.QueryFailed;
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Kanban-task-git-branch (plan:
    // docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
    const item_path = fetchWorkspaceItemPath(allocator, db, input.item_id) catch "";
    defer if (item_path.len > 0) allocator.free(item_path);

    // Migration 111 — ONE query for the whole page (per-task would be N+1).
    // The edges and the per-task field arrays are freed by the defers at the
    // end of the function, i.e. after the response JSON has copied them.
    const dep_edges = ai_mod.kanban_deps.listEdgesForItem(allocator, db, input.item_id) catch
        return error.QueryFailed;
    defer ai_mod.kanban_deps.freeEdges(allocator, dep_edges);

    var dep_scratch: std.ArrayList(http_response.TaskDependencyFields) = .empty;
    defer {
        for (dep_scratch.items) |fields| {
            allocator.free(fields.depends_on);
            allocator.free(fields.blocked_by);
        }
        dep_scratch.deinit(allocator);
    }

    // Convert to response format.
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        // Compute git_branch for this task's cwd.
        // Prefer the task's worktree cwd; fall back to the item path.
        // Empty string when neither is set → no badge on the frontend.
        const cwd = if (task.git_worktree_cwd.len > 0)
            task.git_worktree_cwd
        else
            item_path;
        const git_branch: ?[]const u8 = blk: {
            if (cwd.len == 0) break :blk null;
            const branch = resolveGitBranch(allocator, io, cwd);
            if (branch.len == 0) break :blk null;
            break :blk branch;
        };

        // Migration 111 — this task's dependencies, split into "what I wait
        // for" and "what is still in the way".
        const dep_fields = http_response.makeTaskDependencyFields(
            allocator,
            dep_edges,
            task.id,
        ) catch return error.OutOfMemory;
        try dep_scratch.append(allocator, dep_fields);

        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
            .id = task.id,
            .name = task.name,
            .workspace_item_id = task.workspace_item_id,
            .description = task.description,
            .task_type = task.task_type,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
            .is_pinned = task.is_pinned,
            .pinned_position = task.pinned_position,
            .kanban_column_id = task.kanban_column_id,
            .kanban_position = task.kanban_position,
            // Migration 070 — per-task cwd override.
            .cwd = task.cwd,
            // Auto-retry-until-stop: slice borrow from `task` (owned by
            // WorkspaceItemTaskInfo.deinit, stays valid until the outer defer
            // at the top of useCase runs).
            .is_auto_retry_until_stop = task.is_auto_retry_until_stop,
            // Kanban notification icon (Migration 065 / plan
            // docs/plans/2026-07-26-kanban-task-notification-icon.md):
            // last_finish_reason comes from the LEFT JOIN on sessions,
            .last_finish_reason = task.last_finish_reason,
            .needs_human_review = task.needs_human_review,
            // Migration 067 — kanban task tags. JSON-encoded array
            // string borrowed from WorkspaceItemTaskInfo.tags (the
            // per-request arena reaps it on request teardown).
            .tags = task.tags,
            // Media-flags change — media-presence flags only. The full
            // base64 TEXT columns stay server-side for the lazy media
            // endpoint; the frontend fetches them when the flag is true.
            .is_have_image = task.is_have_image,
            .is_have_video = task.is_have_video,
            // Kanban-task-git-branch: computed on-demand per task from the
            // task's cwd (worktree or item path).
            .git_branch = git_branch,
            // Migration 111 — kanban task dependencies.
            .depends_on = dep_fields.depends_on,
            .blocked_by = dep_fields.blocked_by,
            .is_blocked = dep_fields.is_blocked,
        });
    }

    // next_cursor: the encoded "<sort_value>|<id>" of the LAST task in this
    // page, when has_more is true. The DB fn will decode it.
    const next_cursor: ?[]const u8 = blk: {
        if (!result.has_more) break :blk null;
        if (result.tasks.len == 0) break :blk null;
        const last = result.tasks[result.tasks.len - 1];
        const sort_value: ?[]const u8 = switch (input.sort_field) {
            .created_at => last.created_at orelse null,
            .updated_at => last.updated_at orelse null,
            .name => last.name, // name is NOT NULL in the DB schema
        };
        const v = sort_value orelse break :blk null;
        // Encode as "<sort_value>|<id>". For DATETIME columns the
        // value never contains '|' (the format is "YYYY-MM-DD HH:MM:SS"),
        // so the split in the DB fn is unambiguous.
        break :blk try std.fmt.allocPrint(allocator, "{s}|{s}", .{ v, last.id });
    };
    // `next_cursor` is a freshly-allocated slice whose bytes are COPIED into
    // the JSON response by makeWorkspaceItemTaskListResponse, so we can free
    // it as soon as that call returns.
    defer if (next_cursor) |c| allocator.free(c);

    return try http_response.makeWorkspaceItemTaskListResponse(
        allocator,
        task_responses.items,
        result.has_more,
        next_cursor,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    var input = parseInput(req.query);
    input.item_id = item_id;

    const data = useCase(allocator, sqlite_db, io, input) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.QueryFailed => "Failed to fetch tasks",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// =====================================================================
// Git branch resolution (kanban-task-git-branch plan, 2026-08-06)
// =====================================================================

/// Look up the parent workspace item's `path`. Used as the fallback cwd for
/// the git_branch lookup when a task has no worktree bound.
fn fetchWorkspaceItemPath(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) ![]u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(path, '') FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return "";
    defer rows.deinit();
    const row = (try rows.next()) orelse return "";
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}

/// Run `git -C <path> symbolic-ref --short HEAD` and fall back to `git -C
/// <path> rev-parse --abbrev-ref HEAD` for detached HEAD.
fn resolveGitBranch(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) []const u8 {
    // Attempt 1: symbolic-ref --short HEAD. Fails on detached HEAD
    // (returns non-zero exit with a "not a symbolic ref" message).
    const sym_argv = [_][]const u8{ "git", "-C", path, "symbolic-ref", "--short", "HEAD" };
    if (std.process.run(allocator, io, .{ .argv = &sym_argv })) |sym_result| {
        if (sym_result.term.exited == 0) {
            return std.mem.trim(u8, sym_result.stdout, " \n\r\t");
        }
        // Fall through to attempt 2.
    } else |_| {
        // Spawn failure (e.g. git not on PATH) — give up silently.
        return "";
    }

    // Attempt 2: rev-parse --abbrev-ref HEAD. Works for detached HEAD
    // too (returns literal "HEAD"), which we map to "" so the
    // frontend omits the badge.
    const rev_argv = [_][]const u8{ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" };
    const rev_result = std.process.run(allocator, io, .{ .argv = &rev_argv }) catch return "";
    if (rev_result.term.exited != 0) return "";
    const branch = std.mem.trim(u8, rev_result.stdout, " \n\r\t");
    if (std.mem.eql(u8, branch, "HEAD")) return "";
    return branch;
}
