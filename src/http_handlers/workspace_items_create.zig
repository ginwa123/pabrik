const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

/// Process-local monotonic counter for workspace_item id generation.
var workspace_item_id_counter: std.atomic.Value(u64) = .init(0);

pub const WorkspaceItemsCreateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    MissingName,
    NameNotString,
    /// The `name` field is present and a string but, after trimming
    /// leading/trailing ASCII whitespace, is empty.
    EmptyName,
    MissingPath,
    PathNotString,
    DatabaseError,
};

/// Generate a unique item ID
fn generateItemId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp_ns = ts.toNanoseconds();
    const counter = workspace_item_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "item_{d}_{d}", .{ timestamp_ns, counter });
}

const WorkspaceItemsCreateResult = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    path: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *pabrikcore.database.Db,
    io: std.Io,
    workspace_id: []const u8,
    body: []const u8,
) WorkspaceItemsCreateError!WorkspaceItemsCreateResult {
    if (body.len == 0) return error.MissingBody;

    // Per pabrik-http-handler-thin-wrapper-pattern.md: parseFromSliceLeaky
    // is the correct API for per-request arena allocators.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return error.InvalidJson;
    };
    const root = parsed.object;

    const name_val = root.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.NameNotString;
    // Trim leading/trailing ASCII whitespace and reject empty names. The trim
    // returns a slice into the same backing JSON memory owned by the
    // per-request arena, so no allocation needed.
    const trimmed_name = std.mem.trim(u8, name_val.string, " \t\n\r");
    if (trimmed_name.len == 0) return error.EmptyName;
    const name = trimmed_name;

    const path_val = root.get("path") orelse return error.MissingPath;
    if (path_val != .string) return error.PathNotString;
    const path = path_val.string;

    var item_type: []const u8 = "folder";
    if (root.get("item_type")) |type_val| {
        if (type_val == .string) {
            item_type = type_val.string;
        }
    }

    const item_id = generateItemId(allocator, io) catch return error.OutOfMemory;

    // Insert with timestamps, item_type, name, path, AND a fresh `position`
    // value.
    sqlite_db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &[_][]const u8{ item_id, workspace_id, item_type, name, path, workspace_id },
    ) catch return error.DatabaseError;

    return .{
        .id = item_id,
        .workspace_id = workspace_id,
        .item_type = item_type,
        .name = name,
        .path = path,
    };
}

/// POST /api/workspaces/:workspace_id/items - Create a new workspace item
pub fn workspaceItemsCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"workspace_id required\"" });
    }

    const result = useCase(allocator, sqlite_db, ctx.io, workspace_id, req.body) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidJson, error.MissingBody,
            error.MissingName, error.NameNotString,
            error.EmptyName,
            error.MissingPath, error.PathNotString => 400,
            error.DatabaseError, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "request body required",
            error.MissingName => "name required",
            error.NameNotString => "name must be a string",
            error.EmptyName => "name required",
            error.MissingPath => "path required",
            error.PathNotString => "path must be a string",
            error.DatabaseError => "Failed to create workspace item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}),
        });
    };

    const json_data = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = json_data });
}
