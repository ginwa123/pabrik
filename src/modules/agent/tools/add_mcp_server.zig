//! Agent-callable tool: `add_mcp_server` — register a new MCP server in the
//! live `LlmConfig` (in-memory + JSON mirror) so subsequent agent iterations
//! pick up its tools via `buildMCPToolsRun`.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const config_mod = pabrikcore.config;
const LlmConfig = config_mod.LlmConfig;

const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;

/// One MCP header entry (HTTP transport — v1 ignores these but the field
/// is in the schema so the LLM doesn't have to learn a new shape when HTTP
/// ships in the sibling task).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Input for `add_mcp_server`.
pub const AddMcpServerInput = struct {
    /// Server name (key in `mcp_servers`). Must be non-empty and must not
    /// collide with an existing server. Trailing whitespace is NOT
    /// trimmed — the caller passes the exact key.
    name: []const u8 = "",

    /// Transport discriminator. v1 only accepts `"stdio"`. The HTTP branch
    /// (`"http"`) is gated to a clear error today and will be enabled by
    /// the HTTP sibling task without changing this schema.
    transport: []const u8 = "stdio",

    /// stdio command. Required when `transport == "stdio"`. Empty for HTTP.
    command: []const u8 = "",

    /// stdio argv. Optional.
    args: ?[]const []const u8 = null,

    /// HTTP URL. Reserved for the HTTP sibling task.
    url: []const u8 = "",

    /// HTTP headers. Reserved for the HTTP sibling task.
    headers: ?[]const Header = null,
};

/// Tool definition for the LLM. The description is the agent's primary
/// "when to call this" signal — it lists BOTH the stdio fields the agent
/// must provide AND a brief note that HTTP is forthcoming.
pub const add_mcp_server_tool_system_prompt =
    \\## Add MCP Server Tool — Behavior
    \\Use `add_mcp_server` to register a new MCP server at runtime.
    \\- Provide `name`, `transport="stdio"`, `command`, and optional `args`. The new server's tools become discoverable with `search_tool` on the NEXT iteration; call `use_tool` to make one callable.
    \\- The server's tools are NOT injected into your tool list automatically — MCP tools are progressive.
    \\- v1 supports `stdio` only; `http` will return an error.
    \\
;

pub const add_mcp_server_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_mcp_server",
        .description =
        \\Register a new MCP (Model Context Protocol) server with `add_mcp_server` so its tools become available on the NEXT iteration. Call it when the user asks to add a stdio MCP integration or register a tool provider.
        \\
        \\After a successful call the server's tools appear as `mcp_<serverName>_<toolName>`: find one with `search_tool`, then `use_tool` to make it callable. They are NOT in your tool list automatically — finish your reply first.
        \\
        \\v1 accepts `stdio` only; `url` + `headers` (HTTP) are reserved for a sibling task and return a clear error today.
        \\
        \\The call validates the input, mutates the live in-memory config, then persists it to `~/.config/pabrik/config.json` (or platform equivalent) so the server survives restart. It still succeeds if the server cannot be reached right now.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Server key. Must be non-empty and must not already exist.",
                },
                .{
                    .name = "transport",
                    .type = "string",
                    .description = "Transport. v1 accepts only `\"stdio\"`.",
                },
                .{
                    .name = "command",
                    .type = "string",
                    .description = "stdio binary to spawn. Required when transport == \"stdio\". E.g. `\"npx\"`, `\"mcp-hello-world\"`.",
                },
                .{
                    .name = "args",
                    .type = "array",
                    .description = "stdio argv (optional). One string per argument.",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "HTTP URL. Reserved for the HTTP sibling task — currently ignored, returns an error.",
                },
                .{
                    .name = "headers",
                    .type = "object",
                    .description = "HTTP headers. Reserved for the HTTP sibling task — currently ignored, returns an error.",
                },
            },
            .required = &.{ "name", "transport", "command" },
        },
        .system_prompt = add_mcp_server_tool_system_prompt,
    },
};

