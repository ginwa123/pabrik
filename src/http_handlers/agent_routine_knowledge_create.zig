//! `POST /api/agent-routines/:routine_id/knowledge`. Adds a knowledge entry
//! to an agent-routines config.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_routine_db = @import("../models/agent_routine.db.zig");

/// HTTP request body for knowledge-create.
const CreateKnowledgeBody = struct {
    file_path: []const u8 = "",
    label: []const u8 = "",
    /// Inline manual text. Mutually exclusive with `file_path`.
    content: []const u8 = "",
};

/// Subset of the knowledge row returned by the use-case.
pub const Knowledge = agent_routine_db.KnowledgeRow;

/// Domain-level error set for `useCase`. The handler maps each variant
/// to an HTTP status code + message via two exhaustive switches.
pub const KnowledgeCreateError = error{
    /// `routine_id` path param was missing or empty.
    RoutineIdRequired,
    /// Neither `file_path` nor `content` was provided.
    FilePathRequired,
    /// `file_path` is non-empty but not absolute.
    NotAbsolutePath,
    /// Both `file_path` and `content` were provided.
    BothSourcesSet,
    /// `db.query` failed while looking up the routine.
    LookupFailed,
    /// The workspace_item doesn't exist / isn't a routine, OR the routine
    /// has no `agent_routines` row yet.
    RoutineNotFound,
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
    routine_id: []const u8,
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

/// Create a knowledge row for the given agent-routines config.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: KnowledgeCreateInput,
) KnowledgeCreateError!KnowledgeCreateOutput {
    if (input.routine_id.len == 0) return error.RoutineIdRequired;
    // XOR: exactly one of file_path / content must be non-empty.
    const has_file = input.file_path.len > 0;
    const has_content = input.content.len > 0;
    if (!has_file and !has_content) return error.FilePathRequired;
    if (has_file and has_content) return error.BothSourcesSet;
    if (has_file and !std.fs.path.isAbsolute(input.file_path)) return error.NotAbsolutePath;

    const handle: agent_routine_db.DbOrTx = .{ .db = db };

    // Validate routine exists + is a routine + has an agent_routines row.
    // (spec D3: agent_routines.id == workspace_item_id, so routine_id IS
    // the workspace_item_id.)
    var q = db.query(allocator,
        \\SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'routine'
        \\AND EXISTS (SELECT 1 FROM agent_routines WHERE id = ?)
    , &[_][]const u8{ input.routine_id, input.routine_id }) catch return error.LookupFailed;
    defer q.deinit();
    const row = q.next() catch null;
    if (row == null) return error.RoutineNotFound;
    if (row) |r| r.deinit(allocator);

    // INSERT at MAX(position) + 1 and read the row back.
    const knowledge = (agent_routine_db.insertKnowledge(allocator, handle, input.routine_id, input.file_path, input.label, input.content) catch
        return error.InsertFailed) orelse return error.RowVanished;

    return .{ .knowledge = knowledge };
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`.
pub fn agentRoutineKnowledgeCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const routine_id = req.params.get("routine_id") orelse "";

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
        .routine_id = routine_id,
        .file_path = parsed.file_path,
        .label = parsed.label,
        .content = parsed.content,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.RoutineIdRequired => 400,
            error.FilePathRequired => 400,
            error.NotAbsolutePath => 400,
            error.BothSourcesSet => 400,
            error.LookupFailed => 500,
            error.RoutineNotFound => 404,
            error.InsertFailed => 500,
            error.RefetchFailed => 500,
            error.RowVanished => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.RoutineIdRequired => "routine_id required",
            error.FilePathRequired => "file_path or content is required",
            error.NotAbsolutePath => "file_path must be absolute",
            error.BothSourcesSet => "file_path and content are mutually exclusive",
            error.LookupFailed => "DB error",
            error.RoutineNotFound => "routine not found or not configured",
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
const testing = std.testing;
const Migration087CreateAgentRoutines = @import("../migrations/migration.zig").Migration087CreateAgentRoutines;

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

    // Full-shape workspace_items (see agents_get.zig setupDb comment).
    try db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try Migration087CreateAgentRoutines.up(&db, testing.allocator);

    // Seed: configured routine + bare routine + agent item.
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_1', 'ws_1', 'routine', 'My Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('ws_item_1', 'ws_item_1')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_bare', 'ws_1', 'routine', 'Bare Routine')",
        &[_][]const u8{},
    );
    try db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('ws_item_agent', 'ws_1', 'agent', 'An agent')",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

test "useCase: empty routine_id returns RoutineIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.RoutineIdRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: neither file_path nor content returns FilePathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.FilePathRequired,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .file_path = "", .content = "", .label = "" }),
    );
}

test "useCase: both file_path and content set returns BothSourcesSet" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.BothSourcesSet,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .file_path = "/tmp/a.md", .content = "text", .label = "" }),
    );
}

test "useCase: relative file_path returns NotAbsolutePath" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.NotAbsolutePath,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_1", .file_path = "relative/path.md", .label = "" }),
    );
}

test "useCase: unconfigured routine returns RoutineNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.RoutineNotFound,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_bare", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: agent-type item returns RoutineNotFound" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.RoutineNotFound,
        useCase(alloc, &ctx.db, .{ .routine_id = "ws_item_agent", .file_path = "/tmp/a.md", .label = "" }),
    );
}

test "useCase: happy path inserts with position 0 (COALESCE handles empty table)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const output = try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .file_path = "/tmp/a.md",
        .label = "First",
    });
    defer agent_routine_db.freeKnowledgeRow(alloc, output.knowledge);
    // First row: COALESCE(NULL, -1) + 1 = 0. Critical: NOT 1 (off-by-one trap).
    try testing.expectEqual(@as(i64, 0), output.knowledge.position);
    try testing.expectEqualStrings("/tmp/a.md", output.knowledge.file_path);
    try testing.expectEqualStrings("First", output.knowledge.label);

    // Second row lands at position 1.
    const out2 = try useCase(alloc, &ctx.db, .{
        .routine_id = "ws_item_1",
        .file_path = "",
        .content = "inline notes",
        .label = "Second",
    });
    defer agent_routine_db.freeKnowledgeRow(alloc, out2.knowledge);
    try testing.expectEqual(@as(i64, 1), out2.knowledge.position);
    try testing.expectEqualStrings("inline notes", out2.knowledge.content);
}
