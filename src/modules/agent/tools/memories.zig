const std = @import("std");

/// App name for config directory. Matches skills.zig and agents.zig.
pub const APP_NAME = "pabrik";


/// Subdirectory name under the per-app config folder.
pub const MEMORIES_DIR = "memories";

/// Subdirectory name under the per-project local config folder.
/// Mirrors `LOCAL_SKILLS_DIR = ".pabrik/skills"` in tools/skills.zig.
pub const LOCAL_MEMORIES_DIR = ".pabrik/memories";


/// Concatenate `dir` and `name` into a forward-slash path and return it.
/// Cross-platform convention for "config path" helpers across this project:
/// always use `/` as the separator, regardless of OS.
fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) {
        return allocator.dupe(u8, name);
    }
    const out = try allocator.alloc(u8, dir.len + 1 + name.len);
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 ..][0..name.len], name);
    return out;
}

/// Three-component variant: `parent + "/" + mid + "/" + leaf`.
fn joinPath3(allocator: std.mem.Allocator, parent: []const u8, mid: []const u8, leaf: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, parent.len + 1 + mid.len + 1 + leaf.len);
    var idx: usize = 0;
    @memcpy(out[idx..][0..parent.len], parent);
    idx += parent.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..mid.len], mid);
    idx += mid.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..leaf.len], leaf);
    return out;
}

/// Four-component variant. Single allocation, no partial strings to free.
fn joinPath4(
    allocator: std.mem.Allocator,
    a: []const u8,
    b: []const u8,
    c: []const u8,
    d: []const u8,
) ![]u8 {
    const out = try allocator.alloc(u8, a.len + 1 + b.len + 1 + c.len + 1 + d.len);
    var idx: usize = 0;
    @memcpy(out[idx..][0..a.len], a);
    idx += a.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..b.len], b);
    idx += b.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..c.len], c);
    idx += c.len;
    out[idx] = '/';
    idx += 1;
    @memcpy(out[idx..][0..d.len], d);
    return out;
}

/// Bytes scanned from the start of a memory file when looking for the
/// title (first H1). First H1s almost always live in the first line, but
/// we allow a generous buffer for files that put the H1 after some prose.
const TITLE_SCAN_LIMIT: usize = 4096;

/// One memory file. All string fields are allocator-owned and must be
/// freed via `freeMemoriesList`.
pub const MemoryInfo = struct {
    /// Filename including the .md extension (e.g. "user-preferences.md").
    name: []const u8,
    /// Title extracted from the first H1 line, or the filename stem
    /// (without .md) if no H1 is present.
    title: []const u8,
    /// Absolute path to the memory file.
    path: []const u8,
    /// File size in bytes.
    size: u64,
};

/// Get the global memories directory path using XDG standards.
pub fn get_global_memories_path(
    allocator: std.mem.Allocator,
    environment: *const std.process.Environ.Map,
) ?[]const u8 {
    if (environment.get("XDG_CONFIG_HOME")) |xdg_config| {
        return joinPath3(allocator, xdg_config, APP_NAME, MEMORIES_DIR) catch null;
    }

    if (environment.get("HOME")) |home| {
        // Linux/macOS: ~/.config/<APP>/<MEMORIES_DIR>.
        // On macOS the convention is $HOME/Library/Application Support; keep
        // the Unix-style fallback for now (separate task to detect macOS).
        return joinPath4(allocator, home, ".config", APP_NAME, MEMORIES_DIR) catch null;
    }

    return null;
}

/// Get the local memories directory path for a specific cwd.
pub fn get_local_memories_path_for_dir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ?[]const u8 {
    if (cwd.len == 0) return null;
    // Note: std.fs.path.join produces OS-native separators (e.g. '\' on
    // Windows), which breaks string-equality assertions in tests hardcoded
    // with forward slashes.
    return joinPath(allocator, cwd, LOCAL_MEMORIES_DIR) catch null;
}

