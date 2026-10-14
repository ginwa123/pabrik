//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin`.
//! Body: `{ "is_pinned": true | false }`. Flips the `is_pinned` flag on the
//! row.

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const TaskPinError = error{
    TaskIdRequired,
    BodyRequired,
    InvalidJson,
    IsPinnedRequired,
    IsPinnedMustBeBool,
    TaskNotFound,
    PinUpdateFailed,
    /// `makeTaskPinResponse` / `std.json.Stringify.valueAlloc` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const TaskPinInput = struct {
    task_id: []const u8,
    is_pinned: bool,
};

/// Tagged outcome: returns the new pinned_position (or 0 if
/// unpinning).
pub const TaskPinResult = struct {
    new_pos: i64,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    input: TaskPinInput,
) TaskPinError!TaskPinResult {
    if (input.task_id.len == 0) return error.TaskIdRequired;

    const di = pabrikcore.getSingleton() catch return error.PinUpdateFailed;
    const new_pos = pabrikcore.ai_mod.workspace_item_tasks.setTaskPinned(
        allocator,
        di.db,
        input.task_id,
        input.is_pinned,
    ) catch |err| {
        // The model function returns a wider error set; the only
        // domain-meaningful variant is `TaskNotFound` (404). All
        // other errors collapse to `PinUpdateFailed` (500).
        if (err == error.TaskNotFound) return error.TaskNotFound;
        return error.PinUpdateFailed;
    };

    return .{ .new_pos = new_pos };
}

// =====================================================================
// Handler
// =====================================================================

pub fn taskPinHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate path param.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    // 2. Validate body presence.
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }),
        });
    }

    // 3. Parse JSON and extract `is_pinned`.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const is_pinned_val = parsed.object.get("is_pinned") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned required" }),
        });
    };
    if (is_pinned_val != .bool) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned must be a boolean" }),
        });
    }
    const is_pinned = is_pinned_val.bool;

    // 4. Delegate to the use-case.
    const outcome = useCase(allocator, .{
        .task_id = task_id,
        .is_pinned = is_pinned,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.TaskIdRequired => 400,
            error.BodyRequired => 400,
            error.InvalidJson => 400,
            error.IsPinnedRequired => 400,
            error.IsPinnedMustBeBool => 400,
            error.TaskNotFound => 404,
            error.PinUpdateFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskIdRequired => "task_id required",
            error.BodyRequired => "body required",
            error.InvalidJson => "Invalid JSON",
            error.IsPinnedRequired => "is_pinned required",
            error.IsPinnedMustBeBool => "is_pinned must be a boolean",
            error.TaskNotFound => "Task not found",
            error.PinUpdateFailed => "Failed to update task pin",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try http_response.makeTaskPinResponse(allocator, task_id, is_pinned, outcome.new_pos),
    });
}
