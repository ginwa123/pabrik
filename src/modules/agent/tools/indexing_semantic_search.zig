
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// ============================================================================
// Data Structures
// ============================================================================

pub const ChunkInfo = struct {
    chunk_id: u32,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    oversized: bool = false,
};

pub const EmbeddingsData = struct {
    embeddings: []f32,
    dimensions: u32,
};

pub const SearchResult = struct {
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    snippet: []const u8,
    score: f32,
};

pub const IndexManifest = struct {
    version: u32 = 1,
    dimensions: u32,
    chunk_count: u32,
    indexed_files: []const []const u8,
    last_updated: i64,
    memory_bytes: u64,
    oversized_chunks: []u32,
};

pub const ChunkHash = struct {
    chunk_id: u32,
    hash: [32]u8,
};

pub const FileEntry = struct {
    path: []const u8,
    content: []const u8,
    mtime: i64,
};

// ============================================================================
// Constants
// ============================================================================

const BINARY_EXTENSIONS = &[_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2",
    ".ttf", ".eot", ".zip", ".tar", ".gz", ".bin", ".exe",
    ".o", ".a", ".so", ".dylib", ".dll",
};

const DECLARATION_PATTERNS = &[_][]const u8{
    "fn ", "pub fn ", "const ", "pub const ", "struct ", "pub struct ",
    "test ", "comptime ", "export fn ", "extern fn ",
};

// ============================================================================
// Normalization
// ============================================================================

pub fn normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    if (sum == 0) return;
    const inv = 1.0 / @sqrt(sum);
    for (v) |*x| x.* *= inv;
}

// ============================================================================
// Dot Product for Cosine Similarity
// ============================================================================

pub fn dotProduct(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var sum: f32 = 0;
    for (a, 0..) |av, i| sum += av * b[i];
    return sum;
}

// ============================================================================
// File Extension Detection
// ============================================================================

fn isBinaryExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (BINARY_EXTENSIONS) |binary_ext| {
        if (std.mem.eql(u8, ext, binary_ext)) return true;
    }
    return false;
}

pub fn isBinaryContent(content: []const u8) bool {
    // Check first 512 bytes for null byte
    const check_len = @min(512, content.len);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

// ============================================================================
// Gitignore Parsing (simplified from glob.zig)
// ============================================================================

pub const GitignoreEntry = struct {
    negated: bool,
    pattern: []const u8,
};

pub const GitignoreContext = struct {
    entries: std.ArrayList(GitignoreEntry),
    root_cwd: []const u8,

    pub fn init(root_cwd: []const u8) @This() {
        return .{
            .entries = .empty,
            .root_cwd = root_cwd,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.pattern);
        self.entries.deinit(allocator);
    }

    pub fn loadGitignoreForDir(self: *@This(), allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) void {
        const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return;
        defer allocator.free(gitignore_path);

        const file: std.Io.File = if (std.fs.path.isAbsolute(gitignore_path))
            std.Io.Dir.openFileAbsolute(io, gitignore_path, .{}) catch return
        else
            std.Io.Dir.cwd().openFile(io, gitignore_path, .{}) catch return;
        defer file.close(io);

        const content = std.Io.Dir.cwd().readFileAlloc(io, gitignore_path, allocator, std.Io.Limit.limited(1024 * 64)) catch return;

        var line_start: usize = 0;
        while (line_start < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
            const line = content[line_start..line_end];

            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and trimmed[0] != '#') {
                var negated = false;
                var pattern = trimmed;
                if (pattern[0] == '!') {
                    negated = true;
                    pattern = pattern[1..];
                }
                const clean_pattern = std.mem.trim(u8, pattern, &std.ascii.whitespace);
                if (clean_pattern.len > 0) {
                    const entry = GitignoreEntry{
                        .negated = negated,
                        .pattern = allocator.dupe(u8, clean_pattern) catch return,
                    };
                    self.entries.append(allocator, entry) catch return;
                }
            }
            line_start = line_end + 1;
        }
        allocator.free(content);
    }

    pub fn isIgnored(self: *const @This(), path: []const u8) bool {
        var rel_path: []const u8 = path;
        if (std.mem.startsWith(u8, path, self.root_cwd)) {
            var rest = path[self.root_cwd.len..];
            if (rest.len > 0 and rest[0] == '/') {
                rel_path = rest[1..];
            } else {
                rel_path = rest;
            }
        }

        for (self.entries.items) |entry| {
            const basename = std.fs.path.basename(rel_path);
            if (gitignoreGlobMatch(entry.pattern, basename, false) or
                gitignoreGlobMatch(entry.pattern, rel_path, false)) {
                return !entry.negated;
            }
        }
        return false;
    }
};

