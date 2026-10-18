//! The process-wide `App` singleton — the one object every other part of the
//! code reaches through.

const std = @import("std");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;
const loggermod = @import("modules/logger/Logger.zig");
const config = @import("modules/config/Config.zig");
const event_bus = @import("modules/event_bus/src/event.zig");
const tool_models = @import("modules/agent/tools/schemas.zig");
const mcp_stdio = @import("modules/agent/mcp/mcp/mcp_stdio.zig");
const mcp_http = @import("modules/agent/mcp/mcp/mcp_http.zig");
const ai_mod = @import("ai_workflow/tui/mod.zig");
const agentic_loop_mod = @import("agentic_loop/workflow.zig");

var global_ctx: ?*App = null;

pub fn getSingleton() anyerror!*App {
    return global_ctx orelse error.GlobalContextNotInitialized;
}

pub fn setSingleton(ctx: *App) !void {
    global_ctx = ctx;
}

/// Holds the live `LlmConfig` pointer plus the previously-installed one so
/// that in-flight workflows (which captured the old `*const LlmConfig` into a
/// local) keep dereferencing valid memory until the next swap — or until
pub const LlmConfigHolder = struct {
    current: *config.LlmConfig,
    previous: ?*const config.LlmConfig = null,
    lock: std.Io.Mutex = .init,
};

/// Input to `App.emit_run_agent`. The string fields are PASSED-THROUGH —
/// `emit_run_agent` does not dupe them.
pub const EmitRunAgentInput = struct {
    session_id: []const u8,
    session_name: []const u8,
    queue_message: []const u8,
    cwd: []const u8,
    body_message: []const u8,
    allowed_tools: []const u8,
    image_urls: []const u8,
    video_urls: []const u8 = "",
    selected_profile_model: []const u8,
    is_auto_retry_until_stop: []const u8,
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
    skip_initial_queue_message: bool = false,
    /// Owning user id for the session row this run creates (plan 2026-09-25,
    /// W1).
    user_id: []const u8 = "",
};

