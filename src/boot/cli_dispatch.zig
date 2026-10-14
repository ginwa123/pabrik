//! `pabrik service ...` and `pabrik create-admin ...` subcommand dispatch.
//! Both peek at argv[1] and return false when it does not match, so `main`
//! falls through to the regular server boot.

const std = @import("std");
const helpers = @import("helpers");
const database = @import("databases").database;
const migration = @import("../migrations/mod.zig").migration;
const db_config = @import("db_config.zig");
const service_mod = @import("../service/mod.zig");

const state_file = service_mod.state_file;
const main_service = service_mod.main_service;
const ai_mod = @import("../ai_workflow/tui/mod.zig");

/// `pabrik service {start,stop,status,restart}`. For `service start` we only
/// daemonize + write the state file; the full server handoff is a follow-up.
pub fn dispatchServiceSubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    _ = environment;
    const args = init.minimal.args;
    // `initAllocator` works on every host (`Args.Iterator.init` is
    // compileError-blocked on Windows). Caller must `deinit()` for Windows.
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // skip argv[0]
    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "service")) return false;

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (it.next()) |a| try rest.append(allocator, a);

    const state_path = state_file.defaultStatePath(allocator) catch |err| {
        std.log.err("service: failed to resolve state path: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(state_path);

    const log_path = blk: {
        const home_z = std.c.getenv("HOME") orelse "/tmp";
        const home = std.mem.sliceTo(home_z, 0);
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "pabrik", "service.log" });
    };
    defer allocator.free(log_path);

    const cmd = main_service.parseServiceSubcommand(rest.items) catch |err| switch (err) {
        error.UnknownSubcommand => {
            std.log.err("unknown subcommand: {s}", .{if (rest.items.len > 0) rest.items[0] else "(none)"});
            std.log.err("usage: pabrik service {{start|stop|status|restart}} [flags]", .{});
            std.log.err("  start    [--port PORT] [--static-dir DIR] [--no-static-dir]  (PORT 0 = random free port)", .{});
            std.log.err("  stop     [--graceful-timeout-ms MS]", .{});
            std.log.err("  status", .{});
            std.log.err("  restart  [--port PORT] [--graceful-timeout-ms MS] [--static-dir DIR]", .{});
            return err;
        },
        error.MissingValue => {
            const prev_arg = if (rest.items.len > 1) rest.items[rest.items.len - 2] else "(none)";
            std.log.err("flag '{s}' requires a value", .{prev_arg});
            return err;
        },
        error.InvalidPort => {
            std.log.err("--port value is not a valid u16 number: {s}", .{
                if (rest.items.len > 2) rest.items[rest.items.len - 1] else "(missing)",
            });
            return err;
        },
        else => {
            std.log.err("service: {s}", .{@errorName(err)});
            return err;
        },
    };

    switch (cmd) {
        .start => |s| {
            const dummy_shutdown = struct {
                fn cb() void {}
            }.cb;
            main_service.serviceStart(allocator, io, .{
                .port = s.port,
                .no_static_dir = s.no_static_dir,
                .static_dir = s.static_dir,
                .state_path = state_path,
                .log_path = log_path,
                .on_shutdown = dummy_shutdown,
            }) catch |err| {
                std.log.err("service start: {s}", .{@errorName(err)});
                return err;
            };
        },
        .stop => |s| main_service.serviceStop(allocator, io, .{
            .graceful_timeout_ms = s.graceful_timeout_ms,
            .state_path = state_path,
        }) catch |err| {
            std.log.err("service stop: {s}", .{@errorName(err)});
            return err;
        },
        .status => main_service.serviceStatus(allocator, io, state_path) catch |err| {
            std.log.err("service status: {s}", .{@errorName(err)});
            return err;
        },
        .restart => |s| {
            main_service.serviceStop(allocator, io, .{
                .graceful_timeout_ms = s.graceful_timeout_ms,
                .state_path = state_path,
            }) catch |err| {
                std.log.err("service restart (stop): {s}", .{@errorName(err)});
                return err;
            };
            const dummy_shutdown2 = struct {
                fn cb() void {}
            }.cb;
            main_service.serviceStart(allocator, io, .{
                .port = s.port,
                .no_static_dir = false,
                .static_dir = s.static_dir,
                .state_path = state_path,
                .log_path = log_path,
                .on_shutdown = dummy_shutdown2,
            }) catch |err| {
                std.log.err("service restart (start): {s}", .{@errorName(err)});
                return err;
            };
        },
    }
    return true;
}

