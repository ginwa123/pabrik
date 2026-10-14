const std = @import("std");
const pabrik = @import("pabrikcore");
const agent = pabrik.agent;
const logger_mod = pabrik.loggermod;
const sqlite = pabrik.sqlite;
const config_mod = pabrik.config;
const tools_equipped = @import("tools_equipped.zig");
const tools = @import("tools.zig");
const llm_history = @import("llm_history.zig");
const SaveSkill = llm_history.saveSkill;
const SaveAgent = @import("save_agent.zig").SaveAgent;
const session_helpers = llm_history;
const get_current_agent_by_session_id = llm_history.get_current_agent_by_session_id;
const tool_models = pabrik.tool_models;
const getLatestMessage = llm_history.getLatestMessage;
const handle_mcp_tool = @import("handle_mcp_tool.zig");
const agentic_loop_mod = @import("workflow.zig");
const wrapToolOutput = agentic_loop_mod.tools.wrapToolOutput;
const xmlUnescape = @import("helpers").xmlUnescape;
const helpers = @import("helpers");
const on_event_sent = @import("on_event_sent.zig");
const parsing = @import("parsing.zig");
const hooks = @import("hooks.zig");
const secrets_substitution = @import("secrets_substitution.zig");
const secrets_store = @import("secrets_store.zig");
const workspace_scope = @import("workspace_scope.zig");
const onEventSendLLMHistory = on_event_sent.onEventSendLLMHistory;
const insertLLMHistories = @import("insert_llm_histories.zig").inserLLMHistories;
const skill_evals_db = @import("skill_evals_db.zig");

// ============================================================================
// TOOL REGISTRY - Single source of truth: tools_equipped.zig
// ============================================================================
//
// The registry used to live in `tool_registry.zig` (deleted). It is now
// defined exclusively in `tools_equipped.zig` — every reference in this
// file (and elsewhere) goes through there. Re-export the alias here for
// downstream callers that still import `handle_tool.TOOL_REGISTRY`.

/// Re-export from the canonical registry (`tools_equipped.zig`).
pub const TOOL_REGISTRY = tools_equipped.UNIFIED_TOOL_REGISTRY;

/// Context passed to all tool handlers
const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    agent_temperature: *f32,
    is_thinking: *bool,
    environment: ?*const std.process.Environ.Map,
    selected_profile_model: []const u8 = "",
    /// See `tools.ToolExecContext.allowed_tools` — the progressive-tool
    /// adapter needs it to know which built-ins are not enabled.
    allowed_tools: []const u8 = "",
    is_sub_agent: bool = false,
    /// The `llm_history` tool-result row for the tool call being dispatched
    /// (the Phase-1 placeholder). See `tools.ToolExecContext.llm_history_id`.
    llm_history_id: []const u8 = "",
};

/// Result of parsing diff_view XML from tool result.
/// If diff_view was found, content_without_diffview is an allocated string (caller must free).
/// Otherwise, content_without_diffview is the original content slice.
pub const DiffViewParseResult = struct {
    /// The content with diff_view section removed (allocated if diff_view found).
    /// Caller must free this if diff_view_found is true.
    content_without_diffview: []const u8,
    /// Whether a diff_view section was found and removed
    diff_view_found: bool,
    /// The before content extracted from <before> tag, XML-unescaped
    /// (`&quot;` → `"`, `&lt;` → `<`, `&gt;` → `>`, `&apos;` → `'`, `&amp;` → `&`).
    /// Null if the tag wasn't found. If `diff_view_found` is true, this is
    /// ALWAYS an allocated buffer that the caller MUST free.
    before: ?[]const u8,
    /// The after content extracted from <after> tag, XML-unescaped (see `before`).
    /// Null if the tag wasn't found. If `diff_view_found` is true, this is
    /// ALWAYS an allocated buffer that the caller MUST free.
    after: ?[]const u8,
};

/// Parses diff_view XML from a text_replace tool result.
/// Extracts before/after content and returns content with diff_view section removed.
/// ALWAYS returns an allocated string for content_without_diffview - caller MUST free it.
pub fn parseDiffViewFromResult(allocator: std.mem.Allocator, content: []const u8) !DiffViewParseResult {
    const dv_start = std.mem.indexOf(u8, content, "<diff_view>");
    const dv_end = std.mem.indexOf(u8, content, "</diff_view>");

    // Even if no diff_view found, return allocated copy of original content
    if (dv_start == null or dv_end == null) {
        const allocated = try std.fmt.allocPrint(allocator, "{s}", .{content});
        return DiffViewParseResult{
            .content_without_diffview = allocated,
            .diff_view_found = false,
            .before = null,
            .after = null,
        };
    }

    const dv_content = content[dv_start.? + 10 .. dv_end.?]; // 10 = len("<diff_view>")

    // Extract before content. Inner slices point into `content` which holds
    // XML-encoded entities (`&quot;`, `&lt;`, ...); we MUST unescape them
    // before returning so the consumer sees the original byte-level content.
    // Without this, a source-code diff with `"` / `<` / `>` / `&` would
    // render literally as `&quot;` / `&lt;` / `&gt;` / `&amp;` in the UI
    // (bug: "diff view shows &quot; instead of ""). See parse_diff_view_test.zig
    // for regression coverage.
    var before_val: ?[]const u8 = null;
    var before_allocated = false;
    if (std.mem.indexOf(u8, dv_content, "<before>")) |b_start| {
        const b_content_start = b_start + 8; // 8 = len("<before>")
        if (std.mem.indexOf(u8, dv_content, "</before>")) |b_end| {
            const raw = dv_content[b_content_start..b_end];
            before_val = try xmlUnescape(allocator, raw);
            before_allocated = true;
            errdefer if (before_allocated) allocator.free(before_val.?);
        }
    }

    var after_val: ?[]const u8 = null;
    var after_allocated = false;
    if (std.mem.indexOf(u8, dv_content, "<after>")) |a_start| {
        const a_content_start = a_start + 7; // 7 = len("<after>")
        if (std.mem.indexOf(u8, dv_content, "</after>")) |a_end| {
            const raw = dv_content[a_content_start..a_end];
            after_val = try xmlUnescape(allocator, raw);
            after_allocated = true;
            errdefer if (after_allocated) allocator.free(after_val.?);
        }
    }

    // Remove diff_view section from content by concatenating before + after parts
    const before_part = content[0..dv_start.?];
    const after_part_start = dv_end.? + 12; // 12 = len("</diff_view>")
    const after_part = if (after_part_start < content.len) content[after_part_start..] else "";
    const content_without_diffview = try std.fmt.allocPrint(allocator, "{s}{s}", .{ before_part, after_part });

    return DiffViewParseResult{
        .content_without_diffview = content_without_diffview,
        .diff_view_found = true,
        .before = before_val,
        .after = after_val,
    };
}

/// Result of executing a tool
const ToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
    progressive_tool_saved: ?ProgressiveToolSaveInfo = null,
    /// See `tools.ToolExecResult.stop_loop` — the tool asked for the turn to
    /// end once this batch is persisted. OR-merged into `ToolBatchOutcome`.
    stop_loop: bool = false,
    /// Secrets this dispatch resolved, so the caller can scrub them back out
    /// of `output` before it is persisted or streamed. Empty when the call
    /// carried no placeholder.
    ///
    /// OWNERSHIP: the CALLER owns this list and must release it with
    /// `freeResolvedSecrets` once it has finished redacting with it. Unlike
    /// `output` — which the agentic loop simply leaves to its request
    /// allocator — these are live credential bytes, so they are freed
    /// deterministically instead of at the end of a turn. The `&.{}` default
    /// frees as a no-op.
    secrets: []const secrets_substitution.ResolvedSecret = &.{},
};

const SkillSaveInfo = struct {
    name: []const u8,
    content: []const u8,
};

const AgentSaveInfo = struct {
    name: []const u8,
};

/// `use_tool` actually INSERTed a `session_progressive_tool` row.
const ProgressiveToolSaveInfo = struct {
    name: []const u8,
    server_name: []const u8,
};

/// Extended result type for main agent tool execution
/// Includes optional temperature/is_thinking for set_agent_properties
const MainAgentToolResult = struct {
    output: []const u8,
    temperature: ?f32 = null,
    is_thinking: ?bool = null,
    skill_saved: ?SkillSaveInfo = null,
    agent_saved: ?AgentSaveInfo = null,
};

// ============================================================================
// Workspace-secret substitution seam (plan 2026-10-02-workspace-secrets)
//
// The promise these helpers carry is two-sided. The executor gets the real
// value (property A) and the model gets `{{SECRETS:NAME}}` back everywhere it
// can read — in `llm_history`, in the persisted tool result, over SSE
// (property B). Substitution alone only satisfies A.
// ============================================================================

/// The prefix every placeholder opens with. Used ONLY as a conservative fast
/// path: `secrets_substitution.matchPlaceholder` cannot produce a match
/// without this exact literal, so a negative answer here can never skip a real
/// placeholder. If the grammar ever changes the only consequence is that we
/// resolve a workspace for calls that did not need one — slower, still
/// correct. It is deliberately NOT a placeholder detector: deciding what counts
/// as a placeholder belongs to `substituteToolArguments` alone, and a second
/// detector that can disagree with it is a correctness bug, not an optimization.
const secrets_placeholder_prefix = "{{SECRETS:";

fn mayContainSecretPlaceholder(args: []const u8) bool {
    return std.mem.indexOf(u8, args, secrets_placeholder_prefix) != null;
}

/// Free a `resolved` list and every string in it. `name` and `value` are each
/// their own allocation. A zero-length list is the "nothing was substituted"
/// default and frees as a no-op.
fn freeResolvedSecrets(allocator: std.mem.Allocator, resolved: []const secrets_substitution.ResolvedSecret) void {
    for (resolved) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(resolved);
}

/// The failure envelope for a substitution that did not happen.
///
/// `args` must be the UN-substituted copy: on the error path
/// `substituteToolArguments` never wrote to its output, so this embeds the
/// placeholder and never a value.
fn secretSubstitutionError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: []const u8,
    resolver: *const SecretResolver,
    err: secrets_substitution.SubstError,
) ![]const u8 {
    const message = switch (err) {
        error.UnknownSecretName => try std.fmt.allocPrint(
            allocator,
            "no secret named '{s}' in this workspace — {{{{SECRETS:{s}}}}} cannot be resolved here. " ++
                "Nothing was run. Ask the user to add that name to this workspace, or use a name that exists; " ++
                "retrying the same placeholder will fail the same way.",
            .{ resolver.missing_name orelse "?", resolver.missing_name orelse "?" },
        ),
        error.InvalidArguments => try std.fmt.allocPrint(
            allocator,
            "arguments were not valid JSON, so no secret could be substituted — nothing was run.",
            .{},
        ),
        // Propagated rather than reported: an OOM here is a real fault, and
        // reporting it as a bad placeholder would send the agent hunting for
        // the wrong problem.
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(message);
    return wrapToolOutput(allocator, tool_name, args, false, message, "");
}

/// Adapts `secrets_store` to `secrets_substitution.Resolver`, with a per-dispatch
/// cache and no database dependency of its own.
///
/// Fail-closed by construction: a session that resolves to no workspace leaves
/// `workspace_id` null, and `resolve` then answers null for every name, which
/// `substituteToolArguments` reports as `error.UnknownSecretName`. There is no
/// path on which an unresolved placeholder reaches an executor as literal text
/// — "no workspace" is never treated as "no substitution needed".
const SecretResolver = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    /// Null = the session belongs to no workspace. Resolved server-side from
    /// the session id, so the model can never choose it.
    workspace_id: ?[]const u8,
    /// One store query per DISTINCT name. A placeholder repeated ten times in
    /// one call must not become ten queries, and the values have to outlive
    /// the resolver call that produced them because `redactOutput` runs later.
    cache: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The most recent name this resolver refused. Read by the error envelope
    /// so it can name the key. It comes from the resolver seam rather than a
    /// second scan of the arguments for the same reason the fast path above
    /// stops at the prefix: only one thing may decide what a placeholder is.
    missing_name: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) SecretResolver {
        return .{
            .allocator = allocator,
            .db = db,
            // Any failure to resolve — no session, no link, no matching
            // workspace, a query error — collapses to "no workspace", which
            // fails every name closed.
            .workspace_id = workspace_scope.resolveWorkspaceId(allocator, db, session_id) catch null,
        };
    }

    fn deinit(self: *SecretResolver) void {
        // `HashMapUnmanaged.deinit` releases the table only, so the entries it
        // does not own are released here.
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
        if (self.missing_name) |name| self.allocator.free(name);
        if (self.workspace_id) |id| self.allocator.free(id);
    }

    fn resolve(self: *SecretResolver, name: []const u8) ?[]const u8 {
        if (self.cache.get(name)) |hit| return if (hit.len == 0) null else hit;

        const workspace_id = self.workspace_id orelse return self.refuse(name);
        const wanted = [_][]const u8{name};
        const rows = secrets_store.loadSecretValues(self.allocator, self.db, workspace_id, &wanted) catch
            return self.refuse(name);
        defer secrets_store.freeSecretValueRows(self.allocator, rows);

        for (rows) |row| {
            // The cache stores copies rather than slices into `rows`, which
            // the defer above releases as soon as this returns. A name is not
            // a secret, so owning it as the key costs nothing.
            const key = self.allocator.dupe(u8, row.name) catch return self.refuse(name);
            const value = self.allocator.dupe(u8, row.value) catch {
                self.allocator.free(key);
                return self.refuse(name);
            };
            self.cache.put(self.allocator, key, value) catch {
                self.allocator.free(key);
                self.allocator.free(value);
                return self.refuse(name);
            };
        }

        // A name this workspace does not store is simply absent from `rows`,
        // which is the same thing as a miss. Only the caller knows which
        // placeholder it asked about, so reporting it is the caller's job.
        return self.cache.get(name) orelse self.refuse(name);
    }

    /// Record which placeholder could not be resolved, then report the miss.
    /// Every allocation failure above lands here too: turning exhaustion into
    /// "unknown secret" misreports the cause, but it never substitutes
    /// something the workspace did not supply, which is the failure that would
    /// actually matter.
    fn refuse(self: *SecretResolver, name: []const u8) ?[]const u8 {
        if (self.missing_name) |previous| self.allocator.free(previous);
        self.missing_name = self.allocator.dupe(u8, name) catch null;
        return null;
    }

    fn lookup(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        // The erased `ctx` is const because the `Resolver` signature says so;
        // the adapter's own state (cache, last miss) is genuinely mutated, so
        // the const is shed here rather than by widening the signature.
        const self: *SecretResolver = @ptrCast(@alignCast(@constCast(ctx orelse return null)));
        return self.resolve(name);
    }
};

