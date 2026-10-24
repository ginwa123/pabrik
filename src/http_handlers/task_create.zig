//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks`. Body: `{ name,
//! session_id?, task_type? ('standard'|'memory'), memory_name?,
//! memory_content? }`.

const std = @import("std");
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const memories_mod = pabrikcore.memories;
const tags_validation = @import("tags_validation.zig");
const image_urls_validation = @import("image_urls_validation.zig");
const video_urls_validation = @import("video_urls_validation.zig");
const kanban_deps = pabrikcore.ai_mod.kanban_deps;
const task_skills = @import("task_skills.zig");

/// Process-local monotonic counter for task_id generation.
var task_id_counter: std.atomic.Value(u64) = .init(0);
const on_event_sent_kanban = pabrikcore.ai_mod.on_event_sent_kanban;

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code in the handler (see the handler's
/// `switch (err)` below).
pub const TaskCreateError = error{
    // 400 — path params / body validation
    ItemIdRequired,
    MissingBody,
    InvalidJson,
    // 400 — the per-task 'routine' task_type was deleted (Migration
    // 084). Routines are now first-class workspace items.
    RoutineTasksRemoved,
    // 400 — memory-task validation
    MemoryNameRequired,
    InvalidMemoryName,
    MemoryContentRequired,
    // 400 / 404 — memory-task workspace_item checks
    WorkspaceItemNotFound,
    NotAFolderItem,
    NoPathForMemory,
    // 500 — memory-task file/DB ops
    FailedToBuildMemoriesPath,
    FailedToWriteMemoryFile,
    MemoryTaskInsertFailed,
    // 500 — standard-task DB ops
    StandardTaskCreateFailed,
    // 400 — kanban task tags validation (Migration 067). Empty,
    // too long, or contains forbidden characters (only
    // [a-zA-Z0-9_-] allowed). See tags_validation.zig.
    InvalidTags,
    // 400 / 413 — kanban image_urls validation (Migration 069).
    InvalidImageUrls,
    ImageUrlsTooLarge,
    // 400 / 413 — kanban video_urls validation (Migration 090).
    // Same contract as image_urls with a 25 MB cap.
    InvalidVideoUrls,
    VideoUrlsTooLarge,
    // 400 — per-task cwd validation (Migration 070).
    CwdTooLong,
    CwdNotAbsolute,
    CwdContainsControlChar,
    // 400 — per-task skill validation (Migration 110, array form 112).
    SkillNameTooLong,
    SkillNameContainsControlChar,
    TooManySkills,
    // 400 — `depends_on` validation (Migration 111): a task cannot depend on
    // itself, on a task from another kanban, on a set that would close a
    // cycle, or on more than 32 tasks.
    DependencySelfReference,
    DependencyNotInItem,
    DependencyCycle,
    DependencyCountExceeded,
    // Underlying I/O / alloc errors (required by the type system
    // even though they're unreachable on the per-request arena)
    OutOfMemory,
    Canceled,
};

pub const TaskCreateInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    io: std.Io,
    body: http_response.TaskCreateRequest,
    /// Owning user id for any `sessions` row this create path writes
    /// (unattended-flag INSERT below).
    owner: []const u8 = "",
};

/// Tagged outcome of the use-case. The fields are the data needed
/// to build the response for each task type.
pub const TaskCreateResult = union(enum) {
    memory: MemoryResult,
    standard: StandardResult,
};

pub const MemoryResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
};

pub const StandardResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    kanban_column_id: ?[]const u8,
    kanban_position: i64,
    /// Caller-supplied session_id (if any). When null the JSON response emits
    /// "session_id":null.
    session_id: ?[]const u8,
    /// JSON-encoded array of tag strings (Migration 067 — kanban task tags).
    tags: []const u8 = "",
    /// Per-task cwd (Migration 070 — kanban-cwd-session-optional plan,
    /// 2026-08-06). Borrowed from the per-request arena (validated above).
    cwd: []const u8 = "",
    /// Media-presence flags (media-flags change). Derived from the validated
    /// payload lengths so the create response tells the frontend whether
    /// to lazy-fetch via the media endpoint.
    is_have_image: bool = false,
    is_have_video: bool = false,
};

