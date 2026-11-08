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

/// The multi-agent session verbs. `next` answers the question the loop asks
/// once per iteration, so a caller can drive a group with no model in the
/// way.
pub const GroupOp = enum {
    create,
    join,
    leave,
    lead,
    members,
    next,
};

pub const GroupArgs = struct {
    op: GroupOp,
    session_id: []const u8 = "",
    /// The agent a `join`, `leave` or `lead` names.
    agent: []const u8 = "",
    /// `lead` or `worker`; anything else is read as a worker.
    role: []const u8 = "worker",
    /// Where in the roster this member sits. Null appends.
    position: ?u32 = null,
    /// Turns one human message may trigger. 0 = the built-in budget.
    budget: u32 = 0,
};

pub const UsageArgs = struct {
    workspace_id: []const u8 = "",
    range: []const u8 = "",
};

pub const MemoriesOp = enum {
    list,
    get,
    save,
    delete,
};

pub const MemoriesArgs = struct {
    op: MemoriesOp,
    workspace_id: []const u8 = "",
    id: []const u8 = "",
    content: []const u8 = "",
    tags: []const u8 = "",
    query: []const u8 = "",
    limit: []const u8 = "",
    offset: []const u8 = "",
};

/// The document-folder verbs. One subcommand per write the HTTP API exposes,
/// so an agent can drive the whole feature with no server and no port.
pub const DocumentsOp = enum {
    list,
    folder_create,
    folder_move,
    folder_rename,
    folder_delete,
    doc_create,
    doc_move,
};

pub const DocumentsArgs = struct {
    op: DocumentsOp,
    workspace_id: []const u8 = "",
    /// Folder name for `folder-create` / `folder-rename`.
    name: []const u8 = "",
    /// Parent folder for `folder-create` / `folder-move` / `doc-create` /
    /// `doc-move`. Null means the root.
    parent_id: ?[]const u8 = null,
    /// The folder being moved, renamed or deleted.
    folder_id: ?[]const u8 = null,
    /// The document being moved.
    document_id: ?[]const u8 = null,
    title: []const u8 = "",
};

/// The object-store verbs. One per `Storage` method, so an agent can exercise
/// the whole interface with no server and no bucket.
pub const StorageOp = enum {
    put,
    get,
    stat,
    delete,
};

pub const StorageArgs = struct {
    op: StorageOp,
    /// The object key. Relative, no traversal segments.
    key: []const u8 = "",
    /// The body for `put`, inline.
    body: []const u8 = "",
    /// The body for `put`, read from this file. Wins over `--body`.
    body_file: ?[]const u8 = null,
    /// Store root. Null falls back to `PABRIK_STORAGE_ROOT`, then `$HOME`.
    root: ?[]const u8 = null,
    /// Whether `--body` was passed at all. An empty body is a legitimate
    /// document, so "absent" and "empty" must stay distinguishable.
    body_given: bool = false,
};

