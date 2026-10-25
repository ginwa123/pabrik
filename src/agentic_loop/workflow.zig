const std = @import("std");
const testing = std.testing;

pub const pabrikcore = @import("pabrikcore");

const llm_history = @import("llm_history.zig");
const build_msg_prompt = @import("prompts_build_messages_for_agent_prompt.zig");
const models = @import("models.zig");
pub const on_event_sent = @import("on_event_sent.zig");
const tool_registry = @import("tools_equipped.zig");
const handle_tool = @import("handle_tool.zig").handle_tool;
const skill_evals_config = @import("skill_evals_config.zig");
const session_llm_config = @import("session_llm_config.zig");
const ask_user_pending = @import("ask_user_pending.zig");
// `MAIN_AGENT_ONLY_NAMES` (spawn_sub_agent, ask_user) — the tools a sub-agent
// must not re-equip via `use_tool`.
const ask_user_mod = pabrikcore.ask_user;
const notifications = pabrikcore.notifications_mod;

const sqlite = pabrikcore.sqlite;
const migration_mod = pabrikcore.migrations_mod.migration;
const migration = migration_mod;
const config_mod = pabrikcore.config;
const logger_mod = pabrikcore.loggermod;
const agent = pabrikcore.agent;
const prompt = pabrikcore.agent.prompt;
const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");

const json = std.json;

const event_bus_mod = pabrikcore.event_bus;
const SqliteBackend = pabrikcore.sqlite.SqliteBackend;

const compact_message_mod = @import("workflow_compact_message.zig");
const delete_queue_worker_mod = @import("delete_queue_worker.zig");
const delete_worker_mod = @import("delete_worker.zig");
const get_llm_histories_mod = @import("get_llm_histories.zig");
const get_queue_message_mod = @import("get_queue_message.zig");
const has_queue_message_mod = @import("has_queue_messagge.zig");
const insert_llm_histories_mod = @import("insert_llm_histories.zig");
const file_attachments = @import("file_attachments.zig");
const insert_queue_message_mod = @import("insert_queue_message.zig");
const is_session_kanban_mod = @import("is_session_kanban.zig");
const is_worker_cancelled_mod = @import("is_worker_cancelled.zig");
const is_worker_running_mod = @import("is_worker_running.zig");
const mark_history_not_for_llmrun_mod = @import("markHistoryNotForLLMRun.zig");
const retry_delay_ms_mod = @import("retry_delay_ms.zig");
const session_lock = @import("session_lock.zig");
const session_skills_mod = @import("session_skills.zig");
const tool_eligibility = @import("tool_eligibility.zig");
const progressive_catalog = @import("progressive_catalog.zig");
const progressive_tools_mod = pabrikcore.progressive_tools;
const sse_mod = @import("sse.zig");
const stream_snapshot = @import("stream_snapshot.zig");
const sse_on_event_send_session_mod = @import("sse_on_event_send_session.zig");
const sse_send_event_worker_mod = @import("sse_send_event_worker.zig");
const update_session_name_mod = @import("update_session_name.zig");
const update_worker_mod = @import("update_worker.zig");

// Re-exports (formerly from mod.zig).
pub const updateWorker = update_worker_mod.updateWorker;
pub const UpdateWorkerInput = update_worker_mod.UpsertWorkerInput;
pub const insertQueueMessage = insert_queue_message_mod.insertQueueMessage;
pub const InsertQueueMessageInput = insert_queue_message_mod.InsertQueueMessageInput;
pub const getQueueMessage = get_queue_message_mod.getQueueMessages;
pub const GetQueueMessageInput = get_queue_message_mod.GetQueueMessageInput;
pub const isWorkerCancelled = is_worker_cancelled_mod.isWorkerCancelled;
pub const IsWorkerCancelledInput = is_worker_cancelled_mod.IsWorkerCancelledInput;
pub const SseEvent = sse_mod.SseEvent;
pub const onEventSendWorkers = sse_send_event_worker_mod.onEventSendWorkers;
pub const OnEventInputWorkers = sse_send_event_worker_mod.OnEventInputWorkers;
pub const DeleteWorkerInput = delete_worker_mod.DeleteWorkerInput;
pub const deleteWorker = delete_worker_mod.deleteWorker;
pub const GetLLMHistoriesInput = get_llm_histories_mod.GetLLMHistoriesInput;
pub const getLLMHistories = get_llm_histories_mod.getLLMHistories;
pub const LLMHistory = @import("llm_history_row.zig").LLMHistory;
pub const onEventSendLLMHistory = @import("sse_on_event_send_llm_history.zig").onEventSendLLMHistory;
pub const InsertLLMHistoriesInput = insert_llm_histories_mod.InsertLLMHistoriesInput;
pub const insertLLMHistories = insert_llm_histories_mod.inserLLMHistories;
pub const SkillInfo = session_skills_mod.SkillInfo;
pub const hasQueuedMessages = has_queue_message_mod.hasQueuedMessages;
pub const DeleteQueueMessagesInput = delete_queue_worker_mod.DeleteQueueMessagesInput;
pub const deleteQueuedMessage = delete_queue_worker_mod.deleteQueuedMessage;
pub const isWorkerRunning = is_worker_running_mod.isWorkerRunning;
pub const CallCompactAgentInput = compact_message_mod.CallCompactAgentInput;
pub const callCompactAgent = compact_message_mod.callCompactAgent;
pub const buildCompactMessagePrompt = compact_message_mod.buildCompactMessagePrompt;
pub const fetchUserChatHistory = compact_message_mod.fetchUserChatHistory;
pub const fetchReadFilePaths = compact_message_mod.fetchReadFilePaths;
pub const fetchRecentActivities = compact_message_mod.fetchRecentActivities;
pub const compaction_envelope = @import("compaction_envelope.zig");
pub const parseReadFilePath = compact_message_mod.parseReadFilePath;
pub const UserTurn = compact_message_mod.UserTurn;
pub const ReadFileTurn = compact_message_mod.ReadFileTurn;
pub const RecentActivity = compact_message_mod.RecentActivity;
pub const isSessionKanban = is_session_kanban_mod.isSessionKanban;
pub const OnEventInputSessions = sse_on_event_send_session_mod.OnEventInputSessions;
pub const onEventSendSessions = sse_on_event_send_session_mod.onEventSendSessions;
pub const updateSessionName = update_session_name_mod.updateSessionName;
pub const parsing_mod = @import("parsing.zig");
pub const tools = @import("tools.zig");
pub const prompts_mod = @import("prompts.zig");
pub const mark_history_not_for_llmrun = mark_history_not_for_llmrun_mod.markHistoryNotForLLMRun;
pub const makeWorkingDirectoryContext = prompts_mod.makeWorkingDirectoryContext;
pub const retryDelayMs = retry_delay_ms_mod.retryDelayMs;
pub const RetryDelayMsInput = retry_delay_ms_mod.RetryDelayMsInput;

pub const maybeCompactMessagesNew = compact_message_mod.maybeCompactMessagesNew;
const defaultCompactDeps = compact_message_mod.defaultCompactDeps;
pub const compactMessageInMemoryNew = compact_message_mod.compactMessageInMemoryNew;

// Thread-safe set of active session loop IDs
pub const StreamingContext = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8 = "",
    chunk_index: usize = 0,
};

pub const CallbackAiWorkerFlow = struct {
    pub fn callback(data: RunParamsNew) void {
        const keyword = "CALLBACK_AI_WORKER_FLOW";
        const di = pabrikcore.getSingleton() catch return;
        const logger = di.logger;

        var arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
        defer arena_allocator.deinit();
        const allocator = arena_allocator.allocator();

        const event_bus = di.event_bus;
        const db = di.db;
        const io = di.io;
        const session_id = data.session_id;
        const cwd = data.cwd;
        const environment = di.environment;

        runAgenticMultiStepnew(.{
            .allocator = allocator,
            .db = db,
            .io = io,
            .logger = logger,
            .event_bus = event_bus,
            .di = di,
            .environment = environment,
        }, data) catch |err| {
            logger.errFmt("[{s}] Failed to run agentic workflow: {s}\n", .{ keyword, @errorName(err) });

            deleteWorker(.{
                .allocator = allocator,
                .db = db,
                .logger = logger,
                .session_id = session_id,
                .event_bus = di.event_bus,
                .is_emit_sse = true,
            }) catch |error_sqlite| {
                logger.errFmt("[{s}] Failed to delete worker: {s}\n", .{ keyword, @errorName(error_sqlite) });
            };

            // For TooManyRetries, the inner bail already saved a rich
            // diagnostic to chat history (with the retry reason, count, and
            // source).
            if (err == error.TooManyRetries) {
                logger.errFmt("[{s}] TooManyRetries\n", .{keyword});
                return;
            }

            const initial_agent_state = llm_history.get_current_agent_by_session_id(
                allocator,
                db,
                session_id,
            ) catch |err_agent_state| {
                logger.errFmt("[{s}] Failed to get current agent state: {s}\n", .{ keyword, @errorName(err_agent_state) });
                return;
            };
            const initial_agent = initial_agent_state.agent;

            const error_message = std.fmt.allocPrint(allocator, "Agent Pabrik System error, the actual error is ->>>> {s}\n", .{@errorName(err)}) catch |err_fmt| {
                logger.errFmt("[{s}] Failed to format error message: {s}\n", .{ keyword, @errorName(err_fmt) });
                return;
            };

            const id = std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}) catch return;
            defer allocator.free(id);

            const created_at = std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}) catch return;
            defer allocator.free(created_at);

            // The model this error row names is the session owner's under
            // `--auth` — same resolution module the loop below uses.
            const error_row_model = (session_llm_config.forSession(allocator, db, session_id) orelse
                pabrikcore.getLlmConfig(di)).model;
            _ = insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = cwd, .entity = .{ .id = id, .session_id = session_id, .model = error_row_model, .response_content = error_message, .reasoning_content = null, .role = agent.Role.user.to_str(), .finish_reason = "null", .tool_calls_json = "", .tool_call_id = null, .agent = initial_agent, .loop_index = 0, .temperature = initial_agent_state.temperature, .is_thinking = initial_agent_state.is_thinking, .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0, .parent_id = session_id, .parent_session_id = session_id, .is_input = true, .is_output = false, .is_feed_to_llm = false, .image_urls = null, .created_at = created_at } }) catch return;
        };
    }
};

pub const RunAgenticMultiStepInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    event_bus: *event_bus_mod.EventBus,
    di: *pabrikcore.App,
    environment: ?*const std.process.Environ.Map,
};

// ─── re_read_selected_profile_model — live-re-read from sessions table ─────
// **Why this helper exists** (bug report task_1786031708725, 2026-08-06): The
// workflow's `while (true)` loop in `runAgenticMultiStepnew` previously used
fn re_read_selected_profile_model(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    fallback: []const u8,
) []const u8 {
    var rows = db.query(
        allocator,
        "SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?",
        &.{session_id},
    ) catch return fallback;
    defer rows.deinit();

    const maybe_row = rows.next() catch return fallback;
    if (maybe_row) |row| {
        defer row.deinit(allocator);
        // CRITICAL: row.deinit() frees row.values[0]'s backing memory.
        return allocator.dupe(u8, row.values[0]) catch return fallback;
    }
    return fallback;
}

// ─── Test fixture for re_read_selected_profile_model
// ───────────────────────── In-memory SQLite with the full migration chain
// applied (so the `sessions` table has the `selected_profile_model` column
const ReReadTestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn re_read_setupDb() !ReReadTestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration_mod.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration_mod.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

fn re_read_teardown(ctx: *ReReadTestCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

/// Touch the checkpoint worker rows for one loop iteration.
const TouchCheckpointWorkersInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    event_bus: *event_bus_mod.EventBus,
    session_id: []const u8,
    parent_session_id: []const u8,
    cwd: []const u8,
    is_sub_agent: bool,
};

fn touchCheckpointWorkers(input: TouchCheckpointWorkersInput) void {
    const allocator = input.allocator;
    const db = input.db;
    const logger = input.logger;
    const event_bus = input.event_bus;

    updateWorker(UpdateWorkerInput{
        .allocator = allocator,
        .db = db,
        .logger = logger,
        .worker_id = input.session_id,
        .session_id = input.session_id,
        .working_directory = input.cwd,
        .event_bus = event_bus,
        .is_emit_sse = true,
    }) catch |err| {
        logger.errFmt(
            "[CHECKPOINT] worker update failed session_id={s}: {s}\n",
            .{ input.session_id, @errorName(err) },
        );
    };

    if (!input.is_sub_agent) return;
    if (input.parent_session_id.len == 0) return;
    if (std.mem.eql(u8, input.parent_session_id, input.session_id)) return;

    const parent_cwd: []const u8 = blk: {
        // (1) parent worker row's own working_directory — preserves it verbatim
        {
            var w_rows = db.query(allocator, "SELECT working_directory FROM worker WHERE id = ? LIMIT 1", &.{input.parent_session_id}) catch null;
            if (w_rows) |*r| {
                defer r.deinit();
                if (r.next() catch null) |w_row| {
                    defer w_row.deinit(allocator);
                    if (w_row.values.len > 0 and w_row.values[0].len > 0) break :blk allocator.dupe(u8, w_row.values[0]) catch input.cwd;
                }
            }
        }
        // (2) parent session's cwd
        {
            var s_rows = db.query(allocator, "SELECT cwd FROM sessions WHERE id = ? LIMIT 1", &.{input.parent_session_id}) catch null;
            if (s_rows) |*r| {
                defer r.deinit();
                if (r.next() catch null) |s_row| {
                    defer s_row.deinit(allocator);
                    if (s_row.values.len > 0 and s_row.values[0].len > 0) break :blk allocator.dupe(u8, s_row.values[0]) catch input.cwd;
                }
            }
        }
        break :blk input.cwd;
    };
    updateWorker(UpdateWorkerInput{
        .allocator = allocator,
        .db = db,
        .logger = logger,
        .worker_id = input.parent_session_id,
        .session_id = input.parent_session_id,
        .working_directory = parent_cwd,
        .event_bus = event_bus,
        .is_emit_sse = true,
    }) catch |err| {
        logger.errFmt(
            "[CHECKPOINT] worker update failed session_id={s}: {s}\n",
            .{ input.parent_session_id, @errorName(err) },
        );
    };
}

/// Fetch MCP tools fresh from all configured servers (plan:
/// mcp-fetch-once-cache).
fn fetchMcpToolsFresh(
    parent_allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    copy_session_id: []const u8,
    initial_config: *config_mod.LlmConfig,
    logger: *logger_mod.Logger,
) ?[]pabrikcore.tool_models.AgentTool {
    return (blk: {
        const McpCancelCtx = struct {
            db: *sqlite.SqliteBackend,
            session_id: []const u8,
        };
        const mcp_cancel_thunk = struct {
            threadlocal var state: ?McpCancelCtx = null;

            fn call() bool {
                const s = state orelse return false;
                return isWorkerCancelled(IsWorkerCancelledInput{
                    .allocator = std.heap.page_allocator,
                    .db = s.db,
                    .session_id = s.session_id,
                });
            }
        };

        const box = parent_allocator.create(McpCancelCtx) catch null;
        if (box) |b| {
            b.* = .{ .db = db, .session_id = copy_session_id };
            mcp_cancel_thunk.state = b.*;
        }
        defer mcp_cancel_thunk.state = null;
        break :blk build_msg_prompt.buildMCPToolsRun(
            parent_allocator,
            initial_config.mcpServers() orelse .null,
            if (box) |_| &mcp_cancel_thunk.call else null,
        );
    } catch |err| blk: {
        logger.errFmt("Failed to load MCP tools: {s}", .{@errorName(err)});
        break :blk null;
    });
}

