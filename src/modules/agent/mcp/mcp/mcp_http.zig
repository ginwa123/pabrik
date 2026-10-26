//! MCP Streamable HTTP transport for the agent AI (Zig client). This file
//! contains everything HTTP-specific for the agent's MCP client, mirroring
//! the stdio transport's `mcp_stdio.zig`: 1.

const std = @import("std");
const mcp_scope = @import("mcp_scope.zig");
const builtin = @import("builtin");
const mcp_types = @import("mcp_types.zig");
const custom_http_client_mod = @import("kabelweb").client;

// ============================================================================
// SECTION A — MCP spec constants (pub so the registry in Section D can read)
// ============================================================================

/// Current Streamable HTTP protocol revision we implement.
pub const PROTOCOL_VERSION: []const u8 = "2025-11-25";

/// Spec-mandated Accept header value (comma-separated, no spaces).
/// Every request must include this so the server knows we handle BOTH
/// `application/json` and `text/event-stream` responses.
pub const ACCEPT_HEADER: []const u8 = "application/json, text/event-stream";

pub const HttpError = error{
    InvalidSseEvent,           // no `data:` field on an event we expected to carry a JSON-RPC message
    ServerHeaderMismatch,      // 400 with HeaderMismatch error
    UnsupportedProtocolVersion, // 400 with UnsupportedProtocolVersionError
    ServerMethodNotFound,      // 404 (distinct from a legacy 404)
    ServerReturnedError,       // other 4xx/5xx
    InvalidJson,               // response body wasn't valid JSON-RPC
};

// ============================================================================
// SECTION B — SSE event parser (private to this file)
// ============================================================================

/// One parsed SSE event. All fields are freshly allocated slices owned by the
/// caller (free with `allocator.free`).
pub const SseEvent = struct {
    event: []const u8 = "",
    data: []const u8 = "",
    id: []const u8 = "",
    retry_ms: ?u64 = null,
};

