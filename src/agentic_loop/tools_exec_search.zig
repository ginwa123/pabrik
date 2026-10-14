const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const search_tool_mod = pabrikcore.search_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;

/// Parse the model-provided JSON and normalize zero-valued optional head/tail
/// placeholders. Some providers emit every optional numeric field and use 0
/// for "unused"; executeSearch intentionally keeps its direct API strict, so
/// compatibility belongs at this tool-call boundary.
fn parseSearchInput(allocator: std.mem.Allocator, args: []const u8) !std.json.Parsed(search_tool_mod.SearchInput) {
    var raw = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        args,
        .{ .allocate = .alloc_always },
    );
    defer raw.deinit();

    if (raw.value == .object) {
        for ([_][]const u8{ "head", "tail" }) |field_name| {
            const value = raw.value.object.getPtr(field_name) orelse continue;
            if (value.* == .integer and value.*.integer == 0) {
                value.* = .null;
            }
        }
    }

    return std.json.parseFromValue(
        search_tool_mod.SearchInput,
        allocator,
        raw.value,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = parseSearchInput(ctx.allocator, args_to_parse) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and it is ALSO the directory ripgrep is spawned in (see
    // `executeSearch`'s `cwd` argument) — the two used to be able to disagree,
    // which made an absolute `path` and a stale inherited cwd contradict each
    // other and surface as a bare "could not access search path".
    const cwd = parsed.value.cwd orelse "";
    path_validate.validateCwd(cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    // rg receives the RESOLVED path, so its own cwd cannot reinterpret it.
    var input = parsed.value;
    input.path = path_abs;
    input.cwd = cwd;

    var search_result = search_tool_mod.executeSearch(ctx.allocator, ctx.io, cwd, input) catch |err| {
        // Map domain errors to LLM-friendly messages. A normal stdout
        // max_output overflow no longer appears here: executeSearch returns
        // a successful SearchResult with output_truncated metadata instead.
        var owned_err_msg: ?[]const u8 = null;
        defer if (owned_err_msg) |msg| ctx.allocator.free(msg);
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.OutputReadFailed => break :blk "could not capture the search output stream — retry; if it persists, narrow the path or use a smaller result window",
                error.StderrTooLong => break :blk "ripgrep diagnostics exceeded the output limit — narrow the path or use a more specific pattern to reduce diagnostics",
                error.EmptyPattern => break :blk "search pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "search pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.InvalidMaxOutput => break :blk "max_output must be > 0 (use 1048576 for the 1MB default)",
                error.MaxOutputTooLarge => break :blk "max_output exceeded the 100MB hard ceiling — narrow your search path or use a more specific pattern to reduce output",
                error.InvalidMaxResults => break :blk "max_results must be > 0 (use the default of 50 if you don't need a specific cap)",
                error.HeadAndTailMutuallyExclusive => break :blk "head and tail are mutually exclusive — set only one and omit the other",
                error.InvalidHeadTail => break :blk "head/tail must be > 0 — omit the flag (or use max_results) instead of passing 0, which would look like a no-match",
                error.GlobContainsNulByte => break :blk "the glob filter contained a NUL (0x00) byte — globs must be valid UTF-8 with no embedded NULs",
                error.RegexParseError => break :blk "search pattern is not a valid regex — check for unmatched parentheses, unescaped metacharacters, or an invalid character class",
                error.PathError => {
                    // Naming the path AND the cwd it was resolved against is
                    // the whole fix for the failure this branch used to
                    // report: a bare "could not access search path" named
                    // neither, so the model could not tell which of the two
                    // was wrong. Owned here so the `defer` above frees it.
                    owned_err_msg = try std.fmt.allocPrint(
                        ctx.allocator,
                        "could not access search path \"{s}\" from cwd \"{s}\" — verify both exist and are readable. `cwd` is the directory ripgrep runs in; `path` is resolved against it.",
                        .{ path_abs, cwd },
                    );
                    break :blk owned_err_msg.?;
                },
                error.Timeout => break :blk "search timed out (30s default) — narrow your search path, use a more specific pattern, or pass a larger timeout_ms",
                error.RgNotFound => break :blk "ripgrep (rg) is not installed or not on PATH — install it first, then retry the search",
                else => {},
            }
            const msg = error_explain.explain(ctx.allocator, err, null) catch {
                break :blk "search failed with an unknown error";
            };
            owned_err_msg = msg;
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer search_result.deinit(ctx.allocator);

    // Honor group_by_file flag — use the flat variant when requested. Both
    // formatters carry the same truncation metadata, including a successful
    // partial result when max_output was reached.
    const inner = if (parsed.value.group_by_file)
        try search_tool_mod.search_result_to_json_grouped(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        )
    else
        try search_tool_mod.search_result_to_json_flat(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        );
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

test "search JSON parser treats a zero-valued unused head/tail as omitted" {
    const args =
        \\{"pattern":"Open chat in new tab","path":"/tmp/example","max_results":100,
        \\ "head":100,"tail":0,"max_output":20000,"group_by_file":true,
        \\ "respect_ignore_files":true,"word_boundary":false,"literal":true,
        \\ "only_matching":false,"snippet_max_chars":300,"hidden":false,
        \\ "glob":"*.{vue,ts,tsx,js}","timeout_ms":30000}
    ;

    var parsed = try parseSearchInput(std.testing.allocator, args);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 100), parsed.value.head.?);
    try std.testing.expect(parsed.value.tail == null);
}

test "TDD: execSearch accepts head=100 with tail=0 and returns a successful match envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "open-chat.txt",
        .data = "Open chat in new tab\nOpen chat in new tab again\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];

    // This is the model-call shape from the failing UI request: head is
    // selected, while the unused optional tail is emitted as 0.
    const args_json = try std.json.Stringify.valueAlloc(allocator, .{
        .pattern = "Open chat in new tab",
        .path = ".",
        // `cwd` is required: the directory this call works in, and the base
        // `path` (here ".") resolves against.
        .cwd = tmpdir_path,
        .max_results = 100,
        .head = 100,
        .tail = 0,
        .max_output = 20_000,
        .group_by_file = true,
        .respect_ignore_files = true,
        .word_boundary = false,
        .literal = true,
        .only_matching = false,
        .snippet_max_chars = 300,
        .hidden = false,
        .glob = "*.txt",
        .timeout_ms = 30_000,
    }, .{});

    var dummy_temperature: f32 = 0.0;
    var dummy_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test-session",
        .model = "test-model",
        .cwd = tmpdir_path,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_temperature,
        .is_thinking = &dummy_thinking,
        .environment = null,
    };
    const tool_call = agent.ToolCall{
        .id = "call-search-tail-zero",
        .type = "function",
        .function = .{ .name = "search", .arguments = args_json },
    };

    // Before zero-placeholder normalization, this call reached executeSearch
    // with both optionals non-null and returned success=false with
    // HeadAndTailMutuallyExclusive. This assertion is the red/green regression.
    const exec_result = try execSearch(ctx, tool_call);
    defer exec_result.deinit(allocator);

    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, exec_result.output, .{});
    defer envelope.deinit();
    const root = envelope.value.object;
    const success = root.get("success").?.bool;
    if (!success) {
        const error_value = root.get("error").?;
        if (error_value == .string and std.mem.indexOf(u8, error_value.string, "ripgrep (rg) is not installed") != null) return;
    }

    try std.testing.expect(success);
    try std.testing.expect(root.get("error").? == .null);
    const data = root.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 2), data.get("returned").?.integer);
    const files = data.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), files.len);
    const matches = files[0].object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(i64, 1), matches[0].object.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), matches[1].object.get("line").?.integer);
}

