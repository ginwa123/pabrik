//! `POST /api/agent-kanbans/:kanban_id/system_prompt`. Adds a named
//! system-prompt block to an agent-kanbans config. Body: `{title?, content}`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_kanban_db = @import("../models/agent_kanban.db.zig");

/// HTTP request body for system-prompt-create.
const CreateSystemPromptBody = struct {
    title: []const u8 = "",
    content: []const u8 = "",
};

/// Subset of the system-prompt row returned by the use-case.
pub const SystemPrompt = agent_kanban_db.SystemPromptRow;

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const SystemPromptCreateError = error{
    /// `kanban_id` path param was missing or empty.
    KanbanIdRequired,
    /// `content` field was missing or whitespace-only.
    ContentRequired,
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

/// Inputs to the system-prompt-create use-case.
pub const SystemPromptCreateInput = struct {
    kanban_id: []const u8,
    title: []const u8,
    content: []const u8,
};

/// Output of the system-prompt-create use-case.
pub const SystemPromptCreateOutput = struct {
    system_prompt: SystemPrompt,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a system-prompt row for the given agent-kanbans config.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: SystemPromptCreateInput,
) SystemPromptCreateError!SystemPromptCreateOutput {
    if (input.kanban_id.len == 0) return error.KanbanIdRequired;
    // Content required — reject whitespace-only too.
    const trimmed = std.mem.trim(u8, input.content, " \t\r\n");
    if (trimmed.len == 0) return error.ContentRequired;

    const handle: agent_kanban_db.DbOrTx = .{ .db = db };

    // Validate kanban exists + is a kanban + has an agent_kanbans row.
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'
        \\AND EXISTS (SELECT 1 FROM agent_configs WHERE id = ? AND item_type = 'kanban')
    , &[_][]const u8{ input.kanban_id, input.kanban_id }) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.KanbanNotFound;
    if (row) |r| r.deinit(allocator);

    // INSERT at MAX(position) + 1 and read the row back.
    const system_prompt = (agent_kanban_db.insertSystemPrompt(allocator, handle, input.kanban_id, input.title, input.content) catch
        return error.InsertFailed) orelse return error.RowVanished;

    return .{ .system_prompt = system_prompt };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentKanbanSystemPromptCreateHandler(
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

    const parsed = std.json.parseFromSliceLeaky(CreateSystemPromptBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    const output = useCase(allocator, sqlite_db, .{
        .kanban_id = kanban_id,
        .title = parsed.title,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.KanbanIdRequired => 400,
            error.ContentRequired => 400,
            error.LookupFailed => 500,
            error.KanbanNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.KanbanIdRequired => "kanban_id required",
            error.ContentRequired => "content is required",
            error.LookupFailed => "DB error",
            error.KanbanNotFound => "kanban not found or not configured",
            error.InsertFailed => "Failed to insert system prompt",
            error.RefetchFailed => "Failed to read position",
            error.RowVanished => "Row missing after insert",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const data = try std.json.Stringify.valueAlloc(allocator, output.system_prompt, .{});
    return res.jsonResponse(.{ .status_code = 201, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention). Behavioural coverage: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;
const Migration116 = @import("../migrations/migration.zig").Migration116UnifyAgentConfigTables;

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
        useCase(alloc, &ctx.db, .{ .kanban_id = "", .title = "T", .content = "C" }),
    );
}

test "useCase: empty content returns ContentRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ContentRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .title = "T", .content = "" }),
    );
}

test "useCase: whitespace-only content returns ContentRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.ContentRequired,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_1", .title = "T", .content = "   \n\t  " }),
    );
}

test "useCase: unconfigured kanban returns KanbanNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.KanbanNotFound,
        useCase(alloc, &ctx.db, .{ .kanban_id = "ws_item_bare", .title = "T", .content = "C" }),
    );
}

test "useCase: happy path inserts with position 0 then 1 (COALESCE handles empty table)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out1 = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "Persona",
        .content = "You are X",
    });
    defer agent_kanban_db.freeSystemPromptRow(alloc, out1.system_prompt);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), out1.system_prompt.position);
    try testing.expectEqualStrings("Persona", out1.system_prompt.title);
    try testing.expectEqualStrings("You are X", out1.system_prompt.content);

    const out2 = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "Style",
        .content = "Be terse",
    });
    defer agent_kanban_db.freeSystemPromptRow(alloc, out2.system_prompt);
    try testing.expectEqual(@as(i64, 1), out2.system_prompt.position);
}

test "useCase: empty title tolerated (COALESCE binds '')" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try useCase(alloc, &ctx.db, .{
        .kanban_id = "ws_item_1",
        .title = "",
        .content = "Untitled prompt body",
    });
    defer agent_kanban_db.freeSystemPromptRow(alloc, out.system_prompt);
    try testing.expectEqualStrings("", out.system_prompt.title);
    try testing.expectEqualStrings("Untitled prompt body", out.system_prompt.content);
}
