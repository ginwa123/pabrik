//! Agent-callable MCP-server tools: `add_mcp_server`, `edit_mcp_server`,
//! `delete_mcp_server`. All three mutate the live `LlmConfig` (typed map +
//! JSON mirror) so subsequent agent iterations pick up the change via

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const config_mod = pabrikcore.config;
const LlmConfig = config_mod.LlmConfig;

const helpers = @import("helpers");
const sanitize = helpers.sanitize_control_chars;

/// One MCP header entry (HTTP transport). The LLM sends an array of these;
/// `Config.zig` converts it to the on-disk `{key: value}` object shape.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// ───────────────────────────────────────────────────────────────────────
// add_mcp_server
// ───────────────────────────────────────────────────────────────────────

/// Input for `add_mcp_server`. The LLM fills in `name` + `transport`; the
/// transport-specific fields (`command` for stdio, `url` for HTTP) are
/// required when the matching transport is selected.
pub const AddMcpServerInput = struct {
    /// Server name (key in `mcp_servers`). Must be non-empty and must not
    /// collide with an existing server. Trailing whitespace is NOT
    /// trimmed — the caller passes the exact key.
    name: []const u8 = "",

    /// Transport discriminator: `"stdio"` or `"http"`.
    transport: []const u8 = "stdio",

    /// stdio command. Required when `transport == "stdio"`. Empty for HTTP.
    command: []const u8 = "",

    /// stdio argv. Optional.
    args: ?[]const []const u8 = null,

    /// HTTP URL. Required when `transport == "http"`. Empty for stdio.
    url: []const u8 = "",

    /// HTTP headers. Optional. Each entry is `{name, value}`; the array
    /// shape mirrors the frontend `McpServerModal`.
    headers: ?[]const Header = null,
};

/// Tool definition for the LLM. The description is the agent's primary
/// "when to call this" signal — it lists BOTH transports' fields.
pub const add_mcp_server_tool_system_prompt =
    \\\\## Add MCP Server Tool — Behavior
    \\\\Use `add_mcp_server` to register a new MCP server at runtime.
    \\\\- stdio: provide `name`, `transport="stdio"`, `command`, and optional `args`. http: provide `name`, `transport="http"`, `url`, and optional `headers` (an array of `{name,value}` objects).
    \\\\- The new server's tools become discoverable with `search_tool` on the NEXT iteration; call `use_tool` to make one callable.
    \\\\- The server's tools are NOT injected into your tool list automatically — MCP tools are progressive.
    \\\\
;

pub const add_mcp_server_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_mcp_server",
        .description =
        \\\\Register a new MCP (Model Context Protocol) server with `add_mcp_server` so its tools become available on the NEXT iteration. Call it when the user asks to add an MCP integration or register a tool provider.
        \\\\
        \\\\After a successful call the server's tools appear as `mcp_<serverName>_<toolName>`: find one with `search_tool`, then `use_tool` to make it callable. They are NOT in your tool list automatically — finish your reply first.
        \\\\
        \\\\Two transports. `transport="stdio"` spawns a child process: pass `command` (e.g. `"npx"`) and optional `args` (one string per argv entry). `transport="http"` POSTs JSON-RPC to a remote endpoint: pass `url` and optional `headers` (an array of `{name,value}` objects, e.g. `[{"name":"Authorization","value":"Bearer ..."}]`). Exactly one transport's fields apply — the other transport's fields are ignored.
        \\\\
        \\\\The call validates the input, mutates the live in-memory config, then persists it to `~/.config/pabrik/config.json` (or platform equivalent) so the server survives restart. It still succeeds if the server cannot be reached right now.
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
                    .description = "Transport: `\"stdio\"` (spawn a child process) or `\"http\"` (POST JSON-RPC to a remote endpoint).",
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
                    .description = "HTTP endpoint URL. Required when transport == \"http\". E.g. `\"https://mcp.context7.com/mcp\"`.",
                },
                .{
                    .name = "headers",
                    .type = "array",
                    .description = "HTTP headers (optional). An array of `{name,value}` objects, e.g. `[{\"name\":\"Authorization\",\"value\":\"Bearer ...\"}]`.",
                },
            },
            .required = &.{ "name", "transport" },
        },
        .system_prompt = add_mcp_server_tool_system_prompt,
    },
};

// ───────────────────────────────────────────────────────────────────────
// edit_mcp_server
// ───────────────────────────────────────────────────────────────────────

/// Input for `edit_mcp_server`. Only `name` is required; every other field
/// is a patch. A null field means "leave the stored value alone".
pub const EditMcpServerInput = struct {
    /// The server to edit. Must already exist — this tool never creates.
    name: []const u8 = "",

    /// Transport switch. Omit to keep the current transport. When present
    /// it must be accompanied by the new transport's required field
    /// (`command` for stdio, `url` for http) — the old transport's fields
    transport: []const u8 = "",

    /// stdio command. Required when the target transport is stdio and no
    /// command is stored yet.
    command: []const u8 = "",

    /// stdio argv. `null` keeps the stored argv; an empty slice clears it.
    args: ?[]const []const u8 = null,

    /// HTTP URL. Required when the target transport is http and no url is
    /// stored yet.
    url: []const u8 = "",

    /// HTTP headers. `null` keeps the stored map; an empty slice clears it.
    headers: ?[]const Header = null,

    /// Enable/disable toggle. `null` keeps the stored flag.
    enabled: ?bool = null,
};

/// Tool definition for the LLM. The description names the patch semantics
/// and the transport switch, because those are the two things a model gets
/// wrong.
pub const edit_mcp_server_tool_system_prompt =
    \\\\## Edit MCP Server Tool — Behavior
    \\\\Use `edit_mcp_server` to change an MCP server that is already registered.
    \\\\- Only `name` is required. Every other field is a PATCH: omit it to keep the stored value, pass an empty array (`args`/`headers`) to clear it.
    \\\\- To switch transports, pass `transport` plus the new transport's field (`command` for stdio, `url` for http). The old transport's fields are dropped.
    \\\\- There is no rename. A rename is `delete_mcp_server` then `add_mcp_server`.
    \\\\- The change takes effect on the NEXT iteration; the server's tools are re-listed then.
    \\\\
;

