//! The headless backend boot sequence: everything the server boots, minus
//! the server.
//!
//! ## What is shared with `src/main.zig`
//!
//! `main.zig` boots, in order: SIGPIPE handling → CLI parse → TLS ctx →
//! `LlmConfig` → DB + migrations → panic/crash log paths → global logger →
//! the `App` singleton → MCP registries → event bus → routine scheduler →
//! active loops → **then** the HTTP server.
//!
//! `boot` runs that same prefix and stops before the server. Every phase
//! is the same call with the same arguments, so a headless process and a
//! server process are running identical code up to the point where one
//! binds a socket and the other does not.
//!
//! ## Why the server is skipped rather than started-and-ignored
//!
//! Binding a listener has three costs headless mode does not want: it can
//! fail (`BindFailed` when 8081 is taken), it needs a port picked for it,
//! and `GinwaServer.deinit` joins a cronjob thread whose teardown races
//! the Io worker threads — the exact race that made the old
//! `/test/shutdown` path segfault ~10s after exit. Not creating the
//! listener removes all three.
//!
//! ## The one thing that must be faked
//!
//! `App.server` is a `*gserverz.GinwaServer` with no optional. Three call
//! sites dereference it — `web_status`, `shutdown`, and
//! `unified_events_sse` — and all three are HTTP handlers headless mode
//! never reaches. Rather than widen the field to optional (which would
//! push a null check into every one of those handlers), headless mode
//! constructs a real `GinwaServer` WITHOUT binding it: `init` allocates
//! the struct, the router, the SSE manager and the cronjob manager, and
//! binds nothing. `deinit` then tears those down without a listener or a
//! cron thread ever having started.
//!
//! That is not a stub — it is the same object the server uses, in its
//! pre-listen state. The SSE manager's pipe and the cronjob registry are
//! real; nothing is listening, so nothing can connect.
//!
//! ## Why `boot` takes an out-param and does not return a value
//!
//! `App.db` and `App.event_bus` are pointers INTO the
//! `Backend` struct. Returning that struct by value would copy it to the
//! caller's address while those two pointers still aimed at `boot`'s
//! own frame — which dies on return. The first `db.query()` then reads
//! the reader pool out of reused stack memory and segfaults inside
//! `ArrayList.pop` (observed: SEGV at `array_list.zig` `pop`, fault
//! address 0x0, reached from `getSessionListWithCursor`).
//!
//! So the caller declares the `Backend` and passes it in; every internal
//! pointer aims at that stable storage from the moment it is published.
//! This is the same shape `main.zig` uses, where the equivalent locals
//! live in a `main` that never returns.
//!
//! ## Failure handling
//!
//! `boot` is all-or-nothing. Once the routine scheduler has been
//! submitted there is a live background task holding `*App`, so a later
//! failure cannot safely unwind — the process reports the error and exits
//! non-zero instead, which is what `main.zig` does for the same reason
//! (see the `cli_args.zig` header: an error return after
//! `LlmConfig.init` segfaults and buries the real message). Everything
//! BEFORE that point unwinds cleanly through `errdefer`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = @import("kabelweb").server;

const server_boot = @import("../boot/server_boot.zig");

/// Everything a headless run needs, in the order it must be torn down.
///
/// MUST be declared by the caller and passed to `boot` as an out-param —
/// see the module header for why returning it by value is a
/// use-after-free.
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

    /// Release everything `boot` acquired.
    ///
    /// ONLY safe when no background task is still running. `boot` submits
    /// the routine scheduler onto `ctx.group_emit_session_create`, and that
    /// task holds `*ctx` and `&db_handles.db` for the life of the process —
    /// freeing either while it sleeps between ticks is a use-after-free,
    /// which is exactly the segfault this used to produce.
    ///
    /// `main.zig` never unwinds for the same reason (see the `cli_args.zig`
    /// header: an error return after `LlmConfig.init` segfaults and buries
    /// the real message). Headless mode takes the same route — see
    /// `finish`, which is what the dispatcher calls.
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
        // segfaults inside `ArrayList.pop`. One call, not two.
        self.server.destroy(allocator);

        pabrikcore.mcp_http.HttpRegistry.deinitGlobal();
        pabrikcore.mcp_stdio.StdioRegistry.deinitGlobal();

        // `freeAllLlmConfigs` frees `llm_config_holder.current`, which IS
        // `llm_config_ptr` (boot installed it there). Destroying it again
        // here is a double free — DebugAllocator catches it and the process
        // aborts. One owner, one free.
        pabrikcore.freeAllLlmConfigs(self.ctx);
        allocator.destroy(self.ctx);

        pabrikcore.loggermod.deinitGlobal(io);
        allocator.free(self.log_file_path);

        self.db_handles.deinit(allocator);
    }

    /// End the process with `code`, without unwinding.
    ///
    /// The scheduler task is still parked in a 5-second sleep holding
    /// `*ctx`; tearing the context down under it is the use-after-free
    /// `deinit` documents. `exit` reaps everything instead — the same
    /// trade `main.zig` makes on its shutdown path, and for the same
    /// reason. WAL mode replays uncheckpointed frames on the next boot, so
    /// nothing committed is lost.
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
};

/// Boot the backend into caller-owned `out`.
///
/// Phases before the routine scheduler unwind cleanly on failure. From the
/// scheduler onward a failure is reported and the process exits non-zero,
/// because a live background task already holds `*App`.
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

    // ─── Config ───
    // Same call, same arguments as main.zig. An empty config only warns:
    // the run proceeds and fails at the LLM call with a message that names
    // the missing field, which is more useful than refusing to start.
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

    // ─── Database ───
    // Same open + migration chain as the server. A headless run therefore
    // sees the same schema, and a migration that breaks the server breaks
    // headless mode too — which is the point.
    var db_handles = server_boot.openDatabase(allocator, io, @constCast(environment)) catch |err| {
        std.log.err("headless: failed to open the database: {s}", .{@errorName(err)});
        return error.BootFailed;
    };
    errdefer db_handles.deinit(allocator);

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

    // ─── Publish the stable storage ───
    // Everything below takes the address of a field of `out`, so `out` must
    // hold its final values BEFORE any of those pointers are handed out.
    // The three pointer fields are filled in further down; `undefined` here
    // is a placeholder, never read.
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

    // Same one-shot seeding as the server boot. Headless has no auth
    // (see `ctx.auth_enabled = false` above), so it always takes the
    // file-mode path.
    server_boot.seedWorkspaceSettingsFromUserConfig(allocator, io, @constCast(environment), &db_handles.db, false);

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
    // `main.zig` installs this right after `registerAll`; without it,
    // `emit_run_agent`'s emit is a silent no-op — `EventBus.emit` on an id
    // with no subscriber does nothing at all, which is exactly the failure
    // mode its own tests document. The turn would be scheduled, the
    // session row written, and then nothing would run.
    //
    // Same call, same arguments as main.zig:219.
    try backend_event_bus.subscribe(
        pabrikcore.ai_mod.ai_workflow.RunParamsNew,
        "ai_worker_flow",
        pabrikcore.ai_mod.ai_workflow.CallbackAiWorkerFlow.callback,
    );

    // The routine scheduler: a concurrent Io task, no thread spawned.
    // Started for the same reason the server starts it — a workspace
    // routine that comes due during a headless run should fire. It
    // captures `dbSqlite`, which is `&out.db_handles.db` and therefore
    // stable for the caller's whole turn.
    //
    // From here on a failure cannot unwind: this task holds `*ctx`, and
    // freeing the context under it is a use-after-free. Report and exit.
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
