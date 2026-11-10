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
    delegate,
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
    /// What a `delegate` asks the named agent.
    message: []const u8 = "",
};

pub const UsageArgs = struct {
    workspace_id: []const u8 = "",
    range: []const u8 = "",
};

pub const McpOAuthOp = enum {
    discover,
    authorize_url,
    exchange,
    status,
    refresh,
    logout,
};

pub const McpOAuthArgs = struct {
    op: McpOAuthOp,
    url: []const u8 = "",
    workspace_id: []const u8 = "",
    server_name: []const u8 = "",
    redirect_uri: []const u8 = "http://127.0.0.1:0/callback",
    scope: []const u8 = "",
    client_id: []const u8 = "",
    code: []const u8 = "",
    state: []const u8 = "",
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
    search,
    folder_create,
    folder_move,
    folder_rename,
    folder_delete,
    doc_create,
    doc_move,
    /// `document_markdown` with `action: "create"`, through the real agent
    /// tool dispatch, so the body's round trip through the object store is
    /// exercised with no server.
    doc_add,
    /// `document_markdown` with `action: "edit"`, through the same dispatch.
    doc_edit,
    /// `document_markdown` with `action: "delete"`, through the same dispatch.
    doc_delete,
    /// `document_markdown` with `action: "search"`, through the same dispatch.
    doc_search,
    /// `document_html` with `action: "create"`, through the real agent tool
    /// dispatch, so the HTML page's round trip is exercised with no server.
    doc_html_add,
    /// `document_html` with `action: "edit"`, through the same dispatch.
    doc_html_edit,
    /// `document_html` with `action: "read"`, through the same dispatch.
    doc_html_read,
    /// Read one document back, body included.
    doc_get,
    /// Write one document, or a zip of several, to a file — the same bytes the
    /// HTTP export endpoints return.
    export_file,
    backfill,
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
    /// The document being moved, edited or read.
    document_id: ?[]const u8 = null,
    title: []const u8 = "",
    /// `doc-create` / `doc-add` / `doc-edit`: the body. Markdown text, or a
    /// Univer snapshot JSON when `format` is `office`.
    content: []const u8 = "",
    /// `doc-create`: `markdown` (the default) or `office`.
    format: []const u8 = "",
    /// `doc-add` / `doc-edit` / `doc-get`: the calling session, which is what
    /// resolves the workspace. The tool never takes a workspace id.
    session: []const u8 = "",
    /// `backfill`: stop after this many rows. 0 means no cap.
    limit: usize = 0,
    /// `backfill`: report what would move without writing anything.
    dry_run: bool = false,
    /// `search`: the literal substring to look for.
    query: []const u8 = "",
    /// `export`: comma-separated document ids, zipped into one archive.
    documents: []const u8 = "",
    /// `export`: where to write the file. Null means the exported file's own
    /// name, in the current directory.
    out: ?[]const u8 = null,
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
    /// `fs` or `s3`. Null falls back to `PABRIK_STORAGE_BACKEND`, then `fs`.
    backend: ?[]const u8 = null,
    /// Whether `--body` was passed at all. An empty body is a legitimate
    /// document, so "absent" and "empty" must stay distinguishable.
    body_given: bool = false,
};

/// The single-message admin verbs. One op per write the HTTP API exposes, so
/// an agent can delete, restore or drop a row with no server and no port.
pub const MessageOp = enum {
    delete,
    restore,
    feed,
};