// Typed response structs. Serialized via std.json.Stringify.valueAlloc (NOT
// hand-rolled JSON via the std.fmt formatting helpers) for two reasons: 1.

// NOTE: RoutineResponse deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).
const MemoryResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "memory",
    session_id: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

const StandardResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "standard",
    session_id: ?[]const u8,
    kanban_column_id: ?[]const u8 = null,
    kanban_position: i64 = 0,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Empty string means the task has no
    /// tags.
    tags: []const u8 = "",
    /// Per-task cwd override (Migration 070). Empty string means the task has
    /// no per-task cwd (falls back to kanban-level path + sandbox). Plan:
    /// docs/superpowers/plans/2026-08-06- kanban-cwd-session-optional.md
    cwd: []const u8 = "",
    /// Media-presence flags (media-flags change). True when the just-INSERTed
    /// row has media; the frontend lazy-fetches via the media endpoint.
    is_have_image: bool = false,
    is_have_video: bool = false,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

// =====================================================================
// Use case
// =====================================================================

/// Generate a unique `task_<unix_ms>_<intra_ms_counter>` id. The millisecond
/// prefix preserves wire-compat with previously-stored rows (`task_<ms>`) and
/// keeps IDs roughly time-sortable.
fn generateTaskId(allocator: std.mem.Allocator, io: std.Io) TaskCreateError![]u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const ms: i64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    const counter = task_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "task_{d}_{d}", .{ ms, counter }) catch return error.OutOfMemory;
}

/// Memory branch. Writes the .md file + inserts the task row.
fn createMemoryTask(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!MemoryResult {
    const memory_name = input.body.memory_name orelse return error.MemoryNameRequired;
    if (!memories_mod.isValidMemoryName(memory_name)) return error.InvalidMemoryName;
    const memory_content = input.body.memory_content orelse return error.MemoryContentRequired;

    // Look up the parent workspace_item to get its `path` (the project
    // root — the .md file is scoped to `<path>/.pabrik/memories/<name>.md`).
    const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, db, input.item_id) catch return error.WorkspaceItemNotFound;
    const item = item_opt orelse return error.WorkspaceItemNotFound;
    defer item.deinit(allocator);

    // Refuse non-folder items — `loadLocalKnowledge` reads from
    // `<cwd>/.pabrik/memories/`, so the cwd must be a real directory
    // (which is what a 'folder' item's path is).
    if (!std.mem.eql(u8, item.item_type, "folder")) return error.NotAFolderItem;
    const cwd = item.path orelse return error.NoPathForMemory;

    const dir_path = memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse return error.FailedToBuildMemoriesPath;
    defer allocator.free(dir_path);

    if (!memories_mod.writeLocalMemoryFile(allocator, input.io, dir_path, memory_name, memory_content)) {
        return error.FailedToWriteMemoryFile;
    }

    // Migration 062: persist description. Same dynamic-SQL builder Migration
    // 062: persist description.
    {
        var cols_buf: std.ArrayList(u8) = .empty;
        defer cols_buf.deinit(allocator);
        var vals_buf: std.ArrayList(u8) = .empty;
        defer vals_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try cols_buf.appendSlice(allocator, "id, name, workspace_item_id, task_type");
        try vals_buf.appendSlice(allocator, "?, ?, ?, 'memory'");
        try bind_values.appendSlice(allocator, &[_][]const u8{
            task_id, input.body.name, input.item_id,
        });

        if (input.body.description) |d| {
            if (d.len == 0) {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, d);
            }
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.print(
            allocator,
            "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})",
            .{ cols_buf.items, vals_buf.items },
        );

        db.exec(allocator, sql_buf.items, bind_values.items) catch {
            _ = memories_mod.deleteLocalMemoryFile(allocator, input.io, dir_path, memory_name);
            return error.MemoryTaskInsertFailed;
        };
    }

    return .{ .task_id = task_id, .name = input.body.name, .workspace_item_id = input.item_id };
}

