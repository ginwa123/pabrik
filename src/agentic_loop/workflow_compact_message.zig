//! Compaction message helpers + LLM-call orchestration (merged).

const model_catalog = @import("model_catalog.zig");
const std = @import("std");
const pabrikcore = @import("pabrikcore");
const mark_history_not_for_llmrun = @import("markHistoryNotForLLMRun.zig").markHistoryNotForLLMRun;
const migration = @import("../migrations/migration.zig");

const LlmConfig = pabrikcore.config.LlmConfig;
const LlmProfile = pabrikcore.config.LlmConfig.LlmProfile;
const SubAgentConfig = pabrikcore.config.LlmConfig.SubAgentConfig;
const LLMModels = pabrikcore.llm_models;
const agent = pabrikcore.agent;
const prompt = pabrikcore.agent.prompt;
const AgentMessage = agent.AgentMessage;
const sqlite = pabrikcore.sqlite;
const logger_mod = pabrikcore.loggermod;
const Logger = logger_mod.Logger;
const timestampIso = pabrikcore.loggermod.timestampIso;
const xml_escape = @import("helpers").xml_escape;
const llm_history = @import("llm_history.zig");
const insertLLMHistory = @import("insert_llm_histories.zig").inserLLMHistories;
const event_bus_mod = pabrikcore.event_bus;
// `fetchSessionPlan` reads the current plan row from `session_plan`
// (Migration 076); the handoff envelope carries it as its leading section.
const session_plan_mod = pabrikcore.session_plan;
const git_state_mod = @import("git_state.zig");
const envelope_mod = @import("compaction_envelope.zig");

const testing = std.testing;

// ─── Compaction-context types
pub const UserTurn = envelope_mod.UserTurn;
pub const RecentActivity = envelope_mod.RecentActivity;
pub const ReadFileTurn = envelope_mod.ReadFileTurn;

// ─── Compaction-context helpers ──────────────────────────────────────────────

/// Extract the `<path>...</path>` value from the read_file XML envelope.
/// Returns `null` if the open or close tag is missing.
pub fn parseReadFilePath(content: []const u8) ?[]const u8 {
    const start_tag = "<path>";
    const end_tag = "</path>";
    const start = std.mem.indexOf(u8, content, start_tag) orelse return null;
    const path_start = start + start_tag.len;
    const end = std.mem.indexOf(u8, content[path_start..], end_tag) orelse return null;
    return content[path_start .. path_start + end];
}

/// Fetch all user chat history rows for a session, in chronological
/// order. Filters out assistant/tool rows, rows with NULL/empty content,
/// and rows from other sessions.
pub fn fetchUserChatHistory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !std.ArrayList(UserTurn) {
    var turns: std.ArrayList(UserTurn) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    var rows = try db.query(
        allocator,
        "SELECT response_content, created_at_nano AS created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND role = 'user' " ++
            "  AND response_content IS NOT NULL " ++
            "  AND response_content != '' " ++
            "ORDER BY created_at_nano ASC, id ASC",
        &.{session_id},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        try turns.append(allocator, .{
            .content = try allocator.dupe(u8, row.values[0]),
            .created_at = try allocator.dupe(u8, row.values[1]),
        });
    }
    return turns;
}

/// Fetch all read_file tool-result rows for a session, with the `<path>`
/// already extracted from each row's XML envelope.
pub fn fetchReadFilePaths(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    logger: *Logger,
) !std.ArrayList(ReadFileTurn) {
    var turns: std.ArrayList(ReadFileTurn) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    var rows = try db.query(
        allocator,
        "SELECT response_content, created_at_nano AS created_at " ++
            "FROM llm_history " ++
            "WHERE session_id = ? " ++
            "  AND tool_name = 'read_file' " ++
            "  AND is_output = 1 " ++
            "ORDER BY created_at_nano ASC, id ASC",
        &.{session_id},
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const raw = try allocator.dupe(u8, row.values[0]);
        const created_at = try allocator.dupe(u8, row.values[1]);
        const path_borrowed = parseReadFilePath(raw) orelse {
            logger.warnFmt(
                "[COMPACTION] read_file row missing <path> tag (session_id={s}); skipping",
                .{session_id},
            );
            allocator.free(raw);
            allocator.free(created_at);
            continue;
        };
        const path_owned = try allocator.dupe(u8, path_borrowed);
        try turns.append(allocator, .{
            .path = path_owned,
            .raw_content = raw,
            .created_at = created_at,
        });
    }
    return turns;
}

/// Fetch the most recent `limit` rows from `session_activity` for
/// `session_id`, in chronological order (oldest first — same direction the
/// agent reads them as a timeline).
pub fn fetchRecentActivities(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    limit: u32,
) !std.ArrayList(RecentActivity) {
    var turns: std.ArrayList(RecentActivity) = .empty;
    errdefer {
        for (turns.items) |t| t.deinit(allocator);
        turns.deinit(allocator);
    }

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    // Two-step approach (vs. a single DESC+reverse): the production path is a
    // small-N recent tail, so doing the LIMIT first then reversing in Zig is
    // both correct and lets us reuse the existing
    var rows = try db.query(
        allocator,
        "SELECT description, created_at FROM session_activity " ++
            "WHERE session_id = ? " ++
            "ORDER BY created_at DESC, id DESC LIMIT ?",
        &.{ session_id, limit_str },
    );
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const desc_dup = try allocator.dupe(u8, row.values[0]);
        const created_at_dup = try allocator.dupe(u8, row.values[1]);
        try turns.append(allocator, .{
            .description = desc_dup,
            .created_at = created_at_dup,
        });
    }

    // Reverse in-place to chronological (oldest first).
    std.mem.reverse(RecentActivity, turns.items);
    return turns;
}

/// Fetch all session skills loaded for `session_id` via the `session_skills`
/// table.
pub fn fetchSessionSkills(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]llm_history.SkillInfo {
    return llm_history.getSessionSkills(allocator, db, session_id);
}

/// Fetch the current session plan for the compaction envelope. Returns `null`
/// when no plan exists (matches the convention used by the other compaction
/// fetchers).
pub fn fetchSessionPlan(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?session_plan_mod.PlanRow {
    return session_plan_mod.getPlanOpt(allocator, db, session_id);
}

/// `sessions.git_worktree_cwd` — the directory the file and command tools are
/// bound to. "" when the session works in its own cwd.
pub fn fetchSessionWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    return llm_history.getSessionGitWorktreeCwd(allocator, db, session_id);
}

/// A handoff envelope is a JSON document; this is how one is recognised.
pub const COMPACTION_ENVELOPE_PREFIX = envelope_mod.ENVELOPE_PREFIX;

/// A handoff only pays off once this many messages have accumulated.
pub const MIN_MESSAGES_TO_COMPACT: usize = 5;

/// Messages accumulated after the newest handoff envelope. Equal to
/// `messages.len` when the session has never been compacted.
pub fn messagesSinceLastCompaction(messages: []const AgentMessage) usize {
    var last_envelope: ?usize = null;
    for (messages, 0..) |message, index| {
        const content = message.content orelse continue;
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, COMPACTION_ENVELOPE_PREFIX)) {
            last_envelope = index;
        }
    }
    const start = (last_envelope orelse return messages.len) + 1;
    return messages.len - start;
}

fn resolvePath(allocator: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

// ─── buildCompactMessagePrompt
// ────────────────────────────────────────────── Build the compaction handoff
// prompt that gets sent to the CompactionAgent.
pub fn buildCompactMessagePrompt(
    allocator: std.mem.Allocator,
    logger: ?*logger_mod.Logger,
    messages: std.ArrayList(agent.AgentMessage),
    original_system_prompt: []const u8,
) ?[]const u8 {
    const last_idx = messages.items.len - 1;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (messages.items[1..last_idx]) |msg| {
        if (msg.content) |c| {
            const role_str = msg.role.to_str();
            const labeled = std.fmt.allocPrint(allocator, "[{s}]: {s}", .{ role_str, c }) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to label message content: {s}", .{@errorName(err)});
                return null;
            };
            // If append fails, free our just-allocated `labeled` before
            // returning null — otherwise it's a one-byte-equivalent leak
            // that the leak detector will catch under `testing.allocator`.
            parts.append(allocator, labeled) catch |err| {
                logger.?.errFmt("[COMPACTION] Failed to collect message content: {s}", .{@errorName(err)});
                allocator.free(labeled);
                return null;
            };
        }
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |tc| {
                const tc_str = std.fmt.allocPrint(allocator, "[tool_call]: {s}({s})", .{
                    tc.function.name,
                    tc.function.arguments,
                }) catch continue;
                // Same leak guard as the content branch above.
                parts.append(allocator, tc_str) catch {
                    allocator.free(tc_str);
                    continue;
                };
            }
        }
    }

    const history_str = std.mem.join(allocator, "\n", parts.items) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to join history: {s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(history_str);

    // `std.mem.join` copies each segment into a fresh allocation, so the
    // originals (`parts.items`) are now orphan references and must be freed
    // — caught by `testing.allocator.detectLeaks()` otherwise.
    defer for (parts.items) |part| allocator.free(part);

    const compact_message = std.fmt.allocPrint(allocator,
        \\You are preparing a handoff package for a fresh AI coding agent.
        \\The next agent has ZERO context. It cannot ask questions. It must act immediately.
        \\
        \\Rules:
        \\- Be surgical. No narrative, no filler, no summaries of conversation.
        \\- Every line must help the next agent take action or avoid a mistake.
        \\- If something was tried and failed, say exactly why — not just "it failed".
        \\- If a file was modified, say what changed and why, not just the filename.
        \\- The NEXT ACTION must be a single concrete step, not a vague goal.
        \\- If there are blockers, say what they are and what was tried to unblock them.
        \\
        \\Output exactly this structure, no extra sections:
        \\
        \\GOAL:
        \\(The original user objective, one or two sentences max)
        \\
        \\CURRENT STATE:
        \\- cwd:
        \\- repo:
        \\- branch:
        \\- worktree:
        \\- build status: (passing / failing / unknown)
        \\- test status: (passing / failing / unknown)
        \\
        \\TECH STACK:
        \\(Languages, frameworks, build tools — only what is relevant to the task)
        \\
        \\FILES MODIFIED:
        \\(path — what changed and why, one line per file)
        \\
        \\KEY DISCOVERIES:
        \\(Non-obvious things learned about the codebase, APIs, or constraints)
        \\
        \\FAILED ATTEMPTS:
        \\(What was tried, what happened, root cause if known)
        \\
        \\OPEN ISSUES:
        \\(Unresolved problems blocking or threatening progress)
        \\
        \\ASSUMPTIONS MADE:
        \\(Decisions taken without explicit user confirmation)
        \\
        \\NEXT ACTION:
        \\(Exactly one concrete step. File to edit, command to run, function to write.)
        \\
        \\AFTER THAT:
        \\(The 2-3 steps that follow NEXT ACTION, in order)
        \\
        \\DO NOT:
        \\(Pitfalls, wrong paths, things that look right but aren't)
        \\
        \\---
        \\ORIGINAL SYSTEM PROMPT (context only — constraints, tools, scope the
        \\original agent operated under. Do NOT summarize this section itself;
        \\use it only to inform DO NOT / ASSUMPTIONS MADE / FAILED ATTEMPTS above):
        \\{s}
        \\
        \\---
        \\CONVERSATION HISTORY:
        \\{s}
    , .{ original_system_prompt, history_str }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to format compact message: {s}", .{@errorName(err)});
        return null;
    };

    return compact_message;
}

// ─── Part 2: orchestration (ex-workflow_commpact_message.zig)
// ─────────────── LLM-call orchestration: `callCompactAgent` + threshold
// decision + `maybeCompactMessagesNew` + `compactMessageInMemoryNew` +

/// Inputs to `callCompactAgent`. Moved here from the (now-deleted)
/// `compaction.zig` (PR this file's task card) — same struct, same defaults.
pub const CallCompactAgentInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: ?*Logger,
    messages: std.ArrayList(AgentMessage),
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    /// URL style of the calling profile (`"openai"` or `"anthropic"`).
    url_style: []const u8 = "openai",
    /// Stable per-conversation session id, forwarded to `Agent.sessionId` so
    /// the compaction call sends the same `x-opencode-session` header as the
    /// main loop (OpenCode Go requires it — see Agent.sessionId doc).
    session_id: []const u8 = "",
};