/// List all .md memory files in the global memories directory. Returns a
/// slice of `MemoryInfo`.
pub fn listAllMemories(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
) []MemoryInfo {
    const dir_path = get_global_memories_path(allocator, environment) orelse return &.{};
    defer allocator.free(dir_path);

    // Open the memories directory. Missing directory is NOT an error —
    // it just means the user has not created any memories yet.
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer std.Io.Dir.close(dir, io);

    var list: std.ArrayList(MemoryInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.title);
            allocator.free(item.path);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only consider regular files (skip subdirectories, symlinks, etc.)
        if (entry.kind != .file) continue;

        // Only consider .md files. Memories are markdown by design.
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Build absolute path. Use joinPath for the cross-platform
        // `/` separator (see joinPath for why).
        const full_path = joinPath(allocator, dir_path, entry.name) catch continue;

        // Open the file to read metadata and a prefix for the title.
        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(full_path);
            continue;
        };

        // Read the full file to scan for the first H1. No size cap — every
        // memory is loaded in full.
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        // Extract title from first H1, or fall back to filename stem.
        const title = extractTitle(allocator, entry.name, content) catch {
            allocator.free(full_path);
            continue;
        };

        // Own a copy of the filename for the MemoryInfo.
        const name_copy = allocator.dupe(u8, entry.name) catch {
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };

        // Append to the list. On failure, free the strings we just allocated.
        // `errdefer` on the append block handles the error case cleanly.
        list.append(allocator, .{
            .name = name_copy,
            .title = title,
            .path = full_path,
            .size = stat.size,
        }) catch {
            allocator.free(name_copy);
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };
        // On success, the list now owns name_copy, title, and full_path.
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

/// List all .md memory files in a specific directory (no XDG resolution).
pub fn listMemoriesInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) []MemoryInfo {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer std.Io.Dir.close(dir, io);

    var list: std.ArrayList(MemoryInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.title);
            allocator.free(item.path);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        // Only consider regular files (skip subdirectories, symlinks, etc.)
        if (entry.kind != .file) continue;

        // Only consider .md files. Memories are markdown by design.
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Build full path. Use the cross-platform `/`-separator joinPath
        // helper rather than std.fs.path.join (which would produce `\`
        // on Windows and break string-equality tests).
        const full_path = joinPath(allocator, dir_path, entry.name) catch continue;

        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(full_path);
            continue;
        };

        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        const title = extractTitle(allocator, entry.name, content) catch {
            allocator.free(full_path);
            continue;
        };

        const name_copy = allocator.dupe(u8, entry.name) catch {
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };

        list.append(allocator, .{
            .name = name_copy,
            .title = title,
            .path = full_path,
            .size = stat.size,
        }) catch {
            allocator.free(name_copy);
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };
    }

    return list.toOwnedSlice(allocator) catch &.{};
}

/// Extract the title from memory file content. Strategy: 1. Scan the first
/// TITLE_SCAN_LIMIT bytes line by line. 2.
fn extractTitle(
    allocator: std.mem.Allocator,
    filename: []const u8,
    content: []const u8,
) ![]u8 {
    const scan_limit = @min(content.len, TITLE_SCAN_LIMIT);
    var i: usize = 0;
    while (i < scan_limit) {
        // Find end of the current line.
        var line_end = i;
        while (line_end < scan_limit and content[line_end] != '\n') : (line_end += 1) {}
        const line = std.mem.trim(u8, content[i..line_end], " \t\r");

        // Markdown H1: starts with "# " (single hash followed by space).
        if (line.len >= 2 and line[0] == '#' and line[1] == ' ') {
            const rest = std.mem.trim(u8, line[2..], " \t\r");
            return allocator.dupe(u8, rest);
        }

        if (line_end >= scan_limit) break;
        i = line_end + 1;
    }

    // No H1 found — use filename stem (filename minus ".md").
    const stem = if (std.mem.endsWith(u8, filename, ".md"))
        filename[0 .. filename.len - 3]
    else
        filename;
    return allocator.dupe(u8, stem);
}

/// Free a `MemoryInfo` slice allocated by `listAllMemories`. Frees every
/// owned string and the backing slice itself. Safe to call on an empty slice.
pub fn freeMemoriesList(allocator: std.mem.Allocator, list: []MemoryInfo) void {
    for (list) |item| {
        allocator.free(item.name);
        allocator.free(item.title);
        allocator.free(item.path);
    }
    allocator.free(list);
}

