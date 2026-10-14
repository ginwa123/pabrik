//! `GET /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//! Fetch a single design page plus all of its elements (without the HTML
//! bodies — those are fetched lazily via `GET .../elements/:eid/html`).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

pub const DesignPageGetError = error{
    PageIdRequired,
    /// `design_model.getPageWithElements` returned `PageNotFound`
    /// (no row with that `page_id`).
    PageNotFound,
    /// `getPageWithElements` failed for some other DB / IO reason.
    QueryFailed,
    /// `makeDesignPageWithElementsResponse` failed (effectively
    /// unreachable on the per-request arena).
    OutOfMemory,
};

pub const DesignPageGetResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    page_id: []const u8,
) DesignPageGetError!DesignPageGetResult {
    if (page_id.len == 0) return error.PageIdRequired;

    var bundle = design_model.getPageWithElements(allocator, db, page_id) catch |err| switch (err) {
        error.PageNotFound => return error.PageNotFound,
        else => return error.QueryFailed,
    };
    defer bundle.deinit(allocator);

    return try http_response.makeDesignPageWithElementsResponse(
        allocator,
        bundle.page,
        bundle.elements,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn designPagesGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const page_id = req.params.get("page_id") orelse "";

    const data = useCase(allocator, sqlite_db, page_id) catch |err| {
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.PageNotFound => 404,
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.PageNotFound => "Page not found",
            error.QueryFailed => "Failed to get page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
