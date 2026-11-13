//! Agent-callable tool: `compaction` — the agent compresses its OWN context
//! window through the same path the loop's threshold trigger and the manual
//! Compact button use; the workspace setting `agent_auto_compaction` gates it.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const agent = pabrikcore.agent;
const config_mod = pabrikcore.config;
const tool_models = pabrikcore.tool_models;
const tools = @import("../loop/tools.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const error_explain = @import("tools_error_explain.zig");
const wrap_mod = @import("tools_wrap_output.zig");
const wrapToolOutput = wrap_mod.wrapToolOutput;
const compact_mod = @import("../loop/workflow_compact_message.zig");
const compact_target = @import("../loop/session_compact_target.zig");

pub const NAME = "compaction";

/// What the agent is told when this workspace switched the tool off. Named the
/// setting so the next turn can ask the user for the one change that unblocks
/// it instead of guessing.
pub const DISABLED_MESSAGE =
    "Agent auto-compaction is off for this workspace: the `compaction` tool will not run. " ++
    "Ask the user to turn on `agent_auto_compaction` in Settings -> Runtime for this workspace, " ++
    "or to press Compact. The token-window threshold still compacts on its own.";

/// Whether the agent may compact itself. An absent on-disk key reads as
/// enabled, so the tool works for every config that never mentions it.
pub fn isEnabled(llm_config: *const config_mod.LlmConfig) bool {
    return llm_config.agent_auto_compaction;
}

pub const compaction_tool_system_prompt =
    \\## Compaction Tool — Behavior
    \\Use `compaction` when this session's context has grown long enough that
    \\earlier turns are crowding out the work: after a long search, once a task
    \\is finished and the next one starts, or when you notice yourself re-reading
    \\things you already know.
    \\- No parameters. It compacts THIS session.
    \\- It writes a handoff envelope (plan, user turns, read files, recent
    \\  activity) and marks every earlier message as not-for-LLM. The plan and
    \\  the envelope survive; the raw turns do not come back.
    \\- It is not free: the call costs one summary turn and the old detail is
    \\  gone. Compact at a boundary, never mid-edit with unsaved reasoning.
    \\- `{"compacted":false,...}` means there was too little since the last
    \\  handoff. That is not an error; keep working.
    \\- A workspace can switch this tool off (`agent_auto_compaction`). Then the
    \\  call is refused and the threshold trigger owns compaction.
    \\
;

pub const compaction_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = NAME,
        .description =
        \\Compress this session's context window through the same handoff path the
        \\threshold trigger and the user's Compact button use. Call it when the
        \\context has grown long and earlier turns are crowding out the current
        \\work.
        \\
        \\No parameters. Returns `{"compacted":true,"message":"..."}` when a
        \\handoff was written, or `{"compacted":false,"message":"..."}` when there
        \\was too little since the last one. Refused when this workspace has
        \\turned agent auto-compaction off.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = compaction_tool_system_prompt,
    },
};

/// Compact `ctx.session_id` exactly the way the loop does and report whether
/// anything was written. Caller owns the returned JSON slice.
pub fn executeCompaction(comptime deps: compact_mod.CompactDeps, ctx: ToolExecContext) ![]u8 {
    const target = compact_target.Target{
        .llm_config = ctx.config,
        .eff = ctx.config.resolveEffectiveAgent(ctx.selected_profile_model),
        .profile = ctx.config.resolveSessionAgentCompat(ctx.selected_profile_model),
        .cwd = ctx.cwd,
    };
    // The tool call already runs inside a session whose tool list the loop
    // resolved; re-resolving it here would need the process-wide App and buy
    // the envelope nothing, so it compacts with an empty tool list.
    var no_tools: [0]tool_models.AgentTool = .{};
    const outcome = try compact_target.compactSession(
        deps,
        ctx.allocator,
        target,
        ctx.session_id,
        &no_tools,
        ctx.db,
        ctx.io,
        ctx.logger,
        ctx.event_bus,
    );
    return std.json.Stringify.valueAlloc(ctx.allocator, .{
        .compacted = outcome.compacted,
        .message = outcome.message,
    }, .{});
}