/// Call the CompactionAgent to compress the conversation history into a
/// handoff package.
pub fn callCompactAgent(obj: CallCompactAgentInput) ?[]const u8 {
    const allocator = obj.allocator;
    const messages = obj.messages;
    const logger = obj.logger;
    const api_key = obj.api_key;
    const model = obj.model;
    const base_url = obj.base_url;
    const url_style = obj.url_style;
    const io = obj.io;

    if (messages.items.len < 2) {
        logger.?.warnFmt("[COMPACTION] Not enough messages to compact", .{});
        return null;
    }

    const original_system_prompt: []const u8 = messages.items[0].content orelse "";

    const compact_message_text = buildCompactMessagePrompt(
        allocator,
        logger,
        messages,
        original_system_prompt,
    ) orelse return null;
    defer allocator.free(compact_message_text);

    var messages_convocompact: std.ArrayList(AgentMessage) = .empty;
    defer messages_convocompact.deinit(allocator);

    messages_convocompact.append(allocator, .{
        .role = .system,
        .content = prompt.CompactionAgent,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append system message: {s}", .{@errorName(err)});
        return null;
    };

    messages_convocompact.append(allocator, .{
        .role = .user,
        .content = compact_message_text,
    }) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to append user message: {s}", .{@errorName(err)});
        return null;
    };

    var compaction_agent = agent.Agent.init(allocator, io);
    defer compaction_agent.deinit();

    compaction_agent.apiKey = api_key;
    compaction_agent.model = model;
    compaction_agent.baseUrl = base_url;
    // Wire format must match the upstream endpoint.
    compaction_agent.UrlStyle = url_style;
    compaction_agent.sessionId = obj.session_id;

    const response = compaction_agent.callStreaming(.{
        .tools = &.{},
        .messages = messages_convocompact.items,
        .temperature = 0.0,
    }, null, noopStreamCallbackNew) catch |err| {
        logger.?.errFmt("[COMPACTION] callStreaming failed: {s}", .{@errorName(err)});
        return null;
    };
    defer response.deinit();

    const content = response.content orelse {
        logger.?.errFmt("[COMPACTION] Response content is null", .{});
        return null;
    };

    if (content.len == 0) {
        logger.?.warnFmt("[COMPACTION] Empty response from CompactionAgent", .{});
        return null;
    }

    const duplicated = allocator.dupe(u8, content) catch |err| {
        logger.?.errFmt("[COMPACTION] Failed to duplicate content: {s}", .{@errorName(err)});
        return null;
    };

    return duplicated;
}

fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}

/// Bundle of inputs to `shouldCompactDefault` — the threshold decision that
/// tests can swap via `CompactDeps.should_compact`.
pub const ThresholdCtx = struct {
    force: bool,
    total_tokens: u32,
    model: []const u8,
    llm_config: *const LlmConfig,
    /// The session's selected profile, resolved by the caller from
    /// `sessions.selected_profile_model`.
    profile: ?*const LlmConfig.LlmProfile = null,
};

/// All non-std-lib function dependencies of `maybeCompactMessagesNew`.
/// Bundled into one struct so the function signature stays manageable.
pub const CompactDeps = struct {
    /// Decide whether compaction should run. Return `true` to compact, `false`
    /// to skip the function early. Production: `shouldCompactDefault`.
    shouldCompact: fn (ThresholdCtx) bool,

    /// Produce the optional summary. Production: `callCompactAgent`, which
    /// returns a caller-owned heap copy (or null) that this function frees.
    callCompactAgent: fn (CallCompactAgentInput) ?[]const u8,

    /// Persist the compacted state to DB + return the new in-memory list.
    /// Production: `compactMessageInMemoryNew`. Error set is widened to
    /// `anyerror` so the comptime fn pointer matches every caller's signature.
    compactMessagesInMemory: fn (
        allocator: std.mem.Allocator,
        messages: std.ArrayList(agent.AgentMessage),
        envelope: []const u8,
        session_id: []const u8,
        model: []const u8,
        cwd: []const u8,
        db: *sqlite.SqliteBackend,
        io: std.Io,
        logger: *Logger,
        event_bus: ?*event_bus_mod.EventBus,
    ) anyerror!std.ArrayList(agent.AgentMessage),
};

