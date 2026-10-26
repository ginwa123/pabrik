//! The headless backend boot sequence: everything the server boots, minus the
//! server.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = @import("kabelweb").server;

const server_boot = @import("../boot/server_boot.zig");
const db_target = @import("../boot/db_target.zig");

/// Everything a headless run needs, in the order it must be torn down. MUST
/// be declared by the caller and passed to `boot` as an out-param — see the
/// module header for why returning it by value is a use-after-free.
pub const Backend = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    db_handles: server_boot.DatabaseHandles,
    llm_config: pabrikcore.config.LlmConfig,
    llm_config_ptr: *pabrikcore.config.LlmConfig,
    ctx: *pabrikcore.App,
    event_bus: pabrikcore.event_bus.EventBus,
    logger: *pabrikcore.loggermod.Logger,
    log_file_path: []u8,
    /// A real `GinwaServer` that never bound a socket. See the module header.
    server: *gserverz.GinwaServer,

    /// Release everything `boot` acquired. ONLY safe when no background task
    /// is still running.
    pub fn deinit(self: *Backend) void {
        const allocator = self.allocator;
        const io = self.io;

        // Cancel the scheduler's group FIRST and drain it, so nothing is
        // still holding `*ctx` when the context goes away.
        self.ctx.group_emit_session_create.cancel(io);
        self.ctx.group_emit_session_create.await(io) catch {};

        self.event_bus.deinit();

        // `destroy` calls `deinit` internally (http_server.zig:564), so
        // calling `deinit` first would run the whole teardown TWICE — the
        // second pass reads `cronjob_manager.jobs` out of freed memory and
        self.server.destroy(allocator);

        pabrikcore.mcp_http.HttpRegistry.deinitGlobal();
        pabrikcore.mcp_stdio.StdioRegistry.deinitGlobal();

        // `freeAllLlmConfigs` frees `llm_config_holder.current`, which IS
        // `llm_config_ptr` (boot installed it there).
        pabrikcore.freeAllLlmConfigs(self.ctx);
        allocator.destroy(self.ctx);

        pabrikcore.loggermod.deinitGlobal(io);
        allocator.free(self.log_file_path);

        self.db_handles.deinit();
    }

    /// End the process with `code`, without unwinding.
    pub fn finish(self: *Backend, code: u8) noreturn {
        _ = self;
        std.process.exit(code);
    }
};

pub const BootOptions = struct {
    /// Where diagnostics go. Null = `$TMPDIR/agentic_coding.log`, the same
    /// default `main.zig` uses, so a headless run's log lands where an
    /// operator already looks for one.
    log_file: ?[]const u8 = null,
    /// Which backend to open and where it lives. Empty = the compiled backend.
    db_request: db_target.Request = .{},
};

