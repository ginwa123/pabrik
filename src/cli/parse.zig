//! One argument parser for every flag in `flags.zig`. A caller names a scope
//! (and, for subcommands, a verb) and the struct to fill; the engine walks
//! argv, matches words against the table and writes through `@field`.

const std = @import("std");
const flags = @import("flags.zig");

pub const FailureKind = enum {
    /// A flag wanted more words than argv had left.
    missing_value,
    /// The word was there but the value did not convert (port, number, mode).
    invalid_value,
    /// A word this scope does not know. Only reachable when the scope is
    /// strict; the top-level scope ignores unknown words by design.
    unknown_flag,
};

pub const Failure = struct {
    kind: FailureKind,
    /// The flag word as the user typed it, dashes included.
    flag: []const u8 = "",
    /// The target field the failure belongs to, so the caller can pick the
    /// sentence: `port` and `static_dir` need different messages.
    field: []const u8 = "",
    /// The offending text: the bad value, or the last value consumed.
    value: []const u8 = "",
};

pub const Options = struct {
    scope: flags.Scope,
    /// The subcommand verb being parsed. Empty for a scope without verbs.
    verb: []const u8 = "",
    /// False = an unknown word is skipped (the top-level `pabrik` contract).
    reject_unknown: bool = true,
    /// True = copy text values, so the caller may free argv after parsing.
    dupe_text: bool = false,
};

const Cursor = struct {
    args: []const []const u8,
    i: usize = 0,
    stop: bool = false,
};

const ParseError = error{OutOfMemory};

/// Parse `args` (WITHOUT argv[0]) into `out`, which is reset first. Returns
/// the first failure, or null when everything matched. Bare words land in
/// `positionals` when a caller collects them.
pub fn parse(
    comptime T: type,
    comptime opts: Options,
    allocator: ?std.mem.Allocator,
    args: []const []const u8,
    out: *T,
    positionals: ?*std.ArrayList([]const u8),
) ParseError!?Failure {
    out.* = .{};
    var cursor = Cursor{ .args = args };
    while (cursor.i < args.len) : (cursor.i += 1) {
        const arg = args[cursor.i];
        var handled = false;
        inline for (flags.flags) |row| {
            if (comptime flags.hasScope(row, opts.scope) and flags.hasVerb(row, opts.verb)) {
                if (!handled and matches(row, arg)) {
                    handled = true;
                    if (try apply(T, row, &cursor, out, allocator, opts)) |failure| return failure;
                }
            }
        }
        if (!handled) {
            if (arg.len > 0 and arg[0] == '-') {
                if (opts.reject_unknown) return .{ .kind = .unknown_flag, .flag = arg, .value = arg };
            } else if (positionals) |list| {
                const list_allocator = allocator orelse @panic("positionals need an allocator");
                try list.append(list_allocator, arg);
            } else if (opts.reject_unknown) {
                return .{ .kind = .unknown_flag, .flag = arg, .value = arg };
            }
        }
        if (cursor.stop) return null;
    }
    return null;
}

/// A flag's long name takes two dashes and an alias takes one, so `-port` is
/// not `--port` — the same acceptance set the hand-written parsers had.
fn matches(comptime row: flags.Flag, arg: []const u8) bool {
    if (std.mem.startsWith(u8, arg, "--")) return std.mem.eql(u8, arg[2..], row.long);
    if (arg.len > 1 and arg[0] == '-') {
        inline for (row.aliases) |alias| {
            if (std.mem.eql(u8, arg[1..], alias)) return true;
        }
    }
    return false;
}

