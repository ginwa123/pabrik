//! CLI command dispatch. Each command lives in its own submodule and is
//! re-exported here so the CLI's `main.zig` can call `commands.run(...)`
//! without reaching into the subdirectory.

const std = @import("std");
const config = @import("../config.zig");

pub const send = @import("send.zig");
pub const sessions = @import("sessions.zig");
pub const messages = @import("messages.zig");
pub const events = @import("events.zig");
pub const pr_status = @import("pr_status.zig");

pub const CommandKind = enum {
    send,
    sessions,
    messages,
    events,
    pr_status,
    help,
};

/// Result of running a command.
pub const DispatchResult = enum {
    ok,
    err,
};

/// Parsed CLI command. `args` is a borrowed slice into the
/// `argv` scratch buffer; the caller is responsible for keeping
/// it alive.
pub const Command = struct {
    kind: CommandKind,
    args: []const []const u8,
};

/// Help text shown for `pabrikcli help` (or any unknown verb).
pub const help_text =
    \\pabrikcli — wraps the pabrik backend HTTP API.
    \\
    \\Usage:
    \\  pabrikcli <command> [args...]
    \\
    \\Commands:
    \\  send <message> [--session <id>] [--profile <name>]    Send a message to an LLM session
    \\  sessions [--limit <n>]                                List LLM sessions
    \\  messages <session_id> [--limit <n>] [--reverse]       List messages in a session
    \\  events [--channels <a,b,c>]                           Tail the SSE event stream
    \\  pr-status [<pr>] [--path <repo>] [--provider <n>] [--json]  Show PR open/merged/closed status
    \\  help                                                  Show this help
    \\
    \\Config (highest priority first):
    \\  --server <url>     Server URL (default http://localhost:8081)
    \\  --session <id>     Default session id
    \\  --profile <name>   LLM profile
    \\  env PABRIKCLI_SERVER, PABRIKCLI_SESSION_ID, PABRIKCLI_PROFILE
    \\
;

/// Dispatch a parsed command to its subcommand. Returns `.ok` on success,
/// `.err` on a fatal failure (network down, parse error, non-2xx, etc.).
pub fn dispatch(cmd: Command, cfg: config.Config, io: std.Io) DispatchResult {
    switch (cmd.kind) {
        .help => {
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            stdout_writer.interface.writeAll(help_text) catch return .err;
            stdout_writer.interface.flush() catch return .err;
            return .ok;
        },
        .send => {
            const parsed = parseSendArgs(cmd.args) catch return .err;
            return send.run(parsed, cfg, io);
        },
        .sessions => {
            const parsed = parseSessionsArgs(cmd.args) catch return .err;
            return sessions.run(parsed, cfg, io);
        },
        .messages => {
            const parsed = parseMessagesArgs(cmd.args) catch return .err;
            return messages.run(parsed, cfg, io);
        },
        .events => {
            const parsed = parseEventsArgs(cmd.args) catch return .err;
            return events.run(parsed, cfg, io);
        },
        .pr_status => {
            const parsed = parsePrStatusArgs(cmd.args) catch return .err;
            return pr_status.run(parsed, cfg, io);
        },
    }
}

fn parseSendArgs(args: []const []const u8) !send.Args {
    var out: send.Args = .{ .message = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--session")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.session_id = args[i];
        } else if (std.mem.eql(u8, a, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.profile = args[i];
        } else if (std.mem.eql(u8, a, "--allowed-tools")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.allowed_tools = args[i];
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.cwd = args[i];
        } else if (std.mem.eql(u8, a, "--auto-retry")) {
            out.auto_retry = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (out.message.len == 0) {
            out.message = a;
        } else {
            // Treat additional positional args as appended message text
            // (space-separated). The simplest correct behaviour.
            const old_len = out.message.len;
            const new_buf = std.heap.page_allocator.alloc(u8, old_len + 1 + a.len) catch return error.OutOfMemory;
            @memcpy(new_buf[0..old_len], out.message);
            new_buf[old_len] = ' ';
            @memcpy(new_buf[old_len + 1 ..][0..a.len], a);
            out.message = new_buf;
        }
    }
    if (out.message.len == 0) return error.MissingMessage;
    return out;
}

fn parseSessionsArgs(args: []const []const u8) !sessions.Args {
    var out: sessions.Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.limit = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else {
            return error.UnknownPositional;
        }
    }
    return out;
}

fn parseMessagesArgs(args: []const []const u8) !messages.Args {
    var out: messages.Args = .{ .session_id = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.limit = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, a, "--reverse")) {
            out.reverse = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (out.session_id.len == 0) {
            out.session_id = a;
        } else {
            return error.UnknownPositional;
        }
    }
    if (out.session_id.len == 0) return error.MissingSessionId;
    return out;
}

fn parseEventsArgs(args: []const []const u8) !events.Args {
    var out: events.Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--channels")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.channels = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else {
            return error.UnknownPositional;
        }
    }
    return out;
}

