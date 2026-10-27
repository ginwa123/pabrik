//! `PATCH
//! /api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id`.
//! Update an existing design page by id.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../agentic_loop/design_model.zig");

/// HTTP request body for page-update. `width` + `height` are
/// required; `name` is optional (null = leave unchanged; "" =
/// rejected with 400 by the use-case).
const UpdatePageBody = struct {
    width: i64,
    height: i64,
    // NEW (2026-08-06 — design page rename menu). Optional page name. JSON
    // `null`/absent maps to Zig `null` → name preserved.
    name: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. The handler maps each variant to an
/// HTTP status code + message via two exhaustive switches (one for status,
/// one for the user-facing message).
pub const DesignPageUpdateError = error{
    /// `:page_id` path param was missing or empty.
    PageIdRequired,
    /// Body `width` field was < 320 or > 4096.
    WidthOutOfRange,
    /// Body `height` field was < 240 or > 4096.
    HeightOutOfRange,
    /// Body `name` field was `""` (empty string). Matches the
    /// `setDesignPage` guard — a page must have a non-empty name.
    BadPageName,
    /// `design_model.updateDesignPage` returned `PageNotFound`
    /// (no row with that `page_id`).
    PageNotFound,
    /// `updateDesignPage` failed for some other DB reason.
    DbError,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the update-page use-case. The handler maps the parsed
/// HTTP body + path param into this struct; the use-case is then
/// transport-agnostic.
pub const UpdatePageInput = struct {
    page_id: []const u8,
    width: i64,
    height: i64,
    name: ?[]const u8,
};

/// Output of the update-page use-case.
pub const UpdatePageOutput = struct {
    /// The post-update page.
    page: design_model.DesignPage,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing design page. Steps: 1. Validate `page_id` non-empty. 2.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: UpdatePageInput,
) DesignPageUpdateError!UpdatePageOutput {
    if (input.page_id.len == 0) return error.PageIdRequired;

    const page = design_model.updateDesignPage(allocator, db, .{
        .page_id = input.page_id,
        .width = input.width,
        .height = input.height,
        .name = input.name,
    }) catch |err| switch (err) {
        error.PageIdRequired => return error.PageIdRequired,
        error.WidthOutOfRange => return error.WidthOutOfRange,
        error.HeightOutOfRange => return error.HeightOutOfRange,
        error.BadPageName => return error.BadPageName,
        error.PageNotFound => return error.PageNotFound,
        else => return error.DbError,
    };

    return .{ .page = page };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn designPagesUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const page_id = req.params.get("page_id") orelse "";
    if (page_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "page_id required" }),
        });
    }

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdatePageBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .page_id = page_id,
        .width = parsed.width,
        .height = parsed.height,
        .name = parsed.name,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response.
        const status: u16 = switch (err) {
            error.PageIdRequired => 400,
            error.WidthOutOfRange => 400,
            error.HeightOutOfRange => 400,
            error.BadPageName => 400,
            error.PageNotFound => 404,
            error.DbError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.PageIdRequired => "page_id required",
            error.WidthOutOfRange => "width must be between 320 and 4096",
            error.HeightOutOfRange => "height must be between 240 and 4096",
            error.BadPageName => "name must not be empty",
            error.PageNotFound => "Page not found",
            error.DbError => "Failed to update page",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned page slices. On the per-request
    // arena this is a no-op (the arena reaps at request end) but the
    // explicit frees are defensive + document ownership.
    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // 4. Build the success response (200 OK — PATCH is an update,
    //    not a creation).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignPageResponse(output.page),
            .{},
        ),
    });
}