/// Execute the `add_mcp_server` tool.
pub fn executeAddMcpServerToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *LlmConfig,
    input: AddMcpServerInput,
) ![]const u8 {
    _ = io; // reserved for the HTTP branch

    // ── 1. Validate transport + per-transport fields ───────────────────
    if (!std.mem.eql(u8, input.transport, "stdio")) {
        return jsonError(allocator,
            \\transport must be "stdio" in v1 — HTTP lands in a sibling task. If you intended stdio, set transport="stdio" and provide a non-empty `command`.
        );
    }

    // ── 2. Call the storage primitive ──────────────────────────────────
    config_mod.LlmConfig.addMcpServerStdio(config, .{
        .name = input.name,
        .command = input.command,
        .args = input.args,
    }) catch |err| {
        // Free the per-error allocated msg (when present) before returning.
        // `jsonError` does NOT take ownership of the message slice; it
        // copies it through the sanitizer. We must free our own copies.
        const owned_msg: ?[]u8 = switch (err) {
            error.InvalidName => null,
            error.InvalidCommand => null,
            error.DuplicateServer => blk: {
                const m = std.fmt.allocPrint(allocator, "an MCP server named '{s}' is already configured — choose a different name", .{input.name}) catch break :blk null;
                break :blk m;
            },
            else => null,
        };
        defer if (owned_msg) |m| allocator.free(m);

        const fallback: []const u8 = switch (err) {
            error.InvalidName => "name is required (must be non-empty)",
            error.InvalidCommand => "command is required (must be non-empty for stdio transport)",
            error.DuplicateServer => "an MCP server with that name is already configured",
            else => @errorName(err),
        };
        return jsonError(allocator, owned_msg orelse fallback);
    };

    // No best-effort tools listing here — it would pollute the global
    // StdioRegistry (whose arena is only cleaned up in `deinitGlobal`, which
    // tests don't call) and the test allocator would flag it as a leak.

    // ── 3. Build the success payload (`tools` stays null here; exec
    // wrapper fills it in after a successful listing). ───────────────
    return successJSON(allocator, input);
}

// ───────────────────────────────────────────────────────────────────────
// JSON payloads
// ───────────────────────────────────────────────────────────────────────

// Note on the best-effort `tools/list` listing: it lives in the exec wrapper
// (see `add_mcp_server.zig::listAndAppendTools`), NOT the pure fn.

fn successJSON(
    allocator: std.mem.Allocator,
    input: AddMcpServerInput,
) ![]u8 {
    const clean_name = try sanitize(allocator, input.name);
    defer allocator.free(clean_name);
    const clean_transport = try sanitize(allocator, input.transport);
    defer allocator.free(clean_transport);
    const clean_command = try sanitize(allocator, input.command);
    defer allocator.free(clean_command);

    var clean_args: std.ArrayList([]u8) = .empty;
    defer {
        for (clean_args.items) |a| allocator.free(a);
        clean_args.deinit(allocator);
    }
    if (input.args) |a| {
        for (a) |arg| try clean_args.append(allocator, try sanitize(allocator, arg));
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .name = clean_name,
        .transport = clean_transport,
        .command = clean_command,
        .args = clean_args.items,
        .persisted = "false",
        .tools = @as(?[]const u8, null),
        .note = "MCP server registered in the live config. Its tools will appear as mcp_<server>_<tool> in your next system-prompt rebuild. Disk persistence + live-reload are performed by the exec wrapper.",
    }, .{});
}

fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ───────────────────────────────────────────────────────────────────────
// Inline tests
// ───────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Note: no DB fixture needed — `LlmConfig.addMcpServerStdio` is a
// pure in-memory mutation; tests construct a fresh `LlmConfig` via
// `fixtureConfig` and never touch the database.

fn fixtureConfig(allocator: std.mem.Allocator) !LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
}

fn parseTestJson(alloc: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, out, .{});
}

// ─── Test 1: happy-path stdio entry, success envelope shape ────────────

test "executeAddMcpServerToJSON: valid stdio entry → success payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx7",
        .transport = "stdio",
        .command = "npx",
        .args = &.{ "-y", "@upstash/context7-mcp" },
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("ctx7", obj.get("name").?.string);
    try testing.expectEqualStrings("stdio", obj.get("transport").?.string);
    try testing.expectEqualStrings("npx", obj.get("command").?.string);
    const args = obj.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("-y", args.items[0].string);
    try testing.expectEqualStrings("@upstash/context7-mcp", args.items[1].string);
    try testing.expectEqualStrings("false", obj.get("persisted").?.string);
    try testing.expect(obj.get("tools").? == .null);
    try testing.expect(obj.get("error") == null);

    // Typed map populated.
    try testing.expect(cfg.hasMcpServer("ctx7"));
    const server = cfg.mcpServerConfig("ctx7").?;
    try testing.expectEqualStrings("npx", server.command.?);
}

