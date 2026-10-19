// src/service/main_service.zig Implements the `pabrik service
// {start,stop,status,restart}` subcommand.

const std = @import("std");
const builtin = @import("builtin");
const state_file = @import("state_file.zig");
const daemon = @import("daemon.zig");
const signal_handlers = @import("signal_handlers.zig");
// helpers/ lives at src/helpers/, one directory up from src/service/.
const helpers = @import("helpers");
const cli_parse = @import("../cli/parse.zig");

pub const Subcommand = union(enum) {
    start: struct {
        /// 0 = auto-pick a random free loopback port (browser mode, plan
        /// 2026-09-10-web-launch-toggle).
        port: u16 = 8081,
        no_static_dir: bool = false,
        /// Absolute path to a static file directory to serve at `/`. When
        /// null, the daemon serves only API endpoints (no webapp).
        static_dir: ?[]const u8 = null,
        /// Opt-in auth enforcement (mirrors top-level `--auth`).
        auth_enabled: bool = false,
    },
    stop: struct { graceful_timeout_ms: u32 = 5000 },
    status: void,
    restart: struct {
        port: u16 = 8081,
        graceful_timeout_ms: u32 = 5000,
        static_dir: ?[]const u8 = null,
        auth_enabled: bool = false,
    },
};

pub const ParseError = error{
    UnknownSubcommand,
    MissingValue,
    InvalidPort,
    OutOfMemory,
};

/// The verbs this parser accepts. A runtime `args[0]` picks one, and the
/// engine then sees its name at comptime so the flag table can filter.
const Verb = enum { start, stop, restart };

pub fn parseServiceSubcommand(
    args: []const []const u8,
) ParseError!Subcommand {
    if (args.len == 0) return error.UnknownSubcommand;
    const verb = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, verb, "status")) {
        if (rest.len > 0) return error.UnknownSubcommand;
        return .status;
    }
    if (std.mem.eql(u8, verb, "start")) return parseVerb(.start, rest);
    if (std.mem.eql(u8, verb, "stop")) return parseVerb(.stop, rest);
    if (std.mem.eql(u8, verb, "restart")) return parseVerb(.restart, rest);
    return error.UnknownSubcommand;
}

/// Every field any `service` verb may set. The table refuses a flag the verb
/// does not list, so a field a verb cannot set stays at its default.
const ServiceFlags = struct {
    port: u16 = 8081,
    no_static_dir: bool = false,
    static_dir: ?[]const u8 = null,
    auth_enabled: bool = false,
    graceful_timeout_ms: u32 = 5000,
};

fn parseVerb(comptime verb: Verb, rest: []const []const u8) ParseError!Subcommand {
    var got: ServiceFlags = .{};
    const opts: cli_parse.Options = .{ .scope = .service, .verb = @tagName(verb) };
    if (try cli_parse.parse(ServiceFlags, opts, null, rest, &got, null)) |failure| {
        return switch (failure.kind) {
            .missing_value => error.MissingValue,
            .invalid_value => error.InvalidPort,
            .unknown_flag => error.UnknownSubcommand,
        };
    }
    return switch (verb) {
        .start => .{ .start = .{
            .port = got.port,
            .no_static_dir = got.no_static_dir,
            .static_dir = got.static_dir,
            .auth_enabled = got.auth_enabled,
        } },
        .stop => .{ .stop = .{ .graceful_timeout_ms = got.graceful_timeout_ms } },
        .restart => .{ .restart = .{
            .port = got.port,
            .graceful_timeout_ms = got.graceful_timeout_ms,
            .static_dir = got.static_dir,
            .auth_enabled = got.auth_enabled,
        } },
    };
}

pub const StartError = anyerror;

pub const StartOptions = struct {
    port: u16,
    no_static_dir: bool,
    /// Optional absolute path to a static-dir. Passed through to
    /// runPabrikServer as `--static-dir`. See Subcommand.start.static_dir.
    static_dir: ?[]const u8 = null,
    state_path: []const u8,
    log_path: []const u8,
    /// Injectable shutdown callback. Called from the SIGTERM signal handler
    /// to gracefully close the server and remove the state file.
    on_shutdown: *const fn () void,
};

/// Start the pabrik service.
pub fn serviceStart(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: StartOptions,
) StartError!void {
    // 1. Refuse if a live daemon is already tracked in state.json.
    if (try state_file.readStateFile(allocator, io, opts.state_path)) |existing| {
        defer state_file.freeState(allocator, existing);
        if (helpers.process_status.isProcessRunning(existing.pid)) return error.AlreadyRunning;
        // Stale state (pid is dead) — remove and proceed.
        std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
    }

    // 2. Daemonize.
    try daemon.daemonize(allocator);
    try daemon.redirectStdioToLog(opts.log_path);

    // 3.
    const state: state_file.State = .{
        .pid = helpers.process_status.getCurrentProcessIdInt(),
        .port = opts.port,
        .host = "127.0.0.1",
        .started_at = helpers.unixTimestamp(),
        .version = "0.4.0",
        .static_dir = opts.static_dir,
    };
    try state_file.writeStateFile(allocator, io, opts.state_path, state);

    // 4. Install the shutdown-signal handler.
    signal_handlers.installSigtermHandler(opts.on_shutdown);

    // 5. Hand off to the caller-supplied server run-loop. This blocks
    //    until the server stops (typical: shutdown HTTP endpoint
    //    called, or SIGTERM received).
}

pub const StopError = error{OutOfMemory};

pub const StopOptions = struct {
    graceful_timeout_ms: u32,
    state_path: []const u8,
};