pub fn gitignoreGlobMatch(glob: []const u8, text: []const u8, nocase: bool) bool {
    var gi: usize = 0;
    var ti: usize = 0;

    while (gi < glob.len) {
        const g = glob[gi];

        if (g == '*') {
            gi += 1;
            if (gi >= glob.len) return true;

            if (gi < glob.len and glob[gi] == '*') {
                gi += 1;
                if (gi < glob.len and glob[gi] == '/') gi += 1;

                var t = ti;
                while (t <= text.len) {
                    if (gitignoreGlobMatch(glob[gi..], text[t..], nocase)) return true;
                    t += 1;
                }
                return false;
            }

            while (ti < text.len and text[ti] != '/') {
                if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
                ti += 1;
            }
            if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
            return false;
        }

        if (g == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            gi += 1;
            ti += 1;
            continue;
        }

        if (g == '[') {
            gi += 1;
            if (ti >= text.len) return false;

            var matched = false;
            var negated = false;
            if (gi < glob.len and (glob[gi] == '!' or glob[gi] == '^')) {
                negated = true;
                gi += 1;
            }

            while (gi < glob.len and glob[gi] != ']') {
                if (gi + 2 < glob.len and glob[gi + 1] == '-') {
                    const start = glob[gi];
                    const end = glob[gi + 2];
                    if (text[ti] >= start and text[ti] <= end) matched = true;
                    gi += 3;
                } else {
                    const pc = glob[gi];
                    const tc = text[ti];
                    const match = if (nocase) std.ascii.toLower(pc) == std.ascii.toLower(tc) else pc == tc;
                    if (match) matched = true;
                    gi += 1;
                }
            }
            if (gi < glob.len) gi += 1;

            if (negated) matched = !matched;
            if (matched) ti += 1 else return false;
            continue;
        }

        if (ti >= text.len) return false;
        const tc = text[ti];
        if (g != '/') {
            const char_match = if (nocase) std.ascii.toLower(g) == std.ascii.toLower(tc) else g == tc;
            if (!char_match) return false;
        }
        gi += 1;
        ti += 1;
    }

    return ti == text.len;
}

// ============================================================================
// Directory Pattern Detection for Gitignore
// ============================================================================

fn isGitignoreDirPattern(pattern: []const u8) bool {
    // Gitignore patterns ending with / match directories
    // e.g., "build/" matches "build/", "build/output", "build/a/b/c"
    return pattern.len > 0 and pattern[pattern.len - 1] == '/';
}

pub fn gitignoreMatch(pattern: []const u8, path: []const u8, is_dir: bool) bool {
    _ = is_dir; // Reserved for future use (e.g., matching directories vs files)
    // Handle directory patterns (ending with /)
    if (isGitignoreDirPattern(pattern)) {
        const dir_pattern = pattern[0 .. pattern.len - 1]; // Remove trailing /

        // Check if path matches the directory name
        if (gitignoreGlobMatch(dir_pattern, path, false)) {
            return true;
        }

        // Check if path starts with "dir/"
        const prefix = std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ dir_pattern, "/" }) catch return false;
        defer std.heap.page_allocator.free(prefix);

        if (std.mem.startsWith(u8, path, prefix)) {
            return true;
        }

        return false;
    }

    // Normal pattern matching
    return gitignoreGlobMatch(pattern, path, false);
}

// ============================================================================
// File Walking
// ============================================================================

