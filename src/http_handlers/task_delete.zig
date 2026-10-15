//! HTTP handler + use-case for `DELETE
//! /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const memories_mod = pabrikcore.memories;
const kanban_deps = pabrikcore.ai_mod.kanban_deps;

// =====================================================================
// Domain types
// =====================================================================

/// Outcome of `deleteTaskUseCase`.
pub const TaskDeleteOutcome = union(enum) {
    deleted,
    running: []const u8,
};

// =====================================================================
// Use-case (pure-ish)
// =====================================================================

/// Delete a workspace-item task.
pub fn deleteTaskUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *pabrikcore.sqlite.SqliteBackend,
    task_id: []const u8,
) !TaskDeleteOutcome {
    // 1. Look up the task so we can:
    //    a) check the worker table for an in-flight session,
    //    b) clean up associated resources (.md file for memory tasks).
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, db, task_id) catch null;
    if (task_opt) |task| {
        defer task.deinit(allocator);

        // 2. Refuse if the task is currently running.
        if (ai_mod.llm_history.isTaskRunning(allocator, db, task_id)) {
            // Look up the running worker's id so the 409 response
            // can include it (helpful for debugging — the frontend
            // can map worker_id back to its SSE stream).
            const worker_id = getRunningWorkerId(allocator, db, task_id) catch "";
            return .{ .running = worker_id };
        }

        // 3a. Memory-task cleanup: delete the .md file from
        // `<workspace_item.path>/.pabrik/memories/<task_name>`.
        if (std.mem.eql(u8, task.task_type, "memory")) {
            const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, db, task.workspace_item_id) catch null;
            if (item_opt) |item| {
                defer item.deinit(allocator);
                if (item.path) |cwd| {
                    if (memories_mod.get_local_memories_path_for_dir(allocator, cwd)) |dir_path| {
                        defer allocator.free(dir_path);
                        // The .md filename == task.name.
                        _ = memories_mod.deleteLocalMemoryFile(allocator, io, dir_path, task.name);
                    }
                }
            }
        }

        // 3b. (Deleted: routine-task cleanup removed with the per-task
        //     `routines` table — Migration 084. Standard tasks have no
        //     extra table.)
    } else {
        // Task doesn't exist — same as the pre-refactor behavior,
        // fall through and let the DELETE be idempotent (DELETE on a
        // missing row is a no-op at the SQL level).
    }

    // 4. Delete the task row itself. This is a no-op when the row
    //    didn't exist (idempotent DELETE).
    ai_mod.workspace_item_tasks.deleteWorkspaceItemTask(allocator, db, task_id) catch {
        return error.TaskDeleteFailed;
    };

    // Migration 110 — drop this task's dependency edges (both directions): a
    // dangling edge would freeze the card that waits on it forever. Best-effort,
    // since the task row is gone either way.
    kanban_deps.deleteForTask(allocator, db, task_id) catch |err| {
        std.log.warn("task_delete: dependency cleanup failed (non-fatal): {s}", .{@errorName(err)});
    };

    return .deleted;
}

/// Look up the running worker id for a task (the primary key of the row in
/// `worker` whose `session_id = task_id`).
fn getRunningWorkerId(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    task_id: []const u8,
) ![]const u8 {
    const sql = "SELECT id FROM worker WHERE session_id = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{task_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

// =====================================================================
// Handler
// =====================================================================

/// `DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`. Thin
/// orchestrator over `deleteTaskUseCase`: 1. validate `:task_id` path
/// parameter (inline) 2. resolve DB handle via `pabrikcore.getSingleton` 3.
pub fn tasksDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Validate `:task_id` path parameter.
    const task_id = req.params.get("task_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    };
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // 2. Resolve DB handle via the pabrik singleton.
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error" }) });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case.
    const outcome = deleteTaskUseCase(allocator, io, sqlite_db, task_id) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{
            .@"error" = switch (err) {
                error.TaskDeleteFailed => "Failed to delete task",
            },
        }) });
    };

    // 4. Map the use-case outcome to an HTTP response.
    switch (outcome) {
        .deleted => {
            return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskDeleteResponse(allocator, .{ .id = task_id, .success = true }) });
        },
        .running => |worker_id| {
            const msg = if (worker_id.len > 0)
                try std.fmt.allocPrint(allocator, "Task is currently running (worker_id={s}). Stop the session before deleting.", .{worker_id})
            else
                try allocator.dupe(u8, "Task is currently running. Stop the session before deleting.");
            // The arena reaps msg when the request finishes — no
            // explicit free needed (per-request arena pattern).
            return res.jsonResponse(.{ .status_code = 409, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
    }
}
