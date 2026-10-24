const std = @import("std");

const pabrikcore = @import("pabrikcore");

// Puts pabrik's crash reporter at the FRONT of the Windows exception chain
// (std's vectored handler would otherwise swallow access violations).
// See `crash_handler.root_debug` for the full ordering argument.
pub const debug = pabrikcore.crash_handler.root_debug;

const ai_mod = pabrikcore.ai_mod;
const helpers = @import("helpers");
const gserverz = pabrikcore.gserverz;
const http_routes = pabrikcore.http_routes;
const static_files = pabrikcore.static_files;
// Re-exported via pabrikcore so the exe module never @imports the file
// directly (dual-module error — see root.zig).
const cleanup_stale_worker = pabrikcore.cleanup_stale_worker;
const cleanup_stale_background_process = pabrikcore.cleanup_stale_background_process;
const background_process = pabrikcore.ai_mod.background_process;

// Boot phases (extracted from this file): the exe module reaches them via
// pabrikcore.* for the same dual-module reason as above.
const shutdown = pabrikcore.boot_shutdown;
const cli_dispatch = pabrikcore.boot_cli_dispatch;
const headless_dispatch = pabrikcore.boot_headless_dispatch;
const server_boot = pabrikcore.boot_server_boot;
// The DB policy and its `--db-*` overrides, plus the reader-pool reaper that
// keeps the elastic pool from holding a burst's readers forever.
const db_config = pabrikcore.boot_db_config;
const static_serve = pabrikcore.http_static_serve;
const vmd_lifecycle = pabrikcore.vmd_lifecycle;