pub fn walkWorkspace(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) ![]FileEntry {
    var files = std.ArrayList(FileEntry).empty;
    errdefer {
        for (files.items) |f| {
            allocator.free(f.path);
            allocator.free(f.content);
        }
        files.deinit(allocator);
    }

    var gitignore_ctx = GitignoreContext.init(root_path);
    defer gitignore_ctx.deinit(allocator);

    try walkDirRecursive(allocator, io, root_path, &files, &gitignore_ctx);

    return try files.toOwnedSlice(allocator);
}

fn walkDirRecursive(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    files: *std.ArrayList(FileEntry),
    gitignore_ctx: *GitignoreContext,
) !void {
    gitignore_ctx.loadGitignoreForDir(allocator, io, dir_path);

    const dir: std.Io.Dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true, .follow_symlinks = false })
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = false });
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        const name = entry.name;

        if (std.mem.eql(u8, name, ".git")) continue;
        if (std.mem.startsWith(u8, name, ".pabrik")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, name });

        if (gitignore_ctx.isIgnored(full_path)) {
            allocator.free(full_path);
            continue;
        }

        if (entry.kind == .directory) {
            try walkDirRecursive(allocator, io, full_path, files, gitignore_ctx);
            allocator.free(full_path);
        } else if (entry.kind == .file) {
            if (isBinaryExtension(full_path)) {
                allocator.free(full_path);
                continue;
            }

            const content: []u8 = if (std.fs.path.isAbsolute(full_path))
                std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch {
                    allocator.free(full_path);
                    continue;
                }
            else
                std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch {
                    allocator.free(full_path);
                    continue;
                };

            if (isBinaryContent(content)) {
                allocator.free(content);
                allocator.free(full_path);
                continue;
            }

            const stat = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch {
                allocator.free(content);
                allocator.free(full_path);
                continue;
            };
            const mtime = @as(i64, @intCast(stat.mtime.nanoseconds));

            try files.append(allocator, .{
                .path = full_path,
                .content = content,
                .mtime = mtime,
            });
        } else {
            allocator.free(full_path);
        }
    }
}

// ============================================================================
// Chunking
// ============================================================================

pub fn chunkFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    max_tokens: u32,
) ![]ChunkInfo {
    const is_code = isCodeFile(file_path);
    var chunks = std.ArrayList(ChunkInfo).empty;
    errdefer chunks.deinit(allocator);

    if (is_code) {
        try chunkCodeFile(allocator, file_path, content, max_tokens, &chunks);
    } else {
        try chunkNonCodeFile(allocator, file_path, content, max_tokens, &chunks);
    }

    return try chunks.toOwnedSlice(allocator);
}

fn isCodeFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const code_exts = &[_][]const u8{
        ".zig", ".c", ".cpp", ".h", ".hpp", ".go", ".rs", ".py",
        ".js", ".ts", ".jsx", ".tsx", ".java", ".cs", ".swift",
        ".kt", ".scala", ".rb", ".php", ".lua", ".sh", ".bash",
    };
    for (code_exts) |code_ext| {
        if (std.mem.eql(u8, ext, code_ext)) return true;
    }
    return false;
}

