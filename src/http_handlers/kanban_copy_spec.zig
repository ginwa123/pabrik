//! `POST
//! /api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;
const llm_history = pabrikcore.llm_history;

/// Request body. `mode` is optional — absent defaults to "replace".
const CopySpecBody = struct {
    /// "replace" (default) | "append"
    mode: ?[]const u8 = null,
};

/// Domain error set for the copy-spec flow. The handler maps each variant to
/// an HTTP status code + user-facing message via two exhaustive switches.
pub const CopySpecError = error{
    WorkspaceIdRequired,
    ItemIdRequired,
    SourceItemIdRequired,
    InvalidMode,
    WorkspaceItemNotFound,
    DatabaseError,
    OutOfMemory,
};

pub const CopySpecInput = struct {
    workspace_id: []const u8,
    item_id: []const u8,
    source_item_id: []const u8,
    mode: []const u8,
};

/// Returns the JSON-encoded envelope `{columns: [...], count: N}`.
pub const CopySpecResult = []const u8;

// =====================================================================
// Use case
// =====================================================================

/// Copy the source kanban's column spec to the target kanban. Steps: 1.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: CopySpecInput,
) CopySpecError!CopySpecResult {
    if (input.workspace_id.len == 0) return error.WorkspaceIdRequired;
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.source_item_id.len == 0) return error.SourceItemIdRequired;
    if (std.mem.eql(u8, input.item_id, input.source_item_id)) {
        // Self-copy has no useful semantics (the model would
        // delete-then-recreate, possibly with same row ids). 400.
        return error.SourceItemIdRequired;
    }
    if (!std.mem.eql(u8, input.mode, "replace") and
        !std.mem.eql(u8, input.mode, "append"))
    {
        return error.InvalidMode;
    }

    // Step 2: confirm both items are kanbans in the DB. Return 404 if either
    // is missing or is the wrong type.
    const target_opt = llm_history.getWorkspaceItem(allocator, db, input.item_id)
        catch return error.DatabaseError;
    defer if (target_opt) |t| {
        // WorkspaceItemInfo.deinit takes self by value, so this is
        // a no-copy free of the duped slices inside the struct.
        t.deinit(allocator);
    };
    if (target_opt == null or !std.mem.eql(u8, target_opt.?.item_type, "kanban")) {
        return error.WorkspaceItemNotFound;
    }

    const source_opt = llm_history.getWorkspaceItem(allocator, db, input.source_item_id)
        catch return error.DatabaseError;
    defer if (source_opt) |s| {
        s.deinit(allocator);
    };
    if (source_opt == null or !std.mem.eql(u8, source_opt.?.item_type, "kanban")) {
        return error.WorkspaceItemNotFound;
    }

    // Step 3: snapshot target's pre-existing column ids (used for
    // SSE emits in step 5). We capture the IDs BEFORE the model
    // helper deletes them.
    var pre_existing_ids = std.ArrayList([]u8).empty;
    defer {
        for (pre_existing_ids.items) |id| allocator.free(id);
        pre_existing_ids.deinit(allocator);
    }
    if (std.mem.eql(u8, input.mode, "replace")) {
        var q = db.query(allocator,
            "SELECT kc.id FROM kanban_columns kc WHERE kc.workspace_item_id = ?",
            &.{input.item_id}) catch return error.DatabaseError;
        defer q.deinit();
        while (q.next() catch return error.DatabaseError) |row| {
            defer row.deinit(allocator);
            try pre_existing_ids.append(allocator, allocator.dupe(u8, row.values[0]) catch return error.DatabaseError);
        }
    }

    // Step 4: do the actual copy.
    if (std.mem.eql(u8, input.mode, "replace")) {
        kanban_model.replaceColumnsWith(
            allocator, db, input.source_item_id, input.item_id,
        ) catch return error.DatabaseError;
    } else {
        kanban_model.appendColumnsFrom(
            allocator, db, input.source_item_id, input.item_id,
        ) catch return error.DatabaseError;
    }

    // Step 5: SSE emits — fire-and-forget. Replace mode: emit one `deleted`
    // event per pre-existing column, then one `created` event per newly
    // inserted column. Append mode: only `created` events.
    for (pre_existing_ids.items) |col_id| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "deleted",
            .workspace_id = input.workspace_id,
            .item_id = input.item_id,
            .column_id = col_id,
        }) catch |err| {
            std.log.warn(
                "kanban_copy_spec: SSE delete-event failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Step 6: re-read target columns for the response.
    const new_cols = kanban_model.listColumns(allocator, db, input.item_id) catch return error.DatabaseError;
    defer kanban_model.freeColumns(allocator, new_cols);

    for (new_cols) |col| {
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = input.item_id,
            .column_id = col.id,
            .new_description = col.description,
        }) catch |err| {
            std.log.warn(
                "kanban_copy_spec: SSE create-event failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };
    }

    // Build the wire envelope `{columns, count}`. Each column is
    // mapped via the shared `makeKanbanColumnResponse` helper for
    // shape consistency with the other endpoints.
    const col_responses = try allocator.alloc(http_response.KanbanColumnResponse, new_cols.len);
    defer allocator.free(col_responses);
    for (new_cols, 0..) |col, i| {
        col_responses[i] = http_response.makeKanbanColumnResponse(col);
    }

    const Envelope = struct {
        columns: []const http_response.KanbanColumnResponse,
        count: usize,
    };

    return try std.json.Stringify.valueAlloc(
        allocator,
        Envelope{ .columns = col_responses, .count = new_cols.len },
        .{},
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn kanbanCopySpecHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Path params. `:workspace_id`, `:item_id`, `:source_item_id`.
    const workspace_id = req.params.get("workspace_id") orelse "";
    const item_id = req.params.get("item_id") orelse "";
    const source_item_id = req.params.get("source_item_id") orelse "";

    if (workspace_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }),
        });
    }
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    if (source_item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "source_item_id required" }),
        });
    }

    // 2. Body (may be empty — defaults to mode=replace).
    var mode: []const u8 = "replace";
    if (req.body.len > 0) {
        const parsed = std.json.parseFromSliceLeaky(
            CopySpecBody, allocator, req.body, .{},
        ) catch {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
            });
        };
        if (parsed.mode) |m| mode = m;
    }

    // 3. Delegate to use-case.
    const data = useCase(allocator, sqlite_db, .{
        .workspace_id = workspace_id,
        .item_id = item_id,
        .source_item_id = source_item_id,
        .mode = mode,
    }) catch |err| {
        // Both switches are exhaustive over the inferred error set —
        // adding a new CopySpecError variant will fail to compile
        // here. No `else` prong needed.
        const status: u16 = switch (err) {
            error.WorkspaceIdRequired => 400,
            error.ItemIdRequired => 400,
            error.SourceItemIdRequired => 400,
            error.InvalidMode => 400,
            error.WorkspaceItemNotFound => 404,
            error.DatabaseError => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceIdRequired => "workspace_id required",
            error.ItemIdRequired => "item_id required",
            error.SourceItemIdRequired => "source_item_id required (and must differ from item_id)",
            error.InvalidMode => "mode must be 'replace' or 'append'",
            error.WorkspaceItemNotFound => "Workspace item not found or is not a kanban",
            error.DatabaseError => "Failed to copy kanban spec",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = data,
    });
}