fn parsePrStatusArgs(args: []const []const u8) !pr_status.Args {
    var out: pr_status.Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--path")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.path = args[i];
        } else if (std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.provider = args[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (out.pr.len == 0) {
            out.pr = a;
        } else {
            return error.UnknownPositional;
        }
    }
    return out;
}

/// Parse the command from argv (excluding the program name). The
/// `scratch` buffer is used for in-place lower-casing the verb so
/// we don't need to allocate.
pub fn parseCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    scratch: []u8,
) !Command {
    if (argv.len == 0) return .{ .kind = .help, .args = &.{} };
    const verb = argv[0];

    // Case-insensitive compare against a small allow-list.
    const OwnedLower = struct {
        slice: []const u8,
        owns: bool,
    };
    var owned: OwnedLower = undefined;
    if (verb.len <= scratch.len) {
        for (verb, 0..) |ch, i| scratch[i] = std.ascii.toLower(ch);
        owned = .{ .slice = scratch[0..verb.len], .owns = false };
    } else {
        const dup = try allocator.alloc(u8, verb.len);
        for (verb, 0..) |ch, i| dup[i] = std.ascii.toLower(ch);
        owned = .{ .slice = dup, .owns = true };
    }
    defer if (owned.owns) allocator.free(@constCast(owned.slice));

    const lower = owned.slice;
    if (std.mem.eql(u8, lower, "send")) {
        return .{ .kind = .send, .args = argv[1..] };
    } else if (std.mem.eql(u8, lower, "sessions")) {
        return .{ .kind = .sessions, .args = argv[1..] };
    } else if (std.mem.eql(u8, lower, "messages")) {
        return .{ .kind = .messages, .args = argv[1..] };
    } else if (std.mem.eql(u8, lower, "events")) {
        return .{ .kind = .events, .args = argv[1..] };
    } else if (std.mem.eql(u8, lower, "pr-status") or std.mem.eql(u8, lower, "pr")) {
        return .{ .kind = .pr_status, .args = argv[1..] };
    } else if (std.mem.eql(u8, lower, "help") or std.mem.eql(u8, lower, "--help") or std.mem.eql(u8, lower, "-h")) {
        return .{ .kind = .help, .args = &.{} };
    } else {
        return .{ .kind = .help, .args = argv[0..] };
    }
}

test "parseCommand: empty argv → help" {
    var scratch: [256]u8 = undefined;
    const cmd = try parseCommand(testing.allocator, &.{}, &scratch);
    try testing.expectEqual(CommandKind.help, cmd.kind);
}

test "parseCommand: send → CommandKind.send" {
    var scratch: [256]u8 = undefined;
    const args = [_][]const u8{ "send", "hello" };
    const cmd = try parseCommand(testing.allocator, &args, &scratch);
    try testing.expectEqual(CommandKind.send, cmd.kind);
    try testing.expectEqual(@as(usize, 1), cmd.args.len);
}

test "parseCommand: unknown verb → help (with bad tail)" {
    var scratch: [256]u8 = undefined;
    const args = [_][]const u8{ "frobnicate", "xyz" };
    const cmd = try parseCommand(testing.allocator, &args, &scratch);
    try testing.expectEqual(CommandKind.help, cmd.kind);
    try testing.expectEqual(@as(usize, 2), cmd.args.len);
}

test "parseCommand: case-insensitive" {
    var scratch: [256]u8 = undefined;
    const args = [_][]const u8{ "SEND", "hello" };
    const cmd = try parseCommand(testing.allocator, &args, &scratch);
    try testing.expectEqual(CommandKind.send, cmd.kind);
}

// ============================================================================
// parseXxxArgs tests — behavioural coverage of each subcommand's flag parser.
// ============================================================================

test "parseSendArgs: minimal message" {
    const args = [_][]const u8{ "hello" };
    const parsed = try parseSendArgs(&args);
    try testing.expectEqualStrings("hello", parsed.message);
    try testing.expect(parsed.session_id == null);
    try testing.expectEqualStrings("all", parsed.allowed_tools);
}

test "parseSendArgs: full flag set" {
    const args = [_][]const u8{ "hello", "--session", "s1", "--profile", "p1", "--cwd", "/tmp", "--auto-retry" };
    const parsed = try parseSendArgs(&args);
    try testing.expectEqualStrings("hello", parsed.message);
    try testing.expectEqualStrings("s1", parsed.session_id.?);
    try testing.expectEqualStrings("p1", parsed.profile.?);
    try testing.expectEqualStrings("/tmp", parsed.cwd);
    try testing.expect(parsed.auto_retry);
}

test "parseSendArgs: extra positionals joined with spaces" {
    const args = [_][]const u8{ "hello", "world", "from", "cli" };
    const parsed = try parseSendArgs(&args);
    try testing.expectEqualStrings("hello world from cli", parsed.message);
}

test "parseSendArgs: missing message → error.MissingMessage" {
    const args = [_][]const u8{};
    try testing.expectError(error.MissingMessage, parseSendArgs(&args));
}

