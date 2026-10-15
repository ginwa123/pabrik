//! `execWebSearch` — bridges the agentic loop's `ToolCall` to the search
//! tool.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const agent = pabrikcore.agent;
const web_search_mod = pabrikcore.web_search;
const web_search_config = @import("web_search_config.zig");
const config_mod = pabrikcore.config;

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

const testing = std.testing;

const Providers = config_mod.LlmConfig.WebSearchProvidersMap;

fn fail(ctx: ToolExecContext, tc: agent.ToolCall, msg: []const u8) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn dispatch(
    ctx: ToolExecContext,
    tc: agent.ToolCall,
    providers: *const Providers,
    provider_name: []const u8,
    curl: []const u8,
) !ToolExecResult {
    const resolved = web_search_mod.resolveProvider(ctx.allocator, providers, provider_name) catch |err| switch (err) {
        // Self-correcting: the envelope names what IS configured, so a model
        // that skipped the discovery call recovers in one turn.
        error.UnknownProvider => {
            const inner = web_search_mod.unknownProviderEnvelope(ctx.allocator, providers, provider_name) catch return err;
            defer ctx.allocator.free(inner);
            // The envelope IS the error message — see the note at the top.
            const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, inner, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        },
    };

    const inner = web_search_mod.executeWebSearch(ctx.allocator, resolved, curl) catch |err| {
        const msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer ctx.allocator.free(inner);

    // An envelope carrying `error` reaches the model as success=false while
    // still exposing the full JSON, so it can read `host_mismatch`,
    // `other_providers` and the reason string.
    {
        const maybe = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
        defer if (maybe) |*p| p.deinit();
        if (maybe) |doc| {
            const value = doc.value;
            if (value == .object) {
                if (value.object.get("error")) |e| {
                    if (e == .string) {
                        // `data` is nulled on the failure path, so the WHOLE
                        // envelope goes into `error`: the model needs
                        // `other_providers` / `host_mismatch` / `exhausted`
                        const output = try wrapToolOutput(
                            ctx.allocator,
                            "web_search",
                            tc.function.arguments,
                            false,
                            inner,
                            "",
                        );
                        return ToolExecResult{ .output = output, .output_allocated = true };
                    }
                }
            }
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        web_search_mod.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer parsed.deinit();

    if (parsed.value.provider.len == 0 or parsed.value.curl.len == 0) {
        return fail(
            ctx,
            tc,
            "web_search needs both `provider` and `curl`. Call list_web_search_providers to see the configured providers and their templates.",
        );
    }

    // Per-session FIRST — `ctx.config` is the singleton and is empty in
    // `--auth` mode. The singleton is the documented fallback for exactly the
    // cases `resolve` returns null for, and it outlives this call.
    if (web_search_config.resolve(ctx.allocator, ctx.db, ctx.session_id)) |owned| {
        var map = owned;
        defer config_mod.LlmConfig.freeWebSearchProvidersMap(&map, ctx.allocator);
        return dispatch(ctx, tc, &map, parsed.value.provider, parsed.value.curl);
    }

    if (ctx.config.web_search) |*singleton| {
        return dispatch(ctx, tc, singleton, parsed.value.provider, parsed.value.curl);
    }

    const inner = web_search_mod.notConfiguredEnvelope(ctx.allocator) catch |err| {
        const msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, inner, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── the fallback contract (D8) ───────────────────────────────────────────

test "wrapToolOutput discards `data` when success is false — so `error` is the only channel" {
    // Behavioural, not a source grep. This is the shared helper's actual
    // contract, and the web_search adapter is written against it.
    const alloc = testing.allocator;
    const out = try tools.wrapToolOutput(
        alloc,
        "web_search",
        "{}",
        false,
        "{\"error\":\"quota\",\"exhausted\":true}",
        "{\"never\":\"reaches\"}",
    );
    defer alloc.free(out);

    // `data` is nulled regardless of what was passed…
    try testing.expect(std.mem.indexOf(u8, out, "\"data\":null") != null);
    try testing.expect(std.mem.indexOf(u8, out, "never") == null);
    // …so a flag-bearing envelope MUST go through `error`, which is what
    // the adapter does. D8's fallback depends on it: after a quota error
    // the model has to be able to read `other_providers` and retry.
    try testing.expect(std.mem.indexOf(u8, out, "exhausted") != null);
}

test "wrapToolOutput keeps `data` when success is true" {
    const alloc = testing.allocator;
    const out = try tools.wrapToolOutput(
        alloc,
        "web_search",
        "{}",
        true,
        null,
        "{\"provider\":\"tinyfish\"}",
    );
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"data\":{\"provider\":\"tinyfish\"}") != null);
}