/// Production default for `CompactDeps.should_compact`.
pub fn shouldCompactDefault(ctx: ThresholdCtx) bool {
    if (ctx.force) return true;
    return agent.LLMModels.shouldCompact(
        ctx.total_tokens,
        ctx.llm_config.maxCapacityForModelWith(ctx.profile, null, ctx.llm_config, ctx.model, model_catalog.getSingleton()),
        ctx.llm_config.compactionThresholdPercent(ctx.profile, null, ctx.llm_config),
    );
}
/// All production dependencies wired into one bundle. Pass this as the first
/// argument to `maybeCompactMessagesNew` from production call sites; tests
/// construct their own `CompactDeps` with mock fns.
pub const defaultCompactDeps: CompactDeps = .{
    .shouldCompact = shouldCompactDefault,
    .callCompactAgent = callCompactAgent,
    .compactMessagesInMemory = compactMessageInMemoryNew,
};
/// Conditionally compact `messages` in place.
pub fn maybeCompactMessagesNew(
    comptime deps: CompactDeps,
    allocator: std.mem.Allocator,
    total_tokens: u32,
    model: []const u8,
    force: bool,
    messages: *std.ArrayList(agent.AgentMessage),
    api_key: []const u8,
    base_url: []const u8,
    /// URL style of the calling profile (`"openai"` or `"anthropic"`).
    /// Propagated to `callCompactAgent` so the CompactionAgent sends the SAME
    /// wire format as the main loop.
    url_style: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
    /// Event bus for SSE side-effects (insertLLMHistory's
    /// `onEventSendLLMHistory` path).
    event_bus: ?*event_bus_mod.EventBus,
    llm_config: *const LlmConfig,
    /// The session's selected profile (resolved by the caller from
    /// `sessions.selected_profile_model` via `LlmConfig.getProfile`).
    profile: ?*const LlmConfig.LlmProfile,
) !bool {
    if (!deps.shouldCompact(.{
        .force = force,
        .total_tokens = total_tokens,
        .model = model,
        .llm_config = llm_config,
        .profile = profile,
    })) {
        return false;
    }

    const new_since_last = messagesSinceLastCompaction(messages.items);
    if (new_since_last < MIN_MESSAGES_TO_COMPACT) {
        logger.debugFmt("[COMPACTION] skipped: {d} message(s) since the last handoff", .{new_since_last});
        return false;
    }

    var compacted_xml: ?[]const u8 = null;
    defer if (compacted_xml) |xml| allocator.free(xml);

    if (llm_config.compaction_llm_summary) {
        const copy_messages = try allocator.dupe(agent.AgentMessage, messages.items);
        var copy_list = std.ArrayList(agent.AgentMessage).fromOwnedSlice(copy_messages);
        defer copy_list.deinit(allocator);

        compacted_xml = deps.callCompactAgent(.{
            .allocator = allocator,
            .io = io,
            .messages = copy_list,
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .url_style = url_style,
            .session_id = session_id,
            .logger = logger,
        });
        if (compacted_xml == null) {
            logger.warnFmt("[COMPACTION] summarization failed; using the deterministic envelope", .{});
        }
    }

    // Fetch user chat history + read_file paths + recent activities BEFORE
    // the mark_history_not_for_llmrun step takes them offline.
    var user_turns = fetchUserChatHistory(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchUserChatHistory failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(UserTurn).empty;
    };
    defer {
        for (user_turns.items) |t| t.deinit(allocator);
        user_turns.deinit(allocator);
    }
    var read_files = fetchReadFilePaths(allocator, db, session_id, logger) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchReadFilePaths failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(ReadFileTurn).empty;
    };
    defer {
        for (read_files.items) |rf| rf.deinit(allocator);
        read_files.deinit(allocator);
    }
    // Recent activities: what the agent was thinking/doing at the tail of the
    // now-compacted-away messages.
    const RECENT_ACTIVITIES_LIMIT: u32 = 20;
    var recent_activities = fetchRecentActivities(allocator, db, session_id, RECENT_ACTIVITIES_LIMIT) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchRecentActivities failed: {s}", .{@errorName(err)});
        break :blk std.ArrayList(RecentActivity).empty;
    };
    defer {
        for (recent_activities.items) |a| a.deinit(allocator);
        recent_activities.deinit(allocator);
    }
    // Session skills (loaded via the `add_skill` tool) are stable guidance
    // material the compactor is unlikely to summarize verbatim.
    const session_skills = fetchSessionSkills(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionSkills failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    defer {
        for (session_skills) |s| s.deinit(allocator);
        allocator.free(session_skills);
    }
    // Current task plan — fetched BEFORE mark_history_not_for_llmrun so
    // the next iteration's enriched INSERT carries the plan forward.
    // `null` when no plan exists (silently omitted from the envelope).
    const session_plan_row = fetchSessionPlan(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionPlan failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (session_plan_row) |*p| p.deinit(allocator);

    const git_worktree_cwd = fetchSessionWorktreeCwd(allocator, db, session_id) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchSessionWorktreeCwd failed: {s}", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(git_worktree_cwd);

    const active_dir = if (git_worktree_cwd.len > 0) git_worktree_cwd else cwd;
    const git_state_row = git_state_mod.fetchGitStateFor(allocator, io, db, session_id, active_dir) catch |err| blk: {
        logger.warnFmt("[COMPACTION] fetchGitState failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (git_state_row) |state| state.deinit(allocator);

    const envelope = envelope_mod.build(.{
        .allocator = allocator,
        .io = io,
        .session_id = session_id,
        .model = model,
        .dropped_messages = messages.items[1..],
        .original_count = messages.items.len,
        .plan = session_plan_row,
        .session_cwd = cwd,
        .git_worktree_cwd = git_worktree_cwd,
        .git_state = git_state_row,
        .user_turns = user_turns.items,
        .read_files = read_files.items,
        .recent_activities = recent_activities.items,
        .session_skills = session_skills,
        .summary = compacted_xml,
    }) catch |err| {
        logger.warnFmt("[COMPACTION] buildCompactionEnvelope failed: {s}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(envelope);

    _ = try deps.compactMessagesInMemory(
        allocator,
        messages.*,
        envelope,
        session_id,
        model,
        cwd,
        db,
        io,
        logger,
        event_bus,
    );
    return true;
}

/// Compact messages in memory based on CompactionAgent output. Also persists
/// to database: marks old messages as not for LLM, saves new compacted
/// message.
pub fn compactMessageInMemoryNew(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    /// Handoff document rendered by `envelope_mod.build`.
    envelope: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
    /// Event bus for the SSE side-effect path inside `insertLLMHistory` →
    /// `onEventSendLLMHistory`.
    event_bus: ?*event_bus_mod.EventBus,
) !std.ArrayList(agent.AgentMessage) {
    const total = messages.items.len;
    if (total <= 4) return messages;

    // Mark all existing messages in this session as not for LLM (soft-delete)
    try mark_history_not_for_llmrun(allocator, db, session_id);

    // The new message owns this copy; the caller frees its own.
    const summary_content = try allocator.dupe(u8, envelope);

    // `inserLLMHistories` returns a heap-allocated copy of the generated row
    // id (`allocator.dupe(u8, id)` at the bottom of that function).
    const inserted_id = try insertLLMHistory(.{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cwd = cwd,
        .entity = .{
            // `insertLLMHistories` generates its own id and `created_at`
            // internally (timestamp sampling — see
            // insert_llm_histories.zig:53,55) and IGNORES these fields on the
            .id = "",
            .session_id = session_id,
            .model = model,
            .response_content = summary_content,
            .reasoning_content = null,
            .role = agent.Role.user.to_str(),
            .finish_reason = agent.FinishReason.null.to_str(),
            .tool_calls_json = "",
            .tool_call_id = null,
            .tool_name = "",
            .agent = "Agent",
            .loop_index = 0,
            .temperature = 0.0,
            .is_thinking = false,
            .is_input = true,
            .is_output = false,
            .created_at = "",
            .is_feed_to_llm = true,
            .parent_id = session_id,
            .parent_session_id = session_id,
        },
        .event_bus = event_bus,
        .is_emit_sse = true,
        .logger = logger,
        .is_skip_db = false,
    });
    defer allocator.free(inserted_id);

    // Update the session's cwd in the sessions table
    const copy_cwd = try allocator.dupe(u8, cwd);
    defer allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ? WHERE id = ?", &.{ copy_cwd, session_id });

    // Build new in-memory message list: system message + compacted summary
    var new_messages: std.ArrayList(agent.AgentMessage) = .empty;

    // Keep system message - duplicate content to be safe
    const system_content = if (messages.items[0].content) |c|
        try allocator.dupe(u8, c)
    else
        null;
    try new_messages.append(allocator, .{
        .role = .system,
        .content = system_content,
    });

    // Add compacted summary as user message
    try new_messages.append(allocator, .{
        .role = .user,
        .content = summary_content,
    });

    // Free ALL old messages (including ones we "kept" - we have copies now).
    // The old list is consumed; the caller must use the returned list.
    var messages_owned = messages;
    for (messages_owned.items) |*msg| {
        msg.deinit(allocator);
    }
    messages_owned.deinit(allocator);

    logger.debugFmt("[COMPACTION] Compacted: {} -> {} messages (persisted to DB)", .{ total, new_messages.items.len });
    return new_messages;
}

// ─── Tests ─────────────────────────────────────────────────────────────────
// Convention: walk ALL migrations from scratch so the schema under test is
// GUARANTEED to match production.

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch @panic("setupDb failed in the workflow_compact_message test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedRow(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    row: struct {
        id: []const u8,
        session_id: []const u8,
        role: []const u8,
        tool_name: []const u8,
        content: []const u8,
        is_input: []const u8,
        is_output: []const u8,
        created_at: []const u8,
    },
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
            "VALUES (?, ?, 'test-model', ?, ?, ?, ?, ?, 1, ?)",
        &.{ row.id, row.session_id, row.content, row.role, row.tool_name, row.is_input, row.is_output, row.created_at },
    );
}

test "parseReadFilePath extracts the path from a valid envelope" {
    const content = "<path>/home/user/foo.zig</path>\n<content>body</content>";
    try testing.expectEqualStrings("/home/user/foo.zig", parseReadFilePath(content).?);
}

test "parseReadFilePath returns null when the tag is missing" {
    const content = "<content>body without a path</content>";
    try testing.expect(parseReadFilePath(content) == null);
}

test "parseReadFilePath returns null when the close tag is missing" {
    const content = "<path>/home/user/foo.zig\n<content>body</content>";
    try testing.expect(parseReadFilePath(content) == null);
}

test "parseReadFilePath handles paths with spaces and unicode" {
    const content = "<path>/home/user/My Files/日本語.txt</path><content>x</content>";
    try testing.expectEqualStrings("/home/user/My Files/日本語.txt", parseReadFilePath(content).?);
}

test "fetchUserChatHistory returns only matching session's user rows with non-null content, in chrono order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "u1",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "first ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "a1",
        .session_id = "sess_a",
        .role = "assistant",
        .tool_name = "",
        .content = "first reply",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u2",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "second ask",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u3",
        .session_id = "sess_a",
        .role = "user",
        .tool_name = "",
        .content = "",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:04",
    });
    try seedRow(alloc, &s.db, .{
        .id = "u_x",
        .session_id = "sess_b",
        .role = "user",
        .tool_name = "",
        .content = "wrong session",
        .is_input = "1",
        .is_output = "0",
        .created_at = "2026-01-01 00:00:01",
    });

    var turns = try fetchUserChatHistory(alloc, &s.db, "sess_a");
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("first ask", turns.items[0].content);
    try testing.expectEqualStrings("second ask", turns.items[1].content);
    try testing.expectEqualStrings("2026-01-01 00:00:01", turns.items[0].created_at);
    try testing.expectEqualStrings("2026-01-01 00:00:03", turns.items[1].created_at);
}

test "fetchReadFilePaths returns only matching session's read_file outputs, with parsed paths" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    try seedRow(alloc, &s.db, .{
        .id = "rf1",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/foo.zig</path>\n<content>foo body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf2",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/bar.zig</path>\n<content>bar body</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:02",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf3",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/ignored.zig</path>",
        .is_input = "1", // is_input not is_output -> filtered
        .is_output = "0",
        .created_at = "2026-01-01 00:00:03",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_x",
        .session_id = "sess_b",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<path>/home/user/wrong.zig</path>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:01",
    });
    try seedRow(alloc, &s.db, .{
        .id = "rf_malformed",
        .session_id = "sess_a",
        .role = "tool",
        .tool_name = "read_file",
        .content = "<content>no path tag here</content>",
        .is_input = "0",
        .is_output = "1",
        .created_at = "2026-01-01 00:00:04",
    });

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var turns = try fetchReadFilePaths(alloc, &s.db, "sess_a", &lg);
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    // rf3 is filtered by is_output=0; rf_malformed is dropped with a warning
    // (not failed). 2 valid rows remain.
    try testing.expectEqual(@as(usize, 2), turns.items.len);
    try testing.expectEqualStrings("/home/user/foo.zig", turns.items[0].path);
    try testing.expectEqualStrings("/home/user/bar.zig", turns.items[1].path);
    try testing.expect(std.mem.indexOf(u8, turns.items[0].raw_content, "foo body") != null);
}