// -------------------------------------------------------------------------
// CRUD helpers — used by the settings-menu HTTP handlers (Chunk 3) and
// eventually by the `read_memory` / `write_memory` agent tools.

/// Validate a memory filename.
pub fn isValidMemoryName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (!std.mem.endsWith(u8, trimmed, ".md")) return false;
    if (std.mem.indexOfAny(u8, trimmed, "/\\") != null) return false;
    if (std.mem.indexOf(u8, trimmed, "..") != null) return false;
    return true;
}

/// Read a single global memory file by name (e.g. "user-preferences.md").
/// Returns allocated content the caller owns and must free.
pub fn readMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) ?[]u8 {
    if (!isValidMemoryName(name)) return null;
    const dir_path = get_global_memories_path(allocator, environment) orelse return null;
    defer allocator.free(dir_path);

    const full_path = joinPath(allocator, dir_path, name) catch return null;
    defer allocator.free(full_path);

    return std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    ) catch null;
}

/// Write content to a global memory file. Creates the parent dir if it is
/// missing. Overwrites an existing file with the same name.
pub fn writeMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
    content: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    // Ensure the global memories directory exists. createDirPath is a
    // no-op if the dir already exists, so it is safe on every call.
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch return false;

    const full_path = joinPath(allocator, dir_path, name) catch return false;
    defer allocator.free(full_path);

    // `renameAbsolute` below asserts BOTH paths are absolute and ABORTS the
    // whole process (Debug/ReleaseSafe) when they are not.
    if (!std.fs.path.isAbsolute(full_path)) return false;

    // Atomic-ish: write to a temp file then rename. The temp path is
    // `<dir>/<name>.md.tmp` — an extra `.tmp` suffix on the final filename.
    const tmp_path = allocator.alloc(u8, full_path.len + 4) catch return false;
    defer allocator.free(tmp_path);
    @memcpy(tmp_path[0..full_path.len], full_path);
    @memcpy(tmp_path[full_path.len..][0..4], ".tmp");

    {
        const file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return false;
        defer std.Io.File.close(file, io);
        std.Io.File.writeStreamingAll(file, io, content) catch return false;
    }
    // renameAbsolute asserts both paths are absolute. We joined to an
    // absolute dir_path, so this is safe.
    std.Io.Dir.renameAbsolute(tmp_path, full_path, io) catch return false;
    return true;
}

/// Edit = overwrite an existing memory. Returns `false` if the file does not
/// exist; callers should branch to `writeMemoryFile` for the "create new"
/// case.
pub fn editMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
    content: []const u8,
) !bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);
    const full_path = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(full_path);

    // Fail if the file does not exist — caller can branch to add.
    _ = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch return false;

    return writeMemoryFile(allocator, io, environment, name, content);
}

/// Delete a global memory file by name. Returns `true` on success OR if the
/// file did not exist (idempotent delete — caller does not need to
/// distinguish "was there" from "removed").
pub fn deleteMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    const full_path = joinPath(allocator, dir_path, name) catch return false;
    defer allocator.free(full_path);

    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
        if (err == error.FileNotFound) return true; // idempotent
        return false;
    };
    return true;
}

/// Returns `true` if a memory with the given name exists in the global
/// folder. A validation failure (empty name, no `.md`, path sep, `..`)
/// also returns `false`.
pub fn memoryExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    const full_path = joinPath(allocator, dir_path, name) catch return false;
    defer allocator.free(full_path);

    _ = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch return false;
    return true;
}

// -------------------------------------------------------------------------
// LOCAL memories — scoped to a per-cwd `.pabrik/memories/` directory.

/// Resolve the local memories path from the process's CWD via `io`.
pub fn get_local_memories_path_from_io(
    allocator: std.mem.Allocator,
    io: std.Io,
) ?[]const u8 {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch |err| {
        std.log.debug("Could not get current working directory: {s}", .{@errorName(err)});
        return null;
    };
    return get_local_memories_path_for_dir(allocator, cwd_buf[0..cwd_len]);
}

