//! `POST /api/agents/:agent_id/knowledge`. Adds a markdown knowledge file to
//! an Agent. Body: `{file_path, label?, position?}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");

/// HTTP request body for knowledge-create.
const CreateKnowledgeBody = struct {
    file_path: []const u8 = "",
    label: []const u8 = "",
    /// Inline manual text. Mutually exclusive with `file_path`
    /// (exactly one must be non-empty). Empty = file-backed row.
    content: []const u8 = "",
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = agent_db.KnowledgeRow;

/// Domain-level error set for `useCase`.
pub const KnowledgeCreateError = error{
    /// `agent_id` path param was missing or empty.
    AgentIdRequired,
    /// `file_path` field was missing or empty.
    FilePathRequired,
    /// `file_path` is not absolute.
    NotAbsolutePath,
    /// Both `file_path` and `content` were provided — exactly one
    /// source must be set.
    BothSourcesSet,
    /// `db.query` failed while looking up the agent.
    LookupFailed,
    /// The workspace_item row did not exist or was not of type `'agent'`.
    AgentNotFound,
    /// `db.exec` failed on the INSERT.
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation. Unreachable under arena
    /// allocator (test builds with `testing.allocator` can hit it), but the
    /// type system requires the variant so `try` propagates a typed error.
    OutOfMemory,
};

/// Inputs to the knowledge-create use-case.
pub const KnowledgeCreateInput = struct {
    agent_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    /// Inline manual text. Mutually exclusive with `file_path`.
    content: []const u8 = "",
};

/// Output of the knowledge-create use-case. `knowledge` is owned by
/// the caller (lifetime = request arena).
pub const KnowledgeCreateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a knowledge row for the given agent.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KnowledgeCreateInput,
) KnowledgeCreateError!KnowledgeCreateOutput {
    if (input.agent_id.len == 0) return error.AgentIdRequired;
    // XOR: exactly one of file_path / content must be non-empty.
    const has_file = input.file_path.len > 0;
    const has_content = input.content.len > 0;
    if (!has_file and !has_content) return error.FilePathRequired;
    if (has_file and has_content) return error.BothSourcesSet;
    if (has_file and !std.fs.path.isAbsolute(input.file_path)) return error.NotAbsolutePath;

    const handle: agent_db.DbOrTx = .{ .db = db };

    // Validate agent exists + is an agent.
    var q = db.query(allocator,
        "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'agent'",
        &[_][]const u8{input.agent_id},
    ) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.AgentNotFound;
    if (row) |r| r.deinit(allocator);

    // INSERT at MAX(position) + 1 and read the row back.
    const knowledge = (agent_db.insertKnowledge(allocator, handle, input.agent_id, input.file_path, input.label, input.content) catch
        return error.InsertFailed) orelse return error.RowVanished;

    return .{ .knowledge = knowledge };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn agentKnowledgeCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const agent_id = req.params.get("agent_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .agent_id = agent_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.AgentIdRequired => 400,
            error.FilePathRequired => 400,
            error.NotAbsolutePath => 400,
            error.BothSourcesSet => 400,
            error.LookupFailed => 500,
            error.AgentNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.AgentIdRequired => "agent_id required",
            error.FilePathRequired => "file_path or content is required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.BothSourcesSet => "file_path and content are mutually exclusive",
            error.LookupFailed => "DB error",
            error.AgentNotFound => "agent not found",
            error.InsertFailed => "Failed to insert knowledge",
            error.RefetchFailed => "Failed to read position",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.knowledge, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 5 behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const database = @import("pabrikcore").database;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

const TestCtx = struct {
    db: database.Db,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: database.Db = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // See agent_knowledge_delete.zig for why we re-create
    // workspace_items with the full shape instead of relying on
    // Migration 001.
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);
    // mirror that, or the `content` column (Migration 079) is missing
    // and the INSERT in useCase fails with PrepareFailed.

    // Seed: 1 workspace_item of type 'agent' + matching agents row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'agent', 'My Agent')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type, description) VALUES ('ws_item_1', 'ws_item_1', 'agent', '')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty agent_id returns AgentIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentIdRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "",
            .file_path = "/tmp/a.md",
            .label = "",
        }),
    );
}

test "useCase: empty file_path returns FilePathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.FilePathRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "",
            .label = "",
        }),
    );
}

test "useCase: relative file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "relative/path.md",
            .label = "",
        }),
    );
}

test "useCase: non-existent agent returns AgentNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.AgentNotFound,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_404",
            .file_path = "/tmp/a.md",
            .label = "",
        }),
    );
}

test "useCase: happy path inserts with position 0 (COALESCE handles empty agents)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .file_path = "/tmp/a.md",
        .label = "First",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), output.knowledge.position);
    try testing.expectEqualStrings("/tmp/a.md", output.knowledge.file_path);
    try testing.expectEqualStrings("First", output.knowledge.label);
}

// ─── content (manual text) tests — plan 2026-08-21-agent-knowledge-manual-text ──

test "useCase: inline content happy path inserts row with content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .file_path = "",
        .content = "Manual notes about the deploy process.\nSecond line.",
        .label = "Deploy notes",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);

    try testing.expectEqualStrings("Deploy notes", output.knowledge.label);
    try testing.expectEqualStrings(
        "Manual notes about the deploy process.\nSecond line.",
        output.knowledge.content,
    );
    try testing.expectEqual(@as(i64, 0), output.knowledge.position);
    try testing.expectEqualStrings("", output.knowledge.file_path);
}

test "useCase: both file_path and content empty returns FilePathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.FilePathRequired,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "",
            .content = "",
            .label = "",
        }),
    );
}

test "useCase: both file_path and content set returns BothSourcesSet" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.BothSourcesSet,
        useCase(alloc, &ctx.db, .{
            .agent_id = "ws_item_1",
            .file_path = "/tmp/a.md",
            .content = "inline text",
            .label = "",
        }),
    );
}

test "useCase: file-backed path still works with content empty (no regression)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .agent_id = "ws_item_1",
        .file_path = "/tmp/a.md",
        .content = "",
        .label = "First",
    });
    defer agent_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("/tmp/a.md", output.knowledge.file_path);
    try testing.expectEqualStrings("", output.knowledge.content);
}