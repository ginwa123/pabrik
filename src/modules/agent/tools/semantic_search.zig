const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const indexing = @import("indexing_semantic_search.zig");

// ============================================================================
// Semantic Search Tool Types
// ============================================================================

pub const SemanticSearchInput = struct {
    query: []const u8,
    limit: ?u32 = 5,
};

pub const SearchResultItem = struct {
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    snippet: []const u8,
    score: f32,
};

pub const SemanticSearchResult = struct {
    success: bool,
    results: []SearchResultItem,
    error_msg: ?[]const u8 = null,
};

// ============================================================================
// Tool Schemas
// ============================================================================

pub const semantic_search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "semantic_search",
        .description =
        \\Search the codebase by meaning, not keywords.
        \\Returns file path, line range, content snippet, relevance score.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Natural language query",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Max results. Default: 5.",
                },
            },
            .required = &.{"query"},
        },
    },
};

pub const index_codebase_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "index_codebase",
        .description = "Index or re-index the codebase for semantic search. Skips unchanged files.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

// ============================================================================
// JSON Output Formatting
// ============================================================================

const sanitize = @import("helpers").sanitize_control_chars;

pub fn toJSONSuccess(allocator: std.mem.Allocator, results: []SearchResultItem) ![]u8 {
    const JsonItem = struct {
        file_path: []const u8,
        start_line: u32,
        end_line: u32,
        snippet: []const u8,
        score: f32,
    };
    var clean = try allocator.alloc(JsonItem, results.len);
    defer allocator.free(clean);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    for (results, 0..) |r, i| {
        const fp = try sanitize(allocator, r.file_path);
        try owned.append(allocator, fp);
        const sn = try sanitize(allocator, r.snippet);
        try owned.append(allocator, sn);
        clean[i] = .{
            .file_path = fp,
            .start_line = r.start_line,
            .end_line = r.end_line,
            .snippet = sn,
            .score = r.score,
        };
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .results = clean }, .{});
}

pub fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const clean = try sanitize(allocator, message);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

pub fn handleSemanticSearch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    limit_param: u32,
    query_param: []const u8,
) !void {
    const index_dir = try indexing.getIndexDir(cwd);
    defer allocator.free(index_dir);

    // Check if index exists
    const manifest_path = std.fs.path.join(std.heap.page_allocator, &.{ index_dir, "manifest.json" });
    defer allocator.free(manifest_path);

    const manifest_file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{});
    const index_exists = manifest_file != null;
    if (manifest_file) |f| f.close(io);
    if (index_exists) {
        // Load existing index
        const chunks = indexing.loadChunks(allocator, io, index_dir);
        defer {
            for (chunks) |c| {
                allocator.free(c.file_path);
                allocator.free(c.content);
            }
            allocator.free(chunks);
        }

        const embeddings_data = try indexing.loadEmbeddings(allocator, io, index_dir);
        defer {
            allocator.free(embeddings_data.embeddings);
        }

        const limit = limit_param orelse 5;
        const results = indexing.search(allocator, chunks, embeddings_data.embeddings, embeddings_data.dimensions, query_param, limit);
        defer allocator.free(results);
    } else {
        // Index doesn't exist - suggest running index_codebase first
    }
}

// ============================================================================
// Index Codebase Handler
// ============================================================================

pub fn handleIndexCodebase(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) !void {
    _ = allocator;
    _ = io;
    _ = cwd;
    return error.NotImplemented;
    // const index_dir = indexing.getIndexDir(cwd);
    // defer allocator.free(index_dir);
    //
    // // Create index directory
    // std.Io.Dir.cwd().createDirPath(io, index_dir);
    //
    // const files = indexing.walkWorkspace(allocator, io, cwd);
    // defer {
    //     for (files) |f| {
    //         allocator.free(f.path);
    //         allocator.free(f.content);
    //     }
    //     allocator.free(files);
    // }
    //
    // // Chunk files
    // var all_chunks = std.ArrayList(indexing.ChunkInfo).empty;
    // defer {
    //     for (all_chunks.items) |c| {
    //         allocator.free(c.file_path);
    //         allocator.free(c.content);
    //     }
    //     all_chunks.deinit(allocator);
    // }
    //
    // for (files) |file| {
    //     const chunks = indexing.chunkFile(ctx.allocator, file.path, file.content, 500) catch |err| {
    //         ctx.logger.errFmt("[index_codebase] Failed to chunk {s}: {s}", .{ file.path, @errorName(err) });
    //         continue;
    //     };
    //     for (chunks) |chunk| {
    //         try all_chunks.append(ctx.allocator, chunk);
    //     }
    // }
    //
    // ctx.logger.infoFmt("[index_codebase] Created {d} chunks from {d} files", .{ all_chunks.items.len, files.len });
    //
    // // Write chunks
    // indexing.writeChunks(ctx.allocator, ctx.io, index_dir, all_chunks.items) catch |err| {
    //     ctx.logger.errFmt("[index_codebase] Failed to write chunks: {s}", .{@errorName(err)});
    //     const output = try pabrik.semantic_search.jsonError(ctx.allocator, "Failed to write chunks");
    //     return tool_registry.ToolExecResult{ .output = output, .output_allocated = true };
    // };
    //
    // // Write manifest
    // const manifest = indexing.IndexManifest{
    //     .version = 1,
    //     .dimensions = 768, // Placeholder - would come from embedding provider
    //     .chunk_count = @truncate(all_chunks.items.len),
    //     .indexed_files = &.{},
    //     .last_updated = @as(i64, @intCast(std.Io.Timestamp.now(ctx.io, .real).nanoseconds)),
    //     .memory_bytes = @as(u64, all_chunks.items.len) * 768 * 4,
    //     .oversized_chunks = &.{},
    // };
    // indexing.writeManifest(ctx.io, index_dir, &manifest) catch |err| {};
    //
    // const summary = try std.fmt.allocPrint(ctx.allocator, "Indexed {d} files, {d} chunks.", .{ files.len, all_chunks.items.len });
    // defer ctx.allocator.free(summary);
    //
    // const output = try pabrik.semantic_search.toJSONSuccess(ctx.allocator, &.{});
    // return tool_registry.ToolExecResult{ .output = output, .output_allocated = true };
}
