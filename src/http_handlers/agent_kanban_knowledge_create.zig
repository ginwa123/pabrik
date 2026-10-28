//! `POST /api/agent-kanbans/:kanban_id/knowledge`. Adds a knowledge entry to
//! an agent-kanbans config.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// HTTP request body for knowledge-create.
const CreateKnowledgeBody = struct {
    file_path: []const u8 = "",
    label: []const u8 = "",
    /// Inline manual text. Mutually exclusive with `file_path`.
    content: []const u8 = "",
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = agent_kanban_db.KnowledgeRow;

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeCreateError = error{
    /// `kanban_id` path param was missing or empty.
    KanbanIdRequired,
    /// Neither `file_path` nor `content` was provided.
    FilePathRequired,
    /// `file_path` is non-empty but not absolute.
    NotAbsolutePath,
    /// Both `file_path` and `content` were provided.
    BothSourcesSet,
    /// `db.query` failed while looking up the kanban.
    LookupFailed,
    /// The workspace_item doesn't exist / isn't a kanban, OR the kanban
    /// has no `agent_kanbans` row yet.
    KanbanNotFound,
    /// `db.exec` failed on the INSERT.
    InsertFailed,
    /// Re-fetching the row after INSERT failed.
    RefetchFailed,
    /// Refetched row vanished (should be impossible — surfaces as 500).
    RowVanished,
    /// `std.fmt.allocPrint` failed on id generation.
    OutOfMemory,
};

/// Inputs to the knowledge-create use-case.
pub const KnowledgeCreateInput = struct {
    kanban_id: []const u8,
    file_path: []const u8,
    label: []const u8,
    content: []const u8 = "",
};

/// Output of the knowledge-create use-case.
pub const KnowledgeCreateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a knowledge row for the given agent-kanbans config.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: KnowledgeCreateInput,
) KnowledgeCreateError!KnowledgeCreateOutput {
    if (input.kanban_id.len == 0) return error.KanbanIdRequired;
    // XOR: exactly one of file_path / content must be non-empty.
    const has_file = input.file_path.len > 0;
    const has_content = input.content.len > 0;
    if (!has_file and !has_content) return error.FilePathRequired;
    if (has_file and has_content) return error.BothSourcesSet;
    if (has_file and !std.fs.path.isAbsolute(input.file_path)) return error.NotAbsolutePath;

    const handle: agent_kanban_db.DbOrTx = .{ .db = db };

    // Validate kanban exists + is a kanban + has an agent_kanbans row.
    // (spec D3: agent_kanbans.id == workspace_item_id, so kanban_id IS
    // the workspace_item_id.)
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'
        \\AND EXISTS (SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'kanban')
    , &[_][]const u8{ input.kanban_id, input.kanban_id }) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.KanbanNotFound;
    if (row) |r| r.deinit(allocator);

    // INSERT at MAX(position) + 1 and read the row back.
    const knowledge = (agent_kanban_db.insertKnowledge(allocator, handle, input.kanban_id, input.file_path, input.label, input.content) catch
        return error.InsertFailed) orelse return error.RowVanished;

    return .{ .knowledge = knowledge };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanKnowledgeCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";

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
        .kanban_id = kanban_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.KanbanIdRequired => 400,
            error.FilePathRequired => 400,
            error.NotAbsolutePath => 400,
            error.BothSourcesSet => 400,
            error.LookupFailed => 500,
            error.KanbanNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.KanbanIdRequired => "kanban_id required",
            error.FilePathRequired => "file_path or content is required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.BothSourcesSet => "file_path and content are mutually exclusive",
            error.LookupFailed => "DB error",
            error.KanbanNotFound => "kanban not found or not configured",
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
// impl + tests in one file (project convention). Behavioural coverage: 1.

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
    try test_db.openMemory(&db, io);

    // Full-shape workspace_items (see agents_get.zig setupDb comment).
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration116.up(&db, testing.allocator);

    // Seed: configured kanban + bare kanban + agent item.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_configs (id, workspace_item_id, item_type) VALUES ('ws_item_1', 'ws_item_1', 'kanban')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_bare', 'ws_1', 'kanban', 'Bare Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_agent', 'ws_1', 'agent', 'An agent')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty kanban_id returns KanbanIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanIdRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: neither file_path nor content returns FilePathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.FilePathRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .file_path = "", .content = "", .label = "" }),
    );
}

test "useCase: both file_path and content set returns BothSourcesSet" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.BothSourcesSet,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .file_path = "/tmp/a.md", .content = "text", .label = "" }),
    );
}

test "useCase: relative file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .file_path = "relative/path.md", .label = "" }),
    );
}

test "useCase: unconfigured kanban returns KanbanNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanNotFound,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_bare", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: agent-type item returns KanbanNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanNotFound,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_agent", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: happy path inserts with position 0 (COALESCE handles empty table)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .file_path = "/tmp/a.md",
        .label = "First",
    });
    defer agent_kanban_db.freeKnowledgeRow(alloc, output.knowledge);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), output.knowledge.position);
    try testing.expectEqualStrings("/tmp/a.md", output.knowledge.file_path);
    try testing.expectEqualStrings("First", output.knowledge.label);

    // Second row lands at position 1.
    const out2 = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .file_path = "",
        .content = "inline notes",
        .label = "Second",
    });
    defer agent_kanban_db.freeKnowledgeRow(alloc, out2.knowledge);
    try testing.expectEqual(@as(i64, 1), out2.knowledge.position);
    try testing.expectEqualStrings("inline notes", out2.knowledge.content);
}