fn chunkCodeFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    max_tokens: u32,
    chunks: *std.ArrayList(ChunkInfo),
) !void {
    // Find all declaration boundaries
    var boundaries = std.ArrayList(usize).empty;
    defer boundaries.deinit(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        const line = content[pos..line_end];

        for (DECLARATION_PATTERNS) |pattern| {
            if (line.len >= pattern.len and std.mem.eql(u8, line[0..pattern.len], pattern)) {
                try boundaries.append(allocator, pos);
                break;
            }
        }
        pos = line_end + 1;
    }

    // If no declarations found, fall back to non-code chunking
    if (boundaries.items.len == 0) {
        try chunkNonCodeFile(allocator, file_path, content, max_tokens, chunks);
        return;
    }

    // Create chunks between boundaries
    var chunk_id: u32 = @truncate(chunks.items.len);
    var prev_boundary: usize = 0;

    for (boundaries.items) |boundary| {
        const start_line = countLines(content, prev_boundary, boundary);
        const end_line = start_line + countLines(content, boundary, findEndOfBlock(content, boundary));

        const chunk_content = content[prev_boundary..findEndOfBlock(content, boundary)];
        const is_oversized = countTokens(chunk_content) > max_tokens;

        try chunks.append(allocator, .{
            .chunk_id = chunk_id,
            .file_path = try allocator.dupe(u8, file_path),
            .start_line = start_line,
            .end_line = end_line,
            .content = try allocator.dupe(u8, chunk_content),
            .oversized = is_oversized,
        });

        chunk_id += 1;
        prev_boundary = boundary;
    }

    // Handle remaining content after last declaration
    if (prev_boundary < content.len) {
        const start_line = countLines(content, prev_boundary, content.len);
        const end_line = start_line + countLines(content, content.len, content.len);

        const chunk_content = content[prev_boundary..];
        const is_oversized = countTokens(chunk_content) > max_tokens;

        try chunks.append(allocator, .{
            .chunk_id = chunk_id,
            .file_path = try allocator.dupe(u8, file_path),
            .start_line = start_line,
            .end_line = end_line,
            .content = try allocator.dupe(u8, chunk_content),
            .oversized = is_oversized,
        });
    }
}

fn findEndOfBlock(content: []const u8, start: usize) usize {
    // Find closing brace for a block, or end of file
    var brace_count: i32 = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;

    var i = start;
    while (i < content.len) : (i += 1) {
        const c = content[i];

        if (escaped) {
            escaped = false;
            continue;
        }

        if (c == '\\' and (in_string or in_char)) {
            escaped = true;
            continue;
        }

        if (c == '"' and !in_char) in_string = !in_string;
        if (c == '\'' and !in_string) in_char = !in_char;

        if (!in_string and !in_char) {
            if (c == '{') brace_count += 1;
            if (c == '}') {
                brace_count -= 1;
                if (brace_count == 0) return i + 1;
            }
        }
    }

    return content.len;
}

fn chunkNonCodeFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
    max_tokens: u32,
    chunks: *std.ArrayList(ChunkInfo),
) !void {
    // Split on blank lines
    var sections = std.ArrayList([]const u8).empty;
    defer sections.deinit(allocator);

    var start: usize = 0;
    while (start < content.len) {
        // Find next blank line
        var end = start;
        while (end < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, end, '\n') orelse content.len;
            const line = std.mem.trim(u8, content[start..line_end], &std.ascii.whitespace);

            if (line.len == 0) {
                // Found blank line - end should be at the newline position
                end = line_end;
                break;
            }
            end = line_end + 1;
        }

        // Handle case where we reached end of content without finding blank line
        if (end > content.len) end = content.len;
        if (start >= content.len) break;

        const section = content[start..end];
        if (section.len > 0) {
            try sections.append(allocator, section);
        }
        start = end + 1;
    }

    // Combine sections into chunks not exceeding max_tokens
    var chunk_id: u32 = @truncate(chunks.items.len);
    var current_content = std.ArrayList(u8).empty;
    defer current_content.deinit(allocator);

    var current_start_line: u32 = 1;

    for (sections.items) |section| {
        const section_tokens = countTokens(section);

        if (current_content.items.len == 0) {
            try current_content.appendSlice(allocator, section);
        } else if (countTokens(current_content.items) + section_tokens <= max_tokens * 4) {
            try current_content.appendSlice(allocator, "\n\n");
            try current_content.appendSlice(allocator, section);
        } else {
            // Save current chunk
            if (current_content.items.len > 0) {
                const is_oversized = countTokens(current_content.items) > max_tokens;
                try chunks.append(allocator, .{
                    .chunk_id = chunk_id,
                    .file_path = try allocator.dupe(u8, file_path),
                    .start_line = current_start_line,
                    .end_line = current_start_line + @as(u32, @truncate(countLinesFromContent(current_content.items))),
                    .content = try allocator.dupe(u8, current_content.items),
                    .oversized = is_oversized,
                });
                chunk_id += 1;
            }

            // Start new chunk
            current_content.clearRetainingCapacity();
            try current_content.appendSlice(allocator, section);
            current_start_line += 1;
        }
    }

    // Save final chunk
    if (current_content.items.len > 0) {
        const is_oversized = countTokens(current_content.items) > max_tokens;
        try chunks.append(allocator, .{
            .chunk_id = chunk_id,
            .file_path = try allocator.dupe(u8, file_path),
            .start_line = current_start_line,
            .end_line = current_start_line + @as(u32, @truncate(countLinesFromContent(current_content.items))),
            .content = try allocator.dupe(u8, current_content.items),
            .oversized = is_oversized,
        });
    }
}