/// The application singleton.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    llm_config_holder: LlmConfigHolder,
    logger: *loggermod.Logger,
    environment: ?*const std.process.Environ.Map,
    event_bus: *event_bus.EventBus,
    server: *gserverz.GinwaServer,

    session_to_client_ids: std.StringHashMapUnmanaged(std.ArrayList([16]u8)) = .empty,
    session_map_lock: std.Io.Mutex = .init,

    /// SSE client_id -> owning user id, for per-user event filtering.
    client_owners: std.StringHashMapUnmanaged([]const u8) = .empty,
    client_owners_lock: std.Io.Mutex = .init,

    on_disconnect_cb: ?*fn (client_id: [16]u8) void = null,
    on_disconnect_lock: std.Io.Mutex = .init,
    group_emit_session_create: std.Io.Group,
    /// Fire-and-forget group for background-command completion watchers
    /// (background_watcher.zig).
    group_bg_watchers: std.Io.Group = .init,

    static_dir_path: ?[]const u8 = null,

    /// Opt-in auth enforcement, set from `--auth` CLI flag.
    /// When false, all endpoints are open (legacy single-user mode).
    /// When true, API + static + ws/sse require a valid `pabrik_session` cookie.
    auth_enabled: bool = false,

    /// Process-global MCP stdio registry, cached here so every call site goes
    /// through the singleton struct (`di.mcp_stdio_registry`) instead of
    /// calling `StdioRegistry.global(allocator)` with its own allocator
    mcp_stdio_registry: ?*mcp_stdio.StdioRegistry = null,
    mcp_http_registry: ?*mcp_http.HttpRegistry = null,

    /// Fetch-once MCP tools cache (plan: mcp-fetch-once-cache).
    mcp_tools_cache: ?[]tool_models.AgentTool = null,
    mcp_tools_init: bool = false,
    mcp_tools_lock: std.atomic.Mutex = .unlocked,

    /// Schedule an async session-create task on the Io group.
    pub fn emit_run_agent(self: *App, obj: EmitRunAgentInput) !void {
        // Heap-dupe each string synchronously into the long-lived
        // `self.allocator`.
        const owned_session_id = try self.allocator.dupe(u8, obj.session_id);
        errdefer self.allocator.free(owned_session_id);
        const owned_session_name = try self.allocator.dupe(u8, obj.session_name);
        errdefer self.allocator.free(owned_session_name);
        const owned_queue_message = try self.allocator.dupe(u8, obj.queue_message);
        errdefer self.allocator.free(owned_queue_message);
        const owned_cwd = try self.allocator.dupe(u8, obj.cwd);
        errdefer self.allocator.free(owned_cwd);
        const owned_body_message = try self.allocator.dupe(u8, obj.body_message);
        errdefer self.allocator.free(owned_body_message);
        const owned_allowed_tools = try self.allocator.dupe(u8, obj.allowed_tools);
        errdefer self.allocator.free(owned_allowed_tools);
        const owned_image_urls = try self.allocator.dupe(u8, obj.image_urls);
        errdefer self.allocator.free(owned_image_urls);
        const owned_video_urls = try self.allocator.dupe(u8, obj.video_urls);
        errdefer self.allocator.free(owned_video_urls);
        const owned_selected_profile_model = try self.allocator.dupe(u8, obj.selected_profile_model);
        errdefer self.allocator.free(owned_selected_profile_model);
        const owned_is_auto_retry_until_stop = try self.allocator.dupe(u8, obj.is_auto_retry_until_stop);
        errdefer self.allocator.free(owned_is_auto_retry_until_stop);
        // Owner rides along to the concurrent task (plan 2026-09-25, W1):
        // the worker has no request context, so the enqueuing request's
        // owner is the only source. Empty when auth is off.
        const owned_user_id = try self.allocator.dupe(u8, obj.user_id);
        errdefer self.allocator.free(owned_user_id);
        // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). The
        // flag is a `bool` (no string dupe needed) — pass through the
        // Io group directly.

        // NEW (plan 2026-08-29-chat-sidebar-last-human-touched, Task 3):
        // Stamp `sessions.last_human_touched_at_nano` BEFORE the concurrent
        // task spawns — this is the single funnel for every user-sends-a-
        ai_mod.llm_history.updateSessionLastHumanTouchedAt(
            self.allocator,
            self.db,
            owned_session_id,
            null,
        ) catch |stamp_err| {
            std.log.warn(
                "emit_run_agent: stamp session last_human_touched_at failed (non-fatal): {s}",
                .{@errorName(stamp_err)},
            );
        };

        try self.group_emit_session_create.concurrent(
            self.io,
            struct {
                fn run(
                    di_inner: *App,
                    sid: []const u8,
                    sname: []const u8,
                    qmsg: []const u8,
                    cwd: []const u8,
                    bmsg: []const u8,
                    atools: []const u8,
                    iurls: []const u8,
                    vurls: []const u8,
                    spm: []const u8,
                    iaur: []const u8,
                    siqm: bool,
                    uid: []const u8,
                ) void {
                    // These slices are owned by the Io task lifetime — they
                    // were duped synchronously by `emit_run_agent` into
                    // `di_inner.allocator` (which lives forever).
                    defer di_inner.allocator.free(uid);
                    defer di_inner.allocator.free(iaur);
                    defer di_inner.allocator.free(spm);
                    defer di_inner.allocator.free(vurls);
                    defer di_inner.allocator.free(iurls);
                    defer di_inner.allocator.free(atools);
                    defer di_inner.allocator.free(bmsg);
                    defer di_inner.allocator.free(cwd);
                    defer di_inner.allocator.free(qmsg);
                    defer di_inner.allocator.free(sname);
                    defer di_inner.allocator.free(sid);

                    const event_buss = di_inner.event_bus;

                    di_inner.insert_worker(di_inner.allocator, .{
                        .session_id = sid,
                        .session_name = sname,
                        .queue_message = qmsg,
                        .cwd = cwd,
                        .body_message = bmsg,
                        .allowed_tools = atools,
                        .image_urls = iurls,
                        .video_urls = vurls,
                        .selected_profile_model = spm,
                        .is_auto_retry_until_stop = iaur,
                        .user_id = uid,
                    }) catch @panic("allocPrint failed building the ai_worker_flow RunParamsNew event");

                    event_buss.emit(agentic_loop_mod.RunParamsNew, "ai_worker_flow", .{
                        .parent_session_id = sid,
                        .session_id = sid,
                        .message = qmsg,
                        .cwd = cwd,
                        .body = bmsg,
                        .allowed_tools = atools,
                        .is_sub_agent = false,
                        .image_urls = iurls,
                        .video_urls = vurls,
                        .selected_profile_model = spm,
                        .is_auto_retry_until_stop = iaur,
                        // NEW (plan: 2026-08-18-kanban-task-detail-start-agent)
                        .skip_initial_queue_message = siqm,
                    });
                }
            }.run,
            .{ self, owned_session_id, owned_session_name, owned_queue_message, owned_cwd, owned_body_message, owned_allowed_tools, owned_image_urls, owned_video_urls, owned_selected_profile_model, owned_is_auto_retry_until_stop, obj.skip_initial_queue_message, owned_user_id },
        );
    }

    fn insert_worker(self: *App, allocator: std.mem.Allocator, parsed: EmitRunAgentInput) !void {
        const session_id = parsed.session_id;
        const session_name = parsed.session_name;
        const effective_cwd = parsed.cwd;
        const effective_profile = parsed.selected_profile_model;
        const effective_auto_retry: []const u8 = blk: {
            if (std.mem.eql(u8, parsed.is_auto_retry_until_stop, "1")) break :blk "1";
            break :blk "0";
        };

        // (no debug log — production code)

        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop, user_id) " ++
            "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?, ?)";
        const copy_session_name = try allocator.dupe(u8, session_name);
        const copy_cwd = try allocator.dupe(u8, effective_cwd);
        const copy_profile = if (effective_profile.len > 0) try allocator.dupe(u8, effective_profile) else "";
        // Owner stamped at INSERT time (plan 2026-09-25, W1).
        const copy_user_id = if (parsed.user_id.len > 0) try allocator.dupe(u8, parsed.user_id) else "";
        try self.db.exec(
            allocator,
            session_sql,
            &.{ session_id, copy_session_name, copy_cwd, copy_profile, effective_auto_retry, copy_user_id },
        );

        // `INSERT OR IGNORE` is a no-op when the row already exists — which
        // is EVERY normal send into an existing chat.
        const session_row_inserted = self.db.changes() > 0;

        // Claim an ownerless row when the INSERT OR IGNORE above no-opped on
        // a pre-existing ownerless row (a handler that wrote the row without
        // `user_id` before this task ran).
        if (parsed.user_id.len > 0) {
            self.db.exec(
                allocator,
                "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
                &.{ parsed.user_id, session_id },
            ) catch {};
        }

        // Broadcast session created event — only when the INSERT above
        // actually created the row. See `session_row_inserted`.
        if (!session_row_inserted) return;
        try agentic_loop_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "created",
            .id = session_id,
            .name = session_name,
            .status = "active",
            .cwd = effective_cwd,
            .created_at = "",
            .updated_at = "",
            .selected_profile_model = effective_profile,
            .is_auto_retry_until_stop = effective_auto_retry,
            .last_finish_reason = "",
        });
    }

    /// Fetch-once cache readers/writers (plan: mcp-fetch-once-cache).
    /// All three are io-free (spinlock) so workflow + HTTP handlers share them.
    pub fn isMcpToolsInit(self: *App) bool {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        return self.mcp_tools_init;
    }

    /// Snapshot the cache onto `run_allocator`. Returns `null` when the
    /// cache is uninitialized OR when it was initialized with `null`
    /// (no `mcp_servers` object). The caller owns the returned slice.
    pub fn getMcpToolsCached(self: *App, run_allocator: std.mem.Allocator) ?[]tool_models.AgentTool {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (!self.mcp_tools_init) return null;
        const cached = self.mcp_tools_cache orelse return null;
        return dupeAgentTools(run_allocator, cached) catch null;
    }

    /// Publish a fresh fetch. Deep-dupes `tools` onto `self.allocator`
    /// (process lifetime), frees the previous cache, marks initialized.
    pub fn storeMcpToolsCache(self: *App, tools_in: ?[]tool_models.AgentTool, mark_init: bool) void {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (self.mcp_tools_cache) |old| {
            freeAgentTools(self.allocator, old);
            self.mcp_tools_cache = null;
        }
        if (tools_in) |t| {
            self.mcp_tools_cache = dupeAgentTools(self.allocator, t) catch null;
        } else {
            self.mcp_tools_cache = null;
        }
        if (mark_init) self.mcp_tools_init = true;
    }

    /// Lazy-invalidate: free + mark uninitialized. The next workflow run
    /// does the one refetch. Called from PUT /api/config/pabrik and
    /// add_mcp_server after their `setLlmConfig` swap.
    pub fn clearMcpToolsCache(self: *App) void {
        mcpToolsLock(&self.mcp_tools_lock);
        defer mcpToolsUnlock(&self.mcp_tools_lock);
        if (self.mcp_tools_cache) |old| {
            freeAgentTools(self.allocator, old);
            self.mcp_tools_cache = null;
        }
        self.mcp_tools_init = false;
    }
};

