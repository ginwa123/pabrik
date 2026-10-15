//! src/modules/agent/tools/zig Agent tool: list first-level
//! entries in a directory (like `ls <path>`).

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

/// `dir_path_abs` MUST be an absolute path.
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

/// JSON payload mirrors the old `<directory_listing>` envelope 1:1: `path`,
/// `count`, and `entries` (one object per former `<file>` / `<directory>` tag
/// with `name`, `path`, `is_directory`, `is_symlink`).
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
        \\List first-level entries in a directory (like `ls <path>`) — the non-recursive companion to `glob`.
        \\
        \\Sorted: directories first, then files, alphabetically. The payload is
        \\{path, count, entries:[{name, path, is_directory, is_symlink}]}, and every
        \\entry's `path` is absolute.
        \\
        \\Respects `.gitignore` by default. Hidden entries (starting with `.`) are skipped
        \\unless `hidden=true`.
        \\
        \\`cwd` is REQUIRED and must be absolute. `path` may be relative — resolved against
        \\`cwd` — or absolute, in which case it is used as-is.
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
                    .description = "REQUIRED. Absolute path to the directory this call works in. Pass the tree you are actually editing (your worktree root, NOT the server's directory).",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Include hidden files/folders (starting with .). Default: false.",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Default: true. Set false to list gitignored paths (build/, .zig-cache/, .git/, etc.).",
                },
            },
            .required = &.{"cwd"},
        },
        .system_prompt = list_directory_tool_system_prompt,
    },
};

// src/modules/agent/tools/list_directory_test.zig Tests for the
// list_directory agent tool: first-level directory listing (ls-like).
// Companion to glob_test.zig (recursive pattern matching).