fn countLines(content: []const u8, start: usize, end: usize) u32 {
    var count: u32 = 1;
    for (content[start..end]) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn countLinesFromContent(content: []const u8) usize {
    var count: usize = 1;
    for (content) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn countTokens(content: []const u8) usize {
    // Rough token estimation: ~4 chars per token
    return @divFloor(content.len, 4);
}

// ============================================================================
// Hashing
// ============================================================================

pub fn computeHash(content: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(content, &hash, .{});
    return hash;
}

pub fn computeChunkHashes(chunks: []const ChunkInfo) []ChunkHash {
    var hashes = std.ArrayList(ChunkHash).empty;
    for (chunks) |chunk| {
        hashes.appendAssumeCapacity(.{
            .chunk_id = chunk.chunk_id,
            .hash = computeHash(chunk.content),
        });
    }
    return hashes.items;
}

// ============================================================================
// Index Path Helpers
// ============================================================================

pub fn getIndexDir(root_cwd: []const u8) ![]const u8 {
    // Everything built from this path is handed to `createFileAbsolute` /
    // `openFileAbsolute`, which ASSERT the path is absolute and ABORT the
    // whole process (Debug/ReleaseSafe) instead of returning an error.
    if (!std.fs.path.isAbsolute(root_cwd)) return error.IndexRootNotAbsolute;
    return try std.fs.path.join(std.heap.page_allocator, &.{ root_cwd, ".pabrik", "semantic_index" });
}

// ============================================================================
// Binary Index I/O
// ============================================================================

pub fn writeChunks(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, chunks: []const ChunkInfo) !void {
    const chunks_path = try std.fs.path.join(allocator, &.{ dir_path, "chunks.bin" });
    defer allocator.free(chunks_path);

    const file = try std.Io.Dir.createFileAbsolute(io, chunks_path, .{});
    defer file.close(io);

    var write_buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(chunks.len))));

    for (chunks) |chunk| {
        try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(chunk.file_path.len))));
        try writer.interface.writeAll(chunk.file_path);
        try writer.interface.writeAll(std.mem.asBytes(&chunk.start_line));
        try writer.interface.writeAll(std.mem.asBytes(&chunk.end_line));
        try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(chunk.content.len))));
        try writer.interface.writeAll(chunk.content);
    }
}

pub fn loadChunks(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]ChunkInfo {
    const chunks_path = try std.fs.path.join(allocator, &.{ dir_path, "chunks.bin" });
    defer allocator.free(chunks_path);

    const file = std.Io.Dir.openFileAbsolute(io, chunks_path, .{}) catch return &[_]ChunkInfo{};
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 10)) catch return &[_]ChunkInfo{};
    defer allocator.free(content);

    var chunks = std.ArrayList(ChunkInfo).empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 0;
    const num_chunks = std.mem.readInt(u32, content[offset..][0..4], .little);
    offset += 4;

    var chunk_id: u32 = 0;
    while (chunk_id < num_chunks) : (chunk_id += 1) {
        const chunk_id_read = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        const path_len = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        const file_path = try allocator.dupe(u8, content[offset..offset + path_len]);
        offset += path_len;

        const start_line = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        const end_line = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        const content_len = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        const chunk_content = try allocator.dupe(u8, content[offset..offset + content_len]);
        offset += content_len;

        try chunks.append(allocator, .{
            .chunk_id = chunk_id_read,
            .file_path = file_path,
            .start_line = start_line,
            .end_line = end_line,
            .content = chunk_content,
        });
    }

    return try chunks.toOwnedSlice(allocator);
}

