//! `GET /api/local-memories?cwd=...` — list `.md` memory files in
//! `<cwd>/.pabrik/memories/`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const list_memory_mod = pabrikcore.list_memory_tool;
const http_response = @import("http_response.zig");

/// Domain-level error set for `useCase`. The only failure mode is
/// "could not resolve the local memories directory" — both the query
/// `cwd` and the io fallback returned null/empty.
pub const LocalMemoriesListError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory.
    NoCwdAvailable,
    /// `list_memory_mod.toJson` returned `error.OutOfMemory`. Maps to 500.
    OutOfMemory,
};

/// Inputs to the list use-case.
pub const LocalMemoriesListInput = struct {
    /// The `?cwd=` query value (may be null/empty — the use-case
    /// will fall back to the io CWD in that case).
    cwd: []const u8,
};

/// Output of the list use-case: the heap-owned JSON body to return to the
/// caller. Borrowed `dir_path` is freed by the use-case's internal defer; the
/// JSON body lives until the per-request arena reaps at request end.
pub const LocalMemoriesListOutput = struct {
    json_body: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

/// Resolve the local memories dir and produce the list JSON. Steps: 1.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoriesListInput,
) LocalMemoriesListError!LocalMemoriesListOutput {
    var dir_path_alloc: ?[]const u8 = null;
    if (input.cwd.len > 0) {
        dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, input.cwd);
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, io);
    }
    const dir_path = dir_path_alloc orelse return error.NoCwdAvailable;
    defer allocator.free(dir_path);

    const list = memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    const json_body = try list_memory_mod.toJson(allocator, list);
    return .{ .json_body = json_body };
}

// =====================================================================
// Handler
// =====================================================================

pub fn localMemoriesListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const cwd_raw = req.query.get("cwd") orelse "";
    const outcome = useCase(allocator, ctx.io, .{ .cwd = cwd_raw }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json_body });
}
