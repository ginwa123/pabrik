//! Server-boot phases extracted from `main`: SIGPIPE handling, CLI parsing,
//! TLS setup, database open + migrations, port resolution, static-dir config.
//!
//! Ownership rule: phase fns return owned values; `main` keeps every local
//! and `defer`. Background threads outliving freed context segfault, so
//! teardown order stays in exactly one place.

const std = @import("std");
const helpers = @import("helpers");
const database = @import("databases").database;
const gserverz = @import("kabelweb").server;
const cli_args = @import("../cli_args.zig");
const migration = @import("../migrations/mod.zig").migration;
const static_files = @import("../modules/static_files.zig");
const shutdown = @import("shutdown.zig");
const db_config = @import("db_config.zig");
const secrets_key = @import("secrets_key.zig");
const secrets_at_rest = @import("../agentic_loop/secrets_at_rest.zig");
const static_serve = @import("../http_static/static_serve.zig");
const config_mod = @import("../modules/config/Config.zig");
const workspace_config = @import("../agentic_loop/workspace_config.zig");

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

/// tryParseCliArgs + report + remap to InvalidArgs.
/// Runs BEFORE anything with side effects: `LlmConfig.init` starts the
/// scheduler thread, after which an error exit segfaults instead of
/// reporting the real error.
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
    db_path: [:0]const u8,
    db: database.Db,

    pub fn deinit(self: *DatabaseHandles, allocator: std.mem.Allocator) void {
        self.db.deinit();
        allocator.free(self.db_path);
    }
};

/// Resolve the DB path, open it with `boot/db_config.zig`'s measured
/// policy (WAL + `.normal`, reader pooling, 8 MiB page cache per
/// connection, 256 MiB mmap window), log the live config, and run
/// migrations. Caller owns the handles.
pub fn openDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) !DatabaseHandles {
    const db_path = try helpers.db_path.getDbPath(allocator, io, env);
    errdefer allocator.free(db_path);
    var db: database.Db = .{};
    errdefer db.deinit();
    try database.openWithConfig(&db, io, .{ .sqlite_path = db_path }, db_config.best);
    // Before anything else can read the file: narrow its mode — it holds the
    // LLM api_key, the MCP header values and every workspace secret — and turn
    // on the pragmas `SqliteConfig` cannot express.
    helpers.db_path.restrictDbPermissions(io, db_path);
    db_config.applySecurityPragmas(allocator, &db);
    shutdown.logSqliteConfig(allocator, &db);
    try runMigrations(allocator, &db);

    // At-rest sealing, before the server accepts a request.
    //
    // The key comes from the OS keychain and nowhere else, so a host without
    // one keeps working in plaintext and SAYS SO (see `logSecretsAtRestState`)
    // rather than silently downgrading. This is deliberately after migrations
    // and NOT a migration: the chain has to stay runnable where no key can be
    // obtained, and `migration_103.up` is pure SQL.
    const key_status = secrets_key.load(allocator, io);
    secrets_at_rest.setKey(key_status.key);
    logSecretsAtRestState(key_status);
    sealLegacySecretValues(allocator, io, &db, db_path);

    return .{ .db_path = db_path, .db = db };
}

/// One boot-log line saying whether values are sealed, and exactly how to fix
/// it when they are not.
///
/// A silent downgrade to plaintext is the failure mode this exists to prevent:
/// the operator has to be able to tell "this host is sealing" from "this host
/// gave up and stored the credential in the clear", and the second case has to
/// come with the command that ends it.
fn logSecretsAtRestState(status: secrets_key.Status) void {
    if (status.sealed()) {
        std.log.info("secrets: workspace secret values are sealed at rest (AES-256-GCM, key held by the OS keychain)", .{});
        return;
    }
    std.log.warn("secrets: {s}", .{status.unavailable.describe()});
    if (secrets_key.provisionCommand()) |cmd| {
        std.log.warn(
            "secrets: to seal them, store a 32-byte key (64 hex chars) in the OS keychain and restart — {s}",
            .{cmd},
        );
    }
}

/// Seal every row written before the cipher existed, then make the file agree
/// with the claim.
///
/// Both steps are best-effort and neither is fatal: a boot that cannot seal is
/// still a boot, and the log says what was left behind.
fn sealLegacySecretValues(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *database.Db,
    db_path: []const u8,
) void {
    const sealed_count = secrets_at_rest.sealLegacyRows(allocator, db) catch |err| {
        std.log.warn("secrets: the seal pass failed ({s}); values written before now stay in plaintext", .{@errorName(err)});
        return;
    };
    if (sealed_count == 0) return;

    std.log.info(
        "secrets: sealed {d} previously plaintext value(s); compacting so the old bytes do not survive in the file",
        .{sealed_count},
    );
    secrets_at_rest.compactAfterSeal(allocator, db, db_path, io);
}

pub fn runMigrations(allocator: std.mem.Allocator, db: *database.Db) !void {
    var mm = migration.MigrationManager.init(allocator, db);
    defer mm.deinit();
    try migration.registerAllMigrations(&mm);
    try mm.runMigrations();
}

/// Give every UNDECIDED workspace a copy of the user-level config.
///
/// This is what makes "Profiles / MCP Servers / Tools / Skill Evals live in
/// Workspace settings" true for workspaces that already existed: each one
/// starts with the sections the user already configured, editable in place,
/// instead of an empty page the user has to rebuild.
///
/// BEST-EFFORT, and deliberately not an error path: the settings pages work
/// off the user-level config whether or not this ran, so a failure here must
/// never stop the server from booting. Every failure is logged.
///
/// Idempotent, so running it on every boot is safe: `workspace_config
/// .seedWorkspaces` skips any workspace that already has a `workspace_settings`
/// ROW. The row (not the body) is the test, which is what lets a deliberate
/// "reset to inherited" survive the next boot instead of being re-copied.
///
/// `--auth` mode is SKIPPED on purpose: a workspace is shared between users
/// and `workspace_settings` holds profiles with API keys in them, so seeding
/// it from whichever user happened to be first would hand that user's
/// credentials to every other member. Auth mode gets the same result through
/// the explicit per-workspace copy endpoint, which knows who is asking.
pub fn seedWorkspaceSettingsFromUserConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    db: *database.Db,
    auth_enabled: bool,
) void {
    if (auth_enabled) {
        std.log.info("workspace config seeding: skipped (--auth on: a shared workspace has no single user config to copy)", .{});
        return;
    }

    const config_path = config_mod.getDefaultConfigPath(allocator, env) catch |err| {
        std.log.warn("workspace config seeding: cannot resolve the config path: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(config_path);

    // No config.json at all (a fresh install) is the ordinary first-boot
    // case, not a failure - there is simply nothing to copy.
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch return;
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch |err| {
        std.log.warn("workspace config seeding: cannot read {s}: {s}", .{ config_path, @errorName(err) });
        return;
    };
    defer allocator.free(content);

    const report = workspace_config.seedWorkspaces(allocator, db, content) catch |err| {
        std.log.warn("workspace config seeding: {s}", .{@errorName(err)});
        return;
    };
    if (report.seeded > 0) {
        std.log.info("workspace config seeding: copied the user config into {d} workspace(s); {d} already decided", .{ report.seeded, report.already_decided });
    }
}

/// Build the `--static-dir DIR` config: absolutize first (`openDirAbsolute`
/// asserts absolute and aborts on failure — a relative path must never
/// reach it), then open + canonicalize, with the `/app` + `/login` SPA
/// fallbacks so client-side routes survive reload. Caller frees via
/// `freeStaticDir`.
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
