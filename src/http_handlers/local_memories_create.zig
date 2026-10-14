//! `POST /api/local-memories` — create a local memory file. Body:
//! `{"name":"foo.md","content":"...","cwd":"/abs/path"}`. On success: 201
//! with `{"memory":{name,title,path,size}}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/local-memories`.
const CreateLocalMemoryBody = struct {
    name: []const u8,
    content: []const u8,
    /// Optional. When omitted, falls back to the pabrik server's CWD.
    cwd: ?[]const u8 = null,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryCreateError = error{
    /// Neither the body `cwd` nor the io fallback yielded a usable
    /// local-memories directory. Maps to 500.
    NoCwdAvailable,
    /// Body `name` was empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// A memory with the same name already exists. Maps to 409.
    AlreadyExists,
    /// `writeLocalMemoryFile` returned false (validation / IO failure).
    WriteFailed,
    /// Insert succeeded but the new memory wasn't visible in the
    /// subsequent `listMemoriesInDir` (consistency violation —
    /// extremely unlikely; surfaces as 500).
    NotVisible,
    /// `allocator.dupe` failed while building the heap-owned output.
    OutOfMemory,
};

/// Inputs to the create use-case.
pub const LocalMemoryCreateInput = struct {
    name: []const u8,
    content: []const u8,
    /// Body `cwd` (may be null/empty — the use-case falls back to
    /// the io CWD in that case).
    cwd: []const u8,
};

/// Output of the create use-case. `memory` is HEAP-OWNED by the
/// use-case. The handler is responsible for freeing each slice.
pub const LocalMemoryCreateOutput = struct {
    memory: memories_mod.MemoryInfo,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a local memory file. Steps: 1. Validate `name` (non-empty +
/// `isValidMemoryName`). 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryCreateInput,
) LocalMemoryCreateError!LocalMemoryCreateOutput {
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

    // 409 on duplicate. `localMemoryExists` is the helper-side
    // check; it also validates the name (defense in depth) so an
    // invalid name returns 400 above, never reaching this check.
    if (memories_mod.localMemoryExists(allocator, io, dir_path, input.name)) {
        return error.AlreadyExists;
    }

    if (!memories_mod.writeLocalMemoryFile(allocator, io, dir_path, input.name, input.content)) {
        return error.WriteFailed;
    }

    // Re-list the local directory to derive title/path/size. The
    // freshly-created file is always in the list right after the
    // write succeeds.
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

const CreateLocalMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

pub fn localMemoryCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    // Body is small enough to live entirely in the request slice.
    // Per-request arena owns the parsed value (Leaky variant — see
    // `task_create.zig` for precedent).
    const parsed = std.json.parseFromSliceLeaky(CreateLocalMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const cwd_raw = parsed.cwd orelse "";

    const outcome = useCase(allocator, ctx.io, .{
        .name = parsed.name,
        .content = parsed.content,
        .cwd = cwd_raw,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.NoCwdAvailable => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.AlreadyExists => 409,
            error.WriteFailed => 400,
            error.NotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.NameRequired => "name is required",
            error.InvalidName => "Invalid memory name (must end in .md, no /, no ..)",
            error.AlreadyExists => "Memory already exists",
            error.WriteFailed => "Failed to write memory file",
            error.NotVisible => "Memory written but not visible in directory listing",
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
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, CreateLocalMemoryResponse{ .memory = outcome.memory }, .{}),
    });
}