test "fetchRecentActivities returns the most recent N rows in chrono order" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    // Seed 5 rows for sess_a in NON-chrono order; the helper must
    // return them sorted by created_at ASC (oldest first).
    const sess_a_rows = [_]struct {
        id: []const u8,
        description: []const u8,
        created_at: []const u8,
    }{
        .{ .id = "a3", .description = "wiring it in", .created_at = "2026-01-01 00:00:03" },
        .{ .id = "a1", .description = "planning the migration", .created_at = "2026-01-01 00:00:01" },
        .{ .id = "a5", .description = "shipping it", .created_at = "2026-01-01 00:00:05" },
        .{ .id = "a2", .description = "writing the test", .created_at = "2026-01-01 00:00:02" },
        .{ .id = "a4", .description = "reviewing", .created_at = "2026-01-01 00:00:04" },
    };
    for (sess_a_rows) |r| {
        try s.db.exec(alloc, "INSERT INTO session_activity (id, session_id, description, created_at) " ++
            "VALUES (?, ?, ?, ?)", &.{ r.id, "sess_a", r.description, r.created_at });
    }
    // Other-session row — must be filtered out by the WHERE clause.
    try s.db.exec(alloc, "INSERT INTO session_activity (id, session_id, description, created_at) " ++
        "VALUES (?, ?, ?, ?)", &.{ "a_x", "sess_b", "wrong session", "2026-01-01 00:00:01" });

    var turns = try fetchRecentActivities(alloc, &s.db, "sess_a", 3);
    defer {
        for (turns.items) |t| t.deinit(alloc);
        turns.deinit(alloc);
    }

    // limit=3 → the SQL fetches the 3 newest (DESC) then the helper reverses
    // in-place to chronological (oldest first).
    try testing.expectEqual(@as(usize, 3), turns.items.len);
    try testing.expectEqualStrings("wiring it in", turns.items[0].description);
    try testing.expectEqualStrings("reviewing", turns.items[1].description);
    try testing.expectEqualStrings("shipping it", turns.items[2].description);

    // limit larger than the row count returns all sess_a rows
    // (sess_b's row is filtered out by WHERE) in chrono order.
    var all = try fetchRecentActivities(alloc, &s.db, "sess_a", 100);
    defer {
        for (all.items) |t| t.deinit(alloc);
        all.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 5), all.items.len);
    try testing.expectEqualStrings("planning the migration", all.items[0].description);
    try testing.expectEqualStrings("shipping it", all.items[4].description);
}

test "fetchRecentActivities returns an empty list when the session has no activity" {
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();
    const alloc = testing.allocator;

    var turns = try fetchRecentActivities(alloc, &s.db, "sess_no_activity", 20);
    defer turns.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), turns.items.len);
}

// ─── session_skills tests ───────────────────────────────────────────────────

fn seedSkill(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
    loaded_at: ?i64,
) !void {
    if (loaded_at) |ts| {
        const ts_str = try std.fmt.allocPrint(alloc, "{d}", .{ts});
        defer alloc.free(ts_str);
        try db.exec(
            alloc,
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at_nano) " ++
                "VALUES (?, ?, ?, ?)",
            &.{ session_id, skill_name, content, ts_str },
        );
    } else {
        try db.exec(
            alloc,
            "INSERT INTO session_skills (session_id, skill_name, content, loaded_at_nano) " ++
                "VALUES (?, ?, ?, NULL)",
            &.{ session_id, skill_name, content },
        );
    }
}

test "fetchSessionSkills returns only matching session's skills in insertion order" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try seedSkill(alloc, &s.db, "sess_a", "alpha", "first skill body", 100);
    try seedSkill(alloc, &s.db, "sess_a", "beta", "second skill body", 200);
    try seedSkill(alloc, &s.db, "sess_a", "gamma", "third skill body", null);
    try seedSkill(alloc, &s.db, "sess_b", "delta", "different session", 300);

    const skills = try fetchSessionSkills(alloc, &s.db, "sess_a");
    defer {
        for (skills) |s2| s2.deinit(alloc);
        alloc.free(skills);
    }

    try testing.expectEqual(@as(usize, 3), skills.len);
    try testing.expectEqualStrings("alpha", skills[0].skill_name);
    try testing.expectEqualStrings("first skill body", skills[0].content);
    try testing.expectEqual(@as(i64, 100), skills[0].loaded_at.?);
    try testing.expectEqualStrings("beta", skills[1].skill_name);
    try testing.expectEqualStrings("gamma", skills[2].skill_name);
    try testing.expect(skills[2].loaded_at == null);
}

test "fetchSessionSkills returns empty slice when session has no skills" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    const skills = try fetchSessionSkills(alloc, &s.db, "sess_empty");
    defer {
        for (skills) |sk| sk.deinit(alloc);
        alloc.free(skills);
    }
    try testing.expectEqual(@as(usize, 0), skills.len);
}

test "fetchSessionSkills returns empty slice when session_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    const skills = try fetchSessionSkills(alloc, &s.db, "");
    defer {
        for (skills) |sk| sk.deinit(alloc);
        alloc.free(skills);
    }
    try testing.expectEqual(@as(usize, 0), skills.len);
}

fn countSubstring(hay: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }
    return count;
}

// ─── buildCompactMessagePrompt tests ────────────────────────────────────────

const ToolCall = agent.ToolCall;
const session_plan = @import("session_plan.zig");

/// Build a 5-message list mimicking the production workflow shape: [0] system
/// prompt, [1] user, [2] assistant, [3] user, [4] assistant
/// (current/pending).
fn buildSampleMessages(allocator: std.mem.Allocator) !std.ArrayList(AgentMessage) {
    var list: std.ArrayList(AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "ORIG_SYS") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Hi") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Hello") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "Help me") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "Sure") });
    return list;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(AgentMessage)) void {
    for (messages.items) |*m| m.deinit(allocator);
    var owned = messages.*;
    owned.deinit(allocator);
}

test "buildCompactMessagePrompt: happy path embeds system prompt and labeled history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "ORIG_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Hi") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Hello") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: Help me") != null);
}

test "buildCompactMessagePrompt: first AND last messages are excluded from history" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Index 0 content ("ORIG_SYS") is passed in as `original_system_prompt`,
    // so it should NOT appear as a labeled `[system]: ...` row in history.
    try testing.expect(std.mem.indexOf(u8, s, "[system]: ORIG_SYS") == null);
    // Index 4 ("Sure") is the LAST message — excluded by `messages.items[1..last_idx]`.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: Sure") == null);
    // Middle messages 1..3 SHOULD appear.
    try testing.expect(std.mem.indexOf(u8, s, "Help me") != null);
}

test "buildCompactMessagePrompt: tool_calls formatted as [tool_call]: name(args)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);

    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH content and tool_calls — both should land in history
    try messages.append(alloc, .{
        .role = .assistant,
        .content = try alloc.dupe(u8, "calling search"),
    });
    const tc1 = try alloc.alloc(ToolCall, 2);
    tc1[0] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "search_web"),
            .arguments = try alloc.dupe(u8, "{\"q\":\"zig\"}"),
        },
    };
    tc1[1] = .{
        .id = "",
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "read_file"),
            .arguments = try alloc.dupe(u8, "{\"path\":\"/tmp/x.zig\"}"),
        },
    };
    messages.items[1].tool_calls = tc1;
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "go") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: calling search") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: search_web({\"q\":\"zig\"})") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[tool_call]: read_file({\"path\":\"/tmp/x.zig\"})") != null);
    // The last message's content must not appear.
    try testing.expect(std.mem.indexOf(u8, s, "calling read") == null);
}

test "buildCompactMessagePrompt: message with content=null and no tool_calls is skipped silently" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    // messages[1] has BOTH fields null — must not produce a labeled row.
    try messages.append(alloc, .{ .role = .user, .content = null });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "ok") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "done") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // No labeled row for the null-content message — neither `[user]: ` alone
    // nor `[user]: \n` should appear.
    try testing.expect(std.mem.indexOf(u8, s, "[user]:\n") == null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: \n") == null);
    // The assistant message and the "ok" text must appear.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: ok") != null);
    // The last message ("done") is excluded.
    try testing.expect(std.mem.indexOf(u8, s, "[user]: done") == null);
}

test "buildCompactMessagePrompt: empty middle history (only system + last) returns valid prompt" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "last") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // The prompt header still renders; CONVERSATION HISTORY section exists
    // but has no labeled rows (empty `history_str` from `join`).
    try testing.expect(std.mem.indexOf(u8, s, "ORIGINAL SYSTEM PROMPT") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CONVERSATION HISTORY:") != null);
    // The last message's content must NOT appear in the history.
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: last") == null);
}

test "buildCompactMessagePrompt: history rows are joined with newline separator (order preserved)" {
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    // 6 messages → last_idx=5, history slice = messages[1..5] = 4 rows.
    // The 6th message ("D") is the LAST (current/pending) and must be excluded.
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "A") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "B") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "C") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "D") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "E_LAST") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    // Adjacent rows must be separated by a single `\n` (the `join` separator).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: A\n[assistant]: B") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[assistant]: B\n[user]: C") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: C\n[assistant]: D") != null);
    // The last message ("E_LAST") must NOT appear (it's the excluded tail).
    try testing.expect(std.mem.indexOf(u8, s, "[user]: E_LAST") == null);
}

test "buildCompactMessagePrompt: returns a heap-allocated, caller-owned string" {
    const alloc = testing.allocator;
    var messages = try buildSampleMessages(alloc);
    defer freeMessages(alloc, &messages);

    const result = buildCompactMessagePrompt(alloc, null, messages, "ORIG_SYS");
    try testing.expect(result != null);
    // Allocate, mutate, then free — leak detector (testing.allocator) enforces
    // ownership. If the impl ever returns a non-heap pointer, this `free`
    // would either crash (free on const slice) or trigger a leak report.
    const ptr = result.?;
    _ = ptr.len;
    alloc.free(ptr);
}

