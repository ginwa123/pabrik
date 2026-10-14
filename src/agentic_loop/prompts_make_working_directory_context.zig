const std = @import("std");
const testing = std.testing;

const memory_files = [_][]const u8{ "PABRIK.md", "CLAUDE.md", "AGENTS.md" };

/// Build a working-directory context by concatenating the contents of
/// `PABRIK.md`, `CLAUDE.md`, and `AGENTS.md` in the given `cwd`.
pub fn makeWorkingDirectoryContext(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    const effective_cwd = if (cwd.len == 0) "." else cwd;
    const absolute_cwd = if (std.fs.path.isAbsolute(effective_cwd))
        try allocator.dupe(u8, effective_cwd)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, effective_cwd, allocator);
    defer allocator.free(absolute_cwd);

    for (memory_files) |filename| {
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ absolute_cwd, filename });
        defer allocator.free(file_path);

        // Open the file for reading. If it doesn't exist, skip — do NOT
        // create it. Force-creating an empty markdown file pollutes
        // freshly-cloned repos every time the agent starts a session.
        const file = std.Io.Dir.openFileAbsolute(io, file_path, .{
            .mode = .read_only,
        }) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer std.Io.File.close(file, io);

        const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(std.math.maxInt(usize)));
        defer allocator.free(content);

        try result.appendSlice(allocator, content);

        if (content.len > 0 and content[content.len - 1] != '\n') {
            try result.append(allocator, '\n');
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ─── Tests ─────────────────────────────────────────────────────────── These
// tests are INLINE in the impl file (not a separate `*_test.zig`) per the
// project's prevailing pattern — see `session_skills.zig`, `handle_tool.zig`,

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp.cleanup();
    }
};

fn setupTmpDir(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const abs = try allocator.dupe(u8, path_buf[0..n]);
    return .{ .tmp = tmp, .root_abs = abs };
}

fn listDirContainsAnyOf(dir_path: []const u8, names: []const []const u8) !bool {
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, dir_path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        for (names) |name| {
            if (std.mem.eql(u8, entry.name, name)) {
                return true;
            }
        }
    }
    return false;
}

fn writeFileAbsolute(path: []const u8, content: []const u8) !void {
    var f = try std.Io.Dir.createFileAbsolute(testing.io, path, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, content);
}

test "makeWorkingDirectoryContext: no memory files present returns empty" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}

test "makeWorkingDirectoryContext: never creates a missing memory file (the smoking gun)" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Before the call: directory is empty.
    try testing.expect(!try listDirContainsAnyOf(env.root_abs, &.{
        "PABRIK.md", "CLAUDE.md", "AGENTS.md",
    }));

    // Call the helper. None of the three memory files exist.
    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    // After the call: directory is STILL empty — no AGENTS.md was created.
    try testing.expect(!try listDirContainsAnyOf(env.root_abs, &.{
        "PABRIK.md", "CLAUDE.md", "AGENTS.md",
    }));
    try testing.expectEqualStrings("", result);
}

test "makeWorkingDirectoryContext: only AGENTS.md present → returns its content, no others created" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const agents_path = try std.fs.path.join(alloc, &.{ env.root_abs, "AGENTS.md" });
    defer alloc.free(agents_path);
    try writeFileAbsolute(agents_path, "# Agents\nRead me first.\n");

    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    // Only AGENTS.md was created; PABRIK.md / CLAUDE.md must NOT be created.
    try testing.expect(try listDirContainsAnyOf(env.root_abs, &.{"AGENTS.md"}));
    try testing.expect(!try listDirContainsAnyOf(env.root_abs, &.{"PABRIK.md"}));
    try testing.expect(!try listDirContainsAnyOf(env.root_abs, &.{"CLAUDE.md"}));

    // Result contains the file content with a trailing newline.
    try testing.expectEqualStrings("# Agents\nRead me first.\n", result);
}

test "makeWorkingDirectoryContext: all three files concatenated in canonical order" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Write files in REVERSE order to verify the function reads them
    // in PABRIK / CLAUDE / AGENTS order regardless of insertion order.
    inline for ([_][]const u8{ "AGENTS.md", "CLAUDE.md", "PABRIK.md" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ env.root_abs, name });
        defer alloc.free(p);
        const content = std.fmt.comptimePrint("# {s}\n", .{name[0 .. name.len - 3]});
        try writeFileAbsolute(p, content);
    }

    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    try testing.expectEqualStrings(
        \\# PABRIK
        \\# CLAUDE
        \\# AGENTS
        \\
    , result);
}

test "makeWorkingDirectoryContext: file without trailing newline still gets a separator" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try std.fs.path.join(alloc, &.{ env.root_abs, "PABRIK.md" });
    defer alloc.free(a);
    const b = try std.fs.path.join(alloc, &.{ env.root_abs, "CLAUDE.md" });
    defer alloc.free(b);
    try writeFileAbsolute(a, "no-newline");   // 10 chars, no \n
    try writeFileAbsolute(b, "block\n");

    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    // The first file's content gets a trailing newline so the next
    // file's content doesn't accidentally concatenate onto it.
    try testing.expectEqualStrings("no-newline\nblock\n", result);
}

test "makeWorkingDirectoryContext: empty file contributes nothing extra" {
    const alloc = testing.allocator;
    var env = try setupTmpDir(alloc);
    defer env.deinit(alloc);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try std.fs.path.join(alloc, &.{ env.root_abs, "PABRIK.md" });
    defer alloc.free(a);
    const b = try std.fs.path.join(alloc, &.{ env.root_abs, "AGENTS.md" });
    defer alloc.free(b);
    try writeFileAbsolute(a, "");        // empty file
    try writeFileAbsolute(b, "agents\n");

    const result = try makeWorkingDirectoryContext(alloc, io, env.root_abs);
    defer alloc.free(result);

    // Empty file must produce zero content (no separator, no pad).
    try testing.expectEqualStrings("agents\n", result);
}