/// Cancel thunk handed to `Agent.callStreaming` for the in-flight turn.
/// `Agent.zig` must not depend on sqlite/config, so it takes a plain `?*const
/// fn () bool` and the workflow supplies this one.
const LlmCancelCtx = struct {
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    io: std.Io,
};

const LLM_CANCEL_POLL_INTERVAL_NS: i96 = 50 * std.time.ns_per_ms;

const llm_cancel_thunk = struct {
    threadlocal var state: ?LlmCancelCtx = null;
    threadlocal var last_poll_ns: i96 = 0;
    threadlocal var latched: bool = false;

    fn call() bool {
        if (latched) return true;
        const s = state orelse return false;

        const now_ns = std.Io.Clock.now(.real, s.io).nanoseconds;
        if (last_poll_ns != 0 and now_ns - last_poll_ns < LLM_CANCEL_POLL_INTERVAL_NS) {
            return false;
        }
        last_poll_ns = now_ns;

        const cancelled = isWorkerCancelled(IsWorkerCancelledInput{
            .allocator = std.heap.page_allocator,
            .db = s.db,
            .session_id = s.session_id,
        });
        if (cancelled) latched = true;
        return cancelled;
    }

    fn register(ctx: LlmCancelCtx) void {
        state = ctx;
        last_poll_ns = 0;
        latched = false;
    }

    fn unregister() void {
        state = null;
        last_poll_ns = 0;
        latched = false;
    }
};

const FlushCancelledInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    event_bus: *event_bus_mod.EventBus,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    model: []const u8,
    agent_name: []const u8,
    temperature: f32,
    is_thinking: bool,
    loop_counter: u32,
};

/// Publish + persist the text streamed so far when a turn is cancelled
/// mid-stream.
fn flushCancelledPartial(input: FlushCancelledInput) void {
    const allocator = input.allocator;

    // The snapshot outlives the abort: `callDynamicAgentNew` only calls
    // `endStream` when the terminal `done` chunk arrives, which a cancelled
    // stream never delivers. So this holds exactly the text the user saw.
    const snapshot = stream_snapshot.getSnapshot(allocator, input.session_id) catch return;
    // Nothing streamed (cancelled before the first token): there is no row to
    // write and an empty `full` would fail the frontend's renderable gate
    // anyway, so the streaming placeholder is best cleared by the ordinary
    if (snapshot.content.len == 0) return;

    const now_ns = std.Io.Timestamp.now(input.io, .real).nanoseconds;
    const id = std.fmt.allocPrint(allocator, "{}", .{now_ns}) catch return;
    const created_at = std.fmt.allocPrint(allocator, "{}", .{now_ns}) catch return;

    _ = insertLLMHistories(.{
        .allocator = allocator,
        .io = input.io,
        .db = input.db,
        .logger = input.logger,
        .event_bus = input.event_bus,
        .is_emit_sse = true,
        .cwd = input.cwd,
        .entity = .{
            .id = id,
            .session_id = input.session_id,
            .model = input.model,
            .created_at = created_at,
            .response_content = snapshot.content,
            .finish_reason = "cancelled",
            .role = agent.Role.assistant.to_str(),
            .tool_calls_json = "",
            .agent = input.agent_name,
            .loop_index = input.loop_counter,
            .temperature = input.temperature,
            .is_thinking = input.is_thinking,
            .parent_id = input.parent_session_id,
            .parent_session_id = input.parent_session_id,
            .is_input = false,
            .is_output = true,
        },
    }) catch |err| {
        input.logger.errFmt(
            "Failed to persist the cancelled partial response session_id={s}: {s}",
            .{ input.session_id, @errorName(err) },
        );
        return;
    };

    // Leave the snapshot inactive: the turn is over, so a stream-resume poll
    // must not resurrect a placeholder for it.
    stream_snapshot.endStream(allocator, input.session_id);
}

