//! The `run_skill_eval` agent tool: the one thing the agent has to do for
//! Skill Evals to happen. The prompt rule tells the agent to call this.

const std = @import("std");
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const agent = pabrikcore.agent;
const logger_mod = pabrikcore.loggermod;
const AgentTool = @import("../modules/agent/tools/schemas.zig").AgentTool;

const tools = @import("tools.zig");
const skill_evals_db = @import("skill_evals_db.zig");
const skill_evals_config = @import("skill_evals_config.zig");
const drift = @import("skill_evals_drift.zig");
const skill_eval_events = @import("skill_eval_events.zig");
const skill_eval_judge = @import("skill_eval_judge.zig");
const batch = @import("sub_agent_batch.zig");
const migration = @import("../migrations/migration.zig");

// A skill is a row in one workspace-scoped table (Migration 101), not a file
// in one of two directories.
const skills_store = @import("skills_store.zig");
const workspace_scope = @import("workspace_scope.zig");

const Verdict = skill_evals_db.Verdict;

pub const run_skill_eval_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "run_skill_eval",
        .description =
        \\Evaluate the skills this session actually used. Call it ONCE, after you have finished the user's task and before your final message, when you loaded at least one skill with `use_skill`.
        \\
        \\Takes no arguments: it reads the record of what this session was offered and what it read, so you cannot (and need not) name the skills. It checks whether the paths, commands and facts each skill names are still true against the code as it is now, and records a verdict for a human to review. You are not the judge.
        \\
        \\Cheap and idempotent: evals another session already ran for the same skill content are reused, and a second call in the same session is a no-op rather than a second eval. Skip it when you loaded no skill.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt =
        \\## Skill Evals
        \\
        \\Call `run_skill_eval` once, before your final answer, if this session
        \\loaded a skill. Then report the outcome in one line.
        \\
    },
};

pub const RunOutcome = struct {
    /// The master switch is off. Nothing was read and nothing was written.
    disabled: bool = false,
    /// No skill was loaded or offered this session, so there is nothing to do.
    nothing_loaded: bool = false,
    /// The run could not even be claimed (a database error). Distinct from
    /// `nothing_loaded`, which would be a false statement about the ledger.
    failed: bool = false,
    /// A run already existed for this session. `run_id` names it; nothing was
    /// recomputed. This is the idempotency path, not an error.
    reused: bool = false,
    run_id: []u8 = &.{},
    evaluated: u32 = 0,
    keep: u32 = 0,
    update: u32 = 0,
    needs_human: u32 = 0,
    reused_facts: u32 = 0,
    skipped: u32 = 0,

    pub fn deinit(self: RunOutcome, allocator: std.mem.Allocator) void {
        if (self.run_id.len > 0) allocator.free(self.run_id);
    }
};

pub const RunArgs = struct {
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8 = "",
    profile: []const u8 = "",
    environment: ?*const std.process.Environ.Map,
    enabled: bool,
    /// `skill_evals.max_skills_per_run`.
    max_skills: u32 = 8,
    /// `skill_evals.include_listed_without_loading`.
    include_listed_only: bool = true,
    /// `skill_evals.fact_lease_seconds` — how long a `computing` lease may sit
    /// before another session may take it over.
    fact_lease_seconds: u32 = 300,
    /// The SSE bus, when the caller has one. Null in unit tests and in any
    /// caller with no bus; the emit is then a no-op.
    event_bus: ?*pabrikcore.event_bus.EventBus = null,
    /// Tier 1: fan out one judge sub-agent per skill. Off by default because
    /// it spends tokens — up to `max_skills` sub-agent runs per eval.
    judge_enabled: bool = false,
    /// The judge reads code to check claims; it never writes. Kept to the
    /// read-only set so a judge cannot edit the very skill it is judging, and
    /// so `validateJobs`' main-agent-only rule has nothing to catch.
    judge_tools: []const []const u8 = &.{ "read_file", "search", "glob" },
};

/// One skill waiting to be judged. Collected during the Tier-0 loop, which is
/// where the body and the intrinsic verdict are already in hand.
const JudgeCandidate = struct {
    result_id: []u8,
    skill_name: []u8,
    /// The instruction to send, already built: the body has to be in scope
    /// here anyway, and building it now keeps the fan-out loop free of
    /// allocation that can fail halfway through a batch.
    prompt: []u8,
    /// The deterministic verdict this judge may only ESCALATE from.
    intrinsic: Verdict,
    /// The row's rationale so far, so a failed judge can append to it instead
    /// of overwriting what Tier 0 established.
    rationale: []u8,

    fn deinit(self: JudgeCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.result_id);
        allocator.free(self.skill_name);
        allocator.free(self.prompt);
        allocator.free(self.rationale);
    }
};

fn freeJudgeCandidates(allocator: std.mem.Allocator, items: []JudgeCandidate) void {
    for (items) |c| c.deinit(allocator);
    allocator.free(items);
}

