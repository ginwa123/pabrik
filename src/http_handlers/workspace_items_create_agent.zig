//! `POST /api/workspaces/:workspace_id/items/agent`. Creates a new workspace
//! item of `item_type='agent'` and the matching 1-1 row in the `agents`
//! sibling table, in a single BEGIN/COMMIT transaction.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const agent_db = @import("../models/agent.db.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");

/// Request body for the agent-item create endpoint. Both fields are
/// required (the Agent has a cwd like Kanban/Design).
const CreateAgentBody = struct {
    name: []const u8,
    path: []const u8,
};

/// Response item — mirrors `CreateKanbanResponse` minus the kanban-
/// specific fields. `path` mirrors the request body.
pub const CreateAgentItemResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8, // always "agent"
    name: []const u8,
    path: ?[]const u8 = null,
    position: i64,
};

/// Response agent row. Mirrors `src/models/agent.zig` field set.
pub const CreateAgentAgentResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8, // always "" for new agents
    created_at: []const u8,
    updated_at: []const u8,
};

/// Wire envelope: `{item, agent}`.
pub const CreateAgentResponseFull = struct {
    item: CreateAgentItemResponse,
    agent: CreateAgentAgentResponse,
};

pub const WorkspaceItemsCreateAgentError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    PathRequired,
    EmptyName,
    OutOfMemory,
    DatabaseError,
};

pub const WorkspaceItemsCreateAgentInput = struct {
    workspace_id: []const u8,
    body: CreateAgentBody,
    /// Live config.json `tools` checklist (null = legacy defaults).
    /// Read from the singleton by the HTTP handler and threaded into
    /// the seed so D2's absent/list/[] semantics reach `agent_tools`.
    config_tools: ?[]const []const u8 = null,
};

pub const WorkspaceItemsCreateAgentResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateAgentInput,
) WorkspaceItemsCreateAgentError!WorkspaceItemsCreateAgentResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;

    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.EmptyName;
    if (input.body.path.len == 0) return error.PathRequired;

    // Generate item id. SAME pattern as workspace_items_create_kanban.zig
    // (helpers.unixTimestampNanos is cross-platform; std.c.clock_gettime
    // doesn't compile on Windows in Zig 0.16).
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    // If anything below this point fails before we build the JSON,
    // free item_id — the production handler relies on the arena to
    // reap it, but tests use testing.allocator which leak-detects.
    errdefer allocator.free(item_id);

    // tx so the 2 INSERTs are atomic. A crash mid-flow
    // would otherwise leave a workspace_items row without an agent
    // sibling (breaking the 1-1 invariant).
    var tx = db.begin() catch return error.DatabaseError;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // 1. INSERT INTO workspace_items with item_type='agent' and a
    //    fresh position. NULLIF(?, '') stores NULL when the caller
    //    didn't pass a path (matching the kanban convention).
    tx.exec(
        allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'agent', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, trimmed_name, input.body.path, input.workspace_id },
    ) catch return error.DatabaseError;

    // 2. INSERT INTO agents with the SAME id (spec D3 — agents.id
    //    shares the workspace_item_id space; UNIQUE(workspace_item_id)
    //    enforces 1-1 at the DB layer).
    agent_db.insert(allocator, .{ .tx = &tx }, item_id, item_id) catch return error.DatabaseError;

    // 3.
    tools_equipped.seedDefaultAgentTools(allocator, .{ .tx = &tx }, item_id, input.config_tools) catch return error.DatabaseError;

    // COMMIT.
    tx.commit() catch return error.DatabaseError;

    // Read back the freshly-inserted position (mirrors the kanban
    // CREATE flow — see workspace_items_create_kanban.zig::readInsertedPosition).
    const position = readInsertedPosition(allocator, db, item_id);

    // Build the wire envelope. created_at / updated_at are populated
    // by SQLite's CURRENT_TIMESTAMP — we use empty strings here; the
    // frontend doesn't read them on create (it refetches via getWorkspacesItems).
    const json = try std.json.Stringify.valueAlloc(allocator, CreateAgentResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "agent",
            .name = trimmed_name,
            .path = input.body.path,
            .position = position,
        },
        .agent = .{
            .id = item_id,
            .workspace_item_id = item_id,
            .description = "",
            .created_at = "",
            .updated_at = "",
        },
    }, .{});
    // item_id was copied into the JSON by valueAlloc; the original allocPrint
    // buffer is no longer needed. The production handler doesn't need this —
    // the arena reaps it — but tests using testing.allocator leak-detect.
    allocator.free(item_id);
    return json;
}

