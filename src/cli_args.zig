// src/cli_args.zig Parses the TOP-LEVEL `pabrik` command-line flags: --port,
// --static-dir, --http2, --tls, --tls-selfsigned, --auth and -h/--help.

const std = @import("std");
const logger_mod = @import("modules/logger/Logger.zig");

pub const CliArgs = struct {
    /// `--port`. Stays null unless the user passed it explicitly, so the
    /// default can honour `web_launch_enabled` (random port when on, 8081
    /// when off). 0 = pick a random free loopback port.
    port: ?u16 = null,
    /// `--static-dir`. Copied onto `ctxParent.static_dir_path` once that
    /// context exists. Allocator-owned for the process lifetime — see `parse`.
    /// Ignored when `no_static_dir` is set (see that field).
    static_dir: ?[]const u8 = null,
    /// `--no-static-dir`: serve the API only, no static files at `/`.
    no_static_dir: bool = false,
    /// `--http2 h2c`. OFF by default; there is deliberately no TLS here, so
    /// browsers keep using HTTP/1.1 unless TLS is also enabled.
    enable_h2c: bool = false,
    /// `--tls <cert.pem> <key.pem>` (allocator-owned, process lifetime), or
    /// the pair `tls_selfsigned` generates / reuses in the app data dir.
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    /// `--tls-selfsigned` generates (first run) or reuses a self-signed
    /// pair in the app data dir.
    tls_selfsigned: bool = false,
    /// Opt-in auth (`--auth`): login enforcement (login page + session
    /// cookie + middleware). Off by default so existing single-user setups
    /// keep working with zero behaviour change.
    auth_enabled: bool = false,
    /// `-h` / `--help` was seen. `parse` prints the usage text and stops
    /// scanning, so the caller must bail out without starting anything.
    help_requested: bool = false,
};

/// Which flag was rejected. One variant per distinct user-facing message —
/// the messages differ, so collapsing them into one `InvalidArgs` would lose
/// the only thing that tells the user what to fix.
pub const FailureKind = enum {
    missing_port_value,
    invalid_port_value,
    missing_static_dir_value,
    invalid_http2_mode,
    missing_tls_cert_path,
    missing_tls_key_path,
};

/// What `parse` rejected, in enough detail to print the message.
pub const Failure = struct {
    kind: FailureKind,
    /// The offending word — the `--http2` mode, or the cert path given to a
    /// one-armed `--tls`. Empty when the flag simply had no value.
    value: []const u8 = "",
};

pub const ParseError = error{OutOfMemory};

/// Parse `args` (argv WITHOUT argv[0]) into `out`, which is reset to its
/// defaults first.
pub fn parse(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *CliArgs,
) ParseError!?Failure {
    out.* = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return .{ .kind = .missing_port_value };
            out.port = std.fmt.parseInt(u16, args[i], 10) catch
                return .{ .kind = .invalid_port_value };
        } else if (std.mem.eql(u8, arg, "--static-dir")) {
            i += 1;
            if (i >= args.len) return .{ .kind = .missing_static_dir_value };
            out.static_dir = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--no-static-dir")) {
            out.no_static_dir = true;
        } else if (std.mem.eql(u8, arg, "--http2")) {
            // `--http2` on its own means h2c; an explicit value keeps room
            // for future modes (e.g. `--http2=off`).
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "h2c")) {
                    out.enable_h2c = true;
                } else if (std.mem.eql(u8, args[i], "off")) {
                    out.enable_h2c = false;
                } else {
                    return .{ .kind = .invalid_http2_mode, .value = args[i] };
                }
            } else {
                out.enable_h2c = true;
            }
        } else if (std.mem.eql(u8, arg, "--tls")) {
            // TWO values, consumed positionally: `--tls CERT KEY`.
            i += 1;
            if (i >= args.len) return .{ .kind = .missing_tls_cert_path };
            const cert_arg = args[i];
            i += 1;
            if (i >= args.len) {
                return .{ .kind = .missing_tls_key_path, .value = cert_arg };
            }
            out.tls_cert_path = try allocator.dupe(u8, cert_arg);
            out.tls_key_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--tls-selfsigned")) {
            out.tls_selfsigned = true;
        } else if (std.mem.eql(u8, arg, "--auth")) {
            out.auth_enabled = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            // Help wins over everything to its right, exactly as it did when
            // this block was inline in `main`: `pabrik --help --port abc`
            // prints usage and exits 0 rather than failing on the bad port.
            printUsage();
            out.help_requested = true;
            return null;
        }
    }
    return null;
}