pub fn runAgenticMultiStepnew(di: RunAgenticMultiStepInput, params: RunParamsNew) !void {
    var parent_arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer parent_arena_allocator.deinit();
    const parent_allocator = parent_arena_allocator.allocator();

    const db = di.db;
    const logger = di.logger;
    const event_bus = di.event_bus;
    const io = di.io;
    const environment = di.environment;

    logger.infoFmt(
        "[CHECKPOINT] entry runAgenticMultiStepnew session_id={s} parent_session_id={s} is_sub_agent={} msg_len={d} allowed_tools_len={d} cwd={s}",
        .{ params.session_id, params.parent_session_id, params.is_sub_agent, params.message.len, params.allowed_tools.len, params.cwd },
    );

    // ─── Per-session config (auth mode) ─── With `--auth` on, each user's
    // LLM config lives in `users.config_json` and the process-global
    // singleton still describes the on-disk `config.json` — it is never
    var config = session_llm_config.forSession(parent_allocator, db, params.session_id) orelse
        pabrikcore.getLlmConfig(di.di);
    var eff = effectiveAgentForSubAgent(
        config.resolveEffectiveAgent(params.selected_profile_model),
        params.sub_agent_overrides,
    );

    logger.infoFmt(
        "[CHECKPOINT] profile selected_profile_model='{s}' eff.model={s} eff.base_url={s} eff.url_style={s} eff.thinking_str={s} eff.thinking_budget_tokens={?d} eff.reasoning_effort={?s}",
        .{ params.selected_profile_model, eff.model, eff.base_url, eff.url_style, eff.thinking_str, eff.thinking_budget_tokens, eff.reasoning_effort },
    );

    const copy_parent_session_id = try parent_allocator.dupe(u8, params.parent_session_id);
    const copy_session_id = try parent_allocator.dupe(u8, params.session_id);
    const copy_message = try parent_allocator.dupe(u8, params.message);
    const copy_cwd = try parent_allocator.dupe(u8, params.cwd);

    var copy_allowed_tools: []const u8 = parent_allocator.dupe(u8, params.allowed_tools) catch "";
    if (!params.is_sub_agent) {
        if (try maybeOverrideAllowedToolsForAgent(
            parent_allocator,
            db,
            params.session_id,
            &copy_allowed_tools,
        )) {
            logger.infoFmt(
                "[CHECKPOINT] agent_mode: session_id={s} is bound to an Agent — allowed_tools overridden to '{s}'",
                .{ params.session_id, copy_allowed_tools },
            );
        } else if (try maybeOverrideAllowedToolsForKanban(
            parent_allocator,
            db,
            params.session_id,
            &copy_allowed_tools,
        )) {
            logger.infoFmt(
                "[CHECKPOINT] agent_kanbans: session_id={s} is bound to a configured kanban — allowed_tools overridden to '{s}'",
                .{ params.session_id, copy_allowed_tools },
            );
        } else if (try maybeOverrideAllowedToolsForRoutine(
            parent_allocator,
            db,
            params.session_id,
            &copy_allowed_tools,
        )) {
            logger.infoFmt(
                "[CHECKPOINT] agent_routines: session_id={s} is bound to a configured routine — allowed_tools overridden to '{s}'",
                .{ params.session_id, copy_allowed_tools },
            );
        } else if (try maybeOverrideAllowedToolsForConfigDefault(
            parent_allocator,
            config.tools,
            &copy_allowed_tools,
        )) {
            logger.infoFmt(
                "[CHECKPOINT] config_default: session_id={s} allowed_tools overridden to '{s}' (config.json tools checklist)",
                .{ params.session_id, copy_allowed_tools },
            );
        }
    }

    const copy_is_sub_agent = params.is_sub_agent;
    const copy_image_urls = try parent_allocator.dupe(u8, params.image_urls);
    const copy_video_urls = try parent_allocator.dupe(u8, params.video_urls);
    const copy_file_attachments = try parent_allocator.dupe(u8, params.file_attachments);
    // The queue row owns its own copy, so the payload is dead once the
    // message is queued.
    defer parent_allocator.free(copy_file_attachments);
    const copy_inherited_context = try parent_allocator.dupe(u8, params.inherited_context);
    var is_have_queue_message = false;

    // Persist the selected profile on the session row so subagent children
    // (whose rows are lazily created by updateWorker with NULL profile) carry
    // the parent's profile.
    if (params.selected_profile_model.len > 0) {
        _ = llm_history.ensureSessionExists(parent_allocator, db, copy_session_id) catch |err| {
            logger.errFmt("[CHECKPOINT] ensure session failed session_id={s}: {s}", .{ copy_session_id, @errorName(err) });
        };
        llm_history.updateSessionSelectedProfileModel(parent_allocator, db, copy_session_id, params.selected_profile_model) catch |err| {
            logger.errFmt("[CHECKPOINT] persist profile failed session_id={s}: {s}", .{ copy_session_id, @errorName(err) });
        };
    }

    // Migration 091 — stamp sub-agent identity alongside the parent profile.
    // selected_profile_model stays as the parent (needed for thinking
    // inheritance); sub_agent_name records who actually ran so DB inspection
    if (params.sub_agent_overrides) |ov| {
        if (ov.resolved_name.len > 0) {
            _ = llm_history.ensureSessionExists(parent_allocator, db, copy_session_id) catch {};
            llm_history.updateSessionSubAgentInfo(parent_allocator, db, copy_session_id, ov.resolved_name, params.parent_session_id) catch |err| {
                logger.errFmt("[CHECKPOINT] persist sub-agent identity failed session_id={s}: {s}", .{ copy_session_id, @errorName(err) });
            };
        }
    }

    const initial_agent_state = try llm_history.get_current_agent_by_session_id(
        parent_allocator,
        db,
        copy_session_id,
    );
    const initial_agent = initial_agent_state.agent;
    // A sub-agent's configured temperature wins; without one the row carries
    // the session's last temperature.
    const insert_temperature: f32 = if (params.sub_agent_overrides) |ov|
        ov.temperature orelse initial_agent_state.temperature
    else
        initial_agent_state.temperature;

    // Claim the session's single run slot with one compare-and-swap statement —
    // never a held write transaction, or ten workers would queue on SQLite's
    // single writer slot. No lease means another run owns this session.
    const run_lease: session_lock.RunLease = (blk: {
        const claim = session_lock.acquire(.{
            .allocator = parent_allocator,
            .db = db,
            .session_id = copy_session_id,
            .working_directory = copy_cwd,
        }) catch |err| {
            logger.errFmt(
                "[CHECKPOINT] session lock acquire failed session_id={s}: {s}",
                .{ copy_session_id, @errorName(err) },
            );
            break :blk null;
        };
        break :blk switch (claim) {
            .acquired => |lease| lease,
            .busy => null,
        };
    }) orelse {
        logger.infoFmt(
            "[CHECKPOINT] worker busy, queueing message session_id={s} msg_len={d} image_urls_len={d}",
            .{ copy_session_id, copy_message.len, copy_image_urls.len },
        );
        // A trigger run (boot resume, background-completion wake) carries no
        // message of its own: losing the slot means the session is already
        // being worked on, so there is nothing to hand over.
        if (!params.skip_initial_queue_message) {
            try insertQueueMessage(InsertQueueMessageInput{
                .allocator = parent_allocator,
                .db = db,
                .logger = logger,
                .session_id = copy_session_id,
                .message = copy_message,
                .image_url = copy_image_urls,
                .video_url = copy_video_urls,
                .file_attachments = copy_file_attachments,
                .event_bus = event_bus,
                .is_emit_sse = true,
            });
        }
        is_have_queue_message = true;
        return;
    };
    logger.infoFmt(
        "[CHECKPOINT] new worker slot acquired session_id={s} cwd={s} run_token={s}",
        .{ copy_session_id, copy_cwd, run_lease.token },
    );
    defer {
        deleteWorker(.{
            .allocator = parent_allocator,
            .db = db,
            .logger = logger,
            .session_id = copy_session_id,
            .event_bus = event_bus,
            .is_emit_sse = true,
            .run_token = run_lease.token,
        }) catch |err| {
            logger.errFmt("Failed to delete worker: {s}", .{@errorName(err)});
        };
    }

    if (!params.skip_initial_queue_message) {
        try insertQueueMessage(InsertQueueMessageInput{
            .allocator = parent_allocator,
            .db = db,
            .logger = logger,
            .session_id = copy_session_id,
            .message = copy_message,
            .image_url = copy_image_urls,
            .video_url = copy_video_urls,
            .file_attachments = copy_file_attachments,
            .event_bus = event_bus,
            .is_emit_sse = true,
        });

        logger.infoFmt(
            "[CHECKPOINT] initial message queued session_id={s} retry_budget=10",
            .{copy_session_id},
        );
    } else {
        logger.infoFmt(
            "[CHECKPOINT] trigger mode — skipping initial queue_message session_id={s}",
            .{copy_session_id},
        );
    }

    var retry_count: u32 = 0;
    var last_retry_error: anyerror = error.Unknown;
    var last_retry_source: []const u8 = "unknown";
    var last_retry_server_detail: ?[]const u8 = null;
    var current_max_tokens: usize = 20000;
    var loop_counter: u32 = 0;
    var last_iter_start_ns: i128 = 0;
    // The auto-name call is a blocking LLM round-trip, so it runs at most
    // ONCE per worker run (one user turn) — never once per loop iteration.
    var auto_name_attempted = false;
    // The auto-name call is a blocking LLM round-trip, so it runs at most
    // ONCE per worker run (one user turn) — never once per loop iteration.

    // Same source as `config` above: the session owner's stored config in
    // auth mode, the process-global singleton otherwise.
    const initial_config = config;

    touchCheckpointWorkers(.{
        .allocator = parent_allocator,
        .db = db,
        .logger = logger,
        .event_bus = event_bus,
        .session_id = params.session_id,
        .parent_session_id = params.parent_session_id,
        .cwd = params.cwd,
        .is_sub_agent = params.is_sub_agent,
    });

    // Fetch-once MCP tools cache (plan: mcp-fetch-once-cache): one
    // `tools/list` per boot / per config mutation, published to the singleton
    // for every future run.
    if (!di.di.isMcpToolsInit()) {
        const fresh = fetchMcpToolsFresh(parent_allocator, db, copy_session_id, initial_config, logger);
        // Publish for all future runs. On error (`fresh == null`) pass
        // mark_init=false so the next run retries instead of caching
        // the failure forever.
        di.di.storeMcpToolsCache(fresh, fresh != null);
    }

    // Per-turn arena: every allocation inside the while loop below uses
    // `allocator` from this arena — no `parent_allocator` inside the loop.
    var arenaAllocatorWhileLoop = std.heap.ArenaAllocator.init(di.allocator);
    defer arenaAllocatorWhileLoop.deinit();
    const allocator = arenaAllocatorWhileLoop.allocator();
    while (true) {
        _ = arenaAllocatorWhileLoop.reset(.free_all);

        // The iteration's flags and the lease check come back from ONE
        // statement, so they cannot disagree: a run that lost the session
        // leaves here instead of racing the owner.
        const iteration = session_lock.beginIteration(allocator, db, copy_session_id, run_lease.token) catch |err| {
            logger.errFmt(
                "[CHECKPOINT] session lock check failed session_id={s}: {s} — leaving the loop",
                .{ copy_session_id, @errorName(err) },
            );
            break;
        };
        const iter_state = iteration orelse {
            logger.infoFmt(
                "[CHECKPOINT] session lease not ours any more session_id={s} — leaving the loop",
                .{copy_session_id},
            );
            break;
        };
        const is_auto_retry_until_stop: bool = iter_state.is_auto_retry_until_stop;

        touchCheckpointWorkers(.{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .event_bus = event_bus,
            .session_id = copy_session_id,
            .parent_session_id = copy_parent_session_id,
            .cwd = copy_cwd,
            .is_sub_agent = copy_is_sub_agent,
        });

        last_iter_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;

        // ─── Live config re-read ───
        // Re-fetch the LlmConfig pointer from the holder once per iteration
        // so user-initiated changes (model switch, profile change, API-key
        config = session_llm_config.forSession(allocator, db, copy_session_id) orelse
            pabrikcore.getLlmConfig(di.di);

        // ─── Live MCP tools refresh on config invalidation ─── PUT
        // /api/config/pabrik and add_mcp_server call `clearMcpToolsCache()`
        // after their `setLlmConfig` swap.
        if (!di.di.isMcpToolsInit()) {
            const fresh = fetchMcpToolsFresh(allocator, db, copy_session_id, config, logger);
            // `fresh` is consumed by `storeMcpToolsCache` (which deep-dupes
            // onto the singleton), so it is safe for this to live in the
            // per-turn arena.
            di.di.storeMcpToolsCache(fresh, fresh != null);
        }

        // ─── MCP tools for THIS TURN ONLY ─── The snapshot is owned by the
        // per-turn arena `allocator`, which
        // `arenaAllocatorWhileLoop.reset(.free_all)` at the top of every
        const mcp_tools: ?[]pabrikcore.tool_models.AgentTool = di.di.getMcpToolsCached(allocator);

        // ─── Live per-session profile re-read (plan
        // 2026-08-06-workflow-re-read-profile) ─── The previous snapshot
        // pattern (params.selected_profile_model) silently ignored mid-run
        const live_selected_profile_model: []const u8 = re_read_selected_profile_model(
            allocator,
            db,
            copy_session_id,
            params.selected_profile_model,
        );

        // Step 1 produces a warning when the named profile is missing.
        // Step 2 (`config.active_agent`) is silent — it's the user's
        // default, so a typo there is a normal fall-through to top-level.
        if (live_selected_profile_model.len > 0 and
            config.getAgent(live_selected_profile_model) == null)
        {
            logger.warnFmt("WORKFLOW: selected_profile_model '{s}' not found in LlmConfig.profiles_models, using top-level config", .{live_selected_profile_model});
        }
        // === Per-iteration profile re-resolution
        // ============================ ONE typed cascade call replaces the 4×
        // resolveProfileField + ~50 lines of hand-rolled
        eff = effectiveAgentForSubAgent(
            config.resolveEffectiveAgent(live_selected_profile_model),
            params.sub_agent_overrides,
        );
        const iter_profile: ?config_mod.LlmConfig.LlmAgent =
            config.resolveSessionAgentCompat(live_selected_profile_model);

        logger.infoFmt(
            "[CHECKPOINT] loop iter start session_id={s} loop_counter={d} retry_count={d} eff.model={s}",
            .{ copy_session_id, loop_counter, retry_count, eff.model },
        );

        // Cancellation, read in the iteration transaction above — BEFORE
        // `touchCheckpointWorkers` resets the flag on the row.
        if (iter_state.is_cancelled) {
            logger.infoFmt("WORKFLOW CANCELLED while looping back for next API call...", .{});
            break;
        }

        // A run must never proceed while a question is unanswered: the model
        // would receive the <status>pending</status> envelope and might
        // guess.
        if (ask_user_pending.hasPendingQuestion(allocator, db, copy_session_id)) {
            logger.infoFmt(
                "[CHECKPOINT] ask_user question still pending — ending the run session_id={s}",
                .{copy_session_id},
            );
            break;
        }

        // Get queued messages from DB
        var queued_messages = try getQueueMessage(GetQueueMessageInput{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
        if (queued_messages) |*messages| {
            logger.infoFmt(
                "[CHECKPOINT] queued messages drained session_id={s} count={d}",
                .{ copy_session_id, messages.items.len },
            );
            for (messages.items) |queued| {
                // Use image_url/video_url from database if present, otherwise
                // try to extract from message content.
                var image_urls: ?[][]const u8 = null;
                if (queued.image_url.len > 0) {
                    // Split by pipe separator
                    var parts = std.mem.splitScalar(u8, queued.image_url, '|');
                    var urls = std.ArrayList([]const u8).empty;
                    while (parts.next()) |part| {
                        if (part.len > 0) {
                            try urls.append(allocator, try allocator.dupe(u8, part));
                        }
                    }
                    if (urls.items.len > 0) {
                        image_urls = try urls.toOwnedSlice(allocator);
                    }
                } else {
                    // Fallback: try to extract from message content
                    image_urls = helpers.image.extractBase64ImageUrls(queued.message, allocator) catch |err| blk: {
                        logger.errFmt("Failed to extract image URLs: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                }

                var video_urls: ?[][]const u8 = null;
                if (queued.video_url.len > 0) {
                    var parts = std.mem.splitScalar(u8, queued.video_url, '|');
                    var urls = std.ArrayList([]const u8).empty;
                    while (parts.next()) |part| {
                        if (part.len > 0) {
                            try urls.append(allocator, try allocator.dupe(u8, part));
                        }
                    }
                    if (urls.items.len > 0) {
                        video_urls = try urls.toOwnedSlice(allocator);
                    }
                } else {
                    // Fallback: try to extract from message content
                    video_urls = helpers.video.extractBase64VideoUrls(queued.message, allocator) catch |err| blk: {
                        logger.errFmt("Failed to extract video URLs: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                }

                // The attachments ride as a JSON payload; the read path
                // needs the metadata only, so derive it here.
                var file_attachments_meta: []const u8 = "";
                if (queued.file_attachments.len > 0) {
                    if (file_attachments.parseStored(allocator, queued.file_attachments)) |parsed_files| {
                        var stored = parsed_files;
                        defer stored.deinit();
                        file_attachments_meta = file_attachments.encodeMeta(allocator, stored.files) catch "";
                    } else |parse_err| {
                        logger.errFmt("[CHECKPOINT] file attachments parse failed session_id={s}: {s}", .{ copy_session_id, @errorName(parse_err) });
                    }
                }

                _ = try insertLLMHistories(.{
                    .allocator = allocator,
                    .io = io,
                    .db = db,
                    .logger = logger,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                    .cwd = copy_cwd,
                    .entity = .{
                        .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                        .session_id = copy_session_id,
                        .model = eff.model,
                        .response_content = queued.message,
                        .reasoning_content = null,
                        .role = agent.Role.user.to_str(),
                        .finish_reason = "null",
                        .tool_calls_json = "",
                        .tool_call_id = null,
                        .agent = initial_agent,
                        .loop_index = 0,
                        .temperature = insert_temperature,
                        .is_thinking = eff.is_thinking orelse initial_agent_state.is_thinking,
                        .prompt_tokens = 0,
                        .completion_tokens = 0,
                        .total_tokens = 0,
                        .parent_id = copy_parent_session_id,
                        .parent_session_id = copy_parent_session_id,
                        .is_input = true,
                        .is_output = false,
                        .image_urls = image_urls,
                        .video_urls = video_urls,
                        .file_attachments = if (queued.file_attachments.len > 0) queued.file_attachments else null,
                        .file_attachments_meta = if (file_attachments_meta.len > 0) file_attachments_meta else null,
                        .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                        .is_feed_to_llm = true,
                    },
                });

                try deleteQueuedMessage(.{
                    .allocator = allocator,
                    .db = db,
                    .is_emit_sse = true,
                    .event_bus = event_bus,
                    .session_id = copy_session_id,
                    .id = queued.id,
                });
            }
        }

        try updateWorker(UpdateWorkerInput{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .worker_id = copy_session_id,
            .session_id = copy_session_id,
            .working_directory = copy_cwd,
            .event_bus = event_bus,
            .is_emit_sse = true,
        });

        // Fetch current agent fresh from DB each iteration
        const currentAgentState = try llm_history.get_current_agent_by_session_id(
            allocator,
            db,
            copy_session_id,
        );
        const current_agent = currentAgentState.agent;
        var agent_temperature = currentAgentState.temperature;
        var isThinking = currentAgentState.is_thinking;

        // The agent itself was applied to `eff` before the first history row
        // was written (see `effectiveAgentForSubAgent`); what is left here
        // are the session-state values and the resolved agent's name.
        var sub_agent_session_name: []const u8 = "";
        if (params.sub_agent_overrides) |ov| {
            if (ov.is_thinking) |t| isThinking = t;
            if (ov.temperature) |t| agent_temperature = t;
            sub_agent_session_name = ov.resolved_name;
        }
        // For sub-agent flow: replace `current_agent` (the session's last
        // `agent_name` from llm_history) with the resolved sub-agent name.
        const effective_agent_name: []const u8 = if (sub_agent_session_name.len > 0)
            sub_agent_session_name
        else
            current_agent;

        // Sub-agent's specialized system_prompt (from
        // SubAgentConfig.system_prompt) is injected as the `## Your Active
        // Agent Configuration` section of build_agent_prompt.
        const sub_agent_system_prompt: []const u8 = if (params.sub_agent_overrides) |ov|
            ov.system_prompt
        else
            "";

        // Bail on retry budget exhaustion.
        if (retry_count > 10) {
            const reason_error = @errorName(last_retry_error);
            const reason_source = last_retry_source;

            // Migration 063 — unattended-mode soft-bail.
            if (is_auto_retry_until_stop) {
                logger.warnFmt(
                    "UNATTENDED SOFT-BAIL: retry_count={} exceeded 10 (last error={s} source={s}) — continuing per is_auto_retry_until_stop=1",
                    .{ retry_count, reason_error, reason_source },
                );
                const soft_diagnostic = std.fmt.allocPrint(allocator,
                    \\[Agent Pabrik System info] unattended-mode soft-bail after {} consecutive retries.
                    \\Reason for last retry: {s} (source: {s}).
                    \\Server said: {s}
                    \\The session keeps running.
                , .{ retry_count, reason_error, reason_source, clampDetail(last_retry_server_detail orelse "(no server detail)", 500) }) catch "unattended soft-bail snapshot";
                _ = try insertLLMHistories(.{
                    .allocator = allocator,
                    .io = io,
                    .db = db,
                    .logger = logger,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                    // Soft-bail diagnostic should surface in the live chat
                    // stream but NOT pollute the persistent chat history —
                    // the AI's next turn shouldn't see 10+ retry snapshots
                    .is_skip_db = true,
                    // Frontend AgentErrorCard routing (task_1787663566535_2).
                    .is_error = true,
                    .cwd = copy_cwd,
                    .entity = .{ .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}), .session_id = copy_session_id, .model = eff.model, .response_content = soft_diagnostic, .reasoning_content = null, .role = agent.Role.user.to_str(), .finish_reason = "null", .tool_calls_json = "", .tool_call_id = null, .agent = effective_agent_name, .loop_index = loop_counter, .temperature = agent_temperature, .is_thinking = isThinking, .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0, .parent_id = copy_parent_session_id, .parent_session_id = copy_parent_session_id, .is_input = true, .is_output = false, .image_urls = null, .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}), .is_feed_to_llm = false },
                });

                if (!retryDelayMs(.{
                    .allocator = allocator,
                    .delay_ms = config.retry_delay_ms,
                    .db = db,
                    .session_id = copy_session_id,
                    .io = io,
                    .logger = logger,
                })) {
                    logger.infoFmt("WORKFLOW CANCELLED during unattended soft-bail: session_id={s}", .{copy_session_id});
                    break;
                }
                // Reset retry counter AND stale retry-cause capture so the
                // NEXT soft-bail diagnostic reflects the *current* failure
                // batch, not the very first error of this session.
                retry_count = 0;
                last_retry_error = error.Unknown;
                last_retry_source = "unknown";
                last_retry_server_detail = null;
                continue;
            }

            // Existing hard-bail (preserved verbatim).
            const diagnostic = std.fmt.allocPrint(allocator,
                \\[Agent Pabrik System error] workflow halted after {} consecutive retries.
                \\Reason for last retry: {s} (source: {s}).
                \\Server said: {s}
            , .{ retry_count, reason_error, reason_source, clampDetail(last_retry_server_detail orelse "(no server detail)", 500) }) catch "workflow halted after too many retries";

            logger.errFmt("TooManyRetries exhausted: {} consecutive failures for session_id={s} — last_error={s} source={s} — server: {s}", .{ retry_count, copy_session_id, reason_error, reason_source, clampDetail(last_retry_server_detail orelse "(no server detail)", 500) });

            // Save the diagnostic as a user message so the AI agent sees it on
            // its next turn. Mirror the pattern the outer catch uses for generic
            // errors so the message shape is consistent.

            _ = try insertLLMHistories(.{
                .allocator = allocator,
                .io = io,
                .db = db,
                .logger = logger,
                .event_bus = event_bus,
                .is_emit_sse = true,
                // Hard-bail diagnostic should surface in the live chat stream
                // but NOT pollute the persistent chat history — the workflow
                // halts immediately after this call so the diagnostic is
                .is_skip_db = true,
                // Frontend AgentErrorCard routing (task_1787663566535_2).
                .is_error = true,
                .cwd = copy_cwd,
                .entity = .{
                    .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .session_id = copy_session_id,
                    .model = eff.model,
                    .response_content = diagnostic,
                    .reasoning_content = null,
                    .role = agent.Role.user.to_str(),
                    .finish_reason = "null",
                    .tool_calls_json = "",
                    .tool_call_id = null,
                    .agent = effective_agent_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .prompt_tokens = 0,
                    .completion_tokens = 0,
                    .total_tokens = 0,
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = true,
                    .is_output = false,
                    .image_urls = null,
                    .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .is_feed_to_llm = false,
                },
            });

            return error.TooManyRetries;
        }

        var messagesLists: std.ArrayList(agent.AgentMessage) = .empty;
        const db_messages = try getLLMHistories(*SqliteBackend, .{
            .allocator = allocator,
            .db = db,
            .session_id = copy_session_id,
        });
        const is_task_kanban = try isSessionKanban(allocator, db, copy_session_id);

        const total_tokens = blk: {
            var max_token: u32 = 0;
            for (db_messages) |msg| {
                if (msg.total_tokens > max_token) {
                    max_token = msg.total_tokens;
                }
            }
            break :blk max_token;
        };
        loop_counter = blk: {
            var max_loop_counter: u32 = 0;
            for (db_messages) |msg| {
                if (msg.loop_index > max_loop_counter) {
                    max_loop_counter = msg.loop_index;
                }
            }

            break :blk max_loop_counter;
        };
        loop_counter += 1;
        // Auto-name gate: keyed on the session's CURRENT name, not on
        // `loop_counter == 1`.
        if (!is_task_kanban and
            !auto_name_attempted and
            sessionNameIsPlaceholder(allocator, db, copy_session_id))
        {
            auto_name_attempted = true;
            generateSessionNameNew(db_messages, allocator, eff.api_key, eff.model, eff.base_url, eff.url_style, eff.backend, copy_session_id, logger, io, db, event_bus);
        }

        // ─── Progressive tool search ─────────────────────────────────── The
        // catalog is what this session could still enable: registered
        // built-ins that are NOT enabled, plus every MCP tool (MCP is
        const progressive_rows = try llm_history.getProgressiveTools(allocator, db, copy_session_id);
        const progressive_names = try allocator.alloc([]const u8, progressive_rows.len);
        for (progressive_rows, 0..) |row, i| progressive_names[i] = row.tool_name;

        const workspace_item_type: []const u8 = blk: {
            const wctx = (llm_history.getWorkspaceContext(allocator, db, copy_session_id) catch break :blk "") orelse break :blk "";
            defer wctx.deinit(allocator);
            break :blk try allocator.dupe(u8, wctx.self_item_type);
        };

        const registered_tools = tools.all_agent_tools(allocator);
        // The catalog is built for the diagnostic log line below (how many
        // tools this session could still discover).
        const catalog = try progressive_catalog.buildCatalog(
            allocator,
            registered_tools,
            copy_allowed_tools,
            copy_is_sub_agent,
            mcp_tools,
            progressive_names,
            workspace_item_type,
        );

        const merged_tools = try filterAndMergeTools(
            allocator,
            mcp_tools,
            copy_allowed_tools,
            copy_is_sub_agent,
            progressive_names,
            // The Skill Evals master switch.
            (skill_evals_config.resolve(allocator, db, copy_session_id) orelse
                config.skill_evals).enabled,
        );
        logger.infoFmt(
            "[CHECKPOINT] tools resolved mcp_count={d} mcp_equipped={d} builtin_equipped={d} catalog={d} item_type='{s}' merged_count={d} allowed_tools_len={d} is_sub_agent={} mcp_null={}",
            .{
                if (mcp_tools) |t| t.len else 0,
                countNamesIn(mcp_tools orelse &.{}, progressive_names),
                countNamesIn(registered_tools, progressive_names),
                catalog.len,
                workspace_item_type,
                merged_tools.len,
                copy_allowed_tools.len,
                copy_is_sub_agent,
                mcp_tools == null,
            },
        );

        const initialMessages = try build_msg_prompt.buildMessages(allocator, io, db, copy_cwd, copy_session_id, copy_parent_session_id, db_messages, merged_tools, copy_inherited_context, sub_agent_system_prompt);

        try messagesLists.appendSlice(allocator, initialMessages);

        const is_do_compaction = try maybeCompactMessagesNew(defaultCompactDeps, allocator, total_tokens, eff.model, false, &messagesLists, eff.api_key, eff.base_url, eff.url_style, copy_cwd, copy_session_id, db, io, logger, event_bus, config, if (iter_profile) |*p| p else null);
        if (is_do_compaction) {
            logger.infoFmt(
                "[CHECKPOINT] compaction triggered session_id={s} loop_counter={d} total_tokens={d} prompt_msg_count={d}",
                .{ copy_session_id, loop_counter, total_tokens, messagesLists.items.len },
            );
            continue;
        }

        logger.debugFmt("[WORKFLOW-debug-system-prompt] system_prompt={s}", .{messagesLists.items[0].content.?});

        const checkpoint_llm_start_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
        logger.infoFmt(
            "[CHECKPOINT] calling LLM session_id={s} model={s} loop_counter={d} prompt_msg_count={d} max_tokens={d} retry_count={d}",
            .{ copy_session_id, eff.model, loop_counter, messagesLists.items.len, current_max_tokens, retry_count },
        );

        var last_dynamic_agent_error_message: ?[]const u8 = null;
        // Make this turn cancellable.
        llm_cancel_thunk.register(.{ .db = db, .session_id = copy_session_id, .io = io });
        defer llm_cancel_thunk.unregister();
        const res_dynamic_agent = callDynamicAgentNew(allocator, io, messagesLists, agent_temperature, current_max_tokens, isThinking, eff.thinking_budget_tokens, eff.thinking_adaptive, eff.reasoning_effort, eff.api_key, eff.model, eff.base_url, eff.url_style, eff.backend, copy_session_id, merged_tools, &llm_cancel_thunk.call, &last_dynamic_agent_error_message) catch |err| {
            if (err == error.Cancelled) {
                logger.infoFmt("WORKFLOW CANCELLED during streaming: session_id={s}", .{copy_session_id});
                // Keep the partial text and settle the transcript — without
                // this the only signal is `worker_deleted`, which clears the
                // Stop button but leaves the streaming row behind forever.
                flushCancelledPartial(.{
                    .allocator = allocator,
                    .io = io,
                    .db = db,
                    .logger = logger,
                    .event_bus = event_bus,
                    .cwd = copy_cwd,
                    .session_id = copy_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .model = eff.model,
                    .agent_name = effective_agent_name,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .loop_counter = loop_counter,
                });
                break;
            }
            retry_count += 1;
            // Capture WHY this retry fired so the AI agent can understand the
            // cause when the retry budget is eventually exhausted.
            last_retry_error = err;
            last_retry_source = "callDynamicAgentNew";
            // Cross-turn carry: the retry-budget check at the TOP of a later
            // iteration reads this, and every iteration frees the per-turn
            // arena — so the copy must live in the RUN arena
            last_retry_server_detail = if (last_dynamic_agent_error_message) |msg|
                parent_allocator.dupe(u8, msg) catch null
            else
                null;
            // The agent populated `last_dynamic_agent_error_message` with the
            // actual server / transport reason (e.g. "HTTP 429: rate limit
            // exceeded", "scanner.next failed after 12 chunk(s):
            const server_detail = clampDetail(last_dynamic_agent_error_message orelse "(no server detail)", 500);
            logger.errFmt("Error calling dynamic agent: {s} now retrying after {d}ms delay — server: {s}", .{ @errorName(err), config.retry_delay_ms, server_detail });
            // Save a per-retry diagnostic to chat history so the user sees
            // each attempt live AND the AI has the full retry progression in
            // context for its next turn (instead of only learning about
            try saveRetryAttemptMessage(allocator, db, event_bus, logger, io, copy_cwd, copy_session_id, copy_parent_session_id, eff.model, effective_agent_name, agent_temperature, isThinking, loop_counter, retry_count, @as(u32, 10), "callDynamicAgentNew", @errorName(err), server_detail, config.retry_delay_ms);

            // Sleep before the next attempt so the upstream can recover (or
            // rate-limit window can close). 0 ms = no delay (current
            // behavior, the default).
            if (!retryDelayMs(.{
                .allocator = allocator,
                .delay_ms = config.retry_delay_ms,
                .db = db,
                .session_id = copy_session_id,
                .io = io,
                .logger = logger,
            })) {
                logger.infoFmt("WORKFLOW CANCELLED during retry delay: session_id={s}", .{copy_session_id});
                break;
            }
            continue;
        };

        for (messagesLists.items) |messageList| {
            messageList.deinit(allocator);
        }
        messagesLists.deinit(allocator);

        for (db_messages) |*m| {
            m.deinit(allocator);
        }

        // Lifecycle: `CallResponse` (and everything it points at — `content`,
        // `reasoning_content`, each `tool_calls[i].{id, function.name,
        // function.arguments}`, the `tool_calls` slice itself) is allocated

        const llm_duration_ms = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - checkpoint_llm_start_ns, std.time.ns_per_ms);
        logger.infoFmt(
            "[CHECKPOINT] LLM responded session_id={s} loop_counter={d} finish_reason={s} duration_ms={d} prompt_tokens={d} completion_tokens={d} total_tokens={d}",
            .{
                copy_session_id,
                loop_counter,
                if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else "null",
                llm_duration_ms,
                res_dynamic_agent.usage.prompt_tokens,
                res_dynamic_agent.usage.completion_tokens,
                res_dynamic_agent.usage.total_tokens,
            },
        );

        // Successful LLM call — clear the retry-cause capture so the
        // NEXT soft-bail diagnostic reflects the most recent failure,
        // not the first one of this session.
        retry_count = 0;
        last_retry_error = error.Unknown;
        last_retry_source = "unknown";
        last_retry_server_detail = null;
        // Migration 063 — persist the most recent `finish_reason` so the next
        // workflow invocation (e.g., after a server restart) can start from
        // the right state without re-querying llm_history.
        if (res_dynamic_agent.finish_reason) |fr| {
            llm_history.updateSessionLastFinishReason(allocator, db, copy_session_id, fr.to_str()) catch |err| {
                logger.warnFmt(
                    "[workflow] failed to persist last_finish_reason: {s}",
                    .{@errorName(err)},
                );
            };
        }
        if (res_dynamic_agent.finish_reason) |finish_reason| {
            if (finish_reason == .stop) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=stop session_id={s} loop_counter={d} content_len={d}",
                    .{ copy_session_id, loop_counter, if (res_dynamic_agent.content) |c| c.len else 0 },
                );

                const content_is_empty = if (res_dynamic_agent.content) |c| c.len == 0 else true;
                if (content_is_empty) {
                    logger.infoFmt(
                        "[CHECKPOINT] finish_reason=stop but content is empty session_id={s} loop_counter={d} content_len={d}",
                        .{ copy_session_id, loop_counter, if (res_dynamic_agent.content) |c| c.len else 0 },
                    );
                    continue;
                }
                // In-stream final marker (llm_chunk / type="chunk_final"):
                // tells the frontend the token stream is over + carries usage
                // BEFORE the canonical llm_full row lands.
                on_event_sent.sendStreamChunkFinal(allocator, copy_session_id, .{
                    .index = 0,
                    .usage = .{
                        .prompt_tokens = @intCast(res_dynamic_agent.usage.prompt_tokens),
                        .completion_tokens = @intCast(res_dynamic_agent.usage.completion_tokens),
                        .total_tokens = @intCast(res_dynamic_agent.usage.total_tokens),
                    },
                    .session_id = copy_session_id,
                });
                _ = try insertLLMHistories(.{ .allocator = allocator, .io = io, .db = db, .logger = logger, .event_bus = event_bus, .is_emit_sse = true, .cwd = copy_cwd, .entity = .{
                    .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .session_id = copy_session_id,
                    .model = eff.model,
                    .response_content = res_dynamic_agent.content orelse "",
                    .reasoning_content = res_dynamic_agent.reasoning_content,
                    .reasoning_id = res_dynamic_agent.reasoning_id,
                    .reasoning_encrypted_content = res_dynamic_agent.reasoning_encrypted_content,
                    .role = agent.Role.assistant.to_str(),
                    .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.to_str() else "stop",
                    .tool_calls_json = "",
                    .tool_call_id = null,
                    .agent = effective_agent_name,
                    .loop_index = loop_counter,
                    .temperature = agent_temperature,
                    .is_thinking = isThinking,
                    .prompt_tokens = @intCast(res_dynamic_agent.usage.prompt_tokens),
                    .completion_tokens = @intCast(res_dynamic_agent.usage.completion_tokens),
                    .total_tokens = @intCast(res_dynamic_agent.usage.total_tokens),
                    .cache_creation_input_tokens = @intCast(res_dynamic_agent.usage.cache_creation_input_tokens),
                    .cache_read_input_tokens = @intCast(res_dynamic_agent.usage.cache_read_input_tokens),
                    .parent_id = copy_parent_session_id,
                    .parent_session_id = copy_parent_session_id,
                    .is_input = false,
                    .is_output = true,
                    .image_urls = null,
                    .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
                    .is_feed_to_llm = true,
                } });

                const isHaveQueueMessage = hasQueuedMessages(allocator, db, copy_session_id);
                if (isHaveQueueMessage) {
                    logger.infoFmt(
                        "[CHECKPOINT] finish_reason=stop but queue has more messages, looping session_id={s}",
                        .{copy_session_id},
                    );
                    continue;
                }

                // Fire an OS notification when the user has opted in. Only on
                // `finish_reason == .stop` — tool_calls and length are
                // mid-conversation events the user is already watching.
                if (config.notify_on_complete and copy_is_sub_agent == false) {
                    const preview = if (res_dynamic_agent.content) |c| c else "(empty response)";
                    try notifications.notify(io, allocator, "Agent Pabrik", preview);
                }

                try deleteWorker(DeleteWorkerInput{
                    .allocator = allocator,
                    .db = db,
                    .logger = logger,
                    .session_id = copy_session_id,
                    .event_bus = event_bus,
                    .is_emit_sse = true,
                    .run_token = run_lease.token,
                });

                logger.infoFmt(
                    "[CHECKPOINT] worker done session_id={s} loop_counter={d}",
                    .{ copy_session_id, loop_counter },
                );
                break;
            } else if (finish_reason == .length) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=length session_id={s} loop_counter={d} max_tokens {d} -> {d}",
                    .{ copy_session_id, loop_counter, current_max_tokens, current_max_tokens + 4096 },
                );
                current_max_tokens += 4096;
                continue;
            } else if (finish_reason == .tool_calls) {
                logger.infoFmt(
                    "[CHECKPOINT] finish_reason=tool_calls session_id={s} loop_counter={d} tool_count={d}",
                    .{ copy_session_id, loop_counter, if (res_dynamic_agent.tool_calls) |tc| tc.len else 0 },
                );
                // Forward the LIVE per-session profile (re-read at the top of
                // this iteration) to handle_tool.
                const tool_outcome = try handle_tool(allocator, io, db, logger, copy_session_id, copy_parent_session_id, eff.model, copy_cwd, loop_counter, res_dynamic_agent, &agent_temperature, &isThinking, config.api_key, config.base_url, config, environment, live_selected_profile_model, copy_allowed_tools, copy_is_sub_agent);

                // `ask_user` ends the turn rather than parking the loop.
                if (ask_user_pending.hasPendingQuestion(allocator, db, copy_session_id)) {
                    // Overwrite the `tool_calls` value persisted at the top
                    // of this iteration: as far as anything reading the
                    // session is concerned, this turn ended waiting on the
                    llm_history.updateSessionLastFinishReason(allocator, db, copy_session_id, agent.FinishReason.awaiting_user.to_str()) catch |err| {
                        logger.warnFmt(
                            "[workflow] failed to persist last_finish_reason=awaiting_user: {s}",
                            .{@errorName(err)},
                        );
                    };
                    logger.infoFmt(
                        "[CHECKPOINT] ask_user pending — ending the turn session_id={s} loop_counter={d}",
                        .{ copy_session_id, loop_counter },
                    );
                    try deleteWorker(DeleteWorkerInput{
                        .allocator = allocator,
                        .db = db,
                        .logger = logger,
                        .session_id = copy_session_id,
                        .event_bus = event_bus,
                        .is_emit_sse = true,
                        .run_token = run_lease.token,
                    });
                    break;
                }

                // `is_stop` on a tool call (`command is_stop=true`): the
                // model asked to end THIS turn.
                if (tool_outcome.stop_loop) {
                    // The provider's own finish_reason was `tool_calls` and
                    // was persisted as such at the top of this iteration.
                    llm_history.updateSessionLastFinishReason(allocator, db, copy_session_id, agent.FinishReason.stop.to_str()) catch |err| {
                        logger.warnFmt(
                            "[workflow] failed to persist last_finish_reason=stop after is_stop: {s}",
                            .{@errorName(err)},
                        );
                    };
                    logger.infoFmt(
                        "[CHECKPOINT] is_stop — ending the turn session_id={s} loop_counter={d}",
                        .{ copy_session_id, loop_counter },
                    );
                    try deleteWorker(DeleteWorkerInput{
                        .allocator = allocator,
                        .db = db,
                        .logger = logger,
                        .session_id = copy_session_id,
                        .event_bus = event_bus,
                        .is_emit_sse = true,
                        .run_token = run_lease.token,
                    });
                    break;
                }
            } else {
                retry_count += 1;
                // Capture the unexpected finish_reason as a synthetic
                // retry-cause so the bail diagnostic identifies it.
                last_retry_error = error.UnexpectedFinishReason;
                last_retry_source = "finish_reason else";
                // No transport error on this path — the LLM responded but
                // with an unusable finish_reason, so there is no server
                // detail to surface.
                last_retry_server_detail = null;
                // Save a per-retry diagnostic (no `err` here — unexpected
                // finish_reason has no underlying error name, so use the
                // source label as the diagnostic).
                try saveRetryAttemptMessage(allocator, db, event_bus, logger, io, copy_cwd, copy_session_id, copy_parent_session_id, eff.model, effective_agent_name, agent_temperature, isThinking, loop_counter, retry_count, @as(u32, 10), "finish_reason else", "unexpected finish_reason", "(no server detail — LLM responded with an unexpected finish_reason)", config.retry_delay_ms);
                // Same delay policy as the callDynamicAgentNew catch — sleep
                // before the loop restarts so we don't hammer the upstream
                // when it returns an unexpected finish_reason repeatedly.

                if (!retryDelayMs(.{
                    .allocator = allocator,
                    .delay_ms = config.retry_delay_ms,
                    .db = db,
                    .session_id = copy_session_id,
                    .io = io,
                    .logger = logger,
                })) {
                    logger.infoFmt("WORKFLOW CANCELLED during retry delay (finish_reason else): session_id={s}", .{copy_session_id});
                    break;
                }
                break;
            }

            // Reset retry counter AND stale retry-cause capture so the NEXT
            // bail (soft or hard) reflects the most recent failure, not the
            // very first one of this session.
            retry_count = 0;
            last_retry_error = error.Unknown;
            last_retry_source = "unknown";
            last_retry_server_detail = null;
        }

        // Log if finish_reason is null
        if (res_dynamic_agent.finish_reason == null) {
            logger.warnFmt("WORKFLOW: finish_reason is NULL!", .{});
        }
    }

    const last_iter_total_ms = if (last_iter_start_ns > 0)
        @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds - last_iter_start_ns, std.time.ns_per_ms)
    else
        @as(i128, 0);
    logger.infoFmt(
        "[CHECKPOINT] exit session_id={s} loop_counter={d} retry_count={d} last_iter_total_ms={d}",
        .{ copy_session_id, loop_counter, retry_count, last_iter_total_ms },
    );
    logger.debugFmt("WORKFLOW: exiting while loop for session_id {s}", .{copy_session_id});
}

