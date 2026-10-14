const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;

/// PUT /api/workspaces/:workspace_id/items/:item_id - Update a workspace item
/// Accepts an optional `path` field.
pub fn workspaceItemsUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const root = parsed.object;

    // Optional item_type. Mirror the path/name branch's presence vs absence
    // semantics.
    const item_type_present = root.get("item_type") != null;
    const item_type_in_body: ?[]const u8 = blk: {
        const v = root.get("item_type") orelse break :blk null;
        if (v != .string) break :blk null;
        if (v.string.len == 0) break :blk null;
        break :blk v.string;
    };
    if (item_type_present and item_type_in_body == null) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_type, when present, must be a non-empty string" }) });
    }

    // Optional path.
    const path_present = root.get("path") != null;
    const path_clear: bool = blk: {
        const v = root.get("path") orelse break :blk false;
        break :blk v == .null or (v == .string and v.string.len == 0);
    };
    const path_value: ?[]const u8 = blk: {
        const v = root.get("path") orelse break :blk null;
        if (v == .null) break :blk null;
        if (v == .string and v.string.len == 0) break :blk null;
        if (v == .string) break :blk v.string;
        break :blk null;
    };

    // Optional name.
    const name_present = root.get("name") != null;
    const name_value: ?[]const u8 = blk: {
        const v = root.get("name") orelse break :blk null;
        if (v == .null) break :blk null;
        if (v == .string and v.string.len == 0) break :blk null;
        if (v == .string) break :blk v.string;
        break :blk null;
    };
    // `name_valid` is true when name is present AND non-empty; the
    // handler uses this to decide whether to UPDATE or 400.
    const name_valid: bool = name_present and name_value != null;

    // Check if item exists first
    const existing = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace item" }) });
    };

    if (existing == null) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
    }
    defer existing.?.deinit(allocator);

    // If the caller sent `name` but it was null or empty, reject
    // before hitting the DB. Empty names break the UI rendering
    // (`{{ item.name }}` shows nothing).
    if (name_present and !name_valid) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(
                allocator,
                .{ .@"error" = "name must be a non-empty string when present" },
            ),
        });
    }

    // Get the current workspace_id for the update
    const current_workspace_id = existing.?.workspace_id;

    // Effective item_type: prefer the value sent in the body, fall back to
    // the existing row's type. The fallback makes rename-only calls (e.g.
    const effective_item_type: []const u8 = blk: {
        if (item_type_in_body) |v| break :blk v;
        break :blk existing.?.item_type;
    };

    // If the caller sent NOTHING updatable, return 400. Without this, the
    // handler would silently no-op when the body is `{name: ""}` (rejected
    // earlier anyway) or completely empty.
    if (!item_type_present and !name_valid and !path_present) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(
            allocator,
            .{ .@"error" = "At least one of item_type, name, or path is required" },
        ) });
    }

    // Update the item — if path is present in the body, run the dedicated
    // path-update SQL (preserves `path` semantics from the create endpoint:
    // NULL for empty / null, the string for a non-empty value).
    if (path_present and name_valid) {
        // Caller wants BOTH path + name updated. We update name first
        // (separate SQL) then path (separate SQL).
        ai_mod.workspace_items.updateWorkspaceItemName(
            allocator, sqlite_db, item_id, name_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item name" },
                ),
            });
        };
        if (path_clear or path_value == null) {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, null,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to clear workspace item path" },
                    ),
                });
            };
        } else {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, path_value.?,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to update workspace item path" },
                    ),
                });
            };
        }
    } else if (name_valid) {
        // Name-only update (the rename path). Common case for the
        // KanbanSettingsDialog and KanbanView pencil.
        ai_mod.workspace_items.updateWorkspaceItemName(
            allocator, sqlite_db, item_id, name_value.?,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item name" },
                ),
            });
        };
    } else if (path_present) {
        // Path-only update (preserves the original "PUT /items/:id
        // {item_type: 'kanban'}" path-set behavior). The branch is the same
        // as the old code, but renamed for readability and inlined.
        if (path_clear or path_value == null) {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, null,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to clear workspace item path" },
                    ),
                });
            };
        } else {
            ai_mod.workspace_items.updateWorkspaceItemPath(
                allocator, sqlite_db, item_id, path_value.?,
            ) catch {
                return res.jsonResponse(.{
                    .status_code = 500,
                    .data = try http_response.makeErrorResponse(
                        allocator,
                        .{ .@"error" = "Failed to update workspace item path" },
                    ),
                });
            };
        }
    } else {
        // Neither name nor path in body → legacy item_type-only update path
        // keeps the existing columns untouched.
        ai_mod.workspace_items.updateWorkspaceItem(
            allocator, sqlite_db, item_id, current_workspace_id,
            effective_item_type,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(
                    allocator,
                    .{ .@"error" = "Failed to update workspace item" },
                ),
            });
        };
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
        .id = item_id,
        .workspace_id = current_workspace_id,
        .item_type = effective_item_type,
        // When the body didn't mention path, leave the response field as
        // `null` so callers can distinguish "field not in body" from "field
        // cleared to NULL".
        .path = null,
        .created_at = null,
        .updated_at = null,
    }) });
}