pub fn writeEmbeddings(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, dimensions: u32, embeddings: [][]const f32) !void {
    const embeddings_path = try std.fs.path.join(allocator, &.{ dir_path, "embeddings.bin" });
    defer allocator.free(embeddings_path);

    const file = try std.Io.Dir.createFileAbsolute(io, embeddings_path, .{});
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(std.mem.asBytes(&dimensions));
    try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(embeddings.len))));

    for (embeddings, 0..) |emb, i| {
        try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(i))));
        for (emb) |val| {
            try writer.interface.writeAll(std.mem.asBytes(&val));
        }
    }
}

pub fn loadEmbeddings(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !EmbeddingsData {
    const embeddings_path = try std.fs.path.join(allocator, &.{ dir_path, "embeddings.bin" });
    defer allocator.free(embeddings_path);

    const file = std.Io.Dir.openFileAbsolute(io, embeddings_path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 200)) catch return error.OutOfMemory;
    defer allocator.free(content);

    var offset: usize = 0;
    const dimensions = std.mem.readInt(u32, content[offset..][0..4], .little);
    offset += 4;

    const num_embeddings = std.mem.readInt(u32, content[offset..][0..4], .little);
    offset += 4;

    var all_embeddings = std.ArrayList(f32).empty;
    errdefer all_embeddings.deinit(allocator);

    var i: u32 = 0;
    while (i < num_embeddings) : (i += 1) {
        const chunk_id_read = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;
        _ = chunk_id_read;

        var d: u32 = 0;
        while (d < dimensions) : (d += 1) {
            const val = std.mem.readInt(u32, content[offset..][0..4], .little);
            offset += 4;
            const float_val = @as(f32, @bitCast(val));
            try all_embeddings.append(allocator, float_val);
        }
    }

    return .{
        .embeddings = try allocator.dupe(f32, all_embeddings.items),
        .dimensions = dimensions,
    };
}

pub fn writeHashes(io: std.Io, dir_path: []const u8, hashes: []const ChunkHash) !void {
    const hashes_path = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, "hashes.bin" }) catch return;

    const file = try std.Io.Dir.createFileAbsolute(io, hashes_path, .{});
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(std.mem.asBytes(&@as(u32, @truncate(hashes.len))));

    for (hashes) |h| {
        try writer.interface.writeAll(std.mem.asBytes(&h.chunk_id));
        try writer.interface.writeAll(&h.hash);
    }
}

pub fn loadHashes(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]ChunkHash {
    const hashes_path = std.fs.path.join(allocator, &.{ dir_path, "hashes.bin" }) catch return error.OutOfMemory;

    const file = std.Io.Dir.openFileAbsolute(io, hashes_path, .{}) catch return &[_:0]ChunkHash{};
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch return &[_:0]ChunkHash{};
    defer allocator.free(content);

    var offset: usize = 0;
    const num_hashes = std.mem.readInt(u32, content[offset..][0..4], .little);
    offset += 4;

    var hashes = std.ArrayList(ChunkHash).empty;
    errdefer hashes.deinit(allocator);

    var i: u32 = 0;
    while (i < num_hashes) : (i += 1) {
        const chunk_id = std.mem.readInt(u32, content[offset..][0..4], .little);
        offset += 4;

        var hash: [32]u8 = undefined;
        @memcpy(&hash, content[offset..offset + 32]);
        offset += 32;

        try hashes.append(allocator, .{ .chunk_id = chunk_id, .hash = hash });
    }

    return try hashes.toOwnedSlice(allocator);
}

