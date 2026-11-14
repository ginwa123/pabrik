//! `pabrik headless compaction <session_id>` — the `compaction` agent tool's
//! own path, no HTTP server and no port. The output reports the workspace
//! switch so a script can tell "refused by the setting" from "nothing to do".

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const compact_mod = @import("../modules/agent/loop/workflow_compact_message.zig");
const compact_target = @import("../modules/agent/loop/session_compact_target.zig");
const compaction_tool = @import("../modules/agent/tools/compaction.zig");
const tool_models = pabrikcore.tool_models;

pub const RunError = error{
    /// The session id names no row.
    UnknownSession,
    /// The session exists but its target could not be resolved.
    ResolveFailed,
    /// The compaction itself failed; the real name is logged, not printed.
    CompactionFailed,
    OutOfMemory,
};

/// One run's machine-readable result, plus the exit code the shell should see.
pub const Output = struct {
    json: []u8,
    exit_code: u8,
};

const Report = struct {
    session_id: []const u8,
    /// The workspace setting as this session resolves it.
    agent_auto_compaction: bool,
    /// Whether compaction was allowed to run at all.
    allowed: bool,
    /// `--force` was passed, so the setting was overridden.
    forced: bool,
    compacted: bool,
    message: []const u8,
};

pub fn run(allocator: std.mem.Allocator, di: *pabrikcore.App, a: args.CompactionArgs) RunError!Output {
    const llm_config = compact_target.sessionConfig(allocator, di, di.db, a.session_id);
    const enabled = compaction_tool.isEnabled(llm_config);

    const target = compact_target.resolve(allocator, llm_config, di.db, a.session_id) catch |err| switch (err) {
        error.UnknownSession => return error.UnknownSession,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ResolveFailed,
    };
    defer allocator.free(target.cwd);

    if (!enabled and !a.force) {
        return .{
            .json = try report(allocator, .{
                .session_id = a.session_id,
                .agent_auto_compaction = enabled,
                .allowed = false,
                .forced = false,
                .compacted = false,
                .message = compaction_tool.DISABLED_MESSAGE,
            }),
            .exit_code = 1,
        };
    }

    var no_tools: [0]tool_models.AgentTool = .{};
    const outcome = compact_target.compactSession(
        compact_mod.defaultCompactDeps,
        allocator,
        target,
        a.session_id,
        &no_tools,
        di.db,
        di.io,
        di.logger,
        di.event_bus,
    ) catch |err| {
        std.log.err("headless: compaction failed: {s}", .{@errorName(err)});
        return error.CompactionFailed;
    };

    return .{
        .json = try report(allocator, .{
            .session_id = a.session_id,
            .agent_auto_compaction = enabled,
            .allowed = true,
            .forced = !enabled and a.force,
            .compacted = outcome.compacted,
            .message = outcome.message,
        }),
        .exit_code = 0,
    };
}

fn report(allocator: std.mem.Allocator, r: Report) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, r, .{});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const database = pabrikcore.database;
const test_db = pabrikcore.test_db;
const migration = @import("../migrations/migration.zig");

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

fn seedSession(db: *database.Db, id: []const u8) !void {
    try db.exec(
        testing.allocator,
        "INSERT INTO sessions (id, name, status) VALUES (?, 's', 'active')",
        &[_][]const u8{id},
    );
}

test "resolve: an unknown session is an error, not a compaction of nothing" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const cfg = try testing.allocator.create(pabrikcore.config.LlmConfig);
    cfg.* = try pabrikcore.config.LlmConfig.initFromJsonText(testing.allocator, "{}");
    defer {
        cfg.deinit();
        testing.allocator.destroy(cfg);
    }

    try testing.expectError(
        error.UnknownSession,
        compact_target.resolve(testing.allocator, cfg, &ctx.db, "s_missing"),
    );

    // Positive control: the same call answers for a session that exists.
    try seedSession(&ctx.db, "s_real");
    const target = try compact_target.resolve(testing.allocator, cfg, &ctx.db, "s_real");
    defer testing.allocator.free(target.cwd);
    try testing.expectEqualStrings(".", target.cwd);
}