pub const edit_mcp_server_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_mcp_server",
        .description =
        \\\\Update an MCP server that is already registered with `edit_mcp_server`. Call it when the user asks to change a server's URL, command, arguments, headers, or to enable/disable it.
        \\\\
        \\\\Only `name` is required. Every other field is a PATCH — omit a field to keep its stored value. Pass an empty array for `args` or `headers` to clear them. Pass `enabled=false` to make the agent skip the server without deleting it.
        \\\\
        \\\\To SWITCH transports, pass `transport` together with the new transport's field: `transport="stdio"` + `command`, or `transport="http"` + `url`. The fields belonging to the old transport are dropped, because a server entry carries exactly one transport.
        \\\\
        \\\\There is no rename — the server name is the key every `mcp_<server>_<tool>` name is built from. A rename is `delete_mcp_server` followed by `add_mcp_server`.
        \\\\
        \\\\The call validates the input, mutates the live in-memory config, then persists it to `~/.config/pabrik/config.json` (or platform equivalent) so the change survives restart. The new configuration is used on the NEXT iteration.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Server key to edit. Must already exist — this tool never creates a server.",
                },
                .{
                    .name = "transport",
                    .type = "string",
                    .description = "New transport: `\"stdio\"` or `\"http\"`. Omit to keep the current one. When present, supply the new transport's field too.",
                },
                .{
                    .name = "command",
                    .type = "string",
                    .description = "stdio binary to spawn. Required when the target transport is stdio and no command is stored yet.",
                },
                .{
                    .name = "args",
                    .type = "array",
                    .description = "stdio argv. Omit to keep the stored argv; pass `[]` to clear it. One string per argument.",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "HTTP endpoint URL. Required when the target transport is http and no url is stored yet.",
                },
                .{
                    .name = "headers",
                    .type = "array",
                    .description = "HTTP headers. Omit to keep the stored headers; pass `[]` to clear them. An array of `{name,value}` objects.",
                },
                .{
                    .name = "enabled",
                    .type = "boolean",
                    .description = "Enable/disable the server. Omit to keep the current flag. `false` makes the agent skip it without deleting it.",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = edit_mcp_server_tool_system_prompt,
    },
};

// ───────────────────────────────────────────────────────────────────────
// delete_mcp_server
// ───────────────────────────────────────────────────────────────────────

/// Input for `delete_mcp_server`. One required field — the server name.
pub const DeleteMcpServerInput = struct {
    /// The server to remove. Must already exist; this tool never creates.
    name: []const u8 = "",
};

/// Tool definition for the LLM. The description names the consequence
/// (the server's tools stop being callable) because that is the part a
/// model tends to under-weight.
pub const delete_mcp_server_tool_system_prompt =
    \\\\## Delete MCP Server Tool — Behavior
    \\\\Use `delete_mcp_server` to remove an MCP server that is already registered.
    \\\\- Pass only `name`. The entry is dropped whole, whichever transport it used.
    \\\\- After the call the server's `mcp_<server>_<tool>` tools stop being callable — a call already in flight fails.
    \\\\- To keep the server but stop the agent using it, prefer `edit_mcp_server` with `enabled=false`.
    \\\\- There is no undo. Re-adding is `add_mcp_server` with the same fields.
    \\\\
;

pub const delete_mcp_server_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_mcp_server",
        .description =
        \\\\Remove an MCP server that is already registered with `delete_mcp_server`. Call it when the user asks to remove, unregister or drop an MCP integration.
        \\\\
        \\\\Pass only `name`. The entry is dropped whole, whichever transport it used (stdio or http).
        \\\\
        \\\\After the call the server's `mcp_<serverName>_<toolName>` tools stop being callable — a call already in flight fails. To keep the server configured but stop the agent using it, prefer `edit_mcp_server` with `enabled=false`.
        \\\\
        \\\\There is no undo. Re-adding is `add_mcp_server` with the same fields.
        \\\\
        \\\\The call mutates the live in-memory config, then persists it to `~/.config/pabrik/config.json` (or platform equivalent) so the removal survives restart. The server is gone from the NEXT iteration.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Server key to remove. Must already exist — this tool never creates a server.",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = delete_mcp_server_tool_system_prompt,
    },
};

// ───────────────────────────────────────────────────────────────────────
// Pure fns — mutate the live config, return a JSON payload for the LLM
// ───────────────────────────────────────────────────────────────────────

/// Execute `add_mcp_server`. Mutates `config.mcp_servers` in place; the
/// disk persistence + live-reload path lives in the exec fn below.
///
pub fn executeAddMcpServerToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *LlmConfig,
    input: AddMcpServerInput,
) ![]const u8 {
    _ = io; // reserved for a future HTTP-probe branch

    // ── 1. Validate transport + per-transport fields ───────────────────
    const is_http = std.mem.eql(u8, input.transport, "http");
    const is_stdio = std.mem.eql(u8, input.transport, "stdio");
    if (!is_http and !is_stdio) {
        return jsonError(allocator,
            \\\\transport must be "stdio" or "http". For a child process set transport="stdio" and provide a non-empty `command`; for a remote endpoint set transport="http" and provide a non-empty `url`.
        );
    }

    // ── 2. Call the storage primitive for the selected transport ───────
    if (is_http) {
        // `headerInputs` converts the LLM's {name,value}[] into the
        // Config.zig-shaped slice. The primitive deep-copies every entry,
        // so this temporary is freed as soon as the call returns.
        const hdr_inputs = try headerInputs(allocator, input.headers);
        defer if (hdr_inputs) |h| allocator.free(h);

        config_mod.LlmConfig.addMcpServerHttp(config, .{
            .name = input.name,
            .url = input.url,
            .headers = hdr_inputs,
        }) catch |err| {
            const owned_msg = addErrMessage(allocator, err, input.name);
            defer if (owned_msg) |m| allocator.free(m);
            return jsonError(allocator, owned_msg orelse addErrFallback(err));
        };
    } else {
        config_mod.LlmConfig.addMcpServerStdio(config, .{
            .name = input.name,
            .command = input.command,
            .args = input.args,
        }) catch |err| {
            const owned_msg = addErrMessage(allocator, err, input.name);
            defer if (owned_msg) |m| allocator.free(m);
            return jsonError(allocator, owned_msg orelse addErrFallback(err));
        };
    }

    // No best-effort tools listing here — it would pollute the global
    // StdioRegistry (whose arena is only cleaned up in `deinitGlobal`,
    // which tests don't call) and the test allocator would flag it as a

    // ── 3. Build the success payload (`tools` stays null here; the exec
    // fn fills it in after a successful listing). ─────────────────────
    return successJSON(allocator, input);
}