/// Run the LLM judge tier over `candidates` and write the session-relative
/// half back onto each result row. Returns the number of rows a validated
/// report reached.
fn runJudgeTier(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    args: RunArgs,
    run_id: []const u8,
    candidates: []const JudgeCandidate,
) !u32 {
    const di = pabrikcore.getSingleton() catch {
        // No live context means no workflow, so no sub-agent can run. The
        // deterministic results stay as they are; this is not a failure of
        // the eval, only of the opt-in tier.
        if (logger) |l| l.warnFmt("skill eval: judge tier skipped, no live agent context", .{});
        return 0;
    };
    if (candidates.len == 0) return 0;

    // Emitted once, before the fan-out, so a listener can show that the
    // session-relative half is being computed rather than sitting at 0.
    skill_eval_events.emitSkillEvalEvent(allocator, args.event_bus, .{
        .action = "run_started",
        .run_id = run_id,
        .session_id = args.session_id,
        .evaluated = @intCast(candidates.len),
    });

    const jobs = allocator.alloc(batch.BatchJob, candidates.len) catch {
        if (logger) |l| l.warnFmt("skill eval: could not allocate {d} judge job(s)", .{candidates.len});
        return 0;
    };
    defer allocator.free(jobs);
    for (candidates, 0..) |c, i| {
        jobs[i] = .{
            // A label, not a config lookup: with `overrides` null the batch
            // runner uses the orchestrator defaults and the parent's profile,
            // so an unconfigured name cannot drag in a random agent.
            .name = "skill-eval-judge",
            .instruction = c.prompt,
            .tools = args.judge_tools,
            .overrides = null,
        };
    }

    var outcome = batch.runBatch(.{
        .allocator = allocator,
        .io = io,
        .db = db,
        .logger = di.logger,
        .parent_sess_id = args.session_id,
        .cwd = args.cwd,
        .environment = args.environment,
        .selected_profile_model = args.profile,
        // The eval has no tool_call of its own, so progress events are keyed
        // to the run rather than to a chat card.
        .tool_call_id = "",
    }, jobs) catch |err| {
        if (logger) |l| l.warnFmt("skill eval: judge batch failed: {s}", .{@errorName(err)});
        return 0;
    };
    defer outcome.deinit();

    var judged: u32 = 0;
    for (candidates, 0..) |c, i| {
        const result = outcome.results[i];
        const unreadable = blk: {
            if (!result.success) {
                if (logger) |l| {
                    l.warnFmt("skill eval: judge for '{s}' did not complete: {s}", .{
                        c.skill_name,
                        result.error_message orelse "no reason reported",
                    });
                }
                break :blk "the judge sub-agent did not complete";
            }
            const text = result.response orelse break :blk "the judge returned no text";
            // `var` because `deinit` takes a mutable pointer to release the
            // report's arena.
            var parsed = skill_eval_judge.parseReport(allocator, text) catch {
                break :blk "the judge's reply could not be read";
            } orelse break :blk "the judge's reply was not a JSON report";
            defer parsed.deinit();

            // THE trust boundary. Everything below runs only because this
            // returned; a downgraded report reaches none of the writes.
            const validation = skill_evals_db.validateReport(parsed.report);
            if (validation.downgraded) {
                if (logger) |l| l.warnFmt("skill eval: judge report for '{s}' refused: {s}", .{ c.skill_name, validation.reason });
                const why = try std.fmt.allocPrint(allocator, "{s}; the judge's report was refused ({s})", .{ c.rationale, validation.reason });
                defer allocator.free(why);
                _ = skill_evals_db.updateJudgeResult(allocator, db, c.result_id, .{
                    .verdict = c.intrinsic,
                    .sub_session_id = result.session_id,
                    .status = "needs_human",
                    .rationale = why,
                }) catch false;
                continue;
            }

            const final = skill_eval_judge.combineVerdict(c.intrinsic, validation);
            if (final == .delete and c.intrinsic != .delete) {
                if (logger) |l| l.warnFmt("skill eval: judge escalated '{s}' to delete on a high-severity finding", .{c.skill_name});
            }
            const why = if (parsed.report.rationale.len > 0)
                try std.fmt.allocPrint(allocator, "{s}; judge: {s}", .{ c.rationale, parsed.report.rationale })
            else
                try allocator.dupe(u8, c.rationale);
            defer allocator.free(why);

            _ = skill_evals_db.updateJudgeResult(allocator, db, c.result_id, .{
                .verdict = final,
                .relevance = parsed.report.relevance,
                .used = parsed.report.used,
                .helpfulness = parsed.report.helpfulness,
                .confidence = parsed.report.confidence,
                .sub_session_id = result.session_id,
                .status = "done",
                .rationale = why,
                // The report survived `validateReport`, which has already
                // refused every update/rewrite that arrives without this. It
                // was being dropped here, one line after being made mandatory.
                .proposed_diff = parsed.report.proposed_content,
            }) catch false;
            judged += 1;
            continue;
        };

        // Unreachable in practice — the block above either continues or sets
        // a reason — but Zig needs the `catch` on the JSON parse to have a
        // value, and a fall-through here would be an unrecorded judgement.
        const why = try std.fmt.allocPrint(allocator, "{s}; {s}", .{ c.rationale, unreadable });
        defer allocator.free(why);
        _ = skill_evals_db.updateJudgeResult(allocator, db, c.result_id, .{
            .verdict = c.intrinsic,
            .sub_session_id = result.session_id,
            .status = "needs_human",
            .rationale = why,
        }) catch false;
    }
    return judged;
}

/// Insert one result row. Private because it is the only writer of this table
/// today and it is not a primitive anyone else should reach for.
fn insertResult(
    allocator: std.mem.Allocator,
    db: *database.Db,
    id: []const u8,
    run_id: []const u8,
    skill_key: []const u8,
    skill_name: []const u8,
    session_id: []const u8,
    status: []const u8,
    verdict: Verdict,
    intrinsic_fact_id: []const u8,
    base_content_hash: []const u8,
    /// The exact body `base_content_hash` is the SHA-256 of. Empty when the
    /// body could not be read, in which case there is no "before" to record.
    content_at_use: []const u8,
    rationale: []const u8,
) !void {
    // Every free-text column is COALESCE-wrapped: `exec` binds an empty slice
    // as SQL NULL, and these columns are NOT NULL (Migration 079's class).
    try db.exec(allocator,
        // Column order MUST match the bind order below -- SQLite binds
        // positionally, so a mismatch here writes each value into its
        // neighbour instead of failing.
        \\INSERT INTO skill_eval_results
        \\    (id, run_id, skill_key, skill_name, session_id, status, verdict,
        \\     intrinsic_fact_id, base_content_hash, rationale, content_at_use,
        \\     sub_session_id)
        \\VALUES
        \\    (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), 'needs_human'),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''))
    , &.{
        id,
        run_id,
        skill_key,
        skill_name,
        session_id,
        status,
        verdict.asString(),
        intrinsic_fact_id,
        base_content_hash,
        rationale,
        content_at_use,
        // `sub_session_id` belongs to the LLM judge tier (it will name the
        // sub-agent that produced the session-relative half).
        "",
    });
}