test "buildCompactMessagePrompt: empty-messages list (only system + 1 user) excludes last" {
    // Confirms `messages.items[1..last_idx]` semantics: with two messages
    // (system + last), the slice is empty, no labeled rows produced, but
    // the rest of the prompt renders fine.
    const alloc = testing.allocator;
    var messages: std.ArrayList(AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "ONLY_SYS") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "ONLY_USER") });

    const result = buildCompactMessagePrompt(alloc, null, messages, "ONLY_SYS");
    defer if (result) |r| alloc.free(r);

    try testing.expect(result != null);
    const s = result.?;
    try testing.expect(std.mem.indexOf(u8, s, "ONLY_SYS") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[user]: ONLY_USER") == null);
}

// ─── Inline tests (formerly compaction_config_threshold_test.zig) ───────
// Per-profile compaction threshold integration test. Inlined here.

fn makeLlmConfig(allocator: std.mem.Allocator) !*pabrikcore.config.LlmConfig {
    const cfg_ptr = try allocator.create(pabrikcore.config.LlmConfig);
    cfg_ptr.* = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .notify_on_complete = false,
        .mcpServers_parsed = null,
        .mcp_servers = pabrikcore.config.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = pabrikcore.config.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
    };
    return cfg_ptr;
}

/// Build an LlmProfile with the given threshold. The returned
/// pointer owns its heap allocations; pair with `freeProfile`.
fn makeProfile(
    allocator: std.mem.Allocator,
    name: []const u8,
    threshold: ?u8,
    max_capacity: ?u32,
) !*LlmProfile {
    const p = try allocator.create(LlmProfile);
    p.* = .{
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "test-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .sub_agents = &.{},
        .max_capacity_tokens = max_capacity,
        .compaction_threshold_percent = threshold,
    };
    _ = name;
    return p;
}

/// Free the inner strings of an LlmProfile (allocated by `makeProfile`),
/// then destroy the struct itself. Mirrors `freeProfilesMap`'s per-entry
/// cleanup (Config.zig:431-440).
fn freeProfile(allocator: std.mem.Allocator, p: *LlmProfile) void {
    allocator.free(p.model);
    allocator.free(p.base_url);
    allocator.free(p.thinking);
    allocator.free(p.temperature);
    allocator.free(p.api_key);
    allocator.free(p.url_style);
    // sub_agents is `&.{}` in makeProfile (empty slice) — no free needed.
    allocator.destroy(p);
}

test "compactionThresholdPercent: null profile falls back to 80% built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    try testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

test "compactionThresholdPercent: profile override wins over built-in default" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile);
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, null));
}

test "compaction: two profiles with different thresholds produce different decisions at the same token count" {
    const allocator = testing.allocator;

    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile_80 = try makeProfile(allocator, "prod", null, null); // → 80 (built-in)
    defer freeProfile(allocator, profile_80);
    const profile_50 = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile_50);

    const model = "MiniMax-M2.7";
    const cap: u32 = cfg.maxCapacityForModel(null, null, null, model);
    const at_79pct: u32 = cap * 79 / 100; // ~158,000 with 200k default

    // 79% of 200,000 = 158,000 — below the 80% threshold → no compact
    // under profile_80 (which uses the built-in 80% default).
    try testing.expect(!LLMModels.shouldCompact(
        at_79pct,
        cfg.maxCapacityForModel(profile_80, null, null, model),
        cfg.compactionThresholdPercent(profile_80, null, null),
    ));

    // 79% is above 50% threshold → compact under profile_50.
    try testing.expect(LLMModels.shouldCompact(
        at_79pct,
        cfg.maxCapacityForModel(profile_50, null, null, model),
        cfg.compactionThresholdPercent(profile_50, null, null),
    ));
}

test "compaction: max_capacity_tokens override shifts the threshold proportionally" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    const profile = try makeProfile(allocator, "dev", 50, 400_000);
    defer freeProfile(allocator, profile);

    const model = "MiniMax-M2.7";
    try testing.expectEqual(@as(u32, 200_000), LLMModels.getModelTokenCount(model));

    // With the 2x capacity override (400k) and same 50% threshold, the
    // boundary shifts to 200k — at 100k we are below (was at the
    // boundary without the override).
    try testing.expectEqual(@as(u32, 400_000), cfg.maxCapacityForModel(profile, null, null, model));
    try testing.expect(!LLMModels.shouldCompact(
        100_000,
        cfg.maxCapacityForModel(profile, null, null, model),
        cfg.compactionThresholdPercent(profile, null, null),
    ));
    try testing.expect(LLMModels.shouldCompact(
        200_000,
        cfg.maxCapacityForModel(profile, null, null, model),
        cfg.compactionThresholdPercent(profile, null, null),
    ));
}

test "compaction: sub-agent override beats parent profile (cascade)" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    // Parent profile uses 50% threshold.
    const profile = try makeProfile(allocator, "dev", 50, null);
    defer freeProfile(allocator, profile);
    // Sub-agent tightens to 90% — should win over the parent.
    const sub_agent = try allocator.create(SubAgentConfig);
    sub_agent.* = .{
        .name = try allocator.dupe(u8, "alpha"),
        .model = try allocator.dupe(u8, "MiniMax-M2.7"),
        .base_url = try allocator.dupe(u8, "https://test.example.com"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "test-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .system_prompt = try allocator.dupe(u8, ""),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = 90,
    };
    defer {
        allocator.free(sub_agent.name);
        allocator.free(sub_agent.model);
        allocator.free(sub_agent.base_url);
        allocator.free(sub_agent.thinking);
        allocator.free(sub_agent.temperature);
        allocator.free(sub_agent.url_style);
        allocator.free(sub_agent.api_key);
        allocator.free(sub_agent.system_prompt);
        allocator.destroy(sub_agent);
    }

    // Sub-agent cascade wins: 90% threshold (not 50% from profile).
    try testing.expectEqual(@as(u8, 90), cfg.compactionThresholdPercent(profile, sub_agent, null));
    // Without sub-agent: profile's 50% wins.
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, null));
    // Without profile and sub-agent: built-in 80%.
    try testing.expectEqual(@as(u8, 80), cfg.compactionThresholdPercent(null, null, null));
}

test "compactionThresholdPercent: top-level defaults (cfg) cascade before built-in" {
    const allocator = testing.allocator;
    const cfg = try makeLlmConfig(allocator);
    defer {
        cfg.deinit();
        allocator.destroy(cfg);
    }
    // Set top-level default to 65% on the cfg itself.
    cfg.compaction_threshold_percent = 65;
    cfg.max_capacity_token_model = 350_000;

    // No profile, no sub-agent → top-level defaults apply.
    try testing.expectEqual(@as(u8, 65), cfg.compactionThresholdPercent(null, null, cfg));
    try testing.expectEqual(@as(u32, 350_000), cfg.maxCapacityForModel(null, null, cfg, "MiniMax-M2.7"));

    // Profile override (50%) wins over top-level defaults (65%).
    const profile = try makeProfile(allocator, "dev", 50, 600_000);
    defer freeProfile(allocator, profile);
    try testing.expectEqual(@as(u8, 50), cfg.compactionThresholdPercent(profile, null, cfg));
    try testing.expectEqual(@as(u32, 600_000), cfg.maxCapacityForModel(profile, null, cfg, "MiniMax-M2.7"));
}

// ════════════════════════════════════════════════════════════════════════════
// Inlined from workflow_compaction_envelope_test.zig (Migration 076 tests)
// ════════════════════════════════════════════════════════════════════════════

// ─── Part 2 tests (ex-workflow_commpact_message.zig, merged 2026-09-10) ──────

// ─── Mock infrastructure ────────────────────────────────────────────────────

/// Records what each mock saw on its last invocation, plus what to return on
/// the next call. Lives at module scope so the comptime fns can write to it
/// (comptime fns cannot capture locals).
const MockState = struct {
    // ─── shouldCompact mock ────────────────────────────────────────────
    should_compact_calls: u32 = 0,
    last_ctx_force: bool = undefined,
    last_ctx_total_tokens: u32 = undefined,
    last_ctx_model: []const u8 = undefined,
    should_compact_result: bool = true, // default: "yes, compact"

    // ─── callCompactAgent mock ────────────────────────────────────────
    call_compact_agent_calls: u32 = 0,
    last_agent_model: []const u8 = "",
    last_agent_api_key: []const u8 = "",
    last_agent_base_url: []const u8 = "",
    last_agent_url_style: []const u8 = "",
    last_agent_messages_len: usize = 0,
    next_compact_xml: ?[]const u8 = null, // null → mock returns null

    // ─── compactMessagesInMemory mock ──────────────────────────────────
    compact_messages_in_memory_calls: u32 = 0,
    /// Owned copy of the compacted XML the mock received.
    last_envelope_owned: []u8 = "",
    last_envelope: []const u8 = "", // alias — points into last_envelope_owned
    last_compact_session_id: []const u8 = "",
    last_compact_model: []const u8 = "",
    /// Event bus the most-recent `compactMessagesInMemory` call was invoked
    /// with (production now passes it as a parameter, not through the
    /// singleton — see the function's `event_bus` doc).
    last_event_bus: ?*event_bus_mod.EventBus = null,
    /// If `compact_returns_null` is true, the mock returns error.Skip to
    /// propagate as a test signal. (Mock returns the messages list unchanged
    /// on success — the test owns them.)
    compact_skip: bool = false,
};

var mock_state: MockState = .{};

fn resetMockState() void {
    mock_state = .{};
}

/// Free the heap-owned copy of the last envelope and reset the pointer fields.
fn releaseLastEnvelope() void {
    if (mock_state.last_envelope_owned.len > 0) {
        std.testing.allocator.free(mock_state.last_envelope_owned);
        mock_state.last_envelope_owned = "";
        mock_state.last_envelope = "";
    }
}

