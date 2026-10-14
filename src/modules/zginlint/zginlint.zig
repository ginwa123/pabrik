//! zginlint — a linter for Zig source, in the shape of ESLint.
//! A rule takes source text and appends diagnostics; everything else is
//! shared here. See README.md for the rules and CODING_STANDARDS.md §4.

const std = @import("std");
const comment_scan = @import("comment_scan.zig");
const diagnostic = @import("diagnostic.zig");
const io_util = @import("io_util.zig");
const max_comment_lines_rule = @import("rules/max_comment_lines.zig");

pub const Diagnostic = diagnostic.Diagnostic;
pub const diagnosticMessage = diagnostic.message;
pub const Options = struct {
    /// Ceiling on the lines one comment block may span.
    max_comment_lines: u32 = max_comment_lines_rule.default_max_lines,
};

/// Every diagnostic a single file produced, with the path it came from.
pub const FileFindings = struct {
    /// The path as the caller spelled it: relative when the argument was.
    path: []const u8,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *FileFindings, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.diagnostics);
        self.* = .{ .path = &.{}, .diagnostics = &.{} };
    }
};

/// Free a result set built by `lintPaths`.
pub fn deinitFindings(allocator: std.mem.Allocator, reports: []FileFindings) void {
    for (reports) |*report| report.deinit(allocator);
    allocator.free(reports);
}

/// Lint source text. Diagnostics come back in source order.
pub fn lintSource(allocator: std.mem.Allocator, source: []const u8, options: Options) ![]Diagnostic {
    var found: std.ArrayList(Diagnostic) = .empty;
    errdefer found.deinit(allocator);
    try max_comment_lines_rule.check(
        allocator,
        source,
        .{ .max_lines = options.max_comment_lines },
        &found,
    );
    return found.toOwnedSlice(allocator);
}

/// Lint every `.zig` file under `paths`, sorted by path so a run is
/// reproducible whatever order the filesystem hands its entries back in.
pub fn lintPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    options: Options,
) ![]FileFindings {
    var reports: std.ArrayList(FileFindings) = .empty;
    errdefer {
        for (reports.items) |*report| report.deinit(allocator);
        reports.deinit(allocator);
    }
    for (paths) |path| try lintPath(allocator, io, path, options, &reports);
    std.mem.sort(FileFindings, reports.items, {}, byPath);
    return reports.toOwnedSlice(allocator);
}

/// One path argument: a file lints as itself, a directory lints recursively.
pub fn lintPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
) !void {
    const dir = openRootDir(io, path) catch {
        return appendFile(allocator, io, path, path, options, out);
    };
    defer dir.close(io);
    try lintDir(allocator, io, dir, path, options, out);
}

/// Lint a directory's tree, reporting children under `display_path`.
pub fn lintDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    display_path: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
) !void {
    try lintTree(allocator, io, dir, display_path, options, out, 0);
}

const zig_extension = ".zig";
/// Directory names never worth descending into. A tree that carries a
/// build directory has thousands of copies of the same file in it.
const skipped_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out" };
/// Depth guard, so a pathological tree fails loudly instead of hanging.
const max_depth = 64;

fn lintTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    display_path: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
    depth: usize,
) !void {
    if (depth > max_depth) return error.TreeTooDeep;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (isSkippedDir(entry.name)) continue;
                const child = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                defer child.close(io);
                const child_path = try io_util.join(allocator, display_path, entry.name);
                defer allocator.free(child_path);
                try lintTree(allocator, io, child, child_path, options, out, depth + 1);
            },
            .file => try appendEntry(allocator, io, dir, entry, display_path, options, out),
            // A kind this filesystem could not classify is still worth a
            // look: skipping it would report a clean tree it never read.
            .unknown => {
                if (isSkippedDir(entry.name)) continue;
                const child = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch {
                    try appendEntry(allocator, io, dir, entry, display_path, options, out);
                    continue;
                };
                defer child.close(io);
                const child_path = try io_util.join(allocator, display_path, entry.name);
                defer allocator.free(child_path);
                try lintTree(allocator, io, child, child_path, options, out, depth + 1);
            },
            else => continue,
        }
    }
}

fn appendEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    entry: std.Io.Dir.Entry,
    display_path: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
) !void {
    if (!std.mem.endsWith(u8, entry.name, zig_extension)) return;
    const path = try io_util.join(allocator, display_path, entry.name);
    errdefer allocator.free(path);
    const source = try dir.readFileAlloc(io, entry.name, allocator, .unlimited);
    defer allocator.free(source);
    try appendFindings(allocator, path, source, options, out);
}

