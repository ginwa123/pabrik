//! What one compaction call runs against. The agentic loop and the manual
//! `/compact` endpoint resolve their LLM target, profile and cwd here, so a
//! manual compact cannot pick a different model than the next loop turn would.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const agent = pabrikcore.agent;
const database = pabrikcore.database;
const event_bus_mod = pabrikcore.event_bus;
const Logger = pabrikcore.loggermod.Logger;
const tool_models = pabrikcore.tool_models;
const config_mod = @import("../modules/config/Config.zig");
const buildMessages = @import("prompts_build_messages_for_agent_prompt.zig").buildMessages;
const get_llm_histories_mod = @import("get_llm_histories.zig");
const session_llm_config = @import("session_llm_config.zig");
const compact_mod = @import("workflow_compact_message.zig");

const LlmConfig = config_mod.LlmConfig;

pub const Target = struct {
    llm_config: *const LlmConfig,
    eff: LlmConfig.EffectiveAgent,
    profile: ?LlmConfig.LlmAgent,
    cwd: []const u8,
};

pub const Outcome = struct {
    compacted: bool,
    message: []const u8,
};

/// The `LlmConfig` in force for a session: the owner's stored config under
/// `--auth`, the process-global singleton otherwise.
pub fn sessionConfig(
    allocator: std.mem.Allocator,
    app: *pabrikcore.App,
    db: *database.Db,
    session_id: []const u8,
) *LlmConfig {
    return session_llm_config.forSession(allocator, db, session_id) orelse pabrikcore.getLlmConfig(app);
}