/// Lookup a tool by name and execute it using unified registry
/// Refactored: Uses entry.exec() directly instead of double lookup
///
/// Lua hooks (`hooks/register_hook.lua :: init(event, data)`) wrap every
/// dispatch: the pre hook may deny (error envelope, no exec), modify args,
/// or mock the output (no exec); the post hook may replace the output.
/// All hook failures degrade to the no-hook behavior (see hooks.zig).
fn dispatchTool(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    var effective_call = tool_call;
    var modified_args: ?[]const u8 = null;
    defer if (modified_args) |a| ctx.allocator.free(a);

    // Translate a deprecated tool name to its current registry entry
    // (`bash` → `command`) BEFORE the hooks run, so a pre-2026-09-04 name
    // behaves like the tool it now means: same hooks, same exec, same
    // envelope. Resolution is dispatch-only — `UNIFIED_TOOL_REGISTRY` stays
    // the advertised list, so the model is never re-offered `bash`.
    // For a name that needs no translation this is a no-op.
    if (tools_equipped.resolveToolAlias(tool_call.function.name)) |canonical| {
        effective_call.function.name = canonical;
    }

    switch (runPreHookAction(ctx, effective_call.function.name, tool_call.function.arguments)) {
        .proceed => {},
        .proceed_modified => |a| {
            modified_args = a;
            effective_call.function.arguments = a;
        },
        .short_circuit => |out| return ToolResult{ .output = out },
    }

    // ─── Workspace-secret substitution ───
    //
    // Deliberately AFTER the pre-hook: a user-authored Lua hook receives
    // `arguments` and may log or rewrite them, so substituting first would
    // hand plaintext to arbitrary user code with nothing downstream to scrub
    // it. The hook therefore sees `{{SECRETS:NAME}}` and only the executor
    // sees the value. It also runs on whatever the hook produced — a
    // `.proceed_modified` replaced the arguments above, so the original
    // string is not the right input.
    var resolver: SecretResolver = undefined;
    var resolver_live = false;
    defer if (resolver_live) resolver.deinit();

    var sub: secrets_substitution.SubstitutionResult = .{ .substituted_args = "", .resolved = &.{} };
    var sub_live = false;
    defer if (sub_live) {
        ctx.allocator.free(sub.substituted_args);
        freeResolvedSecrets(ctx.allocator, sub.resolved);
    };

    if (mayContainSecretPlaceholder(effective_call.function.arguments)) {
        resolver = SecretResolver.init(ctx.allocator, ctx.db, ctx.session_id);
        resolver_live = true;
        secrets_substitution.substituteToolArguments(
            ctx.allocator,
            effective_call.function.arguments,
            SecretResolver.lookup,
            &resolver,
            &sub,
        ) catch |err| {
            // Never dispatch: an empty substitution would reach the tool and
            // surface much later as an opaque third-party 401. The envelope
            // carries `effective_call.function.arguments`, which
            // `substituteToolArguments` left untouched on the error path, so
            // `parameters` still shows the placeholder rather than a value.
            const envelope = try secretSubstitutionError(ctx.allocator, effective_call.function.name, effective_call.function.arguments, &resolver, err);
            return ToolResult{ .output = envelope };
        };
        sub_live = true;
        effective_call.function.arguments = sub.substituted_args;
    }

    var result: ToolResult = blk: {
        for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| {
            if (std.mem.eql(u8, effective_call.function.name, entry.name)) {
                break :blk try dispatchFromRegistry(ctx, effective_call, entry.exec);
            }
        }

        // Check if it's an MCP tool (format: mcp_serverName_toolName)
        if (isMCPTool(ctx.config, effective_call.function.name)) {
            break :blk try dispatchMCP(ctx, effective_call);
        }

        return error.UnknownTool;
    };

    if (runPostHookOverride(ctx, effective_call.function.name, effective_call.function.arguments, result.output)) |replacement| {
        result.output = replacement;
    }

    // Ownership of the resolved list moves to the caller, which redacts the
    // output with it and then frees it; the defer above must not also do so.
    result.secrets = sub.resolved;
    sub.resolved = &.{};
    return result;
}

/// Outcome of the Lua pre hook for one tool call. Owned strings transfer
/// to the caller (short_circuit becomes the tool output, proceed_modified
/// must be freed after dispatch).
const PreHookAction = union(enum) {
    proceed,
    proceed_modified: []const u8,
    short_circuit: []const u8,
};

fn runPreHookAction(ctx: ToolContext, tool_name: []const u8, arguments: []const u8) PreHookAction {
    const hook_ctx = hooks.HookContext{ .session_id = ctx.session_id, .cwd = ctx.cwd, .model = ctx.model };
    const pre = hooks.runPreHook(ctx.allocator, ctx.logger, ctx.environment, tool_name, arguments, hook_ctx) catch return .proceed;
    switch (pre) {
        .allow => return .proceed,
        .deny => |reason| {
            defer ctx.allocator.free(reason);
            const out = wrapToolOutput(ctx.allocator, tool_name, arguments, false, reason, "") catch return .proceed;
            return .{ .short_circuit = out };
        },
        .modify => |new_args| return .{ .proceed_modified = new_args },
        .mock => |mock_output| {
            defer ctx.allocator.free(mock_output);
            const out = wrapToolOutput(ctx.allocator, tool_name, arguments, true, null, mock_output) catch return .proceed;
            return .{ .short_circuit = out };
        },
    }
}

/// Run the Lua post hook. Returns an owned replacement output, or null to
/// keep `current`. Never errors outward (fail-open inside).
fn runPostHookOverride(ctx: ToolContext, tool_name: []const u8, arguments: []const u8, current: []const u8) ?[]const u8 {
    const hook_ctx = hooks.HookContext{ .session_id = ctx.session_id, .cwd = ctx.cwd, .model = ctx.model };
    const post = hooks.runPostHook(ctx.allocator, ctx.logger, ctx.environment, tool_name, arguments, current, hook_ctx) catch return null;
    switch (post) {
        .keep => return null,
        .replace => |new_output| return new_output,
        .deny => |reason| {
            defer ctx.allocator.free(reason);
            return wrapToolOutput(ctx.allocator, tool_name, arguments, false, reason, "") catch null;
        },
    }
}

/// Dispatch tool execution from registry entry
/// Calls exec directly and handles auto-save via registry flags
fn dispatchFromRegistry(ctx: ToolContext, tool_call: agent.ToolCall, exec: tools_equipped.ToolExecFunc) !ToolResult {
    const ctx_local = tools.ToolExecContext{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .logger = ctx.logger,
        .session_id = ctx.session_id,
        .model = ctx.model,
        .cwd = ctx.cwd,
        .api_key = ctx.api_key,
        .base_url = ctx.base_url,
        .config = ctx.config,
        .agent_temperature = ctx.agent_temperature,
        .is_thinking = ctx.is_thinking,
        .environment = ctx.environment,
        .selected_profile_model = ctx.selected_profile_model,
        // 2026-08-23 spawn-subagent-live-progress: thread the
        // parent's tool_call.id through ToolExecContext so
        // execSpawnSubAgent can emit progress events keyed by it
        // (ChatView.vue's reducer filters on this exact value).
        .tool_call_id = tool_call.id,
        // Progressive tool search: the exec-side catalog computes which
        // built-ins are NOT enabled, which needs the resolved allowlist.
        .allowed_tools = ctx.allowed_tools,
        .is_sub_agent = ctx.is_sub_agent,
        // The Phase-1 placeholder row this result will be written into.
        // Tools that rewrite their own result later (ask_user) need it.
        .llm_history_id = ctx.llm_history_id,
    };
    const exec_result = try exec(ctx_local, tool_call);

    return ToolResult{
        .output = exec_result.output,
        .temperature = exec_result.temperature,
        .is_thinking = exec_result.is_thinking,
        .stop_loop = exec_result.stop_loop,
        .skill_saved = if (exec_result.skill_save) |sk| SkillSaveInfo{ .name = sk.name, .content = sk.content } else null,
        .agent_saved = if (exec_result.agent_save) |ag| AgentSaveInfo{ .name = ag.name } else null,
        .progressive_tool_saved = if (exec_result.progressive_tool_save) |pt| ProgressiveToolSaveInfo{
            .name = pt.name,
            .server_name = pt.server_name,
        } else null,
    };
}

/// Check if a tool name is an MCP tool (format: mcp_serverName_toolName)
fn isMCPTool(config: *const config_mod.LlmConfig, tool_name: []const u8) bool {
    if (config.mcpServers() == null) return false;

    // MCP tool names have format: mcp_{serverName}_{toolName}
    // e.g., mcp_context7_query-docs
    if (!std.mem.startsWith(u8, tool_name, "mcp_")) return false;

    // Find second underscore (after "mcp_") to get server name
    const after_mcp = tool_name["mcp_".len..];
    const underscore_idx = std.mem.indexOf(u8, after_mcp, "_") orelse return false;
    const server_name = after_mcp[0..underscore_idx];

    const mcp_servers = switch (config.mcpServers().?) {
        .object => |obj| obj,
        else => return false,
    };
    return mcp_servers.get(server_name) != null;
}

/// Dispatch an MCP tool call
fn dispatchMCP(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    const result = try handle_mcp_tool.handle_mcp_tool_run(
        ctx.allocator,
        ctx.logger,
        tool_call,
        ctx.config,
    );
    // Return success with tool output
    return ToolResult{ .output = result };
}

/// Check if a tool name is registered (uses unified registry)
pub fn isKnownTool(name: []const u8) bool {
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |*tool| {
        if (std.mem.eql(u8, name, tool.name)) return true;
    }
    return false;
}

/// Check if a tool name is registered or is an MCP tool
///
/// Alias-aware on purpose. `isKnownTool` is the strict registry check;
/// this gate additionally accepts a deprecated name whose target still
/// exists (`bash` → `command`), because the call is going to run. If
/// this function said no for `bash`, Phase 1 would stamp the call as an
/// unknown-tool error and Phase 3 would `continue` past it — the exact
/// silent-drop that made a dead tool call look like a flaky shell.
pub fn isKnownToolOrMCP(name: []const u8, config: *const config_mod.LlmConfig) bool {
    if (tools_equipped.isDispatchableToolName(name)) return true;
    return isMCPTool(config, name);
}

/// Get all tool names as a slice
pub fn getToolNames() []const []const u8 {
    const unified = tools_equipped.UNIFIED_TOOL_REGISTRY();
    const names = comptime blk: {
        var n: [unified.len][]const u8 = undefined;
        for (unified, 0..) |tool, i| {
            n[i] = tool.name;
        }
        break :blk n;
    };
    return &names;
}

