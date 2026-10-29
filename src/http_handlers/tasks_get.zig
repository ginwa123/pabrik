//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`
//! Single-task fetch for the kanban Task details dialog.

const std = @import("std");
const http_response = @import("http_response.zig");
const git_branch = @import("git_branch.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;

pub const TasksGetError = error{
    QueryFailed,
    /// The task does not exist under the given item — the handler
    /// maps this to 404.
    TaskNotFound,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const TasksGetResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    io: std.Io,
    item_id: []const u8,
    task_id: []const u8,
) TasksGetError!TasksGetResult {
    const task_opt = ai_mod.llm_history.getWorkspaceItemTaskById(
        allocator,
        db,
        item_id,
        task_id,
    ) catch return error.QueryFailed;

    const task = task_opt orelse return error.TaskNotFound;
    defer task.deinit(allocator);

    // Kanban-task-git-branch.
    const item_path = fetchWorkspaceItemPath(allocator, db, item_id) catch "";
    defer if (item_path.len > 0) allocator.free(item_path);
    const cwd = if (task.git_worktree_cwd.len > 0)
        task.git_worktree_cwd
    else
        item_path;
    const branch: []const u8 = if (cwd.len == 0)
        ""
    else
        git_branch.resolve(allocator, io, cwd) orelse "";
    defer if (branch.len > 0) allocator.free(branch);

    // Migration 111 — this task's dependencies, each resolved against its
    // current column. Freed by the `defer` at the end of the function, i.e.
    // AFTER the response JSON has copied the borrowed slices.
    const dep_edges = ai_mod.kanban_deps.listEdgesForTask(allocator, db, task_id) catch
        return error.QueryFailed;
    defer ai_mod.kanban_deps.freeEdges(allocator, dep_edges);
    const dep_fields = try http_response.makeTaskDependencyFields(allocator, dep_edges, task_id);

    const resp = http_response.WorkspaceItemTaskResponse{
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
        .cwd = task.cwd,
        .is_auto_retry_until_stop = task.is_auto_retry_until_stop,
        .last_finish_reason = task.last_finish_reason,
        .needs_human_review = task.needs_human_review,
        .tags = task.tags,
        .is_have_image = task.is_have_image,
        .is_have_video = task.is_have_video,
        .git_branch = if (branch.len == 0) null else branch,
        .depends_on = dep_fields.depends_on,
        .blocked_by = dep_fields.blocked_by,
        .is_blocked = dep_fields.is_blocked,
    };

    // Wrap in `{ "task": {...} }` — the frontend's getTask() reads
    // data.task. Stringify deep-copies the borrowed slices into the
    // response JSON, so the outer task.deinit above is safe.
    return std.json.Stringify.valueAlloc(allocator, .{ .task = resp }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksGetHandler(
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

    // Empty-slice-as-NULL binding rule: Backend binds "" as SQL
    // NULL, which would turn `WHERE t.id = ?` into `WHERE t.id IS
    // NULL` (always false, silently). Guard before any DB call.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, io, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskNotFound => "task not found",
            error.QueryFailed => "Failed to fetch task",
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
    db: *pabrikcore.database.Db,
    item_id: []const u8,
) ![]u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(CAST(path AS TEXT), '') FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return "";
    defer rows.deinit();
    const row = (try rows.next()) orelse return "";
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}