/// Read one SSE event from a line-buffered reader. Returns null on EOF (clean
/// stream end).
fn readSseEvent(allocator: std.mem.Allocator, reader: anytype) !?SseEvent {
    // Per-event accumulators. Reset on every event boundary (blank line). On
    // EOF, if we have any partial event (a `data:` line in flight), we flush
    // it; otherwise we return null to signal clean stream end.
    var event_buf = std.ArrayList(u8).empty;
    var id_buf = std.ArrayList(u8).empty;
    var data_buf = std.ArrayList(u8).empty;
    var retry_ms: ?u64 = null;
    var saw_data = false;
    var in_event = false;
    defer {
        event_buf.deinit(allocator);
        id_buf.deinit(allocator);
        data_buf.deinit(allocator);
    }

    while (true) {
        const line_opt = try reader.next();
        const line = line_opt orelse {
            // EOF: flush if we have a partial event, else return null.
            break;
        };

        if (line.len == 0) {
            // Blank line: event boundary. If we were in an event, dispatch.
            if (in_event) {
                if (saw_data) {
                    return SseEvent{
                        .event = try event_buf.toOwnedSlice(allocator),
                        .data = try data_buf.toOwnedSlice(allocator),
                        .id = try id_buf.toOwnedSlice(allocator),
                        .retry_ms = retry_ms,
                    };
                }
                // No data: this was a comment-only event. Per SSE spec,
                // clients should still process id/retry but we don't
                // have anything to return. Continue.
                event_buf.clearRetainingCapacity();
                id_buf.clearRetainingCapacity();
                data_buf.clearRetainingCapacity();
                retry_ms = null;
                in_event = false;
            }
            continue;
        }

        // Comment line (SSE spec: ":..." is a comment, ignore).
        if (line[0] == ':') continue;

        in_event = true;

        // Dispatch on the first colon. Field names are case-insensitive
        // per the SSE spec — use std.ascii.startsWithIgnoreCase.
        if (std.ascii.startsWithIgnoreCase(line, "data:")) {
            saw_data = true;
            // Per SSE spec, the value is everything after the first
            // colon minus a single leading space (if present).
            var value = line["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (data_buf.items.len > 0) try data_buf.append(allocator, '\n');
            try data_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "event:")) {
            var value = line["event:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            event_buf.clearRetainingCapacity();
            try event_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "id:")) {
            var value = line["id:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            id_buf.clearRetainingCapacity();
            try id_buf.appendSlice(allocator, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "retry:")) {
            var value = line["retry:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            retry_ms = std.fmt.parseInt(u64, value, 10) catch null;
        }
        // Unknown field: ignore (per SSE spec).
    }

    // EOF reached. Flush any partial event.
    if (in_event and saw_data) {
        return SseEvent{
            .event = try event_buf.toOwnedSlice(allocator),
            .data = try data_buf.toOwnedSlice(allocator),
            .id = try id_buf.toOwnedSlice(allocator),
            .retry_ms = retry_ms,
        };
    }
    return null;
}

// ============================================================================
// SECTION C — MCP request-header builder (private to this file)
// ============================================================================

/// Returns true iff every byte of `s` is in the ASCII range (0..127).
fn isAllAscii(s: []const u8) bool {
    for (s) |c| {
        if (c > 127) return false;
    }
    return true;
}

/// Build the request headers for an MCP Streamable HTTP POST. `tool_name` is
/// only used for `tools/call` — pass "" for methods that don't take a name
/// (initialize, ping, tools/list, etc.).
fn buildMcpHeaders(
    allocator: std.mem.Allocator,
    method: []const u8,
    tool_name: []const u8,
    custom_headers: []const custom_http_client_mod.Header,
) ![]custom_http_client_mod.Header {
    // 4 spec headers always present. We MAY add a 5th (Mcp-Name) if tool_name
    // is non-empty AND ASCII.
    const include_name = tool_name.len > 0 and isAllAscii(tool_name);
    const spec_count: usize = if (include_name) 5 else 4;
    const total = spec_count + custom_headers.len;

    const out = try allocator.alloc(custom_http_client_mod.Header, total);
    errdefer allocator.free(out);

    // Spec headers (FIRST in the slice).
    out[0] = .{ .name = "Accept", .value = ACCEPT_HEADER };
    out[1] = .{ .name = "Content-Type", .value = "application/json" };
    out[2] = .{ .name = "MCP-Protocol-Version", .value = PROTOCOL_VERSION };
    out[3] = .{ .name = "Mcp-Method", .value = method };
    if (include_name) {
        out[4] = .{ .name = "Mcp-Name", .value = tool_name };
    }

    // User-supplied custom headers (LAST in the slice, after the spec ones).
    // Note we don't dedupe — libcurl's first-match-wins handles duplicates.
    // The spec headers above will always be the values the server sees.
    for (custom_headers, 0..) |h, i| {
        out[spec_count + i] = h;
    }

    return out;
}

// ============================================================================
// SECTION D — HttpClient + HttpRegistry (arrives in Task 3)
// ============================================================================

/// One MCP Streamable HTTP client. Owns the base URL, the cached custom
/// headers, and a `custom_http_client.Client` for connection pooling.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    custom_headers: []const custom_http_client_mod.Header,
    /// Lazily-initialised on first callTool/listTools. Owned by the
    /// client; freed by deinit. NOT thread-safe; the HttpRegistry
    /// provides the mutex.
    http: custom_http_client_mod.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, url: []const u8, custom_headers: []const custom_http_client_mod.Header) !Self {
        return .{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
            .custom_headers = custom_headers, // borrowed — caller owns the underlying strings
            .http = custom_http_client_mod.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.url);
    }

    /// Send a `tools/call` JSON-RPC request and return the raw JSON-RPC
    /// response body (freshly allocated; caller owns).
    pub fn callTool(self: *Self, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        // Minimal JSON-RPC body (NO `_meta` envelope): servers on protocol
        // revision 2026-07-28 (e.g. context7) return `400 Invalid _meta
        // envelope ... clientCapabilities: missing` for a 2025-11-25-shaped
        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
        , .{ tool_name, arguments_json });
        defer self.allocator.free(body);

        // Build the spec-mandated headers + per-method Mcp-Name, merged
        // with the user's custom_headers (spec headers win).
        const headers = try buildMcpHeaders(self.allocator, "tools/call", tool_name, self.custom_headers);
        defer self.allocator.free(headers);

        // POST. custom_http_client returns a fully-buffered Response.
        const result = custom_http_client_mod.post(
            &self.http,
            self.url,
            body,
            headers,
            .{ .timeout_ms = 30_000 },
        ) catch return HttpError.ServerReturnedError;
        defer result.deinit(self.allocator);

        return switch (result.status_code) {
            200 => parseResponseBody(self.allocator, result.body),
            400 => error.ServerReturnedError, // simplified — real impl inspects error code
            404 => error.ServerMethodNotFound,
            else => error.ServerReturnedError,
        };
    }

    /// Internal: dispatch on Content-Type to extract the final JSON-RPC body
    /// from a 200 response. Both `application/json` (single object) and
    /// `text/event-stream` (SSE stream — last event's data) are supported.
    fn parseResponseBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
        // Heuristic: SSE bodies start with "event:" or "data:". JSON bodies
        // start with "{".
        const trimmed = std.mem.trim(u8, body, " \r\n");
        if (std.mem.startsWith(u8, trimmed, "event:") or std.mem.startsWith(u8, trimmed, "data:")) {
            // SSE: walk events, take the last one with a data: field.
            return parseLastSseData(allocator, body);
        }
        // Otherwise assume JSON — dup the body verbatim.
        return allocator.dupe(u8, body);
    }
};