/// Tool-result text for a call whose name is neither a registry entry nor an
/// MCP tool. Replaces the bare `"unknown tools"` string, which named neither
/// the offending tool nor any way forward, so the model had no correction to
/// make and simply emitted the same name again on the next turn.
///
/// Two shapes, because the two misses need different answers:
///   - a RETIRED name (`bash`, `pwsh`) gets the replacement named directly —
///     the model reached for it because it was trained on it, and listing
///     ~40 registry names buries the one line it needs;
///   - a name nobody ever had gets the enumeration, since there is no single
///     entry to point at.
///
/// Lists the registry names deliberately: dispatch is registry-scoped (there
/// is no allowlist re-check in `dispatchTool`), so this list is exactly the
/// set of names the dispatcher would accept.
fn unknownToolMessage(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (tools_equipped.retiredToolSuggestion(name)) |replacement| {
        return std.fmt.allocPrint(
            allocator,
            "unknown tool '{s}' — it was retired and is not available in this session; do not call it again. Re-issue the same call as `{s}`.",
            .{ name, replacement },
        );
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const head = try std.fmt.allocPrint(
        allocator,
        "unknown tool '{s}' — it is not available in this session; do not call it again. Available tools: ",
        .{name},
    );
    defer allocator.free(head);
    try out.appendSlice(allocator, head);

    for (tools_equipped.UNIFIED_TOOL_REGISTRY(), 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, entry.name);
    }
    try out.appendSlice(allocator, ". Call one of those names exactly.");

    return out.toOwnedSlice(allocator);
}

// ============================================================================
// HELPER FUNCTIONS - XML Parsing
// ============================================================================

fn parseSkillFromResult(result: []const u8) ?struct { name: []const u8, content: []const u8 } {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<skill_name>") orelse return null;
    const name_begin = name_start + "<skill_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</skill_name>") orelse return null;
    const skill_name = result[name_begin .. name_begin + name_end];

    const content_start = std.mem.indexOf(u8, result, "<content>") orelse return null;
    const content_begin = content_start + "<content>".len;
    const content_end = std.mem.indexOf(u8, result[content_begin..], "</content>") orelse return null;
    const skill_content = result[content_begin .. content_begin + content_end];

    return .{ .name = skill_name, .content = skill_content };
}

fn parseAgentFromResult(result: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, result, "<loaded>true</loaded>") == null) return null;

    const name_start = std.mem.indexOf(u8, result, "<agent_name>") orelse return null;
    const name_begin = name_start + "<agent_name>".len;
    const name_end = std.mem.indexOf(u8, result[name_begin..], "</agent_name>") orelse return null;
    return result[name_begin .. name_begin + name_end];
}

// ============================================================================
// MAIN HANDLER - Clean dispatch using registry
// ============================================================================

/// Longest `last_activity_description` written by `touchWorkerActivity`.
/// The column is a human-facing label rendered in the UI, so it is capped
/// rather than allowed to grow with an arbitrarily large argument blob.
const worker_activity_desc_max = 120;

/// Stamp `worker.last_activity_nano` + a short "what is it doing" label for
/// the worker running `session_id`, and emit the SSE `worker_updated` event.
///
/// The worker row is keyed by `id == session_id` (see `update_worker.zig`),
/// which is why the session id is the handle here rather than a separate
/// worker id.
///
/// The description is `Tool call: <name>` plus the leading argument fragment
/// when one is present, so the UI can say "Tool call: bash" rather than just
/// "running". Arguments are truncated at `worker_activity_desc_max` bytes on a
/// char boundary — never mid-codepoint, which would write invalid UTF-8 into
/// a TEXT column.
fn touchWorkerActivity(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    tool_name: []const u8,
    arguments: []const u8,
) !void {
    // A worker row only exists while a run is in flight. Absence is the
    // normal case for a sub-agent's parent (whose row was already deleted)
    // and for any call made outside a worker, so this is not an error.
    var probe = try db.query(allocator, "SELECT 1 FROM worker WHERE id = ? LIMIT 1", &.{session_id});
    defer probe.deinit();
    const row = try probe.next();
    defer if (row) |r| r.deinit(allocator);
    if (row == null) return;

    const desc = try buildWorkerActivityDescription(allocator, tool_name, arguments);
    defer allocator.free(desc);

    try llm_history.updateWorkerActivityWithDescription(allocator, db, session_id, desc);
}

/// `Tool call: <name>` + a truncated leading slice of `arguments`.
/// Returns an allocated string the caller owns.
fn buildWorkerActivityDescription(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: []const u8,
) ![]u8 {
    const prefix = "Tool call: ";
    const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, tool_name });
    }

    // Leave room for the prefix, the tool name, the separating space and the
    // ellipsis. The ellipsis is 3 bytes in UTF-8, so it has to be counted in
    // bytes or the cap is overshot by two.
    const ellipsis_bytes = 3;
    const budget = worker_activity_desc_max - prefix.len - tool_name.len - 1 - ellipsis_bytes;
    if (budget <= 0) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, tool_name });
    }

    const take = @min(trimmed.len, budget);
    // Back off to a char boundary so the slice stays valid UTF-8. The guard
    // matters: when `take` lands exactly on `trimmed.len` there is no byte at
    // that index to inspect, and the whole slice is already valid.
    var end = take;
    while (end > 0 and end < trimmed.len and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    const ellipsis: []const u8 = if (end < trimmed.len) "…" else "";
    return std.fmt.allocPrint(allocator, "{s}{s} {s}{s}", .{ prefix, tool_name, trimmed[0..end], ellipsis });
}

/// What `handle_tool` reports back to the workflow loop.
///
/// A plain `void` was enough while every tool was fire-and-forget. `is_stop`
/// makes one tool's result a LOOP decision, and the workflow loop is the only
/// place allowed to act on it — so the request travels back as data rather
/// than as a side effect the loop would have to re-read from the DB.
pub const ToolBatchOutcome = struct {
    /// At least one tool in the batch asked to end the turn
    /// (`command`'s `is_stop`). OR-merged across the batch: the batch is
    /// always dispatched and persisted in full first, because every
    /// `tool_call_id` needs its `role=tool` row or the provider rejects the
    /// next turn (see the Phase-1 placeholder note in `handle_tool`).
    stop_loop: bool = false,
};

