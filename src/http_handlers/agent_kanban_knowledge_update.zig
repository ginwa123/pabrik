//! `PATCH /api/agent-kanbans/:kanban_id/knowledge/:knowledge_id`. Updates
//! file_path / label / content of an existing knowledge entry.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// HTTP request body.
const UpdateKnowledgeBody = struct {
    file_path: ?[]const u8 = null,
    label: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = agent_kanban_db.KnowledgeRow;

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeUpdateError = error{
    /// `kanban_id` or `knowledge_id` path param was missing or empty.
    IdsRequired,
    /// Body had none of file_path / label / content (nothing to update).
    NothingToUpdate,
    /// `file_path` provided but not absolute (empty string is legal —
    /// it means "clear the column").
    NotAbsolutePath,
    /// `db.exec` failed on the UPDATE.
    UpdateFailed,
    /// Re-fetching the row after UPDATE failed.
    RefetchFailed,
    /// Refetched row vanished (surfaces as 404).
    RowNotFound,
    /// `allocator.alloc` failed while building the dynamic SQL.
    OutOfMemory,
};

/// Inputs to the knowledge-update use-case.
pub const KnowledgeUpdateInput = struct {
    kanban_id: []const u8,
    knowledge_id: []const u8,
    file_path: ?[]const u8,
    label: ?[]const u8,
    content: ?[]const u8 = null,
};

/// Output of the knowledge-update use-case.
pub const KnowledgeUpdateOutput = struct {
    knowledge: Knowledge,
};

// =====================================================================
// Use case
// =====================================================================

/// Update an existing knowledge row.
pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: KnowledgeUpdateInput,
) KnowledgeUpdateError!KnowledgeUpdateOutput {
    if (input.kanban_id.len == 0 or input.knowledge_id.len == 0) {
        return error.IdsRequired;
    }
    if (input.file_path == null and input.label == null and input.content == null) {
        return error.NothingToUpdate;
    }
    if (input.file_path) |fp| {
        // Empty string = clear the column (mode switch). Only NON-empty
        // paths must be absolute.
        if (fp.len > 0 and !std.fs.path.isAbsolute(fp)) return error.NotAbsolutePath;
    }

    const handle: agent_kanban_db.DbOrTx = .{ .db = db };

    // Patch the requested fields, then read the row back.
    const knowledge = (agent_kanban_db.updateKnowledge(
        allocator,
        handle,
        input.knowledge_id,
        input.kanban_id,
        input.file_path,
        input.label,
        input.content,
    ) catch return error.UpdateFailed) orelse return error.RowNotFound;

    return .{ .knowledge = knowledge };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanKnowledgeUpdateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const kanban_id = req.params.get("kanban_id") orelse "";
    const knowledge_id = req.params.get("knowledge_id") orelse "";

    const parsed = std.json.parseFromSliceLeaky(UpdateKnowledgeBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .kanban_id = kanban_id,
        .knowledge_id = knowledge_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.IdsRequired => 400,
            error.NothingToUpdate => 400,
            error.NotAbsolutePath => 400,
            error.UpdateFailed => 500,
            error.RefetchFailed => 500,
            error.RowNotFound => 404,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.IdsRequired => "kanban_id and knowledge_id required",
            error.NothingToUpdate => "file_path or label required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.UpdateFailed => "Failed to update knowledge",
            error.RefetchFailed => "Failed to read row",
            error.RowNotFound => "knowledge row not found",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.knowledge, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention). Behavioural coverage: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration081CreateAgentKanbans = @import("../migrations/migration.zig").Migration081CreateAgentKanbans;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration081CreateAgentKanbans.up(&db, testing.allocator);

    // Seed: configured kanban + 1 knowledge row.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'kanban', 'My Board')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_kanban_knowledges (id, kanban_id, file_path, label, position) VALUES ('kn_1', 'ws_item_1', '/tmp/orig.md', 'Original', 0)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty kanban_id returns IdsRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.IdsRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .knowledge_id = "kn_1", .file_path = "/tmp/new.md", .label = null }),
    );
}

test "useCase: nothing to update returns NothingToUpdate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NothingToUpdate,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .knowledge_id = "kn_1", .file_path = null, .label = null }),
    );
}

test "useCase: relative non-empty file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .knowledge_id = "kn_1", .file_path = "relative/path.md", .label = null }),
    );
}

test "useCase: happy path updates both file_path AND label" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "/tmp/new.md",
        .label = "New label",
    });
    defer agent_kanban_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("kn_1", output.knowledge.id);
    try testing.expectEqualStrings("/tmp/new.md", output.knowledge.file_path);
    try testing.expectEqualStrings("New label", output.knowledge.label);
}

test "useCase: file_path='' clears path and sets content (file→text switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "",
        .label = "Switched",
        .content = "inline body after switch",
    });
    defer agent_kanban_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("", output.knowledge.file_path);
    try testing.expectEqualStrings("inline body after switch", output.knowledge.content);
    try testing.expectEqualStrings("Switched", output.knowledge.label);
}

test "useCase: content='' clears text and sets path (text→file switch)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .knowledge_id = "kn_1",
        .file_path = "/tmp/switched.md",
        .label = "Switched to file",
        .content = "",
    });
    defer agent_kanban_db.freeKnowledgeRow(alloc, output.knowledge);
    try testing.expectEqualStrings("", output.knowledge.content);
    try testing.expectEqualStrings("/tmp/switched.md", output.knowledge.file_path);
}