// ─── Test 2: HTTP transport rejected in v1 ──────────────────────────────

test "executeAddMcpServerToJSON: HTTP transport rejected with clear error" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "remote",
        .transport = "http",
        .url = "https://example.com/mcp",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "transport must be") != null);
    try testing.expect(std.mem.indexOf(u8, err, "stdio") != null);
    // No server added.
    try testing.expect(!cfg.hasMcpServer("remote"));
}

// ─── Test 3: empty name surfaces InvalidName error ─────────────────────

test "executeAddMcpServerToJSON: empty name → error payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "",
        .transport = "stdio",
        .command = "x",
    });
    defer alloc.free(result);

    const parsed3 = try parseTestJson(alloc, result);
    defer parsed3.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed3.value.object.get("error").?.string, "name is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 4: empty command surfaces InvalidCommand error ───────────────

test "executeAddMcpServerToJSON: empty command → error payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "",
    });
    defer alloc.free(result);

    const parsed4 = try parseTestJson(alloc, result);
    defer parsed4.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed4.value.object.get("error").?.string, "command is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 5: duplicate name surfaces DuplicateServer with the name ──────

test "executeAddMcpServerToJSON: duplicate name → error mentioning the existing key" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    // First add succeeds.
    const first = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "first-cmd",
    });
    defer alloc.free(first);
    // Second add with the same name fails; envelope mentions the key.
    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "second-cmd",
    });
    defer alloc.free(result);

    const parsed5 = try parseTestJson(alloc, result);
    defer parsed5.deinit();
    const err5 = parsed5.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err5, "ctx") != null);
    try testing.expect(std.mem.indexOf(u8, err5, "already configured") != null);
    // Original entry preserved.
    const server = cfg.mcpServerConfig("ctx").?;
    try testing.expectEqualStrings("first-cmd", server.command.?);
}

// ─── Test 6: JSON schema shape ──────────────────────────────────────────

test "add_mcp_server_tool JSON schema: name=add_mcp_server, required includes name+transport+command" {
    const tool = add_mcp_server_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("add_mcp_server", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "add_mcp_server") != null);
    try testing.expect(std.mem.indexOf(u8, description, "stdio") != null);

    // Required: name + transport + command. args/url/headers are optional.
    try testing.expectEqual(@as(usize, 3), tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", tool.function.parameters.required[0]);
    try testing.expectEqualStrings("transport", tool.function.parameters.required[1]);
    try testing.expectEqualStrings("command", tool.function.parameters.required[2]);

    // Properties: 6 fields (name, transport, command, args, url, headers).
    // `cwd` was dropped on 2026-10-14 — see the input-struct doc comment.
    try testing.expectEqual(@as(usize, 6), tool.function.parameters.properties.len);
}

// ─── Test 9: <args> block omitted when args is null ─────────────────────

test "executeAddMcpServerToJSON: args block omitted when null" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "no-args",
        .transport = "stdio",
        .command = "mcp-hello-world",
    });
    defer alloc.free(result);

    const parsed9 = try parseTestJson(alloc, result);
    defer parsed9.deinit();
    const args9 = parsed9.value.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 0), args9.items.len);
}

// Exec adapter — merged from `add_mcp_server.zig` (2026-10-14, task_1791993404141_2).
// The tool definition above and its executor below live in ONE file.

