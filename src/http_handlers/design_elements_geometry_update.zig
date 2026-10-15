//! `PATCH
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry`.
//! ⚠️ DEPRECATED — replaced by two distinct endpoints: - `POST

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for geometry-update. All fields optional.
const UpdateGeometryBody = struct {
    x: ?i64 = null,
    y: ?i64 = null,
    width: ?i64 = null,
    height: ?i64 = null,
    rotation: ?f64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each
/// variant to an HTTP status code + message via two exhaustive
/// switches.
pub const DesignElementGeometryUpdateError = error{
    /// `:element_id` path param was missing or empty.
    ElementIdRequired,
    /// No geometry fields were provided in the body — would result
    /// in a no-op UPDATE. Maps to 400 so the frontend gets explicit
    /// feedback (instead of silently succeeding).
    NoChanges,
    /// `design_model.updateElement` returned `ElementNotFound`.
    ElementNotFound,
    /// `updateElement` failed for some other DB reason.
    DbError,
    /// Update succeeded but the element wasn't visible in the
    /// subsequent `getElement`.
    ElementNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
    // Note: `FileWriteFailed` is NOT in this set — geometry updates never
    // rewrite the HTML file, so the model layer cannot surface that error
    // here.
};

/// Output of the update-geometry use-case.
pub const UpdateGeometryOutput = struct {
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
    x: ?i64,
    y: ?i64,
    width: ?i64,
    height: ?i64,
    rotation: ?f64,
) DesignElementGeometryUpdateError!UpdateGeometryOutput {
    if (element_id.len == 0) return error.ElementIdRequired;

    // Detect "no changes" at the use-case boundary.
    const any_change = x != null or y != null or width != null or
        height != null or rotation != null;
    if (!any_change) return error.NoChanges;

    const updated_id = design_model.updateElement(allocator, db, .{
        .element_id = element_id,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .rotation = rotation,
    }) catch |err| switch (err) {
        error.ElementNotFound => return error.ElementNotFound,
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

pub fn designElementsGeometryUpdateHandler(
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

    const parsed = std.json.parseFromSliceLeaky(UpdateGeometryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, element_id, parsed.x, parsed.y, parsed.width, parsed.height, parsed.rotation) catch |err| {
        const status: u16 = switch (err) {
            error.ElementIdRequired => 400,
            error.NoChanges => 400,
            error.ElementNotFound => 404,
            error.DbError => 500,
            error.ElementNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ElementIdRequired => "element_id required",
            error.NoChanges => "No geometry fields to update",
            error.ElementNotFound => "Element not found",
            error.DbError => "Failed to update element geometry",
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

    // 4. Build the success response (200 OK).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignElementResponse(output.element),
            .{},
        ),
    });
}
