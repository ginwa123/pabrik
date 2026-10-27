const std = @import("std");
const builtin = @import("builtin");
const pabrik_mod = @import("pabrikcore");
const agent = pabrik_mod.agent;
const logger_mod = pabrik_mod.loggermod;
const sqlite = pabrik_mod.sqlite;
const database = pabrik_mod.database;
const save_message = @import("llm_history.zig");
const custom_http_client = @import("kabelweb").client;
const config_mod = pabrik_mod.config;
const mcp_stdio = pabrik_mod.mcp_stdio;
const mcp_http = pabrik_mod.mcp_http;
const is_worker_cancelled_mod = @import("is_worker_cancelled.zig");

/// Session identity that owns a `tools/call`, so the Stop button can reach
/// the lease wait and the transport reads/writes.
pub const CancelSession = struct {
    db: *database.Db,
    session_id: []const u8,
    io: std.Io,
};

/// Same order of magnitude as one `tools/call` budget (`:86`): a waiter never
/// waits longer than the holder's own worst case, and every wait is finite.
pub const DEFAULT_LEASE_WAIT_NS: u64 = 60 * std.time.ns_per_s;

/// Injectable knobs, both defaulted to production behaviour. They are
/// parameters rather than constants so a test can drive the busy and cancelled
/// paths without a 60 s wall-clock wait.
pub const CallOptions = struct {
    /// How long to wait for another session's in-flight call on the SAME stdio
    /// server before reporting the server busy. Never pass 0 — that is the
    /// `AcquireOptions` sentinel for "wait forever".
    lease_wait_ns: u64 = DEFAULT_LEASE_WAIT_NS,
    /// The session whose Stop button must break this call. Null = no hook
    /// (tests, and callers with no session).
    cancel_session: ?CancelSession = null,
};

/// `AcquireOptions.is_cancelled`/`recv` take a bare `fn () bool`, so the session
/// rides on a threadlocal — the shape `workflow.zig` uses for `llm_cancel_thunk`.
/// The hook is throttled (50 ms, latched) because every wait polls it.
const session_cancel = struct {
    const POLL_INTERVAL_NS: i96 = 50 * std.time.ns_per_ms;

    threadlocal var state: ?CancelSession = null;
    threadlocal var last_poll_ns: i96 = 0;
    threadlocal var latched: bool = false;

    fn call() bool {
        if (latched) return true;
        const s = state orelse return false;

        const now_ns = std.Io.Clock.now(.real, s.io).nanoseconds;
        if (last_poll_ns != 0 and now_ns - last_poll_ns < POLL_INTERVAL_NS) return false;
        last_poll_ns = now_ns;

        const cancelled = is_worker_cancelled_mod.isWorkerCancelled(.{
            .allocator = std.heap.page_allocator,
            .db = s.db,
            .session_id = s.session_id,
        });
        if (cancelled) latched = true;
        return cancelled;
    }

    fn register(s: CancelSession) void {
        state = s;
        last_poll_ns = 0;
        latched = false;
    }

    fn unregister() void {
        state = null;
        last_poll_ns = 0;
        latched = false;
    }
};