/// Walk an SSE response body and return the data of the LAST event
/// that has at least one `data:` line. Multi-`data:` lines are joined
/// with `\n` per the SSE spec.
fn parseLastSseData(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    // NOTE: `data_lines` is per-event scratch freed at the end of each
    // iteration, so `last_data` must NOT point into it (use-after-free: the
    // final `dupe` can reuse the freed address and trip `@memcpy arguments
    var last_owned: ?[]u8 = null;
    defer if (last_owned) |b| allocator.free(b);
    var blocks = std.mem.splitSequence(u8, body, "\n\n");
    while (blocks.next()) |raw_event| {
        const event = std.mem.trim(u8, raw_event, " \r\n");
        if (event.len == 0) continue;
        var data_lines: std.ArrayList(u8) = .empty;
        defer data_lines.deinit(allocator);
        var line_it = std.mem.splitScalar(u8, event, '\n');
        while (line_it.next()) |line| {
            if (std.mem.startsWith(u8, line, ":")) continue; // comment
            if (std.ascii.startsWithIgnoreCase(line, "data:")) {
                var value = line["data:".len..];
                if (value.len > 0 and value[0] == ' ') value = value[1..];
                if (data_lines.items.len > 0) try data_lines.append(allocator, '\n');
                try data_lines.appendSlice(allocator, value);
            }
        }
        if (data_lines.items.len > 0) {
            if (last_owned) |b| allocator.free(b);
            last_owned = try allocator.dupe(u8, data_lines.items);
        }
    }
    if (last_owned) |owned| {
        // Transfer ownership to the caller; null out so the defer
        // above does not free it.
        last_owned = null;
        return owned;
    }
    return error.InvalidSseEvent;
}

