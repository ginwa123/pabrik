//! HTTP handler + use-case for `POST
//! /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
const http_response = @import("http_response.zig");

// =====================================================================
// Domain types
// =====================================================================

/// Outcome of `startAgentUseCase`. `.triggered` — success.
pub const StartAgentOutcome = union(enum) {
    triggered,
    task_not_found,
    worker_already_running,
};

// =====================================================================
// Use-case (pure-ish)
// =====================================================================

/// Trigger an LLM worker on the task's existing session WITHOUT queueing a
/// new user message.
pub fn startAgentUseCase(
    allocator: std.mem.Allocator,
    db: *database.Db,
    di: *pabrikcore.App,
    task_id: []const u8,
    owner: []const u8,
) !StartAgentOutcome {
    // 1. Validate the task exists. `getWorkspaceItemTask` returns
    //    null when the row is absent (vs. propagating a NOT_FOUND
    //    error); we map that to `.task_not_found`.
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, db, task_id) catch null;
    const task = task_opt orelse return .task_not_found;
    defer task.deinit(allocator);

    // 2. Refuse if a worker is currently running for this session. Mirrors
    // the running-check in task_delete.zig:409.
    if (ai_mod.llm_history.isTaskRunning(allocator, db, task_id)) {
        return .worker_already_running;
    }

    // 3. Read the session row so we can forward selected_profile_model +
    // is_auto_retry_until_stop to the worker pool.
    var session_profile: []const u8 = "";
    var session_auto_retry: []const u8 = "0";
    // Owned dupes live at function scope so they outlive `emit_run_agent`
    // below (which dupes them synchronously into the long-lived allocator).
    var session_profile_owned: ?[]u8 = null;
    var session_auto_retry_owned: ?[]u8 = null;
    defer {
        if (session_profile_owned) |b| allocator.free(b);
        if (session_auto_retry_owned) |b| allocator.free(b);
    }
    {
        // Block scope, NOT function scope: `db.query` hands back a `Rows`
        // holding an UNFINALIZED `sqlite3_stmt`, which is an open read
        // transaction on the shared connection.
        var session_row = try db.query(
            allocator,
            "SELECT COALESCE(selected_profile_model, ''), COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?",
            &.{task_id},
        );
        defer session_row.deinit();

        // `row.deinit` frees every `row.values[i]` at the end of the row
        // scope below, but `emit_run_agent` reads these slices afterwards —
        // borrow-then-free copies freed memory into the worker params, and
        if (try session_row.next()) |row| {
            defer row.deinit(allocator);
            if (row.values.len >= 2) {
                // Already-corrupted rows (0xAA poison from before the fix)
                // are invalid UTF-8 — fall back to empty so we never
                // forward garbage to the worker (which would re-persist it).
                const raw_profile = row.values[0];
                const raw_retry = row.values[1];
                if (std.unicode.utf8ValidateSlice(raw_profile)) {
                    session_profile_owned = try allocator.dupe(u8, raw_profile);
                    session_profile = session_profile_owned.?;
                }
                // is_auto_retry_until_stop is "0"/"1" — same guard for symmetry.
                if (std.unicode.utf8ValidateSlice(raw_retry) and raw_retry.len > 0) {
                    session_auto_retry_owned = try allocator.dupe(u8, raw_retry);
                    session_auto_retry = session_auto_retry_owned.?;
                }
            }
        }
    }

    // 4. Submit the LLM work to the Io group.
    const resolved_cwd: []const u8 = if (task.cwd.len > 0) task.cwd else "";

    try di.emit_run_agent(.{
        .session_id = task_id,
        .session_name = task.name,
        .queue_message = "",
        .cwd = resolved_cwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .selected_profile_model = session_profile,
        .is_auto_retry_until_stop = session_auto_retry,
        .skip_initial_queue_message = true,
        // Owner rides along so the concurrent insert_worker task stamps the
        // session row at INSERT time when it has to upsert one (brand-new
        // task, no session row yet).
        .user_id = owner,
    });

    // Claim an ownerless session row the upsert above may have left behind
    // (INSERT OR IGNORE no-ops on an existing ownerless row). Only claims
    // ownerless rows, so a real owner is never overwritten.
    if (di.auth_enabled and owner.len > 0) {
        db.exec(
            allocator,
            "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
            &[_][]const u8{ owner, task_id },
        ) catch {};
    }

    return .triggered;
}

// =====================================================================
// Handler
// =====================================================================

/// `POST
/// /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.
pub fn startAgentHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate `:task_id` path parameter.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    // 2. Resolve the `App` singleton (carries the DB handle
    //    + the Io group that `emit_run_agent` schedules onto).
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case. Owner rides along so the worker's session
    // upsert keeps the row owned under `--auth` (plan 2026-09-25).
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";
    const outcome = startAgentUseCase(allocator, sqlite_db, di, task_id, owner) catch |err| {
        std.log.err("start_agent: useCase failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "start_agent use-case failed" }),
        });
    };

    // 4. Map the use-case outcome to an HTTP response.
    switch (outcome) {
        .triggered => {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"triggered\"}}",
                    .{task_id},
                ),
            });
        },
        .task_not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task not found" }),
            });
        },
        .worker_already_running => {
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worker already running" }),
            });
        },
    }
}