/// Run the eval for one session. Pure with respect to the tool layer: it takes
/// a db and a session id, so it is testable without a live tool turn.
pub fn runEval(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    logger: ?*logger_mod.Logger,
    args: RunArgs,
) !RunOutcome {
    // Defence in depth. The tool is only injected into the tool list when the
    // switch is on, so reaching here disabled means something re-enabled it
    // behind our back — refuse rather than spend anything.
    if (!args.enabled) return .{ .disabled = true };
    if (args.session_id.len == 0) return .{ .nothing_loaded = true };

    const set = try skill_evals_db.sessionSkillSet(allocator, db, args.session_id);
    defer skill_evals_db.freeSessionSkillSet(allocator, set);
    if (set.len == 0) return .{ .nothing_loaded = true };

    // Which workspace this SESSION belongs to, resolved once for the whole
    // run.
    const workspace_id = workspace_scope.resolveWorkspaceId(allocator, db, args.session_id) catch |err| blk: {
        if (logger) |l| l.warnFmt("skill eval: could not resolve a workspace for session '{s}': {s}", .{ args.session_id, @errorName(err) });
        break :blk null;
    };
    defer if (workspace_id) |w| allocator.free(w);

    const context_key = if (args.cwd.len > 0)
        try std.fmt.allocPrint(allocator, "{s}@", .{args.cwd})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(context_key);

    const run_id = try std.fmt.allocPrint(allocator, "skilleval_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    errdefer allocator.free(run_id);
    // NOTE: ownership of `run_id` moves to `outcome` below. The `errdefer`
    // above covers an early return; once the outcome exists it is the owner
    // and the caller frees it via `deinit`.

    const claimed = skill_evals_db.claimRun(
        allocator,
        db,
        run_id,
        args.session_id,
        "self_prompt",
        "",
        "session",
        args.cwd,
        context_key,
        args.profile,
        args.model,
    ) catch |err| {
        if (logger) |l| l.warnFmt("skill eval: could not claim a run: {s}", .{@errorName(err)});
        // `errdefer` does not fire on a normal return, so the id must be freed
        // here. Reporting this as `nothing_loaded` would also be a lie — the
        // ledger was already read and it was not empty.
        allocator.free(run_id);
        return .{ .failed = true };
    };
    if (!claimed) {
        // The agent emitted two calls in one turn, or already evaluated this
        // session. Return the existing run rather than doing the work twice.
        allocator.free(run_id);
        return .{ .reused = true };
    }

    // A run row now exists and holds the session's one-shot slot.
    errdefer skill_evals_db.finishRun(allocator, db, run_id, "error", 0, "runEval failed mid-loop") catch {};

    var outcome = RunOutcome{ .run_id = run_id };
    var ordinal: u32 = 0;
    // Only populated when the judge tier is on, so the default path allocates
    // nothing beyond the results it already writes.
    var candidates: std.ArrayList(JudgeCandidate) = .empty;
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    // Read once for the whole run: every judge asks the same "what was this
    // session for", and re-querying it per skill would be N identical reads.
    var task_context: []u8 = &.{};
    defer if (task_context.len > 0) allocator.free(task_context);

    for (set) |use| {
        if (outcome.evaluated >= args.max_skills) {
            outcome.skipped += 1;
            continue;
        }
        // A skill that was only OFFERED is still worth judging: "the agent was
        // handed the right skill and ignored it" is a real finding. It is
        // configurable because it is also the noisier half.
        if (!use.loaded and !args.include_listed_only) {
            outcome.skipped += 1;
            continue;
        }

        ordinal += 1;
        const result_id = try std.fmt.allocPrint(allocator, "{s}_r{d}", .{ run_id, ordinal });
        defer allocator.free(result_id);

        // The identity of the question, in one string: the workspace that
        // OWNS the skill, then its name. The workspace is load-bearing.
        const skill_key = if (workspace_id) |w|
            try std.fmt.allocPrint(allocator, "{s}:{s}", .{ w, use.skill_name })
        else
            // No workspace means no row can be found for anything, so this
            // run's results are all needs_human regardless.
            try std.fmt.allocPrint(allocator, "<no-workspace>:{s}", .{use.skill_name});
        defer allocator.free(skill_key);

        // The current body is the row `use_skill` materialised for the agent,
        // read through the same store and the same workspace guard — so there
        // is no local-then-global walk left to disagree with, and no way to
        var owned_row: ?skills_store.SkillRow = null;
        defer if (owned_row) |r| skills_store.freeSkillRow(allocator, r);
        var missing_reason: []const u8 = "";
        if (workspace_id) |w| {
            owned_row = skills_store.getSkillByName(allocator, db, w, use.skill_name) catch |err| switch (err) {
                // An absent row and an unreadable query are the same thing to
                // this loop — there is no body to hash. Only an allocation
                // failure is a real error.
                error.OutOfMemory => return error.OutOfMemory,
                error.NotFound, error.QueryFailed, error.WorkspaceIdNameRequired => @as(?skills_store.SkillRow, null),
            };
            if (owned_row) |r| {
                // An empty body is not a body. Hashing "" would publish a fact
                // about nothing and report the skill as merely unremarkable.
                if (r.content.len == 0) {
                    skills_store.freeSkillRow(allocator, r);
                    owned_row = null;
                    missing_reason = "the skill row has an empty body, so there is nothing to evaluate";
                }
            } else {
                missing_reason = "the skill is not installed in this workspace";
            }
        } else {
            missing_reason = "this session is not linked to any workspace, so the skill cannot be read";
        }

        if (owned_row == null) {
            // No body. That is a finding in itself, and the rationale names
            // WHICH of the reasons applies rather than inventing a body or
            // blaming a file that does not exist in any workspace.
            try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "needs_human", .needs_human, "", "", "", missing_reason);
            outcome.needs_human += 1;
            outcome.evaluated += 1;
            continue;
        }
        // Byte-exact, and deliberately so: this slice is hashed into the
        // identity of the question AND stored as the `content_at_use` a human
        // reads to judge the verdict.
        const body = owned_row.?.content;

        var hash_buf: [64]u8 = undefined;
        skill_evals_db.sha256Hex(body, &hash_buf);
        const body_hash = hash_buf[0..];

        // The identity of the question: this body, in this repo. Reusing it is
        // what makes two sessions evaluating one skill cost one computation.
        const fact_key_hash = try allocator.dupe(u8, body_hash);
        defer allocator.free(fact_key_hash);

        const claim = skill_evals_db.claimFact(allocator, db, result_id, skill_key, fact_key_hash, context_key) catch |err| blk: {
            if (logger) |l| l.warnFmt("skill eval: claimFact failed for '{s}': {s}", .{ use.skill_name, @errorName(err) });
            break :blk skill_evals_db.FactClaim.held;
        };

        // `args.cwd` still belongs here, and it is no longer about where the
        // body LIVES — the body is a row and has no location.
        var analysis = try drift.analyse(allocator, io, args.cwd, body);
        defer analysis.deinit(allocator);

        var intrinsic_fact_id: []const u8 = "";
        // Set only on the reuse path, where the id is a fresh dupe that this
        // iteration owns. The `.won` path points at `result_id`, which is
        // already deferred by the loop body.
        var owned_fact_id: ?[]u8 = null;
        defer if (owned_fact_id) |id| allocator.free(id);
        var verdict = skill_evals_db.decideVerdict(analysis.verdict, analysis.has_high);

        switch (claim) {
            .won => {
                _ = skill_evals_db.publishFact(allocator, db, result_id, .{
                    .verdict = analysis.verdict,
                    .freshness = if (analysis.missing_count > 0) 1 else 3,
                    .findings_json = analysis.findings_json,
                    .missing_paths_json = analysis.missing_paths_json,
                    .evidence_json = analysis.findings_json,
                }) catch false;
                intrinsic_fact_id = result_id;
            },
            .reusable => {
                outcome.reused_facts += 1;
                if (skill_evals_db.readFact(allocator, db, skill_key, fact_key_hash, context_key) catch null) |fact| {
                    defer fact.deinit(allocator);
                    verdict = skill_evals_db.decideVerdict(fact.verdict, false);
                    // Link the result to the fact it reused.
                    owned_fact_id = try allocator.dupe(u8, fact.id);
                    intrinsic_fact_id = owned_fact_id.?;
                }
            },
            .held => {
                // Someone else is computing the same question right now — or
                // a crashed owner left a lease behind.
                const stolen = skill_evals_db.stealFact(
                    allocator,
                    db,
                    skill_key,
                    fact_key_hash,
                    context_key,
                    args.fact_lease_seconds,
                ) catch false;
                if (stolen) {
                    _ = skill_evals_db.publishFact(allocator, db, result_id, .{
                        .verdict = analysis.verdict,
                        .freshness = if (analysis.missing_count > 0) 1 else 3,
                        .findings_json = analysis.findings_json,
                        .missing_paths_json = analysis.missing_paths_json,
                        .evidence_json = analysis.findings_json,
                    }) catch false;
                    intrinsic_fact_id = result_id;
                } else {
                    // A live owner exists. Record what Tier 0 already knows and
                    // let the owner's intrinsic verdict take over when it lands.
                    outcome.reused_facts += 1;
                }
            },
        }

        const changed = use.loaded and use.content_hash.len > 0 and !std.mem.eql(u8, use.content_hash, body_hash);
        const rationale = if (changed)
            try std.fmt.allocPrint(allocator, "the body changed since this session read it; {d} path check(s) failed", .{analysis.missing_count})
        else if (analysis.missing_count > 0)
            try std.fmt.allocPrint(allocator, "{d} referenced path(s) no longer exist", .{analysis.missing_count})
        else
            try allocator.dupe(u8, "Tier 0 found no problem; the session-relative half is not yet evaluated");
        defer allocator.free(rationale);

        try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "done", verdict, intrinsic_fact_id, body_hash, body, rationale);

        // Everything the judge needs is in scope right here, so the candidate
        // is captured now rather than re-derived later.
        if (args.judge_enabled) {
            if (task_context.len == 0) {
                task_context = skill_evals_db.sessionTaskContext(allocator, db, args.session_id, 4_000) catch
                    try allocator.dupe(u8, "");
            }
            const summary = try std.fmt.allocPrint(allocator, "{d} referenced path(s) no longer exist", .{analysis.missing_count});
            const prompt = skill_eval_judge.buildPrompt(allocator, .{
                .skill_name = use.skill_name,
                .skill_body = body,
                .task_context = task_context,
                .loaded = use.loaded,
                .intrinsic_summary = summary,
                .cwd = args.cwd,
            }) catch {
                allocator.free(summary);
                if (logger) |l| l.warnFmt("skill eval: could not build the judge prompt for '{s}'", .{use.skill_name});
                continue;
            };
            allocator.free(summary);

            candidates.append(allocator, .{
                .result_id = try allocator.dupe(u8, result_id),
                .skill_name = try allocator.dupe(u8, use.skill_name),
                .prompt = prompt,
                .intrinsic = verdict,
                .rationale = try allocator.dupe(u8, rationale),
            }) catch {
                allocator.free(prompt);
                if (logger) |l| l.warnFmt("skill eval: could not queue '{s}' for judging", .{use.skill_name});
            };
        }

        outcome.evaluated += 1;
        switch (verdict) {
            .keep => outcome.keep += 1,
            .update => outcome.update += 1,
            else => outcome.needs_human += 1,
        }

        // Distinguish "offered and ignored" explicitly in the log, because it is
        // the one finding that is about the AGENT rather than about the skill.
        if (logger) |l| {
            if (!use.loaded and use.listed) {
                l.debugFmt("skill eval: '{s}' was offered and never loaded", .{use.skill_name});
            }
        }
    }

    // Tier 1, after the deterministic half is on disk and before the run is
    // closed: the judge UPDATEs rows that already exist, so it has to run
    // while the run is still open.
    if (args.judge_enabled and candidates.items.len > 0) {
        // An out-of-memory part-way through is NOT a reason to fail the eval:
        // the deterministic half is already stored and correct.
        const judged = runJudgeTier(allocator, io, db, logger, args, run_id, candidates.items) catch |err| blk: {
            if (logger) |l| l.warnFmt("skill eval: judge tier did not finish: {s}", .{@errorName(err)});
            break :blk 0;
        };
        if (logger) |l| l.debugFmt("skill eval: {d} of {d} judge report(s) validated for run {s}", .{ judged, candidates.items.len, run_id });
        // The counts describe the deterministic pass, which is what the
        // summary reports.
    }

    skill_evals_db.finishRun(allocator, db, run_id, "done", 0, "") catch |err| {
        if (logger) |l| l.warnFmt("skill eval: could not finalize run {s}: {s}", .{ run_id, @errorName(err) });
    };
    // Tell the UI the run finished, so the Evals tab refreshes without polling.
    // Emitted AFTER finishRun so a listener that re-fetches sees the final
    // status, not a `running` row.
    skill_eval_events.emitSkillEvalEvent(allocator, args.event_bus, .{
        .action = "run_finished",
        .run_id = run_id,
        .session_id = args.session_id,
        .evaluated = outcome.evaluated,
    });
    return outcome;
}