/// Standard branch. Creates the task row and, if the parent is a
/// kanban, auto-assigns it to the first column at
/// MAX(kanban_position) + 1.
fn createStandardTask(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!StandardResult {
    // Migration 111 — resolve the requested dependencies BEFORE the task row
    // exists, so a rejected set (self-reference, a task from another board, a
    // cycle, over the cap) cannot leave a half-created card behind.
    const dep_ids: [][]const u8 = if (input.body.depends_on) |raw_ids|
        kanban_deps.normalizeIds(allocator, task_id, raw_ids) catch |err| return switch (err) {
            error.SelfDependency => error.DependencySelfReference,
            error.DependencyNotInItem => error.DependencyNotInItem,
            error.DependencyCycle => error.DependencyCycle,
            error.TooManyDependencies => error.DependencyCountExceeded,
            error.QueryFailed => error.StandardTaskCreateFailed,
            error.OutOfMemory => error.OutOfMemory,
        }
    else
        &.{};
    // Freeing an empty slice is a no-op, so this is safe on both branches.
    defer allocator.free(dep_ids);

    if (dep_ids.len > 0) {
        kanban_deps.validate(allocator, db, input.item_id, task_id, dep_ids) catch |err| return switch (err) {
            error.SelfDependency => error.DependencySelfReference,
            error.DependencyNotInItem => error.DependencyNotInItem,
            error.DependencyCycle => error.DependencyCycle,
            error.TooManyDependencies => error.DependencyCountExceeded,
            error.QueryFailed => error.StandardTaskCreateFailed,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    // Validate + normalize the tags payload (Migration 067). The helper
    // returns a heap-allocated JSON-encoded array string (or "" for "no
    // tags") — the right shape for the `tags` column.
    const validated_tags = tags_validation.validateAndNormalizeTags(
        allocator,
        input.body.tags,
    ) catch return error.InvalidTags;

    // Validate the image_urls payload (Migration 069).
    const validated_image_urls = image_urls_validation.validateImageUrls(
        input.body.image_urls orelse "",
    ) catch |err| return switch (err) {
        error.ImageUrlsTooLarge => error.ImageUrlsTooLarge,
        error.InvalidImageUrl => error.InvalidImageUrls,
    };

    // Validate the video_urls payload (Migration 090). Same shape as
    // image_urls: already-joined `||`-delimited string, validated
    // prefix + allowlist + 25 MB cap.
    const validated_video_urls = video_urls_validation.validateVideoUrls(
        input.body.video_urls orelse "",
    ) catch |err| return switch (err) {
        error.VideoUrlsTooLarge => error.VideoUrlsTooLarge,
        error.InvalidVideoUrl => error.InvalidVideoUrls,
    };

    // Validate the per-task cwd payload (Migration 070). The wire format is
    // an absolute path string from the FilePickerDialog (or empty / null for
    // cwd-less).
    const validated_cwd = blk: {
        const raw = input.body.cwd orelse "";
        if (raw.len == 0) break :blk raw;
        if (raw.len > 4096) return error.CwdTooLong;
        // Must be absolute (POSIX '/' or Windows 'C:\', '\\', ...).
        // Frontend's FilePickerDialog only emits absolute paths; this guard
        // protects against a misbehaving API client (curl, etc.).
        if (!std.fs.path.isAbsolute(raw)) return error.CwdNotAbsolute;
        // Reject any control characters (\x00..\x1f or \x7f). Paths
        // with embedded NULs would crash std.fs.path.join downstream.
        for (raw) |c| {
            if (c < 0x20 or c == 0x7f) return error.CwdContainsControlChar;
        }
        break :blk raw;
    };

    // Migration 112 — the skills this task asks its agent to use, validated,
    // deduplicated and joined into the `||` form the column stores. The
    // pre-112 single name still works for a client that never sent the array.
    const validated_skill_names = task_skills.normalize(
        allocator,
        input.body.skill_names,
        input.body.skill_name,
    ) catch |err| return switch (err) {
        error.SkillNameTooLong => error.SkillNameTooLong,
        error.SkillNameContainsControlChar => error.SkillNameContainsControlChar,
        error.TooManySkills => error.TooManySkills,
        error.OutOfMemory => error.OutOfMemory,
    };

    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        input.body.name,
        input.item_id,
        "standard",
        input.body.description,
        validated_tags,
        // Migration 069 — image_urls. Borrowed from the per-request
        // arena (validated above). Pass through verbatim.
        validated_image_urls,
        // Migration 070 — per-task cwd override. Borrowed from the
        // per-request arena (validated above). Pass through verbatim.
        validated_cwd,
        // Migration 090 — video_urls (trailing param). Same contract.
        validated_video_urls,
        validated_skill_names,
    ) catch return error.StandardTaskCreateFailed;

    // Chunk 5 of kanban-task-notification-icon: creating a card is a human
    // touch.
    ai_mod.llm_history.updateTaskLastHumanTouchedAt(allocator, db, task_id, null) catch |err| {
        if (pabrikcore.loggermod.getGlobal()) |logger| {
            logger.warnFmt("task_create: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
        }
    };
    // NOTE: do NOT `defer task.deinit(allocator)` here.

    // Kanban auto-assign: if the parent is a kanban, append the new
    // task to the bottom of the first column. Errors here are
    // non-fatal — the task row is already created.
    var kanban_column_id: ?[]u8 = null;
    var kanban_position: i64 = 0;
    // NOTE: do NOT `defer allocator.free(kanban_column_id)` here.
    // kanban_column_id (when set) is a dupe on the per-request arena that is
    // BORROWED into the returned StandardResult.

    {
        const parent_is_kanban = blk: {
            var q = db.query(allocator,
                "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'",
                &[_][]const u8{input.item_id}) catch break :blk false;
            defer q.deinit();
            const row = (q.next() catch break :blk false) orelse break :blk false;
            defer row.deinit(allocator);
            break :blk true;
        };

        if (parent_is_kanban) {
            const first_col_id = blk: {
                var q = db.query(allocator,
                    "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
                    &[_][]const u8{input.item_id}) catch break :blk null;
                defer q.deinit();
                const row = (q.next() catch break :blk null) orelse break :blk null;
                defer row.deinit(allocator);
                break :blk allocator.dupe(u8, row.values[0]) catch break :blk null;
            };
            if (first_col_id) |col_id| {
                defer allocator.free(col_id);
                // Post-Migration-072: the task→column assignment lives in the
                // `kanban` join table.
                db.exec(allocator,
                    "INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, (SELECT COALESCE(MAX(k.kanban_position), -1) + 1 FROM kanban k WHERE k.kanban_column_id = ?))",
                    &[_][]const u8{ task_id, col_id, col_id },
                ) catch |err| {
                    std.log.warn("task_create: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Emit SSE event so other connected clients refresh
                // their kanban view. action="assigned" matches the
                // frontend's KanbanTaskEvent union variant.
                const assigned_pos: i64 = blk: {
                    var q = db.query(allocator,
                        "SELECT COALESCE(k.kanban_position, 0) FROM kanban k WHERE k.workspace_item_task_id = ?",
                        &[_][]const u8{task_id}) catch break :blk 0;
                    defer q.deinit();
                    const row = (q.next() catch break :blk 0) orelse break :blk 0;
                    defer row.deinit(allocator);
                    break :blk std.fmt.parseInt(i64, row.values[0], 10) catch 0;
                };
                on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
                    .action = "assigned",
                    .workspace_id = input.workspace_id,
                    .item_id = input.item_id,
                    .task_id = task_id,
                    .new_column_id = col_id,
                    .new_position = assigned_pos,
                }) catch |err| {
                    std.log.warn("task_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Re-read kanban fields after the INSERT so the
                // response carries the assigned values.
                var q2 = db.query(allocator,
                    "SELECT k.kanban_column_id, COALESCE(k.kanban_position, 0) FROM kanban k WHERE k.workspace_item_task_id = ?",
                    &[_][]const u8{task_id}) catch return .{
                    .task_id = task_id,
                    .name = task.name,
                    .workspace_item_id = task.workspace_item_id,
                    .kanban_column_id = null,
                    .kanban_position = 0,
                    .session_id = input.body.session_id,
                };
                defer q2.deinit();
                blk: {
                    const row_opt = q2.next() catch break :blk {};
                    if (row_opt) |row| {
                        defer row.deinit(allocator);
                        if (row.values[0].len > 0) {
                            kanban_column_id = allocator.dupe(u8, row.values[0]) catch null;
                        }
                        kanban_position = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
                    }
                }
            }
        }
    }

    // Migration 111 — the task row exists now, so the validated edges can be
    // written.
    if (dep_ids.len > 0) {
        kanban_deps.replace(allocator, db, task_id, dep_ids) catch
            return error.StandardTaskCreateFailed;
    }

    // session_id is preserved for backward compatibility with the v1 wire
    // format.

    // Auto-retry-until-stop (Option A of the unattended-mode dialog fix): if
    // the request body carries `is_auto_retry_until_stop`, insert a
    // `sessions` row keyed by the new task.id so the flag has somewhere to
    if (input.body.is_auto_retry_until_stop) |flag| {
        const normalized: []const u8 = if (std.mem.eql(u8, flag, "1")) "1" else "0";
        // INSERT OR IGNORE so a concurrent PUT /api/llm/session/:id that
        // landed first (e.g. the user typed a message in the new task's chat
        // before this row was written) doesn't trip a UNIQUE constraint
        db.exec(
            allocator,
            "INSERT OR IGNORE INTO sessions (id, name, status, is_auto_retry_until_stop, user_id) VALUES (?, ?, 'active', ?, ?)",
            &[_][]const u8{ task.id, task.name, normalized, input.owner },
        ) catch |err| {
            std.log.warn("task_create: session INSERT for unattended flag failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    return .{
        .task_id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .kanban_column_id = kanban_column_id,
        .kanban_position = kanban_position,
        .session_id = input.body.session_id,
        // Migration 067 — kanban task tags. Borrowed from the
        // per-request arena; the arena reaps it on request teardown.
        .tags = validated_tags,
        // Migration 070 — per-task cwd override. Borrowed from the
        // per-request arena (validated above). Mirrors what we just
        // INSERTed into the `cwd` column.
        .cwd = validated_cwd,
        // Media-flags change — media-presence flags derived from the validated
        // payloads. The full TEXT stays server-side for lazy fetch.
        .is_have_image = validated_image_urls.len > 0,
        .is_have_video = validated_video_urls.len > 0,
    };
}

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *pabrikcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
) TaskCreateError!TaskCreateResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;

    const task_id = try generateTaskId(allocator, input.io);
    // NOTE: do NOT `defer allocator.free(task_id)` here. `task_id` is passed
    // to `createMemoryTask` / `createStandardTask`, which return it as
    // `*.task_id` in their `*Result` structs.

    if (std.mem.eql(u8, input.body.task_type, "routine")) {
        // Deleted with the per-task `routines` table (Migration 084).
        // Create a routine workspace item instead (`POST .../items/routine`).
        return error.RoutineTasksRemoved;
    }
    if (std.mem.eql(u8, input.body.task_type, "memory")) {
        const result = try createMemoryTask(allocator, db, input, task_id);
        return .{ .memory = result };
    }
    const result = try createStandardTask(allocator, db, input, task_id);
    return .{ .standard = result };
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine.
    const ws_id = req.params.get("workspace_id") orelse "";

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    // Owner for the `sessions` row this request may create (plan 2026-09-25).
    // Server-derived from the `pabrik_session` cookie only — never a body,
    // query, or header field.
    var owner_buf: [128]u8 = undefined;
    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .io = ctx.io,
        .body = parsed,
        // Owner for the unattended-flag `sessions` row (plan 2026-09-25).
        // Server-derived from the cookie only; empty when auth is off.
        .owner = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "",
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired, error.MissingBody, error.InvalidJson => 400,
            error.RoutineTasksRemoved => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.InvalidVideoUrls => 400,
            error.VideoUrlsTooLarge => 413,
            error.CwdTooLong,
            error.CwdNotAbsolute,
            error.CwdContainsControlChar => 400,
            error.SkillNameTooLong,
            error.SkillNameContainsControlChar,
            error.TooManySkills => 400,
            error.DependencySelfReference,
            error.DependencyNotInItem,
            error.DependencyCycle,
            error.DependencyCountExceeded => 400,
            error.MemoryNameRequired, error.InvalidMemoryName,
            error.MemoryContentRequired => 400,
            error.WorkspaceItemNotFound => 404,
            error.NotAFolderItem, error.NoPathForMemory => 400,
            error.MemoryTaskInsertFailed, error.StandardTaskCreateFailed,
            error.FailedToBuildMemoriesPath, error.FailedToWriteMemoryFile => 500,
            error.OutOfMemory, error.Canceled => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON",
            error.RoutineTasksRemoved => "routine tasks are no longer supported; create a routine workspace item instead",
            error.InvalidTags => "tags must be non-empty, ≤50 chars, and contain only letters, digits, hyphens, and underscores",
            error.InvalidImageUrls => "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs",
            error.ImageUrlsTooLarge => "image_urls payload too large (max 10 MB)",
            error.InvalidVideoUrls => "video_urls must be `||`-delimited data:video/<mime>;base64,... URLs",
            error.VideoUrlsTooLarge => "video payload too large (max 25 MB)",
            error.CwdTooLong => "cwd path too long (max 4 KiB)",
            error.CwdNotAbsolute => "cwd must be an absolute path",
            error.CwdContainsControlChar => "cwd contains a control character",
            error.SkillNameTooLong => "skill name too long",
            error.SkillNameContainsControlChar => "skill name must be a directory-safe token (letters, digits, dot, dash, underscore)",
            error.TooManySkills => "skill_names: at most 20 skills per task",
            error.DependencySelfReference => "depends_on: a task cannot depend on itself",
            error.DependencyNotInItem => "depends_on: every id must be a task of the same kanban item",
            error.DependencyCycle => "depends_on: that would create a dependency cycle",
            error.DependencyCountExceeded => "depends_on: at most 32 dependencies per task",
            error.MemoryNameRequired => "memory_name is required for memory tasks",
            error.InvalidMemoryName => "Invalid memory name (must end in .md, no /, no ..)",
            error.MemoryContentRequired => "memory_content is required for memory tasks",
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.NotAFolderItem => "Memory tasks can only be added to folder-type workspace items",
            error.NoPathForMemory => "Workspace item has no path; the folder must have been created with a real path",
            error.MemoryTaskInsertFailed => "Failed to create task row",
            error.StandardTaskCreateFailed => "Failed to create task",
            error.FailedToBuildMemoriesPath => "Failed to build local memories path",
            error.FailedToWriteMemoryFile => "Failed to write memory file",
            error.OutOfMemory => "Out of memory",
            error.Canceled => "Io operation canceled",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Serialize the response based on the tagged outcome.
    return switch (outcome) {
        .memory => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                MemoryResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                },
                .{},
            ),
        }),
        .standard => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                StandardResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                    .session_id = r.session_id,
                    .kanban_column_id = r.kanban_column_id,
                    .kanban_position = r.kanban_position,
                    // Migration 067 — kanban task tags.
                    .tags = r.tags,
                    // Migration 070 — per-task cwd override.
                    .cwd = r.cwd,
                    // Media-flags change — media-presence flags. The frontend
                    // lazy-fetches via the media endpoint when true.
                    .is_have_image = r.is_have_image,
                    .is_have_video = r.is_have_video,
                },
                .{},
            ),
        }),
    };
}

