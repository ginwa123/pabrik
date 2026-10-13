//! Exec wrapper for the `add_mcp_server` agent tool.
//!
//! Composes four steps:
//!   1. Parse the LLM JSON arguments into `AddMcpServerInput`
//!   2. Call the pure-fn primitive `executeAddMcpServerToJSON`, which
//!      validates + mutates the live `LlmConfig.mcp_servers` typed map
//!      and rebuilds `mcpServers_parsed` (the JSON mirror `buildMCPToolsRun`
//!      reads when rebuilding the system prompt each iteration).
//!   3. After a successful primitive, persist the change to disk + hot-
//!      reload `di.llm_config` so subsequent agent iterations see the
//!      new server via `buildMCPToolsRun` (which reads `mcpServers()` from
//!      the live config) — this is the critical live-reload step. The
//!      HTTP PUT endpoint at `pabrik_config_put.zig` uses the same pattern;
//!      see that file for the full write/atomic-swap sequence.
//!   4. Wrap the result in the standard `<tool>...</tool>` envelope.
//!
//! Why the best-effort tools listing lives here (not in the pure fn):
//! the pure fn must be unit-testable in isolation. The listing spawns a
//! child via the global `StdioRegistry`, whose arena is cleaned up only
//! in `deinitGlobal` (process shutdown) — calling it from a unit test
//! leaks arena memory through the test allocator. The exec wrapper
//! runs in production where process-level registry state is the right
//! scope for a child process.
//!
//! Plan: docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
//! Task: task_1787929165057_9 (Step 3 of 7)

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const config_mod = pabrikcore.config;
const add_mcp_server_mod = pabrikcore.add_mcp_server;
const AddMcpServerInput = add_mcp_server_mod.AddMcpServerInput;
const wrapToolOutput = tools.wrapToolOutput;
const error_explain = @import("tools_error_explain.zig");