pub fn execRunSkillEval(ctx: tools.ToolExecContext, tc: agent.ToolCall) !tools.ToolExecResult {
    // Under `--auth` the user's settings live in `users.config_json` and never
    // reach `ctx.config`, so resolve the block per session before deciding.
    // Null in file mode, where the singleton is already authoritative.
    const evals_cfg = skill_evals_config.resolve(ctx.allocator, ctx.db, ctx.session_id) orelse
        ctx.config.skill_evals;
    const enabled = evals_cfg.enabled;
    // The SSE bus, when the singleton is up. Null in tests and in any
    // dispatch with no live context — the emit is then a no-op.
    const bus: ?*pabrikcore.event_bus.EventBus = if (pabrikcore.getSingleton()) |di| di.event_bus else |_| null;
    const outcome = runEval(ctx.allocator, ctx.io, ctx.db, ctx.logger, .{
        .session_id = ctx.session_id,
        .cwd = ctx.cwd,
        .model = ctx.model,
        .profile = ctx.selected_profile_model,
        .environment = ctx.environment,
        .enabled = enabled,
        .max_skills = evals_cfg.max_skills_per_run,
        .include_listed_only = evals_cfg.include_listed_without_loading,
        .fact_lease_seconds = evals_cfg.fact_lease_seconds,
        .event_bus = bus,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "run_skill_eval failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        const out = try tools.wrapToolOutput(ctx.allocator, "run_skill_eval", tc.function.arguments, false, msg, "");
        return tools.ToolExecResult{ .output = out, .output_allocated = true };
    };
    defer outcome.deinit(ctx.allocator);

    const inner = if (outcome.disabled)
        try ctx.allocator.dupe(u8, "{\"status\":\"disabled\",\"message\":\"Skill Evals are off for this user. Turn on Settings > Skill Evals for this account, then try again.\"}")
    else if (outcome.failed)
        try ctx.allocator.dupe(u8, "{\"status\":\"failed\",\"message\":\"The eval could not be started because of a database error. Nothing was evaluated.\"}")
    else if (outcome.reused)
        try ctx.allocator.dupe(u8, "{\"status\":\"already_evaluated\",\"message\":\"This session's skills were already evaluated; nothing was recomputed.\"}")
    else if (outcome.nothing_loaded)
        try ctx.allocator.dupe(u8, "{\"status\":\"nothing_loaded\",\"message\":\"No skill was loaded or offered this session, so there is nothing to evaluate.\"}")
    else
        try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"done\",\"run_id\":{f},\"evaluated\":{d},\"keep\":{d},\"update\":{d},\"needs_human\":{d},\"reused_shared_facts\":{d},\"skipped\":{d}}}", .{
            std.json.fmt(outcome.run_id, .{}),
            outcome.evaluated,
            outcome.keep,
            outcome.update,
            outcome.needs_human,
            outcome.reused_facts,
            outcome.skipped,
        });
    defer ctx.allocator.free(inner);

    const out = try tools.wrapToolOutput(ctx.allocator, "run_skill_eval", tc.function.arguments, true, null, inner);
    return tools.ToolExecResult{ .output = out, .output_allocated = true };
}