pub fn handle_tool(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    parent_session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: *f32,
    isThinking: *bool,
    api_key: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    environment: ?*const std.process.Environ.Map,
    selected_profile_model: []const u8,
    // Passed straight through to `ToolExecContext`. Zig has no default
    // parameter values, so every caller must supply them; `workflow.zig`
    // does. The tool-result envelope stays the same either way.
    allowed_tools: []const u8,
    is_sub_agent: bool,
) !ToolBatchOutcome {
    var outcome: ToolBatchOutcome = .{};

    if (res_dynamic_agent.tool_calls) |tc| {
        // ─── Phase 1: INSERT placeholder rows for ALL known tools ───
        //
        // This is the critical fix for the "Invalid function ID" bug.
        // We pre-create every role=tool row BEFORE running any tool,
        // so the OpenAI API contract (every tool_call_id must have a
        // matching role=tool row) is satisfied even if the app
        // crashes mid-execution. The dispatch loop in Phase 3 then
        // UPDATEs each placeholder in place with the actual result.
        //
        // Unknown tools skip the placeholder (they're skipped below
        // too — the original code's behaviour is preserved).
        //
        // Migrated from the old 2-phase pattern (assistant message
        // INSERT then per-tool saveMessage) which left orphaned
        // tool_call_ids on crash. See plan:
        // docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md

        // ─── Phase 2: INSERT the assistant message (existing code) ───
        //
        // The assistant message declares tool_calls=[A, B, C] and has
        // existing tool_call_id columns that match the placeholders
        // by id. The DB now has 1 assistant row + N placeholder rows.
        //
        // NOTE: the conversation order is "placeholders first, then
        // assistant message" by created_at. This is OK because the LLM
        // API contract matches tool_call_ids by VALUE, not by row
        // order. The LLM sees a complete set of (placeholder, assistant)
        // records either way. The ordering matters for the LLM's
        // understanding of the conversation flow, but an empty
        // placeholder content followed by an assistant message is
        // semantically equivalent to "the agent is mid-execution".
        var has_known_tools = false;
        for (tc) |tool_call| {
            if (isKnownToolOrMCP(tool_call.function.name, config)) {
                has_known_tools = true;
                break;
            }
        }
        if (!has_known_tools) {
            logger.infoFmt("[HANDLE_TOOL] All tool calls are unknown — placeholders were written as error envelopes", .{});
        }

        // Build tool names list and save assistant message
        var toolNames = try std.ArrayList([]const u8).initCapacity(allocator, tc.len);
        defer toolNames.deinit(allocator);
        for (tc) |tc_| {
            _ = try toolNames.append(allocator, tc_.function.name);
        }

        const current_agent_state = try get_current_agent_by_session_id(allocator, db, session_id);
        const current_agent_for_save = current_agent_state.agent;

        _ = try llm_history.saveMessage(allocator, io, db, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = res_dynamic_agent.content,
            .reasoning_content = res_dynamic_agent.reasoning_content,
            .reasoning_id = res_dynamic_agent.reasoning_id,
            .reasoning_encrypted_content = res_dynamic_agent.reasoning_encrypted_content,
            .role = agent.Role.assistant.to_str(),
            .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else null,
            .tool_calls = tc,
            .tool_call_id = null,
            .agent_name = current_agent_for_save,
            .loop_index = loop_counter,
            .temperature = agent_temperature.*,
            .is_thinking = isThinking.*,
            .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
            .completion_tokens = res_dynamic_agent.usage.completion_tokens,
            .total_tokens = res_dynamic_agent.usage.total_tokens,
            .cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
            .cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
            .is_input = true,
            .is_output = false,
            .tool_name = try std.mem.join(allocator, ",", toolNames.items),
            .parent_id = parent_session_id,
            .parent_session_id = parent_session_id,
        });

        // Send SSE for assistant message
        try sendSSEForLatestMessage(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, true, false, tc);

        var list_id_that_was_loaded: std.ArrayList([]const u8) = .empty;

        for (tc) |tool_call| {
            // Phase 1 placeholder content: build the canonical
            // `<tool>...</tool>` envelope via `wrapToolOutput` so the
            // frontend's `tryUnwrapToolOutput` can parse it on
            // page-refresh-mid-execution AND on the live-SSE path.
            //
            //  - Unknown tools (registry miss) → `success=false` envelope
            //    with `<error>unknown tools</error>` so the chat card
            //    shows a structured error block instead of a raw text
            //    bubble. Previously the raw string "unknown tools" was
            //    stored verbatim in `response_content`; the frontend
            //    then tried to unwrap it as a `<tool>` envelope and
            //    fell back to the `msg.content` legacy path, rendering
            //    an empty card.
            //  - Known tools (including MCP) → `success=true` envelope
            //    with empty `<data></data>`. Phase 3 will UPDATE the
            //    same row in place with the actual exec result. The
            //    empty `<data>` block is intentional — it keeps the
            //    envelope shape stable so the frontend never sees a
            //    "raw text" / "envelope" branch flip mid-flight.
            //
            // `wrapToolOutput` always emits `<name>` + `<parameters>`,
            // so any tool-output Vue component (the `v-else-if` chain
            // at ChatView.vue:2857-3094) can render a sensible
            // placeholder card (tool name + arguments) while it waits
            // for Phase 3 to land. Previously the bare empty content
            // caused `innerToolData()` to fall back to `msg.content`,
            // which was `""` — the card rendered blank.
            const placeholder = if (!isKnownToolOrMCP(tool_call.function.name, config)) blk: {
                // Same actionable text Phase 3 writes. The placeholder is what
                // a crash-mid-flight or a stale-result sweep leaves behind, so
                // a vague "unknown tools" here outlives the failure and is
                // what the human sees on refresh.
                const msg = try unknownToolMessage(allocator, tool_call.function.name);
                defer allocator.free(msg);
                break :blk try wrapToolOutput(
                    allocator,
                    tool_call.function.name,
                    tool_call.function.arguments,
                    false,
                    msg,
                    "",
                );
            } else try wrapToolOutput(
                allocator,
                tool_call.function.name,
                tool_call.function.arguments,
                true,
                null,
                "",
            );
            // `insertLLMHistories` duplicates the content slice
            // internally (line 123 of insert_llm_histories.zig), so
            // we own and free the envelope string after the call
            // returns — the DB row holds its own copy.
            defer allocator.free(placeholder);

            const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
            const id_llm_history = try insertLLMHistories(.{
                .allocator = allocator,
                .io = io,
                .db = db,
                .logger = logger,
                .is_emit_sse = false,
                .event_bus = null,
                .cwd = cwd,
                .entity = .{
                    .id = created_at,
                    .session_id = session_id,
                    .model = model,
                    .response_content = placeholder,
                    .reasoning_content = null,
                    .role = agent.Role.tool.to_str(),
                    .finish_reason = agent.FinishReason.tool.to_str(),
                    .tool_calls_json = "",
                    .tool_call_id = tool_call.id,
                    .agent = current_agent_state.agent,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature.*,
                    .is_thinking = isThinking.*,
                    .prompt_tokens = 0,
                    .completion_tokens = 0,
                    .total_tokens = 0,
                    .parent_id = parent_session_id,
                    .parent_session_id = parent_session_id,
                    .is_input = false,
                    .is_output = true,
                    .image_urls = null,
                    .created_at = created_at,
                    .is_feed_to_llm = true,
                    .tool_name = tool_call.function.name,
                },
            });
            try list_id_that_was_loaded.append(allocator, id_llm_history);
        }

        // 2026-09-01 fix: emit placeholder SSE immediately so the
        // frontend has a tool message to attach live progress to.
        // Without this, spawn_sub_agent's `role="subagent_progress"`
        // events arrive but there's no <SpawnSubAgent> component yet
        // (it only mounts for tool messages), so the card stays at
        // "0 sub-agents" until the final <results> envelope lands
        // minutes later. Emitting here gives the card an empty-data
        // envelope (agents.length==0) that flips to inLiveMode when
        // progress arrives.
        for (list_id_that_was_loaded.items) |pid| {
            sendSSEForMessageById(allocator, db, session_id, cwd, current_agent_for_save, parent_session_id, agent_temperature.*, isThinking.*, false, true, pid) catch |err| {
                logger.warnFmt("Failed to emit placeholder SSE for {s}: {s}", .{ pid, @errorName(err) });
            };
        }

        // Build context for dispatch
        var ctx = ToolContext{
            .allocator = allocator,
            .io = io,
            .db = db,
            .logger = logger,
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .api_key = api_key,
            .base_url = base_url,
            .config = config,
            .agent_temperature = agent_temperature,
            .is_thinking = isThinking,
            .environment = environment,
            .selected_profile_model = selected_profile_model,
            .allowed_tools = allowed_tools,
            .is_sub_agent = is_sub_agent,
        };

        // ─── Phase 3: dispatch each tool & UPDATE placeholder in place ───
        //
        // For each tool_call, we run the tool (catching errors) and
        // UPDATE the placeholder row with the actual result (or the
        // error message). The placeholder's id is unchanged, so the
        // SSE listener (which reads the latest message) sees an
        // in-place update.
        //
        // If the app crashes mid-dispatch, the stranded placeholders
        // are picked up by `resolveStaleLoadingToolResults` on the
        // next worker loop start (called from workflow.zig).
        var idx: usize = 0;
        for (tc) |tool_call| {
            const id_llm_history = list_id_that_was_loaded.items[idx];
            idx += 1;
            // Let the tool see its own result row — `ask_user` stores this id
            // so the answer endpoint can rewrite it in place later. `ctx` is
            // passed by value to the dispatchers, so this per-iteration
            // mutation cannot leak into the next tool call.
            ctx.llm_history_id = id_llm_history;
            var tool_result: []const u8 = undefined;
            var toolAgentTemp: f32 = agent_temperature.*;
            var toolIsThinking: bool = isThinking.*;

            // Heartbeat the worker with what it is actually doing.
            //
            // `updateWorker` (the upsert behind `touchCheckpointWorkers`) only
            // runs once before the loop and once per iteration, so a single
            // long tool call left `last_activity_nano` frozen for its whole
            // duration. The UI reads that column to decide whether a run is
            // still alive, so a healthy worker mid-tool looked stalled — and
            // the 600s stale-worker cron would reap a run that was working
            // fine. Stamping per tool call is what makes "last activity" mean
            // what the label promises.
            //
            // Best-effort by design: a failed heartbeat must never abort the
            // tool call it is describing. The description is truncated because
            // the column is a human-facing label, not a log.
            touchWorkerActivity(
                allocator,
                db,
                session_id,
                tool_call.function.name,
                tool_call.function.arguments,
            ) catch {};

            // A name that reaches here is genuinely unknown: the tolerated
            // alias (`run_command` → `command`) was already accepted by
            // `isKnownToolOrMCP` above, and the retired shell names (`bash`,
            // `pwsh`) are deliberately NOT accepted so the correction below
            // reaches the model. Write an ACTIONABLE result into the
            // Phase 1 placeholder rather than `continue`-ing. The bare skip
            // left the placeholder's `data:null` + a non-actionable
            // "unknown tools" as the FINAL tool_result, so the model got
            // nothing to correct against and re-emitted the same name four
            // turns running — while the shell card, which renders `data` and
            // never `error`, showed the human a blank bubble. This is the
            // exact "the shell suddenly stopped working" report.
            if (!isKnownToolOrMCP(tool_call.function.name, config)) {
                logger.warnFmt("[HANDLE_TOOL] unknown tool '{s}' — not in the registry or the MCP catalog", .{tool_call.function.name});
                const err_msg = try unknownToolMessage(allocator, tool_call.function.name);
                defer allocator.free(err_msg);
                tool_result = try wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, err_msg, "");
                errdefer allocator.free(tool_result);
                // Nothing was substituted on this path (there is no executor to
                // substitute for), so `resolved` is empty.
                try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, &.{}, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                allocator.free(tool_result);
                continue;
            }

            // Check if this is an MCP tool. Lua hooks apply here too
            // (same pre/post contract as dispatchTool below) so hook
            // authors see every tool call, not just builtin ones.
            if (isMCPTool(config, tool_call.function.name)) {
                var mcp_call = tool_call;
                var mcp_modified_args: ?[]const u8 = null;
                defer if (mcp_modified_args) |a| allocator.free(a);
                switch (runPreHookAction(ctx, tool_call.function.name, tool_call.function.arguments)) {
                    .proceed => {},
                    .proceed_modified => |a| {
                        mcp_modified_args = a;
                        mcp_call.function.arguments = a;
                    },
                    .short_circuit => |out| {
                        tool_result = out;
                        errdefer allocator.free(tool_result);
                        // A short-circuit returns before substitution runs.
                        try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, &.{}, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                        allocator.free(tool_result);
                        continue;
                    },
                }

                // ─── Workspace-secret substitution (MCP) ───
                //
                // MCP tools are intercepted here and `continue`d, so they NEVER
                // reach `dispatchTool`. A hook placed only there would silently
                // not cover them — and an API-key-authenticated MCP call is the
                // most likely place a user reaches for a credential at all.
                // Same position as in `dispatchTool`: after the pre-hook, on
                // whatever the hook produced.
                var mcp_resolver: SecretResolver = undefined;
                var mcp_resolver_live = false;
                defer if (mcp_resolver_live) mcp_resolver.deinit();

                var mcp_sub: secrets_substitution.SubstitutionResult = .{ .substituted_args = "", .resolved = &.{} };
                var mcp_sub_live = false;
                defer if (mcp_sub_live) {
                    allocator.free(mcp_sub.substituted_args);
                    freeResolvedSecrets(allocator, mcp_sub.resolved);
                };

                if (mayContainSecretPlaceholder(mcp_call.function.arguments)) {
                    mcp_resolver = SecretResolver.init(allocator, ctx.db, ctx.session_id);
                    mcp_resolver_live = true;
                    secrets_substitution.substituteToolArguments(
                        allocator,
                        mcp_call.function.arguments,
                        SecretResolver.lookup,
                        &mcp_resolver,
                        &mcp_sub,
                    ) catch |err| {
                        // Never call the MCP server with a literal placeholder
                        // or an empty credential. `mcp_call.function.arguments`
                        // is untouched on the error path, so the envelope shows
                        // the placeholder.
                        const envelope = try secretSubstitutionError(allocator, mcp_call.function.name, mcp_call.function.arguments, &mcp_resolver, err);
                        tool_result = envelope;
                        errdefer allocator.free(tool_result);
                        try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, mcp_call, tool_result, &.{}, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                        allocator.free(tool_result);
                        continue;
                    };
                    mcp_sub_live = true;
                    mcp_call.function.arguments = mcp_sub.substituted_args;
                }

                // Call MCP handler
                tool_result = handle_mcp_tool.handle_mcp_tool_run(
                    allocator,
                    logger,
                    mcp_call,
                    config,
                ) catch |err| {
                    const err_msg = try std.fmt.allocPrint(allocator, "MCP tool {s} failed: {s}", .{
                        mcp_call.function.name,
                        @errorName(err),
                    });
                    // The envelope embeds `mcp_call.function.arguments`, which
                    // now holds the substituted value, so this site scrubs it.
                    tool_result = try wrapToolOutput(allocator, mcp_call.function.name, mcp_call.function.arguments, false, err_msg, "");
                    errdefer allocator.free(tool_result);
                    try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, mcp_call, tool_result, mcp_sub.resolved, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                    allocator.free(tool_result);
                    continue;
                };
                if (runPostHookOverride(ctx, mcp_call.function.name, mcp_call.function.arguments, tool_result)) |replacement| {
                    tool_result = replacement;
                }
                try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, mcp_call, tool_result, mcp_sub.resolved, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                continue;
            }

            // Dispatch to the appropriate handler
            const exec_result = dispatchTool(ctx, tool_call) catch |err| {
                std.debug.print("DEBUG: dispatchTool failed with error: {s}\n", .{@errorName(err)});
                const err_msg = try std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
                    tool_call.function.name,
                    @errorName(err),
                });
                tool_result = try wrapToolOutput(allocator, tool_call.function.name, tool_call.function.arguments, false, err_msg, "");
                errdefer allocator.free(tool_result);
                // `dispatchTool` reports a failed substitution as a result
                // envelope rather than an error, so reaching here means it
                // errored before or outside the substitution and `resolved` is
                // empty. The envelope's `parameters` come from the raw
                // `tool_call`, which keeps the placeholder in the DB (property
                // B).
                try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, &.{}, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
                allocator.free(tool_result);
                continue;
            };

            tool_result = exec_result.output;
            // Loop control (`command`'s `is_stop`). Merged here, in Phase 3,
            // so the value can only be set by a tool that ACTUALLY RAN — a
            // call rejected as an unknown tool or denied by a hook cannot end
            // the turn.
            if (exec_result.stop_loop) outcome.stop_loop = true;
            // `exec_result.secrets` is ours to release once the result has been
            // scrubbed; the catch above `continue`s, so nothing registers it
            // on a path that never got a result.
            defer freeResolvedSecrets(allocator, exec_result.secrets);

            // The skill-evals ledger below persists this same string, so the
            // scrub has to happen here as well as at the persist site. Guarded
            // on `resolved.len` so the overwhelmingly common no-placeholder
            // call does not pay for a copy of its whole result. The `defer`
            // is at loop scope, not block scope: `tool_result` keeps pointing
            // at this buffer until the persist site at the bottom.
            var ledger_scrubbed: ?[]u8 = null;
            defer if (ledger_scrubbed) |scrubbed| allocator.free(scrubbed);
            if (exec_result.secrets.len > 0) {
                ledger_scrubbed = try secrets_substitution.redactOutput(allocator, tool_result, exec_result.secrets);
                tool_result = ledger_scrubbed.?;
            }

            // Apply property changes from tool execution
            if (exec_result.temperature) |temp| toolAgentTemp = temp;
            if (exec_result.is_thinking) |think| toolIsThinking = think;

            // Auto-save skill if loaded
            if (exec_result.skill_saved) |skill_info| {
                SaveSkill(allocator, db, logger, session_id, skill_info.name, skill_info.content) catch |err| {
                    logger.errFmt("Failed to save skill '{s}': {s}", .{ skill_info.name, @errorName(err) });
                };
            }

            // Skill Evals usage ledger (Migration 095). Records what this
            // session was OFFERED (`search_skills`) and what it actually READ
            // (`use_skill`), with the hash of the body it read. `session_skills`
            // cannot answer either of those: it keeps only the latest body per
            // (session, skill), has no loop index, and is written by `use_skill`
            // alone. Swallows its own errors — a tool turn must not fail because
            // bookkeeping did (same posture as the two blocks above).
            skill_evals_db.recordSkillToolEvents(allocator, db, logger, .{
                .io = io,
                .session_id = session_id,
                .tool_name = tool_call.function.name,
                .tool_result_json = tool_result,
                .loop_index = loop_counter,
                .llm_history_id = id_llm_history,
            });

            // Auto-save agent if loaded
            if (exec_result.agent_saved) |agent_info| {
                SaveAgent(allocator, db, logger, session_id, agent_info.name) catch |err| {
                    logger.errFmt("Failed to save agent '{s}': {s}", .{ agent_info.name, @errorName(err) });
                };
            }

            // Progressive tool search: `use_tool` records the equip so the
            // NEXT iteration's tool resolution includes it. Persisting here
            // (rather than only inside the exec adapter) means a failure to
            // write is visible as a log line instead of a tool that silently
            // never becomes callable.
            if (exec_result.progressive_tool_saved) |pt| {
                _ = llm_history.saveProgressiveTool(allocator, db, logger, session_id, pt.name, pt.server_name) catch |err| {
                    logger.errFmt("Failed to equip progressive tool '{s}': {s}", .{ pt.name, @errorName(err) });
                };
            }

            // `tool_result` may already be the scrubbed copy if this call
            // resolved a secret; `redactOutput` is idempotent, so passing the
            // same `resolved` again is a no-op walk rather than a second copy.
            try persistRedacted(allocator, io, db, id_llm_history, session_id, cwd, tool_call, tool_result, exec_result.secrets, toolAgentTemp, toolIsThinking, current_agent_for_save, parent_session_id);
        }
    }

    logger.debugFmt("Tool calls processing complete, looping back for next API call...", .{});

    return outcome;
}

