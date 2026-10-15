//! `DELETE /api/memories/:name` — delete a global memory file. No body. On
//! success: 200 with `{"success":true,"name":"..."}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `DELETE /api/memories/:name`. Idempotent:
/// `deleteMemoryFile` returns true when the file is deleted OR was already
/// missing (see `src/modules/agent/tools/memories.zig`).
pub const DeleteMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const MemoryDeleteError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment. Maps to 500.
    MissingEnvironment,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// `deleteMemoryFile` returned false (the helper already
    /// validated the name + env, so the only remaining cause is an
    /// unexpected non-`FileNotFound` IO error). Maps to 400.
    DeleteFailed,
    /// `allocator.dupe` failed while building the heap-owned name
    /// slice for the response.
    OutOfMemory,
};

/// Inputs to the delete use-case.
pub const MemoryDeleteInput = struct {
    name: []const u8,
};

/// Output of the delete use-case. `name` is HEAP-OWNED by the use-case (the
/// path param is borrowed; duping it lets the handler hand the response to
/// the JSON serializer without keeping the request alive).
pub const MemoryDeleteOutput = struct {
    name: []u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a global memory file (idempotent). Steps: 1. Get the singleton +
/// env. 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryDeleteInput,
) MemoryDeleteError!MemoryDeleteOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    if (!memories_mod.deleteMemoryFile(allocator, io, environment, input.name)) {
        // `deleteMemoryFile` only returns false on validation error, missing
        // environment, or a non-`FileNotFound` IO error.
        return error.DeleteFailed;
    }

    return .{ .name = try allocator.dupe(u8, input.name) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn memoryDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const name = req.params.get("name") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing :name" }),
        });
    };

    const outcome = useCase(allocator, ctx.io, .{ .name = name }) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.DeleteFailed => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name (must end in .md, no /, no ..)",
            error.DeleteFailed => "Failed to delete memory file",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer allocator.free(outcome.name);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteMemoryResponse{ .name = outcome.name }, .{}),
    });
}