/// Handle an MCP tool call by forwarding it to the MCP server IMPORTANT: This
/// function allocates directly from parent_allocator to avoid nested arena
/// issues that can cause @memcpy aliasing errors.
pub fn handle_mcp_tool_run(
    parent_allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    tool_call: agent.ToolCall,
    config: *const config_mod.LlmConfig,
    opts: CallOptions,
) ![]const u8 {
    // Register BEFORE the first `acquire`: the lease wait and every transport
    // read/write below reach the hook through `call`.
    if (opts.cancel_session) |s| session_cancel.register(s);
    defer if (opts.cancel_session != null) session_cancel.unregister();
    // Use parent_allocator directly to avoid nested arena memory issues
    const allocator = parent_allocator;

    // Debug: log the tool call ID we received
    logger.infoFmt("[MCP] Tool call START - name: '{s}', id: '{s}'", .{ tool_call.function.name, tool_call.id });

    // Parse tool name: format is "mcp_serverName_toolName"
    // First, verify it starts with "mcp_"
    if (!std.mem.startsWith(u8, tool_call.function.name, "mcp_")) {
        logger.warnFmt("[MCP] Tool name does not start with 'mcp_': {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    }

    // Find the second underscore (after "mcp_")
    const after_mcp = tool_call.function.name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse {
        logger.warnFmt("[MCP] No underscore after server name in tool: {s}", .{tool_call.function.name});
        return error.InvalidMCPToolName;
    };

    const server_name = after_mcp[0..underscore_idx];
    const actual_tool_name = after_mcp[underscore_idx + 1 ..];

    logger.infoFmt("[MCP] Parsed - server: '{s}', tool: '{s}'", .{ server_name, actual_tool_name });

    // Get MCP server config
    if (config.mcpServers() == null) {
        logger.warnFmt("[MCP] No MCP servers configured", .{});
        return error.NoMCPServers;
    }

    const mcp_servers = switch (config.mcpServers().?) {
        .object => |obj| obj,
        else => {
            return error.InvalidMCPServersConfig;
        },
    };

    const server_config = mcp_servers.get(server_name) orelse {
        return error.MCPServerNotFound;
    };

    const server_obj = switch (server_config) {
        .object => |obj| obj,
        else => {
            return error.InvalidMCPServerConfig;
        },
    };

    // MCP server toggle: reject calls to explicitly-disabled servers AFTER
    // config lookup but BEFORE any spawn/connect.
    if (server_obj.get("enabled")) |enabled_val| {
        if (enabled_val == .bool and !enabled_val.bool) {
            logger.warnFmt("[MCP] Server '{s}' is disabled", .{server_name});
            return error.MCPServerDisabled;
        }
    }

    // Transport dispatch: stdio (command) or HTTP (url). stdio takes
    // precedence when both are present (the parser already rejects that
    // combo, but the runtime is defensive).
    if (server_obj.get("command")) |_| {
        // 60s default per-call budget for tools/call (vs 30s for tools/list —
        // mid-loop tool calls can legitimately take longer because the work
        // itself is unbounded).
        const deadline_ns: u64 = 60 * std.time.ns_per_s;
        return callViaStdio(allocator, logger, server_name, actual_tool_name, tool_call.function.arguments, server_obj, deadline_ns, opts);
    }

    const url_value = server_obj.get("url") orelse {
        return error.MCPServerURLNotFound;
    };
    const url = url_value.string;

    logger.debugFmt("MCP HTTP dispatch to {s}", .{url});

    // Build the custom_headers slice from the JSON object. MCP headers
    // are a small bounded set; we use a stack buffer (max 16) to avoid
    // a heap allocation on the hot path.
    var std_header_buf: [16]custom_http_client.Header = undefined;
    var header_count: usize = 0;
    if (server_obj.get("headers")) |headers_value| {
        const headers_obj = switch (headers_value) {
            .object => |obj| obj,
            else => {
                return error.InvalidMCPServerHeadersConfig;
            },
        };
        var header_iter = headers_obj.iterator();
        while (header_iter.next()) |h_entry| {
            if (header_count >= std_header_buf.len) return error.InvalidMCPServerHeadersConfig;
            const value = switch (h_entry.value_ptr.*) {
                .string => |s| s,
                else => continue,
            };
            std_header_buf[header_count] = .{
                .name = h_entry.key_ptr.*,
                .value = value,
            };
            header_count += 1;
        }
    }
    const custom_headers = std_header_buf[0..header_count];

    // Get or build a cached HTTP client for this server. The process- global
    // registry keeps the client alive for the process lifetime (the arena
    // memory is freed at process exit).
    const http_registry = pabrik_mod.mcpHttpRegistry(allocator);
    const http_client = http_registry.getOrConnect(
        server_name,
        url,
        custom_headers,
    ) catch |err| {
        logger.errFmt("MCP HTTP client build failed: {s}", .{@errorName(err)});
        return error.FailedToCallMCPServer;
    };

    // Send the request. callTool returns the raw JSON-RPC response body
    // (the SSE parser inside the client has already extracted the final
    // event's data: field if the server returned SSE).
    const response_body = http_client.callTool(actual_tool_name, tool_call.function.arguments) catch |err| {
        logger.errFmt("MCP HTTP call failed: {s}", .{@errorName(err)});
        return error.FailedToCallMCPServer;
    };
    defer allocator.free(response_body);

    // Extract `result.content[0].text` (this function's contract: the
    // agent sees the text content, not the raw JSON-RPC envelope).
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), response_body, .{}) catch {
        logger.errFmt("MCP HTTP response not valid JSON: len={d}", .{response_body.len});
        return error.MCPJSONParseError;
    };

    if (parsed.value.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            // Most common shape: {content: [{type: "text", text: "..."}]}
            if (content_val == .array) {
                if (content_val.array.items.len > 0) {
                    if (content_val.array.items[0].object.get("text")) |text_val| {
                        if (text_val == .string) {
                            return try allocator.dupe(u8, text_val.string);
                        }
                    }
                }
            }
            // Fallback shape: {content: "string"}
            if (content_val == .string) {
                return try allocator.dupe(u8, content_val.string);
            }
        }
    }

    // No content extractable — return the raw response body (caller
    // may want to inspect the JSON-RPC error envelope if any).
    return try allocator.dupe(u8, response_body);
}

