//! `GET /api/sessions/to-client-ids` — map every active session to the SSE
//! client IDs currently listening on it.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

pub const SessionToClientIdsError = error{
    ServerContextNotInitialized,
    /// `std.json.Stringify.valueAlloc` returns `error{Canceled}` on
    /// the Io runtime. Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    Canceled,
    /// `std.json.Stringify.valueAlloc` returns `error{OutOfMemory}`.
    /// Same as above — unreachable on arena, required by the
    /// type system.
    OutOfMemory,
};

pub const SessionToClientIdsEntry = struct {
    session_id: []const u8,
    client_ids: []const []const u8,
};

pub const SessionToClientIdsResponse = struct {
    sessions: []const SessionToClientIdsEntry,
    total_sessions: u32,
    total_clients: u32,
};

pub const SessionToClientIdsResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Convert a [16]u8 client ID to a 32-char lowercase hex string.
fn clientIdToHex(client_id: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, 32);
    for (client_id, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
) SessionToClientIdsError!SessionToClientIdsResult {
    const di = pabrikcore.getSingleton() catch return error.ServerContextNotInitialized;

    // Acquire the session_map_lock to safely read the shared map.
    try di.session_map_lock.lock(io);
    defer di.session_map_lock.unlock(io);

    var entries = std.ArrayListUnmanaged(SessionToClientIdsEntry){ .items = &.{}, .capacity = 0 };
    errdefer entries.deinit(allocator);

    var total_clients: u32 = 0;

    var it = di.session_to_client_ids.iterator();
    while (it.next()) |entry| {
        const session_id = entry.key_ptr.*;
        const client_list = entry.value_ptr.*;

        var client_id_hexes = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
        errdefer client_id_hexes.deinit(allocator);

        for (client_list.items) |client_id| {
            const hex_str = try clientIdToHex(client_id, allocator);
            try client_id_hexes.append(allocator, hex_str);
            total_clients += 1;
        }

        try entries.append(allocator, .{
            .session_id = session_id,
            .client_ids = try allocator.dupe([]const u8, client_id_hexes.items),
        });
    }

    const response_data = SessionToClientIdsResponse{
        .sessions = entries.items,
        .total_sessions = @as(u32, @intCast(entries.items.len)),
        .total_clients = total_clients,
    };
    return try std.json.Stringify.valueAlloc(allocator, response_data, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionToClientIdsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const response = useCase(allocator, ctx.io) catch |err| {
        const status: u16 = switch (err) {
            error.ServerContextNotInitialized => 500,
            error.Canceled => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerContextNotInitialized => "Server context not initialized",
            error.Canceled => "Io operation canceled",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try pabrikcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}