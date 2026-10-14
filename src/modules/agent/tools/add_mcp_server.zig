//! Agent-callable tool: `add_mcp_server` — register a new MCP server in the
//! live `LlmConfig` (in-memory + JSON mirror) so subsequent agent iterations
//! pick up its tools via `buildMCPToolsRun`. The HTTP transport is added in
//! a sibling task; this v1 covers stdio only (per the user request:
//! "handle mcp stdio first").
//!
//! Wire shape:
//!   input:  {
//!     name:     string,            // server name (key in mcp_servers)
//!     transport: "stdio" | "http", // v1 only accepts "stdio"
//!     command:  string,            // required when transport == "stdio"
//!     args:     string[]?,         // optional
//!     url:      string?,           // reserved for the HTTP follow-up
//!     headers:  { key: value }[]?, // reserved for the HTTP follow-up
//!   }
//!   output: {"name":...,"transport":"stdio","command":...,
//!            "args":[...],            // [] when none
//!            "persisted":"false",      // placeholder; exec wrapper substitutes
//!            "tools":null,             // exec wrapper fills in best-effort
//!            "note":...}
//!   or:     {"error":...}
//!
//! Plan: docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
//!
//! Why a separate file (vs adding to the existing tools_exec_add_*.zig
//! chain): the storage primitive already lives in `Config.zig`. This
//! file is the LLM-facing wrapper — JSON schema, input struct, success/
//! error XML envelopes. The exec adapter in
//! `src/agentic_loop/tools_exec_add_mcp_server.zig` calls
//! `executeAddMcpServerToJSON` (same shape as `memory.zig`'s
//! `executeAddSkillToString`).
//!
//! Notes for the future HTTP branch: the input struct already has
//! `url` + `headers` fields (optional). The validator rejects any
//! non-stdio transport today; the HTTP case is a sibling task and will
//! add its own branch in `executeAddMcpServerToJSON`. Mirrors the
//! frontend `McpServerModal` wire shape exactly so the LLM-facing
//! contract doesn't change when HTTP lands.

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

/// Input for `add_mcp_server`. The LLM fills in `name` + `transport`; the
/// transport-specific fields (`command` for stdio, `url` for HTTP) are
/// v1-required when the matching transport is selected. `args` is the
/// optional stdio field. `url` / `headers` are reserved for the HTTP
/// sibling task (plan 2026-08-28-mcp-streamable-http + agent-tool).
///
/// There is deliberately no `cwd`: the parameter was dropped on 2026-10-14.
/// It only ever reached the success envelope — nothing spawned a process
/// with it — so it advertised a guarantee the tool did not honour, and the
/// stdio child's working directory comes from the server's own config entry
/// (which is stored with the rest of the workspace config).
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

/// Execute the `add_mcp_server` tool. Mutates `config.mcp_servers` in
/// place (so the new server's tools appear in the NEXT agent iteration's
/// system prompt via `buildMCPToolsRun`); the disk persistence + live-
/// reload path lives in the exec wrapper so it can swap `di.llm_config`
/// atomically (see `tools_exec_add_mcp_server.zig`).
///
/// Returns a JSON string for the LLM. The success payload carries:
///   - `name`, `transport`, `command` — what was added
///   - `args` — array of argv strings ([] when none)
///   - `persisted` — disk-write outcome (only the exec wrapper can
///     persist; pure fn reports `"false"` as a placeholder the wrapper
///     substitutes)
///   - `tools` — null here; the exec wrapper fills in the best-effort
///     `mcp_<server>_<tool>` listing after a successful spawn
///   - `note` — operator-facing hint ("server will be available on the
///     next iteration")
///
/// Error payload: `{"error":...}`.
///
/// `io` is unused today but kept in the signature so the HTTP branch
/// (which needs HTTP transport) doesn't have to change call sites.
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
    // StdioRegistry (whose arena is only cleaned up in `deinitGlobal`,
    // which tests don't call) and the test allocator would flag it as a
    // leak. The exec wrapper performs the listing AFTER the in-memory
    // mutation succeeds, where process-level registry state is fine.

    // ── 3. Build the success payload (`tools` stays null here; exec
    // wrapper fills it in after a successful listing). ───────────────
    return successJSON(allocator, input);
}

// ───────────────────────────────────────────────────────────────────────
// JSON payloads
// ───────────────────────────────────────────────────────────────────────

// Note on the best-effort `tools/list` listing: it lives in the exec
// wrapper (see `tools_exec_add_mcp_server.zig::listAndAppendTools`),
// NOT the pure fn. Doing it here would call `StdioRegistry.global()`
// from the pure fn's unit tests, polluting the global registry's
// arena with no cleanup path (the global arena is freed only in
// `deinitGlobal`, which tests never call).

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
const add_mcp_server_mod = @import("add_mcp_server.zig");

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

    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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

    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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

    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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

    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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
    const first = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "first-cmd",
    });
    defer alloc.free(first);
    // Second add with the same name fails; envelope mentions the key.
    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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
    const tool = add_mcp_server_mod.add_mcp_server_tool;

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

    const result = try add_mcp_server_mod.executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
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
