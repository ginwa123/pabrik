//! `POST /api/memories` — create a global memory file. Body:
//! `{"name":"foo.md","content":"..."}`. On success: 201 with
//! `{"memory":{name,title,path,size}}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// JSON request body for `POST /api/memories`. Both fields are required.
/// `name` must be a single filename (no `/`, no `..`, must end in `.md`) —
/// see `memories.isValidMemoryName`.
const CreateMemoryBody = struct {
    name: []const u8,
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const MemoryCreateError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment. Maps to 500.
    MissingEnvironment,
    /// Body `name` was empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// A memory with the same name already exists. Maps to 409.
    AlreadyExists,
    /// `writeMemoryFile` returned false (validation / IO failure).
    WriteFailed,
    /// Insert succeeded but the new memory wasn't visible in the
    /// subsequent `listAllMemories` (consistency violation —
    /// extremely unlikely; surfaces as 500).
    NotVisible,
    /// `allocator.dupe` failed while building the heap-owned output.
    OutOfMemory,
};

/// Inputs to the create use-case.
pub const MemoryCreateInput = struct {
    name: []const u8,
    content: []const u8,
};

/// Output of the create use-case. `memory` is HEAP-OWNED by the use-case
/// (duplicated from `listAllMemories` so it survives the internal
/// `freeMemoriesList` defer).
pub const MemoryCreateOutput = struct {
    memory: memories_mod.MemoryInfo,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a global memory file. Steps: 1. Get the singleton + env. 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryCreateInput,
) MemoryCreateError!MemoryCreateOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    // 409 on duplicate.
    if (memories_mod.memoryExists(allocator, io, environment, input.name)) {
        return error.AlreadyExists;
    }

    if (!memories_mod.writeMemoryFile(allocator, io, environment, input.name, input.content)) {
        return error.WriteFailed;
    }

    // Re-list to derive title/path/size. `listAllMemories` is a
    // no-op on a missing dir; the freshly-created file is always in
    // the list right after `writeMemoryFile` returns true.
    const list = memories_mod.listAllMemories(allocator, io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);

    var found: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, input.name)) {
            found = m;
            break;
        }
    }
    const m = found orelse {
        // The file was just written but the re-list cannot see it.
        // This should be impossible unless another process deleted
        // the file between writeMemoryFile and listAllMemories.
        return error.NotVisible;
    };

    // Duplicate the matched slices so the output survives the
    // `free` defers above.
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

const CreateMemoryResponse = struct {
    memory: ?memories_mod.MemoryInfo = null,
    error_message: ?[]const u8 = null,
};

pub fn memoryCreateHandler(
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
    const parsed = std.json.parseFromSliceLeaky(CreateMemoryBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const outcome = useCase(allocator, ctx.io, .{
        .name = parsed.name,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.AlreadyExists => 409,
            error.WriteFailed => 400,
            error.NotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
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
        .data = try std.json.Stringify.valueAlloc(allocator, CreateMemoryResponse{ .memory = outcome.memory }, .{}),
    });
}