/// Stop the pabrik service. Idempotent: if no state file exists, this
/// is a no-op (informational log). If the pid in the state file is
/// dead, we treat it as stale and remove the file (no error).
pub fn serviceStop(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: StopOptions,
) StopError!void {
    const state = (try state_file.readStateFile(allocator, io, opts.state_path)) orelse {
        std.log.info("pabrik is not running (no state file).", .{});
        return;
    };
    defer state_file.freeState(allocator, state);
    if (!helpers.process_status.isProcessRunning(state.pid)) {
        std.log.warn("Stale state file (pid {d} is dead); removing.", .{state.pid});
        std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
        return;
    }

    // Cross-platform terminate-with-grace.
    if (builtin.os.tag == .windows) {
        _ = helpers.process_status.killProcess(state.pid);
    } else {
        _ = std.c.kill(state.pid, @as(std.c.SIG, @enumFromInt(15))); // SIGTERM
        // Monotonic ns for deadline tracking (CLOCK_REALTIME can jump
        // backwards under NTP step — bad for `start + offset` deadlines;
        // CLOCK_MONOTONIC is immune).
        const start_ns: u64 = helpers.monotonicTimestampNanos();
        const deadline_ns: u64 = start_ns +
            @as(u64, opts.graceful_timeout_ms) * std.time.ns_per_ms;
        while (helpers.monotonicTimestampNanos() < deadline_ns) {
            if (!helpers.process_status.isProcessRunning(state.pid)) break;
            helpers.sleepMillis(50);
        }
        if (helpers.process_status.isProcessRunning(state.pid)) {
            std.log.warn("Graceful shutdown timed out, sending SIGKILL.", .{});
            _ = helpers.process_status.killProcess(state.pid);
        }
    }
    std.Io.Dir.cwd().deleteFile(io, opts.state_path) catch {};
}

/// Report service status. Logs (using std.log) whether the service is
/// running, stale, or absent.
pub fn serviceStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,
) !void {
    const state = (try state_file.readStateFile(allocator, io, state_path)) orelse {
        std.log.info("status: stopped (no state file)", .{});
        return;
    };
    defer state_file.freeState(allocator, state);
    if (!helpers.process_status.isProcessRunning(state.pid)) {
        std.log.warn("status: stale state (pid {d} is dead)", .{state.pid});
        return;
    }
    std.log.info("status: running (pid {d}, http://{s}:{d}/)", .{ state.pid, state.host, state.port });
}

// ===== Tests merged from main_service_test.zig (2026-09-29 flatten) =====

// Tests for the `pabrik service` subcommand parser + idempotent stop.

const testing = std.testing;

test "parseServiceSubcommand accepts start with --port" {
    const cmd = try parseServiceSubcommand(&.{ "start", "--port", "8081" });
    try testing.expect(cmd == .start);
    try testing.expectEqual(@as(u16, 8081), cmd.start.port);
}

test "parseServiceSubcommand start defaults port to 8081" {
    const cmd = try parseServiceSubcommand(&.{"start"});
    try testing.expectEqual(@as(u16, 8081), cmd.start.port);
    try testing.expect(!cmd.start.no_static_dir);
}

test "parseServiceSubcommand rejects unknown verb" {
    const result = parseServiceSubcommand(&.{"reboot"});
    try testing.expectError(error.UnknownSubcommand, result);
}

test "parseServiceSubcommand rejects invalid --port" {
    const result = parseServiceSubcommand(&.{ "start", "--port", "notanumber" });
    try testing.expectError(error.InvalidPort, result);
}

test "parseServiceSubcommand accepts status with no args" {
    const cmd = try parseServiceSubcommand(&.{"status"});
    try testing.expect(cmd == .status);
}

test "parseServiceSubcommand rejects status with extra args" {
    const result = parseServiceSubcommand(&.{ "status", "extra" });
    try testing.expectError(error.UnknownSubcommand, result);
}

test "parseServiceSubcommand accepts stop with --graceful-timeout-ms" {
    const cmd = try parseServiceSubcommand(&.{ "stop", "--graceful-timeout-ms", "1000" });
    try testing.expectEqual(@as(u32, 1000), cmd.stop.graceful_timeout_ms);
}

test "parseServiceSubcommand accepts restart with --port and --graceful-timeout-ms" {
    const cmd = try parseServiceSubcommand(&.{
        "restart", "--port", "9999", "--graceful-timeout-ms", "2000",
    });
    try testing.expectEqual(@as(u16, 9999), cmd.restart.port);
    try testing.expectEqual(@as(u32, 2000), cmd.restart.graceful_timeout_ms);
    try testing.expect(cmd.restart.static_dir == null);
}

test "parseServiceSubcommand accepts restart --static-dir (webapp survives a restart)" {
    // Regression: the usage text advertised --static-dir for `restart` but
    // the parser rejected it with UnknownSubcommand, and main.zig never
    // forwarded the value either — so a restarted daemon silently lost its
    const cmd = try parseServiceSubcommand(&.{
        "restart", "--port", "9999", "--static-dir", "/tmp/webapp",
    });
    try testing.expectEqualStrings("/tmp/webapp", cmd.restart.static_dir.?);
}

test "parseServiceSubcommand start keeps --static-dir" {
    const cmd = try parseServiceSubcommand(&.{
        "start", "--port", "9999", "--static-dir", "/tmp/webapp",
    });
    try testing.expectEqualStrings("/tmp/webapp", cmd.start.static_dir.?);
}

test "parseServiceSubcommand rejects empty args" {
    const result = parseServiceSubcommand(&.{});
    try testing.expectError(error.UnknownSubcommand, result);
}
