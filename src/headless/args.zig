//! `pabrik headless` argument parsing. The flag names, the values they take
//! and the help text come from `cli/flags.zig`; this file only knows the
//! verbs, the positional words and how a parsed set becomes a `Command`.

const std = @import("std");
const cli_flags = @import("../cli/flags.zig");
const cli_parse = @import("../cli/parse.zig");

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

/// Every field a `headless` verb may set. The table decides which of them a
/// given verb accepts, so a field it cannot set stays at its default.
const Flags = struct {
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    allowed_tools: []const u8 = "",
    timeout_ms: u64 = 0,
    quiet: bool = false,
    limit: ?u32 = null,
    log_file: ?[]const u8 = null,
    help_requested: bool = false,
};

pub const HELP_TEXT = "pabrik headless — run the pabrik backend with no HTTP server and no port.\n" ++
    "\n" ++
    "Usage:\n" ++
    "  pabrik headless run <message> [flags]     One agentic turn; prints the reply as JSON\n" ++
    "  pabrik headless sessions [flags]          List recent sessions\n" ++
    "  pabrik headless messages <id> [flags]     Print one session's messages\n" ++
    "  pabrik headless help                      Show this help\n" ++
    "\n" ++
    "Flags for `run`:\n" ++
    cli_flags.usageBlock(.headless, "run") ++
    "\n" ++
    "Flags for `sessions` and `messages`:\n" ++
    cli_flags.usageBlock(.headless, "sessions") ++
    "\n" ++
    "Global flags:\n" ++
    cli_flags.globalUsageBlock(.headless) ++
    "\n" ++
    "Output: one JSON object on stdout. Diagnostics go to the log file, never stdout.\n";

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
    var got: Flags = .{};
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(std.heap.page_allocator);

    if (try parseFlags("run", argv, &got, &words)) |failure| return fail(translate(failure));

    // The first bare word is the message. A second one is a caller bug:
    // silently joining them would hide an unquoted message.
    if (words.items.len == 0) return fail(.{ .kind = .run_requires_message });
    if (words.items.len > 1) return fail(.{ .kind = .run_requires_message, .value = words.items[1] });

    return .{ .run = .{
        .message = words.items[0],
        .session_id = got.session_id,
        .cwd = got.cwd,
        .profile = got.profile,
        .allowed_tools = got.allowed_tools,
        .timeout_ms = got.timeout_ms,
        .quiet = got.quiet,
    } };
}

fn parseSessions(argv: []const []const u8) ParseError!Outcome {
    var got: Flags = .{};
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(std.heap.page_allocator);

    if (try parseFlags("sessions", argv, &got, &words)) |failure| return fail(translate(failure));
    if (words.items.len > 0) return fail(.{ .kind = .unknown_subcommand, .value = words.items[0] });
    return .{ .sessions = .{ .limit = got.limit orelse 20 } };
}

fn parseMessages(argv: []const []const u8) ParseError!Outcome {
    var got: Flags = .{};
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(std.heap.page_allocator);

    if (try parseFlags("messages", argv, &got, &words)) |failure| return fail(translate(failure));
    if (words.items.len == 0) return fail(.{ .kind = .messages_requires_session });
    if (words.items.len > 1) return fail(.{ .kind = .unknown_subcommand, .value = words.items[1] });
    return .{ .messages = .{ .session_id = words.items[0], .limit = got.limit orelse 50 } };
}

/// Run the one engine over `verb`'s flags, collecting the bare words.
fn parseFlags(
    comptime verb: []const u8,
    argv: []const []const u8,
    out: *Flags,
    words: *std.ArrayList([]const u8),
) ParseError!?cli_parse.Failure {
    const opts: cli_parse.Options = .{ .scope = .headless, .verb = verb };
    return cli_parse.parse(Flags, opts, std.heap.page_allocator, argv, out, words);
}

/// The engine's vocabulary mapped onto headless's own messages.
fn translate(failure: cli_parse.Failure) Failure {
    return switch (failure.kind) {
        .missing_value => .{ .kind = .missing_value, .value = failure.flag },
        .invalid_value => .{ .kind = .invalid_number, .value = failure.value },
        .unknown_flag => .{ .kind = .unknown_subcommand, .value = failure.flag },
    };
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

test "parse: a flag another verb owns is rejected, not silently ignored" {
    try expectFailure(&.{ "sessions", "--quiet" }, .unknown_subcommand);
    try expectFailure(&.{ "run", "hi", "--limit", "3" }, .unknown_subcommand);
}

test "the help text lists every flag the table gives this scope" {
    inline for (cli_flags.flags) |f| {
        if (comptime cli_flags.hasScope(f, .headless)) {
            var dashed_buf: [64]u8 = undefined;
            const dashed = try std.fmt.bufPrint(&dashed_buf, "--{s}", .{f.long});
            try testing.expect(std.mem.indexOf(u8, HELP_TEXT, dashed) != null);
        }
    }
}
