//! Server-boot phases extracted from `main`: SIGPIPE handling, CLI parsing,
//! TLS setup, database open + migrations, port resolution, static-dir config.

const std = @import("std");
const helpers = @import("helpers");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;
const cli_args = @import("../cli_args.zig");
const runtime_mode = @import("../runtime_mode.zig");
const vmd_client = @import("../vmd/vmd_client.zig");
const vmd_bootstrap = @import("../vmd/bootstrap.zig");
const migration = @import("../migrations/mod.zig").migration;
const static_files = @import("../modules/static_files.zig");
const shutdown = @import("shutdown.zig");
const db_config = @import("db_config.zig");
const db_target = @import("db_target.zig");
const static_serve = @import("../http_static/static_serve.zig");
const model_catalog_refresh = @import("../agentic_loop/model_catalog_refresh.zig");

/// Ignore SIGPIPE process-wide (non-Windows). A peer vanishing mid-write
/// must surface as a write error, not a signal (OpenSSL uses plain write(2)).
pub fn ignoreSigpipe() void {
    if (comptime @import("builtin").os.tag != .windows) {
        var sa = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &sa, null);
    }
}

/// Parse outcome with reporting left to the caller: asserting every variant
/// emits no error-level logs (the test runner fails any test that logs at
/// err level, which `reportFailure` does by design).
pub const CliParseOutcome = union(enum) {
    ok: cli_args.CliArgs,
    help,
    invalid: cli_args.Failure,
};

pub fn tryParseCliArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) cli_args.ParseError!CliParseOutcome {
    var cli: cli_args.CliArgs = .{};
    if (try cli_args.parse(allocator, argv, &cli)) |failure| {
        return .{ .invalid = failure };
    }
    if (cli.help_requested) return .help;
    return .{ .ok = cli };
}

/// tryParseCliArgs + report + remap to InvalidArgs. Runs BEFORE anything with
/// side effects: `LlmConfig.init` starts the scheduler thread, after which an
/// error exit segfaults instead of reporting the real error.
pub fn parseCliArgs(allocator: std.mem.Allocator, argv: []const []const u8) !?cli_args.CliArgs {
    return switch (try tryParseCliArgs(allocator, argv)) {
        .ok => |cli| cli,
        .help => null,
        .invalid => |failure| {
            cli_args.reportFailure(failure);
            return error.InvalidArgs;
        },
    };
}

/// One open of a probe path: a missing /dev/kvm or cgroup mount is an answer,
/// not an error, so this never propagates.
fn probeReadable(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

/// A manager that answers a ping is the last thing `--saas` needs: without it
/// the process could start and then have to run tenant commands on the host.
fn probeManager(allocator: std.mem.Allocator, socket_path: []const u8) bool {
    var client = vmd_client.Client.init(allocator, socket_path);
    client.guard_ms = 1_000;
    const version = client.ping() catch return false;
    allocator.free(version);
    return true;
}

/// The manager is part of the `--saas` contract, so a boot that finds none
/// starts one: `--saas` is the platform, not a manual two-step bring-up.
fn startManager(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, socket_path: []const u8) bool {
    var exe_dir: ?[]u8 = null;
    defer if (exe_dir) |dir| allocator.free(dir);
    if (std.process.executablePathAlloc(io, allocator)) |exe_path| {
        defer allocator.free(exe_path);
        if (std.fs.path.dirname(exe_path)) |dir| exe_dir = allocator.dupe(u8, dir) catch null;
    } else |_| {}

    const outcome = vmd_bootstrap.ensure(allocator, io, env, exe_dir, socket_path, vmd_bootstrap.default_wait_ms) catch |err| {
        std.log.err("--saas could not start pabrik-vmd: {s}", .{@errorName(err)});
        return false;
    };
    return switch (outcome) {
        .started => true,
        .refused => |refusal| blk: {
            std.log.err("{s}", .{vmd_bootstrap.message(refusal)});
            break :blk false;
        },
    };
}

/// Applies `--saas`: it implies auth, then refuses unless this host can honour
/// isolation. Refusal is logged and returns null so the caller can exit. On
/// success the resolved mode and the manager's socket are recorded process-wide.
pub fn enforceRuntimeMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cli: *cli_args.CliArgs,
) ?runtime_mode.Mode {
    if (cli.saas) cli.auth_enabled = true;
    const is_linux = comptime @import("builtin").os.tag == .linux;
    var manager_reachable = false;
    if (is_linux) {
        if (cli.saas) {
            if (runtime_mode.defaultSocketPath(allocator, env)) |path| {
                // Process-lifetime: the tool layer reads it on every command,
                // so it is never freed.
                runtime_mode.setManagerSocket(path);
                manager_reachable = probeManager(allocator, path);
                // No manager yet: `--saas` starts one rather than refusing.
                if (!manager_reachable) manager_reachable = startManager(allocator, io, env, path);
            } else |_| {}
        }
    }
    const probe = runtime_mode.Probe{
        .os = @import("builtin").os.tag,
        .kvm_readable = if (is_linux) probeReadable(io, "/dev/kvm") else false,
        .cgroup2_mounted = if (is_linux) probeReadable(io, "/sys/fs/cgroup/cgroup.controllers") else false,
        .vmd_reachable = manager_reachable,
    };
    return switch (runtime_mode.decide(cli.saas, probe)) {
        .ok => |mode| {
            runtime_mode.setCurrent(mode);
            return mode;
        },
        .refused => |refusal| {
            std.log.err("{s}", .{runtime_mode.message(refusal)});
            return null;
        },
    };
}

