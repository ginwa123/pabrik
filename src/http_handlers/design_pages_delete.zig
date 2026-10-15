//! `DELETE
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//! Delete a design page.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPageDeleteError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// `design_model.deletePage` returned `false` (no such row).
    PageNotFound,
    /// `deletePage` failed for some other DB reason.
    DbError,
    /// `std.json.Stringify.valueAlloc` failed for the response
    /// envelope (effectively unreachable on the per-request arena).
    OutOfMemory,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *pabrikcore.sqlite.SqliteBackend,
    page_id: []const u8,
) DesignPageDeleteError!void {
    if (page_id.len == 0) return error.PageIdRequired;

    const deleted = design_model.deletePage(allocator, io, db, page_id) catch return error.DbError;
    if (!deleted) return error.PageNotFound;
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";

    useCase(allocator, io, sqlite_db, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to delete page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const SuccessResponse = struct { success: bool = true };
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            SuccessResponse{},
            .{},
        ),
    });
}
