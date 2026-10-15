//! `GET /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media`
//! Lazy media fetch for a kanban task (media-flags change).

const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;

pub const TasksMediaError = error{
    QueryFailed,
    TaskNotFound,
    OutOfMemory,
};

const MediaResponse = struct {
    image_urls: []const u8 = "",
    video_urls: []const u8 = "",
};

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
    task_id: []const u8,
) TasksMediaError![]const u8 {
    const media_opt = ai_mod.llm_history.getWorkspaceItemTaskMedia(
        allocator,
        db,
        item_id,
        task_id,
    ) catch return error.QueryFailed;
    const media = media_opt orelse return error.TaskNotFound;
    defer media.deinit(allocator);
    const resp = MediaResponse{
        .image_urls = media.image_urls,
        .video_urls = media.video_urls,
    };
    return std.json.Stringify.valueAlloc(allocator, resp, .{}) catch return error.OutOfMemory;
}

pub fn tasksMediaHandler(
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
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, item_id, task_id) catch |err| {
        const status: u16 = switch (err) {
            error.TaskNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.TaskNotFound => "task not found",
            error.QueryFailed => "Failed to fetch task media",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