/// Execute `edit_mcp_server`. Mutates `config.mcp_servers` in place.
///
/// The success payload echoes the RESULTING entry (rather than what was
pub fn executeEditMcpServerToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *LlmConfig,
    input: EditMcpServerInput,
) ![]const u8 {
    _ = io; // reserved for a future HTTP-probe branch

    // ── 1. Resolve the optional strings into the primitive's optionals ──
    // An empty string from the LLM means "not supplied" — the schema has
    // no way to express JSON null for a string field, and a model that
    const transport_opt: ?[]const u8 = if (input.transport.len == 0) null else input.transport;
    const command_opt: ?[]const u8 = if (input.command.len == 0) null else input.command;
    const url_opt: ?[]const u8 = if (input.url.len == 0) null else input.url;

    // ── 2. Convert the header array (null = keep, [] = clear) ──────────
    // The primitive deep-copies every entry, so the temporary slice is
    // freed as soon as the call returns.
    var header_buf: std.ArrayList(LlmConfig.McpHeaderInput) = .empty;
    defer header_buf.deinit(allocator);
    const headers_opt: ?[]const LlmConfig.McpHeaderInput = if (input.headers) |hdrs| blk: {
        for (hdrs) |h| {
            if (h.name.len == 0) continue;
            try header_buf.append(allocator, .{ .name = h.name, .value = h.value });
        }
        break :blk try header_buf.toOwnedSlice(allocator);
    } else null;
    defer if (headers_opt) |h| allocator.free(h);

    // ── 3. Call the storage primitive ──────────────────────────────────
    config_mod.LlmConfig.editMcpServer(config, .{
        .name = input.name,
        .transport = transport_opt,
        .command = command_opt,
        .args = input.args,
        .url = url_opt,
        .headers = headers_opt,
        .enabled = input.enabled,
    }) catch |err| {
        const owned_msg = editErrMessage(allocator, err, input.name);
        defer if (owned_msg) |m| allocator.free(m);
        return jsonError(allocator, owned_msg orelse editErrFallback(err));
    };

    // ── 4. Build the success payload from the RESULTING entry ──────────
    const server = config.mcpServerConfig(input.name) orelse {
        return jsonError(allocator, "server vanished mid-edit — retry the call");
    };
    return editSuccessJSON(allocator, input.name, server);
}

/// Execute `delete_mcp_server`. Mutates `config.mcp_servers` in place.
///
/// Success payload: `name`, `removed` (always true on this path — the
pub fn executeDeleteMcpServerToJSON(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *LlmConfig,
    input: DeleteMcpServerInput,
) ![]const u8 {
    _ = io; // no transport work happens here

    config_mod.LlmConfig.removeMcpServer(config, input.name) catch |err| {
        const owned_msg = deleteErrMessage(allocator, err, input.name);
        defer if (owned_msg) |m| allocator.free(m);
        return jsonError(allocator, owned_msg orelse deleteErrFallback(err));
    };

    return deleteSuccessJSON(allocator, input.name);
}

// ───────────────────────────────────────────────────────────────────────
// Shared pure-fn helpers
// ───────────────────────────────────────────────────────────────────────

/// Convert the LLM's `{name,value}[]` header array into the
/// `Config.zig`-shaped slice. Returns null on OOM — the caller then
/// treats the server as header-less rather than failing the whole add.
fn headerInputs(
    allocator: std.mem.Allocator,
    headers: ?[]const Header,
) !?[]const LlmConfig.McpHeaderInput {
    const hdrs = headers orelse return null;
    if (hdrs.len == 0) return null;
    var out: std.ArrayList(LlmConfig.McpHeaderInput) = .empty;
    errdefer out.deinit(allocator);
    for (hdrs) |h| {
        if (h.name.len == 0) continue;
        try out.append(allocator, .{ .name = h.name, .value = h.value });
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

/// The per-error message for a failed add. Returns an OWNED slice when
/// the message interpolates the server name, else null (the caller then
/// uses the static fallback). `jsonError` copies through the sanitizer.
fn addErrMessage(
    allocator: std.mem.Allocator,
    err: anyerror,
    name: []const u8,
) ?[]u8 {
    return switch (err) {
        error.DuplicateServer => std.fmt.allocPrint(
            allocator,
            "an MCP server named '{s}' is already configured — choose a different name",
            .{name},
        ) catch null,
        else => null,
    };
}

/// Static fallback message per error, for the cases that need no
/// interpolation.
fn addErrFallback(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "name is required (must be non-empty)",
        error.InvalidCommand => "command is required (must be non-empty for stdio transport)",
        error.InvalidUrl => "url is required (must be non-empty for http transport)",
        error.DuplicateServer => "an MCP server with that name is already configured",
        else => @errorName(err),
    };
}

/// The per-error message for a failed edit. Returns an OWNED slice when
/// the message interpolates the server name, else null.
fn editErrMessage(
    allocator: std.mem.Allocator,
    err: anyerror,
    name: []const u8,
) ?[]u8 {
    return switch (err) {
        error.ServerNotFound => std.fmt.allocPrint(
            allocator,
            "no MCP server named '{s}' is configured — call add_mcp_server first, or check the name",
            .{name},
        ) catch null,
        else => null,
    };
}

/// Static fallback message per error, for the cases that need no
/// interpolation.
fn editErrFallback(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "name is required (must be non-empty)",
        error.InvalidTransport => "transport must be \"stdio\" or \"http\"",
        error.InvalidCommand => "command is required (must be non-empty for stdio transport)",
        error.InvalidUrl => "url is required (must be non-empty for http transport)",
        error.ServerNotFound => "no MCP server with that name is configured",
        else => @errorName(err),
    };
}

