//! The ONE batch runner for sub-agents: launch N concurrently, collect N
//! results.
//!
//! ## Why this is a module and not a tool
//!
//! Two features need "run these sub-agents at the same time and give me the
//! text back": the `spawn_sub_agent` tool, and the Skill Evals LLM judge tier
//! (`skill_eval_judge.zig`). The second is not a tool — it is CODE fanning out
//! from `runEval`, and it must not be reachable by a model. When the fan-out
//! lived inline in `execSpawnSubAgent` there would be two copies of the
//! concurrency, the progress-event protocol and the allowlist policy, and they
//! would drift. So the runner is here and the tool is a caller.
//!
//! ## The payload is code, not a model-authored string
//!
//! `runBatch` takes `[]const BatchJob` — a typed struct the caller built. The
//! tool's JSON front door (`runBatchFromJson`) exists only because a tool call
//! IS a JSON string; it parses and then delegates, so the two paths cannot
//! diverge on policy.
//!
//! ## The policy lives here, not in the caller
//!
//! `validateJobs` enforces the three rules that keep a fan-out bounded and
//! safe: at most `MaxBatch` items, a non-empty explicit tool allowlist (never
//! `"all"`), and no main-agent-only tool. A caller that forgets a check cannot
//! widen the blast radius, because the check is in `runBatch` rather than
//! beside it.
//!
//! ## Ownership
//!
//! `BatchOutcome` owns every string in it. Callers must call
//! `BatchOutcome.deinit`; nothing borrows from `BatchArgs` or `BatchJob` after
//! `runBatch` returns. The per-thread code below therefore DUPES the values it
//! stores rather than aliasing its arguments, which is also what makes the
//! `ThreadResult.deinit` below safe to run unconditionally.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const sqlite = pabrikcore.sqlite;
const logger_mod = pabrikcore.loggermod;
const llm_history = pabrikcore.llm_history;
const ai_workflow = @import("workflow.zig");
const spawn_sub_agent_tool = pabrikcore.spawn_sub_agent;
// The main-agent-only membership list lives with `ask_user` so the parse-time
// check here and `tool_eligibility.zig`'s strip can never disagree.
const main_agent_only = @import("../modules/agent/tools/ask_user.zig");
const subagent_progress = @import("subagent_progress.zig");

/// Hard ceiling on one batch. Twenty is the value the tool has always used
/// and the value the tool schema advertises; a fan-out larger than this is
/// refused, not truncated, so a caller can never silently evaluate a subset
/// and report it as the whole set.
pub const MaxBatch = 20;

/// One unit of work. Built by the caller as CODE — never parsed out of a
/// model's JSON — so `tools` is a real allowlist and `instruction` is a real
/// string.
pub const BatchJob = struct {
    /// The sub-agent's name. Resolved against the active profile by the caller
    /// when it wants a specific configured agent; otherwise it is only a label.
    name: []const u8,
    instruction: []const u8,
    /// REQUIRED, non-empty, never `"all"`, never a main-agent-only tool.
    /// Enforced by `validateJobs`.
    tools: []const []const u8,
    /// Mode string for parent-history inheritance; empty means none.
    inherited_context: []const u8 = "",
    /// Resolved sub-agent config overlay. Null means "orchestrator defaults",
    /// which is what a code-driven fan-out (the judge) wants.
    overrides: ?ai_workflow.SubAgentOverrides = null,
};

/// Everything a batch needs that is not per-job.
pub const BatchArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    /// The session the batch is attributed to (progress events, child parent id).
    parent_sess_id: []const u8,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    /// Forwarded to the child session row and its LLM resolution, so the child
    /// uses the parent's profile instead of top-level defaults.
    selected_profile_model: []const u8,
    /// The parent's tool_call id, so the frontend can route per-agent progress
    /// into the right card.
    tool_call_id: []const u8,
};

/// One sub-agent's outcome. Every string is owned by `BatchOutcome`.
pub const ThreadResult = struct {
    success: bool = false,
    name: []const u8 = "",
    response: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    session_id: []const u8 = "",
    /// True when the requested `name` matched no configured sub-agent and a
    /// random name was substituted. The frontend shows a "random" badge.
    is_random_fallback: bool = false,
};