/// Persist a tool result with every resolved secret put back behind its
/// placeholder, then release the scrubbed copy.
///
/// This is the boundary that makes property B true. `shell.zig`'s
/// `result_to_json` puts `result.command` — the fully substituted command —
/// into the result `data`, so `curl -H "Auth: {{SECRETS:gh}}"` hands the real
/// token straight back to the model and from there into `llm_history` and the
/// next provider request. Redaction is the feature, not hardening.
///
/// EVERY Phase-3 persist site goes through here, including the ones where
/// nothing was substituted: passing an empty `resolved` takes the fast path
/// below, which avoids `redactOutput`'s copy of a result that has nothing to
/// scrub. `updateAndSendToolResult` is called from exactly one place (this
/// function) and the static contract test below pins that count.
fn persistRedacted(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    tool_call: agent.ToolCall,
    result: []const u8,
    resolved: []const secrets_substitution.ResolvedSecret,
    temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: []const u8,
) !void {
    if (resolved.len == 0) {
        return updateAndSendToolResult(allocator, io, db, id, session_id, cwd, tool_call, result, temperature, is_thinking, agent_name, parent_session_id);
    }
    const redacted = try secrets_substitution.redactOutput(allocator, result, resolved);
    defer allocator.free(redacted);
    try updateAndSendToolResult(allocator, io, db, id, session_id, cwd, tool_call, redacted, temperature, is_thinking, agent_name, parent_session_id);
}

fn updateAndSendToolResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    tool_call: agent.ToolCall,
    result: []const u8,
    temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: []const u8,
) !void {
    var diffview_before: ?[]const u8 = null;
    var diffview_after: ?[]const u8 = null;
    var content_modified: []const u8 = result;
    var content_modified_allocated: ?[]u8 = null;

    if (std.mem.eql(u8, tool_call.function.name, "text_replace")) {
        // Parse diff_view from XML result - ALWAYS returns allocated string
        if (parseDiffViewFromResult(allocator, result)) |parsed| {
            diffview_before = parsed.before;
            diffview_after = parsed.after;
            content_modified_allocated = @ptrCast(@constCast(parsed.content_without_diffview));
            content_modified = parsed.content_without_diffview;
        } else |_| {
            // Keep original result on parse error
            content_modified = result;
        }
    }

    // UPDATE the placeholder row in place (created in Phase 1 of
    // handle_tool's 3-phase pattern). The row's id is unchanged, so
    // the SSE listener (which reads the latest message) sees an
    // in-place update.
    //
    // If the placeholder doesn't exist (e.g. an unknown tool was
    // dispatched anyway), updateToolResultById is a silent no-op
    // (0 rows affected) — the old saveMessage would have created a
    // new row, but with the placeholder pattern we prefer to drop
    // the orphan rather than have an unmatched tool result.
    try llm_history.updateToolResultById(allocator, io, db, id, .{
        .content = content_modified,
        .diffview_before = diffview_before,
        .diffview_after = diffview_after,
    });

    // Free the allocated content_after_diff_view.
    // `before` and `after` are also allocations owned by this caller (since
    // parseDiffViewFromResult now always allocates them — so it can unescape
    // XML entities like `&quot;` → `"` before returning the original byte
    // content for storage). See handle_tool.zig parseDiffViewFromResult.
    if (content_modified_allocated) |allocated| {
        allocator.free(allocated);
    }
    if (diffview_before) |before| allocator.free(before);
    if (diffview_after) |after| allocator.free(after);

    // 2026-08-23 B1 fix — emit the SSE for THIS tool's row by its known
    // id. The old code called sendSSEForLatestMessage here, which reads
    // getLatestMessage (last-created row in the session). With N
    // parallel tool calls, completions 1..N-1 all emitted the LAST
    // placeholder's data: empty content + wrong tool_call_id — the
    // frontend showed stale loading cards and TOOLS-pill spam. The row
    // id has been in hand all along (this function's `id` parameter);
    // selecting by it emits each completion's OWN row.
    try sendSSEForMessageById(allocator, db, session_id, cwd, agent_name, parent_session_id, temperature, is_thinking, false, true, id);
}

/// 2026-08-23 B1 fix — emit the SSE for ONE specific llm_history row,
/// selected by its exact id. This is the tool-result path: each
/// placeholder row's id is known (list_id_that_was_loaded), so there is
/// no reason to guess via getLatestMessage — which returns the
/// last-created row in the session and, for multi-tool turns, emitted
/// the WRONG row (empty content + wrong tool_call_id) for every
/// completion except the newest.
fn sendSSEForMessageById(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, cwd: []const u8, agent_name: []const u8, parent_session_id: []const u8, temperature: f32, is_thinking: bool, is_input: bool, is_output: bool, id: []const u8) !void {
    const msgOpt = llm_history.getMessageById(allocator, db, session_id, id) catch |err| {
        logger_mod.debugPrint("SSE_DEBUG: getMessageById failed for session {s} id {s}: {s}\n", .{ session_id, id, @errorName(err) });
        return;
    };
    const msg = msgOpt orelse {
        logger_mod.debugPrint("SSE_DEBUG: no message found for session {s} id {s}\n", .{ session_id, id });
        return;
    };
    defer {
        allocator.free(msg.id);
        allocator.free(msg.session_id);
        allocator.free(msg.model);
        allocator.free(msg.created_at);
        allocator.free(msg.response_content);
        allocator.free(msg.finish_reason);
        allocator.free(msg.role);
        allocator.free(msg.tools);
        if (msg.reasoning_content) |r| allocator.free(r);
        allocator.free(msg.agent);
        allocator.free(msg.session_name);
        allocator.free(msg.tool_name);
        if (msg.parent_session_id) |p| allocator.free(p);
        if (msg.diffview_before) |d| allocator.free(d);
        if (msg.diffview_after) |d| allocator.free(d);
        if (msg.image_urls) |urls| {
            for (urls) |u| allocator.free(u);
            allocator.free(urls);
        }
        if (msg.tool_call_id) |t| allocator.free(t);
    }

    logger_mod.debugPrint("SSE_DEBUG: sending SSE by id for session {s}, id={s}, content='{s}'\n", .{ session_id, msg.id, if (msg.response_content.len > 50) msg.response_content[0..50] else msg.response_content });

    const session_skills_tool = llm_history.getSessionSkills(allocator, db, session_id) catch null;
    defer if (session_skills_tool) |s| for (s) |*skill| {
        allocator.free(skill.skill_name);
        allocator.free(skill.content);
    };

    // DB may hold Option A envelopes; the wire stays plain `.msg`
    // (same unwrap as the insert path + REST handler). Owned dupe —
    // freed below; the emitter only borrows it.
    const wire_content_by_id = parsing.unwrapChatContent(allocator, msg.response_content) catch null;
    defer if (wire_content_by_id) |w| allocator.free(w);

    onEventSendLLMHistory(allocator, .{
        .id = msg.id,
        .session_id = msg.session_id,
        .model = msg.model,
        .cwd = cwd,
        .content = wire_content_by_id orelse msg.response_content,
        .reasoning_content = msg.reasoning_content,
        .role = msg.role,
        .finish_reason = msg.finish_reason,
        // Tool-result rows carry NO tool_calls array — that field is the
        // assistant message's wire format. The old code passed null here
        // too (via sendSSEForLatestMessage's `null` argument).
        .tool_calls_json = null,
        // 2026-09-01 fix: tool_call_id on the wire is the ORIGINAL LLM
        // id (e.g. "call_abc123"), NOT the row id. The row id is already
        // in `msg.id` / `event.id`. Using the row id here broke
        // spawn_sub_agent live progress: progress events are keyed by
        // the original id, but the placeholder's SSE had the row id, so
        // `subAgentProgressMap[msg.tool_call_id]` never matched and the
        // card showed "0 sub-agents" while running. REST (get_llm_histories)
        // already returns the original id; SSE must agree.
        .tool_call_id = msg.tool_call_id orelse msg.id,
        .tool_name = msg.tool_name,
        .agent_name = agent_name,
        .loop_index = msg.loop_index,
        .temperature = temperature,
        .is_thinking = is_thinking,
        .is_input = is_input,
        .is_output = is_output,
        .parent_session_id = parent_session_id,
        .parent_id = session_id,
        .diffview_before = msg.diffview_before,
        .diffview_after = msg.diffview_after,
        .total_tokens = msg.total_tokens,
        .image_url = null,
        .session_skills = session_skills_tool,
    }) catch |err| {
        logger_mod.debugPrint("SSE_DEBUG: on_event_send_new failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
    };
}

fn sendSSEForLatestMessage(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8, cwd: []const u8, agent_name: []const u8, parent_session_id: []const u8, temperature: f32, is_thinking: bool, is_input: bool, is_output: bool, tool_calls_json: ?[]agent.ToolCall) !void {
    // 2026-08-24 wire-shape fix (task_1787590621966_10): the raw array is
    // passed through unchanged — on_event_sent.onEventSendLLMHistory now
    // serializes tool_calls to a JSON STRING internally (single
    // serialization point, all callers fixed at once).

    const latestMessage = getLatestMessage(allocator, db, session_id) catch |err| {
        logger_mod.debugPrint("SSE_DEBUG: getLatestMessage failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        return;
    };
    if (latestMessage) |msg| {
        logger_mod.debugPrint("SSE_DEBUG: sending SSE for session {s}, content='{s}'\n", .{ session_id, if (msg.response_content.len > 50) msg.response_content[0..50] else msg.response_content });

        const session_skills_tool = llm_history.getSessionSkills(allocator, db, session_id) catch null;
        defer if (session_skills_tool) |s| for (s) |*skill| {
            allocator.free(skill.skill_name);
            allocator.free(skill.content);
        };

        // DB may hold Option A envelopes; the wire stays plain `.msg`
        // (same unwrap as the insert path + REST handler). Owned dupe —
        // freed below; the emitter only borrows it.
        const wire_content_latest = parsing.unwrapChatContent(allocator, msg.response_content) catch null;
        defer if (wire_content_latest) |w| allocator.free(w);

        onEventSendLLMHistory(allocator, .{
            .id = msg.id,
            .session_id = msg.session_id,
            .model = msg.model,
            .cwd = cwd,
            .content = wire_content_latest orelse msg.response_content,
            .reasoning_content = msg.reasoning_content,
            .role = msg.role,
            .finish_reason = msg.finish_reason,
            .tool_calls_json = tool_calls_json,
            .tool_call_id = msg.tool_call_id orelse msg.id,
            .tool_name = msg.tool_name,
            .agent_name = agent_name,
            .loop_index = msg.loop_index,
            .temperature = temperature,
            .is_thinking = is_thinking,
            .is_input = is_input,
            .is_output = is_output,
            .parent_session_id = parent_session_id,
            .parent_id = session_id,
            .diffview_before = msg.diffview_before,
            .diffview_after = msg.diffview_after,
            .total_tokens = msg.total_tokens,
            .image_url = null,
            .session_skills = session_skills_tool,
        }) catch |err| {
            logger_mod.debugPrint("SSE_DEBUG: on_event_send_new failed for session {s}: {s}\n", .{ session_id, @errorName(err) });
        };
    } else {
        logger_mod.debugPrint("SSE_DEBUG: no latest message found for session {s}\n", .{session_id});
    }
}

test "parseDiffViewFromResult - no diff_view returns allocated copy" {
    const content = "File modified successfully";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty diff_view at end returns content before diff_view" {
    const content = "Success<diff_view></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts before and after content" {
    const content = "Success<diff_view><before>old content</before><after>new content</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Success!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "old content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "new content"));

    // before / after are always allocated when diff_view_found=true
    // (so xmlUnescape can transform entities).
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - extracts multiline before and after" {
    const content = "Result:<diff_view><before>line1\nline2\nline3</before><after>line1\nmodified\nline3</after></diff_view>:end";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Result::end"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "line1\nline2\nline3"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "line1\nmodified\nline3"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only before tag extracts correctly" {
    const content = "Done<diff_view><before>original</before></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "original"));
    try std.testing.expect(result.after == null);

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - only after tag extracts correctly" {
    const content = "Done<diff_view><after>replacement</after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Done!"));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "replacement"));

    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing closing tag returns allocated copy" {
    const content = "Result<diff_view><before>old</before><after>new</after>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - missing opening tag returns allocated copy" {
    const content = "Result<before>old</before><after>new</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(!result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, content));
    try std.testing.expect(result.before == null);
    try std.testing.expect(result.after == null);

    // ALWAYS free the allocated content
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - empty before and after tags" {
    const content = "Empty<diff_view><before></before><after></after></diff_view>!";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "Empty!"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, ""));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, ""));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - before/after at boundaries" {
    const content = "<diff_view><before>start</before><after>end</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, ""));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "start"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "end"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - diff_view in middle of content" {
    const content = "prefix <diff_view><before>a</before><after>b</after></diff_view> suffix";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(std.mem.eql(u8, result.content_without_diffview, "prefix  suffix"));
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "a"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "b"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

// ============================================================================
// XML unescape regression tests (bug: "diff view shows &quot; instead of \"")
// ============================================================================

test "parseDiffViewFromResult - unescapes &quot; in before/after (regression)" {
    // XML-escaped content (as produced by xmlEscape) must be un-escaped before
    // being stored, so the diff view renders the original characters.
    const content =
        "<diff_view><before>const a = &quot;hello&quot;;</before>" ++
        "<after>const a = &quot;world&quot;;</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.diff_view_found);
    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "const a = \"hello\";"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "const a = \"world\";"));

    // Caller MUST free before/after when diff_view_found is true.
    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes all 5 XML entities" {
    const content =
        "<diff_view><before>" ++
        "&lt;a&gt; &amp; &quot;b&quot; &apos;c&apos;" ++
        "</before><after>" ++
        "&lt;x&gt; &amp; &quot;y&quot; &apos;z&apos;" ++
        "</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "<a> & \"b\" 'c'"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "<x> & \"y\" 'z'"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - no entities, content unchanged (fast path)" {
    // When there's no `&` at all, before/after should be allocated copies
    // with the original content unchanged (fast path in xmlUnescape).
    const content =
        "<diff_view><before>plain text content</before>" ++
        "<after>more plain text</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "plain text content"));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(u8, result.after.?, "more plain text"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - decodes &amp; LAST (no double-decoding)" {
    // `&amp;quot;` is the literal 6-byte sequence representing the entity
    // `&quot;` — NOT a double-encoded `"`. The &amp; replacement must come
    // last, otherwise the prior passes would convert `&amp;quot;` → `"`.
    // Correct: `&amp;quot;` → `&quot;` (literal 6 chars).
    const content =
        "<diff_view><before>encoded &amp;quot;quote&amp;quot;</before></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(u8, result.before.?, "encoded &quot;quote&quot;"));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.content_without_diffview);
}