/// The per-error message for a failed delete. Returns an OWNED slice when
/// the message interpolates the server name, else null.
fn deleteErrMessage(
    allocator: std.mem.Allocator,
    err: anyerror,
    name: []const u8,
) ?[]u8 {
    return switch (err) {
        error.ServerNotFound => std.fmt.allocPrint(
            allocator,
            "no MCP server named '{s}' is configured — nothing to delete",
            .{name},
        ) catch null,
        else => null,
    };
}

/// Static fallback message per error, for the cases that need no
/// interpolation.
fn deleteErrFallback(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "name is required (must be non-empty)",
        error.ServerNotFound => "no MCP server with that name is configured",
        else => @errorName(err),
    };
}

// ───────────────────────────────────────────────────────────────────────
// JSON payloads
// ───────────────────────────────────────────────────────────────────────

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
    const clean_url = try sanitize(allocator, input.url);
    defer allocator.free(clean_url);

    var clean_args: std.ArrayList([]u8) = .empty;
    defer {
        for (clean_args.items) |a| allocator.free(a);
        clean_args.deinit(allocator);
    }
    if (input.args) |a| {
        for (a) |arg| try clean_args.append(allocator, try sanitize(allocator, arg));
    }

    // Both transport fields are always emitted so the payload shape is
    // stable across transports — the unused one is an empty string.
    return std.json.Stringify.valueAlloc(allocator, .{
        .name = clean_name,
        .transport = clean_transport,
        .command = clean_command,
        .url = clean_url,
        .args = clean_args.items,
        .persisted = "false",
        .tools = @as(?[]const u8, null),
        .note = "MCP server registered in the live config. Its tools will appear as mcp_<server>_<tool> in your next system-prompt rebuild. Disk persistence + live-reload are performed by the exec wrapper.",
    }, .{});
}

fn editSuccessJSON(
    allocator: std.mem.Allocator,
    name: []const u8,
    server: LlmConfig.McpServerConfig,
) ![]u8 {
    const clean_name = try sanitize(allocator, name);
    defer allocator.free(clean_name);
    const clean_command = if (server.command) |c| try sanitize(allocator, c) else "";
    defer if (server.command) |_| allocator.free(clean_command);
    const clean_url = if (server.url) |u| try sanitize(allocator, u) else "";
    defer if (server.url) |_| allocator.free(clean_url);

    var clean_args: std.ArrayList([]u8) = .empty;
    defer {
        for (clean_args.items) |a| allocator.free(a);
        clean_args.deinit(allocator);
    }
    if (server.args) |a| {
        for (a) |arg| try clean_args.append(allocator, try sanitize(allocator, arg));
    }

    var clean_headers: std.ArrayList([]u8) = .empty;
    defer {
        for (clean_headers.items) |a| allocator.free(a);
        clean_headers.deinit(allocator);
    }
    var h_it = server.headers.iterator();
    while (h_it.next()) |h| {
        const k = try sanitize(allocator, h.key_ptr.*);
        errdefer allocator.free(k);
        const v = try sanitize(allocator, h.value_ptr.*);
        errdefer allocator.free(v);
        // Rendered as "Name: value" so the LLM sees which header is which
        // without the payload needing a nested object per header.
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ k, v });
        allocator.free(k);
        allocator.free(v);
        try clean_headers.append(allocator, line);
    }

    const transport: []const u8 = switch (server.transport()) {
        .stdio => "stdio",
        .http => "http",
    };

    return std.json.Stringify.valueAlloc(allocator, .{
        .name = clean_name,
        .transport = transport,
        .command = clean_command,
        .url = clean_url,
        .args = clean_args.items,
        .headers = clean_headers.items,
        .enabled = server.enabled,
        .persisted = "false",
        .tools = @as(?[]const u8, null),
        .note = "MCP server updated in the live config. Its tools will be re-listed as mcp_<server>_<tool> on your next system-prompt rebuild. Disk persistence + live-reload are performed by the exec wrapper.",
    }, .{});
}

fn deleteSuccessJSON(
    allocator: std.mem.Allocator,
    name: []const u8,
) ![]u8 {
    const clean_name = try sanitize(allocator, name);
    defer allocator.free(clean_name);

    return std.json.Stringify.valueAlloc(allocator, .{
        .name = clean_name,
        .removed = true,
        .persisted = "false",
        .note = "MCP server removed from the live config. Its mcp_<server>_<tool> tools are no longer callable from the next iteration. Disk persistence + live-reload are performed by the exec wrapper.",
    }, .{});
}

fn jsonError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const clean = try sanitize(allocator, msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, .{ .@"error" = clean }, .{});
}