const exec_testing = std.testing;
const exec_pabrikcore = @import("pabrikcore");
const tools = @import("../../../agentic_loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = exec_pabrikcore.agent;
const exec_config_mod = exec_pabrikcore.config;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("../../../agentic_loop/tools_error_explain.zig");
pub fn execAddMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // ── 1.
    const parsed = std.json.parseFromSlice(
        AddMcpServerInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // ── 2. Mutate the live config (typed map + JSON mirror) ──────────── The
    // pure-fn primitive takes a `*LlmConfig` (mutable).
    const config_mut = @constCast(ctx.config);
    const inner = executeAddMcpServerToJSON(
        ctx.allocator,
        ctx.io,
        config_mut,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // ── 3. Detect the <error>...</error> shape from the pure fn ─────────
    // The pure fn returns `{"error":...}` on validation failures.
    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*par| par.deinit();
    if (inner_parsed) |par| {
        if (par.value == .object) {
            if (par.value.object.get("error")) |e| {
                if (e == .string and e.string.len > 0) {
                    const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, false, e.string, inner);
                    return ToolExecResult{ .output = output, .output_allocated = true };
                }
            }
        }
    }

    // ── 4.
    const persist_status_owned = persistAndReloadStatus(ctx) catch |err| blk: {
        std.log.warn(
            "add_mcp_server: in-memory mutation succeeded but disk write failed: {s}",
            .{@errorName(err)},
        );
        break :blk ctx.allocator.dupe(u8, "false") catch @as([]u8, &[_]u8{});
    };
    defer ctx.allocator.free(persist_status_owned);
    const persist_status: []const u8 = persist_status_owned;

    // ── 5.
    const inner_with_status = try substitutePersistedStatus(
        ctx.allocator,
        inner,
        persist_status,
    );
    defer ctx.allocator.free(inner_with_status);

    // ── 6.
    const inner_with_status_and_tools = if (ctx.environment == null)
        inner_with_status
    else
        listAndAppendTools(ctx, inner_with_status, parsed.value.name) catch inner_with_status;

    // ── 7. Wrap the final envelope ─────────────────────────────────────
    const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, true, null, inner_with_status_and_tools);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Substitute the `"persisted":"false"` placeholder in the pure-fn payload
/// with the actual disk-write + live-reload status.
fn substitutePersistedStatus(
    allocator: std.mem.Allocator,
    inner_json: []const u8,
    status: []const u8,
) ![]u8 {
    const placeholder = "\"persisted\":\"false\"";

    const idx = std.mem.indexOf(u8, inner_json, placeholder) orelse {
        // Defensive: if the pure-fn payload shape ever drifts and the
        // placeholder is missing, surface a clear error rather than return
        // the unmodified JSON (which would lie to the LLM by saying
        return error.MissingPersistedPlaceholder;
    };

    const status_json = try std.json.Stringify.valueAlloc(allocator, status, .{});
    defer allocator.free(status_json);
    const replacement = try std.fmt.allocPrint(allocator, "\"persisted\":{s}", .{status_json});
    defer allocator.free(replacement);

    const prefix = inner_json[0..idx];
    const suffix_start = idx + placeholder.len;
    const suffix = inner_json[suffix_start..];
    const result_len = prefix.len + replacement.len + suffix.len;
    const result = try allocator.alloc(u8, result_len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..][0..replacement.len], replacement);
    @memcpy(result[prefix.len + replacement.len ..][0..suffix.len], suffix);
    return result;
}

// ───────────────────────────────────────────────────────────────────────
// Disk persistence + live-reload helper
// ───────────────────────────────────────────────────────────────────────