/// The gate + the work, with the compaction dependencies open for injection so
/// a test can prove the refusal happens BEFORE anything is written.
pub fn execCompactionWith(
    comptime deps: compact_mod.CompactDeps,
    ctx: ToolExecContext,
    tc: agent.ToolCall,
) !ToolExecResult {
    if (!isEnabled(ctx.config)) {
        const output = try wrapToolOutput(ctx.allocator, NAME, tc.function.arguments, false, DISABLED_MESSAGE, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const inner = executeCompaction(deps, ctx) catch |err| {
        const err_msg = try error_explain.explain(ctx.allocator, err, null);
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, NAME, tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// Registry entry: the production dependencies.
pub fn execCompaction(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    return execCompactionWith(compact_mod.defaultCompactDeps, ctx, tc);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const database = pabrikcore.database;
const test_db = pabrikcore.test_db;
const migration = @import("../../../migrations/migration.zig");

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

/// A real `LlmConfig` from JSON text — the same parse the workflow does, so the
/// gate is tested against the value production actually holds.
fn makeConfig(allocator: std.mem.Allocator, body: []const u8) !*config_mod.LlmConfig {
    const cfg = try allocator.create(config_mod.LlmConfig);
    cfg.* = try config_mod.LlmConfig.initFromJsonText(allocator, body);
    return cfg;
}

fn makeLogger(allocator: std.mem.Allocator) !*pabrikcore.loggermod.Logger {
    const logger = try allocator.create(pabrikcore.loggermod.Logger);
    logger.* = pabrikcore.loggermod.Logger.init(allocator, std.testing.io, .{});
    return logger;
}

fn makeCtx(
    allocator: std.mem.Allocator,
    ctx: *TestCtx,
    logger: *pabrikcore.loggermod.Logger,
    cfg: *const config_mod.LlmConfig,
    session_id: []const u8,
) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = logger,
        .session_id = session_id,
        .model = cfg.model,
        .cwd = "/tmp",
        .api_key = cfg.api_key,
        .base_url = cfg.base_url,
        .config = cfg,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
    };
}

fn fakeToolCall(name: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = "{}" },
    };
}

fn seedSession(db: *database.Db, session_id: []const u8, workspace_id: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name, status, workspace_id) VALUES (?, 's', 'active', ?)",
        &[_][]const u8{ session_id, workspace_id },
    );
}

/// `turns` user/assistant pairs the compaction path can count. Each row is fed
/// to the LLM, which is what `getLLMHistories` selects on.
fn seedHistory(db: *database.Db, session_id: []const u8, turns: usize) !void {
    var content_buf: [64]u8 = undefined;
    var id_buf: [128]u8 = undefined;
    for (0..turns) |i| {
        const role: []const u8 = if (i % 2 == 0) "user" else "assistant";
        const content = try std.fmt.bufPrint(&content_buf, "turn {d}: working on the task", .{i});
        const id = try std.fmt.bufPrint(&id_buf, "h_{s}_{d}", .{ session_id, i });
        try db.exec(
            testing.allocator,
            "INSERT INTO llm_history (id, session_id, model, role, response_content, is_feed_to_llm) " ++
                "VALUES (?, ?, 'test-model', ?, ?, 1)",
            &[_][]const u8{ id, session_id, role, content },
        );
    }
}