// ───────────────────────────────────────────────────────────────────────
// Exec adapters — parse LLM args, call the pure fn, persist, wrap
// ───────────────────────────────────────────────────────────────────────

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

    const output = try finishMcpServerExec(ctx, tc, "add_mcp_server", inner, parsed.value.name);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execEditMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        EditMcpServerInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const config_mut = @constCast(ctx.config);
    const inner = executeEditMcpServerToJSON(
        ctx.allocator,
        ctx.io,
        config_mut,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "edit_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try finishMcpServerExec(ctx, tc, "edit_mcp_server", inner, parsed.value.name);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execDeleteMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        DeleteMcpServerInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const config_mut = @constCast(ctx.config);
    const inner = executeDeleteMcpServerToJSON(
        ctx.allocator,
        ctx.io,
        config_mut,
        parsed.value,
    ) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "delete_mcp_server", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // No tools listing on the delete path: the server is gone, so there
    // is nothing to list.
    const output = try finishMcpServerExec(ctx, tc, "delete_mcp_server", inner, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Shared tail for all three exec fns: surface a pure-fn error as
/// `success=false`, otherwise persist + hot-reload, substitute the
/// `persisted` placeholder, best-effort list the server's tools, and wrap
fn finishMcpServerExec(
    ctx: ToolExecContext,
    tc: agent.ToolCall,
    tool_name: []const u8,
    inner: []const u8,
    server_name: []const u8,
) ![]u8 {
    // ── 1. Detect the error shape from the pure fn ─────────────────────
    var inner_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
    defer if (inner_parsed) |*par| par.deinit();
    if (inner_parsed) |par| {
        if (par.value == .object) {
            if (par.value.object.get("error")) |e| {
                if (e == .string and e.string.len > 0) {
                    return wrapToolOutput(ctx.allocator, tool_name, tc.function.arguments, false, e.string, inner);
                }
            }
        }
    }

    // ── 2. Persist to disk + hot-reload `di.llm_config` ────────────────
    // On any failure here the in-memory config is already updated (the
    // agent's iteration will see the change regardless), so we capture
    const persist_status_owned = persistAndReloadStatus(ctx) catch |err| blk: {
        std.log.warn(
            "{s}: in-memory mutation succeeded but disk write failed: {s}",
            .{ tool_name, @errorName(err) },
        );
        break :blk ctx.allocator.dupe(u8, "false") catch @as([]u8, &[_]u8{});
    };
    defer ctx.allocator.free(persist_status_owned);

    // ── 3. Inject the persisted status into the inner JSON. ─────────────
    const inner_with_status = try substitutePersistedStatus(
        ctx.allocator,
        inner,
        persist_status_owned,
    );
    defer ctx.allocator.free(inner_with_status);

    // ── 4. Best-effort tools listing (process-level registry is OK here)
    // SKIP when the exec context has no environment — that's our signal
    // that we're in a unit test, where calling `StdioRegistry.global`
    const inner_final = if (server_name.len == 0 or ctx.environment == null)
        inner_with_status
    else
        listAndAppendTools(ctx, inner_with_status, server_name) catch inner_with_status;

    // ── 5. Wrap the final envelope ─────────────────────────────────────
    return wrapToolOutput(ctx.allocator, tool_name, tc.function.arguments, true, null, inner_final);
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
        // placeholder is missing, surface a clear error rather than
        // return the unmodified JSON (which would lie to the LLM).
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
// Disk persistence + live-reload
// ───────────────────────────────────────────────────────────────────────

/// Persist the live config to `~/.config/pabrik/config.json` and hot-reload
/// `di.llm_config` via `setLlmConfig` so subsequent agent iterations see
/// the change through `buildMCPToolsRun`.
fn persistAndReloadStatus(ctx: ToolExecContext) ![]u8 {
    const di = exec_pabrikcore.getSingleton() catch return ctx.allocator.dupe(u8, "false: getSingleton failed") catch return ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the mcp_server failure status");
    // Auth mode: persist into the session owner's users.config_json
    // (Migration 092) instead of config.json, and skip the global
    // live-reload (config is per-user). config.json is never touched.
    if (di.auth_enabled) {
        return persistAuthModeStatus(ctx, di);
    }
    const env_ptr = di.environment orelse return std.fmt.allocPrint(ctx.allocator, "false: environment unavailable", .{}) catch ctx.allocator.dupe(u8, "false") catch @panic("allocPrint failed for the mcp_server failure status");
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
    // `createFileAbsolute` abort the whole process for a relative path.
    if (!std.fs.path.isAbsolute(config_path)) {
        return failStatus(ctx.allocator, "config_path", "not an absolute path");
    }

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

    const new_body = try buildUpdatedConfigJson(ctx, existing);
    defer ctx.allocator.free(new_body);

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

    // Fetch-once cache (plan: mcp-fetch-once-cache): lazy-invalidate so
    // the next workflow run refetches once and picks up the change.
    di.clearMcpToolsCache();
    invalidateRegistries(ctx);

    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the mcp_server success status");
}

/// Auth-mode persist. MCP servers are workspace-scoped, so the session's own
/// workspace row is the target. A session with no workspace falls back to the
/// owner's `users.config_json`.
fn persistAuthModeStatus(ctx: ToolExecContext, di: *exec_pabrikcore.App) ![]u8 {
    const user_config_store = exec_pabrikcore.user_config_store;
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

    const store = exec_pabrikcore.workspace_settings_store;
    const resolved_ws = exec_pabrikcore.session_llm_config.sessionWorkspace(ctx.allocator, ctx.db, ctx.session_id) catch null;
    defer if (resolved_ws) |w| ctx.allocator.free(w);
    const in_workspace = if (resolved_ws) |w| w.len > 0 else false;

    const existing = if (in_workspace)
        store.loadRaw(ctx.allocator, ctx.db, owner.?, resolved_ws.?) catch |err| {
            return failStatus(ctx.allocator, "load workspace config", @errorName(err));
        }
    else
        user_config_store.loadRaw(ctx.allocator, ctx.db, owner.?) catch |err| {
            return failStatus(ctx.allocator, "load user config", @errorName(err));
        };
    defer if (existing) |e| ctx.allocator.free(e);

    const new_body = buildUpdatedConfigJson(ctx, existing) catch |err| {
        return failStatus(ctx.allocator, "merge config", @errorName(err));
    };
    defer ctx.allocator.free(new_body);

    if (in_workspace) {
        store.saveRaw(ctx.allocator, ctx.db, owner.?, resolved_ws.?, new_body) catch |err| {
            return failStatus(ctx.allocator, "save workspace config", @errorName(err));
        };
    } else {
        user_config_store.saveRaw(ctx.allocator, ctx.db, owner.?, new_body) catch |err| {
            return failStatus(ctx.allocator, "save user config", @errorName(err));
        };
    }

    di.clearMcpToolsCache();
    invalidateRegistries(ctx);
    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the mcp_server auth-mode status");
}

/// Force the stdio + HTTP registries to drop their cached clients.
///
/// Without this an edited URL / command under the SAME server name keeps
fn invalidateRegistries(ctx: ToolExecContext) void {
    const di = exec_pabrikcore.getSingleton() catch return;
    const servers = ctx.config.mcpServers() orelse return;
    if (servers != .object) return;
    var it = servers.object.iterator();
    while (it.next()) |entry| {
        exec_pabrikcore.mcpStdioRegistry(di.allocator).markStale(entry.key_ptr.*);
        if (di.mcp_http_registry) |hreg| hreg.evict(entry.key_ptr.*);
    }
}

/// Build a `<persisted>false: <op> <reason></persisted>`-shaped failure
/// status. The result is owned by `allocator` — caller frees.
fn failStatus(allocator: std.mem.Allocator, op: []const u8, reason: []const u8) []u8 {
    return std.fmt.allocPrint(
        allocator,
        "false: {s} {s}",
        .{ op, reason },
    ) catch allocator.dupe(u8, "false") catch @panic("dupe failed for the mcp_server failure status");
}

/// Build the on-disk JSON body for the new config. Strategy:
///   - If `existing` is non-null, parse it as a generic `std.json.Value`,
///     copy each (key, value) pair into a fresh ObjectMap (skipping the
fn buildUpdatedConfigJson(ctx: ToolExecContext, existing: ?[]const u8) ![]u8 {
    const allocator = ctx.allocator;
    const live_mcp_servers = ctx.config.mcpServers() orelse .null;

    if (existing) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch {
            const serialized = try std.json.Stringify.valueAlloc(allocator, .{
                .mcp_servers = live_mcp_servers,
            }, .{ .whitespace = .indent_tab });
            return serialized;
        };
        defer parsed.deinit();

        const root = parsed.value;
        switch (root) {
            .object => |root_obj| {
                var new_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
                errdefer new_obj.deinit(allocator);
                var it = root_obj.iterator();
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key_ptr.*, "mcp_servers")) {
                        continue;
                    }
                    const key_dup = try allocator.dupe(u8, kv.key_ptr.*);
                    errdefer allocator.free(key_dup);
                    try new_obj.put(allocator, key_dup, kv.value_ptr.*);
                }
                try new_obj.put(allocator, try allocator.dupe(u8, "mcp_servers"), live_mcp_servers);

                const serialized = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_obj }, .{
                    .whitespace = .indent_tab,
                });
                errdefer allocator.free(serialized);

                var free_it = new_obj.iterator();
                while (free_it.next()) |kv| {
                    allocator.free(kv.key_ptr.*);
                }
                new_obj.deinit(allocator);
                return serialized;
            },
            else => {
                return try std.json.Stringify.valueAlloc(allocator, .{
                    .mcp_servers = live_mcp_servers,
                }, .{ .whitespace = .indent_tab });
            },
        }
    }

    return try std.json.Stringify.valueAlloc(allocator, .{
        .mcp_servers = live_mcp_servers,
    }, .{ .whitespace = .indent_tab });
}