/// Persist the live config to `~/.config/pabrik/config.json` and hot-reload
/// `di.llm_config` via `setLlmConfig` so subsequent agent iterations see the
/// new server through `buildMCPToolsRun`.
fn persistAndReloadStatus(ctx: ToolExecContext) ![]u8 {
    const di = exec_pabrikcore.getSingleton() catch return ctx.allocator.dupe(u8, "false: getSingleton failed") catch return ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server failure status");
    // Auth mode: persist into the session owner's users.config_json
    // (Migration 092) instead of config.json, and skip the global
    // live-reload (config is per-user). config.json is never touched.
    if (di.auth_enabled) {
        return persistAuthModeStatus(ctx, di);
    }
    const env_ptr = di.environment orelse return std.fmt.allocPrint(ctx.allocator, "false: environment unavailable", .{}) catch ctx.allocator.dupe(u8, "false") catch @panic("allocPrint failed for the add_mcp_server failure status");
    // getDefaultConfigDir takes a non-const pointer but doesn't mutate.
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(env_ptr));

    const config_dir = exec_config_mod.getDefaultConfigDir(ctx.allocator, environment) catch |err| {
        return failStatus(ctx.allocator, "getDefaultConfigDir", @errorName(err));
    };
    defer ctx.allocator.free(config_dir);

    const config_path = std.fs.path.join(ctx.allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        return failStatus(ctx.allocator, "path.join", @errorName(err));
    };
    defer ctx.allocator.free(config_path);

    // `getDefaultConfigDir` validates its environment bases, but the calls
    // below are the ones that ASSERT: `openFileAbsolute` /
    // `createFileAbsolute` abort the whole process (Debug/ReleaseSafe) for a
    if (!std.fs.path.isAbsolute(config_path)) {
        return failStatus(ctx.allocator, "config_path", "not an absolute path");
    }

    // Ensure config dir exists.
    std.Io.Dir.cwd().createDirPath(ctx.io, config_dir) catch |err| {
        return failStatus(ctx.allocator, "createDirPath", @errorName(err));
    };

    // Read existing on-disk config (if any) so we don't clobber siblings.
    var existing: ?[]u8 = null;
    if (std.Io.Dir.openFileAbsolute(ctx.io, config_path, .{})) |f| {
        defer f.close(ctx.io);
        var buf: [4096]u8 = undefined;
        var reader = f.reader(ctx.io, &buf);
        existing = reader.interface.allocRemaining(ctx.allocator, .limited(1024 * 1024)) catch null;
    } else |_| {
        existing = null;
    }
    defer if (existing) |e| ctx.allocator.free(e);

    // Build new on-disk JSON by reading the live config (which already
    // contains our new server — the primitive mutated the typed map +
    // mcpServers_parsed mirror).
    const new_body = try buildUpdatedConfigJson(ctx, existing);
    defer ctx.allocator.free(new_body);

    // Write back atomically (truncate + write).
    const wfile = std.Io.Dir.createFileAbsolute(ctx.io, config_path, .{ .truncate = true }) catch |err| {
        return failStatus(ctx.allocator, "createFileAbsolute", @errorName(err));
    };
    var wbuf: [4096]u8 = undefined;
    {
        defer wfile.close(ctx.io);
        var writer = wfile.writer(ctx.io, &wbuf);
        writer.interface.writeAll(new_body) catch |err| {
            return failStatus(ctx.allocator, "writeAll", @errorName(err));
        };
        writer.flush() catch |err| {
            return failStatus(ctx.allocator, "flush", @errorName(err));
        };
    }

    // Hot-reload: re-parse + atomically swap di.llm_config.
    const env_for_reload: *std.process.Environ.Map = @ptrCast(@constCast(di.environment orelse environment));
    var new_cfg = exec_config_mod.LlmConfig.init(di.allocator, ctx.io, null, env_for_reload) catch |err| {
        return failStatus(ctx.allocator, "live reload parse", @errorName(err));
    };
    new_cfg.validate() catch |err| {
        var mut: *exec_config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "live reload validate", @errorName(err));
    };
    const new_ptr = di.allocator.create(exec_config_mod.LlmConfig) catch |err| {
        var mut: *exec_config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "OOM", @errorName(err));
    };
    new_ptr.* = new_cfg;
    exec_pabrikcore.setLlmConfig(di, new_ptr);

    // Fetch-once cache (plan: mcp-fetch-once-cache): lazy-invalidate so the
    // next workflow run refetches once and picks up the new server.
    di.clearMcpToolsCache();

    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server success status");
}

/// Auth-mode persist for `add_mcp_server`: merge the live `mcp_servers` into
/// the session owner's `users.config_json` (Migration 092).
fn persistAuthModeStatus(ctx: ToolExecContext, di: *exec_pabrikcore.App) ![]u8 {
    const user_config_store = exec_pabrikcore.user_config_store;
    // 1. Resolve the session owner.
    var owner: ?[]u8 = null;
    defer if (owner) |o| ctx.allocator.free(o);
    {
        var q = ctx.db.query(
            ctx.allocator,
            "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ?",
            &[_][]const u8{ctx.session_id},
        ) catch |err| {
            return failStatus(ctx.allocator, "session lookup", @errorName(err));
        };
        defer q.deinit();
        const row = q.next() catch |err| {
            return failStatus(ctx.allocator, "session lookup", @errorName(err));
        };
        const r = row orelse return failStatus(ctx.allocator, "session lookup", "unknown session");
        defer r.deinit(ctx.allocator);
        if (r.values.len < 1 or r.values[0].len == 0) {
            return failStatus(ctx.allocator, "session lookup", "session has no owner");
        }
        owner = ctx.allocator.dupe(u8, r.values[0]) catch {
            return failStatus(ctx.allocator, "OOM", "dupe owner");
        };
    }
    // 2. Load the owner's existing config (null = defaults).
    const existing = user_config_store.loadRaw(ctx.allocator, ctx.db, owner.?) catch |err| {
        return failStatus(ctx.allocator, "load user config", @errorName(err));
    };
    defer if (existing) |e| ctx.allocator.free(e);
    // 3. Merge the live mcp_servers over it (same merge as file mode).
    const new_body = buildUpdatedConfigJson(ctx, existing) catch |err| {
        return failStatus(ctx.allocator, "merge user config", @errorName(err));
    };
    defer ctx.allocator.free(new_body);
    // 4. Save back to the owner's column.
    user_config_store.saveRaw(ctx.allocator, ctx.db, owner.?, new_body) catch |err| {
        return failStatus(ctx.allocator, "save user config", @errorName(err));
    };
    di.clearMcpToolsCache();
    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server auth-mode status");
}