/// Resolve the local memories path for a given name. The caller passes the
/// full directory path (e.g.
pub fn get_local_memory_file_path(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
) ?[]const u8 {
    if (dir_path.len == 0) return null;
    if (!isValidMemoryName(name)) return null;
    // See get_local_memories_path_for_dir for why we use joinPath instead
    // of std.fs.path.join.
    return joinPath(allocator, dir_path, name) catch null;
}

/// Read a single local memory file by name. The dir is typically obtained
/// from `get_local_memories_path_from_io` /
/// `get_local_memories_path_for_dir`.
pub fn readLocalMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) ?[]u8 {
    const full_path = get_local_memory_file_path(allocator, dir_path, name) orelse return null;
    defer allocator.free(full_path);

    return std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    ) catch null;
}

/// Write content to a local memory file. Creates the parent `<dir_path>`
/// (typically `<cwd>/.pabrik/memories/`) if missing.
pub fn writeLocalMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
    content: []const u8,
) bool {
    if (dir_path.len == 0) return false;
    if (!isValidMemoryName(name)) return false;
    const full_path = joinPath(allocator, dir_path, name) catch return false;
    defer allocator.free(full_path);

    // `renameAbsolute` below asserts BOTH paths are absolute and ABORTS the
    // whole process (Debug/ReleaseSafe) when they are not.
    if (!std.fs.path.isAbsolute(full_path)) return false;

    // Ensure the local memories directory exists. createDirPath is a
    // no-op if the dir already exists, so it is safe on every call.
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch return false;

    // Atomic-ish: write to a temp file then rename. See writeMemoryFile
    // for why we use `@memcpy` instead of `path.join(full_path, ".tmp")`.
    const tmp_path = allocator.alloc(u8, full_path.len + 4) catch return false;
    defer allocator.free(tmp_path);
    @memcpy(tmp_path[0..full_path.len], full_path);
    @memcpy(tmp_path[full_path.len..][0..4], ".tmp");

    {
        const file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return false;
        defer std.Io.File.close(file, io);
        std.Io.File.writeStreamingAll(file, io, content) catch return false;
    }
    std.Io.Dir.renameAbsolute(tmp_path, full_path, io) catch return false;
    return true;
}

/// Delete a local memory file. Idempotent — returns `true` on success
/// OR if the file was already missing. Returns `false` on validation
/// error, missing dir_path, or unexpected IO failure.
pub fn deleteLocalMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) bool {
    const full_path = get_local_memory_file_path(allocator, dir_path, name) orelse return false;
    defer allocator.free(full_path);

    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
        if (err == error.FileNotFound) return true; // idempotent
        return false;
    };
    return true;
}

/// Returns `true` if a local memory with the given name exists.
pub fn localMemoryExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    name: []const u8,
) bool {
    const full_path = get_local_memory_file_path(allocator, dir_path, name) orelse return false;
    defer allocator.free(full_path);

    _ = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch return false;
    return true;
}

const memories = @import("memories.zig");

// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// -------------------------------------------------------------------------
// get_local_memories_path_for_dir — pure function tests
// -------------------------------------------------------------------------

test "get_local_memories_path_for_dir returns <cwd>/.pabrik/memories" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "/tmp/proj");
    defer if (path) |p| alloc.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/proj/.pabrik/memories", path.?);
}

test "get_local_memories_path_for_dir returns null on empty cwd" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "");

    try std.testing.expect(path == null);
}

test "get_local_memories_path_for_dir does not resolve relative paths" {
    // Mirrors get_local_skills_path_for_dir semantics: no realpath
    // resolution. The caller (buildMessages) is responsible for passing
    // an absolute cwd, which it does via realPathFileAlloc.
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "relative/proj");
    defer if (path) |p| alloc.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("relative/proj/.pabrik/memories", path.?);
}

test "get_local_memories_path_for_dir freed slice does not double-free" {
    // Sanity: returned slice is allocator-owned; freeing it does not crash.
    const alloc = std.testing.allocator;
    const path = memories.get_local_memories_path_for_dir(alloc, "/tmp/x");
    try std.testing.expect(path != null);
    alloc.free(path.?);
}