test "execSearch returns success for an oversized stdout search with a truncation hint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(io, .{
        .sub_path = "large.txt",
        .data = "FOUND_MARKER line\nFOUND_MARKER again\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmpdir.dir.realPath(io, &path_buf);
    const tmpdir_path: []const u8 = path_buf[0..path_len];
    const args_json = try std.json.Stringify.valueAlloc(allocator, .{
        .pattern = "FOUND_MARKER",
        .path = ".",
        .cwd = tmpdir_path,
        .max_output = 1,
        .group_by_file = true,
        .literal = true,
    }, .{});
    defer allocator.free(args_json);

    var dummy_temperature: f32 = 0.0;
    var dummy_thinking: bool = false;
    const ctx = ToolExecContext{
        .allocator = allocator,
        .io = io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test-session",
        .model = "test-model",
        .cwd = tmpdir_path,
        .api_key = "test",
        .base_url = "test",
        .config = undefined,
        .agent_temperature = &dummy_temperature,
        .is_thinking = &dummy_thinking,
        .environment = null,
    };
    const tool_call = agent.ToolCall{
        .id = "call-search-output-cap",
        .type = "function",
        .function = .{ .name = "search", .arguments = args_json },
    };

    const exec_result = try execSearch(ctx, tool_call);
    defer exec_result.deinit(allocator);
    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, exec_result.output, .{});
    defer envelope.deinit();
    const root = envelope.value.object;
    if (!root.get("success").?.bool) {
        const error_value = root.get("error").?;
        if (error_value == .string and std.mem.indexOf(u8, error_value.string, "ripgrep (rg) is not installed") != null) return;
    }
    try std.testing.expect(root.get("success").?.bool);
    try std.testing.expect(root.get("error").? == .null);
    const data = root.get("data").?.object;
    try std.testing.expect(data.get("truncated").?.bool);
    try std.testing.expect(data.get("output_truncated").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, data.get("truncated_hint").?.string, "max_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec_result.output, "Search output exceeded max_output" ++ " limit") == null);
}

test "search JSON parser lets head with tail=0 reach execution as head-only" {
    var parsed = try parseSearchInput(std.testing.allocator,
        \\{"pattern":"needle","path":".","head":100,"tail":0,"timeout_ms":0}
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.Timeout,
        search_tool_mod.executeSearch(std.testing.allocator, std.testing.io, "/tmp", parsed.value),
    );
}

test "search JSON parser preserves positive head and tail for strict validation" {
    var parsed = try parseSearchInput(std.testing.allocator,
        \\{"pattern":"needle","path":".","head":5,"tail":5}
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 5), parsed.value.head.?);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.tail.?);
}
