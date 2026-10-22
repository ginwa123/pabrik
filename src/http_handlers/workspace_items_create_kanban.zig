//! `POST /api/workspaces/:workspace_id/items/kanban`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const tools_equipped = @import("../agentic_loop/tools_equipped.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;
const helpers = @import("helpers");

/// Request body for the kanban-item create endpoint.
const CreateKanbanBody = struct {
    name: []const u8,
    /// Optional absolute path on disk that will become the `cwd` for
    /// every chat session created under this kanban's tasks.
    path: ?[]const u8 = null,
};

/// Response body for the kanban-item create endpoint.
pub const CreateKanbanResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: []const u8,
    /// Mirrors the request body's path. `null` when the caller did
    /// not supply one (cwd-less kanban).
    path: ?[]const u8 = null,
    position: i64,
};

/// Wire envelope for the create endpoint.
pub const CreateKanbanResponseFull = struct {
    item: CreateKanbanResponse,
    columns: []const kanban_model.KanbanColumn,
};

pub const WorkspaceItemsCreateKanbanError = error{
    WorkspaceIdRequired,
    MissingBody,
    InvalidJson,
    NameRequired,
    InsertFailed,
    SeedFailed,
    /// `std.json.Stringify.valueAlloc` and `allocator.dupe` can
    /// fail with `OutOfMemory`. Unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const WorkspaceItemsCreateKanbanInput = struct {
    workspace_id: []const u8,
    body: CreateKanbanBody,
    /// Live config.json `tools` checklist (null = legacy defaults). Read from
    /// the singleton by the HTTP handler and threaded into the seed so D2's
    /// absent/list/[] semantics reach `agent_kanban_tools`.
    config_tools: ?[]const []const u8 = null,
};

pub const WorkspaceItemsCreateKanbanResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: WorkspaceItemsCreateKanbanInput,
) WorkspaceItemsCreateKanbanError!WorkspaceItemsCreateKanbanResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    // Trim leading/trailing ASCII whitespace and reject empty names. Mirrors
    // `workspace_items_create.zig`'s `EmptyName` validation so both create
    // endpoints have consistent semantics.
    const trimmed_name = std.mem.trim(u8, input.body.name, " \t\n\r");
    if (trimmed_name.len == 0) return error.NameRequired;

    // Path is optional — when omitted, NULL is stored (cwd-less kanban, same
    // as pre-fix behavior).
    const path_opt: ?[]const u8 = input.body.path;
    const path_for_insert: []const u8 = path_opt orelse "";

    // Generate item id. Same nanosecond-timestamp scheme as
    // `workspace_items_create.zig:generateItemId`.
    const timestamp_ns = helpers.unixTimestampNanos();
    const item_id = try std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
    defer allocator.free(item_id);

    // tx so workspace_item + columns + agent_kanbans + tools are atomic.
    var tx = db.begin() catch return error.InsertFailed;
    defer tx.commitOrRollback() catch {};
    errdefer tx.rollback() catch {};

    // Compute the new item's position as COALESCE(MAX(position), -1) + 1
    // within this workspace.
    tx.exec(
        allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position, created_at, updated_at) VALUES (?, ?, 'kanban', ?, NULLIF(?, ''), COALESCE((SELECT MAX(position) FROM workspace_items WHERE workspace_id = ?), -1) + 1, datetime('now'), datetime('now'))",
        &.{ item_id, input.workspace_id, trimmed_name, path_for_insert, input.workspace_id },
    ) catch return error.InsertFailed;

    // Seed the 3 default columns (`todo / in progress / done`).
    // Takes `tx` (not `db`): the tx holds the backend mutex, so a
    // `db.exec` here would deadlock on the non-reentrant lock.
    kanban_model.seedDefaultColumns(allocator, .{ .tx = &tx }, item_id) catch return error.SeedFailed;

    // Seed the agent_kanban config row + the tool allowlist (config.json
    // `tools` checklist when set, otherwise DEFAULT_AGENT_TOOLS +
    // DEFAULT_KANBAN_TOOLS) so a fresh board is immediately usable.
    tx.exec(
        allocator,
        "INSERT OR IGNORE INTO agent_configs (id, workspace_item_id, item_type) VALUES (?, ?, 'kanban')",
        &.{ item_id, item_id },
    ) catch return error.SeedFailed;
    tools_equipped.seedDefaultKanbanTools(allocator, .{ .tx = &tx }, item_id, input.config_tools) catch return error.SeedFailed;

    tx.commit() catch return error.SeedFailed;

    // Read back the freshly-seeded columns so the response can include them
    // in the `columns` field of the wire envelope.
    const seeded_cols = kanban_model.listColumns(allocator, db, item_id) catch {
        std.log.warn(
            \\workspace_items_create_kanban: seed-listColumns failed (non-fatal); returning empty columns array
        ,
            .{},
        );
        return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
            .item = .{
                .id = item_id,
                .workspace_id = input.workspace_id,
                .item_type = "kanban",
                .name = trimmed_name,
                .path = path_opt,
                .position = 0,
            },
            .columns = &[_]kanban_model.KanbanColumn{},
        }, .{});
    };
    defer kanban_model.freeColumns(allocator, seeded_cols);

    // Emit SSE events for each seeded column so other connected clients
    // refresh their kanban view. action="created" for all three.
    for (seeded_cols) |col| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = item_id,
            .column_id = col.id,
        }) catch |err| {
            std.log.warn(
                "workspace_items_create_kanban: SSE emit failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Read the actual position back from the DB so the response mirrors what
    // was persisted.
    const position = readInsertedPosition(allocator, db, item_id);

    return try std.json.Stringify.valueAlloc(allocator, CreateKanbanResponseFull{
        .item = .{
            .id = item_id,
            .workspace_id = input.workspace_id,
            .item_type = "kanban",
            .name = trimmed_name,
            .path = path_opt,
            .position = position,
        },
        .columns = seeded_cols,
    }, .{});
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceItemsCreateKanbanHandler(
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

    // Live `tools` checklist — seeds the fresh board's allowlist instead of
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

    const parsed = std.json.parseFromSliceLeaky(CreateKanbanBody, allocator, req.body, .{}) catch {
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
    // Trim leading/trailing ASCII whitespace.
    if (std.mem.trim(u8, parsed.name, " \t\n\r").len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }),
        });
    }

    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .body = parsed,
        .config_tools = config_tools,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.NameRequired => 400,
            error.InsertFailed, error.SeedFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON body",
            error.NameRequired => "name is required",
            error.InsertFailed => "Failed to create kanban item",
            error.SeedFailed => "Failed to seed default columns",
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
    // `try` would propagate the error and abort the 201 — we want
    // a best-effort read, so swallow the error and fall through.
    if (q.next() catch null) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}
