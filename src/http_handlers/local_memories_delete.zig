//! `DELETE /api/local-memories/:name?cwd=...` — delete a local memory file.
//! No body. On success: 200 with `{"success":true,"name":"..."}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// Response shape for `DELETE /api/local-memories/:name`.
pub const DeleteLocalMemoryResponse = struct {
    success: bool = true,
    name: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryDeleteError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory. Maps to 500.
    NoCwdAvailable,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// `deleteLocalMemoryFile` returned false (the helper already
    /// validated the name + dir, so the only remaining cause is an
    /// unexpected non-`FileNotFound` IO error). Maps to 400.
    DeleteFailed,
    /// `allocator.dupe` failed while building the heap-owned name
    /// slice for the response.
    OutOfMemory,
};

/// Inputs to the delete use-case.
pub const LocalMemoryDeleteInput = struct {
    name: []const u8,
    /// `?cwd=` query value (empty → fall back to the io CWD).
    cwd: []const u8,
};

/// Output of the delete use-case. `name` is HEAP-OWNED by the use-case (the
/// path param is borrowed; duping it lets the handler hand the response to
/// the JSON serializer without keeping the request alive).
pub const LocalMemoryDeleteOutput = struct {
    name: []u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Delete a local memory file (idempotent). Steps: 1. Validate `name`
/// (non-empty + `isValidMemoryName`). 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryDeleteInput,
) LocalMemoryDeleteError!LocalMemoryDeleteOutput {
    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    // Resolve the local memories dir (query first, then io fallback).
    var dir_path_alloc: ?[]const u8 = null;
    if (input.cwd.len > 0) {
        dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, input.cwd);
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, io);
    }
    const dir_path = dir_path_alloc orelse return error.NoCwdAvailable;
    defer allocator.free(dir_path);

    if (!memories_mod.deleteLocalMemoryFile(allocator, io, dir_path, input.name)) {
        return error.DeleteFailed;
    }

    return .{ .name = try allocator.dupe(u8, input.name) };
}

// =====================================================================
// Handler
// =====================================================================

pub fn localMemoryDeleteHandler(
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

    const cwd_raw = req.query.get("cwd") orelse "";
    const outcome = useCase(allocator, ctx.io, .{
        .name = name,
        .cwd = cwd_raw,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.DeleteFailed => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
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
        .data = try std.json.Stringify.valueAlloc(allocator, DeleteLocalMemoryResponse{ .name = outcome.name }, .{}),
    });
}
