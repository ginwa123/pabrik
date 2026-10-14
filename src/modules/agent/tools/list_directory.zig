//! src/modules/agent/tools/list_directory.zig
//!
//! Agent tool: list first-level entries in a directory (like `ls <path>`).
//! Companion to `glob` (which finds files by pattern, recursive) —
//! `list_directory` answers "what's in this folder?" with one level.
//!
//! PATH HANDLING: `execute_list_directory` takes an ABSOLUTE path only —
//! it calls `std.Io.Dir.openDirAbsolute`, whose precondition is
//! `assert(path.isAbsolute(...))`. In a Debug build that assert is
//! `unreachable`, so a relative path aborts the process instead of
//! returning an error.
//!
//! The LLM-facing `path` may be relative (the tool description promises it
//! resolves against the session's cwd), so the `execListDirectory` wrapper
//! in src/agentic_loop/tools_exec_list_directory.zig resolves it against
//! `ctx.cwd` before calling in here. As defence in depth,
//! `execute_list_directory` itself returns `error.PathNotAbsolute` for a
//! relative path rather than reaching the asserting API.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;

/// Per-entry result returned by the iterator. Owned by the caller (use
/// `freeEntries`).
pub const Entry = struct {
    name: []const u8,
    /// Absolute path, e.g. `/home/user/project/src/main.zig`.
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
    }
    allocator.free(entries);
}

/// `dir_path_abs` MUST be an absolute path. Relative LLM input is resolved
/// against the session cwd by the exec wrapper before it gets here; the
/// guard below keeps any other caller from triggering `openDirAbsolute`'s
/// assertion (which panics and aborts the worker rather than erroring).
///
/// Behaviour:
/// - Relative path → returns `error.PathNotAbsolute`
/// - Non-existent / non-directory path → returns `error.PathNotFound`
/// - Hidden entries (`.foo`) are skipped unless `hidden == true`
/// - `respect_ignore_files == true` (default) → entries ignored by
///   `git check-ignore` (when run from inside a git repo) are filtered
/// - Results sorted: directories first, then files, alphabetically
pub fn execute_list_directory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path_abs: []const u8,
    hidden: bool,
    respect_ignore_files: bool,
) ![]Entry {
    // Defence in depth — `openDirAbsolute` below asserts
    // `path.isAbsolute(...)`, and that assert is `unreachable` in a Debug
    // build: it panics and aborts the whole worker (sig 6) instead of
    // returning an error, which no `catch` up the stack can intercept.
    // The exec wrapper resolves relative LLM input against the session cwd
    // first, so this only fires for a direct caller passing a relative
    // path; fail that caller cleanly.
    if (!std.fs.path.isAbsolute(dir_path_abs)) return error.PathNotAbsolute;

    var entries = std.ArrayList(Entry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        entries.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path_abs, .{ .iterate = true }) catch {
        return error.PathNotFound;
    };
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = entry.name;
        if (name.len == 0) break;

        // Skip hidden files/folders unless caller asked for them.
        if (!hidden and name.len > 0 and name[0] == '.') continue;

        const is_dir = entry.kind == .directory;
        const is_link = entry.kind == .sym_link;
        const is_file = entry.kind == .file;

        if (!is_dir and !is_file) continue;

        // Gitignore check (when enabled). Spawn failures (no `git`
        // on PATH) are FALL-THROUGH-OK — treat as "not gitignored"
        // so the entry is shown rather than silently dropped.
        if (respect_ignore_files) {
            const git_result = std.process.run(allocator, io, .{
                .argv = &.{ "git", "-C", dir_path_abs, "check-ignore", name },
            }) catch blk: {
                break :blk std.process.RunResult{
                    .term = .{ .exited = 128 },
                    .stdout = &[_]u8{},
                    .stderr = &[_]u8{},
                };
            };
            defer allocator.free(git_result.stdout);
            defer allocator.free(git_result.stderr);
            if (git_result.term.exited == 0) continue; // gitignored → skip
        }

        const entry_name = allocator.dupe(u8, name) catch continue;
        const full_path = std.fs.path.join(allocator, &.{ dir_path_abs, name }) catch {
            allocator.free(entry_name);
            continue;
        };

        entries.append(allocator, Entry{
            .name = entry_name,
            .path = full_path,
            .is_directory = is_dir,
            .is_symlink = is_link,
        }) catch {
            allocator.free(entry_name);
            allocator.free(full_path);
            continue;
        };
    }

    // Sort: directories first, then files, alphabetically.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.is_directory != b.is_directory) return a.is_directory;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);

    return entries.toOwnedSlice(allocator);
}