// -------------------------------------------------------------------------
// listMemoriesInDir — filesystem integration tests
// -------------------------------------------------------------------------

test "listMemoriesInDir returns empty slice when dir does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Point at a dir we know is absent.
    const missing_dir = "/tmp/pabrik-list-memories-missing-dir";
    std.Io.Dir.cwd().deleteTree(io, missing_dir) catch {};

    const list = memories.listMemoriesInDir(alloc, io, missing_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "listMemoriesInDir returns empty slice when dir has no .md files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-empty";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    // Drop a non-md file
    const txt_path = "/tmp/pabrik-list-memories-empty/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "listMemoriesInDir skips .txt, .json, and subdirectories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-filter";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    // Create a real .md file
    const md_path = "/tmp/pabrik-list-memories-filter/keep.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, md_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "# Keep Me\n");
    }

    // A .txt file (must be filtered)
    const txt_path = "/tmp/pabrik-list-memories-filter/skip.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "ignore");
    }

    // A .json file (must be filtered)
    const json_path = "/tmp/pabrik-list-memories-filter/skip.json";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, json_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "{}");
    }

    // A subdirectory that should be skipped (no SKILL.MD analogue for memories)
    try std.Io.Dir.cwd().createDirPath(io, "/tmp/pabrik-list-memories-filter/subdir");

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("keep.md", list[0].name);
    try std.testing.expectEqualStrings("Keep Me", list[0].title);
}

test "listMemoriesInDir lists multiple .md files with correct titles" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-multi";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file1 = "/tmp/pabrik-list-memories-multi/after-fix-test.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Write Regression Test First
            \\
            \\After fixing a tricky bug, write a regression test.
            \\
        );
    }

    const file2 = "/tmp/pabrik-list-memories-multi/stderr-debug.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\# Use stderr for Debug Output
            \\
            \\Stderr can be redirected without affecting stdout.
            \\
        );
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);

    // We don't assert on order (dir.iterate order is OS-dependent),
    // just that both files appear with their expected titles.
    var found_after_fix = false;
    var found_stderr = false;
    for (list) |mem| {
        if (std.mem.eql(u8, mem.name, "after-fix-test.md")) {
            try std.testing.expectEqualStrings("Write Regression Test First", mem.title);
            try std.testing.expect(contains(mem.path, "after-fix-test.md"));
            found_after_fix = true;
        } else if (std.mem.eql(u8, mem.name, "stderr-debug.md")) {
            try std.testing.expectEqualStrings("Use stderr for Debug Output", mem.title);
            try std.testing.expect(contains(mem.path, "stderr-debug.md"));
            found_stderr = true;
        }
    }
    try std.testing.expect(found_after_fix);
    try std.testing.expect(found_stderr);
}

test "listMemoriesInDir falls back to filename stem when no H1" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-no-h1";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/pabrik-list-memories-no-h1/random-name.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header.\n");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("random-name.md", list[0].name);
    try std.testing.expectEqualStrings("random-name", list[0].title);
}

test "listMemoriesInDir finds H1 in second line (after blank line)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-h1-second-line";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/pabrik-list-memories-h1-second-line/delayed-h1.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        // First line is prose, second line is the H1
        try std.Io.File.writeStreamingAll(f, io,
            \\Some intro prose that is NOT a heading.
            \\
            \\# The Real Title
            \\
            \\Body content.
            \\
        );
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("The Real Title", list[0].title);
}

test "listMemoriesInDir record path is absolute" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-list-memories-path-check";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const file_path = "/tmp/pabrik-list-memories-path-check/test.md";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "# Test\n");
    }

    const list = memories.listMemoriesInDir(alloc, io, tmp_dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(std.fs.path.isAbsolute(list[0].path));
    try std.testing.expectEqualStrings(file_path, list[0].path);
}

test "listMemoriesInDir free contract: empty list is safe to free" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};
    memories.freeMemoriesList(alloc, list);
    // No panic — success criterion.
}

// -------------------------------------------------------------------------
// CRUD helpers — Chunk 1 of the memories-settings-menu plan.