/// Hot-path read. Returns the currently-installed `LlmConfig` pointer.
pub fn getLlmConfig(di: *App) *config.LlmConfig {
    return di.llm_config_holder.current;
}

/// Atomic install.
pub fn setLlmConfig(
    di: *App,
    new_ptr: *config.LlmConfig,
) void {
    const io = di.io;
    di.llm_config_holder.lock.lock(io) catch return;
    defer di.llm_config_holder.lock.unlock(io);

    const pending_previous = di.llm_config_holder.previous;
    di.llm_config_holder.previous = di.llm_config_holder.current;
    di.llm_config_holder.current = new_ptr;

    if (pending_previous) |p| freeLlmConfig(di.allocator, p);
}

/// Free both `current` and `previous` (if any). Called once at shutdown
/// from `main.zig` after the HTTP server has stopped accepting requests.
pub fn freeAllLlmConfigs(di: *App) void {
    freeLlmConfig(di.allocator, di.llm_config_holder.current);
    if (di.llm_config_holder.previous) |p| freeLlmConfig(di.allocator, p);
    di.llm_config_holder.current = undefined;
    di.llm_config_holder.previous = null;
}

/// Free a single `LlmConfig`: deinit all owned strings/maps then destroy
/// the heap allocation. The `const`-cast is safe because we own the
/// memory — this is the only place we drop the `const`.
fn freeLlmConfig(allocator: std.mem.Allocator, ptr: *const config.LlmConfig) void {
    var mut: *config.LlmConfig = @constCast(ptr);
    mut.deinit();
    allocator.destroy(mut);
}