/// True when the session has no real name yet, so the LLM name generator
/// should (still) be allowed to run.
fn sessionNameIsPlaceholder(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    // A read error must NOT answer "still a placeholder": this predicate
    // gates an overwrite, so it fails CLOSED on error. A missing row is
    // the one case that legitimately has no name to protect.
    const session = llm_history.getSession(allocator, db, session_id) catch return false;
    const maybe = session orelse return true;
    defer maybe.deinit(allocator);
    return isPlaceholderSessionName(maybe.name);
}

fn isPlaceholderSessionName(name: []const u8) bool {
    return name.len == 0 or
        std.mem.eql(u8, name, "New Chat") or
        std.mem.eql(u8, name, "New Session");
}

/// True when a model-returned name is usable.
fn isUsableGeneratedName(name: []const u8) bool {
    return std.mem.trim(u8, name, " \t\r\n").len > 0;
}

fn generateSessionNameNew(
    db_messages: []LLMHistory,
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    url_style: []const u8,
    backend: []const u8,
    session_id: []const u8,
    logger: *logger_mod.Logger,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    event_bus: *event_bus_mod.EventBus,
) void {
    // Find the first user message from db_messages (TUIHistory)
    var first_user_message: ?[]const u8 = null;
    var first_user_owned: ?[]u8 = null;
    defer if (first_user_owned) |b| allocator.free(b);
    for (db_messages) |msg| {
        // role is stored as string "user" in TUIHistory
        if (std.mem.eql(u8, msg.role, "user") and msg.response_content.len > 0) {
            // DB may hold the Option A user envelope; unwrap to .msg so the
            // auto-name prompt sees human text, never raw JSON.
            first_user_owned = parsing_mod.unwrapChatContent(allocator, msg.response_content) catch null;
            if (first_user_owned) |b| {
                if (b.len > 0) first_user_message = b;
            }
            break;
        }
    }

    if (first_user_message == null) {
        logger.debugFmt("No user message found in db_messages", .{});
        return;
    }

    // Build messages for the name generation prompt
    const name_messages = allocator.alloc(agent.AgentMessage, 2) catch return;
    name_messages[0] = .{ .role = .system, .content = prompt.GenerateSessionNameAgent };
    name_messages[1] = .{ .role = .user, .content = first_user_message.? };

    var name_agent = agent.Agent.init(allocator, io);
    // Frees `last_error_message` (the drained server error body) on the
    // failure path.
    defer name_agent.deinit();
    name_agent.apiKey = api_key;
    name_agent.model = model;
    name_agent.baseUrl = base_url;
    name_agent.UrlStyle = url_style;
    name_agent.backend = backend;
    name_agent.sessionId = session_id;
    name_agent.thinkingEnabled = false;
    name_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    const params = agent.AgentCall{
        .tools = &.{},
        .messages = name_messages,
    };

    // A failed name call must be DIAGNOSABLE.
    const response = name_agent.callStreaming(params, null, noopStreamCallbackNew) catch |err| {
        logger.errFmt(
            "[SESSION NAME] Failed to call LLM for session name session_id={s} model={s} error={s} detail={s}",
            .{ session_id, model, @errorName(err), name_agent.last_error_message orelse "(no server detail)" },
        );
        return;
    };

    if (response.content) |content| {
        // Strip thinking tags if present, fallback to original content on error
        var stripped_content: []const u8 = content;
        var needs_free = false;
        if (helpers.xml.stripThinkingTags(content, allocator)) |stripped| {
            stripped_content = stripped;
            needs_free = true;
        } else |err| {
            logger.warnFmt("[SESSION NAME] Failed to strip thinking tags: {s}, using original content", .{@errorName(err)});
        }

        // An empty / whitespace-only name is not a name.
        const trimmed_name = std.mem.trim(u8, stripped_content, " \t\r\n");
        if (!isUsableGeneratedName(trimmed_name)) {
            logger.warnFmt(
                "[SESSION NAME] model returned an empty name session_id={s} — keeping the placeholder",
                .{session_id},
            );
            if (needs_free) allocator.free(stripped_content);
            return;
        }
        stripped_content = trimmed_name;

        // limit to 50 chars
        if (stripped_content.len > 50) {
            stripped_content = stripped_content[0..50];
        }

        // Update session name in database. Log the ERROR, not the name:
        // the pre-fix line printed the generated name, so a failed UPDATE
        // was indistinguishable from a successful one in the log.
        updateSessionName(allocator, db, session_id, stripped_content, event_bus) catch |err| {
            logger.errFmt(
                "[SESSION NAME] Failed to update session name session_id={s} error={s} name={s}",
                .{ session_id, @errorName(err), stripped_content },
            );
            if (needs_free) allocator.free(stripped_content);
            return;
        };
        llm_history.updateTaskName(allocator, db, session_id, stripped_content) catch |err| {
            logger.errFmt(
                "[SESSION NAME] Failed to update task name session_id={s} error={s} name={s}",
                .{ session_id, @errorName(err), stripped_content },
            );
            if (needs_free) allocator.free(stripped_content);
            return;
        };

        logger.debugFmt("[SESSION NAME] Generated session name: {s}", .{stripped_content});
        if (needs_free) allocator.free(stripped_content);
    }
}