/// JSON payload mirrors the old `<directory_listing>` envelope 1:1:
/// `path`, `count`, and `entries` (one object per former `<file>` /
/// `<directory>` tag with `name`, `path`, `is_directory`, `is_symlink`).
/// `std.json` handles all escaping.
pub const ListDirectoryEntryJSON = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

pub const ListDirectoryJSON = struct {
    path: []const u8,
    count: usize,
    entries: []ListDirectoryEntryJSON,
};

pub fn toJSON(allocator: std.mem.Allocator, entries: []const Entry, dir_path: []const u8) ![]u8 {
    const items = try allocator.alloc(ListDirectoryEntryJSON, entries.len);
    defer allocator.free(items);
    for (entries, 0..) |e, i| {
        items[i] = .{
            .name = e.name,
            .path = e.path,
            .is_directory = e.is_directory,
            .is_symlink = e.is_symlink,
        };
    }
    return try std.json.Stringify.valueAlloc(allocator, ListDirectoryJSON{
        .path = dir_path,
        .count = entries.len,
        .entries = items,
    }, .{});
}

/// Tool definition for the LLM-facing API.
pub const list_directory_tool_system_prompt =
    \\## List Directory Tool — Behavior
    \\Use `list_directory` to list first-level entries in a directory (like `ls`).
    \\- `cwd` is REQUIRED: the absolute directory this call works in. `path` is the directory to list, absolute or relative to `cwd` (default: `cwd` itself).
    \\- Respects `.gitignore`. Set `hidden=true` to include dotfiles.
    \\- Use to explore project structure before diving into files.
    \\
;

pub const list_directory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_directory",
        .description =
        \\List first-level entries in a directory (like `ls <path>`).
        \\Companion to `glob` (which finds files by pattern, recursive).
        \\
        \\Respects `.gitignore` by default — entries ignored by git
        \\are filtered out. Hidden files (starting with `.`) are
        \\skipped unless `hidden=true`.
        \\
        \\Results are sorted: directories first, then files, alphabetically.
        \\Each entry is an object {name, path, is_directory, is_symlink}
        \\inside `entries`, with `path` and `count` alongside.
        \\
        \\`cwd` is REQUIRED and must be absolute: it is the directory this
        \\call works in. `path` may be relative — it is resolved against
        \\`cwd` — or absolute, in which case it is used as-is. Every
        \\entry's `path` is absolute.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Directory to list. Absolute, or relative to `cwd`. Default: `cwd` itself.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "REQUIRED. Absolute path to the directory this call works in. A relative `path` resolves against it; an absolute `path` is used as-is. Pass the tree you are actually editing (your worktree root, NOT the server's directory).",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Include hidden files/folders (starting with .). Default: false.",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Respect .gitignore (entries ignored by git are filtered out). Default: true. Set false to list gitignored paths (build/, .zig-cache/, .git/, etc.).",
                },
            },
            .required = &.{"cwd"},
        },
        .system_prompt = list_directory_tool_system_prompt,
    },
};

// src/modules/agent/tools/list_directory_test.zig
//
// Tests for the list_directory agent tool: first-level directory
// listing (ls-like). Companion to glob_test.zig (recursive pattern
// matching).
//
// These tests are RUN IN-ISOLATION against `testing.tmpDir(.{})`
// (Zig 0.16 stdlib helper). They do NOT touch ctx.cwd — they call
// `execute_list_directory` directly with an absolute path resolved by
// the test. The exec wrapper is tested in
// src/agentic_loop/tools_exec_list_directory_test.zig.

const builtin = @import("builtin");
const testing = std.testing;
const list_directory = @import("list_directory.zig");
const absPath = @import("helpers").test_path.absPath;

const TestEnv = struct {
    tmp_dir: std.testing.TmpDir,
    root_abs: []const u8,

    fn deinit(self: *TestEnv, allocator: std.mem.Allocator) void {
        allocator.free(self.root_abs);
        self.tmp_dir.cleanup();
    }
};

