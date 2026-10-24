const std = @import("std");
const http_response = @import("http_response.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const llm_history = pabrikcore.llm_history;
const tags_validation = @import("tags_validation.zig");
const image_urls_validation = @import("image_urls_validation.zig");
const video_urls_validation = @import("video_urls_validation.zig");
const kanban_deps = pabrikcore.ai_mod.kanban_deps;

/// PUT /api/workspaces/tasks/:task_id - Update task by ID only (no
/// workspace/item needed). Body: { name?, session_id?, description?, tags?,
/// image_urls?, cwd? }.
pub fn tasksUpdateByIdHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
/// (Same body and behavior as tasksUpdateByIdHandler.)
pub fn tasksUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

// =====================================================================
// Error set + input/output types for the useCase
// =====================================================================

pub const TaskUpdateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    FailedToUpdateTask,
    /// Kanban task tags validation (Migration 067). Empty,
    /// too long, or contains forbidden characters (only
    /// [a-zA-Z0-9_-] allowed). See tags_validation.zig.
    InvalidTags,
    /// Per-task cwd validation (Migration 070 — kanban-cwd-session- optional
    /// plan).
    CwdTooLong,
    CwdNotAbsolute,
    CwdContainsControlChar,
    /// Image urls validation (Migration 069 — kanban image urls column).
    /// Mirrors the create handler's errors — malformed data URL prefix (400)
    /// or the 10 MB total cap (413).
    InvalidImageUrls,
    ImageUrlsTooLarge,
    /// Video urls validation (Migration 090). Same contract with
    /// a 25 MB cap.
    InvalidVideoUrls,
    VideoUrlsTooLarge,
    /// Migration 111 — `depends_on` rejects a task that names itself, a task
    /// from a DIFFERENT kanban, a set that would close a dependency cycle, and
    /// a set over the 32-dependency cap.
    DependencySelfReference,
    DependencyNotInItem,
    DependencyCycle,
    DependencyCountExceeded,
};

/// Slice of optional fields the client may send. Mirrors
/// `http_response.TaskUpdateRequest` but expressed as a struct-local type
/// to avoid a forced include in this file.
const TaskUpdateInput = struct {
    task_id: []const u8,
    body: http_response.TaskUpdateRequest,
    db: *pabrikcore.sqlite.SqliteBackend,
};

/// Result of a successful task update. The handler serializes the
/// `id` field into a small `{"success":true,"id":"..."}` JSON response.
const TaskUpdateResult = struct {
    task_id: []const u8,
};

// =====================================================================
// Handler
// =====================================================================

/// Shared implementation for both task-update routes. The two
/// registrations differ only in URL shape; the body parsing, cascade
/// logic, and routine-fields branch are identical.
fn updateTaskHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const result = useCase(allocator, .{
        .task_id = task_id,
        .body = json_body,
        .db = sqlite_db,
    }) catch |err| {
        // (unchanged error-mapping block — collapsed for the diff)
        const status: u16 = switch (err) {
            error.FailedToUpdateTask => 500,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.InvalidVideoUrls => 400,
            error.VideoUrlsTooLarge => 413,
            error.CwdTooLong, error.CwdNotAbsolute, error.CwdContainsControlChar => 400,
            error.DependencySelfReference, error.DependencyNotInItem, error.DependencyCycle, error.DependencyCountExceeded => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "Request body required",
            error.FailedToUpdateTask => "Failed to update task",
            error.InvalidTags => "tags must be non-empty, ≤50 chars, and contain only letters, digits, hyphens, and underscores",
            error.InvalidImageUrls => "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs",
            error.ImageUrlsTooLarge => "image_urls payload too large (max 10 MB)",
            error.InvalidVideoUrls => "video_urls must be `||`-delimited data:video/<mime>;base64,... URLs",
            error.VideoUrlsTooLarge => "video payload too large (max 25 MB)",
            error.CwdTooLong => "cwd path too long (max 4 KiB)",
            error.CwdNotAbsolute => "cwd must be an absolute path",
            error.CwdContainsControlChar => "cwd contains a control character",
            error.DependencySelfReference => "depends_on: a task cannot depend on itself",
            error.DependencyNotInItem => "depends_on: every id must be a task of the same kanban item",
            error.DependencyCycle => "depends_on: that would create a dependency cycle",
            error.DependencyCountExceeded => "depends_on: at most 32 dependencies per task",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Chunk 5 of kanban-task-notification-icon: every rename/edit/pin counts
    // as a human touch — stamp last_human_touched_at so the kanban card flips
    // from the orange "awaiting review" dot to the green "reviewed"
    ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        sqlite_db,
        task_id,
        null,
    ) catch |err| {
        if (pabrikcore.loggermod.getGlobal()) |logger| {
            logger.warnFmt("task_update: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
        }
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{result.task_id}) });
}

