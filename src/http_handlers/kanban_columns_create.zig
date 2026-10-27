//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/columns`. Append
//! a new column to the end of a kanban's column sequence (or at an explicit
//! `position` if the caller passes one).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const kanban_model = @import("../agentic_loop/kanban_model.zig");
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// HTTP request body for column-create.
const CreateColumnBody = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    position: ?i64 = null,
};

/// Domain-level error set for `useCase`. The handler maps each variant to an
/// HTTP status code + message via two exhaustive switches (one for status,
/// one for the user-facing message).
pub const KanbanColumnCreateError = error{
    /// `:item_id` path param was missing or empty.
    ItemIdRequired,
    /// Body `name` field was empty.
    NameRequired,
    /// `kanban_model.addColumn` failed (DB error, etc.).
    AddColumnFailed,
    /// `kanban_model.listColumns` failed after the insert.
    FetchFailed,
    /// Insert succeeded but the new column wasn't visible in the
    /// subsequent `listColumns` (consistency violation — extremely
    /// unlikely; surfaces as 500 so the caller can re-fetch).
    ColumnNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the create-column use-case. The handler maps the parsed
/// HTTP body into this struct; the use-case is then transport-agnostic.
pub const CreateColumnInput = struct {
    item_id: []const u8,
    /// workspace_id is only used for the SSE payload's `workspace_id`
    /// field (the frontend filters kanban events by it). Empty is OK.
    workspace_id: []const u8,
    name: []const u8,
    /// Pre-defaulted: callers should pass `""` when the body omitted
    /// `description` (the "no description" sentinel — `NOT NULL
    /// DEFAULT ''` column).
    description: []const u8,
    /// `null` → place at `MAX(position) + 1`. Concrete integer →
    /// caller is responsible for renumbering collisions
    /// (`kanban_model.reorderColumn` does this for explicit moves).
    position: ?i64,
};

/// Output of the create-column use-case.
pub const CreateColumnOutput = struct {
    /// The freshly-created column.
    column: kanban_model.KanbanColumn,
};

// =====================================================================
// Use case
// =====================================================================

/// Create a kanban column. Steps: 1. Validate `item_id` and `name`. 2.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: CreateColumnInput,
) KanbanColumnCreateError!CreateColumnOutput {
    // 1. Validate. These are business rules: an empty `item_id`
    // means there's no kanban item to add to, and an empty `name`
    // means the column has no label (the DB column is NOT NULL).
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.name.len == 0) return error.NameRequired;

    // 2. Insert the column.
    const new_id = kanban_model.addColumn(
        allocator,
        .{ .db = db },
        input.item_id,
        input.name,
        input.description,
        input.position,
    ) catch return error.AddColumnFailed;
    defer allocator.free(new_id);

    // 3. Re-query to get the full row (we need `id` + `created_at`
    // + `workspace_item_id` for the response, which addColumn does
    // not return).
    const cols = kanban_model.listColumns(allocator, db, input.item_id) catch return error.FetchFailed;
    defer kanban_model.freeColumns(allocator, cols);

    // 4. Locate the new column by its id.
    for (cols) |c| {
        if (!std.mem.eql(u8, c.id, new_id)) continue;

        // 5.
        on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
            .action = "created",
            .workspace_id = input.workspace_id,
            .item_id = input.item_id,
            .column_id = c.id,
            .new_description = c.description,
        }) catch |err| {
            std.log.warn(
                "kanban_columns_create: SSE emit failed (non-fatal): {s}",
                .{@errorName(err)},
            );
        };

        // 6. Duplicate the matched column's slices so the output survives the
        // `freeColumns(cols)` defer above.
        var duped_id: ?[]u8 = null;
        var duped_workspace_item_id: ?[]u8 = null;
        var duped_name: ?[]u8 = null;
        var duped_description: ?[]u8 = null;
        var duped_created_at: ?[]u8 = null;
        errdefer {
            if (duped_id) |v| allocator.free(v);
            if (duped_workspace_item_id) |v| allocator.free(v);
            if (duped_name) |v| allocator.free(v);
            if (duped_description) |v| allocator.free(v);
            if (duped_created_at) |v| allocator.free(v);
        }
        duped_id = try allocator.dupe(u8, c.id);
        duped_workspace_item_id = try allocator.dupe(u8, c.workspace_item_id);
        duped_name = try allocator.dupe(u8, c.name);
        duped_description = try allocator.dupe(u8, c.description);
        duped_created_at = try allocator.dupe(u8, c.created_at);

        return .{ .column = .{
            .id = duped_id.?,
            .workspace_item_id = duped_workspace_item_id.?,
            .name = duped_name.?,
            .description = duped_description.?,
            .position = c.position,
            .created_at = duped_created_at.?,
        } };
    }

    return error.ColumnNotVisible;
}

// =====================================================================
// Handler
// =====================================================================

/// Thin orchestrator over `useCase`. Validates the HTTP request,
/// resolves the singleton DB handle, delegates to `useCase`, and
/// maps the use-case outcome to an HTTP response.
pub fn kanbanColumnsCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }

    // workspace_id is required for the SSE payload (the frontend uses
    // it to filter events for the active workspace). Empty is fine —
    // the SSE event will still be emitted with workspace_id="".
    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreateColumnBody, allocator, req.body, .{}) catch {
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

    // Empty string is the "no description" sentinel (the DB column is
    // NOT NULL DEFAULT '', and the frontend renders "" as the
    // "Add a description..." placeholder).
    const description = parsed.description orelse "";

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .name = parsed.name,
        .description = description,
        .position = parsed.position,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response.
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.NameRequired => 400,
            error.AddColumnFailed => 500,
            error.FetchFailed => 500,
            error.ColumnNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.NameRequired => "name is required",
            error.AddColumnFailed => "Failed to add column",
            error.FetchFailed => "Failed to fetch new column",
            error.ColumnNotVisible => "Column was added but not visible in list",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };
    // Free the useCase's heap-owned column slices. On the per-request arena
    // this is a no-op (the arena reaps at request end) but the explicit frees
    // are defensive + document ownership.
    defer {
        allocator.free(output.column.id);
        allocator.free(output.column.workspace_item_id);
        allocator.free(output.column.name);
        allocator.free(output.column.description);
        allocator.free(output.column.created_at);
    }

    // 4. Build the success response (201 Created — POST that creates
    // a new resource).
    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeKanbanColumnResponse(output.column),
            .{},
        ),
    });
}