/// Process-global cache of `HttpClient` instances, one per (tenant scope,
/// server name). Mirrors `mcp_stdio.StdioRegistry`'s shape — lazy init, clean
/// shutdown.
pub const HttpRegistry = struct {
    allocator: std.mem.Allocator,
    /// Keys (scoped server names) and values are both allocated from the
    /// registry's arena — they're freed when the arena deinits.
    arena: std.heap.ArenaAllocator,
    threaded: ?*std.Io.Threaded = null,
    entries: std.StringHashMap(Cached),
    mutex: std.atomic.Mutex = .unlocked,

    pub const Cached = struct {
        client: *HttpClient,
        digest: u64,
    };

    pub fn init(parent_allocator: std.mem.Allocator) HttpRegistry {
        return .{
            .allocator = parent_allocator,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .threaded = null,
            .entries = std.StringHashMap(Cached).init(parent_allocator),
        };
    }

    pub fn deinit(self: *HttpRegistry) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        // Free each cached client's resources.
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.client.deinit();
        }
        self.entries.deinit();
        if (self.threaded) |t| t.deinit();
        self.arena.deinit();
    }

    fn digestOf(url: []const u8, custom_headers: []const custom_http_client_mod.Header) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(url);
        for (custom_headers) |h| {
            hasher.update(&.{mcp_scope.sep});
            hasher.update(h.name);
            hasher.update("=");
            hasher.update(h.value);
        }
        return hasher.final();
    }

    fn build(self: *HttpRegistry, url: []const u8, custom_headers: []const custom_http_client_mod.Header) !*HttpClient {
        const alloc = self.arena.allocator();
        const client = try alloc.create(HttpClient);
        const hdrs_dup = try alloc.alloc(custom_http_client_mod.Header, custom_headers.len);
        for (custom_headers, 0..) |h, i| hdrs_dup[i] = .{
            .name = try alloc.dupe(u8, h.name),
            .value = try alloc.dupe(u8, h.value),
        };
        client.* = try HttpClient.init(alloc, url, hdrs_dup);
        return client;
    }

    /// Get the cached client for this tenant's `name`, or build a new one and
    /// cache it. Threadsafe.
    pub fn getOrConnect(
        self: *HttpRegistry,
        name: []const u8,
        url: []const u8,
        custom_headers: []const custom_http_client_mod.Header,
        scope: mcp_scope.Scope,
    ) !*HttpClient {
        var key_buf: [mcp_scope.max_key_bytes]u8 = undefined;
        const scoped_key = scope.keyInto(name, &key_buf) orelse return error.NameTooLong;
        const digest = digestOf(url, custom_headers);

        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.getPtr(scoped_key)) |cached| {
            if (cached.digest == digest) return cached.client;
            cached.client.deinit();
            cached.client = try self.build(url, custom_headers);
            cached.digest = digest;
            return cached.client;
        }

        const key_dup = try self.arena.allocator().dupe(u8, scoped_key);
        const client = try self.build(url, custom_headers);
        try self.entries.put(key_dup, .{ .client = client, .digest = digest });
        return client;
    }

    /// Evict one cached client by server name (plan: mcp-fetch-once-cache).
    /// HTTP equivalent of `StdioRegistry.markStale`: the next `getOrConnect`
    /// rebuilds the client with the new URL/headers.
    pub fn evictName(self: *HttpRegistry, name: []const u8) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        var doomed: [64][]const u8 = undefined;
        var count: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!mcp_scope.matchesName(kv.key_ptr.*, name)) continue;
            if (count >= doomed.len) break;
            doomed[count] = kv.key_ptr.*;
            count += 1;
        }
        for (doomed[0..count]) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                kv.value.client.deinit();
            }
        }
    }

    pub fn evict(self: *HttpRegistry, name: []const u8) void {
        mutexLock(&self.mutex);
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(name)) |kv| {
            kv.value.client.deinit();
            // NOTE: key + client backing memory lives in the registry
            // arena and is reclaimed at `deinit` — same as before, no
            // per-evict free. Entries map removal is the correctness fix.
        }
    }

    // Process-global singleton. Mirrors `mcp_stdio.StdioRegistry.global`.
    // Lives for the whole pabrik process; cleaned up via the shutdown
    // hook in main.zig (deinitGlobal).
    var global_registry: ?HttpRegistry = null;
    var global_init_mutex: std.atomic.Mutex = .unlocked;

    /// Get the process-global registry. Lazily initialized on first call.
    pub fn global(allocator: std.mem.Allocator) *HttpRegistry {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry == null) {
            global_registry = HttpRegistry.init(allocator);
        }
        return &global_registry.?;
    }

    /// Called by main.zig shutdown hook. Frees all clients + the map.
    pub fn deinitGlobal() void {
        mutexLock(&global_init_mutex);
        defer global_init_mutex.unlock();
        if (global_registry) |*reg| {
            reg.deinit();
            global_registry = null;
        }
    }
};

/// Spinlock helper (Zig 0.16 removed std.Thread.Mutex; use
/// std.atomic.Mutex + spinloop — same pattern as
/// `mcp_stdio.StdioRegistry`).
fn mutexLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

// ============================================================================
// SECTION E — ListTools helper
// ============================================================================

/// Send a `tools/list` request to `client`, return the parsed `McpTool[]`
/// from `result.tools`.
pub fn listTools(allocator: std.mem.Allocator, client: *HttpClient) ![]mcp_types.McpTool {
    // Minimal body (NO `_meta` envelope — same 2026-07-28 strictness
    // reason as `callTool` above: a bare body gets the lenient 200).
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{{}}}}
    , .{});
    defer allocator.free(body);

    // Headers: same spec-mandated set as callTool, minus the
    // Mcp-Name (tools/list doesn't take a name).
    const headers = try buildMcpHeaders(allocator, "tools/list", "", client.custom_headers);
    defer allocator.free(headers);

    // POST. Response memory belongs to the client's registry arena
    // (perform allocates from client.http.allocator), NOT the caller's
    // run arena — free with client.allocator or the arenas mismatch.
    const result = custom_http_client_mod.post(
        &client.http,
        client.url,
        body,
        headers,
        .{ .timeout_ms = 30_000 },
    ) catch return &[_]mcp_types.McpTool{};
    defer result.deinit(client.allocator);

    if (result.status_code != 200) {
        return &[_]mcp_types.McpTool{};
    }

    // Parse the response: unwrap SSE framing first (real servers like
    // context7 answer `200 text/event-stream` with `event: message\ndata:
    // {...}`), then extract `result.tools[]`.
    const trimmed_body = std.mem.trim(u8, result.body, " \r\n");
    const json_text: []u8 = if (std.mem.startsWith(u8, trimmed_body, "event:") or std.mem.startsWith(u8, trimmed_body, "data:"))
        parseLastSseData(allocator, result.body) catch return &[_]mcp_types.McpTool{}
    else
        allocator.dupe(u8, result.body) catch return &[_]mcp_types.McpTool{};
    defer allocator.free(json_text);
    return parseToolsList(allocator, json_text) catch &[_]mcp_types.McpTool{};
}