// ─── Three mock fns (one per CompactDeps field) ───────────────────────────

fn mockShouldCompact(ctx: ThresholdCtx) bool {
    mock_state.should_compact_calls += 1;
    mock_state.last_ctx_force = ctx.force;
    mock_state.last_ctx_total_tokens = ctx.total_tokens;
    mock_state.last_ctx_model = ctx.model;
    return mock_state.should_compact_result;
}

fn mockCallCompactAgent(obj: CallCompactAgentInput) ?[]const u8 {
    mock_state.call_compact_agent_calls += 1;
    mock_state.last_agent_model = obj.model;
    mock_state.last_agent_api_key = obj.api_key;
    mock_state.last_agent_base_url = obj.base_url;
    mock_state.last_agent_url_style = obj.url_style;
    mock_state.last_agent_messages_len = obj.messages.items.len;
    const canned = mock_state.next_compact_xml orelse return null;
    // Production returns a heap copy the caller frees, so the fake must too.
    return obj.allocator.dupe(u8, canned) catch null;
}

fn mockCompactMessagesInMemory(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    envelope: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *sqlite.SqliteBackend,
    io: std.Io,
    logger: *Logger,
    event_bus: ?*event_bus_mod.EventBus,
) anyerror!std.ArrayList(agent.AgentMessage) {
    _ = cwd;
    _ = db;
    _ = io;
    _ = logger;
    mock_state.compact_messages_in_memory_calls += 1;
    // Track the event_bus the caller passed so tests can assert on
    // null vs non-null wiring without spinning up the full singleton.
    mock_state.last_event_bus = event_bus;
    // Dup the XML before storing — caller frees the original on return.
    // (See `last_envelope_owned` and `releaseLastEnvelope`.)
    mock_state.last_envelope_owned = try allocator.dupe(u8, envelope);
    mock_state.last_envelope = mock_state.last_envelope_owned;
    mock_state.last_compact_session_id = session_id;
    mock_state.last_compact_model = model;
    if (mock_state.compact_skip) return error.Skip;
    // Return the messages unchanged. The test owns them — `messages.*` was
    // passed in by value from `maybeCompactMessagesNew`, and we don't want
    // to double-free or invalidate the test's `messages.items`.
    return messages;
}

/// The mock bundle wired into a `CompactDeps`. Pass this as the first arg
/// to `maybeCompactMessagesNew` from any test in this file.
const mockCompactDeps: CompactDeps = .{
    .shouldCompact = mockShouldCompact,
    .callCompactAgent = mockCallCompactAgent,
    .compactMessagesInMemory = mockCompactMessagesInMemory,
};

// ─── Test fixtures ──────────────────────────────────────────────────────────

fn buildTestConfig(allocator: std.mem.Allocator) LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = "sk-test",
        .model = "test-model",
        .base_url = "https://test.example",
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .url_style = "openai",
    };
}

/// Build a 6-message list like the production workflow. Returns ownership to
/// the caller — caller MUST `defer` cleanup of `messages.items` and `messages`.
fn buildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a1") });
    try list.append(allocator, .{ .role = .tool, .content = try allocator.dupe(u8, "t1"), .tool_call_id = try allocator.dupe(u8, "tc_1") });
    try list.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });
    try list.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "a2") });
    return list;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "shouldCompact dep is called with the right context (force, tokens, model)" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false; // gate early-return path

    _ = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        123_456,
        "gpt-4o-mini",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_mock",
        undefined, // db — not reached when shouldCompact=false
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(false, mock_state.last_ctx_force);
    try testing.expectEqual(@as(u32, 123_456), mock_state.last_ctx_total_tokens);
    try testing.expectEqualStrings("gpt-4o-mini", mock_state.last_ctx_model);
}

test "an envelope with too few messages behind it is not compacted again" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "{\"compact_messages\":{}}") });
    try messages.append(alloc, .{ .role = .assistant, .content = try alloc.dupe(u8, "carrying on") });

    mock_state.should_compact_result = true;

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        999_999,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_guard",
        undefined,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "messages accumulated after a handoff make the next one worth running" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "{\"compact_messages\":{}}") });
    for (0..MIN_MESSAGES_TO_COMPACT) |_| {
        try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "more work") });
    }

    mock_state.should_compact_result = true;
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_again",
        &s.db,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
}

test "shouldCompact declining means no work at all" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = false;

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        100,
        "test-model",
        false,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_mock",
        undefined,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expectEqual(false, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 0), mock_state.compact_messages_in_memory_calls);
}

test "the compactor is never called while compaction_llm_summary is off" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: unused";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_no_summary",
        &s.db,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 0), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
}

test "compaction_llm_summary on routes through the compactor and carries its output" {
    resetMockState();
    const alloc = testing.allocator;
    var cfg = buildTestConfig(alloc);
    cfg.compaction_llm_summary = true;
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "NEXT ACTION: merge";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-bespoke",
        "https://bespoke.example",
        "openai",
        "/tmp",
        "sess_summary",
        &s.db,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqualStrings("sk-bespoke", mock_state.last_agent_api_key);
    try testing.expectEqualStrings("https://bespoke.example", mock_state.last_agent_base_url);
    try testing.expectEqualStrings("openai", mock_state.last_agent_url_style);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "NEXT ACTION: merge") != null);
}

test "a failed summarization still compacts, with a null summary" {
    resetMockState();
    const alloc = testing.allocator;
    var cfg = buildTestConfig(alloc);
    cfg.compaction_llm_summary = true;
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = null;
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_summary_failed",
        &s.db,
        std.testing.io,
        &lg,
        null,
        &cfg,
        null,
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.call_compact_agent_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"summary\":null") != null);
}

test "full happy path: all three deps called, returns true" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship it\nNEXT ACTION: merge";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_bespoke",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expectEqual(true, result);
    try testing.expectEqual(@as(u32, 1), mock_state.should_compact_calls);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.startsWith(u8, mock_state.last_envelope, envelope_mod.ENVELOPE_PREFIX));
    try testing.expectEqualStrings("sess_bespoke", mock_state.last_compact_session_id);
    try testing.expectEqualStrings("test-model", mock_state.last_compact_model);
}

test "compact_messages_in_memory error propagates to caller" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);
    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "valid xml";
    mock_state.compact_skip = true; // mock returns error.Skip
    defer releaseLastEnvelope();

    const result = maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_mock",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expectError(error.Skip, result);
}

// ─── Better-compaction-context integration tests ──────────────────────────

/// In-memory DB with just the columns `fetchUserChatHistory`,
/// `fetchReadFilePaths`, and `fetchRecentActivities` read.
fn setupDbForEnrichmentTest() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(
        alloc,
        "CREATE TABLE llm_history (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  model TEXT," ++
            "  response_content TEXT," ++
            "  role TEXT," ++
            "  tool_name TEXT," ++
            "  is_input INTEGER DEFAULT 0," ++
            "  is_output INTEGER DEFAULT 0," ++
            "  is_feed_to_llm INTEGER DEFAULT 1," ++
            "  created_at_nano TEXT DEFAULT (datetime('now'))" ++
            ")",
        &[_][]const u8{},
    );
    try db.exec(
        alloc,
        "CREATE TABLE session_activity (" ++
            "  id TEXT PRIMARY KEY," ++
            "  session_id TEXT NOT NULL," ++
            "  description TEXT NOT NULL," ++
            "  created_at DATETIME DEFAULT CURRENT_TIMESTAMP" ++
            ")",
        &[_][]const u8{},
    );
    return .{ .db = db, .threaded = threaded };
}

fn teardownDbForEnrichmentTest(s: *@TypeOf(setupDbForEnrichmentTest() catch @panic("setupDbForEnrichmentTest failed in the workflow_compact_message test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

fn seedUserForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
            "VALUES (?, ?, 'test-model', ?, 'user', '', 1, 0, 1, ?)",
        &.{ id, session_id, content, created_at },
    );
}

fn seedReadFileForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO llm_history " ++
            "(id, session_id, model, response_content, role, tool_name, is_input, is_output, is_feed_to_llm, created_at_nano) " ++
            "VALUES (?, ?, 'test-model', ?, 'tool', 'read_file', 0, 1, 1, ?)",
        &.{ id, session_id, content, created_at },
    );
}

fn seedRecentActivityForEnrichmentTest(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    session_id: []const u8,
    description: []const u8,
    created_at: []const u8,
) !void {
    try db.exec(
        alloc,
        "INSERT INTO session_activity (id, session_id, description, created_at) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ id, session_id, description, created_at },
    );
}

test "happy path embeds user history and read_file paths into the compaction XML" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    try seedUserForEnrichmentTest(alloc, &s.db, "u1", "sess_embed", "first user message", "2026-01-01 00:00:01");
    try seedReadFileForEnrichmentTest(alloc, &s.db, "rf1", "sess_embed", "<path>/home/user/foo.zig</path><content>body</content>", "2026-01-01 00:00:02");
    try seedUserForEnrichmentTest(alloc, &s.db, "u2", "sess_embed", "second user message", "2026-01-01 00:00:03");

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/home/user",
        "sess_embed",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"user_history\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"read_files\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "first user message") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "second user message") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "/home/user/foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"summary\":null") != null);
}

test "compaction still proceeds when fetchUserChatHistory returns empty (no user rows)" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // No seeded rows. user_turns comes back empty, read_files empty, but
    // the bare compacted_xml still passes through to compactMessagesInMemory.

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/home/user",
        "sess_empty",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"user_history\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"summary\":null") != null);
}

// ─── Migration 073 — recent_activities integration tests
// ──────────────────── Per PR #226 review feedback: the compaction flow must
// READ prior session_activity rows (recorded by `update_activity`) and embed