/// Explicit `--port` wins; otherwise `web_launch_enabled` decides: random
/// (0) when on so browser-mode URLs never clash, 8081 when off.
pub fn resolvePort(cli_port: ?u16, web_launch_enabled: bool) u16 {
    return cli_port orelse (if (web_launch_enabled) 0 else 8081);
}

/// Generate/reuse the self-signed pair when asked, then load cert+key into
/// a TLS context. Path typos fail here naming the flag and path, never as
/// a silent plaintext fallback later. Null when TLS is off.
pub fn setupTlsCtx(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cli: *cli_args.CliArgs,
) !?*gserverz.tls.Ctx {
    if (cli.tls_selfsigned) {
        const dir = try static_serve.tlsDataDir(allocator, env);
        const paths = try gserverz.tls_cert.ensureSelfSigned(allocator, dir, "localhost", 365);
        cli.tls_cert_path = paths.cert_pem;
        cli.tls_key_path = paths.key_pem;
    }
    if (cli.tls_cert_path) |cert| {
        const key = cli.tls_key_path orelse unreachable;
        const ctx = gserverz.tls.Ctx.init(allocator, cert, key, &.{ gserverz.tls.alpn_h2, gserverz.tls.alpn_http1 }) catch |err| {
            std.log.err("Error: --tls cannot load cert={s} key={s}: {s}", .{ cert, key, @errorName(err) });
            return error.InvalidArgs;
        };
        // The functional tests parse this line for the certificate path.
        std.debug.print("TLS enabled (ALPN: h2, http/1.1) cert={s}\n", .{cert});
        return ctx;
    }
    return null;
}

pub const DatabaseHandles = struct {
    target: db_target.Target,
    db: database.Db,

    pub fn deinit(self: *DatabaseHandles) void {
        self.db.deinit();
        self.target.deinit();
    }
};

/// Resolve the backend `request` names (default: the one this build compiled
/// in), open it with `boot/db_config.zig`'s measured policy, log the target,
/// and run migrations.
pub fn openDatabase(
    //
    // `overrides` are the `--db-*` flags from argv; an empty slice means the
    // defaults. They are applied on top of `db_config.best`.
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    request: db_target.Request,
    overrides: []const db_config.Override,
) !DatabaseHandles {
    var target = try db_target.openTarget(allocator, io, env, request);
    errdefer target.deinit();

    var line_buf: [512]u8 = undefined;
    if (target.describe(&line_buf)) |line| {
        std.log.info("{s}", .{line});
    } else |_| {
        std.log.info("database: backend={s} source={s}", .{ target.backend.text(), target.origin.text() });
    }

    var db: database.Db = .{};
    errdefer db.deinit();
    database.openConfigured(&db, io, target.openConfig(), db_config.resolveConfig(overrides)) catch |err| {
        db_target.reportOpenError(&target, err, db_target.lastErrorMessage(&db));
        return err;
    };
    shutdown.logSqliteConfig(allocator, &db);
    try runMigrations(allocator, &db);
    return .{ .target = target, .db = db };
}

pub fn runMigrations(allocator: std.mem.Allocator, db: *database.Db) !void {
    var mm = migration.MigrationManager.init(allocator, db);
    defer mm.deinit();
    try migration.registerAllMigrations(&mm);
    mm.runMigrations() catch |err| {
        if (mm.running_version != 0) {
            std.log.err(
                "Error: migration {d} ({s}) failed: {s}",
                .{ mm.running_version, mm.running_name, @errorName(err) },
            );
            if (db_target.lastErrorMessage(db)) |detail| std.log.err("  {s}", .{detail});
            std.log.err(
                "  the schema is now partly migrated: a migration is recorded only after it succeeds, so this one retries against what it already changed",
                .{},
            );
        }
        return err;
    };
}

/// Build the `--static-dir DIR` config: absolutize first (`openDirAbsolute`
/// asserts absolute and aborts on failure — a relative path must never reach
/// it), then open + canonicalize, with the `/app` + `/login` SPA fallbacks so
pub fn loadModelCatalog(allocator: std.mem.Allocator, db: *database.Db) void {
    _ = model_catalog_refresh.loadAtBoot(allocator, db);
    model_catalog_refresh.startBackgroundSync(allocator, db);
}