// ============================================================================
// stdio transport: spawn a child process per server, send framed JSON-RPC
// over its stdin, read the framed response from stdout.

/// Call a tool via the stdio transport. Spawns (or reuses) a child process
/// keyed by `server_name`, sends a framed `tools/call` JSON-RPC body, and
/// reads the framed response.
fn callViaStdio(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    server_name: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    server_obj: std.json.ObjectMap,
    deadline_ns: u64,
    opts: CallOptions,
) ![]const u8 {
    // `handle_mcp_tool_run` has already registered the session (if any), so
    // this is the live hook every wait below shares.
    const cancel_fn: ?*const fn () bool =
        if (opts.cancel_session != null) &session_cancel.call else null;
    // Build argv: [command, args...]
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    if (server_obj.get("command")) |cmd_field| {
        if (cmd_field == .string and cmd_field.string.len > 0) {
            try argv_list.append(allocator, try allocator.dupe(u8, cmd_field.string));
        }
    }
    if (server_obj.get("args")) |args_v| {
        if (args_v == .array) {
            for (args_v.array.items) |item| {
                if (item == .string) {
                    try argv_list.append(allocator, try allocator.dupe(u8, item.string));
                }
            }
        }
    }
    if (argv_list.items.len == 0) {
        logger.errFmt("stdio MCP server '{s}' has no command", .{server_name});
        return error.MCPServerCommandNotFound;
    }
    const argv = try argv_list.toOwnedSlice(allocator);
    defer {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    // stdio transport: long-lived child per server, lazy spawn + respawn.
    // Via the singleton struct (see root.zig `mcpStdioRegistry`).
    const reg = pabrik_mod.mcpStdioRegistry(allocator);

    // Retry loop for cold-start / stale child. Use NDJSON framing (like
    // the discovery path) — Python and Node SDKs both default to NDJSON.
    var last_err: anyerror = error.FailedToCallMCPServer;
    var attempt: u8 = 0;
    var resp: []u8 = undefined;
    var resp_owned = false;
    // `resp` is allocated from the client's arena, which dies with the child
    // — so the lease that guards it has to outlive the retry loop (the parse
    // below runs after it).
    var held: ?mcp_stdio.Lease = null;
    defer {
        if (held) |*h| h.release();
    }
    while (attempt < 3) : (attempt += 1) {
        // Bounded + cancellable lease wait: `AcquireOptions{}` means
        // `wait_ns = 0` = wait forever, parking a neighbour session with no
        // deadline and no way for Stop to reach it.
        var lease = reg.acquire(server_name, argv, .{
            .wait_ns = opts.lease_wait_ns,
            .is_cancelled = cancel_fn,
        }) catch |err| {
            logger.errFmt("stdio MCP lease failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            // Busy is contention, not a broken child: retrying would stack the
            // wait budget and pin this session (and its neighbours) three times
            // as long. Report it and let the model decide.
            if (err == error.LeaseTimeout) return error.MCPServerBusy;
            if (attempt + 1 < 3) {
                continue;
            }
            return error.FailedToCallMCPServer;
        };
        defer {
            if (held == null) lease.release();
        }
        const client = lease.client();

        const req = try buildToolCallRequestBody(allocator, tool_name, arguments_json);
        defer allocator.free(req);

        // Send as NDJSON (JSON + '\n'), not Content-Length. The send shares the
        // call's budget and the cancel hook: a child that stopped draining its
        // stdin must not hold this lease (and every waiter behind it) open.
        client.sendNDJSON(req, deadline_ns, cancel_fn) catch |err| {
            logger.errFmt("stdio MCP send failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            if (err == error.SendTimeout or err == error.BrokenPipe) lease.markStale();
            const is_retryable = err == error.BrokenPipe or err == error.SendTimeout;
            if (is_retryable and attempt + 1 < 3) {
                continue;
            }
            return error.FailedToCallMCPServer;
        };
        const r = client.recv(deadline_ns, cancel_fn) catch |err| {
            logger.errFmt("stdio MCP recv failed for {s}.{s}: {s}", .{ server_name, tool_name, @errorName(err) });
            last_err = err;
            if (err == error.RecvTimeout) lease.markStale();
            const is_retryable = err == error.RecvTimeout or err == error.UnexpectedEof or err == error.BrokenPipe;
            if (is_retryable and attempt + 1 < 3) {
                continue;
            }
            return error.MCPServerReturnedError;
        };
        resp = r;
        resp_owned = true;
        held = lease;
        break;
    }
    if (!resp_owned) return last_err;
    // NOTE: no errdefer free of `resp` here — it is owned by the client's own
    // arena (client.allocator()), never transferred to the caller (every
    // return below dupes into `allocator`), so that arena reclaims it.

    // Same JSON extraction as the HTTP branch: pull `result.content[0].text`.
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), resp, .{}) catch {
        return error.MCPJSONParseError;
    };
    const root = parsed.value;
    var tool_result: []const u8 = resp;
    var needs_copy = false;
    if (root.object.get("result")) |result_val| {
        if (result_val.object.get("content")) |content_val| {
            if (content_val == .array) {
                const arr = content_val.array;
                if (arr.items.len > 0) {
                    if (arr.items[0].object.get("text")) |text_val| {
                        if (text_val == .string) {
                            tool_result = try allocator.dupe(u8, text_val.string);
                            needs_copy = true;
                        }
                    }
                }
            }
        }
    }
    if (!needs_copy) tool_result = try allocator.dupe(u8, resp);
    // Large payload guard: truncate tool results over 100KB to avoid
    // downstream SEGV / OOM / LLM context overflow. The 120KB graph
    // data that crashed the backend is a real example.
    const MAX_TOOL_RESULT_BYTES: usize = 100 * 1024;
    if (tool_result.len > MAX_TOOL_RESULT_BYTES) {
        logger.warnFmt("MCP tool result too large: {} bytes, truncating to {} bytes", .{ tool_result.len, MAX_TOOL_RESULT_BYTES });
        const truncated = try std.fmt.allocPrint(allocator, "{s}\n\n[truncated: original was {} bytes, showing first {} bytes]", .{ tool_result[0..MAX_TOOL_RESULT_BYTES], tool_result.len, MAX_TOOL_RESULT_BYTES });
        allocator.free(tool_result);
        // resp is arena-allocated (per-iteration arena in workflow.zig), so
        // it will be freed at iteration end — no need to free here. But if
        // this is called outside workflow (e.g.
        return truncated;
    }
    return tool_result;
}

// ============================================================================
// Shared request-body builder (used by both HTTP and stdio transports)
// ============================================================================

/// Build a JSON-RPC `tools/call` request body for a given tool name + args.
/// Returns a freshly-allocated slice the caller owns (frees with allocator).
/// This is the SHAPE the agent sends over the wire — same for HTTP and stdio.
pub fn buildToolCallRequestBody(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    ,
        .{ tool_name, arguments_json },
    );
}

