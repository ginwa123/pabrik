//! `POST /api/workspaces/:workspace_id/items/:item_id/design/pages`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const design_model = @import("../modules/agent/loop/design_model.zig");

/// HTTP request body for page-create.
const CreatePageBody = struct {
    name: []const u8,
    width: ?i64 = null,
    height: ?i64 = null,
};

/// Domain-level error set for `useCase`.
pub const DesignPageCreateError = error{
    /// `:item_id` path param was missing or empty.
    ItemIdRequired,
    /// Body `name` field was empty (matches `design_model.BadPageName`).
    BadPageName,
    /// `design_model.setDesignPage` returned `ItemPathMissing` (the parent workspace_item has no `path`).
    ItemPathMissing,
    /// `setDesignPage` failed for some other DB reason.
    DbError,
    /// Insert succeeded but the new page wasn't visible in the subsequent `listPages` (consistency violation — extremely unlikely; surfaces as 500 so the caller can …
    PageNotVisible,
    /// `allocator.dupe` failed while building the output struct.
    OutOfMemory,
};

/// Inputs to the create-page use-case.
pub const CreatePageInput = struct {
    item_id: []const u8,
    name: []const u8,
    width: i64,
    height: i64,
};

/// Output of the create-page use-case.
pub const CreatePageOutput = struct {
    /// The freshly-created (or idempotently-upserted) page.
    page: design_model.DesignPage,
};

// Use case

/// Create (or upsert) a design page.
fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.database.Db,
    input: CreatePageInput,
) DesignPageCreateError!CreatePageOutput {
    // 1.
    if (input.item_id.len == 0) return error.ItemIdRequired;
    if (input.name.len == 0) return error.BadPageName;

    // 2.
    const new_id = design_model.setDesignPage(allocator, db, .{
        .item_id = input.item_id,
        .page_name = input.name,
        .width = input.width,
        .height = input.height,
    }) catch |err| switch (err) {
        error.BadPageName => return error.BadPageName,
        error.ItemPathMissing => return error.ItemPathMissing,
        else => return error.DbError,
    };
    defer allocator.free(new_id);

    // 3.
    const pages = design_model.listPages(allocator, db, input.item_id) catch return error.DbError;
    defer design_model.freePages(allocator, pages);

    // 4. Locate the new page by its id.
    for (pages) |p| {
        if (!std.mem.eql(u8, p.id, new_id)) continue;

        // 5.
        var duped_id: ?[]u8 = null;
        var duped_workspace_item_id: ?[]u8 = null;
        var duped_name: ?[]u8 = null;
        var duped_workspace_item_task_id: ?[]u8 = null;
        var duped_created_at: ?[]u8 = null;
        var duped_updated_at: ?[]u8 = null;
        errdefer {
            if (duped_id) |v| allocator.free(v);
            if (duped_workspace_item_id) |v| allocator.free(v);
            if (duped_name) |v| allocator.free(v);
            if (duped_workspace_item_task_id) |v| allocator.free(v);
            if (duped_created_at) |v| allocator.free(v);
            if (duped_updated_at) |v| allocator.free(v);
        }
        duped_id = try allocator.dupe(u8, p.id);
        duped_workspace_item_id = try allocator.dupe(u8, p.workspace_item_id);
        duped_name = try allocator.dupe(u8, p.name);
        duped_workspace_item_task_id = try allocator.dupe(u8, p.workspace_item_task_id);
        duped_created_at = try allocator.dupe(u8, p.created_at);
        duped_updated_at = try allocator.dupe(u8, p.updated_at);

        return .{ .page = .{
            .id = duped_id.?,
            .workspace_item_id = duped_workspace_item_id.?,
            .name = duped_name.?,
            .workspace_item_task_id = duped_workspace_item_task_id.?,
            .width = p.width,
            .height = p.height,
            .position = p.position,
            .created_at = duped_created_at.?,
            .updated_at = duped_updated_at.?,
        } };
    }

    return error.PageNotVisible;
}

// Handler

/// Thin orchestrator over `useCase`.
pub fn designPagesCreateHandler(
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

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(CreatePageBody, allocator, req.body, .{}) catch {
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

    // Defaults match the Figma-lite 1440×1024 canvas from design §5.1.
    const width = parsed.width orelse 1440;
    const height = parsed.height orelse 1024;

    // 2. Delegate to the use-case.
    const output = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .name = parsed.name,
        .width = width,
        .height = height,
    }) catch |err| {
        // 3. Map the use-case error to an HTTP response.
        const status: u16 = switch (err) {
            error.ItemIdRequired => 400,
            error.BadPageName => 400,
            error.ItemPathMissing => 400,
            error.DbError => 500,
            error.PageNotVisible => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.BadPageName => "name is required",
            error.ItemPathMissing => "design item must have a path",
            error.DbError => "Failed to create page",
            error.PageNotVisible => "Page was created but not visible in list",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Free the useCase's heap-owned page slices.
    defer {
        allocator.free(output.page.id);
        allocator.free(output.page.workspace_item_id);
        allocator.free(output.page.name);
        allocator.free(output.page.created_at);
        allocator.free(output.page.updated_at);
    }

    // 4.
    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(
            allocator,
            http_response.makeDesignPageResponse(output.page),
            .{},
        ),
    });
}

// ===== Tests merged from design_pages_create_test.zig (2026-09-11 flatten) ===== Static regression checks for the `POST /design/pages` handler.

const testing = std.testing;

// ─── Contract 6: response includes workspace_item_task_id FK field ───────
test "makeDesignPageResponse serializes workspace_item_task_id on the wire" {
    const allocator = testing.allocator;

    // Build the canonical page row that setDesignPage produces.
    const page = design_model.DesignPage{
        .id = try allocator.dupe(u8, "page_test_abc"),
        .workspace_item_id = try allocator.dupe(u8, "item_test_xyz"),
        .name = try allocator.dupe(u8, "Login"),
        .workspace_item_task_id = try allocator.dupe(u8, "task_test_123"),
        .width = 1440,
        .height = 1024,
        .position = 0,
        .created_at = try allocator.dupe(u8, ""),
        .updated_at = try allocator.dupe(u8, ""),
    };
    defer {
        allocator.free(page.id);
        allocator.free(page.workspace_item_id);
        allocator.free(page.name);
        allocator.free(page.workspace_item_task_id);
        allocator.free(page.created_at);
        allocator.free(page.updated_at);
    }

    // Map the model struct into the wire response struct (the same helper the handler calls).
    const response = http_response.makeDesignPageResponse(page);

    // Serialize via std.json.Stringify.valueAlloc — the exact code path design_pages_create.zig uses for the 201 response body.
    const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(json);

    // The FK MUST be present in the wire payload (the whole point of the design-page-task-fk migration).
    const expected_key_value =
        "\"workspace_item_task_id\":\"task_test_123\"";
    if (std.mem.indexOf(u8, json, expected_key_value) == null) {
        std.debug.print(
            "\n!! Wire payload missing workspace_item_task_id !!\n" ++
                "   JSON body did not contain the expected FK key/value pair.\n" ++
                "   Actual body:\n{s}\n" ++
                "   Expected substring: {s}\n",
            .{ json, expected_key_value },
        );
        return error.WorkspaceItemTaskIdWireFieldMissing;
    }
}
