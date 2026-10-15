//! `DELETE
//! /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id`.
//! Delete a kanban column.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// HTTP response shape for column-delete.
const DeleteColumnResponse = struct {
    success: bool = true,
    column_id: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each variant to an
/// HTTP status code + message via two exhaustive switches (one for status,
/// one for the user-facing message).
pub const KanbanColumnDeleteError = error{
    /// `:item_id` path param was missing or empty.
    ItemIdRequired,
    /// `:column_id` path param was missing or empty.
    ColumnIdRequired,
    /// `kanban_model.countTasksInColumn` failed (DB error, etc.).
    CountFailed,
    /// `kanban_model.deleteColumn` failed (DB error, etc.).
    DeleteFailed,
    /// `allocator` returned no memory.
    OutOfMemory,
};

/// Inputs to the delete-column use-case. The handler maps the HTTP
/// path params into this struct; the use-case is then
/// transport-agnostic.
pub const DeleteColumnInput = struct {
    item_id: []const u8,
    /// workspace_id is only used for the SSE payload's `workspace_id`
    /// field (the frontend filters kanban events by it). Empty is OK.
    workspace_id: []const u8,
    column_id: []const u8,
};

/// Tagged outcome of the delete-column use-case.
pub const KanbanColumnDeleteResult = union(enum) {
    /// Column was deleted (it had no tasks assigned).
    deleted,
    /// Column still has `task_count` tasks assigned — caller must
    /// move them to another column before the delete can succeed.
    has_tasks: u32,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a kanban column, gating on the pre-delete task-count check. Steps:
/// 1. Validate `item_id` and `column_id`. 2.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: DeleteColumnInput,
) KanbanColumnDeleteError!KanbanColumnDeleteResult {
    // 1. Validate. Business rule: both ids are required to locate the column
    // to delete (item_id is a defense — column_id alone is globally unique,
    // but the model takes both for symmetry with the other column mutators).
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.column_id.len == 0) return error.ColumnIdRequired;

    // 2. Pre-delete gate.
    const task_count = kanban_model.countTasksInColumn(
        allocator,
        db,
        input.column_id,
    ) catch return error.CountFailed;
    if (task_count > 0) return .{ .has_tasks = task_count };

    // 3. Delete the column (and NULL-out any orphaned tasks as a
    // defensive measure — see step 2 docstring).
    kanban_model.deleteColumn(
        allocator,
        db,
        input.item_id,
        input.column_id,
    ) catch return error.DeleteFailed;

    // 4.
    on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
        .action = "deleted",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .column_id = input.column_id,
    }) catch |err| {
        std.log.warn(
            "kanban_columns_delete: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return .deleted;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Reads path params, delegates
/// to `useCase`, and maps the outcome + errors to an HTTP response.
pub fn kanbanColumnsDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Read + validate path params.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events by it). Empty is fine — the SSE event will
    // still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";

    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    // 2. Delegate to the use-case.
    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .column_id = column_id,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response.
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.ColumnIdRequired => 400,
            error.CountFailed => 500,
            error.DeleteFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.ColumnIdRequired => "column_id required",
            error.CountFailed => "Failed to check column usage",
            error.DeleteFailed => "Failed to delete column",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // 4. Map the use-case outcome to an HTTP response.
    switch (outcome) {
        .deleted => {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.json.Stringify.valueAlloc(
                    allocator,
                    DeleteColumnResponse{ .column_id = column_id },
                    .{},
                ),
            });
        },
        .has_tasks => |task_count| {
            // The format string preserves the historical message shape
            // exactly so the frontend's notification renderer (and the
            // contract test in `kanban_columns_delete_test.zig` that
            const msg = try std.fmt.allocPrint(
                allocator,
                "Cannot delete column: {d} task{s} still assigned. Move them to another column first.",
                .{ task_count, if (task_count == 1) "" else "s" },
            );
            // arena reaps msg at request end; explicit free is
            // defensive + documents ownership (no-op on arena,
            // real free on leak-tracker test allocators).
            defer allocator.free(msg);
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }),
            });
        },
    }
}