// ============================================================================
// Tests (inline at the bottom — project convention)
// ============================================================================

const testing = std.testing;

test "buildToolCallRequestBody: emits jsonrpc tools/call envelope" {
    // Note: arguments_json is passed through verbatim — the test uses
    // a compact JSON to make the substring match predictable.
    const body = try buildToolCallRequestBody(testing.allocator, "say_hello",
        \\{"name":"world"}
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"say_hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":{\"name\":\"world\"}") != null);
}

test "buildToolCallRequestBody: empty arguments is a valid empty object" {
    const body = try buildToolCallRequestBody(testing.allocator, "ping", "{}");
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":{}") != null);
}

test "handle_mcp_tool_run: disabled server returns MCPServerDisabled (no spawn)" {
    // MCP server toggle: an explicit `"enabled": false` entry must be
    // rejected AFTER config lookup but BEFORE any spawn/connect — the same
    // shape as the existing unknown-server error path (a Zig error the caller
    const json_text =
        \\{"off": {"command": "/no/such/binary/should/exist/xyzzy", "args": [], "enabled": false}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_text, .{});
    defer parsed.deinit();
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var logger = logger_mod.Logger.init(testing.allocator, io, .{
        .min_level = .err,
        .include_location = false,
        .include_request_id = false,
        .include_timestamp = false,
    });
    defer logger.deinit();
    var cfg = config_mod.LlmConfig{
        .allocator = testing.allocator,
        .api_key = "",
        .model = "",
        .base_url = "",
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = parsed,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(testing.allocator),
        .agents = config_mod.LlmConfig.AgentsMap.init(testing.allocator),
        .url_style = "openai",
    };
    // NOTE: no cfg.deinit — the string fields borrow static literals and
    // both maps are empty (no allocations to release); parsed.deinit()
    // above frees the JSON tree.
    const tool_call = agent.ToolCall{
        .id = "t1",
        .function = .{ .name = "mcp_off_ping", .arguments = "{}" },
    };
    // No-op when the gate above holds (no spawn attempted); cleans up the
    // global registry if a regression ever lets a spawn through.
    defer mcp_stdio.StdioRegistry.deinitGlobal();
    const err = handle_mcp_tool_run(testing.allocator, &logger, tool_call, &cfg, .{});
    try testing.expectError(error.MCPServerDisabled, err);
}

