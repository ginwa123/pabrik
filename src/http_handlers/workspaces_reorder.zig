const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const sqlite = pabrikcore.sqlite;

// ─── Pattern: thin handler + use case in one file ─────────────────────────
// This file is structured as a teaching example for new HTTP features. The
// convention is: 1.

/// HTTP handler: POST /api/workspaces/reorder Body: { "ordered_ids": ["id1",
/// "id2", ..., "idN"] } (top-to-bottom display order).
pub fn workspacesReorderHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Step 1: parse the body. Handler is responsible for ALL HTTP
    // parsing — the use case below trusts its inputs.
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const root = parsed.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }) });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }) });
    }

    // Step 2: extract string IDs from the JSON array.
    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    // Step 3: call the use case.
    const di = try pabrikcore.getSingleton();
    // Used to be `catch ""`.
    const owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
    };
    defer allocator.free(owner);

    const result = reorderWorkspaces(allocator, di.db, ids.items, owner) catch |err| switch (err) {
        error.TooManyIds => return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids too long (max 100)" }) }),
        error.DatabaseUpdateFailed => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update workspace position" }) }),
        error.IntegerTooLarge => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error: position value too large" }) }),
    };

    // Step 4: render the typed response.
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspacesReorderResponse(allocator, result.count) });
}

// ─── Use case ──────────────────────────────────────────────────────────────
// Pure business logic: validate, compute positions, write to DB. Returns a
// typed `ReorderResult`.
const MAX_REORDER_IDS: usize = 100;

const ReorderResult = struct {
    count: usize,
};

const ReorderError = error{
    TooManyIds,
    DatabaseUpdateFailed,
    IntegerTooLarge,
};

// Position formula: the i-th id in the array gets `position = (count - 1 -
// i)`.
fn reorderWorkspaces(allocator: std.mem.Allocator, db: *pabrikcore.sqlite.SqliteBackend, ordered_ids: []const []const u8, owner: []const u8) ReorderError!ReorderResult {
    if (ordered_ids.len > MAX_REORDER_IDS) return error.TooManyIds;

    const count: i64 = @intCast(ordered_ids.len);
    var updated_count: usize = 0;

    // Stack-allocated int→string buffer. Reused across iterations. 32 bytes
    // is enough for any i64 (max 20 chars including sign).
    var buf: [32]u8 = undefined;

    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        // `bufPrint` into a fixed buffer — no heap allocation. Only fails on
        // actual buffer overflow, which a 32-byte buffer for an i64 cannot
        // hit. Treat as a programmer error.
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        db.exec(allocator, "UPDATE workspaces SET position = ?, updated_at = datetime('now') WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"), &.{ pos_str, id_str, owner, owner }) catch {
            return error.DatabaseUpdateFailed;
        };
        updated_count += 1;
    }

    return ReorderResult{ .count = updated_count };
}