pub const BatchOutcome = struct {
    results: []ThreadResult = &.{},
    allocator: std.mem.Allocator,

    pub fn succeeded(self: BatchOutcome) usize {
        var n: usize = 0;
        for (self.results) |r| {
            if (r.success) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *BatchOutcome) void {
        for (self.results) |r| {
            if (r.name.len > 0) self.allocator.free(r.name);
            if (r.response) |s| self.allocator.free(s);
            if (r.error_message) |s| self.allocator.free(s);
            if (r.session_id.len > 0) self.allocator.free(r.session_id);
        }
        if (self.results.len > 0) self.allocator.free(self.results);
        self.results = &.{};
    }
};

/// Enforce the batch policy. Called by `runBatch` — never by a caller alone.
///
/// The error names are the ones `spawn_sub_agent`'s parse path already returns,
/// so the tool's `<error>` envelope is unchanged by routing it through here.
pub fn validateJobs(jobs: []const BatchJob) !void {
    if (jobs.len == 0) return error.NoSubAgents;
    if (jobs.len > MaxBatch) return error.TooManySubAgents;
    for (jobs) |j| {
        if (j.instruction.len == 0) return error.MissingSubAgentInstruction;
        if (j.tools.len == 0) return error.EmptySubAgentTools;
        for (j.tools) |t| {
            if (t.len == 0) return error.InvalidSubAgentsFormat;
            const trimmed = std.mem.trim(u8, t, " \t");
            if (trimmed.len == 0) return error.InvalidSubAgentsFormat;
            // `"all"` would hand the child the parent's whole toolset, which
            // includes the tools the allowlist exists to withhold.
            if (std.ascii.eqlIgnoreCase(trimmed, "all")) return error.AllToolsNotAllowed;
            // Main-agent-only tools are a hard error, not a silent strip:
            // `ask_user` would leave the child's question unanswerable and
            // `run_skill_eval` would recurse eval-of-eval without bound.
            if (main_agent_only.isMainAgentOnly(trimmed)) return error.MainAgentOnlyToolNotAllowed;
        }
    }
}

// Heap-allocated per-thread arguments.
// Heap-allocated rather than a stack value so `group.concurrent` owns a
// pointer whose lifetime the group, not this frame, bounds.
const SubAgentThreadArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    parent_sess_id: []const u8,
    agent_name: []const u8,
    instruction: []const u8,
    tools: []const []const u8,
    cwd: []const u8,
    thread_idx: usize,
    shared_results: *SharedResults,
    environment: ?*const std.process.Environ.Map,
    inherited_context: []const u8 = "",
    sub_agent_overrides: ?ai_workflow.SubAgentOverrides = null,
    selected_profile_model: []const u8 = "",
    tool_call_id: []const u8 = "",
    total_agents: usize = 0,
    // Wall-clock capture at thread entry so `elapsed_ms` is meaningful
    // (the frontend renders it as a "running for 12s" chip).
    thread_start_ns: i128 = 0,
};

/// Shared result storage for thread synchronization.
const SharedResults = struct {
    results: []ThreadResult,
    completed_count: std.atomic.Value(usize),
    mutex: std.Io.Mutex,
};

/// Elapsed milliseconds since thread entry.
fn elapsedMs(a: *SubAgentThreadArgs) i64 {
    const now_ns = std.Io.Timestamp.now(a.io, .real).nanoseconds;
    const diff_ns = now_ns - a.thread_start_ns;
    return @intCast(@divTrunc(diff_ns, std.time.ns_per_ms));
}

/// Record a failure on this thread's slot and emit `failed` so the frontend
/// row never strands as `running`.
///
/// `err_msg` may be a static fallback literal, so it is DUPED rather than
/// stored: that keeps every string in a `ThreadResult` owned, which is what
/// lets `BatchOutcome.deinit` free them unconditionally.
fn failSubAgent(a: *SubAgentThreadArgs, err_msg: []const u8, ms: i64) void {
    a.shared_results.results[a.thread_idx].error_message =
        a.allocator.dupe(u8, err_msg) catch null;
    subagent_progress.emitProgressEvent(.{
        .parent_session_id = a.parent_sess_id,
        .tool_call_id = a.tool_call_id,
        .agent_name = a.agent_name,
        .status = .failed,
        .agent_index = a.thread_idx,
        .total_agents = a.total_agents,
        .session_id = "",
        .elapsed_ms = ms,
    });
}