fn apply(
    comptime T: type,
    comptime row: flags.Flag,
    cursor: *Cursor,
    out: *T,
    allocator: ?std.mem.Allocator,
    comptime opts: Options,
) ParseError!?Failure {
    const word = cursor.args[cursor.i];
    switch (row.action) {
        .help => {
            setBool(T, out, row.fields[0], true);
            cursor.stop = true;
        },
        .set_true => setBool(T, out, row.fields[0], true),
        .set_false => setBool(T, out, row.fields[0], false),
        .store => {
            if (row.syntax == .optional_value) {
                if (cursor.i + 1 < cursor.args.len) {
                    const next = cursor.i + 1;
                    const mode = findMode(row, cursor.args[next]) orelse return .{
                        .kind = .invalid_value,
                        .flag = word,
                        .field = row.fields[0],
                        .value = cursor.args[next],
                    };
                    cursor.i = next;
                    setBool(T, out, row.fields[0], mode.on);
                } else {
                    setBool(T, out, row.fields[0], row.missing_mode);
                }
            } else {
                inline for (row.fields, 0..) |field, fi| {
                    if (cursor.i + 1 >= cursor.args.len) return .{
                        .kind = .missing_value,
                        .flag = word,
                        .field = field,
                        .value = if (fi > 0) cursor.args[cursor.i] else "",
                    };
                    cursor.i += 1;
                    const text = cursor.args[cursor.i];
                    assign(T, out, field, row.kind, text, allocator, opts.dupe_text) catch |err| switch (err) {
                        error.InvalidValue => return .{
                            .kind = .invalid_value,
                            .flag = word,
                            .field = field,
                            .value = text,
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                }
            }
        },
    }
    return null;
}

fn setBool(comptime T: type, out: *T, comptime field: []const u8, value: bool) void {
    @field(out.*, field) = value;
}

fn findMode(comptime row: flags.Flag, text: []const u8) ?flags.Mode {
    inline for (row.modes) |mode| {
        if (std.mem.eql(u8, mode.text, text)) return mode;
    }
    return null;
}

const AssignError = error{ InvalidValue, OutOfMemory };

fn assign(
    comptime T: type,
    out: *T,
    comptime field: []const u8,
    comptime kind: flags.Kind,
    text: []const u8,
    allocator: ?std.mem.Allocator,
    comptime dupe: bool,
) AssignError!void {
    const F = @TypeOf(@field(out.*, field));
    switch (@typeInfo(F)) {
        .optional => |o| @field(out.*, field) = try valueOf(o.child, kind, text, allocator, dupe),
        else => @field(out.*, field) = try valueOf(F, kind, text, allocator, dupe),
    }
}

fn valueOf(
    comptime Target: type,
    comptime kind: flags.Kind,
    text: []const u8,
    allocator: ?std.mem.Allocator,
    comptime dupe: bool,
) AssignError!Target {
    switch (@typeInfo(Target)) {
        .bool => return true,
        .int => return std.fmt.parseInt(Target, text, 10) catch error.InvalidValue,
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (dupe) {
                    const copy_allocator = allocator orelse @panic("dupe_text needs an allocator");
                    return try copy_allocator.dupe(u8, text);
                }
                return text;
            }
            @compileError("a " ++ @tagName(kind) ++ " flag stores into a pointer that is not a string slice");
        },
        else => @compileError("a " ++ @tagName(kind) ++ " flag stores into a target that is not a bool, an int or a string"),
    }
}

const testing = std.testing;

const GlobalProbe = struct {
    port: ?u16 = null,
    static_dir: ?[]const u8 = null,
    no_static_dir: bool = false,
    enable_h2c: bool = false,
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    tls_selfsigned: bool = false,
    auth_enabled: bool = false,
    saas: bool = false,
    help_requested: bool = false,
};

const ServiceProbe = struct {
    port: u16 = 8081,
    static_dir: ?[]const u8 = null,
    no_static_dir: bool = false,
    auth_enabled: bool = false,
    graceful_timeout_ms: u32 = 5000,
};

const global_opts: Options = .{ .scope = .global, .reject_unknown = false, .dupe_text = true };

fn freeGlobal(args: GlobalProbe) void {
    if (args.static_dir) |v| testing.allocator.free(v);
    if (args.tls_cert_path) |v| testing.allocator.free(v);
    if (args.tls_key_path) |v| testing.allocator.free(v);
}

fn parseGlobal(argv: []const []const u8, out: *GlobalProbe) !void {
    if (try parse(GlobalProbe, global_opts, testing.allocator, argv, out, null)) |f| {
        std.debug.print("\n!! expected {d}-arg argv to parse, got {s} on {s} !!\n", .{ argv.len, @tagName(f.kind), f.field });
        return error.UnexpectedParseFailure;
    }
}

test "a flag stores the word after it and leaves every other field alone" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&.{ "--port", "9090", "--auth" }, &got);
    try testing.expectEqual(@as(?u16, 9090), got.port);
    try testing.expect(got.auth_enabled);
    try testing.expect(!got.saas);
    try testing.expectEqual(@as(?[]const u8, null), got.static_dir);
}

test "a missing value names the flag, and a second value flag names its first field" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    const port = (try parse(GlobalProbe, global_opts, testing.allocator, &.{"--port"}, &got, null)).?;
    try testing.expectEqual(FailureKind.missing_value, port.kind);
    try testing.expectEqualStrings("--port", port.flag);
    try testing.expectEqualStrings("port", port.field);

    const tls = (try parse(GlobalProbe, global_opts, testing.allocator, &.{ "--tls", "/tmp/cert.pem" }, &got, null)).?;
    try testing.expectEqual(FailureKind.missing_value, tls.kind);
    try testing.expectEqualStrings("tls_key_path", tls.field);
    try testing.expectEqualStrings("/tmp/cert.pem", tls.value);
}

