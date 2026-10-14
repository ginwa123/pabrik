//! `PATCH
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for HTML-update. The only required field is
/// `html` (the new body).
const UpdateHtmlBody = struct {
    html: []const u8,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches.
pub const DesignElementHtmlUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// Body `html` field was missing or empty.
    HtmlRequired,
    /// `design_model.updateElement` returned `ElementNotFound`.
    ElementNotFound,
    /// `updateElement` returned `FileWriteFailed` (atomic rename
    /// of the on-disk HTML file failed).
    FileWriteFailed,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement` (consistency violation).
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Output of the update-html use-case.
pub const UpdateHtmlOutput = struct {
    /// The post-update element. Heap-owned by the use-case.
    element: design_model.DesignElement,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    element_id: []const u8,
    html: []const u8,
) DesignElementHtmlUpdateError!UpdateHtmlOutput {
    if (element_id.len == 0) return error.ElementIdRequired;
    if (html.len == 0) return error.HtmlRequired;

    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .html = html,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
        error.FileWriteFailed => return error.FileWriteFailed,
        else => return error.DbError,
    };
    defer allocator.free(updated_id);

    const element = design_model.getElement(allocator, db, updated_id) catch return error.ElementNotVisible;
    errdefer design_model.freeElement(allocator, element);

    return .{ .element = element };
}

// =====================================================================
// Handler
// =====================================================================

pub fn designElementsHtmlUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const element_id = req.params.get("element_id") orelse "";
    if (element_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "element_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateHtmlBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.html.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "html is required" }),
        });
    }

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, element_id, parsed.html) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.HtmlRequired => 400,
            error.ElementNotFound => 404,
            error.FileWriteFailed => 500,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.HtmlRequired => "html is required",
            error.ElementNotFound => "Element not found",
            error.FileWriteFailed => "Failed to write element HTML file",
            error.DbError => "Failed to update element HTML",
            error.ElementNotVisible => "Element was updated but not visible",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned element slices (no-op on arena).
    defer design_model.freeElement(allocator, output.element);

    // 4. Build the success response (200 OK — PATCH that updates
    //    an existing resource).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}