test "parseDiffViewFromResult - unescapes multiline content with entities" {
    const content =
        "<diff_view><before>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.toString();\n}</before>" ++
        "<after>const fn = &lt;T&gt;(a: &amp;T) {\n" ++
        "  return a.serialize();\n}</after></diff_view>";
    const result = try parseDiffViewFromResult(std.testing.allocator, content);

    try std.testing.expect(result.before != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.before.?,
        "const fn = <T>(a: &T) {\n  return a.toString();\n}",
    ));
    try std.testing.expect(result.after != null);
    try std.testing.expect(std.mem.eql(
        u8,
        result.after.?,
        "const fn = <T>(a: &T) {\n  return a.serialize();\n}",
    ));

    std.testing.allocator.free(result.before.?);
    std.testing.allocator.free(result.after.?);
    std.testing.allocator.free(result.content_without_diffview);
}

// =============================================================================
// Phase 1 placeholder envelope.
//
// 2026-08-24-better-tool-placeholder: Phase 1 inserts used to store
// raw text in `response_content` (`"unknown tools"` for unknown tools,
// `""` for known tools). On page-refresh-mid-execution or restart the
// frontend's `tryUnwrapToolOutput` couldn't parse the row, fell back
// to `msg.content`, and rendered a blank/garbage card. The fix pipes
// every Phase 1 placeholder through `wrapToolOutput` so the envelope
// shape is stable across all 3 phases, and rejects an unknown tool with
// the actionable `unknownToolMessage` rather than the bare
// `"unknown tools"` string, which named neither the offending tool nor
// the valid ones.
// =============================================================================

test "unknownToolMessage names the offending tool and offers the real ones" {
    // A RETIRED name gets the targeted correction rather than the ~40-name
    // menu: the model reached for `bash` because it was trained on it, and
    // the one thing it needs is the name that replaced it.
    const retired_msg = try unknownToolMessage(std.testing.allocator, "bash");
    defer std.testing.allocator.free(retired_msg);

    // Names the tool so the model knows WHICH call was rejected...
    try std.testing.expect(std.mem.indexOf(u8, retired_msg, "unknown tool 'bash'") != null);
    // ...states that the name is gone, so retrying it is pointless...
    try std.testing.expect(std.mem.indexOf(u8, retired_msg, "retired") != null);
    try std.testing.expect(std.mem.indexOf(u8, retired_msg, "do not call it again") != null);
    // ...and names the replacement explicitly. This is the whole point of
    // retiring the alias: "unknown tool" alone left the model with nothing
    // to correct against and it re-emitted `bash` four turns running.
    try std.testing.expect(std.mem.indexOf(u8, retired_msg, "`command`") != null);
    try std.testing.expect(std.mem.indexOf(u8, retired_msg, "Re-issue the same call as") != null);

    // A name nobody ever had still gets the enumeration, so the model can
    // pick a real one instead.
    const made_up_msg = try unknownToolMessage(std.testing.allocator, "totally_made_up_tool");
    defer std.testing.allocator.free(made_up_msg);
    try std.testing.expect(std.mem.indexOf(u8, made_up_msg, "unknown tool 'totally_made_up_tool'") != null);
    try std.testing.expect(std.mem.indexOf(u8, made_up_msg, "command") != null);
    try std.testing.expect(std.mem.indexOf(u8, made_up_msg, "do not call it again") != null);
}

test "wrapToolOutput envelope is round-trip parseable (envelope shape vs frontend)" {
    // Sanity: the known-tool branch envelope can be parsed by the
    // frontend's `unwrapToolOutput` shape (name + parameters +
    // success=true + data=""). Mirrors the wire contract that
    // tools_wrap_output.zig's own tests pin — Phase 1 doesn't need
    // to re-test `wrapToolOutput` itself, just the Phase 1 pick of
    // arguments.
    const envelope = try wrapToolOutput(
        std.testing.allocator,
        "read_file",
        "{\"path\":\"/tmp/foo.txt\"}",
        true,
        null,
        "",
    );
    defer std.testing.allocator.free(envelope);

    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"tool\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"parameters\":{\"path\":\"/tmp/foo.txt\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"success\":true") != null);
    // Empty data — Phase 3 will UPDATE this row with the real result.
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"data\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"error\":null") != null);

    // Unknown tool branch envelope: success=false with the actionable message
    // handle_tool actually writes (not the retired bare "unknown tools").
    const unknown_msg = try unknownToolMessage(std.testing.allocator, "totally_made_up_tool");
    defer std.testing.allocator.free(unknown_msg);
    const err_envelope = try wrapToolOutput(
        std.testing.allocator,
        "totally_made_up_tool",
        "{}",
        false,
        unknown_msg,
        "",
    );
    defer std.testing.allocator.free(err_envelope);

    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "\"tool\":\"totally_made_up_tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "\"error\":\"unknown tool 'totally_made_up_tool'") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_envelope, "\"data\":null") != null);
}

// ============================================================================
// Lua hook seam tests (plan 2026-09-12-hook-lua-pre-post-tool-use, Phase 3)
// ============================================================================
//
// These cover runPreHookAction / runPostHookOverride — the exact helpers
// dispatchTool and the MCP branch call. The helpers only touch
// allocator/logger/environment, so db/config/loops stay `undefined`
// (never dereferenced on these paths; a future touch would crash loudly).
// End-to-end exec-skipping is covered by tests/functional/hooks_lua_test.py.

/// Minimal ToolContext for hook tests: only allocator/logger/environment
/// (+ identity strings) are read by the hook path.
fn hookTestCtx(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    environment: ?*const std.process.Environ.Map,
) ToolContext {
    var temp: f32 = 0.4;
    var thinking: bool = false;
    return ToolContext{
        .allocator = allocator,
        .io = std.testing.io,
        .db = undefined,
        .logger = logger,
        .session_id = "sess_hook_test",
        .model = "test-model",
        // Nonexistent cwd isolates the project-hook tier: no stray
        // <cwd>/.pabrik/hooks/register_hook.lua can interfere.
        .cwd = "/tmp/pabrik-hook-test-no-such-dir-xyz",
        .api_key = "",
        .base_url = "",
        .config = undefined,
        .agent_temperature = &temp,
        .is_thinking = &thinking,
        .environment = environment,
    };
}

/// HOME=tmpdir with hooks/register_hook.lua containing `lua_source`.
/// Returns the env map (caller frees map + tmpdir via cleanup).
const HookFixture = struct {
    env_map: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    home: []const u8, // slice into path_buf below — keep alive via tmp

    fn deinit(self: *HookFixture) void {
        self.env_map.deinit();
        self.tmp.cleanup();
    }
};

fn hookFixture(allocator: std.mem.Allocator, lua_source: []const u8, path_buf: *[std.Io.Dir.max_path_bytes]u8) !HookFixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const n = try tmp.dir.realPath(std.testing.io, path_buf);
    const home = path_buf[0..n];
    var env_map = try hooks.globalHookEnvForTest(allocator, std.testing.io, tmp.dir, home, lua_source);
    errdefer env_map.deinit();
    return HookFixture{ .env_map = env_map, .tmp = tmp, .home = home };
}

test "hook seam: no hook file proceeds without touching exec deps" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try empty_tmp.dir.realPath(std.testing.io, &path_buf);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", path_buf[0..n]);
    // %APPDATA% backs the config dir on Windows; without it the resolve
    // path logs (harmlessly) instead of cleanly resolving to null.
    const appdata_abs = try std.fs.path.join(allocator, &.{ path_buf[0..n], "appdata" });
    defer allocator.free(appdata_abs);
    try env_map.put("APPDATA", appdata_abs);

    const ctx = hookTestCtx(allocator, &lg, &env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .proceed);
    try std.testing.expect(runPostHookOverride(ctx, "bash", "{}", "some output") == null);
}

test "hook seam: pre deny short-circuits with error envelope" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) if event == 'pre_tool_use' then return { deny = 'blocked by hook' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .short_circuit);
    defer allocator.free(action.short_circuit);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "blocked by hook") != null);
}

test "hook seam: pre modify rewrites args" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) return { arguments = '{\"command\":\"echo safe\"}' } end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{\"command\":\"rm -rf /\"}");
    try std.testing.expect(action == .proceed_modified);
    defer allocator.free(action.proceed_modified);
    try std.testing.expectEqualStrings("{\"command\":\"echo safe\"}", action.proceed_modified);
}

test "hook seam: pre mock returns success envelope" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) return { output = 'mocked output' } end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const action = runPreHookAction(ctx, "bash", "{}");
    try std.testing.expect(action == .short_circuit);
    defer allocator.free(action.short_circuit);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, action.short_circuit, "mocked output") != null);
}

test "hook seam: post replace swaps output" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(event, data) if event == 'post_tool_use' then return { output = 'redacted' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    const replacement = runPostHookOverride(ctx, "bash", "{}", "secret=abc");
    try std.testing.expect(replacement != null);
    defer allocator.free(replacement.?);
    try std.testing.expectEqualStrings("redacted", replacement.?);
}

test "hook seam: broken hook file fails open to proceed/keep" {
    const allocator = std.testing.allocator;
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(allocator, "function init(((\n", &path_buf);
    defer fx.deinit();

    const ctx = hookTestCtx(allocator, &lg, &fx.env_map);
    try std.testing.expect(runPreHookAction(ctx, "bash", "{}") == .proceed);
    try std.testing.expect(runPostHookOverride(ctx, "bash", "{}", "out") == null);
}

// ============================================================================
// Lua hook dispatch tests: real registry + real read_file exec + real Lua.
// A real in-memory DB is provided (read_file ignores it); config stays
// undefined because read_file always hits the registry (config is only
// read on registry miss). These prove the wiring, not just the helpers.
// ============================================================================

const HookDispatchCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn hookDispatchSetup() !HookDispatchCtx {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

fn hookDispatchCtx(
    allocator: std.mem.Allocator,
    setup: *HookDispatchCtx,
    logger: *logger_mod.Logger,
    environment: ?*const std.process.Environ.Map,
) ToolContext {
    var temp: f32 = 0.4;
    var thinking: bool = false;
    return ToolContext{
        .allocator = allocator,
        .io = setup.threaded.io(),
        .db = &setup.db,
        .logger = logger,
        .session_id = "sess_hook_dispatch",
        .model = "test-model",
        // Nonexistent cwd isolates the project-hook tier: no stray
        // <cwd>/.pabrik/hooks/register_hook.lua can interfere.
        .cwd = "/tmp/pabrik-hook-test-no-such-dir-xyz",
        .api_key = "",
        .base_url = "",
        .config = undefined,
        .agent_temperature = &temp,
        .is_thinking = &thinking,
        .environment = environment,
    };
}

fn readFileCall(allocator: std.mem.Allocator, path: []const u8) !agent.ToolCall {
    // JSON-escape: Windows paths contain backslashes (`C:\...`) which are
    // JSON escape leaders — embedding them raw yields invalid JSON (`\U`)
    // that the tool arg parser rejects. No-op on POSIX paths.
    const escaped = try jsonEscapePath(allocator, path);
    defer allocator.free(escaped);
    const args = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped});
    return agent.ToolCall{ .id = "call_hook_dispatch", .function = .{ .name = "read_file", .arguments = args } };
}