/// The two "the sub-agent finished but produced nothing" branches. The message
/// is already on the slot, so only the progress event is emitted.
fn failSubAgentAlreadySet(a: *SubAgentThreadArgs, sub_session_id: []const u8, ms: i64) void {
    subagent_progress.emitProgressEvent(.{
        .parent_session_id = a.parent_sess_id,
        .tool_call_id = a.tool_call_id,
        .agent_name = a.agent_name,
        .status = .failed,
        .agent_index = a.thread_idx,
        .total_agents = a.total_agents,
        .session_id = sub_session_id,
        .elapsed_ms = ms,
    });
}

fn setError(a: *SubAgentThreadArgs, err_msg: []const u8) void {
    a.shared_results.results[a.thread_idx].error_message =
        a.allocator.dupe(u8, err_msg) catch null;
}

// Top-level function required by group.concurrent — takes a single
// *SubAgentThreadArgs. The signature must NOT return an error union if you
// want `group.await` not to propagate individual task errors; handle them
// internally and write into shared_results instead.
fn runSubAgent(args_ptr: *SubAgentThreadArgs) void {
    args_ptr.logger.debugFmt("Concurrent task started for '{s}'", .{args_ptr.agent_name});

    var thread_arena_alloc = std.heap.ArenaAllocator.init(args_ptr.allocator);
    defer thread_arena_alloc.deinit();
    const sub_agent_allocator = thread_arena_alloc.allocator();

    defer args_ptr.allocator.destroy(args_ptr);

    // Captured at entry so every emit below reports a real elapsed_ms rather
    // than a timestamp taken after the work.
    args_ptr.thread_start_ns = std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds;

    // Propagate the random-name fallback to the shared result so the frontend
    // can render the "random" badge. Done BEFORE the workflow call so it is
    // set even when the workflow errors out.
    if (args_ptr.sub_agent_overrides) |ov| {
        args_ptr.shared_results.results[args_ptr.thread_idx].is_random_fallback = ov.is_random_fallback;
    }

    // The session id embeds the resolved (or requested) sub-agent name, which
    // is what shows up in the UI's worker list.
    const resolved_display_name: []const u8 = if (args_ptr.sub_agent_overrides) |ov|
        ov.resolved_name
    else
        args_ptr.agent_name;

    // 2026-09-04 subagent-peek P0: child session ids embed the agent name
    // verbatim, so `backend implementer` produced a session id containing a raw
    // space — which breaks the HTTP request line, and where `/` or `%` break
    // router segment matching even when percent-encoded (the parser decodes
    // %2F before splitting). Slugify to [A-Za-z0-9_-] so the id is always one
    // URL-safe path segment. Uniqueness still comes from the nanosecond prefix.
    const slugged_name = slugifySubAgentName(sub_agent_allocator, resolved_display_name) catch resolved_display_name;
    const sess_id = std.fmt.allocPrint(
        sub_agent_allocator,
        "subagent_{}_{s}",
        .{ std.Io.Timestamp.now(args_ptr.io, .real).nanoseconds, slugged_name },
    ) catch {
        failSubAgent(args_ptr, std.fmt.allocPrint(
            args_ptr.allocator,
            "Agent Pabrik System error, the actual error is ->>>> Failed to create session_id for '{s}'\n",
            .{args_ptr.agent_name},
        ) catch "Agent Pabrik System error, the actual error is ->>>> Failed to create session_id", elapsedMs(args_ptr));
        args_ptr.logger.errFmt("Failed to create session_id for '{s}'", .{args_ptr.agent_name});
        return;
    };
    defer sub_agent_allocator.free(sess_id);
    args_ptr.logger.debugFmt("Session ID created: '{s}'", .{sess_id});

    // Stored in shared results immediately, so the `launched` progress event
    // below can carry it and the frontend can enable its peek button.
    {
        const session_id_copy = args_ptr.allocator.dupe(u8, sess_id) catch {
            failSubAgent(args_ptr, std.fmt.allocPrint(
                args_ptr.allocator,
                "Agent Pabrik System error, the actual error is ->>>> Failed to copy session_id for '{s}'\n",
                .{args_ptr.agent_name},
            ) catch "Agent Pabrik System error, the actual error is ->>>> Failed to copy session_id", elapsedMs(args_ptr));
            args_ptr.logger.errFmt("Failed to copy session_id for '{s}'", .{args_ptr.agent_name});
            return;
        };
        args_ptr.shared_results.results[args_ptr.thread_idx].session_id = session_id_copy;
    }

    subagent_progress.emitProgressEvent(.{
        .parent_session_id = args_ptr.parent_sess_id,
        .tool_call_id = args_ptr.tool_call_id,
        .agent_name = args_ptr.agent_name,
        .status = .launched,
        .agent_index = args_ptr.thread_idx,
        .total_agents = args_ptr.total_agents,
        .session_id = args_ptr.shared_results.results[args_ptr.thread_idx].session_id,
        .elapsed_ms = elapsedMs(args_ptr),
    });

    const di = pabrikcore.getSingleton() catch unreachable;

    const is_sub_agent = std.mem.indexOf(u8, sess_id, "subagent") != null;
    args_ptr.logger.debugFmt("Calling workflow.runAgenticMultiStep for '{s}'", .{args_ptr.agent_name});

    ai_workflow.runAgenticMultiStepnew(.{
        .allocator = di.allocator,
        .db = di.db,
        .io = di.io,
        .logger = di.logger,
        .event_bus = di.event_bus,
        // Live DI handle: re-read inside the workflow loop so PabrikSettings
        // changes take effect per iteration.
        .di = di,
        .environment = di.environment,
    }, .{
        .parent_session_id = args_ptr.parent_sess_id,
        .session_id = sess_id,
        .message = args_ptr.instruction,
        .cwd = args_ptr.cwd,
        .body = "",
        .allowed_tools = blk: {
            // `tools` is required per sub-agent (validateJobs refuses omit /
            // empty / "all"), so there is no omit-means-all fallback — the CSV
            // always comes from an explicit list.
            var tools_str = std.ArrayList(u8).empty;
            for (args_ptr.tools, 0..) |tool, i| {
                if (i > 0) tools_str.append(args_ptr.allocator, ',') catch break;
                tools_str.appendSlice(args_ptr.allocator, tool) catch break;
            }
            break :blk tools_str.items;
        },
        .is_sub_agent = is_sub_agent,
        .inherited_context = args_ptr.inherited_context,
        .sub_agent_overrides = args_ptr.sub_agent_overrides,
        .selected_profile_model = args_ptr.selected_profile_model,
    }) catch |err| {
        // Mirror the diagnostic pattern used by workflow.zig so the parent LLM
        // and the user see an actionable message rather than a bare error name.
        //
        // For TooManyRetries specifically, the inner workflow bail has already
        // saved a rich diagnostic to the SUB-AGENT's chat history, but the
        // parent LLM never sees that history — it only sees the error returned
        // from this call. Without this message the parent would have no idea
        // WHY it retried.
        const err_name: []const u8 = @errorName(err);
        const diagnostic: []const u8 = if (std.mem.eql(u8, err_name, "TooManyRetries"))
            std.fmt.allocPrint(args_ptr.allocator,
                \\[Agent Pabrik System error] sub-agent workflow halted after TooManyRetries (10+ consecutive failures).
                \\This typically indicates a network connectivity issue to the LLM API endpoint,
                \\API rate limit exceeded, authentication/authorization failure, or upstream
                \\service unavailability. The sub-agent's session logs contain the full chain
                \\of errors at each retry attempt — review them before retrying.
            , .{}) catch
                "Agent Pabrik System error, the actual error is ->>>> TooManyRetries\n"
        else
            std.fmt.allocPrint(
                args_ptr.allocator,
                "Agent Pabrik System error, the actual error is ->>>> {s}\n",
                .{err_name},
            ) catch "Failed to format error message";
        setError(args_ptr, diagnostic);
        // Also flip the SSE progress event so the chatview row goes
        // running→failed INSTEAD of stranding until group.await returns.
        // emitProgressEvent is fire-and-forget; never wrap in catch.
        subagent_progress.emitProgressEvent(.{
            .parent_session_id = args_ptr.parent_sess_id,
            .tool_call_id = args_ptr.tool_call_id,
            .agent_name = args_ptr.agent_name,
            .status = .failed,
            .agent_index = args_ptr.thread_idx,
            .total_agents = args_ptr.total_agents,
            .session_id = sess_id,
            .elapsed_ms = elapsedMs(args_ptr),
        });
        args_ptr.logger.errFmt("Sub-agent workflow error for '{s}': {s}", .{ args_ptr.agent_name, err_name });
        return;
    };

    args_ptr.logger.debugFmt("workflow.runAgenticMultiStep completed for '{s}', fetching message", .{args_ptr.agent_name});

    const latest_msg_result = llm_history.getLatestMessage(sub_agent_allocator, args_ptr.sqlite_db, sess_id) catch |err| {
        failSubAgent(args_ptr, std.fmt.allocPrint(
            args_ptr.allocator,
            "Agent Pabrik System error, the actual error is ->>>> getLatestMessage: {s}\n",
            .{@errorName(err)},
        ) catch "Agent Pabrik System error, the actual error is ->>>> getLatestMessage failed", elapsedMs(args_ptr));
        args_ptr.logger.errFmt("getLatestMessage error for '{s}': {s}", .{ sess_id, @errorName(err) });
        return;
    };

    if (latest_msg_result) |msg| {
        var mutable_msg = msg;
        if (mutable_msg.response_content.len > 0) {
            const response_copy = args_ptr.allocator.dupe(u8, mutable_msg.response_content) catch {
                failSubAgent(args_ptr, "Agent Pabrik System error, the actual error is ->>>> Failed to copy response: OutOfMemory\n", elapsedMs(args_ptr));
                mutable_msg.deinit(args_ptr.allocator);
                return;
            };
            args_ptr.shared_results.results[args_ptr.thread_idx].response = response_copy;
            args_ptr.shared_results.results[args_ptr.thread_idx].success = true;
            // `completed` ONLY when the sub-agent produced non-empty text. The
            // two "finished but empty" branches below emit `failed` instead.
            subagent_progress.emitProgressEvent(.{
                .parent_session_id = args_ptr.parent_sess_id,
                .tool_call_id = args_ptr.tool_call_id,
                .agent_name = args_ptr.agent_name,
                .status = .completed,
                .agent_index = args_ptr.thread_idx,
                .total_agents = args_ptr.total_agents,
                .session_id = sess_id,
                .elapsed_ms = elapsedMs(args_ptr),
            });
        } else {
            // Finished without producing any assistant text. Treated as a
            // failure so the row flips from running to failed instead of
            // hanging as running until the user navigates away.
            setError(args_ptr, "Agent Pabrik System error, the actual error is ->>>> Sub-agent completed but produced empty response content\n");
            failSubAgentAlreadySet(args_ptr, sess_id, elapsedMs(args_ptr));
        }
        mutable_msg.deinit(args_ptr.allocator);
    } else {
        // No message row at all — same UX treatment as the empty branch.
        setError(args_ptr, "Agent Pabrik System error, the actual error is ->>>> Sub-agent completed but no message found in database\n");
        failSubAgentAlreadySet(args_ptr, sess_id, elapsedMs(args_ptr));
    }

    _ = args_ptr.shared_results.completed_count.fetchAdd(1, .monotonic);
}