// =====================================================================
// useCase
// =====================================================================

fn useCase(allocator: std.mem.Allocator, input: TaskUpdateInput) TaskUpdateError!TaskUpdateResult {
    const task_id = input.task_id;

    // Description branch. When `body.description` is present (non-null),
    // overwrite the column with the new value.
    if (input.body.description) |desc| {
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", description = ");
        if (desc.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, desc);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Tags branch (Migration 067 — kanban task tags feature).
    if (input.body.tags) |raw_tags| {
        // Validate + normalize. Returns a JSON-encoded array
        // string ('' when no tags). Borrowed from the per-request
        // arena; arena reaps it on request teardown.
        const validated_tags = tags_validation.validateAndNormalizeTags(
            allocator,
            raw_tags,
        ) catch return error.InvalidTags;

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", tags = ");
        if (validated_tags.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_tags);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Image urls branch (Migration 069 — kanban image urls column).
    if (input.body.image_urls) |raw_urls| {
        // Validate. Returns the already-joined `||`-delimited string
        // (borrowed from the per-request arena; arena reaps it on request
        // teardown).
        const validated_urls = image_urls_validation.validateImageUrls(raw_urls) catch |err| return switch (err) {
            error.ImageUrlsTooLarge => error.ImageUrlsTooLarge,
            error.InvalidImageUrl => error.InvalidImageUrls,
        };

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", image_urls = ");
        if (validated_urls.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_urls);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Video urls branch (Migration 090 — kanban video urls column).
    // Same shape as image_urls above: present means overwrite, ""
    // clears, null leaves unchanged. Validated prefix + 25 MB cap.
    if (input.body.video_urls) |raw_urls| {
        const validated_urls = video_urls_validation.validateVideoUrls(raw_urls) catch |err| return switch (err) {
            error.VideoUrlsTooLarge => error.VideoUrlsTooLarge,
            error.InvalidVideoUrl => error.InvalidVideoUrls,
        };

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", video_urls = ");
        if (validated_urls.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_urls);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Per-task cwd branch (Migration 070 — kanban-cwd-session- optional
    // plan).
    if (input.body.cwd) |raw_cwd| {
        // Reuse the create-handler validation. Mirrors the create
        // path exactly so a value that's accepted at create time
        // is also accepted at update time (and vice versa).
        if (raw_cwd.len > 4096) return error.CwdTooLong;
        if (raw_cwd.len > 0 and !std.fs.path.isAbsolute(raw_cwd)) return error.CwdNotAbsolute;
        for (raw_cwd) |c| {
            if (c < 0x20 or c == 0x7f) return error.CwdContainsControlChar;
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", cwd = ");
        if (raw_cwd.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, raw_cwd);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Dependencies branch (Migration 111 — kanban task dependencies).
    // REPLACE-ALL semantics: a present array (including `[]`) replaces the
    // whole set; an absent field leaves it untouched.
    if (input.body.depends_on) |raw_ids| {
        const item_id = fetchTaskItemId(allocator, input.db, task_id) catch
            return error.FailedToUpdateTask;
        defer allocator.free(item_id);
        // Empty-slice-as-NULL binding rule: a missing parent would silently
        // match nothing (`WHERE id = NULL`), so refuse it instead.
        if (item_id.len == 0) return error.FailedToUpdateTask;

        kanban_deps.validateAndReplace(allocator, input.db, item_id, task_id, raw_ids) catch |err| return switch (err) {
            error.SelfDependency => error.DependencySelfReference,
            error.DependencyNotInItem => error.DependencyNotInItem,
            error.DependencyCycle => error.DependencyCycle,
            error.TooManyDependencies => error.DependencyCountExceeded,
            error.QueryFailed => error.FailedToUpdateTask,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    // Conditional split: route name updates through the cascade
    // (updateTaskName → updateSessionName → SSE broadcast).
    if (input.body.name) |n| {
        llm_history.updateTaskName(allocator, input.db, task_id, n) catch {
            return error.FailedToUpdateTask;
        };
    }

    return .{ .task_id = task_id };
}

/// The kanban (or other workspace item) that owns this task — '' when the task
/// row is gone.
fn fetchTaskItemId(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    task_id: []const u8,
) ![]u8 {
    var q = try db.query(allocator,
        "SELECT COALESCE(workspace_item_id, '') FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer q.deinit();

    const row = (try q.next()) orelse return allocator.dupe(u8, "");
    defer row.deinit(allocator);
    return allocator.dupe(u8, row.values[0]);
}

// ===== Tests merged from task_update_test.zig (2026-09-11 flatten) ===== The
// contracts this file used to assert were all text-shaped: "does the source
// contain `llm_history.updateTaskName`", "is the `tasks` segment a literal",
