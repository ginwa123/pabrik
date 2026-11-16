//! `GET /api/memories` — list all global memory files (markdown) in `$XDG_CONFIG_HOME/pabrik/memories/` or `~/.config/pabrik/memories/`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const list_memory_mod = pabrikcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`.
pub const MemoriesListError = error{
    /// `pabrikcore.getSingleton()` failed (server has not been initialised yet).
    ServerNotInitialized,
    /// The singleton has no `*const std.process.Environ.Map` (the server was constructed without an env).
    MissingEnvironment,
    /// `list_memory_mod.toJson` returned `error.OutOfMemory`. Maps to 500.
    OutOfMemory,
};

/// Inputs to the list-memories use-case.
pub const MemoriesListInput = struct {};

/// Output of the list-memories use-case: the allocated JSON body to return to the caller, plus the borrowed memory-list backing (the caller does NOT free either — …
pub const MemoriesListOutput = struct {
    json_body: []const u8,
};

// Use case

/// Resolve the environment and produce the memories list JSON.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoriesListInput,
) MemoriesListError!MemoriesListOutput {
    _ = input;

    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    const list = memories_mod.listAllMemories(allocator, io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_body = try list_memory_mod.toJson(allocator, list);
    return .{ .json_body = json_body };
}

// Handler

pub fn memoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const outcome = useCase(allocator, ctx.io, .{}) catch |err| {
        // Both switches are exhaustive over the inferred error set — adding a new `MemoriesListError` variant will fail to compile here (intentional, to keep status …
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
}