// 2026-09-04 subagent-peek fix (P0): child session ids embed the agent name
// verbatim, so `backend implementer` produced
// `subagent_{ns}_backend implementer` — a raw space in the REST path breaks the
// HTTP request line (`GET <path> HTTP/1.1` splits on ' ') and `/`/`%` break
// router segment matching even when encoded (the parser decodes %2F to '/'
// BEFORE it splits). Empty result falls back to "agent".
pub fn slugifySubAgentName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (name) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_') {
            try out.append(allocator, c);
        } else if (c == ' ' or c == '\t') {
            try out.append(allocator, '_');
        }
        // All other bytes (/, %, <, >, &, non-ASCII, …) are dropped.
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "agent");
    }
    return out.toOwnedSlice(allocator);
}

/// Run `jobs` concurrently and return their results.
///
/// The caller owns nothing afterwards: every string in the returned outcome is
/// a fresh allocation. Errors from the policy check propagate; per-job failures
/// do NOT — they land in `ThreadResult.error_message`, because one sub-agent
/// failing must not hide the other nineteen.
pub fn runBatch(args: BatchArgs, jobs: []const BatchJob) !BatchOutcome {
    // In the runner, not beside it: a caller that forgets the check cannot
    // widen the blast radius.
    try validateJobs(jobs);

    const job_count = jobs.len;
    const shared_results = try args.allocator.create(SharedResults);
    errdefer args.allocator.destroy(shared_results);
    shared_results.* = .{
        .results = try args.allocator.alloc(ThreadResult, job_count),
        .completed_count = std.atomic.Value(usize).init(0),
        .mutex = std.Io.Mutex.init,
    };
    errdefer args.allocator.free(shared_results.results);

    // Names are DUPED because a job's `name` is borrowed from the caller's
    // struct and the outcome outlives the call. `response` / `error_message` /
    // `session_id` are duped by `runSubAgent` for the same reason.
    for (shared_results.results, 0..) |*r, i| {
        const owned_name = args.allocator.dupe(u8, jobs[i].name) catch jobs[i].name;
        r.* = .{ .success = false, .name = owned_name };
    }

    var outcome = BatchOutcome{ .results = shared_results.results, .allocator = args.allocator };
    errdefer outcome.deinit();

    // `concurrent` (not `async`): the agents must genuinely run in parallel,
    // and `async` on a single-threaded Io can deadlock.
    var group: std.Io.Group = .init;
    // A launch failure must not leave the already-launched threads un-awaited.
    var launched: usize = 0;
    defer {
        if (launched < job_count) {
            group.await(args.io) catch {};
        }
    }

    for (jobs, 0..) |job, idx| {
        args.logger.debugFmt("Launching concurrent task for agent '{s}' (index {})", .{ job.name, idx });

        const targs = try args.allocator.create(SubAgentThreadArgs);
        targs.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .sqlite_db = args.db,
            .logger = args.logger,
            .parent_sess_id = args.parent_sess_id,
            .agent_name = job.name,
            .instruction = job.instruction,
            .tools = job.tools,
            .cwd = args.cwd,
            .thread_idx = idx,
            .shared_results = shared_results,
            .environment = args.environment,
            .inherited_context = job.inherited_context,
            .sub_agent_overrides = job.overrides,
            // Forward the parent's profile so the child session row carries it
            // (DB NOT NULL) and its LLM calls resolve the same profile instead
            // of falling back to top-level defaults.
            .selected_profile_model = args.selected_profile_model,
            .tool_call_id = args.tool_call_id,
            .total_agents = job_count,
            // .thread_start_ns is set INSIDE runSubAgent at entry.
        };

        // group.concurrent returns error.ConcurrencyUnavailable if the Io
        // backend cannot run tasks in parallel (e.g. a bare blocking Io).
        group.concurrent(args.io, runSubAgent, .{targs}) catch |err| {
            // The thread was never scheduled, so nothing will free it.
            args.allocator.destroy(targs);
            return err;
        };
        launched += 1;
    }

    args.logger.debugFmt("Awaiting {} concurrent tasks...", .{job_count});
    group.await(args.io) catch |err| {
        return err;
    };
    launched = job_count;
    args.logger.debugFmt("All concurrent tasks completed", .{});

    return outcome;
}

