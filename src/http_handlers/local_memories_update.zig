//! `PUT /api/local-memories/:name` — replace the body of a local memory file.
//! Body: `{"content":"...","cwd":"/abs/path"}`. On success: 200 with
//! `{"memory":{name,title,path,size}}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `PUT /api/local-memories/:name`. `content` is the
/// new file body (required). `cwd` is optional — when omitted, the handler
/// falls back to the pabrik server's CWD.
const UpdateLocalMemoryBody = struct {
    content: []const u8,
    cwd: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryUpdateError = error{
    /// Neither the body `cwd` nor the io fallback yielded a usable
    /// local-memories directory. Maps to 500.
    NoCwdAvailable,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// The memory does not exist (cannot edit a non-existent one). Maps to 404.
    NotFound,
    /// `writeLocalMemoryFile` returned false (validation / IO failure).
    WriteFailed,
    /// Update succeeded but the file wasn't visible in the
    /// subsequent `listMemoriesInDir` (consistency violation).
    NotVisible,
    /// `allocator.dupe` failed while building the heap-owned output.
    OutOfMemory,
};

/// Inputs to the update use-case.
pub const LocalMemoryUpdateInput = struct {
    name: []const u8,
    content: []const u8,
    /// Body `cwd` (may be null/empty — the use-case falls back to
    /// the io CWD in that case).
    cwd: []const u8,
};

/// Output of the update use-case. `memory` is HEAP-OWNED by the
/// use-case. The handler is responsible for freeing each slice.
pub const LocalMemoryUpdateOutput = struct {
    memory: memories_mod.MemoryInfo,
};

// =====================================================================
// Use case
// =====================================================================

/// Replace the body of an existing local memory file. Steps: 1. Validate
/// `name` (non-empty + `isValidMemoryName`). 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryUpdateInput,
) LocalMemoryUpdateError!LocalMemoryUpdateOutput {
    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    // Resolve the local memories dir (body cwd first, then io fallback).
    var dir_path_alloc: ?[]const u8 = null;
    if (input.cwd.len > 0) {
        dir_path_alloc = memories_mod.get_local_memories_path_for_dir(allocator, input.cwd);
    }
    if (dir_path_alloc == null) {
        dir_path_alloc = memories_mod.get_local_memories_path_from_io(allocator, io);
    }
    const dir_path = dir_path_alloc orelse return error.NoCwdAvailable;
    defer allocator.free(dir_path);

    // Update only succeeds for existing memories. 404 (not 400) so
    // the UI can distinguish "edit non-existent" from "bad input".
    if (!memories_mod.localMemoryExists(allocator, io, dir_path, input.name)) {
        return error.NotFound;
    }

    if (!memories_mod.writeLocalMemoryFile(allocator, io, dir_path, input.name, input.content)) {
        return error.WriteFailed;
    }

    const list = memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, input.name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        return error.NotVisible;
    };

    var duped_name: ?[]u8 = null;
    var duped_title: ?[]u8 = null;
    var duped_path: ?[]u8 = null;
    errdefer {
        if (duped_name) |v| allocator.free(v);
        if (duped_title) |v| allocator.free(v);
        if (duped_path) |v| allocator.free(v);
    }
    duped_name = try allocator.dupe(u8, m.name);
    duped_title = try allocator.dupe(u8, m.title);
    duped_path = try allocator.dupe(u8, m.path);

    return .{ .memory = .{
        .name = duped_name.?,
        .title = duped_title.?,
        .path = duped_path.?,
        .size = m.size,
    } };
}

// =====================================================================
// Handler
// =====================================================================

const UpdateLocalMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

pub fn localMemoryUpdateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(UpdateLocalMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const cwd_raw = parsed.cwd orelse "";

    const outcome = useCase(allocator, ctx.io, .{
        .name = name,
        .content = parsed.content,
        .cwd = cwd_raw,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.NotFound => 404,
            error.WriteFailed => 400,
            error.NotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name (must end in .md, no /, no ..)",
            error.NotFound => "Memory not found",
            error.WriteFailed => "Failed to write memory file",
            error.NotVisible => "Memory updated but not visible in directory listing",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(outcome.memory.name);
        allocator.free(outcome.memory.title);
        allocator.free(outcome.memory.path);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, UpdateLocalMemoryResponse{ .memory = outcome.memory }, .{}),
    });
}