/// Build a fresh `Environ.Map` with `HOME` set to `home_path`, plus a
/// per-test scratch dir under `/tmp/`.
fn setupMemoryHomeEnv(alloc: std.mem.Allocator, io: std.Io, scratch_name: []const u8) !struct {
    env: std.process.Environ.Map,
    home_path: []u8,
} {
    const home_path = try std.fs.path.join(alloc, &.{ "/tmp", scratch_name });
    errdefer alloc.free(home_path);

    // Clean any leftover state from a previous run, then create the dir.
    std.Io.Dir.cwd().deleteTree(io, home_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home_path);

    var env = std.process.Environ.Map.init(alloc);
    errdefer env.deinit();
    try env.put("HOME", home_path);
    return .{ .env = env, .home_path = home_path };
}

// -------------------------------------------------------------------------
// isValidMemoryName — pure validator tests
// -------------------------------------------------------------------------

test "isValidMemoryName rejects empty, whitespace, no .md, slashes, parent ref" {
    // Reject cases
    const reject = &[_][]const u8{
        "",                  // empty
        "   ",               // whitespace only
        "\t\r\n",            // other whitespace
        "foo",               // no .md
        "foo.txt",           // wrong extension
        "foo.MD",            // case-sensitive — only lowercase .md is OK
        "path/to.md",        // forward slash
        "path\\to.md",       // backslash
        "..",                // bare parent ref
        "../escape.md",      // starts with parent ref
        "subdir/../foo.md",  // contains parent ref anywhere
    };
    for (reject) |name| {
        try std.testing.expect(!memories.isValidMemoryName(name));
    }
}

test "isValidMemoryName accepts simple, hyphenated, and dotted .md names" {
    // Accept cases
    const accept = &[_][]const u8{
        "foo.md",
        "user-preferences.md",
        "user_preferences.md",
        "with.dots.in.name.md", // dots are OK; only ".." is rejected
        "a.md",
        "x-y-z.md",
        "  trimmed.md  ",      // leading/trailing whitespace is trimmed
    };
    for (accept) |name| {
        try std.testing.expect(memories.isValidMemoryName(name));
    }
}

// -------------------------------------------------------------------------
// readMemoryFile — invalid name + missing file
// -------------------------------------------------------------------------

test "readMemoryFile returns null on invalid name" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-invalid-name");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Invalid names should return null even if the file would otherwise
    // be readable — validation is the first guard.
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "no-extension") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "../escape.md") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, &env, "sub/dir.md") == null);
}

test "readMemoryFile returns null on missing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-missing-read");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // No file written yet → null (not a panic / error throw).
    const result = memories.readMemoryFile(alloc, io, &env, "never-written.md");
    try std.testing.expect(result == null);
}

// -------------------------------------------------------------------------
// writeMemoryFile — creates parent dir, overwrites
// -------------------------------------------------------------------------

test "writeMemoryFile creates parent dir if missing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-create-parent");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // The memories/ subdir does not exist yet. writeMemoryFile must
    // create it (via createDirPath) before writing the file.
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "new.md", "# Hello\n"));

    // Read it back to confirm the write actually landed.
    const read_back = memories.readMemoryFile(alloc, io, &env, "new.md");
    try std.testing.expect(read_back != null);
    defer if (read_back) |r| alloc.free(r);
    try std.testing.expectEqualStrings("# Hello\n", read_back.?);
}

test "writeMemoryFile overwrites existing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-overwrite");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // First write
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "mem.md", "v1 content"));
    {
        const r1 = memories.readMemoryFile(alloc, io, &env, "mem.md");
        try std.testing.expect(r1 != null);
        defer if (r1) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v1 content", r1.?);
    }
    // Overwrite with new content
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "mem.md", "v2 content (longer)"));
    {
        const r2 = memories.readMemoryFile(alloc, io, &env, "mem.md");
        try std.testing.expect(r2 != null);
        defer if (r2) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v2 content (longer)", r2.?);
    }
}

// -------------------------------------------------------------------------
// memoryExists — stat-based check
// -------------------------------------------------------------------------