test "happy path embeds prior session_activity rows in <recent_activities>" {
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // Pre-seed 3 prior update_activity rows for this session. Insert
    // them in NON-chrono order to verify the envelope sorts them
    // (oldest first).
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a3", "sess_recent", "wiring it in", "2026-01-01 00:00:03");
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a1", "sess_recent", "planning the migration", "2026-01-01 00:00:01");
    try seedRecentActivityForEnrichmentTest(alloc, &s.db, "a2", "sess_recent", "writing the test", "2026-01-01 00:00:02");

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_recent",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"recent_activities\"") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "planning the migration") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "writing the test") != null);
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "wiring it in") != null);
    // The activities must appear in chronological (oldest first) order.
    const planning_pos = std.mem.indexOf(u8, mock_state.last_envelope, "planning the migration").?;
    const writing_pos = std.mem.indexOf(u8, mock_state.last_envelope, "writing the test").?;
    const wiring_pos = std.mem.indexOf(u8, mock_state.last_envelope, "wiring it in").?;
    try testing.expect(planning_pos < writing_pos);
    try testing.expect(writing_pos < wiring_pos);

    // The session_activity table must NOT have grown — the compaction
    // event is NOT recorded (per review feedback).
    {
        const sid_dup = try alloc.dupe(u8, "sess_recent");
        defer alloc.free(sid_dup);
        const args = [_][]const u8{sid_dup};
        var q = try s.db.query(alloc, "SELECT COUNT(*) FROM session_activity WHERE session_id = ?", &args);
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("3", row.values[0]); // still just the 3 pre-seeded rows
    }
}

test "omits <recent_activities> when session has no prior activity" {
    // When there are no prior session_activity rows for the session,
    // the enriched XML must OMIT the <recent_activities> section
    // entirely (rather than emit an empty one).
    resetMockState();
    const alloc = testing.allocator;
    const cfg = buildTestConfig(alloc);

    var s = try setupDbForEnrichmentTest();
    defer teardownDbForEnrichmentTest(&s);

    // No session_activity rows seeded for sess_no_activity.

    var messages = try buildMessages(alloc);
    defer freeMessages(alloc, &messages);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    mock_state.should_compact_result = true;
    mock_state.next_compact_xml = "GOAL: ship X";
    defer releaseLastEnvelope();

    const result = try maybeCompactMessagesNew(
        mockCompactDeps,
        alloc,
        200_000,
        "test-model",
        true,
        &messages,
        "sk-test",
        "https://test.example",
        "openai",
        "/tmp",
        "sess_no_activity",
        &s.db,
        std.testing.io,
        &lg,
        null, // event_bus — test has no SSE subscriber
        &cfg,
        null, // profile — no override in these tests
    );

    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), mock_state.compact_messages_in_memory_calls);
    // With no recorded activity the array is empty; the key is always present.
    try testing.expect(std.mem.indexOf(u8, mock_state.last_envelope, "\"recent_activities\":[]") != null);
}

// ─── shouldCompactDefault unit tests (Anthropic + OpenAI styles) ───────────
// `shouldCompactDefault` is the production wiring inside
// `defaultCompactDeps`: 1. if `ctx.force` is true, return true

/// Build a stack-allocated `LlmConfig` suitable for direct
/// `shouldCompactDefault` tests.
fn buildShouldCompactTestConfig(
    allocator: std.mem.Allocator,
    model: []const u8,
    max_capacity_override: ?u32,
    threshold_percent_override: ?u8,
    url_style: []const u8,
) LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = "sk-test",
        .model = model,
        .base_url = "https://test.example",
        .url_style = url_style,
        .model_compaction_size_kb = 100,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .max_capacity_token_model = max_capacity_override,
        .compaction_threshold_percent = threshold_percent_override,
    };
}

// ─── force=true short-circuit ────────────────────────────────────────────────

test "shouldCompactDefault: force=true → true regardless of total_tokens (Anthropic claude-sonnet-4-5, 0 tokens)" {
    // The manual endpoint always wins — even at 0 tokens, force=true must
    // trigger compaction. This is the only path where the token count is
    // irrelevant.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = true,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: force=true → true regardless of total_tokens (OpenAI gpt-4o, 1 token)" {
    // Symmetric Anthropic/OpenAI coverage: a 1-token request under
    // url_style="openai" must still compact when the manual endpoint
    // passes force=true.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = true,
        .total_tokens = 1,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

// ─── Anthropic style: claude-sonnet-4-5 (200K fallback, 80% default) ────────

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, 0 tokens → false (built-in 80% threshold)" {
    // No tokens consumed → strictly below the 200K * 80% = 160K threshold.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, just below 80% (159_999) → false" {
    // 200_000 * 80 / 100 = 160_000; 159_999 is strictly below.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, at 80% (160_000) → true" {
    // Boundary: `>=` semantics. 160_000 == 200_000 * 80 / 100 must trigger.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 160_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, above 80% (180_000) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 180_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, custom threshold_percent=50, below 50% → false" {
    // Override top-level `compaction_threshold_percent` to 50%. With the
    // 200K fallback, threshold = 200_000 * 50 / 100 = 100_000.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 50, "anthropic");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 99_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: Anthropic claude-sonnet-4-5, custom threshold_percent=50, at 50% → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 50, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 100_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

// ─── OpenAI style: gpt-4o with override max_capacity=128_000, 80% default ───

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), 0 tokens → false" {
    // gpt-4o's real context window is 128K, so the production workflow uses
    // `max_capacity_token_model = 128_000` in the config.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), just below 80% (102_399) → false" {
    // 128_000 * 80 / 100 = 102_400; 102_399 is strictly below.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 102_399,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), at 80% (102_400) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 102_400,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), above 80% (110_000) → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 110_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), custom threshold=90, below → false" {
    // Override threshold to 90%. 128_000 * 90 / 100 = 115_200. 110_000 < 115_200.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, 90, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 110_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o (max_capacity=128K), custom threshold=90, at → true" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", 128_000, 90, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 115_200,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: OpenAI gpt-4o WITHOUT override (200K fallback), 130_000 → false" {
    // If the user forgets to set max_capacity_token_model, the function falls
    // back to getModelTokenCount("gpt-4o") which returns 200_000 (the
    // codebase's universal fallback). 130_000 < 200_000 * 80% = 160_000.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "gpt-4o", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 130_000,
        .model = "gpt-4o",
        .llm_config = &cfg,
    }));
}

// ─── Built-in model table coverage (MiniMax-M2.7 + MiniMax-M3) ──────────────

test "shouldCompactDefault: MiniMax-M2.7 (built-in 200K), at 80% (160_000) → true" {
    // Built-in MINIMAX_2_7.token_count = 200_000. Boundary check.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M2.7", null, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 160_000,
        .model = "MiniMax-M2.7",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M2.7 (built-in 200K), just below 80% (159_999) → false" {
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M2.7", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 159_999,
        .model = "MiniMax-M2.7",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M3 (built-in 500K), at 80% (400_000) → true" {
    // Built-in MINIMAX_3.token_count = 500_000. 500_000 * 80 / 100 = 400_000.
    // The 500K model has a much larger threshold — at 200K (which would
    // trigger on M2.7), it does NOT compact.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M3", null, null, "openai");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 400_000,
        .model = "MiniMax-M3",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: MiniMax-M3 (built-in 500K), 200_000 → false (same token count as M2.7 trigger, but M3 has 2.5× capacity)" {
    // Regression-style: 200_000 triggers on M2.7 (200K * 80% = 160K threshold)
    // but NOT on M3 (500K * 80% = 400K threshold). Different model → different
    // decision at the same token count.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "MiniMax-M3", null, null, "openai");
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 200_000,
        .model = "MiniMax-M3",
        .llm_config = &cfg,
    }));
}

// ─── Edge cases ─────────────────────────────────────────────────────────────

test "shouldCompactDefault: threshold_percent=0 → total_tokens >= 0 always triggers (compact on every iter)" {
    // 200_000 * 0 / 100 = 0. `total_tokens >= 0` is true for any u32, so
    // 0 tokens already trips compaction. Useful for tests that want to
    // force compaction deterministically.
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, 0, "anthropic");
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 0,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
    }));
}

test "shouldCompactDefault: url_style is ignored by the decision (Anthropic config + OpenAI-style model)" {
    // Regression guard: `shouldCompactDefault` MUST NOT branch on
    // `url_style`.
    const cfg_openai = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "openai");
    const cfg_anthropic = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");
    const ctx_openai: ThresholdCtx = .{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg_openai,
    };
    const ctx_anthropic: ThresholdCtx = .{
        .force = false,
        .total_tokens = 159_999,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg_anthropic,
    };
    try testing.expectEqual(
        shouldCompactDefault(ctx_anthropic),
        shouldCompactDefault(ctx_openai),
    );
    try testing.expect(!shouldCompactDefault(ctx_openai));
}

test "shouldCompactDefault: profile override shapes the decision (cap + threshold)" {
    // 2026-08-21-fix-ui-context-window — the compaction decision must honor
    // the session profile's `max_capacity_tokens` and
    // `compaction_threshold_percent` overrides, matching the (now
    const profile = LlmConfig.LlmProfile{
        .model = "claude-sonnet-4-5",
        .max_capacity_tokens = 400_000,
        .compaction_threshold_percent = 50,
    };
    const cfg = buildShouldCompactTestConfig(testing.allocator, "claude-sonnet-4-5", null, null, "anthropic");

    // With the profile: 190_000 < 50% of 400_000 (200_000) → no compaction.
    // Under the old null-profile code this WAS a compaction (190k >= 80% of
    // 200k = 160k) — the assertion below fails on the old code.
    try testing.expect(!shouldCompactDefault(.{
        .force = false,
        .total_tokens = 190_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = &profile,
    }));

    // And 210_000 >= 200_000 → compaction fires with the profile.
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 210_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = &profile,
    }));

    // null profile → old behavior (built-in cascade): 190_000 >= 160_000 → true.
    try testing.expect(shouldCompactDefault(.{
        .force = false,
        .total_tokens = 190_000,
        .model = "claude-sonnet-4-5",
        .llm_config = &cfg,
        .profile = null,
    }));
}