/// How many rows still feed the LLM: the number `markHistoryNotForLLMRun`
/// moves to 0 and the envelope row is added to.
fn countFed(db: *database.Db, session_id: []const u8) !u64 {
    var q = try db.query(
        testing.allocator,
        "SELECT COUNT(*) FROM llm_history WHERE session_id = ? AND is_feed_to_llm = 1",
        &[_][]const u8{session_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(u64, row.values[0], 10) catch error.NotANumber;
}

/// A compaction dependency set that CANNOT reach a model, and records that it
/// was asked. Used to prove the refusal happens before any cost is paid.
const Spy = struct {
    var should_compact_calls: usize = 0;
};

fn spyShouldCompact(ctx: compact_mod.ThresholdCtx) bool {
    _ = ctx;
    Spy.should_compact_calls += 1;
    return true;
}

fn spyCallCompactAgent(obj: compact_mod.CallCompactAgentInput) ?[]const u8 {
    _ = obj;
    return null;
}

fn spyCompactInMemory(
    allocator: std.mem.Allocator,
    messages: std.ArrayList(agent.AgentMessage),
    envelope: []const u8,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    db: *database.Db,
    io: std.Io,
    logger: *pabrikcore.loggermod.Logger,
    event_bus: ?*pabrikcore.event_bus.EventBus,
) anyerror!std.ArrayList(agent.AgentMessage) {
    return compact_mod.compactMessageInMemoryNew(
        allocator,
        messages,
        envelope,
        session_id,
        model,
        cwd,
        db,
        io,
        logger,
        event_bus,
    );
}

const spyDeps: compact_mod.CompactDeps = .{
    .shouldCompact = spyShouldCompact,
    .callCompactAgent = spyCallCompactAgent,
    .compactMessagesInMemory = spyCompactInMemory,
};

test "gate: a config that never mentions agent_auto_compaction keeps the tool enabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try makeConfig(arena.allocator(), "{\"profiles_models\":{}}");
    try testing.expect(isEnabled(cfg));
}

test "gate: agent_auto_compaction false in the config disables the tool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try makeConfig(arena.allocator(), "{\"agent_auto_compaction\":false}");
    try testing.expect(!isEnabled(cfg));

    // Positive control: the same parse DOES read true, so the assertion above
    // is the flag and not a value that is always false.
    const on = try makeConfig(arena.allocator(), "{\"agent_auto_compaction\":true}");
    try testing.expect(isEnabled(on));
}

test "execCompaction: a disabled workspace compacts nothing and names the setting" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const logger = try makeLogger(alloc);
    defer alloc.destroy(logger);

    const session_id = "sess_disabled";
    try seedSession(&ctx.db, session_id, "");
    try seedHistory(&ctx.db, session_id, 8);
    const fed_before = try countFed(&ctx.db, session_id);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const cfg = try makeConfig(arena.allocator(), "{\"agent_auto_compaction\":false}");

    Spy.should_compact_calls = 0;
    const tcx = makeCtx(alloc, &ctx, logger, cfg, session_id);
    const result = try execCompactionWith(spyDeps, tcx, fakeToolCall(NAME));
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expectEqualStrings(NAME, env.value.object.get("tool").?.string);
    try testing.expect(!env.value.object.get("success").?.bool);
    const err_text = env.value.object.get("error").?.string;
    try testing.expect(std.mem.indexOf(u8, err_text, "agent_auto_compaction") != null);

    // The observable outcome, not a call count: the history is untouched.
    try testing.expectEqual(fed_before, try countFed(&ctx.db, session_id));
    try testing.expectEqual(@as(usize, 0), Spy.should_compact_calls);
}

test "execCompaction: an enabled workspace writes the handoff and reports it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const logger = try makeLogger(alloc);
    defer alloc.destroy(logger);

    const session_id = "sess_enabled";
    try seedSession(&ctx.db, session_id, "");
    try seedHistory(&ctx.db, session_id, 8);
    const fed_before = try countFed(&ctx.db, session_id);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // `compaction_llm_summary` stays false, which is what keeps the real path
    // off the network: the envelope is deterministic.
    const cfg = try makeConfig(arena.allocator(), "{\"profiles_models\":{}}");
    try testing.expect(isEnabled(cfg));

    const tcx = makeCtx(alloc, &ctx, logger, cfg, session_id);
    const result = try execCompactionWith(compact_mod.defaultCompactDeps, tcx, fakeToolCall(NAME));
    defer if (result.output_allocated) alloc.free(result.output);

    const env = try std.json.parseFromSlice(std.json.Value, alloc, result.output, .{});
    defer env.deinit();
    try testing.expectEqualStrings(NAME, env.value.object.get("tool").?.string);
    try testing.expect(env.value.object.get("success").?.bool);
    try testing.expect(env.value.object.get("data").?.object.get("compacted").?.bool);

    // The history really moved: every old row stopped feeding the LLM and one
    // handoff row took their place.
    const fed_after = try countFed(&ctx.db, session_id);
    try testing.expectEqual(@as(u64, 1), fed_after);
    try testing.expect(fed_before > fed_after);
}