/// Tool front door: parse a `spawn_sub_agent` tool-call payload and run it.
///
/// The parse is the only reason a JSON string ever reaches the runner, and it
/// exists because a tool call IS a JSON string. It delegates to `runBatch`, so
/// the policy (`MaxBatch`, the allowlist rules) is enforced in one place.
pub fn runBatchFromJson(args: BatchArgs, input_json: []const u8, max_agents: usize) !BatchOutcome {
    const parsed = try spawn_sub_agent_tool.parse_sub_agents(args.allocator, input_json, max_agents);
    defer parsed.deinit(args.allocator);

    const jobs = try args.allocator.alloc(BatchJob, parsed.sub_agents.len);
    defer args.allocator.free(jobs);
    for (parsed.sub_agents, 0..) |sa, i| {
        jobs[i] = .{
            .name = sa.agent_name,
            .instruction = sa.instruction,
            .tools = sa.tools,
            .inherited_context = sa.inherited_context orelse "",
            // Null here: the caller resolves its own overrides and hands them
            // to `runBatch` (see `execSpawnSubAgent`), because resolving needs
            // the live LlmConfig and the parent's selected profile.
            .overrides = null,
        };
    }
    return runBatch(args, jobs);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "validateJobs refuses more than MaxBatch jobs" {
    const alloc = testing.allocator;
    const jobs = try alloc.alloc(BatchJob, MaxBatch + 1);
    defer alloc.free(jobs);
    for (jobs) |*j| j.* = .{ .name = "a", .instruction = "do it", .tools = &.{"read_file"} };

    try testing.expectError(error.TooManySubAgents, validateJobs(jobs));
    // Exactly at the cap is allowed — the cap is a ceiling, not an off-by-one.
    try validateJobs(jobs[0..MaxBatch]);
}

test "validateJobs refuses a main-agent-only tool in the allowlist" {
    const jobs = [_]BatchJob{
        .{ .name = "judge", .instruction = "judge it", .tools = &.{ "read_file", "ask_user" } },
    };
    try testing.expectError(error.MainAgentOnlyToolNotAllowed, validateJobs(&jobs));

    // run_skill_eval is the recursion hazard specifically: a judging sub-agent
    // that could start another eval would fan out without bound.
    const recursive = [_]BatchJob{
        .{ .name = "judge", .instruction = "judge it", .tools = &.{"run_skill_eval"} },
    };
    try testing.expectError(error.MainAgentOnlyToolNotAllowed, validateJobs(&recursive));
}

test "validateJobs refuses an empty allowlist and the all wildcard" {
    const empty = [_]BatchJob{.{ .name = "j", .instruction = "i", .tools = &.{} }};
    try testing.expectError(error.EmptySubAgentTools, validateJobs(&empty));

    const all = [_]BatchJob{.{ .name = "j", .instruction = "i", .tools = &.{ "read_file", "all" } }};
    try testing.expectError(error.AllToolsNotAllowed, validateJobs(&all));

    const blank = [_]BatchJob{.{ .name = "j", .instruction = "i", .tools = &.{"  "} }};
    try testing.expectError(error.InvalidSubAgentsFormat, validateJobs(&blank));

    const no_instruction = [_]BatchJob{.{ .name = "j", .instruction = "", .tools = &.{"read_file"} }};
    try testing.expectError(error.MissingSubAgentInstruction, validateJobs(&no_instruction));
}

test "validateJobs accepts a well-formed batch at any size up to the cap" {
    const one = [_]BatchJob{.{ .name = "judge", .instruction = "judge it", .tools = &.{ "read_file", "search" } }};
    try validateJobs(&one);
}

test "runBatch enforces the cap before touching the singleton" {
    // The point of the ordering: policy is checked first, so an oversized batch
    // fails without ever reaching `pabrikcore.getSingleton()` (which is
    // `unreachable` in a unit test). If the cap were checked after the launch
    // loop this test would crash rather than return an error.
    const alloc = testing.allocator;
    const jobs = try alloc.alloc(BatchJob, MaxBatch + 1);
    defer alloc.free(jobs);
    for (jobs) |*j| j.* = .{ .name = "a", .instruction = "i", .tools = &.{"read_file"} };

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");

    // `expectError` cannot be used here: it would still evaluate the call, so
    // the real assertion is that the oversized batch comes back as an error
    // rather than crashing on the unreachable singleton.
    if (runBatch(.{
        .allocator = alloc,
        .io = threaded.io(),
        .db = &db,
        // Unused on this path; a null logger would be a lie only if the
        // policy check did not fire first.
        .logger = undefined,
        .parent_sess_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .selected_profile_model = "",
        .tool_call_id = "",
    }, jobs)) |o| {
        var leaked = o;
        leaked.deinit();
        return error.RunBatchAcceptedAnOversizedBatch;
    } else |err| {
        try testing.expectEqual(error.TooManySubAgents, err);
    }
}

test "slugifySubAgentName keeps URL-safe chars, space->underscore" {
    // 2026-09-04 subagent-peek P0: the child session id must be a single
    // URL-safe path segment. Raw spaces broke the HTTP request line and '/'
    // broke router segment matching.
    const alloc = testing.allocator;
    const s1 = try slugifySubAgentName(alloc, "backend implementer");
    defer alloc.free(s1);
    try testing.expectEqualStrings("backend_implementer", s1);

    const s2 = try slugifySubAgentName(alloc, "code-reviewer");
    defer alloc.free(s2);
    try testing.expectEqualStrings("code-reviewer", s2);

    const s3 = try slugifySubAgentName(alloc, "a/b%c<d>e&f");
    defer alloc.free(s3);
    try testing.expectEqualStrings("abcdef", s3);

    const s4 = try slugifySubAgentName(alloc, "");
    defer alloc.free(s4);
    try testing.expectEqualStrings("agent", s4);

    const s5 = try slugifySubAgentName(alloc, "///");
    defer alloc.free(s5);
    try testing.expectEqualStrings("agent", s5);
}
