//! `GET /api/memories/:name` — read a global memory file's content +
//! metadata.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const memories_mod = pabrikcore.memories;
const http_response = @import("http_response.zig");

/// Response payload for `GET /api/memories/:name`. `content` is JSON-escaped
/// automatically by `std.json.Stringify.valueAlloc` — do not hand-roll JSON
/// for the body, it can break on memories that contain `"` or backslash.
pub const MemoryDetailPayload = struct {
    name: []const u8,
    title: []const u8,
    path: []const u8,
    size: u64,
    content: []const u8,
};

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code via two exhaustive switches in the
/// handler.
pub const MemoryDetailError = error{
    /// `getSingleton()` failed — server not initialised.
    ServerNotInitialized,
    /// Singleton has no environment (server constructed without env).
    /// Maps to 500 with the "Missing environment" message.
    MissingEnvironment,
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
pub const MemoryDetailInput = struct {
    name: []const u8,
};

/// Output of the detail use-case.
pub const MemoryDetailOutput = struct {
    payload: MemoryDetailPayload,
};

// =====================================================================
// Use case
// =====================================================================

/// Read a global memory file's content and metadata. Steps: 1. Get the
/// singleton + env. 2.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: MemoryDetailInput,
) MemoryDetailError!MemoryDetailOutput {
    const di = pabrikcore.getSingleton() catch return error.ServerNotInitialized;
    const environment = di.environment orelse return error.MissingEnvironment;

    if (input.name.len == 0) return error.NameRequired;
    if (!memories_mod.isValidMemoryName(input.name)) return error.InvalidName;

    const content = memories_mod.readMemoryFile(allocator, io, environment, input.name) orelse {
        return error.NotFound;
    };
    defer allocator.free(content);

    // Re-list for title/path/size. The re-list is cheap (single
    // `openDir` + iterate) and avoids re-parsing the file to extract
    // the title (readMemoryFile returns raw bytes).
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
        // Defensive: the file existed at read time but the re-list
        // does not see it. Treat as not-found rather than 200/empty.
        return error.NotFound;
    };

    // Duplicate the matched slices + content so the output survives the
    // `free` defers above.
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

const MemoryDetailResponse = struct {
    memory: ?MemoryDetailPayload = null,
    error_message: ?[]const u8 = null,
};

pub fn memoryDetailHandler(
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
        // Exhaustive mapping — adding a new MemoryDetailError variant
        // will fail to compile here (intentional). No `else` prong.
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
            error.MissingEnvironment => 500,
            error.NameRequired => 400,
            error.InvalidName => 400,
            error.NotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
            error.MissingEnvironment => "Missing environment",
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

    // Free the useCase's heap-owned slices. On the per-request arena
    // this is a no-op (the arena reaps at request end) but the
    // explicit frees are defensive + document ownership.
    defer {
        allocator.free(outcome.payload.name);
        allocator.free(outcome.payload.title);
        allocator.free(outcome.payload.path);
        allocator.free(outcome.payload.content);
    }

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.json.Stringify.valueAlloc(allocator, MemoryDetailResponse{ .memory = outcome.payload }, .{}),
    });
}