/// Print the user-facing message for a `Failure`.
pub fn reportFailure(f: Failure) void {
    switch (f.kind) {
        .missing_port_value => std.log.err("Error: --port requires a value", .{}),
        .invalid_port_value => std.log.err("Error: invalid port number", .{}),
        .missing_static_dir_value => std.log.err("Error: --static-dir requires a value", .{}),
        .invalid_http2_mode => std.log.err("Error: --http2 expects h2c or off (got {s})", .{f.value}),
        .missing_tls_cert_path => std.log.err("Error: --tls requires <cert.pem> <key.pem> (no cert path given)", .{}),
        .missing_tls_key_path => std.log.err("Error: --tls <cert.pem> <key.pem>: no key path given (cert={s})", .{f.value}),
    }
}

pub fn printUsage() void {
    logger_mod.debugPrint("Usage: pabrik [--port PORT] [--static-dir DIR] [--http2 h2c|off] [--tls CERT KEY | --tls-selfsigned] [--auth]\n", .{});
    logger_mod.debugPrint("  --port PORT          Port to run the HTTP server on (0 = pick a random free port; default: 8081, or random when web_launch_enabled is on)\n", .{});
    logger_mod.debugPrint("  --static-dir DIR     Serve files from DIR at HTTP / (e.g. for a webapp)\n", .{});
    logger_mod.debugPrint("  --no-static-dir      API only: serve no static files at / (overrides --static-dir)\n", .{});
    logger_mod.debugPrint("  --http2 h2c|off      Also accept HTTP/2 cleartext (h2c) clients on the same port (default: off)\n", .{});
    logger_mod.debugPrint("  --auth               Require login (session cookie + middleware). When off, all endpoints are open.\n", .{});
    logger_mod.debugPrint("Database policy (defaults are tuned for low RAM; override to trade RAM for throughput):\n", .{});
    logger_mod.debugPrint("  --db-read-conns=N              Readers opened at boot (warm floor)\n", .{});
    logger_mod.debugPrint("  --db-max-read-conns=N          Ceiling on pooled readers (0 = uncapped)\n", .{});
    logger_mod.debugPrint("  --db-cache-size-kb=N           Page cache PER connection, in KiB\n", .{});
    logger_mod.debugPrint("  --db-mmap-size-bytes=N         mmap window per connection (0 = off)\n", .{});
    logger_mod.debugPrint("  --db-journal-size-limit-bytes=N  WAL/journal size cap\n", .{});
    logger_mod.debugPrint("  --db-wal-autocheckpoint-pages=N Pages between WAL checkpoints\n", .{});
    logger_mod.debugPrint("  --db-busy-timeout-ms=N         How long SQLite waits for a lock\n", .{});
    logger_mod.debugPrint("  --db-max-idle-time-ms=N        How long an idle reader is kept before it is closed\n", .{});
}

const testing = std.testing;

/// Free the allocator-owned slices a successful `parse` may have produced,
/// so `testing.allocator`'s leak check is meaningful.
fn freeParsed(allocator: std.mem.Allocator, args: CliArgs) void {
    if (args.static_dir) |v| allocator.free(v);
    if (args.tls_cert_path) |v| allocator.free(v);
    if (args.tls_key_path) |v| allocator.free(v);
}

/// `parse` succeeding, with its result bound to `out`.
fn ok(argv: []const []const u8, out: *CliArgs) !void {
    if (try parse(testing.allocator, argv, out)) |f| {
        std.debug.print("\n!! expected {d}-arg argv to parse, got {s} !!\n", .{
            argv.len,
            @tagName(f.kind),
        });
        return error.UnexpectedParseFailure;
    }
}