// ===== Tests merged from task_create_description_test.zig (2026-09-11
// flatten) ===== The description / image_urls / kanban auto-assign /
// 201-response-shape contracts this file used to assert were all source greps

const testing = std.testing;
const workspace_provisioning = @import("workspace_provisioning.zig");

/// One thread's worth of `generateTaskId`. Null on failure so the test can
/// report a short list instead of quietly counting fewer ids.
const TaskIdWorker = struct {
    fn run(allocator: std.mem.Allocator, out: *?[]const u8) void {
        out.* = generateTaskId(allocator, testing.io) catch null;
    }
};

/// Same for the workspace generator, which lives in
/// `workspace_provisioning.zig` (it backs both POST /api/workspaces and
/// the automatic per-user provisioning).
const WorkspaceIdWorker = struct {
    fn run(allocator: std.mem.Allocator, out: *?[]const u8) void {
        out.* = workspace_provisioning.generateWorkspaceId(allocator, testing.io) catch null;
    }
};

/// Every mint must have succeeded, and no two ids may be equal.
fn expectAllIdsDistinct(a: std.mem.Allocator, ids: []const ?[]const u8, count: usize) !void {
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    for (ids[0..count]) |maybe| {
        const id = maybe orelse return error.IdGenerationFailed;
        if (seen.get(id) != null) {
            std.debug.print("\n!! duplicate id minted: {s} !!\n", .{id});
            return error.DuplicateId;
        }
        try seen.put(id, {});
    }
    try testing.expectEqual(count, seen.count());
}