// ───────────────────────────────────────────────────────────────────────
// Best-effort tools listing (post-mutation)
// ───────────────────────────────────────────────────────────────────────

/// Spawn/connect the just-mutated server and run a `tools/list` roundtrip,
/// filling the `tools` array of the success payload. On any failure
/// (spawn / send / recv / parse), the original inner JSON is returned
fn listAndAppendTools(ctx: ToolExecContext, inner_json: []const u8, server_name: []const u8) ![]const u8 {
    const server = ctx.config.mcpServerConfig(server_name) orelse return inner_json;

    if (server.transport() == .http) {
        return listAndAppendToolsHttp(ctx, inner_json, server_name, server);
    }
    return listAndAppendToolsStdio(ctx, inner_json, server_name, server);
}

fn listAndAppendToolsStdio(
    ctx: ToolExecContext,
    inner_json: []const u8,
    server_name: []const u8,
    server: exec_config_mod.LlmConfig.McpServerConfig,
) ![]const u8 {
    const cmd = server.command orelse return inner_json;
    if (cmd.len == 0) return inner_json;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(ctx.allocator);
    argv_list.append(ctx.allocator, ctx.allocator.dupe(u8, cmd) catch return inner_json) catch return inner_json;
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

    const reg = exec_pabrikcore.mcpStdioRegistry(ctx.allocator);
    var lease = reg.acquire(server_name, argv, .{
        // Bounded: this runs on a session's loop thread and shares the
        // per-server child with every other session, so `AcquireOptions{}`
        // (wait forever) would park the session with no deadline at all.
        .wait_ns = 60 * std.time.ns_per_s,
    }) catch return inner_json;
    defer lease.release();
    const client = lease.client();
    const req = ctx.allocator.dupe(u8,
        \\\\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return inner_json;
    defer ctx.allocator.free(req);
    // 60s deadline matches `handle_mcp_tool.zig` and
    // `prompts_build_messages_for_agent_prompt.zig`. Without a deadline,
    // a hung child blocks the tool-exec handler indefinitely.
    const deadline_ns: u64 = 60 * std.time.ns_per_s;
    client.send(req, deadline_ns) catch |err| {
        if (err == error.SendTimeout) lease.markStale();
        return inner_json;
    };
    const resp = client.recv(deadline_ns, null) catch |err| {
        if (err == error.RecvTimeout) lease.markStale();
        return inner_json;
    };
    // No `free` for `resp`: it came from `client.recv`, which allocates
    // in the client's own arena, not in `ctx.allocator`.

    return appendToolNames(ctx, inner_json, server_name, resp);
}

fn listAndAppendToolsHttp(
    ctx: ToolExecContext,
    inner_json: []const u8,
    server_name: []const u8,
    server: exec_config_mod.LlmConfig.McpServerConfig,
) ![]const u8 {
    const url = server.url orelse return inner_json;
    if (url.len == 0) return inner_json;

    // Build the custom-header slice from the typed map. MCP headers are
    // a small bounded set; a stack buffer (max 16) avoids a heap
    // allocation on this cold path.
    const kabelweb = @import("kabelweb");
    var std_header_buf: [16]kabelweb.client.Header = undefined;
    var header_count: usize = 0;
    var it = server.headers.iterator();
    while (it.next()) |h| {
        if (header_count >= std_header_buf.len) return inner_json;
        std_header_buf[header_count] = .{ .name = h.key_ptr.*, .value = h.value_ptr.* };
        header_count += 1;
    }

    const http_registry = exec_pabrikcore.mcpHttpRegistry(ctx.allocator);
    const http_client = http_registry.getOrConnect(
        server_name,
        url,
        std_header_buf[0..header_count],
    ) catch return inner_json;

    const mcp_tools = exec_pabrikcore.mcp_http.listTools(ctx.allocator, http_client) catch return inner_json;
    defer freeMcpTools(ctx.allocator, mcp_tools);

    // Re-serialize the tool names into the same `result.tools[]` JSON
    // shape the stdio branch produces, so one substitution routine
    // serves both transports.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena.allocator());
    for (mcp_tools) |t| {
        const entry = std.fmt.allocPrint(arena.allocator(), "mcp_{s}_{s}", .{ server_name, t.name }) catch continue;
        names.append(arena.allocator(), entry) catch continue;
    }
    if (names.items.len == 0) return inner_json;
    const names_json = std.json.Stringify.valueAlloc(arena.allocator(), names.items, .{}) catch return inner_json;
    return substituteToolsArray(ctx, inner_json, names_json);
}

/// Free a `[]mcp_types.McpTool` returned by `mcp_http.listTools`.
///
/// Only `name` and `description` are freed: those are the two fields
fn freeMcpTools(allocator: std.mem.Allocator, mcp_tools: []const exec_pabrikcore.mcp_types.McpTool) void {
    for (mcp_tools) |t| {
        allocator.free(t.name);
        allocator.free(t.description);
    }
    allocator.free(mcp_tools);
}

/// Parse a `tools/list` JSON-RPC response body and splice the resulting
/// `mcp_<server>_<tool>` names into the payload's `"tools":null` slot.
fn appendToolNames(
    ctx: ToolExecContext,
    inner_json: []const u8,
    server_name: []const u8,
    resp: []const u8,
) ![]const u8 {
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
    defer names.deinit(arena.allocator());
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
        const entry = std.fmt.allocPrint(arena.allocator(), "mcp_{s}_{s}", .{ server_name, name }) catch continue;
        names.append(arena.allocator(), entry) catch continue;
    }
    if (names.items.len == 0) return inner_json;
    const names_json = std.json.Stringify.valueAlloc(arena.allocator(), names.items, .{}) catch return inner_json;
    return substituteToolsArray(ctx, inner_json, names_json);
}