// ── Lease-wait behaviour: one stdio child per server per process, so a call
// must never wait on it unboundedly and Stop has to reach that wait. These
// tests drive the real `handle_mcp_tool_run` against local children.

/// A child that never reads its stdin and stays alive long enough to hold a
/// lease. Host table on purpose (CODING_STANDARDS.md §2): the tests below run
/// on every platform, and a host the table does not name fails the spawn.
fn neverReadingArgv() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/C", "ping", "-n", "30", "127.0.0.1" },
        .linux, .macos => &.{ "sleep", "30" },
        else => &.{},
    };
}

/// The same child as a config entry — `mcp_<server>_<tool>` splits on the first
/// underscore, so server names carry none.
fn neverReadingServerJson() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "{\"command\": \"cmd.exe\", \"args\": [\"/C\", \"ping\", \"-n\", \"30\", \"127.0.0.1\"]}",
        .linux, .macos => "{\"command\": \"sleep\", \"args\": [\"30\"]}",
        else => "{\"command\": \"pabrik-no-such-child\", \"args\": []}",
    };
}

/// A child that echoes what it reads (`cat` / `more`), so a round-trip is
/// observable. Same host table, same rule.
fn echoServerJson() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "{\"command\": \"cmd.exe\", \"args\": [\"/C\", \"more\"]}",
        .linux, .macos => "{\"command\": \"cat\", \"args\": []}",
        else => "{\"command\": \"pabrik-no-such-child\", \"args\": []}",
    };
}