/// The manager this server started goes down with it: SIGTERM first, so it
/// stops the VMs it owns, then SIGKILL for a manager that will not go.
fn stopManager() void {
    const pid = vmd_lifecycle.spawnedPid() orelse return;
    std.log.info("stopping the VM manager (pid {d})", .{pid});
    switch (vmd_lifecycle.stopSpawned(vmd_lifecycle.default_stop_timeout_ms)) {
        .stopped => std.log.info("VM manager stopped", .{}),
        .killed => std.log.warn("the VM manager ignored SIGTERM; it was killed", .{}),
        .survived => std.log.err("the VM manager is still running", .{}),
        .nothing_to_stop => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const environment = init.environ_map;
    const io = init.io;

    if (try cli_dispatch.dispatchServiceSubcommand(allocator, io, environment, init)) return;
    if (try cli_dispatch.dispatchCreateAdmin(allocator, io, environment, init)) return;
    // Headless mode boots the whole backend and runs a turn WITHOUT binding a
    // port.
    if (try headless_dispatch.dispatchHeadless(allocator, io, environment, init)) return;

    server_boot.ignoreSigpipe();

    // Flatten argv for the parser (it dupes what it keeps: the iterator's
    // buffers are freed on Windows).
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    var argv_flat: std.ArrayList([]const u8) = .empty;
    defer argv_flat.deinit(allocator);
    while (args_iter.next()) |arg| try argv_flat.append(allocator, arg);

    // `var` because --tls-selfsigned overwrites the parsed cert/key paths.
    var cli = (try server_boot.parseCliArgs(allocator, argv_flat.items)) orelse return;
    // Before TLS and the config thread: a refused mode must exit cleanly.
    const boot_mode = server_boot.enforceRuntimeMode(allocator, io, environment, &cli) orelse std.process.exit(2);
    std.log.info("runtime mode: {s}", .{@tagName(boot_mode)});
    const tls_ctx = try server_boot.setupTlsCtx(allocator, environment, &cli);

    if (init.environ_map.get("HOME")) |home| {
        std.log.info("HOME={s}", .{home});
    }

    var llm_config = pabrikcore.config.LlmConfig.init(allocator, io, null, environment) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    // Heap-moved for the holder swap below; freed via `freeAllLlmConfigs` at
    // shutdown, so no defer here.
    if (llm_config.validate()) |_| {} else |err| {
        std.log.warn(
            "Config validation: {s}. LLM calls will fail until api_key/model/base_url are populated in ~/.config/pabrik/config.json.",
            .{@errorName(err)},
        );
    }

    const initial_llm_config_ptr = try allocator.create(pabrikcore.config.LlmConfig);
    errdefer allocator.destroy(initial_llm_config_ptr);
    initial_llm_config_ptr.* = llm_config;

    // `--db-*` flags retune the connection policy (page cache, reader pool,
    // mmap window). Parsed here rather than inside `cli_args` because they
    // belong to the DB module that owns the defaults, and a bad one must be

    // reported before the database is opened.
    var db_overrides: std.ArrayList(db_config.Override) = .empty;
    defer db_overrides.deinit(allocator);
    if (db_config.parseOverrides(allocator, argv_flat.items, &db_overrides)) |_| {} else |err| {
        // Name the offending flag: `parseOverrides` stops at the first bad
        // one, so the last `--db-*` in argv is the one that failed.
        for (argv_flat.items) |arg| {
            if (std.mem.startsWith(u8, arg, "--db-") or std.mem.startsWith(u8, arg, "--db_")) {
                db_config.reportOverrideError(arg, err);
            }
        }
        return error.InvalidArgs;
    }

    var db_handles = try server_boot.openDatabase(allocator, io, environment, db_overrides.items);
    defer db_handles.deinit(allocator);
    const dbSqlite = &db_handles.db;

    const tmp_path = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(allocator, &.{ tmp_path, "agentic_coding.log" });
    defer allocator.free(log_file_path);

    pabrikcore.setPanicLogPath(log_file_path);
    // Crash handlers go in BEFORE the HTTP server starts, sharing the panic
    // log path (see src/service/crash_handler.zig for the contract).
    pabrikcore.crash_handler.setCrashLogPath(log_file_path);
    pabrikcore.crash_handler.installCrashHandlers();

    pabrikcore.loggermod.initGlobalColor(allocator, io, .{
        .min_level = .debug,
        .output_mode = .stdout,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer pabrikcore.loggermod.deinitGlobal(io);

    const global_logger_ptr = pabrikcore.loggermod.getGlobal().?;

    const ctxParent = try allocator.create(pabrikcore.App);
    defer allocator.destroy(ctxParent);
    ctxParent.* = pabrikcore.App{
        .allocator = allocator,
        .io = io,
        .db = dbSqlite,
        .llm_config_holder = .{ .current = initial_llm_config_ptr },
        .logger = global_logger_ptr,
        .environment = environment,
        .event_bus = undefined, // set below after initialization
        .server = undefined, // set below after initialization
        .group_emit_session_create = .init,
        .group_bg_watchers = .init,
    };

    // `--no-static-dir` wins over `--static-dir` regardless of order.
    if (cli.no_static_dir) {
        if (cli.static_dir) |dir_arg| allocator.free(dir_arg);
        std.log.info("--no-static-dir: API only, no static files at /.", .{});
    } else if (cli.static_dir) |dir_arg| ctxParent.static_dir_path = dir_arg;
    // Installer layouts ship html/ beside the install root (install.sh
    // extracts it next to the binaries, mirroring zig-out/bin/html; Windows
    // keeps %LOCALAPPDATA%\pabrik\html): serve it without requiring
    if (ctxParent.static_dir_path == null) {
        var candidates: std.ArrayList([]const u8) = .empty;
        defer {
            for (candidates.items) |c| allocator.free(c);
            candidates.deinit(allocator);
        }
        const addCandidate = struct {
            fn run(
                list: *std.ArrayList([]const u8),
                alloc: std.mem.Allocator,
                parts: []const []const u8,
            ) void {
                const dir = std.fs.path.join(alloc, parts) catch return;
                list.append(alloc, dir) catch alloc.free(dir);
            }
        }.run;
        // Next-to-executable probe.
        var exe_dir: ?[]u8 = null;
        defer if (exe_dir) |d| allocator.free(d);
        if (std.process.executablePathAlloc(io, allocator)) |exe_path| {
            defer allocator.free(exe_path);
            if (std.fs.path.dirname(exe_path)) |d| {
                exe_dir = allocator.dupe(u8, d) catch null;
            }
        } else |_| {}
        if (exe_dir == null and argv_flat.items.len > 0) {
            const argv0 = argv_flat.items[0];
            if (std.mem.indexOfAny(u8, argv0, "/\\") != null) {
                if (std.fs.path.dirname(argv0)) |d| exe_dir = allocator.dupe(u8, d) catch null;
            }
        }
        if (exe_dir) |d| {
            addCandidate(&candidates, allocator, &.{ d, "html" });
        }
        if (@import("builtin").os.tag == .windows) {
            if (environment.get("LOCALAPPDATA")) |appdata| {
                addCandidate(&candidates, allocator, &.{ appdata, "pabrik", "html" });
            }
        } else {
            if (environment.get("XDG_DATA_HOME")) |xdg| {
                addCandidate(&candidates, allocator, &.{ xdg, "pabrik", "html" });
            } else if (environment.get("HOME")) |home| {
                addCandidate(&candidates, allocator, &.{ home, ".local", "share", "pabrik", "html" });
            }
            // System installs (--system): absolute from the start.
            addCandidate(&candidates, allocator, &.{ "/", "usr", "local", "share", "pabrik", "html" });
            addCandidate(&candidates, allocator, &.{ "/", "usr", "share", "pabrik", "html" });
        }
        if (server_boot.findBundledWebapp(io, allocator, candidates.items)) |dir| {
            ctxParent.static_dir_path = dir;
            std.log.info("serving installed webapp from {s}", .{dir});
        }
    }
    ctxParent.auth_enabled = cli.auth_enabled;
    if (cli.auth_enabled) {
        std.log.info("--auth on: per-user LLM config comes from users.config_json; config.json is ignored.", .{});
    }

    _ = try pabrikcore.setSingleton(ctxParent);

    // Copy the user-level config into every workspace that has not decided
    // yet, so existing workspaces open with the sections that moved to
    // Workspace settings already populated. Idempotent + best-effort.
    server_boot.seedWorkspaceSettingsFromUserConfig(allocator, io, environment, dbSqlite, cli.auth_enabled);

    // `mode="background_persistence"` services die with the pabrik that owns
    // them.
    if (background_process.sweepServicesOnBoot(dbSqlite, io, allocator)) |sweep| {
        if (sweep.killed > 0 or sweep.marked_orphaned > 0) {
            std.log.info(
                "background services: swept {d} row(s) from a previous run, killed {d}",
                .{ sweep.marked_orphaned, sweep.killed },
            );
        }
    } else |err| {
        std.log.warn("background service boot sweep failed: {s}", .{@errorName(err)});
    }

    // models.dev model catalog: read the cached snapshot from the DB (local,
    // no network) and kick the detached hourly sync. This is what makes a
    // non-MiniMax model resolve to its real context window instead of 200k.
    server_boot.loadModelCatalog(allocator, dbSqlite);

    // Eager globals: call sites go through the singleton instead of
    // lazy-init on first MCP use; the defers free the arenas at shutdown.
    ctxParent.mcp_stdio_registry = pabrikcore.mcp_stdio.StdioRegistry.global(allocator);
    ctxParent.mcp_http_registry = pabrikcore.mcp_http.HttpRegistry.global(allocator);
    defer pabrikcore.mcp_stdio.StdioRegistry.deinitGlobal();
    defer pabrikcore.mcp_http.HttpRegistry.deinitGlobal();

    const event_bus_mod = pabrikcore.event_bus;
    var event_bus = event_bus_mod.EventBus.init("my-bus", allocator, io);
    defer event_bus.deinit();
    ctxParent.event_bus = &event_bus;

    // Routine scheduler: a concurrent Io task (no thread spawned), after
    // setSingleton + event bus so its fire path can emit events.
    ai_mod.startup.start(allocator, dbSqlite, ctxParent, io) catch |err| {
        std.log.err("Failed to submit routine scheduler: {s}", .{@errorName(err)});
    };

    // Explicit --port wins; otherwise web_launch_enabled decides.
    var port: u16 = server_boot.resolvePort(cli.port, llm_config.web_launch_enabled);
    if (port == 0) {
        port = pabrikcore.web_port.pickFreePort(io) catch |err| {
            std.log.err("web launch: no free port in [{d},{d}]: {s}", .{
                pabrikcore.web_port.web_port_range_start,
                pabrikcore.web_port.web_port_range_end,
                @errorName(err),
            });
            return err;
        };
        std.log.info("web launch: browser mode on http://127.0.0.1:{d}/", .{port});
    }

    const address = blk: {
        const first = gserverz.Address.init("127.0.0.1", port) catch |err| switch (err) {
            error.BindFailed => {
                // An explicit --port is operator intent: fail loud so a
                // typo'd flag never silently serves somewhere unexpected.
                if (cli.port != null) {
                    std.log.err("cannot bind 127.0.0.1:{d} - address already in use (is another pabrik already running on this port?)", .{port});
                    std.process.exit(1);
                }
                // Default-port convenience, on every platform: the user asked
                // for no port in particular (usually the 8081 default), so a
                // taken port picks a free one instead of dying.
                std.log.warn("port {d} is already in use - picking a free port instead", .{port});
                port = pabrikcore.web_port.pickFreePort(io) catch |pick_err| {
                    std.log.err("no free port available: {s}", .{@errorName(pick_err)});
                    return pick_err;
                };
                break :blk try gserverz.Address.init("127.0.0.1", port);
            },
            else => return err,
        };
        break :blk first;
    };
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();
    gs.enable_h2c = cli.enable_h2c;

    // The engine's cross-site pre-gate is a TENANT defence: on in --saas only.
    // The local UI is served from the Vite dev origin, so enabling it for local
    // mode would 403 every mutation the app makes.
    const allowed_origins = try ai_mod.http_handlers.preview_origin.allowedFor(allocator, environment, address.port);
    // `allow_same_origin`: the app's own origin passes the gate, so a
    // deployment behind a proxy serves its public origin with no allowlist.
    gs.cors = .{
        .enabled = boot_mode == .saas,
        .allowed_origins = allowed_origins,
        .allow_same_origin = true,
    };

    // SIGINT/SIGTERM close the listener via shutdown(), unblocking listen()
    // so the post-listen block below runs. Second signal force-exits (130).
    shutdown.setServer(gs);
    shutdown.reset();
    pabrikcore.signal_handlers.installShutdownHandlers(shutdown.handleShutdownSignal);

    if (tls_ctx) |ctx| gs.setTlsCtx(ctx);
    if (cli.enable_h2c) std.debug.print("HTTP/2 (h2c) enabled on this port (HTTP/1.1 clients unaffected)\n", .{});

    var static_dir_cfg: ?*static_files.StaticDirConfig = null;
    defer if (static_dir_cfg) |cfg| server_boot.freeStaticDir(allocator, cfg);

    if (ctxParent.static_dir_path) |dir| {
        const cfg = try server_boot.setupStaticDir(allocator, io, dir);
        static_dir_cfg = cfg;
        gs.setStaticDirHandler(static_serve.staticDirHandler, @ptrCast(cfg));
    }

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(
        io,
        struct {
            fn run(gss: *gserverz.GinwaServer) void {
                gss.sse_manager.startEventLoop(5) catch {};
            }
        }.run,
        .{gs},
    );

    ctxParent.server = gs;
    try http_routes.registerAll(gs);

    _ = try event_bus.subscribe(ai_mod.ai_workflow.RunParamsNew, "ai_worker_flow", ai_mod.ai_workflow.CallbackAiWorkerFlow.callback);
    ctxParent.server.sse_manager.on_disconnect = ai_mod.handleClientDisconnect;

    std.debug.print("Agent is ready to serve!\n", .{});
    // The browser URL, on every boot path — not just web-launch mode.
    std.debug.print("Open in your browser: http://127.0.0.1:{d}/\n", .{port});
    if (ctxParent.static_dir_path != null) {
        std.debug.print("App: http://127.0.0.1:{d}/app\n", .{port});
    } else {
        std.debug.print("Health check: http://127.0.0.1:{d}/health\n", .{port});
    }

    const boot_unix = std.Io.Clock.now(.real, io).toSeconds();
    _ = gs.cronjob_manager.register(
        "* * * * *",
        "cleanup_stale_worker",
        cleanup_stale_worker.handle,
        null,
        boot_unix,
    ) catch |err| {
        std.debug.print("Failed to register heartbeat cron: {s}\n", .{@errorName(err)});
    };
    _ = gs.cronjob_manager.register(
        "* * * * *",
        "cleanup_stale_background_process",
        cleanup_stale_background_process.handle,
        null,
        boot_unix,
    ) catch |err| {
        std.debug.print("Failed to register cleanup_stale_background_process cron: {s}\n", .{@errorName(err)});
    };
    try gs.listenEventLoop(.{ .dispatch_mode = .worker_pool });

    // The manager is this server's child, so it goes down with the server.
    stopManager();

    // Post-listen shutdown. The signal path only sets the flag (handlers
    // can't log), so logging happens here.
    if (shutdown.isRequested()) {
        std.log.info("shutdown signal received — listener closed, flushing in-flight requests", .{});

        // `mode="background_persistence"` processes belong to THIS service,
        // so they go down with it — a dev server still holding its port after
        // the user quit pabrik is not "persistent", it is a leak.
        if (background_process.killServicesForShutdown(dbSqlite, io, allocator)) |killed| {
            if (killed > 0) std.log.info("background services: stopped {d} on shutdown", .{killed});
        } else |err| {
            std.log.warn("background service shutdown kill failed: {s}", .{@errorName(err)});
        }

        // Exit instead of unwinding: full unwind segfaults (defer teardowns
        // race draining Io worker threads) and the stops race
        // signal-interrupted workers.
        helpers.sleepMillis(50);
        std.process.exit(0);
    }

    // Only /test/shutdown reaches here (the signal path exits above): join
    // the cron thread BEFORE the defers free its context, or it segfaults
    // ~10s later (rc=-11).
    gs.cronjob_manager.stop();
    gs.sse_manager.stop();
}
