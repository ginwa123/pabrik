//! `PATCH /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move`.
//! Move a task to a different kanban column (and/or reorder within its
//! column).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// Request body for task-move.
const MoveTaskBody = struct {
    column_id: []const u8,
    position: i64,
};

/// Response shape for task-move.
const MoveTaskResponse = struct {
    success: bool = true,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
};

pub const TasksMoveError = error{
    ItemIdRequired,
    TaskIdRequired,
    MissingBody,
    InvalidJson,
    ColumnIdRequired,
    MoveFailed,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const TasksMoveInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    task_id: []const u8,
    body: MoveTaskBody,
};

pub const TasksMoveResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: TasksMoveInput,
) TasksMoveError!TasksMoveResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.task_id.len == 0) return error.TaskIdRequired;
    if (input.body.column_id.len == 0) return error.ColumnIdRequired;

    kanban_model.moveTask(
        allocator,
        db,
        input.item_id,
        input.task_id,
        input.body.column_id,
        input.body.position,
    ) catch return error.MoveFailed;

    // Emit SSE event so other connected clients refresh their kanban view.
    // action="moved" matches the frontend's `KanbanTaskEvent` union variant.
    on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = input.task_id,
        .new_column_id = input.body.column_id,
        .new_position = input.body.position,
    }) catch |err| {
        std.log.warn(
            "tasks_move: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    // Chunk 5 of kanban-task-notification-icon: dragging a card to another
    // column is the most visible "human touch" — stamp last_human_touched_at
    // so the kanban card flips from the orange "awaiting review" dot to the
    pabrikcore.ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        db,
        input.task_id,
        null,
    ) catch |err| {
        std.log.warn(
            "tasks_move: stamp last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try std.json.Stringify.valueAlloc(allocator, MoveTaskResponse{
        .task_id = input.task_id,
        .column_id = input.body.column_id,
        .position = input.body.position,
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksMoveHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine —
    // the SSE event will still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(MoveTaskBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const data = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .task_id = task_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.TaskIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.ColumnIdRequired => 400,
            error.MoveFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.TaskIdRequired => "task_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.ColumnIdRequired => "column_id is required",
            error.MoveFailed => "Failed to move task",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