// ─── tests ───────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: database.Db = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, threaded.io());
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn seedLoaded(alloc: std.mem.Allocator, db: *database.Db, io: std.Io, session_id: []const u8, name: []const u8) !void {
    const result = try std.fmt.allocPrint(alloc,
        "{{\"tool\":\"use_skill\",\"success\":true,\"data\":{{\"skill_name\":{f},\"content\":\"body\",\"loaded\":true}},\"error\":null,\"v\":1}}",
        .{std.json.fmt(name, .{})});
    defer alloc.free(result);
    skill_evals_db.recordSkillToolEvents(alloc, db, null, .{
        .io = io,
        .session_id = session_id,
        .tool_name = "use_skill",
        .tool_result_json = result,
        .loop_index = 3,
        .llm_history_id = "h1",
    });
}

fn countResults(alloc: std.mem.Allocator, db: *database.Db) !i64 {
    var q = try db.query(alloc, "SELECT COUNT(*) FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

test "runEval does nothing at all when the switch is off" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "whatever");
    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = false,
    });
    defer out.deinit(alloc);

    try testing.expect(out.disabled);
    // Nothing read, nothing written: "off" must not mean "off, but it still
    // touched the database".
    try testing.expectEqual(@as(i64, 0), try countResults(alloc, &ctx.db));
}

