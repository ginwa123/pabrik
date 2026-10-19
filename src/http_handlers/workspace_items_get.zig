const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = pabrikcore.llm_history;
const workspace_default = @import("workspace_items_default.zig");

pub const WorkspaceItemsListError = error{
    OutOfMemory,
    DatabaseError,
};

pub const WorkspaceItemsGetError = error{
    OutOfMemory,
    WorkspaceItemNotFound,
    DatabaseError,
};

/// GET /api/workspaces/:workspace_id/items - Get all workspace items D12:
/// this read also ENSURES the workspace's default project exists.
pub fn workspaceItemsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }) });
    }

    // 1. Existence gate — see rule 1 above.
    if (workspace_default.workspaceExists(allocator, sqlite_db, workspace_id)) {
        // 2. Non-fatal ensure — see rule 2 above.
        const config_tools = auth_common.requestWorkspaceConfig(allocator, di, workspace_id, req.headers) orelse
            pabrikcore.getLlmConfig(di);
        const ensured = workspace_default.ensureDefaultProject(
            allocator,
            sqlite_db,
            workspace_id,
            di.environment,
            config_tools.tools,
        );
        if (ensured) |project| {
            defer project.deinit(allocator);
            if (project.created) {
                // Not an error, just a workspace that had no default —
                // which means a legacy workspace healed on this read.
                std.log.info("workspace_items_list: created default project for workspace {s}", .{workspace_id});
            }
        } else |err| {
            std.log.warn("workspace_items_list: default project ensure failed (non-fatal): {s}", .{@errorName(err)});
        }
    }

    const items = useCaseList(allocator, sqlite_db, workspace_id) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to fetch workspace items",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemListObjectResponse(allocator, items) });
}

fn useCaseList(allocator: std.mem.Allocator, sqlite_db: *pabrikcore.sqlite.SqliteBackend, workspace_id: []const u8) WorkspaceItemsListError![]const llm_history.WorkspaceItemInfo {
    return ai_mod.workspace_items.listWorkspaceItems(allocator, sqlite_db, workspace_id) catch {
        return error.DatabaseError;
    };
}

/// GET /api/workspaces/:workspace_id/items/:item_id - Get a single workspace item
pub fn workspaceItemsGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const item = useCaseGet(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceItemNotFound => 404,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.DatabaseError => "Failed to fetch workspace item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
        .id = item.id,
        .workspace_id = item.workspace_id,
        .item_type = item.item_type,
        .name = item.name,
        .path = item.path,
        .created_at = item.created_at,
        .updated_at = item.updated_at,
        .is_default = item.is_default,
    }) });
}

fn useCaseGet(allocator: std.mem.Allocator, sqlite_db: *pabrikcore.sqlite.SqliteBackend, item_id: []const u8) WorkspaceItemsGetError!llm_history.WorkspaceItemInfo {
    const opt = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return error.DatabaseError;
    };
    return opt orelse error.WorkspaceItemNotFound;
}
