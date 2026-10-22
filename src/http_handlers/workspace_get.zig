//! `GET /api/workspaces/:id` — fetch a workspace by id. Layered as `useCase`
//! (resolve singleton + read DB) and a thin handler that maps the outcome +
//! errors to status codes / JSON.

const std = @import("std");
const mod = @import("mod.zig");
const pabrikcore = mod.pabrikcore;
const gserverz = pabrikcore.gserverz;
const http_response = mod.http_response;
const auth_common = @import("auth_common.zig");
const workspace_vm = @import("../agentic_loop/workspace_vm.zig");
const runtime_mode = @import("../runtime_mode.zig");

/// SQLite error info surfaced from the use-case to the handler.
pub const DbErrorInfo = struct {
    sqlite_message: []const u8,
};

/// Tagged outcome of the workspace-get use-case.
pub const WorkspaceGetResult = union(enum) {
    found: WorkspaceGetData,
    not_found,
    /// The SQL query failed at the prepare/bind stage (Rows was never
    /// created, so no `sqlite3_errmsg` capture is available).
    query_failed: DbErrorInfo,
    /// `Rows.next()` returned an error after the Rows object was
    /// created; `sqlite_message` is the last `sqlite3_errmsg(db)`
    /// value (may be empty if the backend couldn't capture it).
    row_fetch_failed: DbErrorInfo,
    out_of_memory,
    id_required,
};

pub const WorkspaceGetData = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    /// Whether this workspace runs in a microVM on THIS server (Migration
    /// 115). False on a local server, which has no Firecracker at all.
    is_vm: bool,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    id: []const u8,
    owner: []const u8,
    mode: runtime_mode.Mode,
) WorkspaceGetResult {
    if (id.len == 0) return .id_required;

    // `db.query` returns `Error!Rows`; on failure the Rows object is never
    // created, so we can't capture the SQLite error message.
    var rows = db.query(
        allocator,
        "SELECT id, name, created_at, updated_at, is_vm FROM workspaces WHERE id = ? AND " ++ comptime auth_common.workspaceVisibilityClause("workspaces"),
        &.{ id, owner, owner },
    ) catch |err| {
        // Build a best-effort message. The sqlite3_errmsg is not available
        // here because Rows was never created; surface the error name as the
        // fallback.
        const fallback: []const u8 = @errorName(err);
        const duped = allocator.dupe(u8, fallback) catch return .out_of_memory;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            else => .{ .query_failed = .{ .sqlite_message = duped } },
        };
    };
    defer rows.deinit();

    // `rows.next()` calls `sqlite3_errmsg` on failure and caches the message
    // in `Rows.last_error_msg`. We dup it before `rows.deinit` so the handler
    // can render it.
    const row = (rows.next() catch {
        const captured = rows.getLastErrorMessage() orelse "";
        const duped = allocator.dupe(u8, captured) catch return .out_of_memory;
        return .{ .row_fetch_failed = .{ .sqlite_message = duped } };
    }) orelse return .not_found;

    // Dupe the strings BEFORE `rows.deinit()` fires below.
    return .{
        .found = .{
            .id = allocator.dupe(u8, row.values[0]) catch return .out_of_memory,
            .name = allocator.dupe(u8, row.values[1]) catch return .out_of_memory,
            .created_at = allocator.dupe(u8, row.values[2]) catch return .out_of_memory,
            .updated_at = allocator.dupe(u8, row.values[3]) catch return .out_of_memory,
            // The stored flag says the workspace was created by a saas server;
            // the mode says whether there is a Firecracker here to run it in.
            .is_vm = workspace_vm.runsInVm(mode, row.values[4].len > 0 and row.values[4][0] == '1'),
        },
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workspaceGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";

    // Not-found (not 403) when the workspace belongs to another user, so a
    // caller cannot probe for the existence of someone else's ids.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, di.auth_enabled, req.headers) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owner);

    const outcome = useCase(allocator, sqlite_db, id, owner, runtime_mode.currentMode());

    switch (outcome) {
        .found => |data| {
            // The four strings are duped by useCase; the response body copies
            // them into a fresh allocation.
            const body = try std.fmt.allocPrint(
                allocator,
                "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\",\"is_vm\":{s}}}",
                .{ data.id, data.name, data.created_at, data.updated_at, if (data.is_vm) "true" else "false" },
            );
            return res.jsonResponse(.{ .status_code = 200, .data = body });
        },
        .not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = "{\"error\":\"Workspace not found\"}",
            });
        },
        .id_required => {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "id required" }),
            });
        },
        .out_of_memory => {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        },
        .query_failed => |info| {
            // `info.sqlite_message` is duped by useCase but lives in the
            // per-request arena — freed when the request scope ends (no
            // manual `defer allocator.free` needed; see the arena note on
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"Database query failed: {s}\"}}",
                    .{info.sqlite_message},
                ),
            });
        },
        .row_fetch_failed => |info| {
            // Two shapes: with a captured sqlite message (most common,
            // surfaces e.g. "no such column: foo") or without
            // (backend couldn't capture — generic fallback).
            const data = if (info.sqlite_message.len > 0)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"Failed to fetch row: {s}\"}}",
                    .{info.sqlite_message},
                )
            else
                try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch row" });
            return res.jsonResponse(.{ .status_code = 500, .data = data });
        },
    }
}

// =====================================================================
// Tests
// =====================================================================

const testing = @import("std").testing;

test "workspaceGetError DbErrorInfo shape is plain" {
    // Sanity: the struct is a plain data type so the captured
    // sqlite message can be examined in tests without unwrapping.
    const info: DbErrorInfo = .{ .sqlite_message = "no such column: foo" };
    try testing.expectEqualStrings("no such column: foo", info.sqlite_message);
}

