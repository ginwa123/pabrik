//! Tool executor for `move_element_to_page` — wraps the tool's
//! `executeMoveElementToPageToString` into the `ToolExecContext` /
//! `ToolExecResult` shape used by the agentic loop's tool dispatcher.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const move_element_to_page_mod = pabrikcore.move_element_to_page;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execMoveElementToPage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        move_element_to_page_mod.MoveElementToPageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(
            ctx.allocator,
            "move_element_to_page",
            tc.function.arguments,
            false,
            err_msg,
            "",
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // The tool needs the *active* page_id — the agentic loop currently passes
    // the page context through `ctx.cwd` or a similar channel.
    const active_page_id = ctx.active_page_id;

    const inner = move_element_to_page_mod.executeMoveElementToPageToString(
        ctx.allocator,
        ctx.db,
        active_page_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(
            ctx.allocator,
            "move_element_to_page",
            tc.function.arguments,
            false,
            err_msg,
            "",
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect {{"error":...}} and surface it as a tool failure (so the
    // LLM sees `success=false` rather than a successful wrapper around
    // an error body).
    const json_err_msg: ?[]u8 = blk: {
        const inner_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch break :blk null;
        defer inner_parsed.deinit();
        if (inner_parsed.value != .object) break :blk null;
        const e = inner_parsed.value.object.get("error") orelse break :blk null;
        if (e != .string) break :blk null;
        break :blk try ctx.allocator.dupe(u8, e.string);
    };
    if (json_err_msg) |err_msg| {
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "move_element_to_page", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(
        ctx.allocator,
        "move_element_to_page",
        tc.function.arguments,
        true,
        null,
        inner,
    );
    return ToolExecResult{ .output = output, .output_allocated = true };
}