test "memoryExists: false on missing, true after write, false after delete" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-exists");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Missing → false
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "absent.md"));

    // Write → true
    try std.testing.expect(memories.writeMemoryFile(alloc, io, &env, "present.md", "hello"));
    try std.testing.expect(memories.memoryExists(alloc, io, &env, "present.md"));

    // Delete → false
    try std.testing.expect(memories.deleteMemoryFile(alloc, io, &env, "present.md"));
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "present.md"));
}

// -------------------------------------------------------------------------
// deleteMemoryFile — idempotent
// -------------------------------------------------------------------------

test "deleteMemoryFile is idempotent (returns true on missing)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-idem-delete");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Delete a file that was never written — must return true (idempotent).
    try std.testing.expect(memories.deleteMemoryFile(alloc, io, &env, "never.md"));

    // And on an invalid name — must return false (validation is the
    // first guard, so an invalid name short-circuits to false before
    // we even check the FS).
    try std.testing.expect(!memories.deleteMemoryFile(alloc, io, &env, "no-ext"));
    try std.testing.expect(!memories.deleteMemoryFile(alloc, io, &env, "../escape.md"));
}

// -------------------------------------------------------------------------
// editMemoryFile — fails on missing
// -------------------------------------------------------------------------

test "editMemoryFile returns false when target does not exist" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_or_err = try setupMemoryHomeEnv(alloc, io, "pabrik-crud-edit-missing");
    var env = env_or_err.env;
    defer env.deinit();
    defer alloc.free(env_or_err.home_path);
    defer std.Io.Dir.cwd().deleteTree(io, env_or_err.home_path) catch {};

    // Edit on a file that was never written → false.
    const result = try memories.editMemoryFile(alloc, io, &env, "ghost.md", "replacement");
    try std.testing.expect(!result);

    // And the file must NOT have been created as a side-effect — the
    // whole point of edit (vs write) is to require pre-existence.
    try std.testing.expect(!memories.memoryExists(alloc, io, &env, "ghost.md"));
}

// ===========================================================================
// LOCAL memory helpers — get_local_memories_path_from_io,
// get_local_memory_file_path, readLocalMemoryFile, writeLocalMemoryFile,

/// Build a unique empty temp dir and return its absolute path.
/// Caller owns the returned slice.
fn setupLocalDir(alloc: std.mem.Allocator, io: std.Io, label: []const u8) ![]u8 {
    const stamp = std.Io.Clock.now(.real, io).toNanoseconds();
    const path = try std.fmt.allocPrint(
        alloc,
        "/tmp/pabrik-local-mem-{s}-{d}",
        .{ label, stamp },
    );
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

test "get_local_memory_file_path joins dir and name" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memory_file_path(alloc, "/tmp/proj/.pabrik/memories", "foo.md");
    defer if (path) |p| alloc.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/proj/.pabrik/memories/foo.md", path.?);
}

test "get_local_memory_file_path returns null on invalid name" {
    const alloc = std.testing.allocator;
    // `..` segment is rejected by isValidMemoryName (path-traversal guard).
    try std.testing.expect(memories.get_local_memory_file_path(alloc, "/tmp/proj/.pabrik/memories", "../escape.md") == null);
    // Missing `.md` extension is rejected.
    try std.testing.expect(memories.get_local_memory_file_path(alloc, "/tmp/proj/.pabrik/memories", "no-ext") == null);
    // Empty name is rejected.
    try std.testing.expect(memories.get_local_memory_file_path(alloc, "/tmp/proj/.pabrik/memories", "") == null);
}

test "get_local_memory_file_path returns null on empty dir_path" {
    const alloc = std.testing.allocator;
    const path = memories.get_local_memory_file_path(alloc, "", "foo.md");
    try std.testing.expect(path == null);
}

