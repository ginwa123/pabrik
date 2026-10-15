//! `GET /api/workspaces/:workspace_id/items/:item_id/kanban/columns`. Returns
//! the kanban column list for a workspace item.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");

pub const KanbanColumnsListError = error{
    ItemIdRequired,
    QueryFailed,
    /// `makeKanbanColumnListResponse` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with `OutOfMemory`).
    OutOfMemory,
};

pub const KanbanColumnsListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) KanbanColumnsListError!KanbanColumnsListResult {
    if (item_id.len == 0) return error.ItemIdRequired;

    const cols = kanban_model.listColumns(allocator, db, item_id) catch return error.QueryFailed;
    defer kanban_model.freeColumns(allocator, cols);

    return try http_response.makeKanbanColumnListResponse(allocator, cols);
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanColumnsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";

    const data = useCase(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.QueryFailed => "Failed to list kanban columns",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
