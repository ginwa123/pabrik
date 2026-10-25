const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
pub const memories = @import("memories.zig");
const MemoryInfo = memories.MemoryInfo;

/// Wrapper struct used for JSON serialization of the memories list.
/// `std.json.Stringify.valueAlloc` reads field names as JSON keys, so
/// the output shape is `{"memories":[{...},{...}]}`.
pub const MemoriesListData = struct {
    memories: []const MemoryInfo,
};

/// Tool definition for `list_memory`. This tool is intentionally
/// parameter-less: memories live in a single global config folder and there
/// is no per-session or per-cwd variant.
pub const list_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_memory",
        .description = "List all available memory files — markdown files in the global pabrik config folder (~/.config/pabrik/memories/ on Linux, %APPDATA%/pabrik/memories/ on Windows). Each row carries the filename, title (the first H1 line, or the filename stem when no H1 is present), absolute path, and size in bytes. Read one with `read_file` at the returned path. Lists only — never creates, modifies, or deletes.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// Serialize a `MemoryInfo` slice to JSON for the HTTP endpoint.
pub fn toJson(allocator: std.mem.Allocator, list: []const MemoryInfo) ![]const u8 {
    const data = MemoriesListData{ .memories = list };
    return std.json.Stringify.valueAlloc(allocator, data, .{});
}

/// Execute the `list_memory` tool. Returns a JSON string for the LLM.
pub fn execute_list_memory(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    const env = environment orelse {
        return std.json.Stringify.valueAlloc(allocator, struct {
            memories: []const MemoryInfo = &.{},
            @"error": []const u8 = "MissingEnvironment",
        }{}, .{});
    };

    const list = memories.listAllMemories(allocator, io, env);
    defer memories.freeMemoriesList(allocator, list);

    return toJson(allocator, list);
}

/// Parsed shape of `execute_list_memory` output, for tests.
pub const ListMemoryOutput = struct {
    memories: []MemoryInfo,
    @"error": ?[]const u8 = null,
};


// Helper: substring check
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// -------------------------------------------------------------------------
// Pure serialization tests (no filesystem)
// -------------------------------------------------------------------------

test "toJson on empty list produces parsed memories=[] with no error" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};

    const json = try toJson(alloc, list);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.memories.len);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "toJson carries all four fields per memory, parsed" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{
        .{
            .name = "weird <name>.md",
            .title = "Title & more",
            .path = "/path/with \"quotes\"",
            .size = 42,
        },
    };

    const json = try toJson(alloc, list);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.memories.len);
    try std.testing.expectEqualStrings("weird <name>.md", parsed.value.memories[0].name);
    try std.testing.expectEqualStrings("Title & more", parsed.value.memories[0].title);
    try std.testing.expectEqualStrings("/path/with \"quotes\"", parsed.value.memories[0].path);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.memories[0].size);
}

test "toJson includes all four fields per memory" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{
        .{
            .name = "user-prefs.md",
            .title = "User Preferences",
            .path = "/home/u/.config/pabrik/memories/user-prefs.md",
            .size = 1024,
        },
    };

    const json = try toJson(alloc, list);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.memories.len);
    try std.testing.expectEqualStrings("user-prefs.md", parsed.value.memories[0].name);
    try std.testing.expectEqualStrings("User Preferences", parsed.value.memories[0].title);
    try std.testing.expectEqualStrings("/home/u/.config/pabrik/memories/user-prefs.md", parsed.value.memories[0].path);
    try std.testing.expectEqual(@as(u64, 1024), parsed.value.memories[0].size);
}

// -------------------------------------------------------------------------
// freeMemoriesList — no panic on empty
// -------------------------------------------------------------------------

test "freeMemoriesList handles empty list without panicking" {
    const alloc = std.testing.allocator;
    const list = &[_]memories.MemoryInfo{};
    // Should not panic
    memories.freeMemoriesList(alloc, list);
}

// -------------------------------------------------------------------------
// execute_list_memory — filesystem integration tests
// -------------------------------------------------------------------------

