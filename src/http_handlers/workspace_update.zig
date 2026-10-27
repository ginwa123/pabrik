const std = @import("std");
const root_mod = @import("pabrikcore");
const gserverz = root_mod.gserverz;
const pabrikcore = root_mod;
const ai_workflow = pabrikcore.ai_workflow;
const http_response = pabrikcore.http_response;
const auth_common = @import("auth_common.zig");

pub const WorkspaceUpdateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    DatabaseError,
    /// The workspace does not exist, or belongs to another user — the two
    /// are deliberately indistinguishable (404, never 403) so a caller
    /// cannot probe for the existence of someone else's ids.
    NotFound,
};

/// PUT /api/workspaces/:id
pub fn workspaceUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "id is required" }) });
    }

    const result = useCase(allocator, sqlite_db, id, req.body, di.auth_enabled, req.headers) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody, error.MissingName, error.NameNotString => 400,
            error.NotFound => 404,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "name is required",
            error.MissingName => "name is required",
            error.NameNotString => "name must be a string",
            error.NotFound => "Workspace not found",
            error.DatabaseError => "Failed to update workspace",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ result.id, result.name }) });
}

const WorkspaceUpdateResult = struct {
    id: []const u8,
    name: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *pabrikcore.database.Db,
    id: []const u8,
    body: []const u8,
    auth_enabled: bool,
    headers: anytype,
) WorkspaceUpdateError!WorkspaceUpdateResult {
    if (body.len == 0) return error.MissingBody;

    // Owner resolved server-side (cookie only). A caller must not be able to
    // rename another user's workspace by guessing its id.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, auth_enabled, headers) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(owner);

    // Per the project memory (pabrik-http-handler-thin-wrapper-pattern.md),
    // the per-request arena allocator (`allocator`) is the per-request arena,
    // so parseFromSliceLeaky is the correct API — its internal arena lifetime
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.NameNotString;

    {
        var q = sqlite_db.query(
            allocator,
            "SELECT 1 FROM workspaces WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
            &[_][]const u8{ id, owner, owner },
        ) catch {
            return error.DatabaseError;
        };
        defer q.deinit();
        const row = q.next() catch {
            return error.DatabaseError;
        };
        if (row == null) return error.NotFound;
        if (row) |r| r.deinit(allocator);
    }

    sqlite_db.exec(allocator,
        "UPDATE workspaces SET name = ?, updated_at = datetime('now') WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
        &[_][]const u8{ name_val.string, id, owner, owner },
    ) catch {
        return error.DatabaseError;
    };

    return .{ .id = id, .name = name_val.string };
}