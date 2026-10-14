const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const design_io = @import("../agentic_loop/design_io.zig");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;

pub const WorkspaceItemsDeleteError = error{
    OutOfMemory,
    WorkspaceItemNotFound,
    DatabaseError,
};

/// DELETE /api/workspaces/:workspace_id/items/:item_id - Delete a workspace item
pub fn workspaceItemsDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const result = useCase(allocator, io, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceItemNotFound => 404,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.DatabaseError => "Failed to delete workspace item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemResponse(allocator, .{ .id = result.id }) });
}

const WorkspaceItemsDeleteResult = struct {
    id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) WorkspaceItemsDeleteError!WorkspaceItemsDeleteResult {
    // Check if item exists first
    const existing = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return error.DatabaseError;
    };

    if (existing == null) return error.WorkspaceItemNotFound;
    defer existing.?.deinit(allocator);

    // For design items, rmdir the .pabrik/design/ folder from disk BEFORE the
    // SQL DELETE.
    const existing_item_type = existing.?.item_type;
    if (std.mem.eql(u8, existing_item_type, "design")) {
        if (existing.?.path) |p| {
            if (p.len > 0) {
                var folder_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const folder_path = std.fmt.bufPrint(
                    &folder_path_buf,
                    "{s}/.pabrik/design",
                    .{p},
                ) catch null;
                if (folder_path) |fp| {
                    design_io.deleteDirectoryRecursively(allocator, io, fp) catch |err| {
                        std.log.warn(
                            "failed to rmdir design folder {s} on item delete: {s}",
                            .{ fp, @errorName(err) },
                        );
                    };
                }
            }
        }
    }

    // Delete the item
    ai_mod.workspace_items.deleteWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return error.DatabaseError;
    };

    return .{ .id = item_id };
}