/// Record the owning user id for an SSE client, for per-user event filtering.
pub fn registerClientOwner(client_id: [16]u8, owner: []const u8) void {
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.client_owners_lock.lock(io) catch {};
    defer di.client_owners_lock.unlock(io);

    // The key MUST be an owned copy: `client_id` is a by-value parameter, so
    // `client_id[0..]` would dangle the moment this function returns.
    const owned_key = allocator.dupe(u8, client_id[0..]) catch return;
    const owned = allocator.dupe(u8, owner) catch {
        allocator.free(owned_key);
        return;
    };
    if (di.client_owners.fetchRemove(owned_key)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    di.client_owners.put(allocator, owned_key, owned) catch {
        allocator.free(owned_key);
        allocator.free(owned);
    };
}

/// Look up the owning user id recorded for an SSE client. Returns a BORROWED
/// slice valid only while the caller holds no other registry mutation — the
/// fan-out uses it immediately and never stores it.
pub fn getClientOwner(client_id: [16]u8) ?[]const u8 {
    const di = getSingleton() catch return null;
    const io = di.io;
    di.client_owners_lock.lock(io) catch {};
    defer di.client_owners_lock.unlock(io);
    return di.client_owners.get(client_id[0..]);
}

/// Drop the recorded owner for a disconnected SSE client. Called from
/// `handleClientDisconnect`, which the SseManager invokes on every removal
/// path, so the map cannot grow across reconnects.
pub fn unregisterClientOwner(client_id: [16]u8) void {
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.client_owners_lock.lock(io) catch {};
    defer di.client_owners_lock.unlock(io);
    if (di.client_owners.fetchRemove(client_id[0..])) |kv| {
        allocator.free(kv.value);
    }
}

/// Register a session -> client_id mapping (appends to list)
pub fn registerSessionClient(session_id: []const u8, client_id: [16]u8, is_use_lock: bool) !void {
    _ = is_use_lock;
    var di = try getSingleton();
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        // Session already exists — just append if not duplicate
        for (list.items) |existing_id| {
            if (std.mem.eql(u8, &existing_id, &client_id)) return;
        }
        try list.append(allocator, client_id);
        return;
    }

    // New session — build list first
    var list = std.ArrayListUnmanaged([16]u8).empty;
    try list.append(allocator, client_id);

    const result = try di.session_to_client_ids.getOrPut(allocator, session_id);
    if (result.found_existing) {
        // Another thread beat us — discard our list, append to existing
        list.deinit(allocator);
        for (result.value_ptr.items) |existing_id| {
            if (std.mem.eql(u8, &existing_id, &client_id)) return;
        }
        try result.value_ptr.append(allocator, client_id);
    } else {
        // We own the new entry — dupe the key so we can free it later
        const owned_key = try allocator.dupe(u8, session_id);
        result.key_ptr.* = owned_key;
        result.value_ptr.* = list;
    }
}