fn setupRoot(allocator: std.mem.Allocator) !TestEnv {
    var tmp = std.testing.tmpDir(.{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    return .{ .tmp_dir = tmp, .root_abs = try allocator.dupe(u8, path_buf[0..n]) };
}

// -------------------------------------------------------------------------
// execute_list_directory — basic happy paths
// -------------------------------------------------------------------------

test "execute_list_directory: lists files and subdirs at the cwd" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Create: 2 files + 1 subdir + 1 hidden file
    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.txt", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, "bar.md", .{});
        defer f2.close(testing.io);
        try env.tmp_dir.dir.createDirPath(testing.io, "subdir");
        const f3 = try env.tmp_dir.dir.createFile(testing.io, ".hidden", .{});
        defer f3.close(testing.io);
    }

    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false, // hidden
        false, // respect_ignore_files (gitignore lookup skipped — speed)
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 3), entries.len); // foo, bar, subdir — NOT .hidden

    // Dirs-first sort: subdir first.
    try testing.expectEqualStrings("subdir", entries[0].name);
    try testing.expect(entries[0].is_directory);
    try testing.expectEqualStrings("bar.md", entries[1].name);
    try testing.expect(!entries[1].is_directory);
    try testing.expectEqualStrings("foo.txt", entries[2].name);
    try testing.expect(!entries[2].is_directory);
}

test "execute_list_directory: hidden=true includes dotfiles" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "visible.txt", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, ".hidden", .{});
        defer f2.close(testing.io);
    }

    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        true,
        false,
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    // alphabetical: .hidden < visible.txt
    try testing.expectEqualStrings(".hidden", entries[0].name);
    try testing.expectEqualStrings("visible.txt", entries[1].name);
}

test "execute_list_directory: returns PathNotAbsolute for a relative path (no panic)" {
    const alloc = testing.allocator;

    // `openDirAbsolute` asserts `path.isAbsolute(...)`; in a Debug build that
    // assertion is `unreachable` → panic → abort(), killing the whole worker.
    // A direct caller passing a relative path must get an error instead.
    for ([_][]const u8{ ".", "frontend/src", "" }) |relative| {
        const result = list_directory.execute_list_directory(
            alloc,
            testing.io,
            relative,
            false,
            false,
        );
        try testing.expectError(error.PathNotAbsolute, result);
    }
}

test "execute_list_directory: returns PathNotFound for missing dir" {
    const alloc = testing.allocator;

    // An ABSOLUTE name under the cwd: a hardcoded `/tmp/...` would be
    // rooted-but-driveless on Windows, so `std.fs.path.isAbsolute` (which
    // dispatches to `isAbsoluteWindows` there) would reject it as
    // `PathNotAbsolute` and the test would prove the wrong thing.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try absPath(&path_buf, "this_path_definitely_does_not_exist_xyz_123");

    const result = list_directory.execute_list_directory(
        alloc,
        testing.io,
        missing,
        false,
        false,
    );
    try testing.expectError(error.PathNotFound, result);
}

test "execute_list_directory: respects .gitignore (gitignored entries filtered)" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Git init + write a .gitignore that ignores *.log
    const git_init = std.process.run(alloc, testing.io, .{
        .argv = &.{ "git", "-C", env.root_abs, "init", "--initial-branch=main", "--quiet" },
    }) catch null;
    if (git_init) |gr| {
        alloc.free(gr.stdout);
        alloc.free(gr.stderr);
    }
    {
        try env.tmp_dir.dir.writeFile(testing.io, .{
            .sub_path = ".gitignore",
            .data = "*.log\n",
        });
    }

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.log", .{});
        defer f1.close(testing.io);
        const f2 = try env.tmp_dir.dir.createFile(testing.io, "bar.txt", .{});
        defer f2.close(testing.io);
    }
    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        true,
    );
    defer list_directory.freeEntries(alloc, entries);

    // bar.txt should be present, foo.log should be filtered.
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("bar.txt", entries[0].name);
}

