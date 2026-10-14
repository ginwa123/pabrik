const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const llm_history = pabrikcore.llm_history;
const set_git_worktree_mod = pabrikcore.set_git_worktree;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");
const path_validate = @import("helpers").path_validate;

pub fn execSetGitWorktree(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        set_git_worktree_mod.SetGitWorktreeInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // `cwd` is REQUIRED and names the REPOSITORY the worktree is created
    // from. It replaces the session cwd this call used to borrow: the model
    // now states which repo it is branching, instead of inheriting whichever
    // one the session happened to be bound to.
    path_validate.validateCwd(parsed.value.cwd) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // executeSetGitWorktreeToString returns JSON (![]const u8) — errors are
    // also encoded as {"created":false,"error":"..."} on success paths.
    // We must catch the error union separately.
    const inner = set_git_worktree_mod.executeSetGitWorktreeToString(
        ctx.allocator,
        ctx.io,
        ctx.db,
        parsed.value.cwd,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (extractJsonError(ctx.allocator, inner)) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // SUCCESS: persist the new git_worktree_cwd to the DB so the
    // session remembers it across tool calls. For CLEAR, pass null
    // (the function treats null and "" identically as "clear the
    // binding"). For SET, extract the "path" from the inner JSON
    // and persist it.
    if (parsed.value.clear) {
        llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, null) catch |err| {
            ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
        };
    } else if (extractJsonPath(ctx.allocator, inner)) |worktree_path| {
        defer ctx.allocator.free(worktree_path);
        if (worktree_path.len > 0) {
            llm_history.updateSessionGitWorktreeCwd(ctx.allocator, ctx.db, ctx.session_id, worktree_path) catch |err| {
                ctx.logger.errFmt("set_git_worktree: failed to persist git_worktree_cwd: {s}", .{@errorName(err)});
            };
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "set_git_worktree", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Extract the "error" string from the inner JSON payload.
/// Returns null when the payload has no error (success case) or when
/// the payload is not valid JSON (treat as success and let the wrapper
/// surface it via _raw). Caller owns the returned slice.
fn extractJsonError(allocator: std.mem.Allocator, inner: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_val = parsed.value.object.get("error") orelse return null;
    switch (err_val) {
        .null => return null,
        .string => |s| {
            if (s.len == 0) return null;
            return allocator.dupe(u8, s) catch null;
        },
        else => return null,
    }
}

/// Extract the "path" string from the inner JSON payload.
/// Returns null when absent or unparseable. Caller owns the slice.
fn extractJsonPath(allocator: std.mem.Allocator, inner: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, inner, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path_val = parsed.value.object.get("path") orelse return null;
    switch (path_val) {
        .string => |s| return allocator.dupe(u8, s) catch null,
        .null => return null,
        else => return null,
    }
}