pub fn setupStaticDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !*static_files.StaticDirConfig {
    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_static_dir = try static_files.resolveStaticDirAbs(io, allocator, dir, &abs_buf);
    defer allocator.free(abs_static_dir);

    const root_dir = std.Io.Dir.openDirAbsolute(io, abs_static_dir, .{}) catch |err| {
        std.log.err("--static-dir '{s}' cannot be opened: {s}", .{ dir, @errorName(err) });
        return err;
    };
    defer root_dir.close(io);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try root_dir.realPath(io, &path_buf);
    const abs_dir = try allocator.dupe(u8, path_buf[0..path_len]);
    errdefer allocator.free(abs_dir);

    const cfg = try allocator.create(static_files.StaticDirConfig);
    cfg.* = .{
        .root_dir = abs_dir,
        .allocator = allocator,
        .spa_fallback_prefix = "/app",
        .spa_fallback_prefix2 = "/login",
    };
    return cfg;
}

pub fn freeStaticDir(allocator: std.mem.Allocator, cfg: *static_files.StaticDirConfig) void {
    allocator.free(cfg.root_dir);
    allocator.destroy(cfg);
}

/// Find a shipped webapp dir (its `index.html`) without any flags, for
/// installer layouts where the UI ships beside the install root: `install.sh`
/// extracts `html/` next to the binaries (mirroring the `zig-out/bin/html`
pub fn findBundledWebapp(
    io: std.Io,
    allocator: std.mem.Allocator,
    candidates: []const []const u8,
) ?[]u8 {
    for (candidates) |dir| {
        const probe = std.fs.path.join(allocator, &.{ dir, "index.html" }) catch continue;
        defer allocator.free(probe);
        std.Io.Dir.cwd().access(io, probe, .{}) catch continue;
        return allocator.dupe(u8, dir) catch null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Behaviour tests (call the phase fns, assert outputs)
// ---------------------------------------------------------------------------

test "server_boot: resolvePort prefers an explicit --port either way" {
    try std.testing.expectEqual(@as(u16, 9090), resolvePort(9090, true));
    try std.testing.expectEqual(@as(u16, 9090), resolvePort(9090, false));
}

test "server_boot: resolvePort falls back to web-launch mode" {
    try std.testing.expectEqual(@as(u16, 0), resolvePort(null, true));
    try std.testing.expectEqual(@as(u16, 8081), resolvePort(null, false));
}

test "findBundledWebapp: returns null when no candidate holds index.html" {
    const found = findBundledWebapp(
        std.testing.io,
        std.testing.allocator,
        &.{ "/nonexistent-pabrik-dir-xyz", "/also-nonexistent-pabrik-dir-xyz" },
    );
    try std.testing.expect(found == null);
}

test "findBundledWebapp: returns the first candidate holding index.html" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // <tmp>/first/ stays empty; <tmp>/second/html/index.html is the hit.
    try tmp.dir.createDirPath(io, "first");
    try tmp.dir.createDirPath(io, "second/html");
    try tmp.dir.writeFile(io, .{
        .sub_path = "second/html/index.html",
        .data = "<!doctype html>",
        .flags = .{ .truncate = true },
    });

    const abs_file = try tmp.dir.realPathFileAlloc(io, "second/html/index.html", allocator);
    defer allocator.free(abs_file);
    const abs_html = std.fs.path.dirname(abs_file).?;
    const abs_second = std.fs.path.dirname(abs_html).?;
    const abs_tmp = std.fs.path.dirname(abs_second).?;
    const first = try std.fs.path.join(allocator, &.{ abs_tmp, "first" });
    defer allocator.free(first);

    const found = findBundledWebapp(io, allocator, &.{ first, abs_html }) orelse
        return error.TestUnexpectedResult;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(abs_html, found);
}

test "server_boot: tryParseCliArgs maps a bad --port to invalid" {
    const argv: []const []const u8 = &.{ "pabrik", "--port", "abc" };
    const outcome = try tryParseCliArgs(std.testing.allocator, argv);
    try std.testing.expect(outcome == .invalid);
    try std.testing.expectEqual(cli_args.FailureKind.invalid_port_value, outcome.invalid.kind);
}

test "server_boot: tryParseCliArgs maps --help to help" {
    const argv: []const []const u8 = &.{ "pabrik", "--help" };
    const outcome = try tryParseCliArgs(std.testing.allocator, argv);
    try std.testing.expect(outcome == .help);
}

test "server_boot: tryParseCliArgs passes through a valid --port" {
    const argv: []const []const u8 = &.{ "pabrik", "--port", "9090" };
    const outcome = try tryParseCliArgs(std.testing.allocator, argv);
    try std.testing.expect(outcome == .ok);
    try std.testing.expectEqual(@as(?u16, 9090), outcome.ok.port);
}

test "server_boot: parseCliArgs returns null when --help is requested" {
    const argv: []const []const u8 = &.{ "pabrik", "--help" };
    const result = try parseCliArgs(std.testing.allocator, argv);
    try std.testing.expect(result == null);
}

test "server_boot: parseCliArgs passes through a valid --port" {
    const argv: []const []const u8 = &.{ "pabrik", "--port", "9090" };
    const cli = (try parseCliArgs(std.testing.allocator, argv)) orelse return error.HelpUnexpected;
    try std.testing.expectEqual(@as(?u16, 9090), cli.port);
}