test "a value that does not convert is an invalid value carrying the text" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    const f = (try parse(GlobalProbe, global_opts, testing.allocator, &.{ "--port", "70000" }, &got, null)).?;
    try testing.expectEqual(FailureKind.invalid_value, f.kind);
    try testing.expectEqualStrings("70000", f.value);
    try testing.expectEqual(@as(?u16, null), got.port);
}

test "the last duplicate wins" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&.{ "--port", "8081", "--port", "9000" }, &got);
    try testing.expectEqual(@as(?u16, 9000), got.port);
}

test "an optional-value flag eats the next word even when it looks like a flag" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&.{"--http2"}, &got);
    try testing.expect(got.enable_h2c);

    var got_off: GlobalProbe = .{};
    defer freeGlobal(got_off);
    try parseGlobal(&.{ "--http2", "off" }, &got_off);
    try testing.expect(!got_off.enable_h2c);

    var got_eaten: GlobalProbe = .{};
    defer freeGlobal(got_eaten);
    const f = (try parse(GlobalProbe, global_opts, testing.allocator, &.{ "--http2", "--auth" }, &got_eaten, null)).?;
    try testing.expectEqual(FailureKind.invalid_value, f.kind);
    try testing.expectEqualStrings("--auth", f.value);
    try testing.expect(!got_eaten.auth_enabled);
}

test "a help flag stops the scan, so a bad flag to its right is never seen" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&.{ "--auth", "--help", "--port", "abc" }, &got);
    try testing.expect(got.help_requested);
    try testing.expect(got.auth_enabled);
    try testing.expectEqual(@as(?u16, null), got.port);
}

test "an alias is only accepted with one dash" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&.{"-h"}, &got);
    try testing.expect(got.help_requested);

    var single_dash: GlobalProbe = .{};
    defer freeGlobal(single_dash);
    try parseGlobal(&.{"-port"}, &single_dash);
    try testing.expectEqual(@as(?u16, null), single_dash.port);
}

test "a strict scope rejects an unknown word, a loose one ignores it" {
    var loose: GlobalProbe = .{};
    defer freeGlobal(loose);
    try parseGlobal(&.{ "--not-a-flag", "stray", "--auth" }, &loose);
    try testing.expect(loose.auth_enabled);

    var strict: ServiceProbe = .{};
    const f = (try parse(ServiceProbe, .{ .scope = .service, .verb = "start" }, testing.allocator, &.{ "--port", "9", "stray" }, &strict, null)).?;
    try testing.expectEqual(FailureKind.unknown_flag, f.kind);
    try testing.expectEqualStrings("stray", f.flag);
}

test "the verb decides which flags exist, so stop has no --static-dir" {
    var stop: ServiceProbe = .{};
    const rejected = (try parse(ServiceProbe, .{ .scope = .service, .verb = "stop" }, testing.allocator, &.{ "--static-dir", "/tmp" }, &stop, null)).?;
    try testing.expectEqual(FailureKind.unknown_flag, rejected.kind);

    var start: ServiceProbe = .{};
    try testing.expect((try parse(ServiceProbe, .{ .scope = .service, .verb = "start" }, testing.allocator, &.{ "--static-dir", "/tmp" }, &start, null)) == null);
    try testing.expectEqualStrings("/tmp", start.static_dir.?);
}

test "dupe_text copies the value so mutating argv does not change what was parsed" {
    var backing = [_]u8{ '/', 't', 'm', 'p' };
    const argv = [_][]const u8{ "--static-dir", &backing };
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    try parseGlobal(&argv, &got);
    backing[0] = 'X';
    try testing.expectEqualStrings("/tmp", got.static_dir.?);
}

test "bare words are collected in argv order when the caller wants them" {
    var got: GlobalProbe = .{};
    defer freeGlobal(got);
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(testing.allocator);
    const opts: Options = .{ .scope = .global, .reject_unknown = true };
    try testing.expect((try parse(GlobalProbe, opts, testing.allocator, &.{ "first", "--auth", "second" }, &got, &words)) == null);
    try testing.expectEqual(@as(usize, 2), words.items.len);
    try testing.expectEqualStrings("first", words.items[0]);
    try testing.expectEqualStrings("second", words.items[1]);
    try testing.expect(got.auth_enabled);
}