/// Replace the payload's `"tools":null` with `"tools":<names_json>`.
/// Returns a freshly-allocated slice on `ctx.allocator`; caller frees.
/// On any failure the original `inner_json` is returned unchanged.
fn substituteToolsArray(
    ctx: ToolExecContext,
    inner_json: []const u8,
    names_json: []const u8,
) ![]const u8 {
    const placeholder = "\"tools\":null";
    const tools_idx = std.mem.indexOf(u8, inner_json, placeholder) orelse return inner_json;
    const replacement = std.fmt.allocPrint(ctx.allocator, "\"tools\":{s}", .{names_json}) catch return inner_json;
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

const testing = std.testing;

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

// ─── add_mcp_server: pure fn ───────────────────────────────────────────

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

    try testing.expect(cfg.hasMcpServer("ctx7"));
    const server = cfg.mcpServerConfig("ctx7").?;
    try testing.expectEqualStrings("npx", server.command.?);
}

test "executeAddMcpServerToJSON: HTTP entry → success payload with url + headers" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx7",
        .transport = "http",
        .url = "https://mcp.context7.com/mcp",
        .headers = &.{
            .{ .name = "Authorization", .value = "Bearer tok" },
        },
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("ctx7", obj.get("name").?.string);
    try testing.expectEqualStrings("http", obj.get("transport").?.string);
    try testing.expectEqualStrings("https://mcp.context7.com/mcp", obj.get("url").?.string);
    try testing.expectEqualStrings("false", obj.get("persisted").?.string);
    try testing.expect(obj.get("tools").? == .null);
    try testing.expect(obj.get("error") == null);

    try testing.expect(cfg.hasMcpServer("ctx7"));
    const server = cfg.mcpServerConfig("ctx7").?;
    try testing.expect(server.isValid());
    try testing.expectEqualStrings("https://mcp.context7.com/mcp", server.url.?);
    try testing.expectEqualStrings("Bearer tok", server.headers.get("Authorization").?);
    try testing.expect(server.command == null);
}

test "executeAddMcpServerToJSON: HTTP entry without headers → empty header map" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "bare",
        .transport = "http",
        .url = "https://x.test/mcp",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("error") == null);
    const server = cfg.mcpServerConfig("bare").?;
    try testing.expectEqual(@as(usize, 0), server.headers.count());
}

test "executeAddMcpServerToJSON: HTTP entry with empty url → error payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "bad",
        .transport = "http",
        .url = "",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "url is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

test "executeAddMcpServerToJSON: unknown transport → error naming both" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "x",
        .transport = "sse",
        .url = "https://x.test/mcp",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "transport must be") != null);
    try testing.expect(std.mem.indexOf(u8, err, "stdio") != null);
    try testing.expect(std.mem.indexOf(u8, err, "http") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

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

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "name is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

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

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "command is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

test "executeAddMcpServerToJSON: duplicate name → error mentioning the existing key" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const first = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "first-cmd",
    });
    defer alloc.free(first);
    const result = try executeAddMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "second-cmd",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "ctx") != null);
    try testing.expect(std.mem.indexOf(u8, err, "already configured") != null);
    const server = cfg.mcpServerConfig("ctx").?;
    try testing.expectEqualStrings("first-cmd", server.command.?);
}

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

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const args = parsed.value.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 0), args.items.len);
}

// ─── edit_mcp_server: pure fn ──────────────────────────────────────────

test "executeEditMcpServerToJSON: stdio command + args patch → success payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "old", .args = &.{"--a"} });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "s",
        .command = "new",
        .args = &.{ "--b", "--c" },
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("s", obj.get("name").?.string);
    try testing.expectEqualStrings("stdio", obj.get("transport").?.string);
    try testing.expectEqualStrings("new", obj.get("command").?.string);
    const args = obj.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("--b", args.items[0].string);
    try testing.expectEqualStrings("--c", args.items[1].string);
    try testing.expect(obj.get("error") == null);

    const server = cfg.mcpServerConfig("s").?;
    try testing.expectEqualStrings("new", server.command.?);
}

test "executeEditMcpServerToJSON: http url + headers patch → success payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerHttp(.{ .name = "h", .url = "https://old.test/mcp" });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "h",
        .url = "https://new.test/mcp",
        .headers = &.{.{ .name = "Authorization", .value = "Bearer tok" }},
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("http", obj.get("transport").?.string);
    try testing.expectEqualStrings("https://new.test/mcp", obj.get("url").?.string);
    const headers = obj.get("headers").?.array;
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expect(std.mem.indexOf(u8, headers.items[0].string, "Authorization") != null);
    try testing.expect(std.mem.indexOf(u8, headers.items[0].string, "Bearer tok") != null);

    const server = cfg.mcpServerConfig("h").?;
    try testing.expectEqualStrings("Bearer tok", server.headers.get("Authorization").?);
}