/// Build a `<persisted>false: <op> <reason></persisted>`-shaped failure
/// status. The result is owned by `allocator` — caller frees.
fn failStatus(allocator: std.mem.Allocator, op: []const u8, reason: []const u8) []u8 {
    return std.fmt.allocPrint(
        allocator,
        "false: {s} {s}",
        .{ op, reason },
    ) catch allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server failure status");
}

/// Build the on-disk JSON body for the new config.
fn buildUpdatedConfigJson(ctx: ToolExecContext, existing: ?[]const u8) ![]u8 {
    const allocator = ctx.allocator;
    const live_mcp_servers = ctx.config.mcpServers() orelse .null;

    if (existing) |body| {
        // Parse existing as a generic Value so we can carry siblings
        // (active_profile, sub_agents, profiles_models, …) into the
        // new file without re-listing them by hand.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            // Fallback: malformed JSON → just emit mcp_servers alone.
            const serialized = try std.json.Stringify.valueAlloc(allocator, .{
                .mcp_servers = live_mcp_servers,
            }, .{ .whitespace = .indent_tab });
            return serialized;
        };
        defer parsed.deinit();

        const root = parsed.value;
        switch (root) {
            .object => |root_obj| {
                // Build the new map.
                var new_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer new_obj.deinit(allocator);
                var it = root_obj.iterator();
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key_ptr.*, "mcp_servers")) {
                        // Skip — replaced below with the live value.
                        continue;
                    }
                    const key_dup = try allocator.dupe(u8, kv.key_ptr.*);
                    errdefer allocator.free(key_dup);
                    try new_obj.put(allocator, key_dup, kv.value_ptr.*);
                }
                // Live mcp_servers overrides whatever was on disk.
                // Value is borrowed from ctx.config — no deep copy
                // needed; Stringify.valueAlloc reads it on serialize.
                try new_obj.put(allocator, try allocator.dupe(u8, "mcp_servers"), live_mcp_servers);

                // Serialize FIRST (deep-copies the structure into a flat
                // string buffer), THEN free the source map.
                const serialized = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_obj }, .{
                    .whitespace = .indent_tab,
                });
                errdefer allocator.free(serialized);

                // Free the duped keys (ObjectMap.deinit doesn't).
                // Values stay borrowed — their owners are ctx.config
                // (mcp_servers) and parsed.value (siblings).
                var free_it = new_obj.iterator();
                while (free_it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                }
                new_obj.deinit(allocator);
                return serialized;
            },
            else => {
                // Root wasn't an object — emit a minimal config.
                return try std.json.Stringify.valueAlloc(allocator, .{
                    .mcp_servers = live_mcp_servers,
                }, .{ .whitespace = .indent_tab });
            },
        }
    }

    // No existing file: emit a fresh config with just mcp_servers.
    return try std.json.Stringify.valueAlloc(allocator, .{
        .mcp_servers = live_mcp_servers,
    }, .{ .whitespace = .indent_tab });
}

// `freeJsonValueRecursive` removed: the cleaner `buildUpdatedConfigJson`
// refactor (skip + replace the `mcp_servers` key during the walk) no longer
// needs to deep-free old values — the borrowed old value goes back to

// ───────────────────────────────────────────────────────────────────────
// Best-effort tools listing (post-mutation)
// ───────────────────────────────────────────────────────────────────────