/// Save a per-retry diagnostic message to chat history so the user sees each
/// retry attempt live in their chat (instead of only learning about retries
/// via the final TooManyRetries summary) AND the AI agent has the full retry
fn clampDetail(detail: []const u8, max_len: usize) []const u8 {
    if (detail.len <= max_len) return detail;
    return detail[0..max_len];
}

fn saveRetryAttemptMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    event_bus: *event_bus_mod.EventBus,
    logger: *logger_mod.Logger,
    io: std.Io,
    cwd: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    effective_model: []const u8,
    effective_agent_name: []const u8,
    agent_temperature: f32,
    isThinking: bool,
    loop_counter: u32,
    attempt: u32,
    max_attempts: u32,
    source: []const u8,
    error_name: []const u8,
    /// Actual server-side reason (HTTP status+body, scanner error, raw SSE
    /// sample) — already clamped by the caller via `clampDetail`.
    server_detail: []const u8,
    delay_ms: u32,
) !void {
    // Track ownership explicitly. On allocPrint failure (e.g.
    const formatted = std.fmt.allocPrint(allocator,
        \\[Retry {d}/{d}] {s} ({s}). Retrying in {d}ms.
        \\Server said: {s}
    , .{ attempt, max_attempts, error_name, source, delay_ms, server_detail }) catch |err| blk: {
        logger.errFmt("Failed to format retry diagnostic: {s}", .{@errorName(err)});
        break :blk null;
    };
    const content: []const u8 = formatted orelse "[Retry error: formatting failed]";

    logger.errFmt("Retry {d}/{d}: {s} ({s}). Retrying in {d}ms.", .{ attempt, max_attempts, error_name, source, delay_ms });

    _ = try insertLLMHistories(.{
        .allocator = allocator,
        .io = io,
        .db = db,
        .logger = logger,
        .event_bus = event_bus,
        .is_emit_sse = true,
        .cwd = cwd,
        .is_skip_db = true,
        // Frontend AgentErrorCard routing (task_1787663566535_2).
        .is_error = true,
        .entity = .{
            .id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
            .session_id = session_id,
            .model = effective_model,
            .response_content = content,
            .reasoning_content = null,
            .role = agent.Role.user.to_str(),
            .finish_reason = "null",
            .tool_calls_json = "",
            .tool_call_id = null,
            .agent = effective_agent_name,
            .loop_index = loop_counter,
            .temperature = agent_temperature,
            .is_thinking = isThinking,
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
            .parent_id = parent_session_id,
            .parent_session_id = parent_session_id,
            .is_input = true,
            .is_output = false,
            .is_feed_to_llm = false,
            .image_urls = null,
            .created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds}),
        },
    });

    // NEW (plan 2026-08-29-chat-sidebar-last-human-touched, Task 5): "Also
    // when error too" — bump the session's last_human_touched_at whenever the
    // workflow emits an error diagnostic (retry-catch / unexpected
    llm_history.updateSessionLastHumanTouchedAt(
        allocator,
        db,
        session_id,
        null,
    ) catch |stamp_err| {
        logger.warnFmt(
            "saveRetryAttemptMessage: stamp session last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(stamp_err)},
        );
    };
}

fn callDynamicAgentNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    messages_list: std.ArrayList(agent.AgentMessage),
    agent_temperature: f32,
    current_max_tokens: usize,
    isThinking: bool,
    /// Anthropic-only override for `thinking.budget_tokens`. When set,
    /// `buildJsonAnthropicRequest` uses it directly (clamped to >=1024 and
    /// <max_tokens).
    thinking_budget_tokens: ?u32,
    /// Anthropic-only.
    thinking_adaptive: bool,
    /// OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). When
    /// set, `buildJsonOpenAIRequest` emits `reasoning_effort` verbatim.
    /// Anthropic-style URLs ignore this field.
    reasoning_effort: ?[]const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    url_style: []const u8,
    backend: []const u8,
    session_id: []const u8,
    equip_tools: []const agent.AgentTool,
    /// Polled by the agent's SSE chunk-read loop between chunks so a
    /// user-initiated Stop aborts the in-flight turn immediately instead of
    /// waiting for the response to finish (see `Agent.callStreaming`).
    cancel_fn: ?*const fn () bool,
    /// On error, the underlying server/transporter detail (drained HTTP error
    /// body, scanner error name, chunk count) so the retry-catch block can
    /// log the actual reason instead of just `error.ApiError` /
    out_last_error_message: *?[]const u8,
) !agent.CallResponse {
    // Libcurl-backed Agent (custom_http_client). Same field names, same
    // callStreaming signature as the previous std.http.Client version — only
    // the transport differs.
    var dynamic_agent = agent.Agent.init(allocator, io);
    dynamic_agent.apiKey = api_key;
    dynamic_agent.model = model;
    dynamic_agent.baseUrl = base_url;
    dynamic_agent.UrlStyle = url_style;
    dynamic_agent.backend = backend;
    dynamic_agent.sessionId = session_id;
    // `messages_list.items` is `[]agent.AgentMessage`; the local
    // `agent.AgentCall.messages` wants the same type — direct assignment.
    const messages_for_agent: []const agent.AgentMessage = messages_list.items;
    const dynamic_agent_call_params = agent.AgentCall{ .tools = equip_tools, .messages = messages_for_agent, .temperature = agent_temperature, .max_tokens = current_max_tokens, .cancel_fn = cancel_fn };
    dynamic_agent.thinkingEnabled = isThinking;
    // === Model-thinking ======================================= The
    // new fields are no-ops when the URL style isn't a match:
    // buildJsonAnthropicRequest ignores `reasoningEffort`; OpenAI
    dynamic_agent.thinkingBudgetTokens = thinking_budget_tokens;
    dynamic_agent.thinkingAdaptive = thinking_adaptive;
    dynamic_agent.reasoningEffort = reasoning_effort;
    dynamic_agent.httpOptions.read_timeout_ms = 300_000; // 10 minutes

    var stream_ctx = StreamingContext{
        .allocator = allocator,
        .session_id = session_id,
        .chunk_index = 0,
    };
    // 2026-09-02 stream-resume-on-reselect — mark the in-flight stream buffer
    // as started (clears any stale content from a previous turn) so `GET
    // /api/llm/session/:id/stream` can serve the partial text to a re-mounted
    stream_snapshot.beginStream(allocator, session_id);
    // `stream_callback` is typed as agent.StreamCallback; callStreaming
    // wants the same type — direct assignment, no @ptrCast needed.
    const callback_for_agent: agent.StreamCallback = &stream_callback;
    out_last_error_message.* = null;
    // Catch the callStreaming error so we can copy `last_error_message` out
    // BEFORE the deferred `dynamic_agent.deinit()` frees it.
    const res_dynamic_agent = dynamic_agent.callStreaming(dynamic_agent_call_params, &stream_ctx, callback_for_agent) catch |err| {
        if (dynamic_agent.last_error_message) |msg| {
            out_last_error_message.* = allocator.dupe(u8, msg) catch null;
        }
        return err;
    };
    // `callDynamicAgentNew` returns `agent.CallResponse` (preserves the
    // upstream signature).
    const tool_calls_for_agent: ?[]agent.ToolCall = res_dynamic_agent.tool_calls;
    const finish_reason_for_agent: ?agent.FinishReason = res_dynamic_agent.finish_reason;
    const usage_for_agent: agent.Usage = .{
        .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
        .completion_tokens = res_dynamic_agent.usage.completion_tokens,
        .total_tokens = res_dynamic_agent.usage.total_tokens,
        .cache_creation_input_tokens = res_dynamic_agent.usage.cache_creation_input_tokens,
        .cache_read_input_tokens = res_dynamic_agent.usage.cache_read_input_tokens,
    };
    return .{
        .allocator = res_dynamic_agent.allocator,
        .content = res_dynamic_agent.content,
        .tool_calls = tool_calls_for_agent,
        .finish_reason = finish_reason_for_agent,
        .reasoning_content = res_dynamic_agent.reasoning_content,
        .reasoning_id = res_dynamic_agent.reasoning_id,
        .reasoning_encrypted_content = res_dynamic_agent.reasoning_encrypted_content,
        .usage = usage_for_agent,
    };
}

fn noopStreamCallbackNew(_: ?*anyopaque, _: agent.StreamChunk) void {}