/// The cascades the loop re-resolves every iteration, read from the session
/// row: `selected_profile_model` walks to the effective model/key/base_url/
/// url_style, and the same name resolves the profile the threshold reads.
pub fn resolve(
    allocator: std.mem.Allocator,
    llm_config: *const LlmConfig,
    db: *database.Db,
    session_id: []const u8,
) !Target {
    var q = try db.query(
        allocator,
        "SELECT COALESCE(CAST(selected_profile_model AS TEXT), ''), COALESCE(CAST(cwd AS TEXT), '') FROM sessions WHERE id = ?",
        &[_][]const u8{session_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.UnknownSession;
    defer row.deinit(allocator);
    if (row.values.len < 2) return error.UnknownSession;

    return .{
        .llm_config = llm_config,
        .eff = llm_config.resolveEffectiveAgent(row.values[0]),
        .profile = llm_config.resolveSessionAgentCompat(row.values[0]),
        .cwd = try allocator.dupe(u8, if (row.values[1].len > 0) row.values[1] else "."),
    };
}

/// The compaction trigger's token input: the largest `total_tokens` across the
/// rows that feed the model.
pub fn totalTokens(rows: anytype) u32 {
    var max: u32 = 0;
    for (rows) |row| {
        if (row.total_tokens > max) max = row.total_tokens;
    }
    return max;
}

/// Compact `session_id` exactly the way the loop's call site does, and report
/// whether anything was actually written.
pub fn compactSession(
    comptime deps: compact_mod.CompactDeps,
    allocator: std.mem.Allocator,
    target: Target,
    session_id: []const u8,
    tools: []tool_models.AgentTool,
    db: *database.Db,
    io: std.Io,
    logger: *Logger,
    event_bus: ?*event_bus_mod.EventBus,
) !Outcome {
    var resolved = target;
    const db_messages = try get_llm_histories_mod.getLLMHistories(*database.Db, .{
        .allocator = allocator,
        .db = db,
        .session_id = session_id,
    });

    var messages: std.ArrayList(agent.AgentMessage) = .empty;
    try messages.appendSlice(
        allocator,
        try buildMessages(allocator, io, db, resolved.cwd, session_id, "", db_messages, tools, "", ""),
    );

    const compacted = try compact_mod.maybeCompactMessagesNew(
        deps,
        allocator,
        totalTokens(db_messages),
        resolved.eff.model,
        true,
        &messages,
        resolved.eff.api_key,
        resolved.eff.base_url,
        resolved.eff.url_style,
        resolved.cwd,
        session_id,
        db,
        io,
        logger,
        event_bus,
        resolved.llm_config,
        if (resolved.profile) |*p| p else null,
    );
    if (compacted) return .{ .compacted = true, .message = "Compaction completed" };

    const since_last = compact_mod.messagesSinceLastCompaction(messages.items);
    return .{
        .compacted = false,
        .message = if (since_last < compact_mod.MIN_MESSAGES_TO_COMPACT)
            "Nothing to compact: too few messages since the last handoff"
        else
            "Nothing to compact",
    };
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const migration = @import("../migrations/migration.zig");
const test_db = pabrikcore.test_db;

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

fn seedSession(db: *database.Db, id: []const u8, selected_profile_model: []const u8, cwd: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name, status, selected_profile_model, cwd) VALUES (?, 's', 'active', ?, ?)",
        &[_][]const u8{ id, selected_profile_model, cwd },
    );
}

/// Top-level `gpt-4o` on the OpenAI wire, plus one Anthropic-profile the
/// session can select. A compaction sent with the top-level fields would go to
/// the wrong host with the wrong key and the wrong wire format.
fn twoTargetConfig(allocator: std.mem.Allocator) !*LlmConfig {
    const body =
        "{\"model\":\"gpt-4o\",\"base_url\":\"https://top.example/v1\",\"api_key\":\"sk-top\"," ++
        "\"url_style\":\"openai\",\"active_profile\":\"\",\"profiles_models\":{\"deep\":{" ++
        "\"model\":\"claude-opus-4\",\"base_url\":\"https://api.anthropic.com\",\"api_key\":\"sk-ant\"," ++
        "\"url_style\":\"anthropic\"}}}";
    const cfg = try allocator.create(LlmConfig);
    cfg.* = try LlmConfig.initFromJsonText(allocator, body);
    return cfg;
}

test "manual compact targets the selected session profile not the top-level config" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try seedSession(&ctx.db, "s_deep", "deep", "/work/project");
    const cfg = try twoTargetConfig(alloc);

    const target = try resolve(alloc, cfg, &ctx.db, "s_deep");

    try testing.expectEqualStrings("claude-opus-4", target.eff.model);
    try testing.expectEqualStrings("sk-ant", target.eff.api_key);
    try testing.expectEqualStrings("https://api.anthropic.com", target.eff.base_url);
    try testing.expectEqualStrings("anthropic", target.eff.url_style);
    try testing.expectEqualStrings("claude-opus-4", target.profile.?.model);
    try testing.expectEqualStrings("/work/project", target.cwd);
    try testing.expect(target.llm_config == cfg);

    // Positive control: the top-level fields this used to send are different,
    // so the assertions above can actually fail.
    try testing.expectEqualStrings("gpt-4o", cfg.model);
    try testing.expectEqualStrings("sk-top", cfg.api_key);
}

test "no selected profile falls back to the active profile target" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try seedSession(&ctx.db, "s_plain", "", "");
    const cfg = try twoTargetConfig(alloc);
    cfg.active_agent = try alloc.dupe(u8, "deep");

    const target = try resolve(alloc, cfg, &ctx.db, "s_plain");

    try testing.expectEqualStrings("claude-opus-4", target.eff.model);
    try testing.expectEqualStrings("anthropic", target.profile.?.url_style);
    // An empty cwd column still yields a usable working directory.
    try testing.expectEqualStrings(".", target.cwd);
}

test "resolving an unknown session is an error not a compaction of nothing" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg = try twoTargetConfig(alloc);
    try testing.expectError(error.UnknownSession, resolve(alloc, cfg, &ctx.db, "s_missing"));
}

test "totalTokens is the largest fed row and zero for an empty history" {
    const Row = struct { total_tokens: u32 };
    try testing.expectEqual(@as(u32, 0), totalTokens(&[_]Row{}));
    try testing.expectEqual(@as(u32, 10), totalTokens(&[_]Row{.{ .total_tokens = 10 }}));
    try testing.expectEqual(
        @as(u32, 900),
        totalTokens(&[_]Row{ .{ .total_tokens = 10 }, .{ .total_tokens = 900 }, .{ .total_tokens = 42 } }),
    );
}