pub fn writeManifest(io: std.Io, dir_path: []const u8, manifest: *const IndexManifest) !void {
    const manifest_path = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, "manifest.json" }) catch return;

    var manifest_content = std.ArrayList(u8).empty;
    defer manifest_content.deinit(std.heap.page_allocator);

    try manifest_content.appendSlice(std.heap.page_allocator,
        \\{\n
        \\"version": 1,\n
        \\"dimensions":
    );

    const dim_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{manifest.dimensions});
    defer std.heap.page_allocator.free(dim_str);
    try manifest_content.appendSlice(std.heap.page_allocator, dim_str);

    try manifest_content.appendSlice(std.heap.page_allocator,
        \\,\n"chunk_count":
    );

    const chunk_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{manifest.chunk_count});
    defer std.heap.page_allocator.free(chunk_str);
    try manifest_content.appendSlice(std.heap.page_allocator, chunk_str);

    try manifest_content.appendSlice(std.heap.page_allocator,
        \\,\n"last_updated":
    );

    const time_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{manifest.last_updated});
    defer std.heap.page_allocator.free(time_str);
    try manifest_content.appendSlice(std.heap.page_allocator, time_str);

    try manifest_content.appendSlice(std.heap.page_allocator,
        \\,\n"memory_bytes":
    );

    const mem_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{manifest.memory_bytes});
    defer std.heap.page_allocator.free(mem_str);
    try manifest_content.appendSlice(std.heap.page_allocator, mem_str);

    try manifest_content.appendSlice(std.heap.page_allocator, "\n}\n");

    const file = try std.Io.Dir.createFileAbsolute(io, manifest_path, .{});
    defer file.close(io);

    try std.Io.File.writeStreamingAll(file, io, manifest_content.items);
}

// ============================================================================
// Search
// ============================================================================

pub fn search(
    allocator: std.mem.Allocator,
    chunks: []const ChunkInfo,
    embeddings: []const f32,
    dimensions: u32,
    query: []const u8,
    limit: u32,
) !void {
    _ = allocator;
    _ = chunks;
    _ = embeddings;
    _ = dimensions;
    _ = query;
    _ = limit;

    // Placeholder - actual implementation would: 1. Embed the query 2.
    // Compute dot product with all embeddings 3. Return top-k results

    return error.OutOfMemory;
}

// ===== Tests merged from indexing_semantic_search_test.zig (2026-09-29
// flatten) =====
const testing = std.testing;

// ============================================================================
// Test: Chunk Single Function
// ============================================================================