/// Callback for streaming chunks - sends each chunk to the client via SSE
pub fn stream_callback(ctx: ?*anyopaque, chunk: agent.StreamChunk) void {
    if (ctx == null) return;

    const stream_ctx = @as(*StreamingContext, @ptrCast(@alignCast(ctx.?)));
    const allocator = stream_ctx.allocator;
    const session_id = stream_ctx.session_id;

    // Handle done marker - no data to send
    if (chunk.done) {
        stream_ctx.chunk_index = 0;
        // 2026-09-02 stream-resume-on-reselect — flip the snapshot to
        // inactive (content stays readable for a late poll).
        stream_snapshot.endStream(allocator, session_id);
        return;
    }

    // Send content chunk if present
    if (chunk.content) |content| {
        if (content.len > 0) {
            const content_chunk = on_event_sent.ContentChunk{
                .index = stream_ctx.chunk_index,
                .content = content,
                .session_id = session_id,
            };
            on_event_sent.sendStreamChunkContent(allocator, session_id, content_chunk);
            // 2026-09-02 stream-resume-on-reselect — accumulate the delta
            // into the in-memory snapshot so a re-selected ChatView can
            // recover the partial text via GET /api/llm/session/:id/stream.
            stream_snapshot.appendContent(allocator, session_id, content);
        }
    }

    // Send reasoning chunk if present
    if (chunk.reasoning_content) |reasoning| {
        if (reasoning.len > 0) {
            const reasoning_chunk = on_event_sent.ReasoningChunk{
                .index = stream_ctx.chunk_index,
                .reasoning = reasoning,
                .session_id = session_id,
            };
            on_event_sent.sendStreamChunkReasoning(allocator, session_id, reasoning_chunk);
        }
    }

    // Send tool call delta chunk if present
    if (chunk.tool_calls_delta) |deltas| {
        if (deltas.len > 0) {
            const delta_chunk = on_event_sent.ToolCallDeltaChunk{
                .index = stream_ctx.chunk_index,
                .deltas = deltas,
                .session_id = session_id,
            };
            on_event_sent.sendStreamToolCallDelta(allocator, session_id, delta_chunk);
        }
    }

    stream_ctx.chunk_index += 1;
}

/// Filter and merge tools based on allowed_tools setting - allowed_tools: ""
/// = no filtering (all tools), "all" = all tools, "none" = zero tools (the
/// exact sentinel emitted by the agent override's zero-enabled case and the
pub fn filterAndMergeTools(
    allocator: std.mem.Allocator,
    mcp_tools: ?[]const agent.AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
    progressive_equipped: []const []const u8,
    // Injected by the caller from `config.skill_evals.enabled`.
    inject_skill_evals: bool,
) ![]agent.AgentTool {
    // Single source of truth for the allowlist + sub-agent strip
    // (shared with the progressive-tool catalog so the two can never
    // disagree about what is already enabled).
    const registered = tools.all_agent_tools(allocator);
    const enabled = try tool_eligibility.allowlistFilter(
        allocator,
        registered,
        allowed_tools,
        is_sub_agent,
    );

    var out: std.ArrayList(agent.AgentTool) = .empty;
    // Dedup by name, first wins. Today a server tool named `read_file` used to
    // ship twice; the built-in now wins.
    var seen: std.StringArrayHashMapUnmanaged(void) = .{};

    for (enabled) |tool| {
        if (seen.contains(tool.function.name)) continue;
        try seen.put(allocator, tool.function.name, {});
        try out.append(allocator, tool);
    }

    // Workspace secrets discovery: injected SERVER-SIDE, bypassing the
    // allowlist, exactly as the MCP/progressive and skill_evals injections
    // below do.
    if (!is_sub_agent and !seen.contains("list_secrets")) {
        for (registered) |tool| {
            if (std.mem.eql(u8, tool.function.name, "list_secrets")) {
                try seen.put(allocator, "list_secrets", {});
                try out.append(allocator, tool);
                break;
            }
        }
    }

    // Built-ins this session enabled for itself. Injected even when the
    // allowlist excluded them — that is the point of `use_tool`.
    for (progressive_equipped) |name| {
        if (seen.contains(name)) continue;
        if (is_sub_agent and ask_user_mod.isMainAgentOnly(name)) continue;
        for (registered) |tool| {
            if (std.mem.eql(u8, tool.function.name, name)) {
                try seen.put(allocator, name, {});
                try out.append(allocator, tool);
                break;
            }
        }
    }

    // Skill Evals: injected from CONFIG, not from the allowlist, and only
    // when the user turned the feature on.
    if (inject_skill_evals and !is_sub_agent and !seen.contains("run_skill_eval")) {
        for (registered) |tool| {
            if (std.mem.eql(u8, tool.function.name, "run_skill_eval")) {
                try seen.put(allocator, "run_skill_eval", {});
                try out.append(allocator, tool);
                break;
            }
        }
    }

    // MCP tools reach the wire ONLY when this session equipped them.
    if (mcp_tools) |mcp| {
        for (mcp) |tool| {
            if (seen.contains(tool.function.name)) continue;
            var equipped = false;
            for (progressive_equipped) |name| {
                if (std.mem.eql(u8, name, tool.function.name)) {
                    equipped = true;
                    break;
                }
            }
            if (!equipped) continue;
            try seen.put(allocator, tool.function.name, {});
            try out.append(allocator, tool);
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// How many of `names` exist in `list` (registered built-ins or the MCP
/// catalog). Used for the resolution checkpoint log.
fn countNamesIn(list: []const agent.AgentTool, names: []const []const u8) usize {
    var n: usize = 0;
    for (names) |name| {
        for (list) |tool| {
            if (std.mem.eql(u8, tool.function.name, name)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

pub const RunParams = struct {
    ctxTui: *pabrikcore.App,

    parent_allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
};

pub const SubAgentOverrides = struct {
    resolved_name: []const u8,
    is_random_fallback: bool,
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key: []const u8 = "",
    url_style: []const u8 = "",
    /// Transport override — `"http"` | `"claude-code"` | `"opencode"`.
    /// Empty = keep the parent's (see `ResolvedAgent.backend`).
    backend: []const u8 = "",
    /// Claude Code only: `CLAUDE_CONFIG_DIR` override. Null = parent's.
    config_dir: ?[]const u8 = null,
    /// Claude Code only: `--max-turns` override. Null = parent's.
    max_turns: ?u32 = null,
    /// OpenCode only: `--agent` override. Null = parent's.
    opencode_agent: ?[]const u8 = null,
    /// OpenCode only: `--auto` override. Null = parent's.
    opencode_auto: ?bool = null,
    is_thinking: ?bool = null,
    temperature: ?f32 = null,
    /// Anthropic-only override for `thinking.budget_tokens`. When set, the
    /// spawned sub-agent's `Agent.thinkingBudgetTokens` is this value (not
    /// the parent profile's).
    thinking_budget_tokens: ?u32 = null,
    /// OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). When set, the
    /// spawned sub-agent's `Agent.reasoningEffort` is this value.
    reasoning_effort: ?[]const u8 = null,
    system_prompt: []const u8 = "",
};

/// The agent a session runs with: a sub-agent's resolved override wins over
/// what this session resolved. It has to be applied before the first history
/// row is written — a sub-agent session has no config owner to resolve one.
pub fn effectiveAgentForSubAgent(
    base: config_mod.LlmConfig.EffectiveAgent,
    overrides: ?SubAgentOverrides,
) config_mod.LlmConfig.EffectiveAgent {
    var eff = base;
    const ov = overrides orelse return eff;
    if (ov.model.len > 0) eff.model = ov.model;
    if (ov.base_url.len > 0) eff.base_url = ov.base_url;
    if (ov.api_key.len > 0) eff.api_key = ov.api_key;
    if (ov.url_style.len > 0) eff.url_style = ov.url_style;
    // Transport: a non-empty string wins for `backend`, and the optional CLI
    // knobs are applied whenever the override carries one.
    if (ov.backend.len > 0) eff.backend = ov.backend;
    if (ov.config_dir) |d| eff.config_dir = d;
    if (ov.max_turns) |n| eff.max_turns = n;
    if (ov.opencode_agent) |a| eff.opencode_agent = a;
    if (ov.opencode_auto) |b| eff.opencode_auto = b;
    if (ov.is_thinking) |t| eff.is_thinking = t;
    // Model-thinking overrides. A non-null budget wins over the profile's
    // value, and so does a non-null reasoning effort.
    if (ov.thinking_budget_tokens) |t| eff.thinking_budget_tokens = t;
    if (ov.reasoning_effort) |re| {
        if (re.len > 0) eff.reasoning_effort = re;
    }
    return eff;
}

pub const RunParamsNew = struct {
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
    image_urls: []const u8 = "",
    video_urls: []const u8 = "",
    /// The chat's file attachments, as the JSON payload the model path
    /// reads. Empty when the message carries no file.
    file_attachments: []const u8 = "",
    selected_profile_model: []const u8 = "",
    inherited_context: []const u8 = "",
    sub_agent_overrides: ?SubAgentOverrides = null,
    is_auto_retry_until_stop: []const u8 = "",
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). When true,
    // runAgenticMultiStepnew skips the initial insertQueueMessage call.
    skip_initial_queue_message: bool = false,
};

// ─── Inline tests (formerly compaction_long_context_test.zig) ────────────
// Long-context compaction test. Inlined here. The original test file
// self-imported zig — that self-import is removed in the inlined copy.

/// Walk ALL migrations from 001 → latest (per project memory
/// `llm-history-test-use-migrations-module.md`). No hand-rolled
/// CREATE TABLE — the migration chain is the source of truth.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
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

fn teardownDb(s: *@TypeOf(setupDb() catch @panic("setupDb failed in the workflow test fixture"))) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "end-to-end: compaction envelope is queryable via getCompactedMessages" {
    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    // Build a 6-message fixture (system + 5 dropped). Capture the
    // DB ids we'll write for the dropped messages so we can verify
    // they show up in the read tool's output AFTER compaction.
    const session_id = "sess_e2e_1";
    const dropped_ids = [_][]const u8{ "h_real_1", "h_real_2", "h_real_3", "h_real_4", "h_real_5" };
    const dropped_contents = [_][]const u8{
        "Fix the login bug",
        "I'll investigate the auth flow",
        "running tests now",
        "tests pass: 42/42",
        "shipping the patch",
    };
    const dropped_roles = [_][]const u8{ "user", "assistant", "assistant", "tool", "user" };

    // Pre-seed the DB with realistic ids (so the agent can fetch them after compaction).
    for (dropped_ids, dropped_contents, dropped_roles) |id, content, role| {
        const sql =
            \\INSERT INTO llm_history (id, session_id, model, response_content, role, is_feed_to_llm, created_at_nano, tool_call_id, tool_name)
            \\VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
        ;
        const created_at = "2025-01-01 00:00:00";
        var tcid_buf: [16]u8 = undefined;
        const tcid = if (std.mem.eql(u8, role, "tool")) std.fmt.bufPrint(&tcid_buf, "tc_{s}", .{id}) catch "" else "";
        const tname = if (std.mem.eql(u8, role, "tool")) "bash" else "";
        try s.db.exec(alloc, sql, &.{ id, session_id, "gpt-4o", content, role, created_at, tcid, tname });
    }

    // Build the in-memory message list and compact it.
    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.append(alloc, .{ .role = .system, .content = try alloc.dupe(u8, "You are a coding agent.") });
    for (dropped_contents, 0..) |content, i| {
        const role_str = dropped_roles[i];
        const role_enum = std.meta.stringToEnum(agent.Role, role_str) orelse .user;
        try messages.append(alloc, .{
            .role = role_enum,
            .content = try alloc.dupe(u8, content),
            .tool_call_id = if (std.mem.eql(u8, role_str, "tool")) try alloc.dupe(u8, "tc_x") else null,
        });
    }
    // No defer messages.deinit — compactMessageInMemoryNew takes ownership (T → !T).

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    const new_messages = try compactMessageInMemoryNew(
        alloc,
        messages,
        "{\"compact_messages\":{\"format_version\":2},\"summary\":null}",
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

    // Now exercise getCompactedMessages in both modes.

    // INDEX MODE: should return the 5 dropped messages.
    const index_results = try llm_history.getCompactedMessages(alloc, &s.db, session_id, .{});
    defer {
        for (index_results) |*m| m.deinit(alloc);
        alloc.free(index_results);
    }
    try testing.expectEqual(@as(usize, 5), index_results.len);
    for (dropped_ids) |id| {
        // The read tool returns rows by their pre-seeded h_real_* ids (the
        // in-memory messages in this test don't set .id, so the envelope uses
        // "unknown" placeholders — but the DB rows still carry the real
        try testing.expect(std.mem.indexOf(u8, id, "h_real_") == null or index_results.len > 0);
    }
    // Verify the h_real_ ids appear in the read tool's results
    var found_real = [_]bool{ false, false, false, false, false };
    for (index_results) |m| {
        for (dropped_ids, 0..) |id, idx| {
            if (std.mem.eql(u8, m.id, id)) found_real[idx] = true;
        }
    }
    for (found_real) |found| {
        try testing.expect(found);
    }
    // And verify the tool result for the tool role includes tool_name
    for (index_results) |m| {
        if (std.mem.eql(u8, m.role, "tool")) {
            try testing.expect(m.tool_name != null);
            try testing.expectEqualStrings("bash", m.tool_name.?);
        }
    }
}

/// Agent Mode helper: if `session_id` is bound to a workspace_item whose
/// item_type='agent', resolve the agent's allowed_tools from the
/// `agent_tools` table and overwrite `out_allowed_tools` with the
fn maybeOverrideAllowedToolsForAgent(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    out_allowed_tools: *[]const u8,
) !bool {
    if (session_id.len == 0) return false;

    // Resolve session_id → workspace_item_id.
    var q1 = db.query(
        allocator,
        "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return false;
    defer q1.deinit();
    const row1 = (q1.next() catch null) orelse return false;
    defer row1.deinit(allocator);
    const workspace_item_id = row1.values[0];

    // Only filter when the workspace_item is an agent.
    if (!agent_db.exists(allocator, .{ .db = db }, workspace_item_id)) return false;

    // Fetch the enabled tool_names.
    const names = agent_db.listEnabledToolNames(allocator, .{ .db = db }, workspace_item_id) catch return false;
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    // Zero enabled rows → secure-by-default zero tools.
    if (names.len == 0) {
        out_allowed_tools.* = "none";
        return true;
    }

    // Non-empty: join with ','.
    out_allowed_tools.* = try std.mem.join(allocator, ",", names);
    return true;
}

/// Agent-Kanbans mirror (Migration 081): override `out_allowed_tools` with
/// the board's allowlist from `agent_kanban_tools` when the session's
/// workspace_item is a kanban WITH an `agent_kanbans` row.
fn maybeOverrideAllowedToolsForKanban(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    out_allowed_tools: *[]const u8,
) !bool {
    if (session_id.len == 0) return false;

    // Resolve session_id → workspace_item_id.
    var q1 = db.query(
        allocator,
        "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return false;
    defer q1.deinit();
    const row1 = (q1.next() catch null) orelse return false;
    defer row1.deinit(allocator);
    const workspace_item_id = row1.values[0];

    // Only filter when the workspace_item has an agent_kanbans row.
    var q2 = db.query(
        allocator,
        "SELECT id FROM agent_configs WHERE id = ? AND item_type = 'kanban'",
        &[_][]const u8{workspace_item_id},
    ) catch return false;
    defer q2.deinit();
    const row2 = (q2.next() catch null) orelse return false;
    defer row2.deinit(allocator);

    // Fetch the enabled tool_names.
    var q3 = db.query(allocator,
        \\SELECT tool_name FROM agent_config_tools
        \\WHERE config_id = ? AND enabled = 1
        \\ORDER BY tool_name ASC
    , &[_][]const u8{workspace_item_id}) catch return false;
    defer q3.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    while ((q3.next() catch null)) |r| {
        defer r.deinit(allocator);
        try names.append(allocator, try allocator.dupe(u8, r.values[0]));
    }

    // D5: configured but zero enabled tools = "not configured" — leave
    // caller defaults untouched. See doc comment above for the flip.
    if (names.items.len == 0) {
        return false;
    }

    // Non-empty: join with ','.
    out_allowed_tools.* = try std.mem.join(allocator, ",", names.items);
    return true;
}

/// Agent-Routines mirror (Migration 087): override `out_allowed_tools` with
/// the routine's allowlist from `agent_routine_tools` when the session
/// belongs to a routine WITH an `agent_routines` row.
fn maybeOverrideAllowedToolsForRoutine(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    out_allowed_tools: *[]const u8,
) !bool {
    if (session_id.len == 0) return false;

    // Resolve session_id → workspace_item_id (tasks first, then fires).
    // Duped: row defers are block-scoped, so the slice must be owned here.
    var workspace_item_id: []const u8 = "";
    defer if (workspace_item_id.len > 0) allocator.free(workspace_item_id);
    var q1 = db.query(
        allocator,
        "SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{session_id},
    ) catch return false;
    defer q1.deinit();
    if ((q1.next() catch null)) |row1| {
        defer row1.deinit(allocator);
        workspace_item_id = try allocator.dupe(u8, row1.values[0]);
    } else {
        var qf = db.query(
            allocator,
            "SELECT workspace_item_id FROM workspace_routines WHERE id = ?",
            &[_][]const u8{session_id},
        ) catch return false;
        defer qf.deinit();
        const rowf = (qf.next() catch null) orelse return false;
        defer rowf.deinit(allocator);
        workspace_item_id = try allocator.dupe(u8, rowf.values[0]);
    }
    if (workspace_item_id.len == 0) return false;

    // Only filter when the workspace_item has an agent_routines row.
    var q2 = db.query(
        allocator,
        "SELECT id FROM agent_configs WHERE id = ? AND item_type = 'routine'",
        &[_][]const u8{workspace_item_id},
    ) catch return false;
    defer q2.deinit();
    const row2 = (q2.next() catch null) orelse return false;
    defer row2.deinit(allocator);

    // Fetch the enabled tool_names.
    var q3 = db.query(allocator,
        \\SELECT tool_name FROM agent_config_tools
        \\WHERE config_id = ? AND enabled = 1
        \\ORDER BY tool_name ASC
    , &[_][]const u8{workspace_item_id}) catch return false;
    defer q3.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    while ((q3.next() catch null)) |r| {
        defer r.deinit(allocator);
        try names.append(allocator, try allocator.dupe(u8, r.values[0]));
    }

    // D5: configured but zero enabled tools = "not configured".
    if (names.items.len == 0) {
        return false;
    }

    // Non-empty: join with ','.
    out_allowed_tools.* = try std.mem.join(allocator, ",", names.items);
    return true;
}

/// Config-default fallback: apply config.json's top-level `tools` checklist
/// as `allowed_tools` when NO agent / kanban / routine override fired (the
/// final else-if in the `runAgenticMultiStepnew` chain, inside the
fn maybeOverrideAllowedToolsForConfigDefault(
    allocator: std.mem.Allocator,
    config_tools: ?[]const []const u8,
    out_allowed_tools: *[]const u8,
) !bool {
    const names = config_tools orelse return false;

    // Explicit-empty checklist → zero tools. Must be the `none` sentinel:
    // emitting `""` would mean "no filtering → all tools" in
    // allowlistFilter — the exact opposite of what the user checked.
    if (names.len == 0) {
        out_allowed_tools.* = "none";
        return true;
    }

    out_allowed_tools.* = try std.mem.join(allocator, ",", names);
    return true;
}

test "config default override: null (key absent) leaves the request body untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var out: []const u8 = "request_body_tools";
    const fired = try maybeOverrideAllowedToolsForConfigDefault(arena.allocator(), null, &out);
    try testing.expect(!fired);
    try testing.expectEqualStrings("request_body_tools", out);
}

test "config default override: [] maps to the none sentinel (D2/D3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var out: []const u8 = "request_body_tools";
    const empty: []const []const u8 = &.{};
    const fired = try maybeOverrideAllowedToolsForConfigDefault(arena.allocator(), empty, &out);
    try testing.expect(fired);
    try testing.expectEqualStrings("none", out);
}

test "config default override: non-empty list joins into the CSV allowlist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var out: []const u8 = "request_body_tools";
    const cfg = [_][]const u8{ "command", "read_file", "glob" };
    const fired = try maybeOverrideAllowedToolsForConfigDefault(arena.allocator(), &cfg, &out);
    try testing.expect(fired);
    try testing.expectEqualStrings("command,read_file,glob", out);
}

test "filterAndMergeTools: MCP tools are progressive — absent from the tool list unless equipped" {
    // MCP is progressive: the catalog is fetched and cached (so search_tool
    // can offer it) but NOT injected into the LLM's tool list until the
    // session equips it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mock_mcp = [_]agent.AgentTool{.{
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "mcp_graphify_query_graph"),
            .description = try alloc.dupe(u8, "Search the graph"),
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    }};
    // allowed_tools="" means no filtering — every built-in, no MCP.
    const merged = try filterAndMergeTools(alloc, &mock_mcp, "", false, &.{}, false);
    try testing.expect(merged.len > 0);
    for (merged) |t| {
        try testing.expect(!std.mem.startsWith(u8, t.function.name, "mcp_"));
    }

    // Null MCP (not configured) still yields the built-ins.
    const merged_null = try filterAndMergeTools(alloc, null, "", false, &.{}, false);
    try testing.expect(merged_null.len > 0);
}

test "filterAndMergeTools: an equipped MCP tool is appended after the built-ins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var mock_mcp = [_]agent.AgentTool{.{
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "mcp_graphify_query_graph"),
            .description = try alloc.dupe(u8, "Search the graph"),
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    }};

    const merged = try filterAndMergeTools(alloc, &mock_mcp, "", false, &.{"mcp_graphify_query_graph"}, false);

    // Present, and LAST — append-only so the built-in prefix stays stable.
    const last = merged[merged.len - 1];
    try testing.expectEqualStrings("mcp_graphify_query_graph", last.function.name);
    for (merged[0 .. merged.len - 1]) |t| {
        try testing.expect(!std.mem.startsWith(u8, t.function.name, "mcp_"));
    }
}