/// Internal: parse a tools/list response body into a McpTool slice. Each
/// tool's owned strings (name, description, inputSchema) are freshly
/// allocated via `allocator`.
fn parseToolsList(allocator: std.mem.Allocator, body: []const u8) ![]mcp_types.McpTool {
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, parse_arena.allocator(), body, .{}) catch {
        return try allocator.alloc(mcp_types.McpTool, 0);
    };

    // Switch-based (never direct `.object` / `.array` access): an error
    // envelope like `{"error":{...}}` or a bare array must yield an
    // empty slice, not a panic.
    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return try allocator.alloc(mcp_types.McpTool, 0),
    };
    const result_val = root.get("result") orelse return try allocator.alloc(mcp_types.McpTool, 0);
    const result_obj = switch (result_val) {
        .object => |obj| obj,
        else => return try allocator.alloc(mcp_types.McpTool, 0),
    };
    const tools_value = result_obj.get("tools") orelse return try allocator.alloc(mcp_types.McpTool, 0);
    const tools_arr = switch (tools_value) {
        .array => |a| a,
        else => return try allocator.alloc(mcp_types.McpTool, 0),
    };

    const out = try allocator.alloc(mcp_types.McpTool, tools_arr.items.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    while (i < tools_arr.items.len) : (i += 1) {
        const tool_obj = switch (tools_arr.items[i]) {
            .object => |obj| obj,
            else => continue,
        };
        const name_v = tool_obj.get("name") orelse continue;
        const name = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        const desc_v = tool_obj.get("description") orelse continue;
        const description = switch (desc_v) {
            .string => |s| s,
            else => continue,
        };
        const schema_v = tool_obj.get("inputSchema") orelse continue;
        out[i] = .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .inputSchema = .{
                .type = "object",
                .properties = schema_v,
                .required = null,
            },
        };
    }
    return out;
}

// ============================================================================
// SECTION F — Tests
// ============================================================================

const testing = std.testing;

// ── Mock line reader for SSE parser tests ──────────────────────────────

/// In-memory line reader for `readSseEvent` tests. Holds a list of lines
/// (without trailing `\n`); `next()` returns them one at a time then null.
const MockLineReader = struct {
    lines: []const []const u8,
    index: usize = 0,

    fn next(self: *MockLineReader) !?[]const u8 {
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        return line;
    }
};

// ── readSseEvent tests (8 tests) ───────────────────────────────────────

/// All readSseEvent tests must free ALL three freshly-allocated fields of the
/// returned event (event / data / id).
const testing_allocator = testing.allocator;