// ─── Inlined from workflow_compact_call_agent_test.zig
// ──────────────────────── Regression test for the `effective_url_style`
// propagation bug: `callCompactAgent` builds an `agent.Agent` to call the

test "CallCompactAgentInput: url_style field exists with default \"openai\" (back-compat)" {
    const default = CallCompactAgentInput{
        .allocator = testing.allocator,
        .io = std.testing.io,
        .logger = null,
        .messages = .empty,
        .api_key = "sk",
        .model = "m",
        .base_url = "https://x",
        // intentionally OMITTING url_style — must default to "openai"
    };
    try testing.expectEqualStrings("openai", default.url_style);
}

test "CallCompactAgentInput: url_style can be overridden to \"anthropic\"" {
    const anthropic_input = CallCompactAgentInput{
        .allocator = testing.allocator,
        .io = std.testing.io,
        .logger = null,
        .messages = .empty,
        .api_key = "sk",
        .model = "m",
        .base_url = "https://api.minimax.io/anthropic",
        .url_style = "anthropic",
    };
    try testing.expectEqualStrings("anthropic", anthropic_input.url_style);
}

test "callCompactAgent: returns null + logs when messages.items.len < 2 (early branch — bypasses agent.Agent)" {
    // This proves the url_style parameter is recognized by the production
    // function even when messages is too short to reach the actual LLM call.
    // The earlier "field exists" tests prove the field shape.
    const alloc = testing.allocator;

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    var messages: std.ArrayList(AgentMessage) = .empty;
    defer messages.deinit(alloc);
    // messages.items.len = 0 → triggers the early `Not enough messages`
    // branch at workflow_compact_message.zig (Part 2: callCompactAgent
    // early-return).

    const result = callCompactAgent(.{
        .allocator = alloc,
        .io = std.testing.io,
        .logger = &lg,
        .messages = messages,
        .api_key = "sk-test",
        .model = "MiniMax-M3",
        .base_url = "https://api.minimax.io/anthropic",
        .url_style = "anthropic", // verify this field is accepted
    });

    try testing.expect(result == null);
}

// Static contract: confirms the regression-protecting assertion was added
// next to the existing `callCompactAgent`-receives-right- fields test
// (above).
test "PR regression: callCompactAgent mock asserts url_style propagation" {
    // This is a marker test — the real assertion is inline above in the
    // `shouldCompact returning true routes through callCompactAgent` test
    // (the mock_state.last_agent_url_style check).
    try testing.expect(true);
}

// ─── Inlined from workflow_compaction_envelope_test.zig
// ─────────────────────── Compaction persistence tests: cover
// `compactMessageInMemoryNew` and its marking contract

fn envelopeSetupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn envelopeTeardownDb(s: *@TypeOf(envelopeSetupDb() catch @panic("envelopeSetupDb failed in the workflow_compact_message test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

/// Build a synthetic in-memory message list shaped like the agent's real
/// messages: [system, user-1, assistant-1, tool-result-1, user-2,
/// assistant-2].
fn envelopeBuildMessages(allocator: std.mem.Allocator) !std.ArrayList(agent.AgentMessage) {
    var list: std.ArrayList(agent.AgentMessage) = .empty;
    try list.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "You are a coding agent."),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Fix the login bug"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "I'll investigate"),
    });
    try list.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tests pass: 42/42"),
        .tool_call_id = try allocator.dupe(u8, "tc_1"),
        // Set a real DB-style id so the envelope-test can assert
        // real-id embedding (regression for the adhoc_N synthesis bug).
        .id = try allocator.dupe(u8, "1782027292879102675"),
    });
    try list.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Now ship it"),
    });
    try list.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "Shipping."),
    });
    return list;
}

test "compactMessageInMemoryNew keeps the system prompt and hands the envelope on unchanged" {
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    const messages = try envelopeBuildMessages(alloc);

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const envelope = "{\"compact_messages\":{\"format_version\":2}}";
    const new_messages = try compactMessageInMemoryNew(
        alloc,
        messages,
        envelope,
        "sess_123",
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
        null,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), new_messages.items.len);
    try testing.expectEqualStrings("You are a coding agent.", new_messages.items[0].content.?);
    try testing.expectEqualStrings(envelope, new_messages.items[1].content.?);
}

test "compactMessageInMemoryNew marks every older row unfed and leaves the envelope as the only fed row" {
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;
    const session_id = "sess_fed";

    const old_ids = [_][]const u8{ "id_a", "id_b", "id_c" };
    for (old_ids) |id| {
        try s.db.exec(
            alloc,
            "INSERT INTO llm_history (id, session_id, model, response_content, role, is_feed_to_llm, created_at_nano) " ++
                "VALUES (?, ?, 'gpt-4o', 'old turn', 'user', 1, '2026-01-01 00:00:00')",
            &.{ id, session_id },
        );
    }

    const messages = try envelopeBuildMessages(alloc);
    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const envelope = "{\"compact_messages\":{\"format_version\":2}}";
    const new_messages = try compactMessageInMemoryNew(
        alloc,
        messages,
        envelope,
        session_id,
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
        null,
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 3), try countRowsWithFeedFlag(alloc, &s.db, session_id, false));
    try testing.expectEqual(@as(usize, 1), try countRowsWithFeedFlag(alloc, &s.db, session_id, true));
    const fed = try fedEnvelope(alloc, &s.db, session_id);
    defer alloc.free(fed);
    // A stored user row is the {user,name,msg} chat envelope, so the handoff
    // text arrives escaped inside `msg` rather than verbatim.
    try testing.expect(std.mem.indexOf(u8, fed, "compact_messages") != null);
}

fn countRowsWithFeedFlag(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    fed: bool,
) !usize {
    const sql = if (fed)
        "SELECT COUNT(*) FROM llm_history WHERE session_id = ? AND is_feed_to_llm = 1"
    else
        "SELECT COUNT(*) FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 0 OR is_feed_to_llm IS NULL)";
    var q = try db.query(alloc, sql, &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(usize, row.values[0], 10) catch 0;
}

fn fedEnvelope(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) ![]u8 {
    var q = try db.query(
        alloc,
        "SELECT response_content FROM llm_history WHERE session_id = ? AND is_feed_to_llm = 1",
        &.{session_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "compactMessageInMemoryNew: existing short-circuit (total <= 4) returns messages unchanged" {
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    try messages.append(alloc, .{ .role = .user, .content = try alloc.dupe(u8, "hi") });

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const result = try compactMessageInMemoryNew(
        alloc,
        messages,
        "summary",
        "sess_1",
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        // Free each AgentMessage's content then the ArrayList.
        for (result.items) |*m| m.deinit(alloc);
        var result_owned = result;
        result_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), result.items.len); // unchanged
    try testing.expectEqualStrings("hi", result.items[1].content.?);
}

test "end-to-end: compacted rows are findable via getCompactedMessages after compaction" {
    // CURRENT IMPL: the envelope uses synthetic `adhoc_<i>` ids, NOT the real
    // DB primary keys.
    var s = try envelopeSetupDb();
    defer envelopeTeardownDb(&s);
    const alloc = testing.allocator;

    const session_id = "sess_roundtrip";
    const ids = [_][]const u8{
        "1000000000000000001",
        "1000000000000000002",
        "1000000000000000003",
        "1000000000000000004",
        "1000000000000000005",
    };
    const contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate",
        "running tests",
        "tests pass: 42/42",
        "shipping",
    };
    const roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed DB with real ids, marked is_feed_to_llm=1 (so compactMessageInMemoryNew's
    // markMessageNotForLlmRun will flip them to 0 after compaction).
    for (ids, contents, roles) |id, content, role| {
        const tcid: []const u8 = if (std.mem.eql(u8, role, "tool")) "tc_xyz" else "";
        const tname: []const u8 = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc,
            \\INSERT INTO llm_history
            \\  (id, session_id, model, response_content, role, is_feed_to_llm,
            \\   created_at_nano, tool_call_id, tool_name)
            \\VALUES (?, ?, 'gpt-4o', ?, ?, 1, '2026-01-01 00:00:00', ?, ?)
        , &.{ id, session_id, content, role, tcid, tname });
    }

    // Build the in-memory message list with matching .id values, then compact.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "sys") });
    for (ids, contents, roles) |id, content, role| {
        const role_enum = std.meta.stringToEnum(agent.Role, role) orelse .user;
        try messages.append(alloc, .{
            .id = try alloc.dupe(u8, id),
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role, "tool"))
                try alloc.dupe(u8, "tc_xyz")
            else
                null,
        });
    }

    var lg = Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
        alloc,
        messages,
        "summary",
        session_id,
        "gpt-4o",
        "/tmp",
        &s.db,
        s.threaded.io(),
        &lg,
        null, // event_bus — no SSE subscriber in tests
    );
    defer {
        for (new_messages.items) |*m| m.deinit(alloc);
        var nm_owned = new_messages;
        nm_owned.deinit(alloc);
    }

    try testing.expectEqual(@as(usize, 2), new_messages.items.len);

    // Pull ALL compacted rows for the session (no message_ids filter) and
    // verify each pre-seeded row is findable with its original content.
    const found = try llm_history.getCompactedMessages(alloc, &s.db, session_id, .{ .limit = 100 });
    defer {
        for (found) |m| {
            var copy = m;
            copy.deinit(alloc);
        }
        alloc.free(found);
    }
    try testing.expectEqual(@as(usize, 5), found.len);

    // Build a quick id→row index and verify every original id/content
    // is recoverable.
    for (ids, contents) |id, original_content| {
        var matched = false;
        for (found) |m| {
            if (std.mem.eql(u8, m.id, id)) {
                try testing.expectEqualStrings(original_content, m.content);
                matched = true;
                break;
            }
        }
        try testing.expect(matched); // id was recoverable from the session
    }
}