const builtin = @import("builtin");
const testing = std.testing;
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

    const entries = try execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false, // hidden
        false, // respect_ignore_files (gitignore lookup skipped — speed)
    );
    defer freeEntries(alloc, entries);

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

    const entries = try execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        true,
        false,
    );
    defer freeEntries(alloc, entries);

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
        const result = execute_list_directory(
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
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try absPath(&path_buf, "this_path_definitely_does_not_exist_xyz_123");

    const result = execute_list_directory(
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
    const entries = try execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        true,
    );
    defer freeEntries(alloc, entries);

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
    const entries = try execute_list_directory(
        alloc,
        testing.io,
        env.root_abs,
        false,
        false,
    );
    defer freeEntries(alloc, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("foo.log", entries[0].name);
}

// -------------------------------------------------------------------------
// toJSON — JSON envelope
// -------------------------------------------------------------------------

test "toJSON: emits path, count and entries" {
    const alloc = testing.allocator;

    const entries = &[_]Entry{
        .{ .name = "src", .path = "/proj/src", .is_directory = true, .is_symlink = false },
        .{ .name = "main.zig", .path = "/proj/main.zig", .is_directory = false, .is_symlink = false },
    };

    const payload = try toJSON(alloc, entries, "/proj");
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
    const entries = &[_]Entry{};

    const payload = try toJSON(alloc, entries, "/empty");
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
    const params = list_directory_tool.function.parameters;
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
    const desc = list_directory_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, desc, "`cwd` is REQUIRED") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "resolved against") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "used as-is") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "rejected") == null);

    var found_path = false;
    var found_cwd = false;
    for (list_directory_tool.function.parameters.properties) |prop| {
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
    for (list_directory_tool.function.parameters.required) |name| {
        if (std.mem.eql(u8, name, "cwd")) required_cwd = true;
    }
    try testing.expect(required_cwd);
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;
const exec_testing = std.testing;
const ListDirectoryInput = struct {
    path: []const u8 = ".",
    hidden: bool = false,
    respect_ignore_files: bool = true,
    /// REQUIRED on the wire. Absolute directory this call works in; a
    /// relative `path` resolves against it. Empty by default so this struct
    /// stays constructible, but the exec rejects an empty value.
    cwd: []const u8 = "",
};

pub fn execListDirectory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // 1. Parse JSON (path/hidden/respect_ignore_files; all optional).
    const parsed = std.json.parseFromSlice(
        ListDirectoryInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. `cwd` is required (see helpers/path_validate.validateCwd), and the
    //    model's directory resolves against it.
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // 2b. Resolve the model-supplied path against the call's `cwd`.
    const dir_path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(dir_path_abs);

    // 3. Execute the listing.
    const entries = execute_list_directory(
        ctx.allocator,
        ctx.io,
        dir_path_abs,
        parsed.value.hidden,
        parsed.value.respect_ignore_files,
    ) catch |err| {
        // The resolved absolute path is the one thing the model can act on
        // here, so it rides along as the explanation's context.
        const err_msg = try error_explain.explain(ctx.allocator, err, dir_path_abs);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer freeEntries(ctx.allocator, entries);

    // 4. Serialise to JSON and wrap. The reported `path` is the resolved
    // absolute path, so the LLM (and the tool-output panel) can see which
    // directory `frontend/src` actually meant.
    const inner = try toJSON(ctx.allocator, entries, dir_path_abs);
    const output = try wrapToolOutput(ctx.allocator, "list_directory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// End-to-end proof that the list_directory exec wrapper resolves its input
// BEFORE reaching the underlying tool.
test "execListDirectory: absolute path passes through and lists entries" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(exec_testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    {
        const f = try tmp.dir.createFile(exec_testing.io, "alpha.txt", .{});
        defer f.close(exec_testing.io);
        try tmp.dir.createDirPath(exec_testing.io, "beta");
    }

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = exec_testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test",
        .model = "test",
        .cwd = root_abs,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
    // Build JSON with the absolute path embedded.
    var escaped_path: std.ArrayList(u8) = .empty;
    defer escaped_path.deinit(a);
    for (root_abs) |c| {
        if (c == '\\' or c == '"') {
            try escaped_path.append(a, '\\');
        }
        try escaped_path.append(a, c);
    }
    const args_json = try std.fmt.allocPrint(
        a,
        "{{\"path\":\"{s}\",\"cwd\":\"{s}\",\"respect_ignore_files\":false}}",
        .{ escaped_path.items, escaped_path.items },
    );
    const tc = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "list_directory", .arguments = args_json },
    };

    const result = try execListDirectory(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    // Success JSON envelope + both entries visible in data.entries.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try exec_testing.expect(obj.get("success").?.bool);
    const data = obj.get("data").?.object;
    // Absolute input is used as-is (no prefixing, no normalization).
    try exec_testing.expectEqualStrings(root_abs, data.get("path").?.string);
    const entries = data.get("entries").?.array.items;
    try exec_testing.expectEqual(@as(usize, 2), entries.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (entries) |e| {
        const name = e.object.get("name").?.string;
        if (std.mem.eql(u8, name, "alpha.txt")) saw_alpha = true;
        if (std.mem.eql(u8, name, "beta")) saw_beta = true;
    }
    try exec_testing.expect(saw_alpha);
    try exec_testing.expect(saw_beta);
    // No validator error (the validator was removed by the revert).
    try exec_testing.expect(obj.get("error").? == .null);
}

test "execListDirectory: absolute path returns success envelope without validator error" {
    // Absolute paths are used as-is (never joined onto ctx.cwd).
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(std.testing.io, &tmp_buf);
    const abs_dir = tmp_buf[0..tmp_len];

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a,
        .io = std.testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        // A DIFFERENT absolute base, so "used as-is" stays observable: had
        // the wrapper joined onto ctx.cwd, the reported path would not
        // match `abs_dir`.
        .cwd = "/home/user/proj",
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };

    // `std.json.Stringify` escapes the Windows separators for us (a raw
    // `C:\Users\...` inside a JSON string is malformed).
    const args = try std.json.Stringify.valueAlloc(a, .{
        .path = abs_dir,
        .cwd = "/home/user/proj",
    }, .{});

    const tool_call = agent.ToolCall{
        .id = "call_1",
        .type = "function",
        .function = .{
            .name = "list_directory",
            .arguments = args,
        },
    };

    const result = try execListDirectory(ctx, tool_call);
    defer if (result.output_allocated) a.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try exec_testing.expect(obj2.get("success").?.bool);
    try exec_testing.expectEqualStrings(abs_dir, obj2.get("data").?.object.get("path").?.string);
    try exec_testing.expect(obj2.get("error").? == .null);
}

// =====================================================================
// Relative-path regression tests (crash: task_1790256349339_0) The LLM called
// `list_directory` with `{"path":"frontend/src"}` and the wrapper forwarded

/// Build a ToolExecContext for the wrapper tests.
fn testCtx(
    a: std.mem.Allocator,
    session_cwd: []const u8,
    temperature: *f32,
    thinking: *bool,
) ToolExecContext {
    return .{
        .allocator = a,
        .io = exec_testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test",
        .cwd = session_cwd,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = temperature,
        .is_thinking = thinking,
        .environment = null,
    };
}

fn listDirectoryCall(id: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = id,
        .type = "function",
        .function = .{ .name = "list_directory", .arguments = args },
    };
}

test "execListDirectory: relative 'frontend/src' resolves against the call's cwd (crash regression)" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(exec_testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    // <root>/frontend/src/index.ts — the layout the crashed session had.
    try tmp.dir.createDirPath(exec_testing.io, "frontend/src");
    {
        const f = try tmp.dir.createFile(exec_testing.io, "frontend/src/index.ts", .{});
        defer f.close(exec_testing.io);
    }

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    // The EXACT arguments the model emitted when the worker aborted, plus the
    // `cwd` the tool now requires. `std.json.Stringify` handles the Windows
    // separators in `root_abs`.
    const call_a = try std.json.Stringify.valueAlloc(a, .{
        .path = "frontend/src",
        .cwd = root_abs,
        .hidden = false,
        .respect_ignore_files = true,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_crash", call_a));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // Success envelope — BEFORE the fix this line never ran: the process
    // aborted inside openDirAbsolute's assertion.
    try exec_testing.expect(obj.get("success").?.bool);
    try exec_testing.expect(obj.get("error").? == .null);

    const data = obj.get("data").?.object;
    const expected_dir = try std.fs.path.join(a, &.{ root_abs, "frontend/src" });
    // The reported path is the resolved ABSOLUTE path, so the LLM can see
    // which directory its relative path meant.
    try exec_testing.expectEqualStrings(expected_dir, data.get("path").?.string);
    // NB: `count` may legitimately be 0 on this call — `tmpDir` creates the
    // fixture under `.zig-cache/tmp/<rand>`, which lives INSIDE the repo and
    // is covered by the repo's `.gitignore`, so `git check-ignore` filters
    const entries = data.get("entries").?.array.items;
    try exec_testing.expectEqual(data.get("count").?.integer, @as(i64, @intCast(entries.len)));

    // Same relative path, gitignore filtering off — proves `frontend/src`
    // resolved to <cwd>/frontend/src (and not the server process cwd).
    const call_b = try std.json.Stringify.valueAlloc(a, .{
        .path = "frontend/src",
        .cwd = root_abs,
        .hidden = false,
        .respect_ignore_files = false,
    }, .{});
    const result2 = try execListDirectory(ctx, listDirectoryCall("call_crash_no_ignore", call_b));
    defer if (result2.output_allocated) a.free(result2.output);

    const parsed2 = try std.json.parseFromSlice(std.json.Value, a, result2.output, .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try exec_testing.expect(obj2.get("success").?.bool);
    const data2 = obj2.get("data").?.object;
    try exec_testing.expectEqualStrings(expected_dir, data2.get("path").?.string);
    try exec_testing.expectEqual(@as(i64, 1), data2.get("count").?.integer);

    const entries2 = data2.get("entries").?.array.items;
    try exec_testing.expectEqual(@as(usize, 1), entries2.len);
    try exec_testing.expectEqualStrings("index.ts", entries2[0].object.get("name").?.string);
    try exec_testing.expect(!entries2[0].object.get("is_directory").?.bool);
}

test "execListDirectory: omitted path lists the call's cwd (not the process cwd)" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(exec_testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);
    {
        const f = try tmp.dir.createFile(exec_testing.io, "only_here.txt", .{});
        defer f.close(exec_testing.io);
    }

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    const call = try std.json.Stringify.valueAlloc(a, .{
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_default", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try exec_testing.expect(obj.get("success").?.bool);

    // The default `"."` means the session cwd itself — NOT the server
    // process cwd, and never an abort.
    const data = obj.get("data").?.object;
    try exec_testing.expectEqualStrings(root_abs, data.get("path").?.string);
    const entries = data.get("entries").?.array.items;
    try exec_testing.expectEqual(@as(usize, 1), entries.len);
    try exec_testing.expectEqualStrings("only_here.txt", entries[0].object.get("name").?.string);
}

test "execListDirectory: an empty path resolves to the call's cwd" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(exec_testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    // Some providers emit `"path":""` for an optional string instead of
    // omitting the field (same class of bug as the migrations' empty-slice
    // binding).
    const call = try std.json.Stringify.valueAlloc(a, .{
        .path = "",
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_empty", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try exec_testing.expect(obj.get("success").?.bool);
    try exec_testing.expectEqualStrings(root_abs, obj.get("data").?.object.get("path").?.string);
}

test "execListDirectory: non-existent relative path returns an error envelope, not a crash" {
    var arena = std.heap.ArenaAllocator.init(exec_testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(exec_testing.io, &path_buf);
    const root_abs = path_buf[0..n];
    const missing_dir = try std.fs.path.join(a, &.{ root_abs, "definitely/not/here" });

    var temperature: f32 = 0.0;
    var thinking: bool = false;
    const ctx = testCtx(a, root_abs, &temperature, &thinking);

    const call = try std.json.Stringify.valueAlloc(a, .{
        .path = "definitely/not/here",
        .cwd = root_abs,
        .respect_ignore_files = false,
    }, .{});
    const result = try execListDirectory(ctx, listDirectoryCall("call_missing", call));
    defer if (result.output_allocated) a.free(result.output);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try exec_testing.expect(!obj.get("success").?.bool);
    try exec_testing.expect(obj.get("data").? == .null);
    // The error names the resolved native path so the LLM can self-correct.
    try exec_testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, missing_dir) != null);
}

