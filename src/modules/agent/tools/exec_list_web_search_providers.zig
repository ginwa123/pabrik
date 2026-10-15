//! `execListWebSearchProviders` — the discovery adapter. Trivial by design:
//! resolve the providers for THIS session and render them.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const agent = pabrikcore.agent;
const web_search_mod = pabrikcore.web_search;
const web_search_config = @import("../../../agentic_loop/web_search_config.zig");
const config_mod = pabrikcore.config;

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");

fn render(
    ctx: ToolExecContext,
    tc: agent.ToolCall,
    providers: *const config_mod.LlmConfig.WebSearchProvidersMap,
) !ToolExecResult {
    const inner = web_search_mod.renderProviderList(ctx.allocator, providers) catch |err| {
        const msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(msg);
        const output = try wrapToolOutput(ctx.allocator, "list_web_search_providers", tc.function.arguments, false, msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(
        ctx.allocator,
        "list_web_search_providers",
        tc.function.arguments,
        true,
        null,
        inner,
    );
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execListWebSearchProviders(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // Per-session FIRST. `ctx.config` is the singleton, and in `--auth` mode
    // it does not hold what the user saved — see web_search_config.zig for
    // the full story and the Skill Evals incident that motivated it.
    if (web_search_config.resolve(ctx.allocator, ctx.db, ctx.session_id)) |owned| {
        var map = owned;
        defer config_mod.LlmConfig.freeWebSearchProvidersMap(&map, ctx.allocator);
        return render(ctx, tc, &map);
    }

    // `resolve` returned null, which means the DATABASE is not the authority
    // here (file mode, or a session with no owner) — not that the user has no
    // providers.
    if (ctx.config.web_search) |*singleton| return render(ctx, tc, singleton);

    const inner = web_search_mod.notConfiguredEnvelope(ctx.allocator) catch |err| {
        const msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(msg);
        const output = try wrapToolOutput(ctx.allocator, "list_web_search_providers", tc.function.arguments, false, msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(
        ctx.allocator,
        "list_web_search_providers",
        tc.function.arguments,
        true,
        null,
        inner,
    );
    return ToolExecResult{ .output = output, .output_allocated = true };
}