/// Which flag was rejected. One variant per distinct user-facing message.
pub const FailureKind = enum {
    unknown_subcommand,
    missing_value,
    run_requires_message,
    invalid_number,
    messages_requires_session,
    documents_unknown_op,
    documents_requires_flag,
    group_unknown_op,
    group_requires_flag,
    usage_requires_flag,
    storage_unknown_op,
    storage_requires_flag,
    memories_unknown_op,
    memories_requires_flag,
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
    "  pabrik headless documents <op> [flags]    Read or change document folders\n" ++
    "      ops: list | folder-create | folder-move | folder-rename | folder-delete | doc-create | doc-move\n" ++
    "      flags: --workspace <id> --name <n> --parent <id> --folder <id> --document <id> --title <t>\n" ++
    "  pabrik headless group <op> [flags]       Read or change a multi-agent session\n" ++
    "      ops: create | join | leave | lead | members | next\n" ++
    "      flags: --session <id> --agent <n> --role lead|worker --position <n> --budget <n>\n" ++
    "  pabrik headless usage [flags]             Token, cache and tool totals for a workspace\n" ++
    "      flags: --workspace <id> --range 1d|7d|30d|90d\n" ++
    "  pabrik headless storage <op> [flags]      Read or write the object store\n" ++
    "      ops: put | get | stat | delete\n" ++
    "      flags: --key <k> --body <text> --body-file <path> --root <dir>\n" ++
    "  pabrik headless memories <op> [flags]     Read or change a workspace's saved memories\n" ++
    "      ops: list | get | save | delete\n" ++
    "      flags: --workspace <id> --id <mem_id> --content <text> --tags a,b --query <text> --limit <n> --offset <n>\n" ++
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
    documents: DocumentsArgs,
    group: GroupArgs,
    usage: UsageArgs,
    storage: StorageArgs,
    memories: MemoriesArgs,
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
    if (std.mem.eql(u8, verb, "documents")) return try parseDocuments(rest);
    if (std.mem.eql(u8, verb, "group")) return try parseGroup(rest);
    if (std.mem.eql(u8, verb, "usage")) return try parseUsage(rest);
    if (std.mem.eql(u8, verb, "storage")) return try parseStorage(rest);
    if (std.mem.eql(u8, verb, "memories")) return try parseMemories(rest);

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

/// `documents` parses its own tiny flag set: the shared table in
/// `cli/flags.zig` describes the server CLI, and these six flags exist only
/// here.
fn parseDocuments(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .documents_unknown_op });

    const op: DocumentsOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "list")) break :blk .list;
        if (std.mem.eql(u8, word, "folder-create")) break :blk .folder_create;
        if (std.mem.eql(u8, word, "folder-move")) break :blk .folder_move;
        if (std.mem.eql(u8, word, "folder-rename")) break :blk .folder_rename;
        if (std.mem.eql(u8, word, "folder-delete")) break :blk .folder_delete;
        if (std.mem.eql(u8, word, "doc-create")) break :blk .doc_create;
        if (std.mem.eql(u8, word, "doc-move")) break :blk .doc_move;
        return fail(.{ .kind = .documents_unknown_op, .value = word });
    };

    var got = DocumentsArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--workspace")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.workspace_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--name")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.name = argv[i];
        } else if (std.mem.eql(u8, flag, "--parent")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.parent_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--folder")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.folder_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--document")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.document_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--title")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.title = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    if (got.workspace_id.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--workspace" });
    switch (op) {
        .list, .folder_delete => {},
        .folder_create, .folder_rename => {
            if (got.name.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--name" });
            if (op == .folder_rename and got.folder_id == null) {
                return fail(.{ .kind = .documents_requires_flag, .value = "--folder" });
            }
        },
        .folder_move => {
            if (got.folder_id == null) return fail(.{ .kind = .documents_requires_flag, .value = "--folder" });
        },
        .doc_create => {
            if (got.title.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--title" });
        },
        .doc_move => {
            if (got.document_id == null) return fail(.{ .kind = .documents_requires_flag, .value = "--document" });
        },
    }

    return .{ .documents = got };
}

fn parseUsage(argv: []const []const u8) ParseError!Outcome {
    var got = UsageArgs{};
    var i: usize = 0;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--workspace")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.workspace_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--range")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.range = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }
    if (got.workspace_id.len == 0) return fail(.{ .kind = .usage_requires_flag, .value = "--workspace" });
    return .{ .usage = got };
}

/// `storage` parses its own flag set for the same reason `documents` does: the
/// shared table describes the server CLI, and these four flags exist only in
/// this verb.
fn parseStorage(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .storage_unknown_op });

    const op: StorageOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "put")) break :blk .put;
        if (std.mem.eql(u8, word, "get")) break :blk .get;
        if (std.mem.eql(u8, word, "stat")) break :blk .stat;
        if (std.mem.eql(u8, word, "delete")) break :blk .delete;
        return fail(.{ .kind = .storage_unknown_op, .value = word });
    };

    var got = StorageArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--key")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.key = argv[i];
        } else if (std.mem.eql(u8, flag, "--body")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.body = argv[i];
            got.body_given = true;
        } else if (std.mem.eql(u8, flag, "--body-file")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.body_file = argv[i];
            got.body_given = true;
        } else if (std.mem.eql(u8, flag, "--root")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.root = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    if (got.key.len == 0) return fail(.{ .kind = .storage_requires_flag, .value = "--key" });
    if (op == .put and !got.body_given) {
        return fail(.{ .kind = .storage_requires_flag, .value = "--body" });
    }

    return .{ .storage = got };
}

fn parseMemories(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .memories_unknown_op });

    const op: MemoriesOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "list")) break :blk .list;
        if (std.mem.eql(u8, word, "get")) break :blk .get;
        if (std.mem.eql(u8, word, "save")) break :blk .save;
        if (std.mem.eql(u8, word, "delete")) break :blk .delete;
        return fail(.{ .kind = .memories_unknown_op, .value = word });
    };

    var got = MemoriesArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--workspace")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.workspace_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--id")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.id = argv[i];
        } else if (std.mem.eql(u8, flag, "--content")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.content = argv[i];
        } else if (std.mem.eql(u8, flag, "--tags")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.tags = argv[i];
        } else if (std.mem.eql(u8, flag, "--query")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.query = argv[i];
        } else if (std.mem.eql(u8, flag, "--limit")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.limit = argv[i];
        } else if (std.mem.eql(u8, flag, "--offset")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.offset = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    if (got.workspace_id.len == 0) return fail(.{ .kind = .memories_requires_flag, .value = "--workspace" });
    switch (op) {
        .list => {},
        .get, .delete => {
            if (got.id.len == 0) return fail(.{ .kind = .memories_requires_flag, .value = "--id" });
        },
        .save => {
            if (got.content.len == 0) return fail(.{ .kind = .memories_requires_flag, .value = "--content" });
        },
    }

    return .{ .memories = got };
}