/// Escape `\` and `"` for embedding a path in a JSON string value.
fn jsonEscapePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, path.len);
    errdefer out.deinit(allocator);
    for (path) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "hook dispatch: no hook runs real read_file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real.txt", .data = "REAL CONTENT" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "real.txt" });

    var empty_tmp = std.testing.tmpDir(.{});
    defer empty_tmp.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const hn = try empty_tmp.dir.realPath(std.testing.io, &home_buf);
    var env_map = std.process.Environ.Map.init(dispatch_alloc);
    defer env_map.deinit();
    try env_map.put("HOME", home_buf[0..hn]);
    // %APPDATA% backs the config dir on Windows; keep the test hermetic
    // there too (unused on POSIX/macOS, resolve path stays clean).
    const appdata_abs = try std.fs.path.join(dispatch_alloc, &.{ home_buf[0..hn], "appdata" });
    try env_map.put("APPDATA", appdata_abs);

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &env_map);
    const tc = try readFileCall(dispatch_alloc, abs);
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "REAL CONTENT") != null);
}

test "hook dispatch: pre deny skips exec (missing file still denies)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fx = try hookFixture(dispatch_alloc, "function init(event, data) if event == 'pre_tool_use' and data.tool_name == 'read_file' then return { deny = 'reads blocked' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    // Points at a file that does not exist: without the hook this would
    // be a read_file error envelope, with the hook it must be the deny.
    const tc = try readFileCall(dispatch_alloc, "/tmp/pabrik-hook-test-does-not-exist-12345.txt");
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "reads blocked") != null);
}

test "hook dispatch: pre modify rewrites args seen by exec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.txt", .data = "OTHER CONTENT" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const other_abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "other.txt" });

    // JSON-escape the path (Windows backslashes) + Lua long brackets
    // ([[...]] disables Lua escape processing, so the JSON arrives
    // verbatim and `\\` stays valid JSON for the tool arg parser).
    const escaped = try jsonEscapePath(dispatch_alloc, other_abs);
    const lua_source = try std.fmt.allocPrint(dispatch_alloc, "function init(event, data) if event == 'pre_tool_use' then return {{ arguments = [[{{\"path\":\"{s}\"}}]] }} end return nil end\n", .{escaped});
    var fx = try hookFixture(dispatch_alloc, lua_source, &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    const tc = try readFileCall(dispatch_alloc, "/tmp/pabrik-hook-test-original-12345.txt");
    const result = try dispatchTool(ctx, tc);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OTHER CONTENT") != null);
}

test "hook dispatch: post replace swaps real output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dispatch_alloc = arena.allocator();
    var lg = logger_mod.Logger.init(dispatch_alloc, std.testing.io, .{});
    var setup = try hookDispatchSetup();
    defer setup.threaded.deinit();
    defer setup.db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.txt", .data = "TOP SECRET" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(dispatch_alloc, &.{ path_buf[0..n], "secret.txt" });

    var fx = try hookFixture(dispatch_alloc, "function init(event, data) if event == 'post_tool_use' then return { output = 'REDACTED BY HOOK' } end return nil end\n", &path_buf);
    defer fx.deinit();

    const ctx = hookDispatchCtx(dispatch_alloc, &setup, &lg, &fx.env_map);
    const tc = try readFileCall(dispatch_alloc, abs);
    const result = try dispatchTool(ctx, tc);
    try std.testing.expectEqualStrings("REDACTED BY HOOK", result.output);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TOP SECRET") == null);
}

test "jsonEscapePath escapes backslashes and quotes for JSON embedding" {
    const allocator = std.testing.allocator;
    // Windows-style path: every backslash must double, or the tool arg
    // parser rejects the JSON (`\U` is not a valid escape).
    const escaped = try jsonEscapePath(allocator, "C:\\Users\\x\\f.txt");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("C:\\\\Users\\\\x\\\\f.txt", escaped);
    // POSIX paths pass through untouched.
    const plain = try jsonEscapePath(allocator, "/tmp/foo.txt");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("/tmp/foo.txt", plain);
    // Quotes are escaped too.
    const quoted = try jsonEscapePath(allocator, "a\"b");
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("a\\\"b", quoted);
}
// ============================================================================
// Workspace-secret substitution tests (plan 2026-10-02-workspace-secrets)
//
// Two properties are under test and they pull in opposite directions. A —
// the executor receives the real value. B — the model never does: the value
// must not appear in `llm_history.tool_calls_json`, in a persisted tool
// result, or anywhere else the model can read it back.
//
// The fixture is in-memory SQLite with the tables these paths actually read:
// the three `resolveWorkspaceId` walks, `workspace_secrets`, and the
// `llm_history` / `sessions` columns `saveMessage` and
// `updateToolResultById` name. The DDL is spelled out here rather than
// imported from the migrations on purpose — these tests pin the dispatch
// wiring, not the schema.
// ============================================================================

const secrets_test_workspace = "ws_secrets_test";
/// Task-linked to a workspace item, so `resolveWorkspaceId` finds it through
/// the exact-link branch.
const secrets_test_session = "sess_secrets_test";
/// In `sessions` with a cwd that no `workspace_items` path prefixes, so it
/// resolves to nothing. This is the fail-closed case.
const secrets_test_orphan_session = "sess_secrets_orphan";
/// Chosen to contain nothing JSON-significant, so a canary found in an output
/// is the credential itself and not an artifact of escaping.
const secrets_test_canary = "canary-4f1c9a-Zx7Q";

const SecretsFixture = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *SecretsFixture) void {
        self.db.deinit();
        self.threaded.deinit();
    }

    fn io(self: *SecretsFixture) std.Io {
        return self.threaded.io();
    }
};

fn secretsSetup(allocator: std.mem.Allocator) !SecretsFixture {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // The three shapes `resolveWorkspaceId` walks before giving up.
    // `saveMessage` also runs `UPDATE sessions SET cwd = ?, updated_at = ...`,
    // so `updated_at` has to exist for the property-B test to get that far.
    try db.exec(allocator,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  cwd TEXT,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  path TEXT
        \\)
    , &.{});
    try db.exec(allocator,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  workspace_item_id TEXT
        \\)
    , &.{});

    // Migration 101, in the columns the store reads. `value` is here because
    // this fixture is the secret's own home; nothing in handle_tool.zig
    // selects it except through `loadSecretValues`.
    try db.exec(allocator,
        \\CREATE TABLE workspace_secrets (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  name TEXT NOT NULL,
        \\  value TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // Every column `saveMessage` inserts or `updateToolResultById` writes.
    // Nullable on purpose: an empty slice binds as SQL NULL in this backend,
    // so a NOT NULL column would turn a `null` argument into a constraint
    // failure that has nothing to do with secrets.
    try db.exec(allocator,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT,
        \\  model TEXT,
        \\  response_content TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT,
        \\  tool_calls_json TEXT,
        \\  tool_call_id TEXT,
        \\  reasoning_content TEXT,
        \\  reasoning_id TEXT,
        \\  reasoning_encrypted_content TEXT,
        \\  is_feed_to_llm INTEGER,
        \\  agent TEXT,
        \\  loop_index INTEGER,
        \\  temperature REAL,
        \\  is_thinking INTEGER,
        \\  created_at_nano INTEGER,
        \\  created_iso TEXT,
        \\  parent_session_id TEXT,
        \\  parent_id TEXT,
        \\  prompt_tokens INTEGER,
        \\  completion_tokens INTEGER,
        \\  total_tokens INTEGER,
        \\  cache_creation_input_tokens INTEGER,
        \\  cache_read_input_tokens INTEGER,
        \\  is_input INTEGER,
        \\  is_output INTEGER,
        \\  tool_name TEXT,
        \\  diffview_before TEXT,
        \\  diffview_after TEXT,
        \\  image_url TEXT,
        \\  video_url TEXT,
        \\  is_loading INTEGER DEFAULT 0
        \\)
    , &.{});

    try db.exec(allocator,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, path)
        \\VALUES ('wi_secrets', 'ws_secrets_test', 'kanban', '/proj/secrets')
    , &.{});
    try db.exec(allocator,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('sess_secrets_test', 'Secrets task', 'wi_secrets')
    , &.{});
    try db.exec(allocator,
        \\INSERT INTO sessions (id, name, cwd) VALUES
        \\  ('sess_secrets_test', 'Linked', '/proj/secrets'),
        \\  ('sess_secrets_orphan', 'Unlinked', '/elsewhere/no-item-here')
    , &.{});

    const row = try secrets_store.createSecret(allocator, &db, .{
        .workspace_id = secrets_test_workspace,
        .name = "TOK",
        .value = secrets_test_canary,
    });
    secrets_store.freeSecretRow(allocator, row);

    return .{ .db = db, .threaded = threaded };
}

/// `ToolContext` for the secrets tests. `config` stays `undefined` because
/// every tool used here hits the registry, and the registry walk never reads
/// it — the same posture as `hookDispatchCtx`.
fn secretsCtx(
    allocator: std.mem.Allocator,
    fx: *SecretsFixture,
    logger: *logger_mod.Logger,
    environment: ?*const std.process.Environ.Map,
    session_id: []const u8,
) ToolContext {
    var temp: f32 = 0.4;
    var thinking: bool = false;
    return ToolContext{
        .allocator = allocator,
        .io = fx.io(),
        .db = &fx.db,
        .logger = logger,
        .session_id = session_id,
        .model = "test-model",
        // Nonexistent, so no stray <cwd>/.nalar/hooks/register_hook.lua can
        // reach these dispatches and rewrite the arguments under test.
        .cwd = "/tmp/nalar-secrets-test-no-such-dir-xyz",
        .api_key = "",
        .base_url = "",
        .config = undefined,
        .agent_temperature = &temp,
        .is_thinking = &thinking,
        .environment = environment,
    };
}

/// HOME pointing at an empty tmpdir, so the Lua hook tiers find no
/// `register_hook.lua` and every dispatch below exercises the real path.
const SecretsEnv = struct {
    map: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
};

fn secretsEnvMap(allocator: std.mem.Allocator) !SecretsEnv {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    try map.put("HOME", path_buf[0..n]);
    // %APPDATA% backs the config dir on Windows; keeping the test hermetic
    // there too means the resolve path stays clean instead of logging.
    const appdata_abs = try std.fs.path.join(allocator, &.{ path_buf[0..n], "appdata" });
    defer allocator.free(appdata_abs);
    try map.put("APPDATA", appdata_abs);
    return .{ .map = map, .tmp = tmp };
}

/// A `write_file` call whose `content` is the given raw JSON fragment.
/// Writing is how the tests observe the executor: the file on disk is proof of
/// what the tool actually received, and its absence is proof the tool never
/// ran.
fn writeFileCall(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    id: []const u8,
    file_name: []const u8,
    content_json: []const u8,
) !agent.ToolCall {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const abs = try std.fs.path.join(allocator, &.{ path_buf[0..n], file_name });
    defer allocator.free(abs);
    const escaped = try jsonEscapePath(allocator, abs);
    defer allocator.free(escaped);
    const args = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"content\":{s}}}", .{ escaped, content_json });
    return agent.ToolCall{ .id = id, .function = .{ .name = "write_file", .arguments = args } };
}

/// Read one column out of `llm_history` by id, straight from SQL so an
/// assertion about what was persisted cannot be satisfied by the same code
/// that wrote it.
fn storedColumn(fx: *SecretsFixture, allocator: std.mem.Allocator, id: []const u8, column: []const u8) !?[]const u8 {
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM llm_history WHERE id = ?", .{column});
    defer allocator.free(sql);
    var q = try fx.db.query(allocator, sql, &[_][]const u8{id});
    defer q.deinit();
    const row = (try q.next()) orelse return null;
    defer row.deinit(allocator);
    return try allocator.dupe(u8, row.values[0]);
}