test "execute_list_directory: respect_ignore_files=false lists gitignored paths" {
    const alloc = testing.allocator;
    var env = try setupRoot(alloc);
    defer env.deinit(alloc);

    // Set up a gitignore like the previous test.
    const git_init = std.process.run(alloc, testing.io, .{
        .argv = &.{ "git", "-C", env.root_abs, "init", "--initial-branch=main", "--quiet" },
    }) catch null;
    if (git_init) |gr| {
        alloc.free(gr.stdout);
        alloc.free(gr.stderr);
    }
    {
        try env.tmp_dir.dir.writeFile(testing.io, .{
            .sub_path = ".gitignore",
            .data = "*.log\n",
        });
    }

    {
        const f1 = try env.tmp_dir.dir.createFile(testing.io, "foo.log", .{});
        defer f1.close(testing.io);
    }

    // respect_ignore_files=false → foo.log is listed despite .gitignore.
    const entries = try list_directory.execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        false,
    );
    defer list_directory.freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("foo.log", entries[0].name);
}

// -------------------------------------------------------------------------
// toJSON — JSON envelope
// -------------------------------------------------------------------------

test "toJSON: emits path, count and entries" {
    const alloc = testing.allocator;

    const entries = &[_]list_directory.Entry{
        .{ .name = "src", .path = "/proj/src", .is_directory = true, .is_symlink = false },
        .{ .name = "main.zig", .path = "/proj/main.zig", .is_directory = false, .is_symlink = false },
    };

    const payload = try list_directory.toJSON(alloc, entries, "/proj");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/proj", obj.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), obj.get("count").?.integer);
    const items = obj.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("src", items[0].object.get("name").?.string);
    try testing.expectEqualStrings("/proj/src", items[0].object.get("path").?.string);
    try testing.expect(items[0].object.get("is_directory").?.bool);
    try testing.expect(!items[0].object.get("is_symlink").?.bool);
    try testing.expectEqualStrings("main.zig", items[1].object.get("name").?.string);
    try testing.expect(!items[1].object.get("is_directory").?.bool);
}

test "toJSON: empty list produces empty entries array" {
    const alloc = testing.allocator;
    const entries = &[_]list_directory.Entry{};

    const payload = try list_directory.toJSON(alloc, entries, "/empty");
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), obj.get("count").?.integer);
    try testing.expectEqual(@as(usize, 0), obj.get("entries").?.array.items.len);
}

// Schema contract — mirrors the static-contract tests in glob_test.zig
// -------------------------------------------------------------------------

test "list_directory_tool schema: name is list_directory, parameters object with 3 properties" {
    const params = list_directory.list_directory_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 4), params.properties.len);

    var found_path = false;
    var found_hidden = false;
    var found_ignore = false;
    var found_cwd = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) found_path = true;
        if (std.mem.eql(u8, prop.name, "hidden")) found_hidden = true;
        if (std.mem.eql(u8, prop.name, "respect_ignore_files")) found_ignore = true;
        if (std.mem.eql(u8, prop.name, "cwd")) found_cwd = true;
    }
    try testing.expect(found_path);
    try testing.expect(found_hidden);
    try testing.expect(found_ignore);
    try testing.expect(found_cwd);

    // `cwd` is the ONLY required field: `path` still defaults to the call's
    // cwd, but the model must state which directory it is working in.
    try testing.expectEqual(@as(usize, 1), params.required.len);
    try testing.expectEqualStrings("cwd", params.required[0]);
}

test "list_directory_tool description documents the cwd + path contract" {
    // The DESCRIPTION is the product here: it is the only text the model
    // reads before choosing arguments, so its promises are the contract the
    // exec wrapper implements (helpers/path_validate.zig's validateCwd +
    // resolveAgainstCwd). A `path` promise with no `cwd` requirement would
    // describe a rule the tool no longer has.
    const desc = list_directory.list_directory_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "`cwd` is REQUIRED") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "resolved against") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "used as-is") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "rejected") == null);

    var found_path = false;
    var found_cwd = false;
    for (list_directory.list_directory_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) {
            found_path = true;
            try testing.expect(std.mem.indexOf(u8, prop.description, "relative to `cwd`") != null);
        }
        if (std.mem.eql(u8, prop.name, "cwd")) {
            found_cwd = true;
            try testing.expect(std.mem.indexOf(u8, prop.description, "REQUIRED") != null);
        }
    }
    try testing.expect(found_path);
    try testing.expect(found_cwd);

    // The schema must actually require it — a described-but-optional `cwd`
    // would let the model omit the one argument the resolution depends on.
    var required_cwd = false;
    for (list_directory.list_directory_tool.function.parameters.required) |name| {
        if (std.mem.eql(u8, name, "cwd")) required_cwd = true;
    }
    try testing.expect(required_cwd);
}