/// Unregister a session -> client_id mapping (removes all clients for session)
pub fn unregisterSessionClient(session_id: []const u8, is_use_lock: bool) void {
    _ = is_use_lock;
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
    if (di.session_to_client_ids.fetchRemove(session_id)) |kv| {
        var list = kv.value;
        list.deinit(allocator);
        allocator.free(kv.key); // safe — we duped this with allocator in register
    }
}

/// Remove ONE client_id from a routing key's list (disconnect path). Drops
/// the map entry only when its list becomes empty.
pub fn unregisterSessionClientId(routing_key: []const u8, client_id: [16]u8, is_use_lock: bool) void {
    _ = is_use_lock;
    const di = getSingleton() catch return;
    const allocator = di.allocator;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
    const list = di.session_to_client_ids.getPtr(routing_key) orelse return;
    var idx: ?usize = null;
    for (list.items, 0..) |existing_id, i| {
        if (std.mem.eql(u8, &existing_id, &client_id)) {
            idx = i;
            break;
        }
    }
    _ = list.orderedRemove(idx orelse return);
    if (list.items.len == 0) {
        list.deinit(allocator);
        if (di.session_to_client_ids.fetchRemove(routing_key)) |kv| {
            allocator.free(kv.key);
        }
    }
}

/// Get client_id for a session, if registered (returns first client if multiple)
pub fn getClientIdForSession(session_id: []const u8, is_use_lock: bool) ?[16]u8 {
    _ = is_use_lock;
    const di = getSingleton() catch return null;
    // const io = di.io;
    // di.session_map_lock.lock(io) catch {};
    // defer di.session_map_lock.unlock(io);

    if (di.session_to_client_ids.getPtr(session_id)) |list| {
        if (list.items.len > 0) {
            return list.items[0];
        }
    }
    return null;
}

/// Get list of client_ids for a session Returns an owned copy that the caller
/// MUST free with `allocator.free`. Returns null if the session has no
/// registered clients (or does not exist).
pub fn getListClientsForSession(session_id: []const u8, allocator: std.mem.Allocator, is_use_lock: bool) !?[][16]u8 {
    _ = is_use_lock;
    const di = try getSingleton();
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);

    const list = di.session_to_client_ids.get(session_id) orelse return null;
    if (list.items.len == 0) return null;

    const copy = try allocator.alloc([16]u8, list.items.len);
    @memcpy(copy, list.items);
    return copy;
}

/// Find session_id by client_id (reverse lookup)
pub fn getSessionIdForClient(client_id: [16]u8, is_use_lock: bool) ?[]const u8 {
    _ = is_use_lock;
    const di = getSingleton() catch return null;
    const io = di.io;
    di.session_map_lock.lock(io) catch {};
    defer di.session_map_lock.unlock(io);
    var it = di.session_to_client_ids.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |v| {
            var equal = true;
            for (v, client_id) |a, b| {
                if (a != b) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                // ✅ return an owned copy, caller must free
                return di.allocator.dupe(u8, entry.key_ptr.*) catch null;
            }
        }
    }
    return null;
}