/// Boot the backend into caller-owned `out`. Phases before the routine
/// scheduler unwind cleanly on failure.
pub fn boot(
    out: *Backend,
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    opts: BootOptions,
) !void {
    // SIGPIPE: a peer vanishing mid-write must surface as a write error,
    // not a signal. Same call the server makes, for the same reason — the
    // LLM client writes to a socket that can go away.
    server_boot.ignoreSigpipe();

    // ─── Config ─── Same call, same arguments as main.zig.
    var llm_config = pabrikcore.config.LlmConfig.init(allocator, io, null, @constCast(environment)) catch |err| {
        std.log.err("headless: failed to load config: {s}", .{@errorName(err)});
        return error.BootFailed;
    };
    errdefer llm_config.deinit();
    if (llm_config.validate()) |_| {} else |err| {
        std.log.warn(
            "headless: config validation: {s}. The turn will fail until api_key/model/base_url are populated in ~/.config/pabrik/config.json.",
            .{@errorName(err)},
        );
    }

    const llm_config_ptr = try allocator.create(pabrikcore.config.LlmConfig);
    errdefer allocator.destroy(llm_config_ptr);
    llm_config_ptr.* = llm_config;

    // ─── Database ─── Same open + migration chain as the server. A headless
    // run therefore sees the same schema, and a migration that breaks the
    // server breaks headless mode too — which is the point.
    var db_handles = server_boot.openDatabase(allocator, io, @constCast(environment), opts.db_request, &.{}) catch |err| {
        std.log.err("headless: failed to open the database: {s}", .{@errorName(err)});
        return error.BootFailed;
    };
    errdefer db_handles.deinit();

    // ─── Log paths ───
    const log_file_path = if (opts.log_file) |p|
        try allocator.dupe(u8, p)
    else
        try std.fs.path.join(allocator, &.{ tmpPath(environment), "agentic_coding.log" });

    pabrikcore.setPanicLogPath(log_file_path);
    pabrikcore.crash_handler.setCrashLogPath(log_file_path);
    pabrikcore.crash_handler.installCrashHandlers();

    // File-only output: stdout is the machine-readable channel and must
    // stay clean. This is the one place headless mode deliberately differs
    // from main.zig, which logs to stdout because a human is watching.
    pabrikcore.loggermod.initGlobalColor(allocator, io, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    errdefer pabrikcore.loggermod.deinitGlobal(io);
    const global_logger_ptr = pabrikcore.loggermod.getGlobal().?;

    // ─── Publish the stable storage ─── Everything below takes the address
    // of a field of `out`, so `out` must hold its final values BEFORE any of
    // those pointers are handed out.
    out.* = .{
        .allocator = allocator,
        .io = io,
        .environment = environment,
        .db_handles = db_handles,
        .llm_config = llm_config,
        .llm_config_ptr = llm_config_ptr,
        .ctx = undefined,
        .event_bus = undefined,
        .logger = global_logger_ptr,
        .log_file_path = log_file_path,
        .server = undefined,
    };
    const dbSqlite = &out.db_handles.db;

    // ─── The App singleton ───
    const ctx = try allocator.create(pabrikcore.App);
    errdefer allocator.destroy(ctx);
    ctx.* = pabrikcore.App{
        .allocator = allocator,
        .io = io,
        .db = dbSqlite,
        .llm_config_holder = .{ .current = llm_config_ptr },
        .logger = global_logger_ptr,
        .environment = environment,
        .event_bus = undefined,
        .server = undefined,
        .group_emit_session_create = .init,
        .group_bg_watchers = .init,
    };
    out.ctx = ctx;

    // Headless mode has no auth: there is no request to carry a cookie,
    // so every row lands in the shared bucket — the same behaviour the
    // server has with `--auth` off.
    ctx.auth_enabled = false;

    try pabrikcore.setSingleton(ctx);

    // models.dev catalog, same as the server boot: a local DB read plus the
    // detached hourly sync. Without this the CLI runs with no catalog and every
    // model falls back to the built-in 200k window.
    server_boot.loadModelCatalog(allocator, &db_handles.db);

    ctx.mcp_stdio_registry = pabrikcore.mcp_stdio.StdioRegistry.global(allocator);
    ctx.mcp_http_registry = pabrikcore.mcp_http.HttpRegistry.global(allocator);

    // Both live in `out`, so the singleton points at storage that outlives
    // this function.
    out.event_bus = pabrikcore.event_bus.EventBus.init("my-bus", allocator, io);
    ctx.event_bus = &out.event_bus;
    const backend_event_bus = &out.event_bus;

    // The subscriber that turns a `RunParamsNew` emit into an actual turn.
    try backend_event_bus.subscribe(
        pabrikcore.ai_mod.ai_workflow.RunParamsNew,
        "ai_worker_flow",
        pabrikcore.ai_mod.ai_workflow.CallbackAiWorkerFlow.callback,
    );

    // The routine scheduler: a concurrent Io task, no thread spawned. Started
    // for the same reason the server starts it — a workspace routine that
    // comes due during a headless run should fire.
    pabrikcore.ai_mod.startup.start(allocator, dbSqlite, ctx, io) catch |err| {
        std.log.err("headless: failed to submit the routine scheduler: {s}", .{@errorName(err)});
        return error.BootFailed;
    };

    // A real server object that never bound. See the module header for why
    // this is not a stub.
    out.server = try gserverz.GinwaServer.init(allocator, io, undefined);
    ctx.server = out.server;
}

/// `$TMPDIR` → `$TEMP` → `$TMP` → `/tmp`, the same chain `main.zig` uses.
fn tmpPath(environment: *const std.process.Environ.Map) []const u8 {
    return environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
}

const testing = std.testing;

test "boot: tmpPath falls back through the documented chain" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("/tmp", tmpPath(&env));
    try env.put("TMP", "/tmp/t");
    try testing.expectEqualStrings("/tmp/t", tmpPath(&env));
    try env.put("TEMP", "/tmp/e");
    try testing.expectEqualStrings("/tmp/e", tmpPath(&env));
    try env.put("TMPDIR", "/tmp/d");
    try testing.expectEqualStrings("/tmp/d", tmpPath(&env));
}