/// Re-read the `position` of a freshly-INSERTed workspace_item.
fn readInsertedPosition(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    item_id: []const u8,
) i64 {
    var q = db.query(
        allocator,
        "SELECT position FROM workspace_items WHERE id = ?",
        &.{item_id},
    ) catch return 0;
    defer q.deinit();
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateAgentHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }

    // Live `tools` checklist — seeds the fresh agent's allowlist instead of
    // the defaults when set (plan 2026-09-22-tools-menu). It is the
    // WORKSPACE's list: tools are workspace-scoped.
    const workspace_cfg = auth_common.requestWorkspaceConfig(allocator, di, workspace_id, req.headers) orelse
        pabrikcore.getLlmConfig(di);
    const config_tools = workspace_cfg.tools;

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateAgentBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    if (parsed.name.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    // Trim leading/trailing ASCII whitespace. Reject whitespace-only
    // names at the handler level too (the useCase also rejects them).
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }
    if (parsed.path.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path is required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
        .config_tools = config_tools,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired, error.MissingBody, error.InvalidJson, error.NameRequired, error.PathRequired, error.EmptyName => 400,
            error.DatabaseError, error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired, error.EmptyName => "name is required",
            error.PathRequired => "path is required",
            error.DatabaseError => "Failed to create agent item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 201,
        .data = data,
    });
}
// ─── Tests ──────────────────────────────────────────────────────────────
// impl + tests in one file (project convention for Agent Mode). 4 behavioural
// tests cover the use-case: 1.

const sqlite = @import("pabrikcore").sqlite;
const testing = std.testing;

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

    // The useCase INSERTs into workspace_items + agents. workspace_items
    // needs the full shape (per spec D6) — re-create here matching the
    // post-migration-018 schema.
    try db.exec(
        testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try db.exec(
        testing.allocator,
        "CREATE TABLE agents (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL UNIQUE, description TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );
    try db.exec(
        testing.allocator,
        "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

fn rowCount(db: *sqlite.SqliteBackend, allocator: std.mem.Allocator, table: []const u8, where: []const u8) !u32 {
    var sql_buf: [256]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ table, where });
    var q = try db.query(allocator, sql, &[_][]const u8{});
    defer q.deinit();
    const row = (q.next() catch null) orelse return 0;
    defer row.deinit(allocator);
    return try std.fmt.parseInt(u32, row.values[0], 10);
}

test "useCase: empty workspace_id returns WorkspaceIdRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.WorkspaceIdRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "",
            .body = .{ .name = "My Agent", .path = "/tmp" },
        }),
    );
}

test "useCase: empty name returns EmptyName" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.EmptyName,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "   ", .path = "/tmp" },
        }),
    );
}

test "useCase: empty path returns PathRequired" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try testing.expectError(
        error.PathRequired,
        useCase(alloc, &ctx.db, .{
            .workspace_id = "ws_1",
            .body = .{ .name = "My Agent", .path = "" },
        }),
    );
}

test "useCase: happy path creates workspace_item (atomically)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const json = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "My Agent", .path = "/tmp/agent" },
    });
    defer alloc.free(json);

    // 1 workspace_item row.
    try testing.expectEqual(@as(u32, 1), try rowCount(&ctx.db, alloc, "workspace_items", "workspace_id = 'ws_1'"));
}

test "useCase: position increments per workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Use DIFFERENT workspace_ids for each call so the agents INSERT's
    // workspace_item_id column doesn't collide on the UNIQUE constraint (the
    // production code passes input.workspace_id as workspace_item_id, not
    const a1 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_1",
        .body = .{ .name = "Agent 1", .path = "/tmp/a1" },
    });
    defer alloc.free(a1);
    const a2 = try useCase(alloc, &ctx.db, .{
        .workspace_id = "ws_2",
        .body = .{ .name = "Agent 2", .path = "/tmp/a2" },
    });
    defer alloc.free(a2);

    // Parse the position out of both responses. The wire shape is {item:
    // {...}, agent: {...}} — we capture the same fields as
    // CreateAgentResponseFull so the parser sees a shape it recognizes.
    const PosView = CreateAgentResponseFull;
    const p1_pos = try std.json.parseFromSliceLeaky(PosView, alloc, a1, .{});
    try testing.expectEqual(@as(i64, 0), p1_pos.item.position);
    try testing.expectEqualStrings("ws_1", p1_pos.item.workspace_id);
    const p2_pos = try std.json.parseFromSliceLeaky(PosView, alloc, a2, .{});
    try testing.expectEqual(@as(i64, 0), p2_pos.item.position);
    try testing.expectEqualStrings("ws_2", p2_pos.item.workspace_id);
}