/// Handle client disconnect - called by SseManager on_disconnect callback
pub fn handleClientDisconnect(client_id: [16]u8) void {
    const di = getSingleton() catch return;
    const io = di.io;

    di.on_disconnect_lock.lock(io) catch {};
    defer di.on_disconnect_lock.unlock(io);

    if (di.on_disconnect_cb) |cb| {
        // di.session_map_lock.lock(io) catch {};
        // defer di.session_map_lock.unlock(io);
        cb(client_id);
    }

    // Drop the per-user event-filter entry for this client.
    unregisterClientOwner(client_id);

    // Collect EVERY routing_key that contains this client_id, then unregister
    // each one and drop its event_bus subscription.
    var routing_keys_to_drop: std.ArrayList([]const u8) = .empty;
    defer routing_keys_to_drop.deinit(di.allocator);

    {
        di.session_map_lock.lock(io) catch {};
        defer di.session_map_lock.unlock(io);
        var it = di.session_to_client_ids.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |v| {
                if (std.mem.eql(u8, &v, &client_id)) {
                    // Each routing_key's map entry owns its key string
                    // (registered via `registerSessionClient` →
                    // result.key_ptr.* = owned_key).
                    if (di.allocator.dupe(u8, entry.key_ptr.*)) |duped| {
                        routing_keys_to_drop.append(di.allocator, duped) catch continue;
                    } else |_| {
                        continue;
                    }
                    break;
                }
            }
        }
    }

    for (routing_keys_to_drop.items) |rk| {
        defer di.allocator.free(rk);
        unregisterSessionClientId(rk, client_id, false);
        std.log.info("sse disconnect: client {x} dropped from routing key '{s}'", .{ client_id, rk });
    }
}

/// Process-global MCP stdio registry accessor (lives beside `App` so every
/// call site shares one `long_lived` allocator choice).
pub fn mcpStdioRegistry(fallback: std.mem.Allocator) *mcp_stdio.StdioRegistry {
    if (getSingleton()) |di| {
        if (di.mcp_stdio_registry) |cached| return cached;
        const reg = mcp_stdio.StdioRegistry.global(di.allocator);
        di.mcp_stdio_registry = reg;
        return reg;
    } else |_| {}
    return mcp_stdio.StdioRegistry.global(fallback);
}

/// Same shape for the HTTP transport registry.
pub fn mcpHttpRegistry(fallback: std.mem.Allocator) *mcp_http.HttpRegistry {
    if (getSingleton()) |di| {
        if (di.mcp_http_registry) |cached| return cached;
        const reg = mcp_http.HttpRegistry.global(di.allocator);
        di.mcp_http_registry = reg;
        return reg;
    } else |_| {}
    return mcp_http.HttpRegistry.global(fallback);
}

/// Spinlock helper for the fetch-once tools cache (same pattern as
/// `mcp_stdio.StdioRegistry` / `mcp_http.HttpRegistry` — Zig 0.16 has
/// no `std.Thread.Mutex` in the public surface).
fn mcpToolsLock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

fn mcpToolsUnlock(m: *std.atomic.Mutex) void {
    m.unlock();
}

/// Deep-dupe one `AgentTool` (all strings + nested slices) onto
/// `allocator`. Mirrors the ownership contract of
/// `buildMCPToolsRun` (caller owns everything).
fn dupeAgentTool(allocator: std.mem.Allocator, src: tool_models.AgentTool) !tool_models.AgentTool {
    const props = try allocator.alloc(tool_models.ToolProperty, src.function.parameters.properties.len);
    errdefer allocator.free(props);
    for (src.function.parameters.properties, 0..) |p, i| {
        props[i] = .{
            .name = try allocator.dupe(u8, p.name),
            .type = try allocator.dupe(u8, p.type),
            .description = try allocator.dupe(u8, p.description),
        };
    }
    errdefer {
        for (props) |p| {
            allocator.free(p.name);
            allocator.free(p.type);
            allocator.free(p.description);
        }
        allocator.free(props);
    }
    const required = try allocator.alloc([]const u8, src.function.parameters.required.len);
    errdefer allocator.free(required);
    for (src.function.parameters.required, 0..) |r, i| {
        required[i] = try allocator.dupe(u8, r);
    }
    errdefer for (required) |r| allocator.free(r);
    return .{
        .type = try allocator.dupe(u8, src.type),
        .function = .{
            .name = try allocator.dupe(u8, src.function.name),
            .description = try allocator.dupe(u8, src.function.description),
            .parameters = .{
                .type = try allocator.dupe(u8, src.function.parameters.type),
                .properties = props,
                .required = required,
            },
            .system_prompt = try allocator.dupe(u8, src.function.system_prompt),
        },
    };
}

/// Free one `AgentTool` previously duped with `dupeAgentTool`.
pub fn freeAgentTool(allocator: std.mem.Allocator, tool: tool_models.AgentTool) void {
    allocator.free(tool.type);
    allocator.free(tool.function.name);
    allocator.free(tool.function.description);
    allocator.free(tool.function.parameters.type);
    for (tool.function.parameters.properties) |p| {
        allocator.free(p.name);
        allocator.free(p.type);
        allocator.free(p.description);
    }
    allocator.free(tool.function.parameters.properties);
    for (tool.function.parameters.required) |r| allocator.free(r);
    allocator.free(tool.function.parameters.required);
    allocator.free(tool.function.system_prompt);
}

