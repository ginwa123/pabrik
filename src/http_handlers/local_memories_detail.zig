//! `GET /api/local-memories/:name?cwd=...` — read a local memory file's
//! content + metadata.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// Response payload for `GET /api/local-memories/:name`. `content` is
/// JSON-escaped automatically by `std.json.Stringify.valueAlloc` — do not
/// hand-roll JSON for the body.
pub const LocalMemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code.
pub const LocalMemoryDetailError = error{
    /// Neither the per-request `cwd` query nor the io fallback
    /// yielded a usable local-memories directory. Maps to 500.
    NoCwdAvailable,
    /// `:name` path param was missing or empty.
    NameRequired,
    /// The name failed `isValidMemoryName` (path-traversal or non-md).
    InvalidName,
    /// The file does not exist on disk (or the re-list did not see it).
    NotFound,
    /// `allocator.dupe` failed while building the heap-owned payload.
    OutOfMemory,
};

/// Inputs to the detail use-case.
pub const LocalMemoryDetailInput = struct {
    name: []const u8,
    /// `?cwd=` query value (empty → fall back to the io CWD).
    cwd: []const u8,
};

/// Output of the detail use-case.
pub const LocalMemoryDetailOutput = struct {
    payload: LocalMemoryDetailPayload,
};

// =====================================================================
// Use case
// =====================================================================

/// Read a local memory file's content and metadata. Steps: 1. Validate `name`
/// (non-empty + `isValidMemoryName`). 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: LocalMemoryDetailInput,
) LocalMemoryDetailError!LocalMemoryDetailOutput {
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

    const content = memories_mod.readLocalMemoryFile(allocator, io, dir_path, input.name) orelse {
        return error.NotFound;
    };
    defer allocator.free(content);

    // Re-list for title/path/size. The re-list is cheap (single
    // openDir + iterate).
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
        return error.NotFound;
    };

    // Duplicate the matched slices + content so the output survives
    // the `free` defers above.
    var duped_name: ?[]u8 = null;
    var duped_title: ?[]u8 = null;
    var duped_path: ?[]u8 = null;
    var duped_content: ?[]u8 = null;
    errdefer {
        if (duped_name) |v| allocator.free(v);
        if (duped_title) |v| allocator.free(v);
        if (duped_path) |v| allocator.free(v);
        if (duped_content) |v| allocator.free(v);
    }
    duped_name = try allocator.dupe(u8, m.name);
    duped_title = try allocator.dupe(u8, m.title);
    duped_path = try allocator.dupe(u8, m.path);
    duped_content = try allocator.dupe(u8, content);

    return .{ .payload = .{
        .name = duped_name.?,
        .title = duped_title.?,
        .path = duped_path.?,
        .size = m.size,
        .content = duped_content.?,
    } };
}

// =====================================================================
// Handler
// =====================================================================

const LocalMemoryDetailResponse = struct {
    memory: ?LocalMemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

pub fn localMemoryDetailHandler(
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
            error.NotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.NoCwdAvailable => "Could not resolve local memories directory (no cwd available)",
            error.NameRequired => "Missing :name",
            error.InvalidName => "Invalid memory name",
            error.NotFound => "Memory not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    defer {
        allocator.free(outcome.payload.name);
        allocator.free(outcome.payload.title);
        allocator.free(outcome.payload.path);
        allocator.free(outcome.payload.content);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, LocalMemoryDetailResponse{ .memory = outcome.payload }, .{}),
    });
}
