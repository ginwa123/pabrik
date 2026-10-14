//! `pabrik headless` argument parsing.

const std = @import("std");

pub const RunArgs = struct {
    /// The user's message. Required — a turn with nothing to say is a
    /// caller bug, not a default.
    message: []const u8,
    /// Resume this session instead of minting a new one.
    session_id: ?[]const u8 = null,
    /// Working directory for the turn. Defaults to the process cwd.
    cwd: ?[]const u8 = null,
    /// Profile name from `config.json`'s `profiles_models`.
    profile: ?[]const u8 = null,
    /// Comma-separated tool allowlist. Empty = the config default.
    allowed_tools: []const u8 = "",
    /// Wall-clock budget for the whole turn, in milliseconds.
    /// 0 = no budget (wait forever).
    timeout_ms: u64 = 0,
    /// Print the assistant's text only, not the JSON envelope.
    quiet: bool = false,
};

pub const SessionsArgs = struct {
    limit: u32 = 20,
};

pub const MessagesArgs = struct {
    session_id: []const u8,
    limit: u32 = 50,
};

/// Which flag was rejected. One variant per distinct user-facing message.
pub const FailureKind = enum {
    unknown_subcommand,
    missing_value,
    run_requires_message,
    invalid_number,
    messages_requires_session,
};

pub const Failure = struct {
    kind: FailureKind,
    /// The offending word — the unknown subcommand, or the flag whose
    /// value was missing. Empty when nothing names it.
    value: []const u8 = "",
};

pub const ParseError = error{OutOfMemory};

pub const HELP_TEXT =
    \\pabrik headless — run the pabrik backend with no HTTP server and no port.
    \\
    \\Usage:
    \\  pabrik headless run <message> [flags]     One agentic turn; prints the reply as JSON
    \\  pabrik headless sessions [--limit N]      List recent sessions
    \\  pabrik headless messages <id> [--limit N] Print one session's messages
    \\  pabrik headless help                      Show this help
    \\
    \\Flags for `run`:
    \\  --session <id>       Resume an existing session (default: mint a new one)
    \\  --cwd <dir>          Working directory for the turn (default: process cwd)
    \\  --profile <name>     LLM profile from config.json's profiles_models
    \\  --tools <a,b,c>      Comma-separated tool allowlist (default: config default)
    \\  --timeout-ms <n>     Wall-clock budget for the turn (default: no budget)
    \\  --quiet              Print the assistant text only, not the JSON envelope
    \\
    \\Global flags:
    \\  --log-file <path>    Where diagnostics go (default: $TMPDIR/agentic_coding.log)
    \\  --json               Force the JSON envelope even with --quiet
    \\
    \\Output: one JSON object on stdout. Diagnostics go to the log file, never stdout.
    \\
;

/// What `parse` produced: exactly one of the two fields is non-null.
/// `mod.zig` turns this into the `Command` union.
pub const Outcome = union(enum) {
    run: RunArgs,
    sessions: SessionsArgs,
    messages: MessagesArgs,
    help,
    /// Nothing parsed; `failure` says why.
    invalid: Failure,
};

/// Parse `argv` (WITHOUT argv[0] and WITHOUT the leading `headless` word).
/// Never returns an error union for bad input — the `invalid` payload carries
/// what was rejected so the caller decides how loudly to report it.
pub fn parse(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return .help;

    const verb = argv[0];
    const rest = argv[1..];

    // `--help` / `-h` anywhere wins, matching the top-level parser's
    // "help stops scanning" contract.
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
    }

    if (std.mem.eql(u8, verb, "help")) return .help;
    if (std.mem.eql(u8, verb, "run")) return try parseRun(rest);
    if (std.mem.eql(u8, verb, "sessions")) return try parseSessions(rest);
    if (std.mem.eql(u8, verb, "messages")) return try parseMessages(rest);

    return .{ .invalid = .{ .kind = .unknown_subcommand, .value = verb } };
}

fn parseRun(argv: []const []const u8) ParseError!Outcome {
    var out: RunArgs = .{ .message = "" };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--session" });
            out.session_id = argv[i];
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--cwd" });
            out.cwd = argv[i];
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--profile" });
            out.profile = argv[i];
        } else if (std.mem.eql(u8, a, "--tools")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--tools" });
            out.allowed_tools = argv[i];
        } else if (std.mem.eql(u8, a, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--timeout-ms" });
            out.timeout_ms = std.fmt.parseInt(u64, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else if (std.mem.eql(u8, a, "--quiet")) {
            out.quiet = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            out.quiet = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return fail(.{ .kind = .unknown_subcommand, .value = a });
        } else if (out.message.len == 0) {
            // The first bare word is the message. Everything after it is
            // appended, so an unquoted multi-word message still works.
            out.message = a;
        } else {
            return fail(.{ .kind = .run_requires_message, .value = a });
        }
    }
    if (out.message.len == 0) return fail(.{ .kind = .run_requires_message });
    return .{ .run = out };
}

fn parseSessions(argv: []const []const u8) ParseError!Outcome {
    var out: SessionsArgs = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--limit" });
            out.limit = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = a });
        }
    }
    return .{ .sessions = out };
}