/// One stdio MCP server entry + everything `handle_mcp_tool_run` needs, wired
/// to a real local child and to a log file the tests read to count lease
/// attempts (`.err` is the only level it keeps).
const StdioCallFixture = struct {
    /// Heap-allocated on purpose: `std.Io.Threaded.io()` stores
    /// `userdata = &threaded`, so holding the Threaded BY VALUE here would
    /// leave `io` pointing at `init`'s dead frame — UB that hangs on Windows.
    threaded: *std.Io.Threaded,
    logger: logger_mod.Logger,
    servers: std.json.Parsed(std.json.Value),
    cfg: config_mod.LlmConfig,
    io: std.Io,
    log_path: []const u8,

    fn init(server_name: []const u8, server_json: []const u8, log_path: []const u8) !StdioCallFixture {
        const allocator = testing.allocator;
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();

        const owned_log_path = try allocator.dupe(u8, log_path);
        errdefer allocator.free(owned_log_path);
        std.Io.Dir.cwd().deleteFile(io, owned_log_path) catch {};

        var logger = logger_mod.Logger.init(allocator, io, .{
            .min_level = .err,
            .include_location = false,
            .include_request_id = false,
            .include_timestamp = false,
            .output_mode = .file,
            .log_file_path = owned_log_path,
        });
        errdefer logger.deinit();

        const json_text = try std.fmt.allocPrint(allocator, "{{\"{s}\": {s}}}", .{ server_name, server_json });
        defer allocator.free(json_text);
        var servers = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        errdefer servers.deinit();

        return .{
            .threaded = threaded,
            .logger = logger,
            .servers = servers,
            .io = io,
            .log_path = owned_log_path,
            // No cfg.deinit: the string fields borrow static literals and both
            // maps stay empty, so `servers.deinit()` is the whole teardown.
            .cfg = .{
                .allocator = allocator,
                .api_key = "",
                .model = "",
                .base_url = "",
                .model_compaction_size_kb = 100,
                .mcpServers_parsed = servers,
                .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
                .agents = config_mod.LlmConfig.AgentsMap.init(allocator),
                .url_style = "openai",
            },
        };
    }

    /// Error lines the call logged — one per lease-acquire attempt, so this is
    /// the retry count. The only platform-independent way to assert it:
    /// wall-clock cannot tell one attempt from three on a coarse-timer host.
    fn leaseAttempts(self: *StdioCallFixture) usize {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.log_path, testing.allocator, .limited(1 << 20)) catch return 0;
        defer testing.allocator.free(bytes);
        return std.mem.count(u8, bytes, "\n");
    }

    /// Call `mcp_<server>_<tool>` through the real entry point.
    fn call(self: *StdioCallFixture, tool_name: []const u8, opts: CallOptions) anyerror![]const u8 {
        const tool_call = agent.ToolCall{
            .id = "tc_lease",
            .function = .{ .name = tool_name, .arguments = "{}" },
        };
        return handle_mcp_tool_run(testing.allocator, &self.logger, tool_call, &self.cfg, opts);
    }

    fn deinit(self: *StdioCallFixture) void {
        // Kills the child this fixture spawned via the process-global registry.
        mcp_stdio.StdioRegistry.deinitGlobal();
        self.logger.deinit();
        std.Io.Dir.cwd().deleteFile(self.io, self.log_path) catch {};
        testing.allocator.free(self.log_path);
        self.threaded.deinit();
        testing.allocator.destroy(self.threaded);
        self.servers.deinit();
    }
};

fn elapsedMsSince(io: std.Io, start_ns: i128) u64 {
    return @intCast(@divTrunc(
        std.Io.Timestamp.now(io, .real).nanoseconds - start_ns,
        std.time.ns_per_ms,
    ));
}

test "handle_mcp_tool_run: a server another session holds reports MCPServerBusy within ONE lease budget" {
    var fx = try StdioCallFixture.init("busysrv", neverReadingServerJson(), "./test_mcp_lease_busy.log");
    defer fx.deinit();

    // Arrange: another session is mid-transaction on this server.
    const reg = pabrik_mod.mcpStdioRegistry(testing.allocator);
    var held = try reg.acquire("busysrv", neverReadingArgv(), .{});
    defer held.release();

    const start = std.Io.Timestamp.now(fx.io, .real).nanoseconds;
    const result = fx.call("mcp_busysrv_ping", .{ .lease_wait_ns = 200 * std.time.ns_per_ms });
    const elapsed_ms = elapsedMsSince(fx.io, start);

    try testing.expect(result == error.MCPServerBusy);
    // ONE acquire attempt, not three: a busy lease is contention, not a broken
    // child, so the retry loop must not stack the wait. Counted from the log,
    // because a 200ms budget measures >1s under macOS/CI timer granularity.
    try testing.expectEqual(@as(usize, 1), fx.leaseAttempts());
    // The budget was waited out rather than failed instantly…
    try testing.expect(elapsed_ms >= 150);
    // …and this is a hang guard, not a budget check (see above). Pre-fix the
    // caller never returned at all.
    try testing.expect(elapsed_ms < 30_000);
}