/// Free a whole cached slice.
fn freeAgentTools(allocator: std.mem.Allocator, list: []tool_models.AgentTool) void {
    for (list) |t| freeAgentTool(allocator, t);
    allocator.free(list);
}

/// Dupe a whole slice (used for both store + snapshot paths).
fn dupeAgentTools(allocator: std.mem.Allocator, src: []tool_models.AgentTool) ![]tool_models.AgentTool {
    const out = try allocator.alloc(tool_models.AgentTool, src.len);
    errdefer allocator.free(out);
    for (src, 0..) |t, i| {
        out[i] = try dupeAgentTool(allocator, t);
    }
    return out;
}
// ─── Fetch-once MCP tools cache tests (plan: mcp-fetch-once-cache) ───

fn mcpCacheTestTool(allocator: std.mem.Allocator) !tool_models.AgentTool {
    const props = try allocator.alloc(tool_models.ToolProperty, 1);
    props[0] = .{
        .name = try allocator.dupe(u8, "q"),
        .type = try allocator.dupe(u8, "string"),
        .description = try allocator.dupe(u8, "query"),
    };
    const required = try allocator.alloc([]const u8, 1);
    required[0] = try allocator.dupe(u8, "q");
    return .{
        .type = try allocator.dupe(u8, "function"),
        .function = .{
            .name = try allocator.dupe(u8, "mcp_srv_do"),
            .description = try allocator.dupe(u8, "does things"),
            .parameters = .{
                .type = try allocator.dupe(u8, "object"),
                .properties = props,
                .required = required,
            },
            .system_prompt = try allocator.dupe(u8, ""),
        },
    };
}

fn mcpCacheFreeTestTool(allocator: std.mem.Allocator, tool: tool_models.AgentTool) void {
    freeAgentTool(allocator, tool);
}

fn mcpCacheTestCtx() App {
    var ctx: App = undefined;
    ctx.allocator = std.testing.allocator;
    ctx.mcp_tools_cache = null;
    ctx.mcp_tools_init = false;
    ctx.mcp_tools_lock = .unlocked;
    return ctx;
}

test "mcp fetch-once: uninitialized cache returns null snapshot" {
    var ctx = mcpCacheTestCtx();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: store + snapshot roundtrip with deep-dupe isolation" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    defer ctx.clearMcpToolsCache();
    try std.testing.expect(ctx.isMcpToolsInit());
    const snap = ctx.getMcpToolsCached(std.testing.allocator) orelse return error.SnapshotMiss;
    defer {
        for (snap) |s| freeAgentTool(std.testing.allocator, s);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("mcp_srv_do", snap[0].function.name);
    // Snapshots must be independently duped (not aliased to the cache):
    // different backing pointers prove the deep dupe.
    try std.testing.expect(snap[0].function.name.ptr != ctx.mcp_tools_cache.?[0].function.name.ptr);
    try std.testing.expect(snap[0].function.parameters.properties.ptr != ctx.mcp_tools_cache.?[0].function.parameters.properties.ptr);
}

test "mcp fetch-once: clear resets to uninitialized" {
    var ctx = mcpCacheTestCtx();
    const src = try std.testing.allocator.alloc(tool_models.AgentTool, 1);
    defer std.testing.allocator.free(src);
    src[0] = try mcpCacheTestTool(std.testing.allocator);
    defer mcpCacheFreeTestTool(std.testing.allocator, src[0]);
    ctx.storeMcpToolsCache(src, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    ctx.clearMcpToolsCache();
    try std.testing.expect(!ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}

test "mcp fetch-once: error publish (mark_init=false) leaves retry open" {
    var ctx = mcpCacheTestCtx();
    ctx.storeMcpToolsCache(null, false);
    try std.testing.expect(!ctx.isMcpToolsInit());
    // A null publish WITH init (no servers configured) is a valid cached state.
    ctx.storeMcpToolsCache(null, true);
    try std.testing.expect(ctx.isMcpToolsInit());
    try std.testing.expect(ctx.getMcpToolsCached(std.testing.allocator) == null);
}
