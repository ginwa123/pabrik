//! `pabrik headless` — run the real backend with NO HTTP server and NO port.

const std = @import("std");

pub const args = @import("args.zig");
pub const boot = @import("boot.zig");
pub const run = @import("run.zig");
pub const sessions = @import("sessions.zig");

/// The subcommand to run, with its arguments already parsed. `help` is a
/// first-class variant rather than an error so `pabrik headless --help` exits
/// 0.
pub const Command = union(enum) {
    /// One agentic turn: send a message, wait for the assistant reply.
    run: args.RunArgs,
    /// List recent sessions.
    sessions: args.SessionsArgs,
    /// Print one session's messages.
    messages: args.MessagesArgs,
    /// Print the usage text.
    help,
    /// The argv was rejected; `failure` says why.
    invalid: args.Failure,
};

/// Parse `argv` (WITHOUT argv[0] and WITHOUT the leading `headless` word)
/// into a `Command`.
pub fn parseCommand(argv: []const []const u8) args.ParseError!Command {
    return switch (try args.parse(argv)) {
        .run => |a| .{ .run = a },
        .sessions => |a| .{ .sessions = a },
        .messages => |a| .{ .messages = a },
        .help => .help,
        .invalid => |f| .{ .invalid = f },
    };
}

test {
    _ = args;
    _ = boot;
    _ = run;
    _ = sessions;
}

test "parseCommand: maps every Outcome variant onto a Command" {
    try std.testing.expect((try parseCommand(&.{"help"})) == .help);
    try std.testing.expect((try parseCommand(&.{})).? == .help);
    const r = try parseCommand(&.{ "run", "hi" });
    try std.testing.expectEqualStrings("hi", r.run.message);
    const bad = try parseCommand(&.{"nope"});
    try std.testing.expect(bad == .invalid);
}