fn parseMessages(argv: []const []const u8) ParseError!Outcome {
    var out: ?[]const u8 = null;
    var limit: u32 = 50;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = "--limit" });
            limit = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else if (std.mem.startsWith(u8, a, "-")) {
            return fail(.{ .kind = .unknown_subcommand, .value = a });
        } else if (out == null) {
            out = a;
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = a });
        }
    }
    const sid = out orelse return fail(.{ .kind = .messages_requires_session });
    return .{ .messages = .{ .session_id = sid, .limit = limit } };
}

fn fail(f: Failure) Outcome {
    return .{ .invalid = f };
}

/// Print the user-facing message for a `Failure`. Kept out of `parse` so
/// the parser stays pure.
pub fn reportFailure(f: Failure) void {
    switch (f.kind) {
        .unknown_subcommand => std.log.err("headless: unknown subcommand or flag '{s}'", .{f.value}),
        .missing_value => std.log.err("headless: {s} requires a value", .{f.value}),
        .run_requires_message => std.log.err("headless: run requires a message: pabrik headless run <message>", .{}),
        .invalid_number => std.log.err("headless: '{s}' is not a number", .{f.value}),
        .messages_requires_session => std.log.err("headless: messages requires a session id: pabrik headless messages <id>", .{}),
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn okRun(argv: []const []const u8) !RunArgs {
    return switch (try parse(argv)) {
        .run => |a| a,
        else => return error.UnexpectedOutcome,
    };
}

fn expectFailure(argv: []const []const u8, kind: FailureKind) !void {
    switch (try parse(argv)) {
        .invalid => |f| try testing.expectEqual(kind, f.kind),
        else => return error.ExpectedFailure,
    }
}

test "parse: bare invocation prints help" {
    try testing.expect((try parse(&.{})) == .help);
}

test "parse: help verb and --help both yield help" {
    for ([_][]const []const u8{ &.{"help"}, &.{"--help"}, &.{"-h"}, &.{ "run", "--help" } }) |argv| {
        try testing.expect((try parse(argv)) == .help);
    }
}

test "parse: run takes the first bare word as the message" {
    const a = try okRun(&.{ "run", "fix" });
    try testing.expectEqualStrings("fix", a.message);
}

test "parse: run rejects a second bare word rather than silently joining" {
    // Deliberate: an unquoted multi-word message is a caller bug, and
    // silently concatenating would hide it. The shell is responsible for
    // quoting — `headless run "fix the bug"` arrives as ONE argv entry.
    try expectFailure(&.{ "run", "fix", "the", "bug" }, .run_requires_message);
}

test "parse: run reads every flag" {
    const a = try okRun(&.{ "run", "hello", "--session", "s1", "--cwd", "/tmp", "--profile", "p", "--tools", "bash,glob", "--timeout-ms", "5000", "--quiet" });
    try testing.expectEqualStrings("hello", a.message);
    try testing.expectEqualStrings("s1", a.session_id.?);
    try testing.expectEqualStrings("/tmp", a.cwd.?);
    try testing.expectEqualStrings("p", a.profile.?);
    try testing.expectEqualStrings("bash,glob", a.allowed_tools);
    try testing.expectEqual(@as(u64, 5000), a.timeout_ms);
    try testing.expect(a.quiet);
}

test "parse: run without a message fails" {
    try expectFailure(&.{"run"}, .run_requires_message);
    try expectFailure(&.{ "run", "--quiet" }, .run_requires_message);
}

test "parse: run rejects a flag with no value" {
    try expectFailure(&.{ "run", "hi", "--session" }, .missing_value);
    try expectFailure(&.{ "run", "hi", "--timeout-ms" }, .missing_value);
}

test "parse: run rejects a non-numeric --timeout-ms" {
    try expectFailure(&.{ "run", "hi", "--timeout-ms", "soon" }, .invalid_number);
}

test "parse: run rejects an unknown flag" {
    try expectFailure(&.{ "run", "hi", "--nope" }, .unknown_subcommand);
}

test "parse: --json cancels --quiet" {
    const a = try okRun(&.{ "run", "hi", "--quiet", "--json" });
    try testing.expect(!a.quiet);
}

test "parse: sessions defaults to limit 20 and reads --limit" {
    try testing.expectEqual(@as(u32, 20), (try parse(&.{"sessions"})).sessions.limit);
    try testing.expectEqual(@as(u32, 5), (try parse(&.{ "sessions", "--limit", "5" })).sessions.limit);
}

test "parse: sessions rejects a bad --limit" {
    try expectFailure(&.{ "sessions", "--limit", "lots" }, .invalid_number);
    try expectFailure(&.{ "sessions", "--limit" }, .missing_value);
}

test "parse: messages requires a session id" {
    try expectFailure(&.{"messages"}, .messages_requires_session);
    const r = try parse(&.{ "messages", "sess_1" });
    try testing.expectEqualStrings("sess_1", r.messages.session_id);
    try testing.expectEqual(@as(u32, 50), r.messages.limit);
}

test "parse: messages reads --limit" {
    const r = try parse(&.{ "messages", "sess_1", "--limit", "3" });
    try testing.expectEqual(@as(u32, 3), r.messages.limit);
}

test "parse: an unknown verb is reported by name" {
    switch (try parse(&.{"frobnicate"})) {
        .invalid => |f| try testing.expectEqualStrings("frobnicate", f.value),
        else => return error.ExpectedFailure,
    }
}