/// Spawn the just-added server and run a `tools/list` JSON-RPC roundtrip,
/// filling the `tools` array of the success payload.
fn listAndAppendTools(ctx: ToolExecContext, inner_json: []const u8, server_name: []const u8) ![]const u8 {
    const server = ctx.config.mcpServerConfig(server_name) orelse return inner_json;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(ctx.allocator);
    if (server.command) |cmd| {
        argv_list.append(ctx.allocator, ctx.allocator.dupe(u8, cmd) catch return inner_json) catch return inner_json;
    } else {
        return inner_json;
    }
    if (server.args) |a| {
        for (a) |arg| {
            argv_list.append(ctx.allocator, ctx.allocator.dupe(u8, arg) catch return inner_json) catch return inner_json;
        }
    }
    const argv = argv_list.toOwnedSlice(ctx.allocator) catch return inner_json;
    defer {
        for (argv) |a| ctx.allocator.free(a);
        ctx.allocator.free(argv);
    }

    // Via the singleton struct (see root.zig `mcpStdioRegistry`).
    const reg = exec_pabrikcore.mcpStdioRegistry(ctx.allocator);
    var lease = reg.acquire(server_name, argv, .{}) catch return inner_json;
    defer lease.release();
    const client = lease.client();
    const req = ctx.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return inner_json;
    defer ctx.allocator.free(req);
    // 60s deadline matches `handle_mcp_tool.zig:79` and
    // `prompts_build_messages_for_agent_prompt.zig:637`.
    const deadline_ns: u64 = 60 * std.time.ns_per_s;
    client.send(req, deadline_ns) catch |err| {
        if (err == error.SendTimeout) lease.markStale();
        return inner_json;
    };
    const resp = client.recv(deadline_ns, null) catch |err| {
        if (err == error.RecvTimeout) lease.markStale();
        return inner_json;
    };
    // No `free` for `resp`: it came from `client.recv`, which allocates in
    // the client's own arena (`client.allocator()`), not in `ctx.allocator`.

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), resp, .{
        .ignore_unknown_fields = true,
    }) catch return inner_json;
    const root = parsed.value;
    const result_val = root.object.get("result") orelse return inner_json;
    const tools_val = result_val.object.get("tools") orelse return inner_json;
    const arr = switch (tools_val) {
        .array => |a| a,
        else => return inner_json,
    };

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.allocator);
    for (arr.items) |tool_value| {
        const obj = switch (tool_value) {
            .object => |o| o,
            else => continue,
        };
        const name_val = obj.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        const entry = std.fmt.allocPrint(ctx.allocator, "mcp_{s}_{s}", .{ server_name, name }) catch continue;
        names.append(ctx.allocator, entry) catch {
            ctx.allocator.free(entry);
            return inner_json;
        };
    }
    if (names.items.len == 0) return inner_json;
    defer for (names.items) |n| ctx.allocator.free(n);

    // Fill the payload's `"tools":null` with the string array.
    const placeholder = "\"tools\":null";
    const tools_idx = std.mem.indexOf(u8, inner_json, placeholder) orelse return inner_json;
    const tools_json = std.json.Stringify.valueAlloc(ctx.allocator, names.items, .{}) catch return inner_json;
    defer ctx.allocator.free(tools_json);
    const replacement = std.fmt.allocPrint(ctx.allocator, "\"tools\":{s}", .{tools_json}) catch return inner_json;
    defer ctx.allocator.free(replacement);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(ctx.allocator);
    result.appendSlice(ctx.allocator, inner_json[0..tools_idx]) catch return inner_json;
    result.appendSlice(ctx.allocator, replacement) catch return inner_json;
    result.appendSlice(ctx.allocator, inner_json[tools_idx + placeholder.len ..]) catch return inner_json;
    return result.toOwnedSlice(ctx.allocator) catch inner_json;
}

// ───────────────────────────────────────────────────────────────────────
// Inline tests
// ───────────────────────────────────────────────────────────────────────

const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: exec_pabrikcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = exec_testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: exec_pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *exec_pabrikcore.sqlite.SqliteBackend) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined, // overridden by the test
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn exec_fixtureConfig(allocator: std.mem.Allocator) !exec_config_mod.LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = exec_config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = exec_config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
}

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

// ─── Test 1: success path (persistence disabled — no environment) ───────