pub fn execAddMcpServer(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // ── 1. Parse the LLM JSON args ──────────────────────────────────────
    // AddMcpServerInput has a ?[]const Header field reserved for the HTTP
    // sibling task; the default parser handles it fine (Header is a plain
    // {name, value} struct). For stdio entries (the v1 case) the field
    // stays null — the primitive ignores it via its own
    // addMcpServerStdio branch.
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

    // ── 2. Mutate the live config (typed map + JSON mirror) ────────────
    //
    // The pure-fn primitive takes a `*LlmConfig` (mutable). The exec
    // context's `config` is `*const` — constCast is the standard trick
    // for "I know the underlying memory is mutable, the const-ness is
    // just to discourage accidental writes through this pointer". Same
    // pattern as the LlmConfig clone path.
    const config_mut = @constCast(ctx.config);
    const inner = add_mcp_server_mod.executeAddMcpServerToJSON(
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
    //
    // The pure fn returns `{"error":...}` on validation failures. The exec
    // wrapper surfaces these as `success=false` in the standard envelope
    // (so the LLM sees the error rather than a successful wrapper around
    // an error body). The inner JSON is still surfaced in `data` so the
    // LLM can see the per-tool detail.
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

    // ── 4. Persist to disk + hot-reload `di.llm_config` ────────────────
    //
    // On any failure here the in-memory config is already updated (the
    // agent's iteration will see the new server's tools regardless), so
    // we capture the failure reason + log + continue rather than
    // failing the whole tool call. The status string flows into the
    // `<persisted>` block via `substitutePersistedStatus` below.
    //
    // `persistAndReload` ALWAYS returns an owned slice on `ctx.allocator`
    // (allocated via `dupe` or `allocPrint`) so the caller can defer
    // free without branching on which path produced the value.
    const persist_status_owned = persistAndReloadStatus(ctx) catch |err| blk: {
        std.log.warn(
            "add_mcp_server: in-memory mutation succeeded but disk write failed: {s}",
            .{@errorName(err)},
        );
        break :blk ctx.allocator.dupe(u8, "false") catch @as([]u8, &[_]u8{});
    };
    defer ctx.allocator.free(persist_status_owned);
    const persist_status: []const u8 = persist_status_owned;

    // ── 5. Inject the persisted status into the inner JSON. ─────────────
    //
    // The pure-fn payload hard-codes `"persisted":"false"` as a
    // placeholder (it doesn't know whether persistence will happen —
    // that's the exec wrapper's responsibility). We substitute the
    // placeholder with the actual outcome. We assume the placeholder
    // appears EXACTLY once — the inner JSON comes from
    // `successJSON` in tools/add_mcp_server.zig which emits it via a
    // single Stringify call (no duplication).
    //
    // We can do a more precise substitution than "true"/"false": the
    // placeholder is literal `"persisted":"false"`. We replace
    // it with `"persisted":"{status}"` (JSON-escaped). When the
    // status is just "true" or "false" this preserves the LLM-friendly
    // exact shape; when it's "false: <reason>" it carries the failure
    // mode so the LLM can self-correct on retry.
    const inner_with_status = try substitutePersistedStatus(
        ctx.allocator,
        inner,
        persist_status,
    );
    defer ctx.allocator.free(inner_with_status);

    // ── 6. Best-effort tools listing (process-level registry is OK here)
    //
    // SKIP when the exec context has no environment — that's our signal
    // that we're in a unit test, where calling `StdioRegistry.global`
    // would leak arena memory through the test allocator (the global
    // registry's arena is only cleaned up in `deinitGlobal`, which the
    // test process never calls). Production callers always have an env.
    const inner_with_status_and_tools = if (ctx.environment == null)
        inner_with_status
    else
        listAndAppendTools(ctx, inner_with_status, parsed.value.name) catch inner_with_status;

    // ── 7. Wrap the final envelope ─────────────────────────────────────
    const output = try wrapToolOutput(ctx.allocator, "add_mcp_server", tc.function.arguments, true, null, inner_with_status_and_tools);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Substitute the `"persisted":"false"` placeholder in the
/// pure-fn payload with the actual disk-write + live-reload status.
///
/// `inner_json` is the pure-fn output (built by `add_mcp_server.executeAddMcpServerToJSON`).
/// The placeholder appears exactly once — emitted by `successJSON` via a
/// single Stringify call. We swap the placeholder `"persisted":"false"`
/// with `"persisted":"{status}"` where `status` is the caller-provided
/// persist_status (typically `"true"`, `"false"`, or `"false: <reason>"`).
/// The `status` argument is JSON-escaped via Stringify so any embedded
/// `"` or control char doesn't corrupt the payload shape — the caller
/// passes a single line of text from `persistAndReload` and we keep the
/// whole payload well-formed.
///
/// Returns a freshly-allocated slice; caller frees.
fn substitutePersistedStatus(
    allocator: std.mem.Allocator,
    inner_json: []const u8,
    status: []const u8,
) ![]u8 {
    const placeholder = "\"persisted\":\"false\"";

    const idx = std.mem.indexOf(u8, inner_json, placeholder) orelse {
        // Defensive: if the pure-fn payload shape ever drifts and the
        // placeholder is missing, surface a clear error rather than
        // return the unmodified JSON (which would lie to the LLM by
        // saying "persisted=false" when actually unknown).
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
/// `di.llm_config` via `setLlmConfig` so subsequent agent iterations see
/// the new server through `buildMCPToolsRun`. Mirrors the write sequence
/// in `pabrik_config_put.zig` (PUT /api/config/pabrik):
/// read → mutate `mcp_servers` → write → re-parse + swap `llm_config`.
///
/// Returns the status string the agent sees in the `<persisted>` field.
/// The returned slice is owned by `ctx.allocator` — caller frees via
/// `defer`. On success the slice contains `"true"`; on any failure path
/// it contains `"false: <reason>"` (allocated via `allocPrint`).
fn persistAndReloadStatus(ctx: ToolExecContext) ![]u8 {
    const di = pabrikcore.getSingleton() catch return ctx.allocator.dupe(u8, "false: getSingleton failed") catch return ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server failure status");
    // Auth mode: persist into the session owner's users.config_json
    // (Migration 092) instead of config.json, and skip the global
    // live-reload (config is per-user). config.json is never touched.
    if (di.auth_enabled) {
        return persistAuthModeStatus(ctx, di);
    }
    const env_ptr = di.environment orelse return std.fmt.allocPrint(ctx.allocator, "false: environment unavailable", .{}) catch ctx.allocator.dupe(u8, "false") catch @panic("allocPrint failed for the add_mcp_server failure status");
    // getDefaultConfigDir takes a non-const pointer but doesn't mutate.
    const environment: *std.process.Environ.Map = @ptrCast(@constCast(env_ptr));

    const config_dir = config_mod.getDefaultConfigDir(ctx.allocator, environment) catch |err| {
        return failStatus(ctx.allocator, "getDefaultConfigDir", @errorName(err));
    };
    defer ctx.allocator.free(config_dir);

    const config_path = std.fs.path.join(ctx.allocator, &[_][]const u8{ config_dir, "config.json" }) catch |err| {
        return failStatus(ctx.allocator, "path.join", @errorName(err));
    };
    defer ctx.allocator.free(config_path);

    // `getDefaultConfigDir` validates its environment bases, but the calls below
    // are the ones that ASSERT: `openFileAbsolute` / `createFileAbsolute` abort
    // the whole process (Debug/ReleaseSafe) for a relative path. Fail the tool
    // cleanly instead of taking the worker down.
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
    //
    // We use a minimal shape: take the existing JSON if present (to
    // preserve siblings like active_profile / sub_agents / etc.) and
    // update only the `mcp_servers` field. If no existing file, write
    // a fresh JSON containing just the mcp_servers map.
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
    var new_cfg = config_mod.LlmConfig.init(di.allocator, ctx.io, null, env_for_reload) catch |err| {
        return failStatus(ctx.allocator, "live reload parse", @errorName(err));
    };
    new_cfg.validate() catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "live reload validate", @errorName(err));
    };
    const new_ptr = di.allocator.create(config_mod.LlmConfig) catch |err| {
        var mut: *config_mod.LlmConfig = &new_cfg;
        mut.deinit();
        return failStatus(ctx.allocator, "OOM", @errorName(err));
    };
    new_ptr.* = new_cfg;
    pabrikcore.setLlmConfig(di, new_ptr);

    // Fetch-once cache (plan: mcp-fetch-once-cache): lazy-invalidate so
    // the next workflow run refetches once and picks up the new server.
    // The best-effort probe below stays as-is (it warms the stdio child);
    // the tools-list cache itself refreshes on the next run.
    di.clearMcpToolsCache();

    return ctx.allocator.dupe(u8, "true") catch ctx.allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server success status");
}

/// Auth-mode persist for `add_mcp_server`: merge the live `mcp_servers`
/// into the session owner's `users.config_json` (Migration 092).
/// The owner resolves via `sessions.user_id`; ownerless/unknown
/// sessions fail the persist (the in-memory mutation from step 2 still
/// applies to the current run). Skips the global live-reload — config
/// is per-user in auth mode — but invalidates the MCP tools cache.
/// Returns an owned status slice on `ctx.allocator` (`"true"` or
/// `"false: <reason>"`), same contract as `persistAndReloadStatus`.
fn persistAuthModeStatus(ctx: ToolExecContext, di: *pabrikcore.App) ![]u8 {
    const user_config_store = pabrikcore.user_config_store;
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

/// Build a `<persisted>false: <op> <reason></persisted>`-shaped
/// failure status. The result is owned by `allocator` — caller frees.
/// Falls back to a literal "false" copy on OOM (allocPrint failure) so
/// the caller doesn't have to handle the inner failure.
fn failStatus(allocator: std.mem.Allocator, op: []const u8, reason: []const u8) []u8 {
    return std.fmt.allocPrint(
        allocator,
        "false: {s} {s}",
        .{ op, reason },
    ) catch allocator.dupe(u8, "false") catch @panic("dupe failed for the add_mcp_server failure status");
}

/// Build the on-disk JSON body for the new config. Strategy:
///   - If `existing` is non-null, parse it as a generic `std.json.Value`,
///     copy each (key, value) pair into a fresh ObjectMap (skipping the
///     stale `mcp_servers` entry), put the LIVE `LlmConfig.mcpServers()`
///     under `mcp_servers`, then serialize the fresh map.
///   - If `existing` is null, serialize just `{"mcp_servers": ...}`.
///
/// Ownership rules (D2 in the plan):
///   - The keys in the fresh map are duped strings — we free them after
///     Stringify.valueAlloc deep-copies the structure into a serialized
///     buffer.
///   - The values in the fresh map are **borrowed** from either
///     `parsed.value` (existing config) or `ctx.config.mcpServers()`
///     (live config). ObjectMap.deinit does NOT free values, so the
///     borrowed ObjectMap entries survive — when we serialize, the
///     output is independent.
///   - The borrowed source values' lifetimes are managed by the
///     `defer parsed.deinit()` and the live-config's mirror. Neither is
///     freed by `new_obj.deinit()`, so no use-after-free.
///
/// Why this avoids the F2 leak (the previous version's deep-copy-
/// through-Stringify→parseFromSlice wasted an arena allocation +
/// orphaned the source tree on the success path).
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
                // Build the new map. Keys are duped; values are borrowed
                // from `parsed.value` (the existing on-disk shape) or
                // from `live_mcp_servers` (the just-updated typed map's
                // JSON mirror — owned by ctx.config).
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

                // Serialize FIRST (deep-copies the structure into
                // a flat string buffer), THEN free the source map.
                // F2 fix: the previous version's deep-copy-
                // through-parseFromSlice orphaned new_obj + all its
                // duped keys on the success path.
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
// refactor (skip + replace the `mcp_servers` key during the walk) no
// longer needs to deep-free old values — the borrowed old value goes
// back to `parsed` whose `deinit()` handles the cleanup at scope exit.

// ───────────────────────────────────────────────────────────────────────
// Best-effort tools listing (post-mutation)
// ───────────────────────────────────────────────────────────────────────

/// Spawn the just-added server and run a `tools/list` JSON-RPC roundtrip,
/// filling the `tools` array of the success payload. On any failure
/// (spawn / send / recv / parse), the original inner JSON is returned
/// unchanged — the server IS registered, this is just a courtesy.
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
    const reg = pabrikcore.mcpStdioRegistry(ctx.allocator);
    var lease = reg.acquire(server_name, argv, .{}) catch return inner_json;
    defer lease.release();
    const client = lease.client();
    const req = ctx.allocator.dupe(u8,
        \\{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}
    ) catch return inner_json;
    defer ctx.allocator.free(req);
    // 60s deadline matches `handle_mcp_tool.zig:79` and
    // `prompts_build_messages_for_agent_prompt.zig:637`. Without a
    // deadline, a hung child (deadlock, waiting on stdin forever)
    // blocks the tool-exec handler indefinitely — same blocking
    // behaviour the stdio transport had before PR #373. On
    // SendTimeout / RecvTimeout the stale child is killed so the next
    // `acquire` respawns a fresh process.
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
    // in the client's own arena (`client.allocator()`), not in
    // `ctx.allocator`. Freeing it here would hand a foreign pointer to
    // the wrong allocator — an invalid free under DebugAllocator, and
    // heap corruption in production. The arena reclaims it when the
    // child is respawned or the registry shuts down.

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

const migration = @import("../migrations/migration.zig");

const TestCtx = struct {
    db: pabrikcore.sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn makeTestCtx(allocator: std.mem.Allocator, db: *pabrikcore.sqlite.SqliteBackend) ToolExecContext {
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

fn fixtureConfig(allocator: std.mem.Allocator) !config_mod.LlmConfig {
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
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
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
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"hello","transport":"stdio","command":"mcp-hello-world","args":["--port","3001"]}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env_parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env_parsed.deinit();
    const env = env_parsed.value.object;
    try testing.expectEqualStrings("add_mcp_server", env.get("tool").?.string);
    try testing.expect(env.get("success").?.bool);
    try testing.expect(env.get("error").? == .null);
    // The pure-fn payload is surfaced in `data`.
    const data = env.get("data").?.object;
    try testing.expectEqualStrings("hello", data.get("name").?.string);
    try testing.expectEqualStrings("mcp-hello-world", data.get("command").?.string);
    const args = data.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqualStrings("--port", args.items[0].string);

    // Live config mutated.
    try testing.expect(cfg.hasMcpServer("hello"));
    const server = cfg.mcpServerConfig("hello").?;
    try testing.expectEqualStrings("mcp-hello-world", server.command.?);
}

// ─── Test 2: malformed JSON args → wrapped parse error ─────────────────

test "execAddMcpServer: malformed JSON args → wrapped error envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server", "{not json at all");

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env2 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env2.deinit();
    try testing.expect(!env2.value.object.get("success").?.bool);
    // The message must tell the model WHAT was wrong with its JSON, not
    // just name the Zig error. `{not json at all` is a syntax error, so
    // the explanation names JSON and the usual causes.
    const mcp_err = env2.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, mcp_err, "JSON") != null);
    try testing.expect(std.mem.indexOf(u8, mcp_err, "SyntaxError") == null);

    // No server added.
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 3: empty name (validation error) → wrapped error envelope ─────

test "execAddMcpServer: empty name → wrapped error envelope (success=false)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    var tcx = makeTestCtx(alloc, &ctx.db);
    tcx.config = &cfg;
    const tc = fakeToolCall("add_mcp_server",
        \\{"name":"","transport":"stdio","command":"x"}
    );

    const result = try execAddMcpServer(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    const env3 = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env3.deinit();
    try testing.expect(!env3.value.object.get("success").?.bool);
    try testing.expect(std.mem.indexOf(u8, env3.value.object.get("error").?.string, "name is required") != null);
    // `data` is null on the error path — it lives ONLY on success
    // (see wrapToolOutput). Mirrors save_memory's error contract.
    try testing.expect(env3.value.object.get("data").? == .null);

    // No server added.
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 4: substitutePersistedStatus replaces the placeholder correctly ─
//
// F1 fix regression guard. The pure-fn payload hard-codes
// `"persisted":"false"` as a placeholder (it doesn't know the
// disk-write outcome). This test pins the substitution contract so a
// future drift in `successJSON` (e.g., renaming the placeholder, removing
// it, or duplicating it) gets caught here rather than silently returning
// the wrong status to the LLM.
test "substitutePersistedStatus: replaces placeholder with success status" {
    const alloc = testing.allocator;
    const inner =
        "{\"name\":\"ctx7\"," ++
        "\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "true");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("true", parsed.value.object.get("persisted").?.string);
    // Sibling fields are preserved.
    try testing.expectEqualStrings("ctx7", parsed.value.object.get("name").?.string);
}

test "substitutePersistedStatus: replaces placeholder with failure reason" {
    const alloc = testing.allocator;
    const inner = "{\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "false: createDirPath FileNotFound");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("false: createDirPath FileNotFound", parsed.value.object.get("persisted").?.string);
}

test "substitutePersistedStatus: status with quotes stays valid JSON" {
    const alloc = testing.allocator;
    const inner = "{\"persisted\":\"false\"}";
    const result = try substitutePersistedStatus(alloc, inner, "false: write \"oops\" failed");
    defer alloc.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("false: write \"oops\" failed", parsed.value.object.get("persisted").?.string);
}

test "substitutePersistedStatus: missing placeholder returns error" {
    // F1 defense-in-depth: if the pure-fn payload ever drops the
    // `"persisted":"false"` placeholder, the exec wrapper
    // refuses to substitute a lie and surfaces an error instead.
    const alloc = testing.allocator;
    const inner = "{\"name\":\"ctx7\"}";
    const result = substitutePersistedStatus(alloc, inner, "true");
    try testing.expectError(error.MissingPersistedPlaceholder, result);
}

// F6 caveat: `persistAndReloadStatus` requires `pabrikcore.getSingleton()`
// (the live App) so it can't be unit-tested in isolation —
// the path is exercised end-to-end when an LLM actually calls
// `add_mcp_server` in production. The functional harness boots pabrik
// with a stub LLM that never responds to chat completions, so a
// chat-driven test would have to add a fake LLM harness of its own.
// Out of scope for this PR.