/// `parse` failing, with the kind of failure bound.
fn rejects(argv: []const []const u8, expected: FailureKind) !void {
    var out: CliArgs = .{};
    defer freeParsed(testing.allocator, out);
    const f = (try parse(testing.allocator, argv, &out)) orelse {
        std.debug.print("\n!! expected {d}-arg argv to be rejected, it parsed !!\n", .{argv.len});
        return error.ExpectedRejection;
    };
    try testing.expectEqual(expected, f.kind);
}

test "parse: no arguments yields the documented defaults" {
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&.{}, &args);
    try testing.expectEqual(@as(?u16, null), args.port);
    try testing.expectEqual(@as(?[]const u8, null), args.static_dir);
    try testing.expectEqual(false, args.no_static_dir);
    try testing.expectEqual(false, args.enable_h2c);
    try testing.expectEqual(@as(?[]const u8, null), args.tls_cert_path);
    try testing.expectEqual(@as(?[]const u8, null), args.tls_key_path);
    try testing.expectEqual(false, args.tls_selfsigned);
    try testing.expectEqual(false, args.auth_enabled);
    try testing.expectEqual(false, args.help_requested);
}

test "parse: --port, --static-dir and --auth are read in any order" {
    const argv = [_][]const u8{ "--auth", "--static-dir", "/tmp/webapp", "--port", "9999" };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqual(@as(?u16, 9999), args.port);
    try testing.expectEqualStrings("/tmp/webapp", args.static_dir.?);
    try testing.expectEqual(true, args.auth_enabled);
}

test "parse: --port 0 is preserved so the free-port picker runs later" {
    // `port == 0` must survive parsing — main.zig turns it into a concrete
    // free port via web_port.pickFreePort, and a parser that collapsed it to
    // null would silently fall back to 8081.
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&.{ "--port", "0" }, &args);
    try testing.expectEqual(@as(?u16, 0), args.port.?);
}

test "parse: last --port wins" {
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&.{ "--port", "8081", "--port", "9000" }, &args);
    try testing.expectEqual(@as(?u16, 9000), args.port);
}

test "parse: --port rejects a missing, non-numeric, and out-of-range value" {
    try rejects(&.{"--port"}, .missing_port_value);
    try rejects(&.{ "--port", "abc" }, .invalid_port_value);
    // Out of range for u16 — parseInt fails rather than wrapping silently.
    try rejects(&.{ "--port", "70000" }, .invalid_port_value);
}

test "parse: --static-dir copies the value instead of aliasing argv" {
    var backing = [_]u8{ '/', 't', 'm', 'p', '/', 'w', 'e', 'b' };
    const argv = [_][]const u8{ "--static-dir", &backing };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqualStrings("/tmp/web", args.static_dir.?);
    // Mutating the argument buffer must NOT change what was parsed. This is
    // what dupe buys, and what a `?[]const u8 = args[i]` version would get
    // wrong on Windows, where the iterator buffer is freed on deinit.
    backing[0] = 'X';
    try testing.expectEqualStrings("/tmp/web", args.static_dir.?);
    try rejects(&.{"--static-dir"}, .missing_static_dir_value);
}

test "parse: --no-static-dir is independent of --static-dir, in either order" {
    // `zig build run` appends `--static-dir src/apps/desktop/dist`, so the
    // opt-out has to be readable from the same argv — and has to win
    // regardless of where it lands. main.zig resolves the precedence from
    var flag_first: CliArgs = .{};
    defer freeParsed(testing.allocator, flag_first);
    try ok(&.{ "--no-static-dir", "--static-dir", "/tmp/webapp" }, &flag_first);
    try testing.expectEqual(true, flag_first.no_static_dir);
    try testing.expectEqualStrings("/tmp/webapp", flag_first.static_dir.?);

    var flag_last: CliArgs = .{};
    defer freeParsed(testing.allocator, flag_last);
    try ok(&.{ "--static-dir", "/tmp/webapp", "--no-static-dir" }, &flag_last);
    try testing.expectEqual(true, flag_last.no_static_dir);
    try testing.expectEqualStrings("/tmp/webapp", flag_last.static_dir.?);
}