pub const MessageArgs = struct {
    op: MessageOp,
    /// The row being deleted or flipped. Empty for `restore`.
    message_id: []const u8 = "",
    /// `restore` reads the row JSON from this file — the object `delete` printed.
    row_file: []const u8 = "",
    /// `feed` target. Null means `--feed` was missing.
    feed: ?bool = null,
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
    message_unknown_op,
    message_requires_flag,
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
    "      ops: list | search | folder-create | folder-move | folder-rename | folder-delete | doc-create | doc-move | doc-add | doc-edit | doc-delete | doc-search | doc-get | doc-html-add | doc-html-edit | doc-html-read | export | backfill\n" ++
    "      flags: --workspace <id> --name <n> --parent <id> --folder <id> --document <id> --title <t>\n" ++
    "      doc-create flags: --content <body> --format markdown|office|html\n" ++
    "      search flags: --query <text>\n" ++
    "      export flags: --document <id> | --documents <id,id,...> --out <path>\n" ++
    "      agent-tool flags: --session <id> --title <t> --content <markdown> --query <text> --limit <n> (doc-add, doc-edit, doc-delete, doc-search, doc-get, doc-html-add, doc-html-edit, doc-html-read)\n" ++
    "      backfill flags: --limit <n> --dry-run\n" ++
    "  pabrik headless group <op> [flags]       Read or change a multi-agent session\n" ++
    "      ops: create | join | leave | lead | members | next | delegate\n" ++
    "      flags: --session <id> --agent <n> --role lead|worker --position <n> --budget <n> --message <text>\n" ++
    "  pabrik headless message <op> [flags]      Delete, restore or drop ONE llm_history row\n" ++
    "      ops: delete <id> | restore --row-file <path> | feed <id> --feed 0|1\n" ++
    "  pabrik headless usage [flags]             Token, cache and tool totals for a workspace\n" ++
    "      flags: --workspace <id> --range 1d|7d|30d|90d\n" ++
    "  pabrik headless storage <op> [flags]      Read or write the object store\n" ++
    "      ops: put | get | stat | delete\n" ++
    "      flags: --key <k> --body <text> --body-file <path> --root <dir> --backend fs|s3|rustfs\n" ++
    "  pabrik headless memories <op> [flags]     Read or change a workspace's saved memories\n" ++
    "      ops: list | get | save | delete\n" ++
    "      flags: --workspace <id> --id <mem_id> --content <text> --tags a,b --query <text> --limit <n> --offset <n>\n" ++
    "  pabrik headless mcp-oauth <op> [flags]    Authorize a remote MCP server over OAuth 2.1\n" ++
    "      ops: discover | authorize-url | exchange | status | refresh | logout\n" ++
    "      flags: --url <mcp-url> --workspace <id> --server <name> --redirect-uri <uri>\n" ++
    "             --scope <s> --client-id <id> --code <c> --state <s>\n" ++
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
    message: MessageArgs,
    memories: MemoriesArgs,
    mcp_oauth: McpOAuthArgs,
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
    if (std.mem.eql(u8, verb, "message")) return try parseMessage(rest);
    if (std.mem.eql(u8, verb, "memories")) return try parseMemories(rest);
    if (std.mem.eql(u8, verb, "mcp-oauth")) return try parseMcpOAuth(rest);

    return .{ .invalid = .{ .kind = .unknown_subcommand, .value = verb } };
}