test "secrets: the executor receives the real value (property A)" {
    // Arena, like the `hook dispatch` tests above: `execWriteFile` hands the
    // `data` payload it built to `wrapToolOutput` without freeing it, so the
    // testing allocator would report a leak that has nothing to do with this
    // feature.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    const tc = try writeFileCall(allocator, &tmp, "call_secrets_a", "out.txt", "\"{{SECRETS:TOK}}\"");
    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    // The write landed with the credential in it, so the executor really was
    // handed the value and not the placeholder.
    const written = try tmp.dir.readFileAlloc(std.testing.io, "out.txt", allocator, .limited(1 << 20));
    try std.testing.expectEqualStrings(secrets_test_canary, written);

    try std.testing.expectEqual(@as(usize, 1), result.secrets.len);
    try std.testing.expectEqualStrings("TOK", result.secrets[0].name);
    try std.testing.expectEqualStrings(secrets_test_canary, result.secrets[0].value);

    // `execWriteFile` embeds the arguments in the envelope's `parameters`, so
    // the value is in the result string too — which is precisely why
    // redaction cannot be skipped. This assertion is what makes the redaction
    // tests below meaningful rather than vacuous.
    try std.testing.expect(std.mem.indexOf(u8, result.output, secrets_test_canary) != null);

    // The caller's own tool_call is untouched: substitution writes to a copy.
    try std.testing.expect(std.mem.indexOf(u8, tc.function.arguments, "{{SECRETS:TOK}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tc.function.arguments, secrets_test_canary) == null);
}

test "secrets: llm_history keeps the placeholder, never the value (property B)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    const tc = try writeFileCall(allocator, &tmp, "call_secrets_b", "out.txt", "\"{{SECRETS:TOK}}\"");

    // Phase 2 of `handle_tool`, reproduced against the same database and in
    // the same textual position — the assistant row is written with the RAW
    // tool_calls BEFORE dispatch runs.
    var assistant_tool_calls = [_]agent.ToolCall{tc};
    try llm_history.saveMessage(allocator, fx.io(), &fx.db, .{
        .session_id = secrets_test_session,
        .model = "test-model",
        .cwd = ctx.cwd,
        .content = "",
        .reasoning_content = null,
        .role = agent.Role.assistant.to_str(),
        .finish_reason = agent.FinishReason.tool.to_str(),
        .tool_calls = assistant_tool_calls[0..],
        .tool_call_id = null,
        .agent_name = "Agent",
        .loop_index = 0,
        .temperature = 0.4,
        .is_thinking = false,
        .is_input = true,
        .is_output = false,
    });

    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    const assistant_id = blk: {
        var q = try fx.db.query(allocator, "SELECT id FROM llm_history WHERE tool_call_id IS NULL LIMIT 1", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestExpectedEqual;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };

    const tool_calls_json = (try storedColumn(&fx, allocator, assistant_id, "tool_calls_json")).?;

    // The model reads this column on the next turn. It must carry the
    // placeholder and never the value.
    try std.testing.expect(std.mem.indexOf(u8, tool_calls_json, "{{SECRETS:TOK}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_calls_json, secrets_test_canary) == null);
}

test "secrets: the persisted tool result is scrubbed before it is stored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    const tc = try writeFileCall(allocator, &tmp, "call_secrets_redact", "out.txt", "\"{{SECRETS:TOK}}\"");
    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    // The Phase-1 placeholder row, then the same persist path Phase 3 takes.
    try fx.db.exec(allocator,
        \\INSERT INTO llm_history (id, session_id, model, response_content, role, tool_name, is_loading)
        \\VALUES ('row_secrets_redact', ?, 'test-model', '', 'tool', 'write_file', 1)
    , &[_][]const u8{secrets_test_session});

    try persistRedacted(allocator, fx.io(), &fx.db, "row_secrets_redact", secrets_test_session, ctx.cwd, tc, result.output, result.secrets, 0.4, false, "Agent", "");

    const stored = (try storedColumn(&fx, allocator, "row_secrets_redact", "response_content")).?;

    try std.testing.expect(std.mem.indexOf(u8, stored, secrets_test_canary) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "{{SECRETS:TOK}}") != null);
}

test "secrets: the shell echo case is scrubbed too (shell.zig puts the command in data)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();

    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    // `shell.zig`'s `result_to_json` serializes `result.command` into the
    // result `data`, so the fully substituted command comes straight back —
    // alongside the envelope's own `parameters` and the shell's stdout. This
    // is the leak that survives when redaction is applied anywhere other than
    // immediately before persistence.
    //
    // `timeout` and `cwd` are BOTH required by `execute_command`;
    // without either the tool returns an error envelope and never runs a shell,
    // which would leave the leak one layer short and the test below passing for
    // the wrong reason.
    // 60 also sits at exactly shell.zig's MAX_TIMEOUT_SEC, so an
    // over-max deadline would short the leak the same way — the minted value
    // must stay at or under one minute.
    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"command\":\"echo {{{{SECRETS:TOK}}}}\",\"cwd\":\"/tmp\",\"timeout\":60}}",
        .{},
    );
    const tc = agent.ToolCall{ .id = "call_secrets_shell", .function = .{ .name = "command", .arguments = args } };

    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);
    try std.testing.expectEqual(@as(usize, 1), result.secrets.len);
    try std.testing.expectEqualStrings("TOK", result.secrets[0].name);

    // The value really is in the raw result, more than once. Without this the
    // redaction assertions would pass vacuously.
    const raw_hits = std.mem.count(u8, result.output, secrets_test_canary);
    try std.testing.expect(raw_hits >= 2);

    const scrubbed = try secrets_substitution.redactOutput(allocator, result.output, result.secrets);

    try std.testing.expect(std.mem.indexOf(u8, scrubbed, secrets_test_canary) == null);
    // EVERY occurrence became a placeholder, not just the first: redaction
    // sweeps the whole output, which is what makes it safe to apply at a
    // boundary rather than to each field the tool happens to echo.
    try std.testing.expectEqual(raw_hits, std.mem.count(u8, scrubbed, "{{SECRETS:TOK}}"));
}

test "secrets: an unknown placeholder fails with the key named and never dispatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    const tc = try writeFileCall(allocator, &tmp, "call_secrets_unknown", "never.txt", "\"{{SECRETS:NOPE}}\"");
    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    // Actionable: the agent is told which key is missing, immediately, rather
    // than being handed an empty credential that fails later as a 401.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NOPE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Nothing was run") != null);
    // Nothing was substituted, so there is nothing to redact with.
    try std.testing.expectEqual(@as(usize, 0), result.secrets.len);

    // Not dispatched: the target file was never created.
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "never.txt", allocator, .limited(1 << 20)));
}

test "secrets: a session with no workspace fails closed, never passing the placeholder through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Same shape as the passing tests, but nothing links this session to a
    // workspace, so `resolveWorkspaceId` returns null.
    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_orphan_session);
    try std.testing.expect(
        try workspace_scope.resolveWorkspaceId(allocator, &fx.db, secrets_test_orphan_session) == null,
    );

    const tc = try writeFileCall(allocator, &tmp, "call_secrets_orphan", "orphan.txt", "\"{{SECRETS:TOK}}\"");
    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    // "No workspace" must not degrade to "no substitution needed": it is
    // reported as a miss like any other unknown name.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TOK") != null);
    try std.testing.expectEqual(@as(usize, 0), result.secrets.len);
    try std.testing.expect(std.mem.indexOf(u8, result.output, secrets_test_canary) == null);

    // The outcome that matters: an un-resolved placeholder must never arrive
    // at a tool as literal text to be used as a credential.
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "orphan.txt", allocator, .limited(1 << 20)));
}

test "secrets: a call with no placeholder is untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lg = logger_mod.Logger.init(allocator, std.testing.io, .{});
    var fx = try secretsSetup(allocator);
    defer fx.deinit();
    var env = try secretsEnvMap(allocator);
    defer env.map.deinit();
    defer env.tmp.cleanup();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The fast path that skips substitution entirely has to leave an ordinary
    // call working, or the feature breaks every tool that does not use it.
    const ctx = secretsCtx(allocator, &fx, &lg, &env.map, secrets_test_session);
    const tc = try writeFileCall(allocator, &tmp, "call_secrets_plain", "plain.txt", "\"no secrets here\"");
    const result = try dispatchTool(ctx, tc);
    defer freeResolvedSecrets(allocator, result.secrets);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"success\":true") != null);
    try std.testing.expectEqual(@as(usize, 0), result.secrets.len);

    const written = try tmp.dir.readFileAlloc(std.testing.io, "plain.txt", allocator, .limited(1 << 20));
    try std.testing.expectEqualStrings("no secrets here", written);
}

test "secrets: the resolver queries the store once per distinct name and remembers a miss" {
    // No dispatch here on purpose: this exercises the adapter's own memory
    // handling, which the testing allocator can then actually police.
    const allocator = std.testing.allocator;
    var fx = try secretsSetup(allocator);
    defer fx.deinit();

    var resolver = SecretResolver.init(allocator, &fx.db, secrets_test_session);
    defer resolver.deinit();

    const first = resolver.resolve("TOK");
    try std.testing.expectEqualStrings(secrets_test_canary, first.?);
    // The cache returns the same buffer, so the second resolve neither
    // re-queried nor re-duped. Pointer identity is the observable difference;
    // the values would compare equal either way.
    const second = resolver.resolve("TOK");
    try std.testing.expectEqualStrings(secrets_test_canary, second.?);
    try std.testing.expectEqual(@intFromPtr(first.?.ptr), @intFromPtr(second.?.ptr));
    try std.testing.expectEqual(@as(usize, 1), resolver.cache.count());

    // A miss is refused and remembered, so the error envelope can name the
    // key instead of saying only that something was missing.
    try std.testing.expect(resolver.resolve("ABSENT") == null);
    try std.testing.expectEqualStrings("ABSENT", resolver.missing_name.?);
}

// ============================================================================
// Worker activity heartbeat tests
// ============================================================================
//
// `touchWorkerActivity` is what makes the UI's "last activity" label mean
// anything: without it the timestamp only moves once per loop iteration, so a
// long tool call reads as a stalled worker. These tests drive the real DB
// write through `updateWorkerActivityWithDescription` and read the row back.

fn workerActivityDb(allocator: std.mem.Allocator) !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(allocator,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    cancelled INTEGER DEFAULT 0,
        \\    user_id TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

fn workerActivityRow(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
) !struct { desc: []u8, activity: i64 } {
    var rows = try db.query(allocator, "SELECT last_activity_description, last_activity_nano FROM worker WHERE id = ?", &.{id});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoRow;
    defer row.deinit(allocator);
    return .{
        .desc = try allocator.dupe(u8, row.values[0]),
        .activity = try std.fmt.parseInt(i64, row.values[1], 10),
    };
}

test "touchWorkerActivity stamps the timestamp and a tool-call description" {
    const allocator = std.testing.allocator;
    var s = try workerActivityDb(allocator);
    defer s.db.deinit();
    defer s.threaded.deinit();

    // Production keys the worker row by `id == session_id` (see
    // `update_worker.zig`), which is why `touchWorkerActivity` takes the
    // session id as its handle. Mirror that here or the probe finds nothing.
    try s.db.exec(allocator, "INSERT INTO worker (id, session_id, last_activity_nano, last_activity_description) VALUES ('s1', 's1', 0, '')", &.{});

    try touchWorkerActivity(allocator, &s.db, "s1", "bash", "{\"command\":\"ls -la\"}");

    const got = try workerActivityRow(allocator, &s.db, "s1");
    defer allocator.free(got.desc);

    // The description names the tool and carries the leading argument
    // fragment, so the UI can say what the worker is doing rather than
    // just that it is alive.
    try std.testing.expectEqualStrings("Tool call: bash {\"command\":\"ls -la\"}", got.desc);
    // The heartbeat moved off the seeded 0.
    try std.testing.expect(got.activity > 0);
}

test "touchWorkerActivity is a no-op when no worker row exists" {
    const allocator = std.testing.allocator;
    var s = try workerActivityDb(allocator);
    defer s.db.deinit();
    defer s.threaded.deinit();

    // A sub-agent's parent row is deleted by the time the child dispatches,
    // and tool calls also happen outside any worker. Neither is an error.
    try touchWorkerActivity(allocator, &s.db, "no_such_session", "bash", "{}");
}

test "buildWorkerActivityDescription omits the argument fragment when there is none" {
    const allocator = std.testing.allocator;

    const empty = try buildWorkerActivityDescription(allocator, "read_file", "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("Tool call: read_file", empty);

    const blank = try buildWorkerActivityDescription(allocator, "read_file", "   \n\t ");
    defer allocator.free(blank);
    try std.testing.expectEqualStrings("Tool call: read_file", blank);
}

test "buildWorkerActivityDescription truncates a long argument blob on a char boundary" {
    const allocator = std.testing.allocator;

    // Far past the cap, and with a multi-byte codepoint straddling the cut so
    // a naive byte slice would write invalid UTF-8 into the TEXT column.
    const long = try allocator.alloc(u8, 4000);
    defer allocator.free(long);
    @memset(long, 'a');
    // "é" is 2 bytes in UTF-8; place it so the cut lands inside it.
    @memcpy(long[worker_activity_desc_max - 3 ..][0..2], "é");

    const desc = try buildWorkerActivityDescription(allocator, "write_file", long);
    defer allocator.free(desc);

    try std.testing.expect(desc.len <= worker_activity_desc_max);
    try std.testing.expect(std.mem.endsWith(u8, desc, "…"));
    try std.testing.expect(std.mem.startsWith(u8, desc, "Tool call: write_file "));
    // Valid UTF-8 end to end — the truncation backed off the continuation byte.
    try std.testing.expect(std.unicode.utf8ValidateSlice(desc));
}

test "buildWorkerActivityDescription leaves a short argument untouched" {
    const allocator = std.testing.allocator;

    const desc = try buildWorkerActivityDescription(allocator, "search", "{\"q\":\"worker\"}");
    defer allocator.free(desc);

    try std.testing.expectEqualStrings("Tool call: search {\"q\":\"worker\"}", desc);
    try std.testing.expect(!std.mem.endsWith(u8, desc, "…"));
}