/// `group` parses its own flag set for the same reason `documents` does: the
/// shared table describes the server CLI, and these five flags exist only in
/// this verb.
fn parseGroup(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .group_unknown_op });

    const op: GroupOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "create")) break :blk .create;
        if (std.mem.eql(u8, word, "join")) break :blk .join;
        if (std.mem.eql(u8, word, "leave")) break :blk .leave;
        if (std.mem.eql(u8, word, "lead")) break :blk .lead;
        if (std.mem.eql(u8, word, "members")) break :blk .members;
        if (std.mem.eql(u8, word, "next")) break :blk .next;
        return fail(.{ .kind = .group_unknown_op, .value = word });
    };

    var got = GroupArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--session")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.session_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--agent")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.agent = argv[i];
        } else if (std.mem.eql(u8, flag, "--role")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.role = argv[i];
        } else if (std.mem.eql(u8, flag, "--position")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.position = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else if (std.mem.eql(u8, flag, "--budget")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.budget = std.fmt.parseInt(u32, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    if (op != .create and got.session_id.len == 0) {
        return fail(.{ .kind = .group_requires_flag, .value = "--session" });
    }
    switch (op) {
        .members, .next => {},
        .create, .join, .leave, .lead => {
            if (got.agent.len == 0) return fail(.{ .kind = .group_requires_flag, .value = "--agent" });
        },
    }

    return .{ .group = got };
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
        .documents_unknown_op => std.log.err("headless: unknown documents op '{s}'", .{f.value}),
        .documents_requires_flag => std.log.err("headless: documents needs {s}", .{f.value}),
        .group_unknown_op => std.log.err("headless: unknown group op '{s}'", .{f.value}),
        .group_requires_flag => std.log.err("headless: group needs {s}", .{f.value}),
        .usage_requires_flag => std.log.err("headless: usage needs {s}", .{f.value}),
        .storage_unknown_op => std.log.err("headless: unknown storage op '{s}'", .{f.value}),
        .storage_requires_flag => std.log.err("headless: storage needs {s}", .{f.value}),
        .memories_unknown_op => std.log.err("headless: unknown memories op '{s}'", .{f.value}),
        .memories_requires_flag => std.log.err("headless: memories needs {s}", .{f.value}),
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

test "parse: documents list needs only a workspace" {
    const a = try parse(&.{ "documents", "list", "--workspace", "ws_1" });
    try testing.expectEqual(DocumentsOp.list, a.documents.op);
    try testing.expectEqualStrings("ws_1", a.documents.workspace_id);
}

test "parse: documents folder-create reads the name and the parent" {
    const a = try parse(&.{ "documents", "folder-create", "--workspace", "ws_1", "--name", "Split bill", "--parent", "fld_1" });
    try testing.expectEqualStrings("Split bill", a.documents.name);
    try testing.expectEqualStrings("fld_1", a.documents.parent_id.?);
}

test "parse: documents refuses a write with no workspace" {
    try expectFailure(&.{ "documents", "folder-create", "--name", "x" }, .documents_requires_flag);
}

test "parse: documents refuses an unknown op by name" {
    try expectFailure(&.{ "documents", "folder-explode", "--workspace", "ws_1" }, .documents_unknown_op);
}

test "parse: documents doc-move needs the document id" {
    try expectFailure(&.{ "documents", "doc-move", "--workspace", "ws_1" }, .documents_requires_flag);
    const a = try parse(&.{ "documents", "doc-move", "--workspace", "ws_1", "--document", "doc_a", "--folder", "fld_1" });
    try testing.expectEqualStrings("doc_a", a.documents.document_id.?);
}

test "parse: usage reads the workspace and the range" {
    const a = try parse(&.{ "usage", "--workspace", "ws_1", "--range", "1d" });
    try testing.expectEqualStrings("ws_1", a.usage.workspace_id);
    try testing.expectEqualStrings("1d", a.usage.range);
}

test "parse: usage defaults to no range, so the endpoint's own default applies" {
    const a = try parse(&.{ "usage", "--workspace", "ws_1" });
    try testing.expectEqualStrings("", a.usage.range);
}

test "parse: usage refuses to guess which workspace was meant" {
    try expectFailure(&.{"usage"}, .usage_requires_flag);
    try expectFailure(&.{ "usage", "--range", "7d" }, .usage_requires_flag);
    try expectFailure(&.{ "usage", "--workspace" }, .missing_value);
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

test "parse: group create reads the lead agent and needs no session" {
    const a = try parse(&.{ "group", "create", "--agent", "Engineer", "--role", "lead" });
    try testing.expectEqual(GroupOp.create, a.group.op);
    try testing.expectEqualStrings("", a.group.session_id);
    try testing.expectEqualStrings("Engineer", a.group.agent);
}

test "parse: group create without an agent is refused by name" {
    try expectFailure(&.{ "group", "create" }, .group_requires_flag);
}

test "parse: group join reads the session, the agent and the role" {
    const a = try parse(&.{ "group", "join", "--session", "s_1", "--agent", "Engineer", "--role", "lead", "--position", "0" });
    try testing.expectEqual(GroupOp.join, a.group.op);
    try testing.expectEqualStrings("s_1", a.group.session_id);
    try testing.expectEqualStrings("Engineer", a.group.agent);
    try testing.expectEqualStrings("lead", a.group.role);
}

test "parse: group defaults the role to worker and the budget to the built-in one" {
    const a = try parse(&.{ "group", "join", "--session", "s_1", "--agent", "Engineer" });
    try testing.expectEqualStrings("worker", a.group.role);
    try testing.expectEqual(@as(u32, 0), a.group.budget);
}

test "parse: group members needs only a session" {
    const a = try parse(&.{ "group", "members", "--session", "s_1" });
    try testing.expectEqual(GroupOp.members, a.group.op);
    try testing.expectEqualStrings("s_1", a.group.session_id);
}

test "parse: group join without an agent is refused by name" {
    try expectFailure(&.{ "group", "join", "--session", "s_1" }, .group_requires_flag);
}

test "parse: group without a session is refused by name" {
    try expectFailure(&.{ "group", "members" }, .group_requires_flag);
}

test "parse: group refuses an unknown op by name" {
    try expectFailure(&.{ "group", "explode", "--session", "s_1" }, .group_unknown_op);
}

test "parse: group reads the hop budget" {
    const a = try parse(&.{ "group", "next", "--session", "s_1", "--budget", "3" });
    try testing.expectEqual(@as(u32, 3), a.group.budget);
    try expectFailure(&.{ "group", "next", "--session", "s_1", "--budget", "lots" }, .invalid_number);
}

test "parse: storage put reads the key and the inline body" {
    const a = try parse(&.{ "storage", "put", "--key", "ws/ws_1/documents/doc_a/abc.md", "--body", "# Plan" });
    try testing.expectEqual(StorageOp.put, a.storage.op);
    try testing.expectEqualStrings("ws/ws_1/documents/doc_a/abc.md", a.storage.key);
    try testing.expectEqualStrings("# Plan", a.storage.body);
    try testing.expect(a.storage.body_given);
}

test "parse: storage put accepts an empty body, which is a legitimate document" {
    const a = try parse(&.{ "storage", "put", "--key", "k.md", "--body", "" });
    try testing.expectEqualStrings("", a.storage.body);
    try testing.expect(a.storage.body_given);
}

test "parse: storage put refuses to run with no body at all" {
    try expectFailure(&.{ "storage", "put", "--key", "k.md" }, .storage_requires_flag);
}

test "parse: storage put reads a body file and marks the body as given" {
    const a = try parse(&.{ "storage", "put", "--key", "k.md", "--body-file", "/tmp/body.md" });
    try testing.expectEqualStrings("/tmp/body.md", a.storage.body_file.?);
    try testing.expect(a.storage.body_given);
}

test "parse: storage get, stat and delete need only a key" {
    inline for (.{ "get", "stat", "delete" }) |op| {
        const a = try parse(&.{ "storage", op, "--key", "k.md" });
        try testing.expectEqualStrings("k.md", a.storage.key);
        try testing.expect(!a.storage.body_given);
    }
}

test "parse: storage reads the root override" {
    const a = try parse(&.{ "storage", "get", "--key", "k.md", "--root", "/srv/objects" });
    try testing.expectEqualStrings("/srv/objects", a.storage.root.?);
}

test "parse: storage defaults the root to null so the environment decides" {
    const a = try parse(&.{ "storage", "get", "--key", "k.md" });
    try testing.expect(a.storage.root == null);
}

test "parse: storage refuses a write with no key" {
    try expectFailure(&.{ "storage", "put", "--body", "x" }, .storage_requires_flag);
    try expectFailure(&.{ "storage", "get" }, .storage_requires_flag);
}

test "parse: storage refuses an unknown op by name" {
    try expectFailure(&.{ "storage", "explode", "--key", "k.md" }, .storage_unknown_op);
    try expectFailure(&.{"storage"}, .storage_unknown_op);
}

test "parse: storage refuses a flag it does not own" {
    try expectFailure(&.{ "storage", "get", "--key", "k.md", "--workspace", "ws_1" }, .unknown_subcommand);
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