test "task_create: generateTaskId mints distinct ids from 32 concurrent threads" {
    // No platform gate: the id is `<unix-ms>_<atomic counter>` and both
    // halves exist on Windows.
    const a = testing.allocator;
    const n = 32;
    const ids = try a.alloc(?[]const u8, n);
    defer a.free(ids);
    for (ids) |*slot| slot.* = null;
    const threads = try a.alloc(std.Thread, n);
    defer a.free(threads);
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, TaskIdWorker.run, .{ a, &ids[i] });
    for (threads) |t| t.join();
    try expectAllIdsDistinct(a, ids, n);
    for (ids) |maybe| if (maybe) |id| a.free(id);
}

test "workspaces_create: generateWorkspaceId mints distinct ids from 32 concurrent threads" {
    // No platform gate: the id is `<unix-ms>_<atomic counter>` and both
    // halves exist on Windows.
    const a = testing.allocator;
    const n = 32;
    const ids = try a.alloc(?[]const u8, n);
    defer a.free(ids);
    for (ids) |*slot| slot.* = null;
    const threads = try a.alloc(std.Thread, n);
    defer a.free(threads);
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, WorkspaceIdWorker.run, .{ a, &ids[i] });
    for (threads) |t| t.join();
    try expectAllIdsDistinct(a, ids, n);
    for (ids) |maybe| if (maybe) |id| a.free(id);
}