test "readSseEvent: single data-only event" {
    var reader = MockLineReader{ .lines = &.{ "data: hello" } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("hello", ev.data);
    try testing.expectEqualStrings("", ev.event);
    try testing.expectEqualStrings("", ev.id);
    try testing.expectEqual(@as(?u64, null), ev.retry_ms);
}

test "readSseEvent: event + data" {
    var reader = MockLineReader{ .lines = &.{
        "event: progress",
        "data: {\"p\":50}",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("progress", ev.event);
    try testing.expectEqualStrings("{\"p\":50}", ev.data);
}

test "readSseEvent: multi-data concatenation with \\n" {
    // Per SSE spec, multi-`data:` lines are concatenated with a single
    // \n character between them (NOT stripped, NOT removed).
    var reader = MockLineReader{ .lines = &.{
        "data: line1",
        "data: line2",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("line1\nline2", ev.data);
}

test "readSseEvent: comment line ignored" {
    // Per SSE spec, lines starting with `:` are comments and ignored.
    var reader = MockLineReader{ .lines = &.{
        ":heartbeat",
        "data: real",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("real", ev.data);
}

test "readSseEvent: retry parsed as integer" {
    var reader = MockLineReader{ .lines = &.{
        "retry: 3000",
        "data: ok",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqual(@as(?u64, 3000), ev.retry_ms);
    try testing.expectEqualStrings("ok", ev.data);
}

test "readSseEvent: id field captured" {
    var reader = MockLineReader{ .lines = &.{
        "id: 42",
        "data: ok",
    } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("42", ev.id);
    try testing.expectEqualStrings("ok", ev.data);
}

test "readSseEvent: blank line mid-stream resets to a new event" {
    // Two events in one stream: first carries "first", second carries
    // "second". A blank line (`""` in our mock = event boundary) resets
    // the per-event accumulators.
    var reader = MockLineReader{ .lines = &.{
        "data: first",
        "", // event boundary
        "data: second",
    } };
    const ev1 = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev1.event);
        testing_allocator.free(ev1.data);
        testing_allocator.free(ev1.id);
    }
    try testing.expectEqualStrings("first", ev1.data);

    const ev2 = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev2.event);
        testing_allocator.free(ev2.data);
        testing_allocator.free(ev2.id);
    }
    try testing.expectEqualStrings("second", ev2.data);
}

test "readSseEvent: case-insensitive field names" {
    // Per SSE spec, field names are case-insensitive. "DATA:" must be
    // treated the same as "data:".
    var reader = MockLineReader{ .lines = &.{ "DATA: upper" } };
    const ev = (try readSseEvent(testing_allocator, &reader)) orelse unreachable;
    defer {
        testing_allocator.free(ev.event);
        testing_allocator.free(ev.data);
        testing_allocator.free(ev.id);
    }
    try testing.expectEqualStrings("upper", ev.data);
}

// ── buildMcpHeaders tests (4 tests) ────────────────────────────────────

test "buildMcpHeaders: required headers always present for tools/call" {
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "say_hello",
        &[_]custom_http_client_mod.Header{},
    );
    defer testing.allocator.free(hdrs);
    // 4 spec headers (Accept, Content-Type, MCP-Protocol-Version,
    // Mcp-Method) + 1 per-method (Mcp-Name) = 5 total.
    try testing.expectEqual(@as(usize, 5), hdrs.len);
    // Spot-check the values. Order isn't asserted here (libcurl
    // uses first-match, not order).
    var found_accept = false;
    var found_content_type = false;
    var found_protocol = false;
    var found_method = false;
    var found_name = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Accept")) {
            try testing.expectEqualStrings("application/json, text/event-stream", h.value);
            found_accept = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            try testing.expectEqualStrings("application/json", h.value);
            found_content_type = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "MCP-Protocol-Version")) {
            try testing.expectEqualStrings("2025-11-25", h.value);
            found_protocol = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Mcp-Method")) {
            try testing.expectEqualStrings("tools/call", h.value);
            found_method = true;
        } else if (std.ascii.eqlIgnoreCase(h.name, "Mcp-Name")) {
            try testing.expectEqualStrings("say_hello", h.value);
            found_name = true;
        }
    }
    try testing.expect(found_accept);
    try testing.expect(found_content_type);
    try testing.expect(found_protocol);
    try testing.expect(found_method);
    try testing.expect(found_name);
}

test "buildMcpHeaders: no Mcp-Name for initialize" {
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "initialize",
        "", // no tool name
        &[_]custom_http_client_mod.Header{},
    );
    defer testing.allocator.free(hdrs);
    // 4 spec headers only (no Mcp-Name when tool_name is empty).
    try testing.expectEqual(@as(usize, 4), hdrs.len);
    for (hdrs) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Mcp-Name"));
    }
}

test "buildMcpHeaders: Mcp-Name omitted for non-ASCII tool names" {
    // Spec says Mcp-Name MUST be ASCII-safe (with a Base64-sentinel
    // fallback for non-ASCII values, which we don't implement in v1).
    // For v1 we just SKIP the header when the value isn't ASCII.
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "\xe5\x90\x8d\xe5\xad\x97", // "名字" in UTF-8 (non-ASCII)
        &[_]custom_http_client_mod.Header{},
    );
    defer testing.allocator.free(hdrs);
    try testing.expectEqual(@as(usize, 4), hdrs.len);
    for (hdrs) |h| {
        try testing.expect(!std.ascii.eqlIgnoreCase(h.name, "Mcp-Name"));
    }
}