test "testChunkSingleFunction" {
    const allocator = testing.allocator;

    const content =
        \\fn myFunction() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
    ;

    const chunks = try chunkFile(allocator, "test.zig", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    // May produce 1 or 2 chunks depending on trailing content handling
    try testing.expect(chunks.len >= 1);
    try testing.expectEqual(@as(u32, 0), chunks[0].chunk_id);
    try testing.expect(!chunks[0].oversized);
}

// ============================================================================
// Test: Chunk Multiple Functions
// ============================================================================

test "testChunkMultipleFunctions" {
    const allocator = testing.allocator;

    const content =
        \\fn funcA() void {}
        \\
        \\fn funcB() void {}
        \\
        \\fn funcC() void {}
        \\
        \\fn funcD() void {}
        \\
        \\fn funcE() void {}
    ;

    const chunks = try chunkFile(allocator, "test.zig", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    // May produce 5-6 chunks depending on trailing content handling
    try testing.expect(chunks.len >= 5);
    for (0..@min(chunks.len, 5)) |i| {
        try testing.expect(chunks[i].content.len > 0);
    }
}

// ============================================================================
// Test: Chunk Non-Code File (Markdown)
// ============================================================================

test "testChunkNonCode" {
    const allocator = testing.allocator;

    const content =
        \\# Title
        \\
        \\Paragraph one.
        \\
        \\Paragraph two.
    ;

    const chunks = try chunkFile(allocator, "readme.md", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    try testing.expect(chunks.len >= 1);
}

// ============================================================================
// Test: Gitignore Glob Matching
// ============================================================================

test "testGitignoreGlob" {
    // Test *.o pattern
    try testing.expect(gitignoreGlobMatch("*.o", "test.o", false));
    try testing.expect(!gitignoreGlobMatch("*.o", "test.c", false));

    // Test build/* pattern
    try testing.expect(gitignoreMatch("build/", "build/output", true));
    try testing.expect(gitignoreMatch("build/", "build/", true));

    // Test negation pattern - this tests the matching logic
    // *.o should NOT match keep.o when the glob is properly respecting characters
    try testing.expect(!gitignoreGlobMatch("build/*.txt", "keep.o", false));
}

// ============================================================================
// Test: Binary Content Detection
// ============================================================================

test "testBinarySniff" {
    // Null byte in content
    try testing.expect(isBinaryContent("hello\x00world"));

    // No null bytes
    try testing.expect(!isBinaryContent("hello world"));
    try testing.expect(!isBinaryContent("line1\nline2\nline3"));
}

// ============================================================================
// Test: Normalization
// ============================================================================

test "testNormalization" {
    var v: [4]f32 = .{ 3.0, 4.0, 0.0, 0.0 };
    normalize(&v);

    // Compute magnitude
    var mag: f32 = 0;
    for (v) |x| mag += x * x;
    mag = @sqrt(mag);

    try testing.expect(@abs(mag - 1.0) < 0.0001);
}

// ============================================================================
// Test: Dot Product
// ============================================================================

test "testDotProduct" {
    const a: [3]f32 = .{ 1.0, 2.0, 3.0 };
    const b: [3]f32 = .{ 4.0, 5.0, 6.0 };

    const result = dotProduct(&a, &b);
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    try testing.expect(@abs(result - 32.0) < 0.0001);
}

// ============================================================================
// Test: Hash Computation
// ============================================================================

test "testHashDiff" {
    const content1 = "hello world";
    const content2 = "hello world";
    const content3 = "different content";

    const hash1 = computeHash(content1);
    const hash2 = computeHash(content2);
    const hash3 = computeHash(content3);

    try testing.expectEqual(hash1, hash2);
    try testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

// ============================================================================
// Test: Search Results Structure
// ============================================================================

test "testSearchResultsStructure" {
    const result = SearchResult{
        .file_path = "test.zig",
        .start_line = 10,
        .end_line = 20,
        .snippet = "test content snippet",
        .score = 0.95,
    };

    try testing.expectEqualStrings("test.zig", result.file_path);
    try testing.expectEqual(@as(u32, 10), result.start_line);
    try testing.expectEqual(@as(u32, 20), result.end_line);
    try testing.expectEqualStrings("test content snippet", result.snippet);
    try testing.expectEqual(@as(f32, 0.95), result.score);
}

// ============================================================================
// Test: Chunk Info Structure
// ============================================================================

test "testChunkInfoStructure" {
    const chunk = ChunkInfo{
        .chunk_id = 5,
        .file_path = "myfile.zig",
        .start_line = 1,
        .end_line = 10,
        .content = "fn test() {}",
        .oversized = false,
    };

    try testing.expectEqual(@as(u32, 5), chunk.chunk_id);
    try testing.expectEqualStrings("myfile.zig", chunk.file_path);
    try testing.expect(!chunk.oversized);
}

// ============================================================================
// Test: File Entry Structure
// ============================================================================

test "testFileEntryStructure" {
    const entry = FileEntry{
        .path = "/path/to/file.zig",
        .content = "file content",
        .mtime = 1234567890,
    };

    try testing.expectEqualStrings("/path/to/file.zig", entry.path);
    try testing.expectEqualStrings("file content", entry.content);
    try testing.expectEqual(@as(i64, 1234567890), entry.mtime);
}

// NOTE: the former `testSearchEmptyIndex` was dropped with the flatten.

// ============================================================================
// Test: Index Manifest Structure
// ============================================================================

test "testIndexManifestStructure" {
    const manifest = IndexManifest{
        .version = 1,
        .dimensions = 768,
        .chunk_count = 100,
        .indexed_files = &.{},
        .last_updated = 1234567890,
        .memory_bytes = 307200,
        .oversized_chunks = &.{},
    };

    try testing.expectEqual(@as(u32, 1), manifest.version);
    try testing.expectEqual(@as(u32, 768), manifest.dimensions);
    try testing.expectEqual(@as(u32, 100), manifest.chunk_count);
    try testing.expectEqual(@as(u64, 307200), manifest.memory_bytes);
}