test "execute_list_memory returns missing-dir empty XML, no crash" {
    // Point HOME at a path that does NOT contain a memories/ subdir.
    // The tool should return <memories></memories>, not throw.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-list-memory-missing-home";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);
    // Make sure XDG_CONFIG_HOME does not shadow HOME either
    try env.put("XDG_CONFIG_HOME", tmp_home);

    const output = try execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.memories.len);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "execute_list_memory lists .md files in HOME/.config/pabrik/memories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-list-memory-with-files";
    const memories_dir = "/tmp/pabrik-list-memory-with-files/.config/pabrik/memories";
    const file1_path = "/tmp/pabrik-list-memory-with-files/.config/pabrik/memories/user-prefs.md";
    const file2_path = "/tmp/pabrik-list-memory-with-files/.config/pabrik/memories/project-notes.md";

    // Clean up any leftovers from prior runs
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    // Create the memories directory and two .md files
    try std.Io.Dir.cwd().createDirPath(io, memories_dir);

    const file1_content = "# User Preferences\n\nLikes tabs not spaces.\n";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file1_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, file1_content);
    }

    const file2_content =
        \\# Project Notes
        \\
        \\Some long-running project context.
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file2_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, file2_content);
    }

    // Also create a .txt file that should be SKIPPED
    const txt_path = "/tmp/pabrik-list-memory-with-files/.config/pabrik/memories/notes.txt";
    {
        const f = try std.Io.Dir.createFileAbsolute(io, txt_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, "should be ignored");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    // Set HOME only so get_global_memories_path falls back to HOME/.config/pabrik/memories,
    // which matches where the test created the files. Setting XDG_CONFIG_HOME would
    // make the tool look at ${XDG_CONFIG_HOME}/pabrik/memories (XDG spec) instead.
    try env.put("HOME", tmp_home);

    const output = try execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.memories.len);

    var found_prefs = false;
    var found_notes = false;
    for (parsed.value.memories) |mem| {
        if (std.mem.eql(u8, mem.name, "user-prefs.md")) {
            found_prefs = true;
            try std.testing.expectEqualStrings("User Preferences", mem.title);
        }
        if (std.mem.eql(u8, mem.name, "project-notes.md")) {
            found_notes = true;
            try std.testing.expectEqualStrings("Project Notes", mem.title);
        }
        // The .txt file should be filtered out
        try std.testing.expect(!std.mem.eql(u8, mem.name, "notes.txt"));
    }
    try std.testing.expect(found_prefs);
    try std.testing.expect(found_notes);
}

test "execute_list_memory falls back to filename stem when no H1 present" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_home = "/tmp/pabrik-list-memory-no-h1";
    const memories_dir = "/tmp/pabrik-list-memory-no-h1/.config/pabrik/memories";
    const file_path = "/tmp/pabrik-list-memory-no-h1/.config/pabrik/memories/random-name.md";

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, memories_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer std.Io.File.close(f, io);
        // No H1 in this content — title should fall back to "random-name"
        try std.Io.File.writeStreamingAll(f, io, "Just some prose, no header.\n");
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    // HOME-only: see note in the previous test about XDG_CONFIG_HOME precedence.
    try env.put("HOME", tmp_home);

    const output = try execute_list_memory(alloc, io, &env);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.memories.len);
    try std.testing.expectEqualStrings("random-name.md", parsed.value.memories[0].name);
    // Filename stem is used as the title when no H1 exists
    try std.testing.expectEqualStrings("random-name", parsed.value.memories[0].title);
}

test "execute_list_memory with null environment returns error XML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const output = try execute_list_memory(alloc, io, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListMemoryOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("MissingEnvironment", parsed.value.@"error" orelse "");
    try std.testing.expectEqual(@as(usize, 0), parsed.value.memories.len);
}

// Exec adapter — merged from `zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const list_memory_mod = pabrikcore.list_memory_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
pub fn execListMemory(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Memories are global only — no cwd involvement. The env comes from ctx
    // (same path as list_skills); on null we emit an error-tagged XML so the
    // LLM gets a structured failure instead of a panic.
    const inner = list_memory_mod.execute_list_memory(ctx.allocator, ctx.io, ctx.environment) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "list_memory", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