test "executeEditMcpServerToJSON: omitted fields keep stored values" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "keep", .args = &.{"--keep"} });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "s",
        .enabled = false,
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(!obj.get("enabled").?.bool);
    try testing.expectEqualStrings("keep", obj.get("command").?.string);
    try testing.expectEqualStrings("--keep", obj.get("args").?.array.items[0].string);
}

test "executeEditMcpServerToJSON: stdio to http switch drops the stdio fields" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd", .args = &.{"--a"} });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "s",
        .transport = "http",
        .url = "https://x.test/mcp",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("http", obj.get("transport").?.string);
    try testing.expectEqualStrings("https://x.test/mcp", obj.get("url").?.string);
    try testing.expectEqualStrings("", obj.get("command").?.string);
    try testing.expectEqual(@as(usize, 0), obj.get("args").?.array.items.len);

    const server = cfg.mcpServerConfig("s").?;
    try testing.expect(server.isValid());
    try testing.expect(server.command == null);
}

test "executeEditMcpServerToJSON: unknown server → error naming the key" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "ghost",
        .command = "x",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "ghost") != null);
    try testing.expect(std.mem.indexOf(u8, err, "add_mcp_server") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

test "executeEditMcpServerToJSON: bad transport → error, entry untouched" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd" });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "s",
        .transport = "sse",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "transport must be") != null);
    try testing.expectEqualStrings("cmd", cfg.mcpServerConfig("s").?.command.?);
}

test "executeEditMcpServerToJSON: empty name → error payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "",
        .command = "x",
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "name is required") != null);
}

test "executeEditMcpServerToJSON: empty args slice clears the stored argv" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd", .args = &.{ "--a", "--b" } });

    const result = try executeEditMcpServerToJSON(alloc, testing.io, &cfg, .{
        .name = "s",
        .args = &.{},
    });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("args").?.array.items.len);
    try testing.expect(cfg.mcpServerConfig("s").?.args == null);
}

// ─── delete_mcp_server: pure fn ────────────────────────────────────────

test "executeDeleteMcpServerToJSON: stdio entry → success payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "s", .command = "cmd" });

    const result = try executeDeleteMcpServerToJSON(alloc, testing.io, &cfg, .{ .name = "s" });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("s", obj.get("name").?.string);
    try testing.expect(obj.get("removed").?.bool);
    try testing.expectEqualStrings("false", obj.get("persisted").?.string);
    try testing.expect(obj.get("error") == null);

    try testing.expect(!cfg.hasMcpServer("s"));
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

test "executeDeleteMcpServerToJSON: http entry → success payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerHttp(.{ .name = "h", .url = "https://x.test/mcp" });

    const result = try executeDeleteMcpServerToJSON(alloc, testing.io, &cfg, .{ .name = "h" });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("removed").?.bool);
    try testing.expect(!cfg.hasMcpServer("h"));
}

test "executeDeleteMcpServerToJSON: siblings survive the delete" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();
    try cfg.addMcpServerStdio(.{ .name = "a", .command = "cmd-a" });
    try cfg.addMcpServerHttp(.{ .name = "b", .url = "https://x.test/mcp" });

    const result = try executeDeleteMcpServerToJSON(alloc, testing.io, &cfg, .{ .name = "a" });
    defer alloc.free(result);

    try testing.expect(!cfg.hasMcpServer("a"));
    try testing.expect(cfg.hasMcpServer("b"));
    try testing.expectEqual(@as(usize, 1), cfg.mcp_servers.count());
}

test "executeDeleteMcpServerToJSON: unknown server → error naming the key" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeDeleteMcpServerToJSON(alloc, testing.io, &cfg, .{ .name = "ghost" });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err, "ghost") != null);
    try testing.expect(std.mem.indexOf(u8, err, "nothing to delete") != null);
}

test "executeDeleteMcpServerToJSON: empty name → error payload" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try executeDeleteMcpServerToJSON(alloc, testing.io, &cfg, .{ .name = "" });
    defer alloc.free(result);

    const parsed = try parseTestJson(alloc, result);
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("error").?.string, "name is required") != null);
}

// ─── JSON schema shapes ────────────────────────────────────────────────

test "add_mcp_server_tool JSON schema: name=add_mcp_server, required is name+transport" {
    const tool = add_mcp_server_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("add_mcp_server", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "add_mcp_server") != null);
    try testing.expect(std.mem.indexOf(u8, description, "stdio") != null);
    try testing.expect(std.mem.indexOf(u8, description, "http") != null);

    // Required: name + transport only. `command` / `url` are per-transport
    // and therefore cannot both be required — the transport decides which.
    try testing.expectEqual(@as(usize, 2), tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", tool.function.parameters.required[0]);
    try testing.expectEqualStrings("transport", tool.function.parameters.required[1]);

    // 6 properties: name, transport, command, args, url, headers.
    try testing.expectEqual(@as(usize, 6), tool.function.parameters.properties.len);

    // `headers` is an ARRAY of {name,value} objects (the frontend
    // McpServerModal shape), not the on-disk {key:value} object.
    for (tool.function.parameters.properties) |p| {
        if (std.mem.eql(u8, p.name, "headers")) {
            try testing.expectEqualStrings("array", p.type);
        }
    }
}

test "edit_mcp_server_tool JSON schema: name=edit_mcp_server, required is name only" {
    const tool = edit_mcp_server_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("edit_mcp_server", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "edit_mcp_server") != null);
    try testing.expect(std.mem.indexOf(u8, description, "PATCH") != null);
    try testing.expect(std.mem.indexOf(u8, description, "stdio") != null);
    try testing.expect(std.mem.indexOf(u8, description, "http") != null);

    // Only `name` is required — everything else is a patch.
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", tool.function.parameters.required[0]);

    // 7 properties: name, transport, command, args, url, headers, enabled.
    try testing.expectEqual(@as(usize, 7), tool.function.parameters.properties.len);
}

test "delete_mcp_server_tool JSON schema: name=delete_mcp_server, required is name only" {
    const tool = delete_mcp_server_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("delete_mcp_server", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "delete_mcp_server") != null);
    try testing.expect(std.mem.indexOf(u8, description, "no undo") != null);

    try testing.expectEqual(@as(usize, 1), tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", tool.function.parameters.required[0]);
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.properties.len);
}