test "handle_mcp_tool_run: a cancelled session stops waiting for a busy stdio server" {
    var fx = try StdioCallFixture.init("cancsrv", neverReadingServerJson(), "./test_mcp_lease_cancelled.log");
    defer fx.deinit();

    // The Stop button's state, read from where the loop writes it: the worker row.
    var db: database.Db = .{};
    defer db.deinit();
    try db.init(fx.io, ":memory:");
    try db.exec(testing.allocator, "CREATE TABLE worker (id TEXT PRIMARY KEY, cancelled INTEGER DEFAULT 0)", &.{});
    try db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('sess_cancelled', 1)", &.{});

    const reg = pabrik_mod.mcpStdioRegistry(testing.allocator);
    var held = try reg.acquire("cancsrv", neverReadingArgv(), .{});
    defer held.release();

    const start = std.Io.Timestamp.now(fx.io, .real).nanoseconds;
    const result = fx.call("mcp_cancsrv_ping", .{
        // A budget far beyond this test: only the cancel may end the wait.
        .lease_wait_ns = 60 * std.time.ns_per_s,
        .cancel_session = .{ .db = &db, .session_id = "sess_cancelled", .io = fx.io },
    });
    const elapsed_ms = elapsedMsSince(fx.io, start);

    try testing.expect(result == error.MCPServerBusy);
    try testing.expectEqual(@as(usize, 1), fx.leaseAttempts());
    try testing.expect(elapsed_ms < 2000);
}

test "handle_mcp_tool_run: a session that is NOT cancelled still waits out the busy server" {
    // The other half of the contract: the cancel hook fires on the row's VALUE,
    // not on its mere presence — otherwise every MCP call would abort the
    // moment its session row existed.
    var fx = try StdioCallFixture.init("livewsrv", neverReadingServerJson(), "./test_mcp_lease_uncancelled.log");
    defer fx.deinit();

    var db: database.Db = .{};
    defer db.deinit();
    try db.init(fx.io, ":memory:");
    try db.exec(testing.allocator, "CREATE TABLE worker (id TEXT PRIMARY KEY, cancelled INTEGER DEFAULT 0)", &.{});
    try db.exec(testing.allocator, "INSERT INTO worker (id, cancelled) VALUES ('sess_live', 0)", &.{});

    const reg = pabrik_mod.mcpStdioRegistry(testing.allocator);
    var held = try reg.acquire("livewsrv", neverReadingArgv(), .{});
    defer held.release();

    const start = std.Io.Timestamp.now(fx.io, .real).nanoseconds;
    const result = fx.call("mcp_livewsrv_ping", .{
        .lease_wait_ns = 400 * std.time.ns_per_ms,
        .cancel_session = .{ .db = &db, .session_id = "sess_live", .io = fx.io },
    });
    const elapsed_ms = elapsedMsSince(fx.io, start);

    try testing.expect(result == error.MCPServerBusy);
    try testing.expectEqual(@as(usize, 1), fx.leaseAttempts());
    // Waited the budget, then reported busy — it did not abort early.
    try testing.expect(elapsed_ms >= 350);
    try testing.expect(elapsed_ms < 30_000); // hang guard, see the busy test
}

test "handle_mcp_tool_run: an unheld stdio server answers the call" {
    // Happy path through the new bounded send: an unheld server must still
    // round-trip the request and hand the child's body back as the tool output.
    var fx = try StdioCallFixture.init("idlesrv", echoServerJson(), "./test_mcp_lease_unheld.log");
    defer fx.deinit();

    const result = try fx.call("mcp_idlesrv_ping", .{});
    defer testing.allocator.free(result);

    // The echo child returns the JSON-RPC request, which carries no
    // `result.content[0].text`, so the raw body is what the model receives.
    try testing.expect(std.mem.indexOf(u8, result, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"ping\"") != null);
}
