const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;
const auth_common = @import("auth_common.zig");
const provisioning = @import("workspace_provisioning.zig");

pub const WorkspacesCreateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    DatabaseError,
};

/// POST /api/workspaces
pub fn workspacesCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // The owner is derived server-side from the `pabrik_session` cookie —
    // never from the request body, which a client controls (a body-supplied
    // owner id would be a spoofing vector).
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    const result = useCase(allocator, sqlite_db, ctx.io, req.body, owner, di.environment) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody, error.MissingName, error.NameNotString => 400,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "name required",
            error.MissingName => "name required",
            error.NameNotString => "name must be a string",
            error.DatabaseError => "Failed to create workspace",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    defer result.deinit(allocator);

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceResponse(allocator, .{
        .id = result.id,
        .name = result.name,
        .created_at = null,
        .updated_at = null,
    }) });
}

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *sqlite.SqliteBackend,
    io: std.Io,
    body: []const u8,
    owner: []const u8,
    /// Needed to resolve the default project's `path` ($HOME). Read from
    /// the singleton by the handler, never from the request body.
    environment: ?*const std.process.Environ.Map,
) WorkspacesCreateError!provisioning.ProvisionedWorkspace {
    if (body.len == 0) return error.MissingBody;

    // Per pabrik-http-handler-thin-wrapper-pattern.md: parseFromSliceLeaky
    // is the correct API for per-request arena allocators.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;
    const name = root.get("name") orelse return error.MissingName;
    if (name != .string) return error.NameNotString;

    // Id generation, the `position = MAX + 1` formula, the paired
    // `workspace_members` grant and the attached default project all live in
    // workspace_provisioning.zig — the same code the automatic per-user
    return provisioning.createWorkspaceRow(allocator, sqlite_db, io, name.string, owner, environment);
}
