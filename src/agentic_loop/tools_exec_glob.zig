const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const glob_tool_mod = pabrikcore.glob_tool;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;

pub fn execGlob(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        glob_tool_mod.GlobInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED on every path-taking tool: it is the directory this
    // call works in, and the base a relative `path` resolves against. See
    // helpers/path_validate.zig for the one implementation of that rule.
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const path_abs = try path_validate.resolveAgainstCwd(ctx.allocator, parsed.value.cwd, parsed.value.path);
    defer ctx.allocator.free(path_abs);

    // Search the RESOLVED directory: a relative `path` would otherwise be
    // resolved by the globber against the SERVER's directory, not `cwd`.
    var input = parsed.value;
    input.path = path_abs;

    var glob_result = glob_tool_mod.executeGlob(ctx.allocator, ctx.io, input) catch |err| {
        // Map the new domain errors to LLM-friendly messages. Each one
        // names the fix the LLM can try (different pattern, narrower
        // path, smaller max_results, etc).
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.EmptyPattern => break :blk "glob pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.WhitespaceOnlyPattern => break :blk "glob pattern contained only whitespace characters — pass a real pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "glob pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.PathDoesNotExist => break :blk "glob path does not exist or is not a directory — verify the path exists and points to a directory (not a file)",
                error.InvalidFileType => break :blk "glob file_type must be 'f', 'file', 'd', or 'directory' (or omitted for all types)",
                error.InvalidMaxResults => break :blk "glob max_results must be > 0 (omit the field or use a positive integer; the default is 100)",
                error.InvalidBraceExpansion => break :blk "glob pattern has unmatched braces ('{' without '}') — fix the brace expansion syntax",
                else => {},
            }
            // Fall-through for unrecognised errors: the shared table keeps
            // the raw error name and adds generic repair advice.
            const msg = error_explain.explain(ctx.allocator, err, null) catch "glob failed with an unknown error";
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    const inner = try glob_tool_mod.toJSONSuccess(ctx.allocator, glob_result, parsed.value.pattern);
    glob_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "glob", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