const migration_mod = @import("../migrations/migration.zig");

// The unattended-flag `sessions` row must carry the requesting owner under
// `--auth`.
test "task_create: unattended sessions row carries the requesting owner" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: pabrikcore.sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    var manager = migration_mod.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration_mod.registerAllMigrations(&manager);
    try manager.runMigrations();

    // No parent row on purpose: the kanban auto-assign path treats a
    // missing parent as non-kanban, so this stays on the sessions-INSERT
    // path under test.
    const owned = try useCase(alloc, &db, .{
        .item_id = "item_folder",
        .workspace_id = "ws_1",
        .io = io,
        .body = .{
            .name = "Owned task",
            .is_auto_retry_until_stop = "1",
        },
        .owner = "user_1",
    });
    {
        var q = try db.query(alloc, "SELECT COALESCE(user_id, '') FROM sessions WHERE id = ?", &.{owned.standard.task_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionRowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_1", row.values[0]);
    }

    // Empty owner (auth off) keeps the legacy shared bucket: NULL.
    const shared = try useCase(alloc, &db, .{
        .item_id = "item_folder",
        .workspace_id = "ws_1",
        .io = io,
        .body = .{
            .name = "Shared task",
            .is_auto_retry_until_stop = "1",
        },
    });
    {
        var q = try db.query(alloc, "SELECT user_id IS NULL FROM sessions WHERE id = ?", &.{shared.standard.task_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionRowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}