test "buildMcpHeaders: custom headers merged; spec headers win on conflict" {
    // A custom `MCP-Protocol-Version: 1999-01-01` must NOT override the spec
    // value `2025-11-25`.
    const custom = [_]custom_http_client_mod.Header{
        .{ .name = "X-Trace-Id", .value = "abc" },
        .{ .name = "MCP-Protocol-Version", .value = "1999-01-01" },
    };
    const hdrs = try buildMcpHeaders(
        testing.allocator,
        "tools/call",
        "say_hello",
        &custom,
    );
    defer testing.allocator.free(hdrs);
    // Total: 4 spec + 1 Mcp-Name + 2 custom = 7.
    try testing.expectEqual(@as(usize, 7), hdrs.len);
    // The FIRST MCP-Protocol-Version in the slice must be the spec
    // value (so libcurl uses it). The custom 1999-01-01 should appear
    // LATER in the slice.
    var first_protocol: ?[]const u8 = null;
    var found_1999 = false;
    var found_2025 = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "MCP-Protocol-Version")) {
            if (first_protocol == null) first_protocol = h.value;
            if (std.mem.eql(u8, h.value, "1999-01-01")) found_1999 = true;
            if (std.mem.eql(u8, h.value, "2025-11-25")) found_2025 = true;
        }
    }
    try testing.expectEqualStrings("2025-11-25", first_protocol.?);
    try testing.expect(found_1999);
    try testing.expect(found_2025);
    // X-Trace-Id is present and equals the custom value.
    var found_trace = false;
    for (hdrs) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "X-Trace-Id")) {
            try testing.expectEqualStrings("abc", h.value);
            found_trace = true;
        }
    }
    try testing.expect(found_trace);
}

// ── HttpClient + HttpRegistry tests (6 tests) ───────────────────────────
// These are pure in-memory tests (no network, no subprocess).

test "HttpClient.init: stores URL and custom headers" {
    const url = "http://127.0.0.1:1234/mcp";
    const hdrs = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer test-token" },
    };
    var client = try HttpClient.init(testing.allocator, url, &hdrs);
    defer client.deinit();
    try testing.expectEqualStrings(url, client.url);
    try testing.expectEqual(@as(usize, 1), client.custom_headers.len);
    try testing.expectEqualStrings("Authorization", client.custom_headers[0].name);
    try testing.expectEqualStrings("Bearer test-token", client.custom_headers[0].value);
}

test "HttpClient.init: different URLs create independent clients" {
    var a = try HttpClient.init(testing.allocator, "http://a/mcp", &.{});
    defer a.deinit();
    var b = try HttpClient.init(testing.allocator, "http://b/mcp", &.{});
    defer b.deinit();
    try testing.expect(a.url.ptr != b.url.ptr);
    try testing.expectEqualStrings("http://a/mcp", a.url);
    try testing.expectEqualStrings("http://b/mcp", b.url);
}

test "a cached client is reused while its url and headers are unchanged" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const headers = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer a" },
    };
    const c1 = try reg.getOrConnect("alpha", "http://127.0.0.1:1/mcp", &headers, .{});
    const c2 = try reg.getOrConnect("alpha", "http://127.0.0.1:1/mcp", &headers, .{});
    try testing.expectEqual(@intFromPtr(c1), @intFromPtr(c2));
}

test "a changed url rebuilds the client instead of reusing the old one" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const c1 = try reg.getOrConnect("alpha", "http://127.0.0.1:1/mcp", &.{}, .{});
    const c2 = try reg.getOrConnect("alpha", "http://127.0.0.1:2/mcp", &.{}, .{});
    try testing.expect(c1 != c2);
    try testing.expectEqualStrings("http://127.0.0.1:2/mcp", c2.url);
}

test "a changed token rebuilds the client so the old token cannot be reused" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const with_a = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer tenant-a" },
    };
    const with_b = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer tenant-b" },
    };
    const c1 = try reg.getOrConnect("alpha", "http://127.0.0.1:1/mcp", &with_a, .{});
    const c2 = try reg.getOrConnect("alpha", "http://127.0.0.1:1/mcp", &with_b, .{});
    try testing.expect(c1 != c2);
    try testing.expectEqualStrings("Bearer tenant-b", c2.custom_headers[0].value);
}