test "runEval reports nothing_loaded for a session with no ledger rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_empty",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expect(out.nothing_loaded);
    // No run should be left behind for a session that had nothing to evaluate.
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "a skill this workspace does not have is an honest needs_human, not a guess" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // In the ledger, but this workspace holds no skill by that name.
    try seedWorkspace(alloc, &ctx.db, "sess_1", "ws_a");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "definitely-not-a-real-skill-xyz");
    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.needs_human);
    try testing.expectEqual(@as(u32, 0), out.keep);
    try testing.expectEqual(@as(i64, 1), try countResults(alloc, &ctx.db));

    var q = try ctx.db.query(alloc, "SELECT status, verdict, rationale, skill_key FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("needs_human", row.values[0]);
    try testing.expectEqualStrings("needs_human", row.values[1]);
    try testing.expectEqualStrings("the skill is not installed in this workspace", row.values[2]);
    // The key names the workspace, so this row can never be mistaken for
    // another workspace's result about the same skill name.
    try testing.expectEqualStrings("ws_a:definitely-not-a-real-skill-xyz", row.values[3]);
}

test "a session with no workspace says that, instead of blaming a body" {
    // Two different problems, two different fixes: "no workspace" is a wiring
    // problem the user can fix, "the file is gone" sends them hunting for a
    // file that was never where they thought it was.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No `workspace_item_tasks` row and no cwd match: unresolvable, and the
    // resolver fails closed rather than guessing a workspace.
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_orphan", "some-skill");
    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_orphan",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.needs_human);

    var q = try ctx.db.query(alloc, "SELECT rationale, skill_key FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("this session is not linked to any workspace, so the skill cannot be read", row.values[0]);
    // A sentinel a workspace id cannot collide with, so these rows stay out
    // of any real workspace's fact cache.
    try testing.expectEqualStrings("<no-workspace>:some-skill", row.values[1]);
}

test "an empty skill body is not evaluated as if it were a good one" {
    // `content` defaults to `''` and a model routinely writes the body after
    // the row exists. Hashing "" would publish a fact about nothing and
    // report the skill as merely unremarkable — a `keep` nobody earned.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_empty_body", "ws_empty");
    try seedSkillRow(alloc, &ctx.db, "ws_empty", "draft-skill", "");
    try seedLoaded(alloc, &ctx.db, io, "sess_empty_body", "draft-skill");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_empty_body",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.needs_human);
    try testing.expectEqual(@as(u32, 0), out.keep);

    // No fact was published about a body that does not exist.
    var fq = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("0", frow.values[0]);

    var q = try ctx.db.query(alloc, "SELECT rationale FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("the skill row has an empty body, so there is nothing to evaluate", row.values[0]);
}

test "the same skill name in two workspaces gets its own fact, not the other's verdict" {
    // The regression this pins.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_a", "ws_a");
    try seedWorkspace(alloc, &ctx.db, "sess_b", "ws_b");

    // Workspace A's copy is current; workspace B's names a path that does not
    // exist. Same name, same repo, different bodies and different verdicts.
    const a_body =
        \\---
        \\name: pdf
        \\description: A's copy
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    const b_body =
        \\---
        \\name: pdf
        \\description: B's copy
        \\---
        \\## Procedure
        \\Read src/definitely/not/here.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_a", "pdf", a_body);
    try seedSkillRow(alloc, &ctx.db, "ws_b", "pdf", b_body);

    try seedLoaded(alloc, &ctx.db, io, "sess_a", "pdf");
    try seedLoaded(alloc, &ctx.db, io, "sess_b", "pdf");

    const a = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_a",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), a.keep);

    const b = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_b",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer b.deinit(alloc);

    // Neither run reused the other's fact, and B's rot was found rather than
    // answered from A's cache.
    try testing.expectEqual(@as(u32, 0), a.reused_facts);
    try testing.expectEqual(@as(u32, 0), b.reused_facts);
    try testing.expectEqual(@as(u32, 1), b.update);

    var fq = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("2", frow.values[0]);

    // Each result carries ITS OWN workspace in the key and ITS OWN body as the
    // before/after a human reads.
    var q = try ctx.db.query(alloc,
        \\SELECT skill_key, content_at_use, verdict FROM skill_eval_results ORDER BY skill_key
    , &.{});
    defer q.deinit();
    const ra = (try q.next()) orelse return error.RowMissing;
    defer ra.deinit(alloc);
    try testing.expectEqualStrings("ws_a:pdf", ra.values[0]);
    try testing.expectEqualStrings(a_body, ra.values[1]);
    try testing.expectEqualStrings("keep", ra.values[2]);

    const rb = (try q.next()) orelse return error.RowMissing;
    defer rb.deinit(alloc);
    try testing.expectEqualStrings("ws_b:pdf", rb.values[0]);
    try testing.expectEqualStrings(b_body, rb.values[1]);
    try testing.expectEqualStrings("update", rb.values[2]);
}

test "a skill in ANOTHER workspace is invisible to this session" {
    // The read is scoped, not filtered afterwards. A session in ws_a must not
    // be able to evaluate ws_b's body even when the name matches, or the
    // verdict would be about text this workspace never held.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_a", "ws_a");
    try seedSkillRow(alloc, &ctx.db, "ws_b", "pdf", "---\nname: pdf\n---\nB's body");
    try seedLoaded(alloc, &ctx.db, io, "sess_a", "pdf");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_a",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.needs_human);
    var q = try ctx.db.query(alloc, "SELECT rationale, COALESCE(CAST(content_at_use AS TEXT), '') FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("the skill is not installed in this workspace", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
}

test "a second call in the same session reuses the run instead of redoing it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "definitely-not-a-real-skill-xyz");
    const first = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer first.deinit(alloc);
    try testing.expect(!first.reused);

    // The agent can emit this twice in one turn. The partial unique index is
    // the arbiter, and the loser must not evaluate again.
    const second = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer second.deinit(alloc);
    try testing.expect(second.reused);
    try testing.expectEqual(@as(i64, 1), try countResults(alloc, &ctx.db));
}

test "max_skills bounds the work and records the remainder as skipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-one");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-two");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-three");

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
        .max_skills = 2,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 2), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.skipped);
    try testing.expectEqual(@as(i64, 2), try countResults(alloc, &ctx.db));
}

