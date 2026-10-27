//! `POST /api/workspaces/:workspace_id/items/design`. Creates a new workspace
//! item of `item_type='design'`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");

/// Request body for the design-item create endpoint.
const CreateDesignBody = struct {
    name: []const u8,
    /// Absolute path on disk that will become the storage root for design
    /// elements (`<path>/.pabrik/design/...`).
    path: []const u8,
};

/// Response body for the design-item create endpoint. Same shape as
/// `CreateKanbanResponse` minus the seeded-column fields.
pub const CreateDesignResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8, // always "design"
    name: []const u8,
    path: []const u8,
    position: i64,
};

pub const WorkspaceItemsCreateDesignError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    PathRequired,
    PathEmpty,
    InsertFailed,
    /// `std.json.Stringify.valueAlloc` and `allocator.dupe` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const WorkspaceItemsCreateDesignInput = struct {
    workspace_id: []const u8,
    body: CreateDesignBody,
};

pub const WorkspaceItemsCreateDesignResult = []const u8; // pre-serialized JSON

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: WorkspaceItemsCreateDesignInput,
) WorkspaceItemsCreateDesignError!WorkspaceItemsCreateDesignResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    // Trim whitespace and reject empty names. Mirrors
    // `workspace_items_create.zig`'s `EmptyName` validation.
    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.NameRequired;

    // Design items REQUIRE a path — without it, addElement would fail on
    // first use.
    const trimmed_path = std.mem.trim(u8, input.body.path, " \t\n\r");
    if (trimmed_path.len == 0) return error.PathRequired;

    // Generate item id with the same `item_<unix_nanoseconds>` scheme as
    // `workspace_items_create.zig:generateItemId` and
    // `workspace_items_create_kanban.zig:79-81`.
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // Compute the new item's position as COALESCE(MAX(position), -1) + 1
    // within this workspace.
    db.exec(allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at)
        \\VALUES (?, ?, 'design', ?, ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))
    , &.{ item_id, input.workspace_id, trimmed_name, trimmed_path, input.workspace_id }) catch {
        return error.InsertFailed;
    };

    // Build the full CreateDesignResponse.
    const json = std.json.Stringify.valueAlloc(allocator, CreateDesignResponse{
        .id = item_id,
        .workspace_id = input.workspace_id,
        .item_type = "design",
        .name = trimmed_name,
        .path = trimmed_path,
        .position = 0,
    }, .{}) catch {
        return error.OutOfMemory;
    };
    return json;
}

/// POST /api/workspaces/:workspace_id/items/design.
pub fn workspaceItemsCreateDesignHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
    });

    const json_body_len = req.body.len;
    if (json_body_len == 0) return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "request body required" }),
    });

    const parsed = std.json.parseFromSliceLeaky(CreateDesignBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const result = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.PathRequired => 400,
            error.PathEmpty => 400,
            error.InsertFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.PathRequired => "path is required for design items (the storage root for design files)",
            error.PathEmpty => "path is empty after trimming whitespace",
            error.InsertFailed => "Failed to create design item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 201, .data = result });
}