test "two tenants using one server name get their own client and their own token" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };
    const token_a = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer tenant-a" },
    };
    const token_b = [_]custom_http_client_mod.Header{
        .{ .name = "Authorization", .value = "Bearer tenant-b" },
    };

    const a = try reg.getOrConnect("files", "http://127.0.0.1:1/mcp", &token_a, tenant_a);
    const b = try reg.getOrConnect("files", "http://127.0.0.1:1/mcp", &token_b, tenant_b);

    try testing.expect(a != b);
    try testing.expectEqualStrings("Bearer tenant-a", a.custom_headers[0].value);
    try testing.expectEqualStrings("Bearer tenant-b", b.custom_headers[0].value);
    try testing.expectEqual(@as(usize, 2), reg.entries.count());
}

test "evicting a tenant's server leaves the same-named server of another tenant alive" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const tenant_a = mcp_scope.Scope{ .owner = "u_a", .workspace_id = "ws_1" };
    const tenant_b = mcp_scope.Scope{ .owner = "u_b", .workspace_id = "ws_1" };
    const a = try reg.getOrConnect("files", "http://127.0.0.1:1/mcp", &.{}, tenant_a);
    const b = try reg.getOrConnect("files", "http://127.0.0.1:1/mcp", &.{}, tenant_b);

    var key_buf: [mcp_scope.max_key_bytes]u8 = undefined;
    const key_a = tenant_a.keyInto("files", &key_buf).?;
    reg.evict(key_a);

    const b_again = try reg.getOrConnect("files", "http://127.0.0.1:1/mcp", &.{}, tenant_b);
    try testing.expectEqual(@intFromPtr(b), @intFromPtr(b_again));
    try testing.expectEqual(@as(usize, 1), reg.entries.count());
    _ = a;
}

test "HttpRegistry: getOrConnect returns different clients for different names" {
    var reg = HttpRegistry.init(testing.allocator);
    defer reg.deinit();
    const a = try reg.getOrConnect("a", "http://127.0.0.1:1/mcp", &.{}, .{});
    const b = try reg.getOrConnect("b", "http://127.0.0.1:1/mcp", &.{}, .{});
    try testing.expect(a != b);
}

test "HttpRegistry: deinit cleans up registered clients without leaking" {
    var reg = HttpRegistry.init(testing.allocator);
    _ = try reg.getOrConnect("a", "http://127.0.0.1:1/mcp", &.{}, .{});
    _ = try reg.getOrConnect("b", "http://127.0.0.1:2/mcp", &.{}, .{});
    _ = try reg.getOrConnect("c", "http://127.0.0.1:3/mcp", &.{}, .{});
    reg.deinit();
    // No assertion needed — the test passes if no leak is reported
    // by zig's DebugAllocator (this is the default in debug builds).
}

test "listTools: returns an empty slice for a stubbed client (signature test)" {
    // The full listTools behavior is covered by the functional test
    // (tests/functional/mcp_http_test.py uses the real binary).
    var client = try HttpClient.init(testing.allocator, "http://x/mcp", &.{});
    defer client.deinit();
    const tools = try listTools(testing.allocator, &client);
    defer testing.allocator.free(tools);
    try testing.expectEqual(@as(usize, 0), tools.len);
}

test "parseLastSseData: single event returns its data (no alias panic)" {
    // Regression: the old impl stored `last_data = data_lines.items` (freed
    // at end of iteration) then `dupe`d it — the allocator reuses the freed
    // address so src == dst and Debug panics with `@memcpy arguments alias`.
    const body = "event: message\ndata: {\"hello\":1}\n\n";
    const out = try parseLastSseData(testing.allocator, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"hello\":1}", out);
}

test "parseLastSseData: last event wins across progress + result events" {
    // Real servers (e.g. context7) stream progress notifications then
    // the final JSON-RPC result. The parser must return the LAST
    // data payload, not the first, and must not alias freed memory.
    const body =
        "event: message\ndata: {\"progress\":50}\n\n" ++
        "event: message\ndata: {\"result\":{\"tools\":[]}}\n\n";
    const out = try parseLastSseData(testing.allocator, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"result\":{\"tools\":[]}}", out);
}

test "parseLastSseData: no data lines returns InvalidSseEvent" {
    const body = "event: ping\n:heartbeat\n\n";
    try testing.expectError(error.InvalidSseEvent, parseLastSseData(testing.allocator, body));
}