/// `pabrik create-admin --email E [--password P] [--name N] [--force]`.
pub fn dispatchCreateAdmin(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    const args = init.minimal.args;
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "create-admin")) return false;

    var email: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var name: []const u8 = "";
    var force = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--email")) {
            email = it.next() orelse {
                std.log.err("create-admin: --email requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--password")) {
            password = it.next() orelse {
                std.log.err("create-admin: --password requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--name")) {
            name = it.next() orelse {
                std.log.err("create-admin: --name requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("Usage: pabrik create-admin --email E [--password P] [--name N] [--force]\n", .{});
            return true;
        } else {
            std.log.err("create-admin: unknown flag '{s}'", .{a});
            return error.InvalidArgs;
        }
    }
    const email_v = email orelse {
        std.log.err("create-admin: --email is required", .{});
        return error.InvalidArgs;
    };
    if (std.mem.indexOfScalar(u8, email_v, '@') == null) {
        std.log.err("create-admin: --email must contain '@'", .{});
        return error.InvalidArgs;
    }
    const password_v = password orelse {
        std.log.err("create-admin: --password is required (pass via env in scripts)", .{});
        return error.InvalidArgs;
    };
    if (password_v.len < 8) {
        std.log.err("create-admin: password must be at least 8 characters", .{});
        return error.InvalidArgs;
    }

    const db_path = try helpers.db_path.getDbPath(allocator, io, @constCast(environment));
    defer allocator.free(db_path);
    var dbSqlite: database.Db = .{};
    defer dbSqlite.deinit();
    try database.openWithConfig(&dbSqlite, io, .{ .sqlite_path = db_path }, db_config.best);
    var mm = migration.MigrationManager.init(allocator, &dbSqlite);
    defer mm.deinit();
    try migration.registerAllMigrations(&mm);
    try mm.runMigrations();

    if (!force) {
        var q = try dbSqlite.query(allocator, "SELECT 1 FROM users WHERE role = 'admin' AND is_active = 1 LIMIT 1", &.{});
        defer q.deinit();
        if ((try q.next()) != null) {
            std.log.err("create-admin: an active admin already exists (use --force to add another)", .{});
            return error.InvalidArgs;
        }
    }

    var hash_buf: [256]u8 = undefined;
    const hash_slice = std.crypto.pwhash.bcrypt.strHash(password_v, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &hash_buf, io) catch {
        std.log.err("create-admin: password hashing failed", .{});
        return error.InvalidArgs;
    };
    const ts = std.Io.Timestamp.now(io, .real);
    const id = try std.fmt.allocPrint(allocator, "user_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});
    defer allocator.free(id);
    dbSqlite.exec(
        allocator,
        "INSERT INTO users (id, email, name, password_hash, role, is_active) VALUES (?, ?, COALESCE(?, ''), ?, 'admin', 1)",
        &[_][]const u8{ id, email_v, name, hash_slice },
    ) catch {
        std.log.err("create-admin: insert failed (email may already exist)", .{});
        return error.InvalidArgs;
    };
    std.debug.print("create-admin: admin '{s}' created\n", .{email_v});

    // New admins get their "Default" workspace now; the first login retries
    // via the same idempotent ensure, so a failure here stays non-fatal.
    const provisioned = ai_mod.http_handlers.workspace_provisioning.ensureDefaultWorkspace(
        allocator,
        &dbSqlite,
        io,
        id,
        environment,
    ) catch |err| {
        std.log.warn("create-admin: could not provision the default workspace (non-fatal, the first login retries): {s}", .{@errorName(err)});
        return true;
    };
    if (provisioned) |workspace| {
        defer workspace.deinit(allocator);
        std.debug.print("create-admin: workspace '{s}' ({s}) provisioned\n", .{ workspace.name, workspace.id });
    }
    return true;
}