test "parse: bare --http2 means h2c, explicit off disables it" {
    var on: CliArgs = .{};
    defer freeParsed(testing.allocator, on);
    try ok(&.{"--http2"}, &on);
    try testing.expectEqual(true, on.enable_h2c);

    var off: CliArgs = .{};
    defer freeParsed(testing.allocator, off);
    try ok(&.{ "--http2", "off" }, &off);
    try testing.expectEqual(false, off.enable_h2c);

    var explicit: CliArgs = .{};
    defer freeParsed(testing.allocator, explicit);
    try ok(&.{ "--http2", "h2c" }, &explicit);
    try testing.expectEqual(true, explicit.enable_h2c);
}

test "parse: --http2 rejects an unknown mode and eats the next word" {
    try rejects(&.{ "--http2", "on" }, .invalid_http2_mode);
    // `--http2` unconditionally consumes the following word, so `--auth` after
    // it is read as the MODE, not as a flag. Pre-existing behaviour; pinned so
    // that making it "nicer" has to be a deliberate change.
    try rejects(&.{ "--http2", "--auth" }, .invalid_http2_mode);
}

test "parse: --http2's failure names the offending mode" {
    var out: CliArgs = .{};
    defer freeParsed(testing.allocator, out);
    const f = (try parse(testing.allocator, &.{ "--http2", "gRPC" }, &out)).?;
    try testing.expectEqualStrings("gRPC", f.value);
}

test "parse: --tls takes cert AND key, in that order" {
    const argv = [_][]const u8{ "--tls", "/tmp/cert.pem", "/tmp/key.pem" };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqualStrings("/tmp/cert.pem", args.tls_cert_path.?);
    try testing.expectEqualStrings("/tmp/key.pem", args.tls_key_path.?);
    try testing.expectEqual(false, args.tls_selfsigned);
}

test "parse: --tls with only one path fails instead of half-configuring TLS" {
    try rejects(&.{"--tls"}, .missing_tls_cert_path);
    var out: CliArgs = .{};
    defer freeParsed(testing.allocator, out);
    const f = (try parse(testing.allocator, &.{ "--tls", "/tmp/cert.pem" }, &out)).?;
    try testing.expectEqual(FailureKind.missing_tls_key_path, f.kind);
    // The message echoes the cert that WAS given, so the user can tell which
    // of two --tls flags was short.
    try testing.expectEqualStrings("/tmp/cert.pem", f.value);
}

test "parse: --tls-selfsigned and --auth are independent booleans" {
    const argv = [_][]const u8{ "--tls-selfsigned", "--auth" };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqual(true, args.tls_selfsigned);
    try testing.expectEqual(true, args.auth_enabled);
    try testing.expectEqual(@as(?[]const u8, null), args.tls_cert_path);
}

test "parse: --help stops scanning, so a bad flag to its right is never seen" {
    const argv = [_][]const u8{ "--auth", "--help", "--port", "abc" };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqual(true, args.help_requested);
    // `--auth` was scanned BEFORE the help flag, so it survives; the bad
    // `--port` after it is never reached.
    try testing.expectEqual(true, args.auth_enabled);
    try testing.expectEqual(@as(?u16, null), args.port);
}

test "parse: unknown arguments are ignored, not rejected" {
    const argv = [_][]const u8{ "--not-a-flag", "--auth", "stray", "--port", "8080" };
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&argv, &args);
    try testing.expectEqual(true, args.auth_enabled);
    try testing.expectEqual(@as(?u16, 8080), args.port);
}

test "parse: out is RESET between calls, so a second parse cannot inherit" {
    var args: CliArgs = .{};
    defer freeParsed(testing.allocator, args);
    try ok(&.{ "--auth", "--port", "9999" }, &args);
    try testing.expectEqual(true, args.auth_enabled);
    // Same `out` reused with a flag-free argv: nothing may leak across.
    try ok(&.{}, &args);
    try testing.expectEqual(false, args.auth_enabled);
    try testing.expectEqual(@as(?u16, null), args.port);
}