fn parseMcpOAuth(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .unknown_subcommand, .value = "mcp-oauth" });

    const op: McpOAuthOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "discover")) break :blk .discover;
        if (std.mem.eql(u8, word, "authorize-url")) break :blk .authorize_url;
        if (std.mem.eql(u8, word, "exchange")) break :blk .exchange;
        if (std.mem.eql(u8, word, "status")) break :blk .status;
        if (std.mem.eql(u8, word, "refresh")) break :blk .refresh;
        if (std.mem.eql(u8, word, "logout")) break :blk .logout;
        return fail(.{ .kind = .unknown_subcommand, .value = word });
    };

    var got = McpOAuthArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--url")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.url = argv[i];
        } else if (std.mem.eql(u8, flag, "--workspace")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.workspace_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--server")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.server_name = argv[i];
        } else if (std.mem.eql(u8, flag, "--redirect-uri")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.redirect_uri = argv[i];
        } else if (std.mem.eql(u8, flag, "--scope")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.scope = argv[i];
        } else if (std.mem.eql(u8, flag, "--client-id")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.client_id = argv[i];
        } else if (std.mem.eql(u8, flag, "--code")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.code = argv[i];
        } else if (std.mem.eql(u8, flag, "--state")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.state = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    if (got.url.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--url" });
    switch (op) {
        .discover => {},
        .authorize_url, .exchange, .status, .refresh, .logout => {
            if (got.workspace_id.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--workspace" });
        },
    }
    if (op == .exchange) {
        if (got.state.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--state" });
        if (got.code.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--code" });
    }

    return .{ .mcp_oauth = got };
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
        if (std.mem.eql(u8, word, "search")) break :blk .search;
        if (std.mem.eql(u8, word, "folder-create")) break :blk .folder_create;
        if (std.mem.eql(u8, word, "folder-move")) break :blk .folder_move;
        if (std.mem.eql(u8, word, "folder-rename")) break :blk .folder_rename;
        if (std.mem.eql(u8, word, "folder-delete")) break :blk .folder_delete;
        if (std.mem.eql(u8, word, "doc-create")) break :blk .doc_create;
        if (std.mem.eql(u8, word, "doc-move")) break :blk .doc_move;
        if (std.mem.eql(u8, word, "doc-add")) break :blk .doc_add;
        if (std.mem.eql(u8, word, "doc-edit")) break :blk .doc_edit;
        if (std.mem.eql(u8, word, "doc-delete")) break :blk .doc_delete;
        if (std.mem.eql(u8, word, "doc-search")) break :blk .doc_search;
        if (std.mem.eql(u8, word, "doc-html-add")) break :blk .doc_html_add;
        if (std.mem.eql(u8, word, "doc-html-edit")) break :blk .doc_html_edit;
        if (std.mem.eql(u8, word, "doc-html-read")) break :blk .doc_html_read;
        if (std.mem.eql(u8, word, "doc-get")) break :blk .doc_get;
        if (std.mem.eql(u8, word, "export")) break :blk .export_file;
        if (std.mem.eql(u8, word, "backfill")) break :blk .backfill;
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
        } else if (std.mem.eql(u8, flag, "--content")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.content = argv[i];
        } else if (std.mem.eql(u8, flag, "--format")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.format = argv[i];
        } else if (std.mem.eql(u8, flag, "--session")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.session = argv[i];
        } else if (std.mem.eql(u8, flag, "--limit")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.limit = std.fmt.parseInt(usize, argv[i], 10) catch
                return fail(.{ .kind = .invalid_number, .value = argv[i] });
        } else if (std.mem.eql(u8, flag, "--dry-run")) {
            got.dry_run = true;
        } else if (std.mem.eql(u8, flag, "--query")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.query = argv[i];
        } else if (std.mem.eql(u8, flag, "--documents")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.documents = argv[i];
        } else if (std.mem.eql(u8, flag, "--out")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.out = argv[i];
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = flag });
        }
        i += 1;
    }

    const tool_op = op == .doc_add or op == .doc_edit or op == .doc_delete or op == .doc_search or op == .doc_get or
        op == .doc_html_add or op == .doc_html_edit or op == .doc_html_read;
    if (tool_op) {
        if (got.session.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--session" });
    } else if (got.workspace_id.len == 0 and op != .backfill) {
        return fail(.{ .kind = .documents_requires_flag, .value = "--workspace" });
    }
    switch (op) {
        .list, .folder_delete, .backfill => {},
        .export_file => {
            if (got.document_id == null and got.documents.len == 0) {
                return fail(.{ .kind = .documents_requires_flag, .value = "--document" });
            }
        },
        .search => {
            if (got.query.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--query" });
        },
        .folder_create, .folder_rename => {
            if (got.name.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--name" });
            if (op == .folder_rename and got.folder_id == null) {
                return fail(.{ .kind = .documents_requires_flag, .value = "--folder" });
            }
        },
        .folder_move => {
            if (got.folder_id == null) return fail(.{ .kind = .documents_requires_flag, .value = "--folder" });
        },
        .doc_create, .doc_add, .doc_html_add => {
            if (got.title.len == 0) return fail(.{ .kind = .documents_requires_flag, .value = "--title" });
        },
        .doc_move, .doc_edit, .doc_delete, .doc_get, .doc_html_edit, .doc_html_read => {
            if (got.document_id == null) return fail(.{ .kind = .documents_requires_flag, .value = "--document" });
        },
        .doc_search => {},
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
        } else if (std.mem.eql(u8, flag, "--backend")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.backend = argv[i];
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

/// `message` parses its own flag set for the same reason `documents` does.
fn parseMessage(argv: []const []const u8) ParseError!Outcome {
    if (argv.len == 0) return fail(.{ .kind = .message_unknown_op });

    const op: MessageOp = blk: {
        const word = argv[0];
        if (std.mem.eql(u8, word, "delete")) break :blk .delete;
        if (std.mem.eql(u8, word, "restore")) break :blk .restore;
        if (std.mem.eql(u8, word, "feed")) break :blk .feed;
        return fail(.{ .kind = .message_unknown_op, .value = word });
    };

    var got = MessageArgs{ .op = op };
    var i: usize = 1;
    while (i < argv.len) {
        const word = argv[i];
        if (std.mem.eql(u8, word, "--row-file")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = word });
            got.row_file = argv[i];
        } else if (std.mem.eql(u8, word, "--feed")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = word });
            const v = argv[i];
            if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) {
                got.feed = true;
            } else if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) {
                got.feed = false;
            } else {
                return fail(.{ .kind = .invalid_number, .value = v });
            }
        } else if (word.len > 0 and word[0] == '-') {
            return fail(.{ .kind = .unknown_subcommand, .value = word });
        } else if (got.message_id.len == 0) {
            got.message_id = word;
        } else {
            return fail(.{ .kind = .unknown_subcommand, .value = word });
        }
        i += 1;
    }

    switch (op) {
        .delete, .feed => {
            if (got.message_id.len == 0) return fail(.{ .kind = .message_requires_flag, .value = "message_id" });
        },
        .restore => {
            if (got.row_file.len == 0) return fail(.{ .kind = .message_requires_flag, .value = "--row-file" });
        },
    }
    if (op == .feed and got.feed == null) return fail(.{ .kind = .message_requires_flag, .value = "--feed" });

    return .{ .message = got };
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
        if (std.mem.eql(u8, word, "delegate")) break :blk .delegate;
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
        } else if (std.mem.eql(u8, flag, "--message")) {
            i += 1;
            if (i >= argv.len) return fail(.{ .kind = .missing_value, .value = flag });
            got.message = argv[i];
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
        .delegate => {
            if (got.agent.len == 0) return fail(.{ .kind = .group_requires_flag, .value = "--agent" });
            if (got.message.len == 0) return fail(.{ .kind = .group_requires_flag, .value = "--message" });
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
        .message_unknown_op => std.log.err("headless: unknown message op '{s}'", .{f.value}),
        .message_requires_flag => std.log.err("headless: message needs {s}", .{f.value}),
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

test "parse message: delete takes a bare id" {
    const a = switch (try parse(&.{ "message", "delete", "m_1" })) {
        .message => |m| m,
        else => return error.UnexpectedOutcome,
    };
    try testing.expectEqual(MessageOp.delete, a.op);
    try testing.expectEqualStrings("m_1", a.message_id);
}

test "parse message: restore takes --row-file" {
    const a = switch (try parse(&.{ "message", "restore", "--row-file", "/tmp/row.json" })) {
        .message => |m| m,
        else => return error.UnexpectedOutcome,
    };
    try testing.expectEqual(MessageOp.restore, a.op);
    try testing.expectEqualStrings("/tmp/row.json", a.row_file);
}

test "parse message: feed takes 0 and 1, and rejects anything else" {
    const off = switch (try parse(&.{ "message", "feed", "m_1", "--feed", "0" })) {
        .message => |m| m,
        else => return error.UnexpectedOutcome,
    };
    try testing.expectEqual(false, off.feed.?);

    const on = switch (try parse(&.{ "message", "feed", "m_1", "--feed", "1" })) {
        .message => |m| m,
        else => return error.UnexpectedOutcome,
    };
    try testing.expectEqual(true, on.feed.?);

    try expectFailure(&.{ "message", "feed", "m_1", "--feed", "7" }, .invalid_number);
}

test "parse message: each op names the flag it is missing" {
    try expectFailure(&.{"message"}, .message_unknown_op);
    try expectFailure(&.{ "message", "nope" }, .message_unknown_op);
    try expectFailure(&.{ "message", "delete" }, .message_requires_flag);
    try expectFailure(&.{ "message", "restore" }, .message_requires_flag);
    try expectFailure(&.{ "message", "feed", "m_1" }, .message_requires_flag);
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

test "parse: documents doc-add takes a session, a title and a body" {
    const a = try parse(&.{
        "documents", "doc-add", "--session", "task_1", "--title", "Plan", "--content", "# hi",
    });
    try testing.expectEqual(DocumentsOp.doc_add, a.documents.op);
    try testing.expectEqualStrings("task_1", a.documents.session);
    try testing.expectEqualStrings("Plan", a.documents.title);
    try testing.expectEqualStrings("# hi", a.documents.content);
    // The tool resolves the workspace from the session, so no --workspace.
    try testing.expectEqualStrings("", a.documents.workspace_id);
}

test "parse: documents doc-html-add takes a session, a title and a page" {
    const a = try parse(&.{
        "documents", "doc-html-add", "--session", "task_1", "--title", "Page", "--content", "<p>hi</p>",
    });
    try testing.expectEqual(DocumentsOp.doc_html_add, a.documents.op);
    try testing.expectEqualStrings("task_1", a.documents.session);
    try testing.expectEqualStrings("Page", a.documents.title);
    try testing.expectEqualStrings("<p>hi</p>", a.documents.content);
}

test "parse: documents doc-html-edit and doc-html-read need a document id" {
    try expectFailure(&.{ "documents", "doc-html-edit", "--session", "task_1" }, .documents_requires_flag);
    try expectFailure(&.{ "documents", "doc-html-read", "--session", "task_1" }, .documents_requires_flag);

    const edit = try parse(&.{
        "documents", "doc-html-edit", "--session", "task_1", "--document", "doc_a", "--content", "<p>x</p>",
    });
    try testing.expectEqual(DocumentsOp.doc_html_edit, edit.documents.op);
    try testing.expectEqualStrings("doc_a", edit.documents.document_id.?);

    const read = try parse(&.{ "documents", "doc-html-read", "--session", "task_1", "--document", "doc_a" });
    try testing.expectEqual(DocumentsOp.doc_html_read, read.documents.op);
}

test "parse: documents doc-get needs a session and a document id" {
    try expectFailure(&.{ "documents", "doc-get", "--document", "doc_a" }, .documents_requires_flag);
    try expectFailure(&.{ "documents", "doc-get", "--session", "task_1" }, .documents_requires_flag);

    const a = try parse(&.{ "documents", "doc-get", "--session", "task_1", "--document", "doc_a" });
    try testing.expectEqual(DocumentsOp.doc_get, a.documents.op);
    try testing.expectEqualStrings("doc_a", a.documents.document_id.?);
}

test "parse: documents doc-delete needs a session and a document id" {
    try expectFailure(&.{ "documents", "doc-delete", "--document", "doc_a" }, .documents_requires_flag);
    try expectFailure(&.{ "documents", "doc-delete", "--session", "task_1" }, .documents_requires_flag);

    const a = try parse(&.{ "documents", "doc-delete", "--session", "task_1", "--document", "doc_a" });
    try testing.expectEqual(DocumentsOp.doc_delete, a.documents.op);
    try testing.expectEqualStrings("doc_a", a.documents.document_id.?);
}

test "parse: documents doc-search takes a session and an optional query" {
    try expectFailure(&.{ "documents", "doc-search", "--query", "plan" }, .documents_requires_flag);

    const a = try parse(&.{ "documents", "doc-search", "--session", "task_1", "--query", "plan", "--limit", "5" });
    try testing.expectEqual(DocumentsOp.doc_search, a.documents.op);
    try testing.expectEqualStrings("plan", a.documents.query);
    try testing.expectEqual(@as(usize, 5), a.documents.limit);
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

test "parse: group delegate reads the session, the agent and the message" {
    const a = try parse(&.{ "group", "delegate", "--session", "s_1", "--agent", "deepseek auto", "--message", "What is the retry policy?" });
    try testing.expectEqual(GroupOp.delegate, a.group.op);
    try testing.expectEqualStrings("s_1", a.group.session_id);
    try testing.expectEqualStrings("deepseek auto", a.group.agent);
    try testing.expectEqualStrings("What is the retry policy?", a.group.message);
}

test "parse: group delegate without a message is refused by name" {
    try expectFailure(&.{ "group", "delegate", "--session", "s_1", "--agent", "deepseek auto" }, .group_requires_flag);
}

test "parse: group delegate without an agent is refused by name" {
    try expectFailure(&.{ "group", "delegate", "--session", "s_1", "--message", "hi" }, .group_requires_flag);
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

test "parse: storage reads the backend override" {
    const a = try parse(&.{ "storage", "get", "--key", "k.md", "--backend", "s3" });
    try testing.expectEqualStrings("s3", a.storage.backend.?);
}

test "parse: storage defaults the backend to null so the environment decides" {
    const a = try parse(&.{ "storage", "get", "--key", "k.md" });
    try testing.expect(a.storage.backend == null);
}

test "parse: documents backfill needs no workspace, so it can sweep every one" {
    const a = try parse(&.{ "documents", "backfill" });
    try testing.expectEqual(DocumentsOp.backfill, a.documents.op);
    try testing.expectEqualStrings("", a.documents.workspace_id);
    try testing.expectEqual(@as(usize, 0), a.documents.limit);
    try testing.expect(!a.documents.dry_run);
}

test "parse: documents backfill reads the limit, the dry run and the workspace" {
    const a = try parse(&.{ "documents", "backfill", "--workspace", "ws_1", "--limit", "50", "--dry-run" });
    try testing.expectEqualStrings("ws_1", a.documents.workspace_id);
    try testing.expectEqual(@as(usize, 50), a.documents.limit);
    try testing.expect(a.documents.dry_run);
}

test "parse: documents backfill refuses a non-numeric limit" {
    try expectFailure(&.{ "documents", "backfill", "--limit", "lots" }, .invalid_number);
}

test "parse: documents search reads the query and needs a workspace" {
    const a = try parse(&.{ "documents", "search", "--workspace", "ws_1", "--query", "zephyr" });
    try testing.expectEqual(DocumentsOp.search, a.documents.op);
    try testing.expectEqualStrings("zephyr", a.documents.query);
}

test "parse: documents search refuses to run with no query" {
    try expectFailure(&.{ "documents", "search", "--workspace", "ws_1" }, .documents_requires_flag);
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
