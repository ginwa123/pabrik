//! `PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched`.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = ai_mod.llm_history;
const on_event_sent_kanban = ai_mod.on_event_sent_kanban;

pub const MarkTouchedError = error{
    TaskIdRequired,
    /// `std.json.Stringify.valueAlloc` can fail with `OutOfMemory`.
    /// Unreachable on the per-request arena, but the type system
    /// requires the variant.
    OutOfMemory,
};

pub const MarkTouchedResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

const MarkTouchedResponse = struct {
    success: bool = true,
    task_id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    workspace_id: []const u8,
    item_id: []const u8,
    task_id: []const u8,
) MarkTouchedError!MarkTouchedResult {
    if (task_id.len == 0) return error.TaskIdRequired;

    // 1. Stamp the column. Idempotent — re-stamping is harmless.
    //    The writer reads current time via libc gettimeofday
    //    internally (now_unix_ms=null → auto-now).
    llm_history.updateTaskLastHumanTouchedAt(allocator, db, task_id, null) catch {
        // Collapse writer errors to a single caller-handled variant (matches
        // the project's pattern of narrow use-case error sets; see memory
        // `zig-language-quirks` §"catch narrows the inferred error set before
        return error.TaskIdRequired;
    };

    // 2. Emit SSE so connected kanban clients refresh.
    on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "human_touched",
        .workspace_id = workspace_id,
        .item_id = item_id,
        .task_id = task_id,
        // After a human touch, the task is no longer "awaiting
        // review" (if it ever was). Send the explicit flag so the
        // frontend doesn't have to recompute it.
        .needs_human_review = false,
    }) catch |err| {
        std.log.warn(
            "task_mark_human_touched: SSE emit failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        MarkTouchedResponse{ .task_id = task_id },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn taskMarkHumanTouchedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // workspace_id + item_id are not strictly required (the DB write is keyed
    // on task_id only), but we keep them in the route so the path matches the
    // sibling task handlers and the SSE event payload carries them.
    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, workspace_id, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskIdRequired => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskIdRequired => "task_id required",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}