test "max_skills = 0 evaluates nothing and does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-one");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-two");

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
        .max_skills = 0,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 0), out.evaluated);
    try testing.expectEqual(@as(u32, 2), out.skipped);
    try testing.expectEqual(@as(i64, 0), try countResults(alloc, &ctx.db));
}

// ─── the publish / reuse paths ───────────────────────────────────────────
// These need a skill that actually EXISTS in the session's workspace, because
// every test above names one that does not and therefore exits at the "no

/// Give `session_id` a workspace through the exact task link a kanban task
/// session has (`workspace_item_tasks.id` IS the session id) — the first
/// branch of `workspace_scope.resolveWorkspaceId`.
fn seedWorkspace(alloc: std.mem.Allocator, db: *database.Db, session_id: []const u8, ws_id: []const u8) !void {
    try db.exec(alloc,
        \\INSERT INTO workspaces (id, name) VALUES (?, 'skill eval fixture') ON CONFLICT DO NOTHING
    , &.{ws_id});
    const item_id = try std.fmt.allocPrint(alloc, "wi_{s}", .{ws_id});
    defer alloc.free(item_id);
    try db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path)
        \\VALUES (?, ?, 'kanban', 'skill eval fixture', '') ON CONFLICT DO NOTHING
    , &.{ item_id, ws_id });
    try db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, 'skill eval fixture', ?) ON CONFLICT DO NOTHING
    , &.{ session_id, item_id });
}

/// One row in `skills`, which is now the whole of a skill.
fn seedSkillRow(alloc: std.mem.Allocator, db: *database.Db, ws_id: []const u8, name: []const u8, body: []const u8) !void {
    const id = try std.fmt.allocPrint(alloc, "sk_test_{s}_{s}", .{ ws_id, name });
    defer alloc.free(id);
    try db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name, description, content, created_at, updated_at)
        \\VALUES (?, ?, ?, 'seeded by a skill eval test', COALESCE(NULLIF(?, ''), ''), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        \\ON CONFLICT (id) DO UPDATE SET workspace_id = excluded.workspace_id, name = excluded.name,
        \\  description = excluded.description, content = excluded.content, updated_at = excluded.updated_at
    , &.{ id, ws_id, name, body });
}

test "a real skill is published as a fact and linked from the result" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_1", "ws_publish");

    // A body whose only reference resolves, so Tier 0 says `keep`.
    const body =
        \\---
        \\name: real-skill
        \\description: a skill that exists
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_publish", "real-skill", body);
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "real-skill");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.keep);
    try testing.expectEqual(@as(u32, 0), out.reused_facts);

    // The FACT must exist and be published (not left as a `computing` lease).
    var fq = try ctx.db.query(alloc,
        "SELECT verdict_intrinsic, freshness FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("keep", frow.values[0]);
    try testing.expectEqualStrings("3", frow.values[1]);

    // And the RESULT must point at it, or the LEFT JOIN loses the evidence.
    var rq = try ctx.db.query(alloc,
        "SELECT intrinsic_fact_id, base_content_hash, status FROM skill_eval_results", &.{});
    defer rq.deinit();
    const rrow = (try rq.next()) orelse return error.RowMissing;
    defer rrow.deinit(alloc);
    try testing.expect(rrow.values[0].len > 0);
    try testing.expectEqualStrings("done", rrow.values[2]);
    // The base hash must be the hash of the body that was read.
    var expected: [64]u8 = undefined;
    skill_evals_db.sha256Hex(body, &expected);
    try testing.expectEqualStrings(expected[0..], rrow.values[1]);
}

test "a second session reuses the shared fact AND links the result to it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    // BOTH sessions are in ONE workspace: two tasks on one item. That is what
    // makes the fact shared rather than accidentally separated by a key that
    // forgot the workspace.
    try seedWorkspace(alloc, &ctx.db, "sess_a", "ws_shared");
    try seedWorkspace(alloc, &ctx.db, "sess_b", "ws_shared");

    const body =
        \\---
        \\name: shared-skill
        \\description: shared
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_shared", "shared-skill", body);

    // Session A computes and publishes the fact.
    try seedLoaded(alloc, &ctx.db, io, "sess_a", "shared-skill");
    const a = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_a",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.reused_facts);

    // Session B evaluates the SAME body in the same repo: the fact is reused.
    try seedLoaded(alloc, &ctx.db, io, "sess_b", "shared-skill");
    const b = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_b",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer b.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), b.reused_facts);
    try testing.expectEqual(@as(u32, 1), b.keep);

    // Exactly one fact for the question — the cache did its job.
    var fq = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("1", frow.values[0]);

    // BOTH results must carry the fact id.
    var rq = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM skill_eval_results WHERE intrinsic_fact_id != ''", &.{});
    defer rq.deinit();
    const rrow = (try rq.next()) orelse return error.RowMissing;
    defer rrow.deinit(alloc);
    try testing.expectEqualStrings("2", rrow.values[0]);
}

test "a body edited between the read and the eval is reported as changed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_1", "ws_changed");

    // The ledger records a hash of the body the session READ...
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "edited-skill");
    // ...but the row the workspace holds is now different.
    const new_body =
        \\---
        \\name: edited-skill
        \\description: edited after the read
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_changed", "edited-skill", new_body);

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    var q = try ctx.db.query(alloc, "SELECT rationale FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // The `changed` branch has its own rationale; nothing else produces it.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "the body changed since this session read it") != null);
}

test "a skill that was only LISTED is still evaluated when configured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_1", "ws_offered");
    try seedWorkspace(alloc, &ctx.db, "sess_2", "ws_offered");

    const body =
        \\---
        \\name: offered-only
        \\description: offered and ignored
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_offered", "offered-only", body);

    // Only a `listed` event — the agent was offered the skill and never read it.
    // The row carries no `scope` and no `path`: a skill has neither any more.
    const listed =
        \\{"tool":"search_skills","success":true,"data":{"query":"","skills":[{"name":"offered-only","description":"d"}],"count":1,"total":1},"error":null,"v":1}
    ;
    skill_evals_db.recordSkillToolEvents(alloc, &ctx.db, null, .{
        .io = io,
        .session_id = "sess_1",
        .tool_name = "search_skills",
        .tool_result_json = listed,
        .loop_index = 1,
        .llm_history_id = "h1",
    });

    // With include_listed_only = true (the default) it IS evaluated: "the agent
    // was handed the right skill and ignored it" is a real finding.
    const with_listed = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = null,
        .enabled = true,
        .include_listed_only = true,
    });
    defer with_listed.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), with_listed.evaluated);

    // With it off, the same session skips it.
    const without = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_2",
        .cwd = ".",
        .environment = null,
        .enabled = true,
        .include_listed_only = false,
    });
    defer without.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), without.evaluated);
}

