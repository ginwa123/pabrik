//! `pabrik headless` — run the real backend with NO HTTP server and NO port.

const std = @import("std");

pub const args = @import("args.zig");
pub const boot = @import("boot.zig");
pub const run = @import("run.zig");
pub const sessions = @import("sessions.zig");
pub const documents = @import("documents.zig");
pub const storage = @import("storage.zig");
pub const usage = @import("usage.zig");
pub const group = @import("group.zig");

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
    /// Read or change document folders (Migration 140).
    documents: args.DocumentsArgs,
    usage: args.UsageArgs,
    /// Read or change a multi-agent session: its roster and who speaks next.
    group: args.GroupArgs,
    /// Read or write the object store (document bodies).
    storage: args.StorageArgs,
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
        .documents => |a| .{ .documents = a },
        .usage => |a| .{ .usage = a },
        .group => |a| .{ .group = a },
        .storage => |a| .{ .storage = a },
        .help => .help,
        .invalid => |f| .{ .invalid = f },
    };
}

test "parseCommand: maps every Outcome variant onto a Command" {
    try std.testing.expect((try parseCommand(&.{"help"})) == .help);
    try std.testing.expect((try parseCommand(&.{}) == .help));
    const r = try parseCommand(&.{ "run", "hi" });
    try std.testing.expectEqualStrings("hi", r.run.message);
    const bad = try parseCommand(&.{"nope"});
    const docs = try parseCommand(&.{ "documents", "list", "--workspace", "ws_1" });
    try std.testing.expect(docs == .documents);
    const usage_cmd = try parseCommand(&.{ "usage", "--workspace", "ws_1", "--range", "1d" });
    try std.testing.expectEqualStrings("1d", usage_cmd.usage.range);
    const store_cmd = try parseCommand(&.{ "storage", "get", "--key", "k.md" });
    try std.testing.expect(store_cmd == .storage);
    try std.testing.expectEqualStrings("k.md", store_cmd.storage.key);
    try std.testing.expect(bad == .invalid);
}