test "execAddMcpServer: valid stdio entry → wrapped success envelope" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try exec_fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"hello","transport":"stdio","command":"mcp-hello-world","args":["--port","3001"]}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try exec_testing.expectEqualStrings("add_mcp_server", env.get("tool").?.string);
    try exec_testing.expect(env.get("success").?.bool);
    try exec_testing.expect(env.get("error").? == .null);
    // The pure-fn payload is surfaced in `data`.
    const data = env.get("data").?.object;
    try exec_testing.expectEqualStrings("hello", data.get("name").?.string);
    try exec_testing.expectEqualStrings("mcp-hello-world", data.get("command").?.string);
    const args = data.get("args").?.array;
    try exec_testing.expectEqual(@as(usize, 2), args.items.len);
    try exec_testing.expectEqualStrings("--port", args.items[0].string);

    // Live config mutated.
    try exec_testing.expect(cfg.hasMcpServer("hello"));
    const server = cfg.mcpServerConfig("hello").?;
    try exec_testing.expectEqualStrings("mcp-hello-world", server.command.?);
}

// ─── Test 2: malformed JSON args → wrapped parse error ─────────────────

test "execAddMcpServer: malformed JSON args → wrapped error envelope" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try exec_fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server", "{not json at all");

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    try exec_testing.expect(!env2.value.object.get("success").?.bool);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json at all` is a syntax error, so
    // the explanation names JSON and the usual causes.
    const mcp_err = env2.value.object.get("error").?.string;
    try exec_testing.expect(std.mem.indexOf(u8, mcp_err, "JSON") != null);
    try exec_testing.expect(std.mem.indexOf(u8, mcp_err, "SyntaxError") == null);

    // No server added.
    try exec_testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 3: empty name (validation error) → wrapped error envelope ─────

test "execAddMcpServer: empty name → wrapped error envelope (success=false)" {
    const alloc = exec_testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try exec_fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"","transport":"stdio","command":"x"}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try exec_testing.expect(result.output_allocated);
    const env3 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env3.deinit();
    try exec_testing.expect(!env3.value.object.get("success").?.bool);
    try exec_testing.expect(std.mem.indexOf(u8, env3.value.object.get("error").?.string, "name is required") != null);
    // `data` is null on the error path — it lives ONLY on success
    // (see wrapToolOutput). Mirrors save_memory's error contract.
    try exec_testing.expect(env3.value.object.get("data").? == .null);

    // No server added.
    try exec_testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 4: substitutePersistedStatus replaces the placeholder correctly ─
// F1 fix regression guard.
test "substitutePersistedStatus: replaces placeholder with success status" {
    const alloc = exec_testing.allocator;
    const inner =
        "{\"name\":\"ctx7\"," ++
        "\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "true");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try exec_testing.expectEqualStrings("true", parsed.value.object.get("persisted").?.string);
    // Sibling fields are preserved.
    try exec_testing.expectEqualStrings("ctx7", parsed.value.object.get("name").?.string);
}

test "substitutePersistedStatus: replaces placeholder with failure reason" {
    const alloc = exec_testing.allocator;
    const inner = "{\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "false: createDirPath FileNotFound");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try exec_testing.expectEqualStrings("false: createDirPath FileNotFound", parsed.value.object.get("persisted").?.string);
}

test "substitutePersistedStatus: status with quotes stays valid JSON" {
    const alloc = exec_testing.allocator;
    const inner = "{\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "false: write \"oops\" failed");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try exec_testing.expectEqualStrings("false: write \"oops\" failed", parsed.value.object.get("persisted").?.string);
}

test "substitutePersistedStatus: missing placeholder returns error" {
    // F1 defense-in-depth: if the pure-fn payload ever drops the
    // `"persisted":"false"` placeholder, the exec wrapper
    // refuses to substitute a lie and surfaces an error instead.
    const alloc = exec_testing.allocator;
    const inner = "{\"name\":\"ctx7\"}";
    const result = substitutePersistedStatus(alloc, inner, "true");
    try exec_testing.expectError(error.MissingPersistedPlaceholder, result);
}

// F6 caveat: `persistAndReloadStatus` requires `exec_pabrikcore.getSingleton()`
// (the live App) so it can't be unit-tested in isolation — the path is
// exercised end-to-end when an LLM actually calls `add_mcp_server` in