fn appendFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    read_path: []const u8,
    display_path: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
) !void {
    const path = try allocator.dupe(u8, display_path);
    errdefer allocator.free(path);
    const source = try io_util.readFileAlloc(allocator, io, read_path);
    defer allocator.free(source);
    try appendFindings(allocator, path, source, options, out);
}

fn appendFindings(
    allocator: std.mem.Allocator,
    path: []u8,
    source: []const u8,
    options: Options,
    out: *std.ArrayList(FileFindings),
) !void {
    const found = try lintSource(allocator, source, options);
    if (found.len == 0) {
        allocator.free(found);
        allocator.free(path);
        return;
    }
    try out.append(allocator, .{ .path = path, .diagnostics = found });
}

fn openRootDir(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn isSkippedDir(name: []const u8) bool {
    for (skipped_dirs) |skipped| if (std.mem.eql(u8, skipped, name)) return true;
    return false;
}

fn byPath(_: void, left: FileFindings, right: FileFindings) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

const testing = std.testing;

fn writeFixtureTree(dir: std.Io.Dir) !void {
    try dir.createDirPath(testing.io, "nested");
    try dir.writeFile(testing.io, .{
        .sub_path = "clean.zig",
        .data = "// one\n// two\n// three\nconst x = 1;\n",
    });
    try dir.writeFile(testing.io, .{
        .sub_path = "nested/long.zig",
        .data = "// one\n// two\n// three\n// four\n",
    });
    try dir.writeFile(testing.io, .{
        .sub_path = "nested/notes.md",
        .data = "// one\n// two\n// three\n// four\n",
    });
}

fn rootOf(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    return buffer[0..try tmp.dir.realPath(testing.io, buffer)];
}

test "zginlint: lintSource reports the long block of a source string" {
    const found = try lintSource(testing.allocator, "// a\n// b\n// c\n// d\n", .{});
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].line);
}

test "zginlint: lintPaths walks nested directories and only .zig files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtureTree(tmp.dir);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    const reports = try lintPaths(testing.allocator, testing.io, &.{root}, .{});
    defer deinitFindings(testing.allocator, reports);

    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expect(std.mem.endsWith(u8, reports[0].path, "nested/long.zig"));
    try testing.expectEqual(@as(usize, 1), reports[0].diagnostics.len);
}

test "zginlint: lintPaths sorts its report by path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtureTree(tmp.dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "aaa.zig", .data = "// a\n// b\n// c\n// d\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    const reports = try lintPaths(testing.allocator, testing.io, &.{root}, .{});
    defer deinitFindings(testing.allocator, reports);

    try testing.expectEqual(@as(usize, 2), reports.len);
    try testing.expect(std.mem.endsWith(u8, reports[0].path, "aaa.zig"));
    try testing.expect(std.mem.endsWith(u8, reports[1].path, "nested/long.zig"));
}

test "zginlint: a clean tree reports nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "clean.zig", .data = "// one\n// two\n// three\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    const reports = try lintPaths(testing.allocator, testing.io, &.{root}, .{});
    defer deinitFindings(testing.allocator, reports);
    try testing.expectEqual(@as(usize, 0), reports.len);
}

test "zginlint: a single file path lints that file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "long.zig", .data = "// a\n// b\n// c\n// d\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/long.zig", .{root});
    defer testing.allocator.free(file);

    const reports = try lintPaths(testing.allocator, testing.io, &.{file}, .{});
    defer deinitFindings(testing.allocator, reports);

    try testing.expectEqual(@as(usize, 1), reports.len);
    try testing.expectEqualStrings(file, reports[0].path);
}

test "zginlint: the ceiling reaches the rule through Options" {
    const found = try lintSource(testing.allocator, "// a\n// b\n", .{ .max_comment_lines = 1 });
    defer testing.allocator.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(u32, 1), found[0].max_lines);
}

test "zginlint: a missing path is an error, not an empty report" {
    const reports = lintPaths(testing.allocator, testing.io, &.{"no/such/path/here.zig"}, .{});
    try testing.expectError(error.FileNotFound, reports);
}

test "zginlint: a build directory is not descended into" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "zig-out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zig-out/copy.zig", .data = "// a\n// b\n// c\n// d\n" });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try rootOf(&tmp, &path_buffer);

    const reports = try lintPaths(testing.allocator, testing.io, &.{root}, .{});
    defer deinitFindings(testing.allocator, reports);
    try testing.expectEqual(@as(usize, 0), reports.len);
}

test "zginlint: comment_scan is reachable from the library root" {
    const blocks = try comment_scan.commentBlocks(testing.allocator, "// one\nconst x = 1;\n");
    defer testing.allocator.free(blocks);
    try testing.expectEqual(@as(u32, 1), blocks[0].line_count);
}