test "filterAndMergeTools: a not-enabled built-in becomes available once session-equipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // allowlist "read_file" → glob is not enabled, so normally absent.
    const without = try filterAndMergeTools(alloc, null, "read_file", false, &.{}, false);
    var found_glob = false;
    for (without) |t| {
        if (std.mem.eql(u8, t.function.name, "glob")) found_glob = true;
    }
    try testing.expect(!found_glob);

    // Equipped via use_tool → injected even though the allowlist excluded it.
    const with_equipped = try filterAndMergeTools(alloc, null, "read_file", false, &.{"glob"}, false);
    var found_read_file = false;
    found_glob = false;
    for (with_equipped) |t| {
        if (std.mem.eql(u8, t.function.name, "glob")) found_glob = true;
        if (std.mem.eql(u8, t.function.name, "read_file")) found_read_file = true;
    }
    try testing.expect(found_glob);
    try testing.expect(found_read_file);
}

test "filterAndMergeTools: the progressive tools ship when the tool config names them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A tool config that NAMES them — which is exactly what the creation-time
    // seed does for agent and kanban items (DEFAULT_AGENT_TOOLS includes the
    // three, and only workspace_items_create_agent / _kanban apply that list).
    const seeded = "read_file,search_tool,view_tool,use_tool";
    const with_metas = try filterAndMergeTools(alloc, null, seeded, false, &.{}, false);
    for (progressive_tools_mod.PROGRESSIVE_TOOL_NAMES) |name| {
        var found = false;
        for (with_metas) |t| {
            if (std.mem.eql(u8, t.function.name, name)) found = true;
        }
        try testing.expect(found);
    }
    var found_read_file = false;
    for (with_metas) |t| {
        if (std.mem.eql(u8, t.function.name, "read_file")) found_read_file = true;
    }
    try testing.expect(found_read_file);
    // 4 allowlisted + the injected list_secrets.
    try testing.expectEqual(@as(usize, 5), with_metas.len);

    // A tool config that does NOT name them (a design or folder item, which
    // seeds no list, or a user who unticked them): they are simply absent —
    // no special-casing either way.
    const without_metas = try filterAndMergeTools(alloc, null, "read_file,glob", false, &.{}, false);
    for (without_metas) |t| {
        for (progressive_tools_mod.PROGRESSIVE_TOOL_NAMES) |name| {
            try testing.expect(!std.mem.eql(u8, t.function.name, name));
        }
    }
    // read_file, glob, and the injected list_secrets — none of the three
    // progressive meta-tools.
    try testing.expectEqual(@as(usize, 3), without_metas.len);

    // `use_tool` remains the escape hatch: an equipped tool is injected even
    // when the allowlist excluded it.
    const equipped = try filterAndMergeTools(alloc, null, "read_file", false, &.{"use_tool"}, false);
    var found_equipped = false;
    for (equipped) |t| {
        if (std.mem.eql(u8, t.function.name, "use_tool")) found_equipped = true;
    }
    try testing.expect(found_equipped);
    // read_file + use_tool (equipped) + the injected list_secrets.
    try testing.expectEqual(@as(usize, 3), equipped.len);

    // Only spawn_sub_agent is ever stripped for a sub-agent.
    const sub = try filterAndMergeTools(alloc, null, seeded, true, &.{}, false);
    for (progressive_tools_mod.PROGRESSIVE_TOOL_NAMES) |name| {
        var found = false;
        for (sub) |t| {
            if (std.mem.eql(u8, t.function.name, name)) found = true;
        }
        try testing.expect(found);
    }
}

test "filterAndMergeTools: dedup by name, the built-in wins over a colliding MCP tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A server tool named exactly like a built-in.
    var mock_mcp = [_]agent.AgentTool{.{
        .type = "function",
        .function = .{
            .name = try alloc.dupe(u8, "read_file"),
            .description = try alloc.dupe(u8, "impostor from an MCP server"),
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    }};

    const merged = try filterAndMergeTools(alloc, &mock_mcp, "read_file", false, &.{"read_file"}, false);
    var count: usize = 0;
    for (merged) |t| {
        if (std.mem.eql(u8, t.function.name, "read_file")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "filterAndMergeTools: a sub-agent cannot re-equip spawn_sub_agent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const merged = try filterAndMergeTools(alloc, null, "all", true, &.{"spawn_sub_agent"}, false);
    for (merged) |t| {
        try testing.expect(!std.mem.eql(u8, t.function.name, "spawn_sub_agent"));
    }
}

test "filterAndMergeTools: list_secrets is injected past the allowlist, for main agents only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The Migration099 lesson: a tool only new agents have is a tool no
    // existing agent ever sees.
    const restrictive = "read_file,glob";
    const merged = try filterAndMergeTools(alloc, null, restrictive, false, &.{}, false);

    var found_secrets = false;
    var found_read_file = false;
    for (merged) |t| {
        if (std.mem.eql(u8, t.function.name, "list_secrets")) found_secrets = true;
        if (std.mem.eql(u8, t.function.name, "read_file")) found_read_file = true;
    }
    try testing.expect(found_read_file);
    try testing.expect(found_secrets);

    // Exactly once — the injection must not duplicate a tool the allowlist
    // already granted.
    var count: usize = 0;
    for (merged) |t| {
        if (std.mem.eql(u8, t.function.name, "list_secrets")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    const with_it_allowed = try filterAndMergeTools(alloc, null, "read_file,list_secrets", false, &.{}, false);
    var count_allowed: usize = 0;
    for (with_it_allowed) |t| {
        if (std.mem.eql(u8, t.function.name, "list_secrets")) count_allowed += 1;
    }
    try testing.expectEqual(@as(usize, 1), count_allowed);

    // `is_sub_agent` is still respected by the INJECTION.
    const sub = try filterAndMergeTools(alloc, null, restrictive, true, &.{}, false);
    for (sub) |t| {
        try testing.expect(!std.mem.eql(u8, t.function.name, "list_secrets"));
        try testing.expect(std.mem.eql(u8, t.function.name, "read_file") or std.mem.eql(u8, t.function.name, "glob"));
    }

    // The `"none"` sentinel still receives it, exactly as the skill_evals
    // injection above does.
    const none = try filterAndMergeTools(alloc, null, "none", false, &.{}, false);
    var none_secrets = false;
    for (none) |t| {
        if (std.mem.eql(u8, t.function.name, "list_secrets")) none_secrets = true;
    }
    try testing.expect(none_secrets);
}

test "filterAndMergeTools: the injected list_secrets schema cannot be pointed at another workspace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Asserted on the SERIALIZED schema of the tool that actually gets
    // appended, not on the const in the tool module: this is the copy the
    // model reads, and it is the copy that matters.
    const merged = try filterAndMergeTools(alloc, null, "read_file", false, &.{}, false);

    var checked = false;
    for (merged) |t| {
        if (!std.mem.eql(u8, t.function.name, "list_secrets")) continue;
        checked = true;

        const schema_json = try std.json.Stringify.valueAlloc(alloc, t, .{});
        defer alloc.free(schema_json);
        try testing.expect(std.mem.indexOf(u8, schema_json, "\"workspace_id\"") == null);
        try testing.expect(std.mem.indexOf(u8, schema_json, "\"value\"") == null);
        try testing.expect(std.mem.indexOf(u8, schema_json, "\"properties\":[]") != null);
        try testing.expectEqual(@as(usize, 0), t.function.parameters.properties.len);
    }
    try testing.expect(checked);
}

test "list_secrets prompt rule: the gated append is in buildMessages, and the gate really is a gate" {
    // Static contract, in the spirit of the source-grep tests above: the rule
    // exists in `core.zig` and is reachable through the `prompts.zig` barrel
    // the builder consumes.
    const alloc = testing.allocator;

    const builder = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/agentic_loop/prompts_build_messages_for_agent_prompt.zig",
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(builder);

    const gate = std.mem.indexOf(u8, builder, "if (hasTool(filtered_tools, \"list_secrets\")) {") orelse
        return error.SecretsRuleNotGated;
    const append = std.mem.indexOf(u8, builder, "prompts_const.SecretsToolRule") orelse
        return error.SecretsRuleNotAppended;

    // The append has to be INSIDE the gate's block. The gap between the
    // condition and the append is a few bytes of body and nothing else — a
    // closing brace in between would mean the rule is unconditional.
    try testing.expect(gate < append);
    try testing.expect(append - gate < 120);
    try testing.expect(std.mem.indexOf(u8, builder[gate..append], "}") == null);

    // The rule has to say the three things the feature cannot work without.
    const core_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/modules/agent/prompts/core.zig",
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(core_src);

    const rule_start = std.mem.indexOf(u8, core_src, "pub const SecretsToolRule =") orelse
        return error.SecretsRuleMissing;
    const rule_end = std.mem.indexOf(u8, core_src, "pub const CrossProjectCwdRule =") orelse
        return error.RuleEndNotFound;
    const rule = core_src[rule_start..rule_end];

    try testing.expect(std.mem.indexOf(u8, rule, "{{SECRETS:NAME}}") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "list_secrets") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "ANY tool parameter") != null);
    try testing.expect(std.mem.indexOf(u8, rule, "Never echo, print, log, or write a secret's value") != null);
}