test "parseSendArgs: unknown flag → error.UnknownFlag" {
    const args = [_][]const u8{ "hi", "--wat" };
    try testing.expectError(error.UnknownFlag, parseSendArgs(&args));
}

test "parseSendArgs: missing value after flag → error.MissingValue" {
    const args = [_][]const u8{ "hi", "--session" };
    try testing.expectError(error.MissingValue, parseSendArgs(&args));
}

test "parseSessionsArgs: defaults" {
    const args = [_][]const u8{};
    const parsed = try parseSessionsArgs(&args);
    try testing.expectEqual(@as(u32, 50), parsed.limit);
}

test "parseSessionsArgs: --limit 100" {
    const args = [_][]const u8{ "--limit", "100" };
    const parsed = try parseSessionsArgs(&args);
    try testing.expectEqual(@as(u32, 100), parsed.limit);
}

test "parseSessionsArgs: unknown positional → error.UnknownPositional" {
    const args = [_][]const u8{ "wat" };
    try testing.expectError(error.UnknownPositional, parseSessionsArgs(&args));
}

test "parseSessionsArgs: --limit abc → error.InvalidNumber" {
    const args = [_][]const u8{ "--limit", "abc" };
    try testing.expectError(error.InvalidNumber, parseSessionsArgs(&args));
}

test "parseMessagesArgs: positional session_id" {
    const args = [_][]const u8{ "session-abc" };
    const parsed = try parseMessagesArgs(&args);
    try testing.expectEqualStrings("session-abc", parsed.session_id);
    try testing.expectEqual(@as(u32, 100), parsed.limit);
    try testing.expect(!parsed.reverse);
}

test "parseMessagesArgs: with --reverse" {
    const args = [_][]const u8{ "session-abc", "--reverse", "--limit", "5" };
    const parsed = try parseMessagesArgs(&args);
    try testing.expectEqualStrings("session-abc", parsed.session_id);
    try testing.expectEqual(@as(u32, 5), parsed.limit);
    try testing.expect(parsed.reverse);
}

test "parseMessagesArgs: missing session_id → error.MissingSessionId" {
    const args = [_][]const u8{ "--reverse" };
    try testing.expectError(error.MissingSessionId, parseMessagesArgs(&args));
}

test "parseEventsArgs: default channels" {
    const args = [_][]const u8{};
    const parsed = try parseEventsArgs(&args);
    try testing.expectEqualStrings(
        "workers,sessions,kanban,design_element,llm,queue",
        parsed.channels,
    );
}

test "parseEventsArgs: --channels workers,llm" {
    const args = [_][]const u8{ "--channels", "workers,llm" };
    const parsed = try parseEventsArgs(&args);
    try testing.expectEqualStrings("workers,llm", parsed.channels);
}

test "parseEventsArgs: unknown flag → error.UnknownFlag" {
    const args = [_][]const u8{ "--wat" };
    try testing.expectError(error.UnknownFlag, parseEventsArgs(&args));
}

test "parseCommand: pr-status → CommandKind.pr_status" {
    var scratch: [256]u8 = undefined;
    const args = [_][]const u8{ "pr-status", "42" };
    const cmd = try parseCommand(testing.allocator, &args, &scratch);
    try testing.expectEqual(CommandKind.pr_status, cmd.kind);
    try testing.expectEqual(@as(usize, 1), cmd.args.len);
}

test "parseCommand: pr alias → CommandKind.pr_status" {
    var scratch: [256]u8 = undefined;
    const args = [_][]const u8{ "pr", "42" };
    const cmd = try parseCommand(testing.allocator, &args, &scratch);
    try testing.expectEqual(CommandKind.pr_status, cmd.kind);
}

test "parsePrStatusArgs: defaults (current branch)" {
    const args = [_][]const u8{};
    const parsed = try parsePrStatusArgs(&args);
    try testing.expectEqualStrings("", parsed.pr);
    try testing.expectEqualStrings(".", parsed.path);
    try testing.expect(!parsed.json);
}

test "parsePrStatusArgs: full flag set" {
    const args = [_][]const u8{ "42", "--path", "/tmp/repo", "--provider", "github", "--json" };
    const parsed = try parsePrStatusArgs(&args);
    try testing.expectEqualStrings("42", parsed.pr);
    try testing.expectEqualStrings("/tmp/repo", parsed.path);
    try testing.expectEqualStrings("github", parsed.provider.?);
    try testing.expect(parsed.json);
}

test "parsePrStatusArgs: unknown flag → error.UnknownFlag" {
    const args = [_][]const u8{ "--wat" };
    try testing.expectError(error.UnknownFlag, parsePrStatusArgs(&args));
}

test "parsePrStatusArgs: second positional → error.UnknownPositional" {
    const args = [_][]const u8{ "42", "43" };
    try testing.expectError(error.UnknownPositional, parsePrStatusArgs(&args));
}

const testing = std.testing;