test "a run that fails mid-loop is finalized as error, not left running" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    // A session with a ledger row, so the run is claimed...
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "whatever");
    // ...then drop the results table so the first insertResult fails. This is
    // the shape of any transient DB error mid-loop.
    try ctx.db.exec(alloc, "DROP TABLE skill_eval_results", &.{});

    const result = runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    // It must propagate an error. Which variant arrives is the backend's own
    // affair: sqlite fails at prepare, postgres at execute.
    if (result) |_| {
        return error.ExpectedMissingTableError;
    } else |err| switch (err) {
        error.PrepareFailed, error.QueryFailed, error.ExecuteFailed => {},
        else => return err,
    }

    // ...and the run must NOT be left `running`. A stuck run both shows a
    // permanently spinning UI and, because the partial unique index still holds
    // the row, blocks every later eval for this session forever.
    var q = try ctx.db.query(alloc, "SELECT status FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("error", row.values[0]);
}

test "judge_enabled with no live agent context still completes the deterministic half" {
    // A unit test has no singleton, so no sub-agent can run.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_j1", "some-skill");

    var outcome = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_j1",
        .cwd = ".",
        .environment = null,
        .enabled = true,
        .max_skills = 4,
        .judge_enabled = true,
    });
    defer outcome.deinit(alloc);

    // The session is in no workspace at all, so there is no row to read and
    // Tier 0 records a `needs_human` result — and the judge tier did not
    // disturb it.
    try testing.expectEqual(@as(i64, 1), try countResults(alloc, &ctx.db));

    const rows = try skill_evals_db.listResults(alloc, &ctx.db, outcome.run_id);
    defer skill_evals_db.freeResultRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("needs_human", rows[0].verdict);
    try testing.expectEqualStrings("needs_human", rows[0].status);
    // Nothing was judged, so the session-relative half is untouched at 0 —
    // never a fabricated score.
    const scores = (try skill_evals_db.readJudgeScores(alloc, &ctx.db, rows[0].id)).?;
    defer scores.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), scores.relevance);
    try testing.expectEqual(@as(u8, 0), scores.used);
    try testing.expectEqual(@as(u8, 0), scores.helpfulness);
    try testing.expectEqualStrings("", scores.sub_session_id);
}

test "the judge tier is off unless a caller opts in" {
    // `judge_enabled` defaults false, so the shipped tool spends nothing on
    // sub-agents. This pins the default: a future edit that flips it would
    // start billing a sub-agent per skill on every eval.
    const args = RunArgs{
        .session_id = "s",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    };
    try testing.expectEqual(false, args.judge_enabled);
    // And the allowlist the judge runs with is read-only: a judge that could
    // write could edit the very skill it is judging.
    for (args.judge_tools) |tool| {
        try testing.expect(std.mem.eql(u8, tool, "read_file") or
            std.mem.eql(u8, tool, "search") or
            std.mem.eql(u8, tool, "glob"));
    }
    // `runBatch` refuses a batch whose allowlist is empty or wildcard, so the
    // judge's tools must satisfy the same policy the tool's do.
    try batch.validateJobs(&.{.{ .name = "skill-eval-judge", .instruction = "judge", .tools = args.judge_tools }});
}

test "a result row stores the exact body its base_content_hash was computed from" {
    // `content_at_use` existed in the schema from the start and had exactly
    // one reference in the whole repo: the CREATE TABLE.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_ca", "ws_snapshot");

    // Frontmatter, blank lines and all — the row stores what a human typed,
    // and this test is the one place that proves nothing is normalised on the
    // way in.
    const body =
        \\---
        \\name: snapshot-skill
        \\description: a skill whose body must be recoverable from the result row
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillRow(alloc, &ctx.db, "ws_snapshot", "snapshot-skill", body);
    try seedLoaded(alloc, &ctx.db, io, "sess_ca", "snapshot-skill");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_ca",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), out.evaluated);

    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(CAST(content_at_use AS TEXT), ''), COALESCE(CAST(base_content_hash AS TEXT), ''), COALESCE(CAST(proposed_diff AS TEXT), '') FROM skill_eval_results",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);

    // The stored body IS the body -- byte for byte, frontmatter included.
    try testing.expectEqualStrings(body, row.values[0]);
    try testing.expect(row.values[0].len > 0);

    // And the hash on the row is the SHA-256 of exactly that text, so the guard
    // can be re-derived from what is stored rather than trusted blind.
    var hash_buf: [64]u8 = undefined;
    skill_evals_db.sha256Hex(row.values[0], &hash_buf);
    try testing.expectEqualStrings(hash_buf[0..], row.values[1]);

    // Tier 0 proposes no text -- that is the judge's job -- so this stays empty
    // rather than being back-filled with the before body.
    try testing.expectEqualStrings("", row.values[2]);
}

test "a result whose body could not be read stores no before" {
    // The `needs_human` branch has no body, so `content_at_use` must be empty
    // rather than a placeholder that would look like a snapshot.
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    try seedWorkspace(alloc, &ctx.db, "sess_cm", "ws_missing");

    // Ledger says the session read it; this workspace has no such skill, so
    // the body read fails and the row lands on the needs_human branch.
    try seedLoaded(alloc, &ctx.db, io, "sess_cm", "never-written");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_cm",
        .cwd = ".",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), out.needs_human);

    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(CAST(content_at_use AS TEXT), ''), COALESCE(CAST(base_content_hash AS TEXT), '') FROM skill_eval_results",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
}