test "writeLocalMemoryFile creates the parent dir if missing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Note: the parent dir does NOT exist when we call writeLocalMemoryFile
    // — the helper is expected to create it (mirrors writeMemoryFile).
    const stamp = std.Io.Clock.now(.real, io).toNanoseconds();
    const dir = try std.fmt.allocPrint(
        alloc,
        "/tmp/pabrik-local-mem-create-dir-{d}/.pabrik/memories",
        .{stamp},
    );
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "new.md", "# Hello\n"));

    const read_back = memories.readLocalMemoryFile(alloc, io, dir, "new.md");
    try std.testing.expect(read_back != null);
    defer if (read_back) |r| alloc.free(r);
    try std.testing.expectEqualStrings("# Hello\n", read_back.?);
}

test "writeLocalMemoryFile refuses a relative dir_path instead of aborting" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // `dir_path` is a request-supplied `cwd` (local_memories_create/update)
    // that nothing validates as absolute.
    try std.testing.expect(!memories.writeLocalMemoryFile(alloc, io, "relative/dir", "m.md", "# Hi\n"));
}

test "writeLocalMemoryFile overwrites existing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "overwrite");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "mem.md", "v1"));
    {
        const r1 = memories.readLocalMemoryFile(alloc, io, dir, "mem.md");
        try std.testing.expect(r1 != null);
        defer if (r1) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v1", r1.?);
    }
    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "mem.md", "v2 (longer)"));
    {
        const r2 = memories.readLocalMemoryFile(alloc, io, dir, "mem.md");
        try std.testing.expect(r2 != null);
        defer if (r2) |r| alloc.free(r);
        try std.testing.expectEqualStrings("v2 (longer)", r2.?);
    }
}

test "writeLocalMemoryFile returns false on invalid name" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "invalid-name");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try std.testing.expect(!memories.writeLocalMemoryFile(alloc, io, dir, "../escape.md", "x"));
    try std.testing.expect(!memories.writeLocalMemoryFile(alloc, io, dir, "no-ext", "x"));
    try std.testing.expect(!memories.writeLocalMemoryFile(alloc, io, dir, "", "x"));
}

test "writeLocalMemoryFile returns false on empty dir_path" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect(!memories.writeLocalMemoryFile(alloc, io, "", "foo.md", "x"));
}

test "readLocalMemoryFile returns null on missing file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "read-missing");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const content = memories.readLocalMemoryFile(alloc, io, dir, "absent.md");
    try std.testing.expect(content == null);
}

test "localMemoryExists: false on missing, true after write, false after delete" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "exists");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Missing → false
    try std.testing.expect(!memories.localMemoryExists(alloc, io, dir, "absent.md"));

    // Write → true
    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "present.md", "hello"));
    try std.testing.expect(memories.localMemoryExists(alloc, io, dir, "present.md"));

    // Delete → false
    try std.testing.expect(memories.deleteLocalMemoryFile(alloc, io, dir, "present.md"));
    try std.testing.expect(!memories.localMemoryExists(alloc, io, dir, "present.md"));
}

test "deleteLocalMemoryFile is idempotent (returns true on missing)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "idem-delete");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Delete a file that was never written — must return true (idempotent).
    try std.testing.expect(memories.deleteLocalMemoryFile(alloc, io, dir, "never.md"));

    // Invalid name → false (validation is the first guard).
    try std.testing.expect(!memories.deleteLocalMemoryFile(alloc, io, dir, "no-ext"));
    try std.testing.expect(!memories.deleteLocalMemoryFile(alloc, io, dir, "../escape.md"));
    // Empty dir_path → false.
    try std.testing.expect(!memories.deleteLocalMemoryFile(alloc, io, "", "foo.md"));
}

test "listMemoriesInDir returns the local memory we just wrote" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const dir = try setupLocalDir(alloc, io, "list-after-write");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "alpha.md", "# Alpha\n"));
    try std.testing.expect(memories.writeLocalMemoryFile(alloc, io, dir, "beta.md", "no h1 here\n"));

    const list = memories.listMemoriesInDir(alloc, io, dir);
    defer memories.freeMemoriesList(alloc, list);

    try std.testing.expectEqual(@as(usize, 2), list.len);

    // Find the alpha entry; verify the title was extracted from the H1.
    var found_alpha = false;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, "alpha.md")) {
            try std.testing.expectEqualStrings("Alpha", m.title);
            found_alpha = true;
        }
    }
    try std.testing.expect(found_alpha);
}