// Composition test: replays exactly what the loop does at the resolution
// point (getProgressiveTools -> buildCatalog -> filterAndMergeTools) against
// a real database, so the three pieces are proven to fit together — not just
test "progressive tool search: equipping a built-in makes it appear in the next resolution" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS session_progressive_tool (
        \\    session_id TEXT NOT NULL,
        \\    tool_name TEXT NOT NULL,
        \\    server_name TEXT NOT NULL DEFAULT '',
        \\    loaded_at_nano INTEGER NOT NULL DEFAULT 0,
        \\    PRIMARY KEY (session_id, tool_name)
        \\)
    , &.{});
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = tools.all_agent_tools(a);
    const session_id = "s_prog";

    // ── Before: only read_file is enabled, so glob is NOT in the tool list
    //    but IS discoverable, and the meta-tools ship because the catalog is
    //    non-empty.
    const catalog_before = try progressive_catalog.buildCatalog(a, registered, "read_file", false, null, &.{}, "agent");
    try testing.expect(catalog_before.len > 0);
    var glob_discoverable = false;
    for (catalog_before) |entry| {
        if (std.mem.eql(u8, entry.name, "glob")) glob_discoverable = true;
        // An enabled tool is never offered.
        try testing.expect(!std.mem.eql(u8, entry.name, "read_file"));
    }
    try testing.expect(glob_discoverable);

    var names_before: [0][]const u8 = .{};
    // What agent/kanban creation seeds: the three progressive tools are
    // named in the tool config, so they are in the list from turn one.
    const seeded_allowlist = "read_file" ++ ",search_tool" ++ ",view_tool" ++ ",use_tool";
    const before = try filterAndMergeTools(a, null, seeded_allowlist, false, &names_before, false);
    var found_glob_before = false;
    var found_search_tool_before = false;
    for (before) |t| {
        if (std.mem.eql(u8, t.function.name, "glob")) found_glob_before = true;
        if (std.mem.eql(u8, t.function.name, "search_tool")) found_search_tool_before = true;
    }
    try testing.expect(!found_glob_before);
    try testing.expect(found_search_tool_before);

    // ── The agent calls use_tool("glob") → one row.
    const inserted = try llm_history.saveProgressiveTool(a, &db, &lg, session_id, "glob", "");
    try testing.expect(inserted);
    // Re-equipping writes nothing (the validation rule).
    const again = try llm_history.saveProgressiveTool(a, &db, &lg, session_id, "glob", "");
    try testing.expect(!again);

    // ── After: the loop re-reads the session's equip set.
    const rows = try llm_history.getProgressiveTools(a, &db, session_id);
    try testing.expectEqual(@as(usize, 1), rows.len);
    const names_after = try a.alloc([]const u8, rows.len);
    for (rows, 0..) |row, i| names_after[i] = row.tool_name;

    const catalog_after = try progressive_catalog.buildCatalog(a, registered, "read_file", false, null, names_after, "agent");
    // An equipped tool is no longer discoverable (it is enabled now).
    for (catalog_after) |entry| {
        try testing.expect(!std.mem.eql(u8, entry.name, "glob"));
    }

    const after = try filterAndMergeTools(a, null, seeded_allowlist, false, names_after, false);
    var found_glob_after = false;
    var found_read_file_after = false;
    var found_search_tool_after = false;
    for (after) |t| {
        if (std.mem.eql(u8, t.function.name, "glob")) found_glob_after = true;
        if (std.mem.eql(u8, t.function.name, "read_file")) found_read_file_after = true;
        if (std.mem.eql(u8, t.function.name, "search_tool")) found_search_tool_after = true;
    }
    // The equipped built-in is injected even though the allowlist excluded it,
    // the enabled built-in is still there, and the meta-tools remain.
    try testing.expect(found_glob_after);
    try testing.expect(found_read_file_after);
    try testing.expect(found_search_tool_after);

    // ── Append-only: the enabled prefix is unchanged, glob is last.
    try testing.expect(after.len > before.len);
    for (before, after[0..before.len]) |b, aft| {
        try testing.expectEqualStrings(b.function.name, aft.function.name);
    }
    try testing.expectEqualStrings("glob", after[after.len - 1].function.name);
}

test "progressive tool search: an MCP tool is invisible until equipped, then appended last" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS session_progressive_tool (
        \\    session_id TEXT NOT NULL,
        \\    tool_name TEXT NOT NULL,
        \\    server_name TEXT NOT NULL DEFAULT '',
        \\    loaded_at_nano INTEGER NOT NULL DEFAULT 0,
        \\    PRIMARY KEY (session_id, tool_name)
        \\)
    , &.{});
    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock_mcp = [_]agent.AgentTool{.{
        .type = "function",
        .function = .{
            .name = "mcp_ctx_query-docs",
            .description = "Query docs",
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    }};
    const session_id = "s_mcp";

    // Never injected while the equip set is empty, even with "all" built-ins.
    const before = try filterAndMergeTools(a, &mock_mcp, "all", false, &.{}, false);
    for (before) |t| {
        try testing.expect(!std.mem.eql(u8, t.function.name, "mcp_ctx_query-docs"));
    }

    _ = try llm_history.saveProgressiveTool(a, &db, &lg, session_id, "mcp_ctx_query-docs", "ctx");
    const rows = try llm_history.getProgressiveTools(a, &db, session_id);
    const names = try a.alloc([]const u8, rows.len);
    for (rows, 0..) |row, i| names[i] = row.tool_name;

    const after = try filterAndMergeTools(a, &mock_mcp, "all", false, names, false);
    try testing.expectEqualStrings("mcp_ctx_query-docs", after[after.len - 1].function.name);
}

/// Insert a minimal session row (matching the production schema: the
/// `sessions` table's NOT NULL columns are id, name, status, cwd, created_at,
/// updated_at, selected_profile_model, is_auto_retry_until_stop).
fn re_read_insertSession(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    selected_profile_model: []const u8,
) !void {
    try db.exec(
        alloc,
        \\INSERT INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop)
        \\VALUES (?, 'test', 'active', '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, '0')
    ,
        &.{ session_id, selected_profile_model },
    );
}

test "re_read_selected_profile_model: returns live DB value when row exists" {
    // Wrap in a per-test arena so the dupe'd slice is freed at the
    // end of the test (matches production usage in runAgenticMultiStepnew
    // where the caller passes the per-iteration arena allocator).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_alpha", "beta");
    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_alpha", "fallback-snapshot");
    try testing.expectEqualStrings("beta", got);
}

test "re_read_selected_profile_model: returns empty string when DB has empty (mirrors COALESCE)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_empty", "");
    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_empty", "fallback-snapshot");
    try testing.expectEqualStrings("", got);
}

test "re_read_selected_profile_model: returns fallback when no session row exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    const got = re_read_selected_profile_model(alloc, &ctx.db, "s_missing", "fallback-snapshot");
    try testing.expectEqualStrings("fallback-snapshot", got);
}

test "re_read_selected_profile_model: subsequent reads see UPDATEd value (live re-read)" {
    // The whole point of this helper: a second call after a session row
    // UPDATE picks up the new value, NOT the snapshot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ctx = try re_read_setupDb();
    defer re_read_teardown(&ctx);

    try re_read_insertSession(alloc, &ctx.db, "s_live", "alpha");
    const first = re_read_selected_profile_model(alloc, &ctx.db, "s_live", "snapshot");
    try testing.expectEqualStrings("alpha", first);

    // Simulate the user picking a different profile in the chatview
    // dropdown (PUT /api/llm/session/:id → sessions.selected_profile_model).
    try ctx.db.exec(
        alloc,
        "UPDATE sessions SET selected_profile_model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        &.{ "gamma", "s_live" },
    );

    const second = re_read_selected_profile_model(alloc, &ctx.db, "s_live", "snapshot");
    try testing.expectEqualStrings("gamma", second);
}

test "a sub-agent's override supplies the model when the session's own resolution is empty" {
    const base = config_mod.LlmConfig.EffectiveAgent{
        .model = "",
        .base_url = "",
        .api_key = "",
        .url_style = "",
        .backend = "http",
        .config_dir = null,
        .max_turns = null,
        .opencode_agent = null,
        .opencode_auto = null,
        .thinking_str = "auto",
        .is_thinking = null,
        .thinking_adaptive = true,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    };
    const eff = effectiveAgentForSubAgent(base, .{
        .resolved_name = "opencode",
        .is_random_fallback = false,
        .model = "minimax-m3.1-flash-free",
        .base_url = "https://opencode.ai/inference/go/v1/chat/completions",
        .api_key = "a-key",
        .url_style = "openai",
    });
    try testing.expectEqualStrings("minimax-m3.1-flash-free", eff.model);
    try testing.expectEqualStrings("https://opencode.ai/inference/go/v1/chat/completions", eff.base_url);
    try testing.expectEqualStrings("a-key", eff.api_key);
    try testing.expectEqualStrings("openai", eff.url_style);
}

test "a session that spawns no sub-agent keeps the agent it resolved" {
    const base = config_mod.LlmConfig.EffectiveAgent{
        .model = "space-bunny-free",
        .base_url = "https://opencode.ai/zen/go/v1/chat/completions",
        .api_key = "a-key",
        .url_style = "openai",
        .backend = "http",
        .config_dir = null,
        .max_turns = null,
        .opencode_agent = null,
        .opencode_auto = null,
        .thinking_str = "auto",
        .is_thinking = null,
        .thinking_adaptive = true,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    };
    const eff = effectiveAgentForSubAgent(base, null);
    try testing.expectEqualStrings("space-bunny-free", eff.model);
    try testing.expectEqualStrings("a-key", eff.api_key);
}

test "flushCancelledPartial persists the streamed partial as a cancelled turn" {
    // Phase C contract: a Stop mid-stream must leave the transcript settled.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Run the REAL migrations rather than hand-rolling `llm_history`:
    // `insertLLMHistories` binds ~30 columns plus an `UPDATE sessions`, and a
    // hand-written CREATE TABLE would silently drift from the real schema.
    var mgr = migration_mod.MigrationManager.init(alloc, &db);
    // `registerAllMigrations` grows this list; the manager does not own its
    // teardown.
    defer mgr.migrations.deinit(alloc);
    try migration_mod.registerAllMigrations(&mgr);
    try mgr.runMigrations();

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var bus = event_bus_mod.EventBus.init("cancel-partial-test", alloc, std.testing.io);

    // The flush path is arena-scoped BY CONTRACT — production passes the
    // per-iteration arena, and `insertLLMHistories` hands several allocations
    // to the SSE emit path without freeing them itself.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const session_id = "sess_cancel_partial";

    // Exactly what the agent loop leaves behind when a stream is aborted: the
    // accumulated content sits in the snapshot registry, and the terminal
    // `done` chunk never arrived so `endStream` was never called.
    stream_snapshot.beginStream(alloc, session_id);
    stream_snapshot.appendContent(alloc, session_id, "hello ");
    stream_snapshot.appendContent(alloc, session_id, "wor");

    flushCancelledPartial(.{
        .allocator = a,
        .io = io,
        .db = &db,
        .logger = &lg,
        .event_bus = &bus,
        .cwd = "/tmp",
        .session_id = session_id,
        .parent_session_id = session_id,
        .model = "test-model",
        .agent_name = "Agent",
        .temperature = 0.2,
        .is_thinking = false,
        .loop_counter = 1,
    });

    var rows = try db.query(
        a,
        "SELECT response_content, finish_reason, role, is_output FROM llm_history WHERE session_id = ?",
        &.{session_id},
    );
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoRowInserted;
    defer row.deinit(a);

    // The text the user already saw is preserved (Option A: assistant rows
    // persist the {model,msg} envelope; unwrap to .msg for the assertion)...
    const stored = row.values[0];
    const unwrapped = try parsing_mod.unwrapChatContent(a, stored);
    try testing.expectEqualStrings("hello wor", unwrapped);
    // ...flagged as cancelled, NOT "stop" — the frontend's completed-turn
    // affordances key off "stop", and an aborted turn must not claim them.
    try testing.expectEqualStrings("cancelled", row.values[1]);
    try testing.expectEqualStrings("assistant", row.values[2]);
    // `is_output` is what makes the row render as an assistant bubble.
    try testing.expectEqualStrings("1", row.values[3]);

    // Snapshot released: a stream-resume poll must not resurrect a
    // placeholder for a turn that is no longer running.
    const snap = try stream_snapshot.getSnapshot(a, session_id);
    try testing.expect(!snap.active);
}

test "sessionNameIsPlaceholder: un-named sessions are a placeholder, real names are not" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer teardownDb(&s);

    // Both UI placeholders count — "New Chat" is what the sidebar's
    // new-chat flow creates, "New Session" is the TUI/handler default.
    for ([_][]const u8{ "s_new_chat", "s_new_session" }) |id| {
        try s.db.exec(
            alloc,
            "INSERT INTO sessions (id, name, status) VALUES (?, ?, 'active')",
            &.{ id, if (std.mem.eql(u8, id, "s_new_chat")) "New Chat" else "New Session" },
        );
        try testing.expect(sessionNameIsPlaceholder(alloc, &s.db, id));
    }

    // A generated or user-typed name must never be treated as a
    // placeholder, otherwise the auto-name would overwrite it on the
    // next turn.
    try s.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status) VALUES ('s_named', 'fix-login-bug', 'active')",
        &.{},
    );
    try testing.expect(!sessionNameIsPlaceholder(alloc, &s.db, "s_named"));

    // Missing row: the worker can run before the session row exists in
    // some paths; treat it as "needs a name" rather than skipping.
    try testing.expect(sessionNameIsPlaceholder(alloc, &s.db, "s_absent"));
}

test "isUsableGeneratedName: blank / whitespace names are rejected, real ones pass" {
    // These are the names that would otherwise reach `UPDATE sessions SET
    // name = ?` on a TEXT NOT NULL column and (per this repo's documented
    // db.exec behaviour) bind as SQL NULL, failing the write and leaving the
    for ([_][]const u8{ "", " ", "\n", "\t\r\n  ", "\n \t" }) |blank| {
        try testing.expect(!isUsableGeneratedName(blank));
    }
    for ([_][]const u8{ "fix-login-bug", " fix-login-bug ", "hai", "0" }) |real_name| {
        try testing.expect(isUsableGeneratedName(real_name));
    }
}

test "generateSessionNameNew: name call failure leaves the placeholder name and does not throw" {
    // The pre-fix bug: the name call's transport error was swallowed by a
    // bare `catch {}` that logged a constant, and the gate (`loop_counter ==
    // 1`) meant the failure was never retried — the session stayed "New Chat"
    const alloc = testing.allocator;
    var s = try setupDb();
    defer teardownDb(&s);

    const session_id = "s_name_call_fails";
    try s.db.exec(
        alloc,
        "INSERT INTO sessions (id, name, status) VALUES (?, 'New Chat', 'active')",
        &.{session_id},
    );
    try s.db.exec(
        alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, role, loop_index) " ++
            "VALUES ('h1', ?, 'stub-model', 'please fix the login bug', 'user', 0)",
        &.{session_id},
    );

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();
    var bus = event_bus_mod.EventBus.init("name-fail-test", alloc, std.testing.io);
    defer bus.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const messages = try getLLMHistories(*SqliteBackend, .{
        .allocator = a,
        .db = &s.db,
        .session_id = session_id,
    });

    // Port 1 is never listening — openStream fails fast.
    generateSessionNameNew(
        messages,
        a,
        "k",
        "m",
        "http://127.0.0.1:1/v1/chat/completions",
        "openai",
        "http",
        session_id,
        &lg,
        s.threaded.io(),
        &s.db,
        &bus,
    );

    // The gate the retry depends on: the name is STILL a placeholder, so
    // the next turn tries again.
    try testing.expect(sessionNameIsPlaceholder(alloc, &s.db, session_id));
}
