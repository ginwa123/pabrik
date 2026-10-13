//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks`.
//!
//! Body: `{ name, session_id?, task_type? ('standard'|'memory'),
//!         memory_name?, memory_content? }`.
//!
//! Two task types are supported:
//!
//!   - **standard** (default): existing `createWorkspaceItemTask` path;
//!     the migration's `task_type` column default is 'standard'.
//!     If the parent item is a kanban, the new task is auto-assigned
//!     to the first column at MAX(kanban_position) + 1.
//!
//! NOTE: the **routine** task type was deleted with the per-task
//! `routines` table (Migration 084, plan
//! 2026-09-10-workspace-items-routines). Routines are now
//! first-class workspace items (`item_type='routine'`,
//! `workspace_routines` table) — see
//! `workspace_items_create_routine.zig`.
//!
//!   - **memory**: a local memory file scoped to the parent
//!     workspace_item's directory. The .md file is created at
//!     `<workspace_item.path>/.pabrik/memories/<memory_name>` (the
//!     directory is created if missing) so `loadLocalKnowledge` picks
//!     it up on the next chat. The task row has `task_type='memory'`
//!     and no `session_id` — the file is the content. Requires
//!     `memory_name` (must pass `isValidMemoryName`) and `memory_content`
//!     in the body.
//!
//! Layered as `useCase` (validate + generate id + branch by
//! `task_type` + DB/file work + return tagged result with kanban
//! fields) and a thin handler that maps the outcome + errors to
//! status codes / JSON.
//!
//! Plans:
//!   - docs/plans/2026-06-20-add-markdown-memory.md (memory)
//!   - docs/superpowers/plans/2026-09-10-workspace-items-routines.md
//!     (routine task_type deleted; workspace-level replacement)

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

/// Process-local monotonic counter for task_id generation. The ts-
/// only generator (`task_<unix_ms>`) collided when 2+ tasks were
/// created within the same wall-clock millisecond — the 2nd and
/// later hits returned HTTP 500 "Failed to create task" because
/// the SQLite INSERT tripped the PRIMARY KEY constraint. Observed
/// on Mac ARM64 CI run 31863092055's
/// `test_add_twelve_tasks_across_four_columns` (12 tasks created
/// in <2ms collectively). `seq_cst` is overkill (a relaxed fetchAdd
/// is sufficient for uniqueness), but it's two instructions either
/// way on aarch64 and removes the need to argue about ordering.
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
    // 400 / 413 — kanban image_urls validation (Migration 069). Either
    // the joined string exceeds the 10 MB cap (ImageUrlsTooLarge →
    // 413) or a segment fails the `data:image/...;base64,...` prefix
    // check (InvalidImageUrls → 400). See image_urls_validation.zig.
    InvalidImageUrls,
    ImageUrlsTooLarge,
    // 400 / 413 — kanban video_urls validation (Migration 090).
    // Same contract as image_urls with a 25 MB cap.
    InvalidVideoUrls,
    VideoUrlsTooLarge,
    // 400 — per-task cwd validation (Migration 070). Either:
    //   - the path exceeds 4 KiB (CwdTooLong → 400)
    //   - the path is not absolute (CwdNotAbsolute → 400)
    //   - the path contains a control character (CwdContainsControlChar → 400)
    // Existence of the path is NOT validated here — that's an
    // OS-level concern surfaced by the agent's first cwd-using
    // tool call. See session_create.zig's 3-level fallback chain.
    CwdTooLong,
    CwdNotAbsolute,
    CwdContainsControlChar,
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
    /// (unattended-flag INSERT below). Server-derived from the
    /// `pabrik_session` cookie by the handler — never a body field.
    /// Empty means "no identity" (auth off) and the row stays in the
    /// shared bucket, so `session_llm_config.forSession` keeps falling
    /// back to the process-global `config.json` exactly as before.
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
    /// Caller-supplied session_id (if any). When null the JSON response
    /// emits "session_id":null. The standard-task path no longer accepts
    /// a caller-supplied session_id per the task.id == session.id
    /// convention; the field is preserved for backward compatibility.
    session_id: ?[]const u8,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags). Borrowed from the per-request arena; freed by
    /// the arena reaper on request teardown (matches the lifetime
    /// pattern of the other borrowed slices in StandardResult).
    tags: []const u8 = "",
    /// Per-task cwd (Migration 070 — kanban-cwd-session-optional
    /// plan, 2026-08-06). Borrowed from the per-request arena
    /// (validated above). Mirrors what we just INSERTed into the
    /// `cwd` column. Frontend's KanbanView reads this on the
    /// subsequent `getTasks` to populate `task.cwd` for the
    /// session_create 3-level fallback chain (per-task cwd →
    /// kanban path → sandbox). Empty string is the canonical
    /// "no per-task cwd" sentinel.
    cwd: []const u8 = "",
    /// Media-presence flags (media-flags change). Derived from the validated
    /// payload lengths so the create response tells the frontend whether
    /// to lazy-fetch via the media endpoint.
    is_have_image: bool = false,
    is_have_video: bool = false,
};

// Typed response structs. Serialized via std.json.Stringify.valueAlloc
// (NOT hand-rolled JSON via the std.fmt formatting helpers) for two
// reasons:
//
// 1. Aliasing safety: chaining two per-arena fmt.allocPrint calls
//    (one as a format arg of the other) lets Writer.Allocating land
//    the inner result in the same chunk the outer ensureTotalCapacity
//    just reallocated from, and Zig 0.16's @memcpy safety check aborts
//    with "@memcpy arguments alias" (user-reported crash on 2026-07-01).
//
// 2. JSON escaping: hand-rolled JSON via the fmt helpers does NOT
//    escape quotes / backslashes / control chars in user-provided
//    fields like r.name. A task name containing a quote would produce
//    malformed JSON and break the frontend. valueAlloc delegates to
//    std.json.Stringify which handles all escaping per RFC 8259.

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
    /// tags. Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: []const u8 = "",
    /// Per-task cwd override (Migration 070). Empty string means
    /// the task has no per-task cwd (falls back to kanban-level
    /// path + sandbox). Plan: docs/superpowers/plans/2026-08-06-
    /// kanban-cwd-session-optional.md
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

/// Generate a unique `task_<unix_ms>_<intra_ms_counter>` id.
///
/// The millisecond prefix preserves wire-compat with previously-stored
/// rows (`task_<ms>`) and keeps IDs roughly time-sortable. The atomic
/// counter suffix guarantees uniqueness even when 2+ tasks are
/// created in the same millisecond — without it, fast clients (a
/// tight pytest loop on Apple Silicon, a bulk-import script, etc.)
/// collide on the SQLite PRIMARY KEY and the 2nd+ insert returns
/// HTTP 500 "Failed to create task" (CI run 31863092055,
/// Mac ARM64: 3/64 functional tests failed for this reason —
/// `test_add_twelve_tasks_across_four_columns` and friends).
///
/// The counter resets to 0 at process start. A single-process
/// pabrik can never have two threads call this with the same fetch
/// result, so uniqueness is trivial. Restart = pid change, but
/// new IDs start from 0 again which never collides with the
/// previously-emitted ms (a long-lived workspace has many ms prefixes).
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

    // Migration 062: persist description. Same dynamic-SQL builder
        // Migration 062: persist description. Same dynamic-SQL builder
    // pattern as the standard branch below — null → omit column, "" →
    // SQL '' literal (avoids the empty-slice-as-NULL bind footgun),
    // "x…" → bind via `?`. On failure, roll back the .md file we
    // just wrote.
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
    // Validate + normalize the tags payload (Migration 067). The
    // helper returns a heap-allocated JSON-encoded array string
    // (or "" for "no tags") — the right shape for the `tags`
    // column. The slice is borrowed into the returned StandardResult
    // (see comment there) — the per-request arena reaps it on
    // request teardown. No explicit `defer allocator.free` here.
    const validated_tags = tags_validation.validateAndNormalizeTags(
        allocator,
        input.body.tags,
    ) catch return error.InvalidTags;

    // Validate the image_urls payload (Migration 069). The wire
    // format is the already-joined `||`-delimited string from the
    // client; the helper validates each segment's `data:image/
    // ...;base64,...` prefix and the total byte cap. The string is
    // borrowed (per-request arena) and passed through to the
    // model's INSERT.
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

    // Validate the per-task cwd payload (Migration 070). The wire
    // format is an absolute path string from the FilePickerDialog
    // (or empty / null for cwd-less). Validation is intentionally
    // minimal: the OS-level cwd check happens at agent-run time
    // (the session_create sandbox-create path + every tool's spawn
    // call would surface a nonexistent dir as a 500 to the user).
    // Here we just trim + reject control chars + cap at 4 KiB to
    // bound memory + reject relative paths to avoid surprising the
    // user with a "cd to nowhere" first turn.
    const validated_cwd = blk: {
        const raw = input.body.cwd orelse "";
        if (raw.len == 0) break :blk raw;
        if (raw.len > 4096) return error.CwdTooLong;
        // Must be absolute (POSIX '/' or Windows 'C:\', '\\', ...).
        // Frontend's FilePickerDialog only emits absolute paths; this
        // guard protects against a misbehaving API client (curl, etc.).
        // Use std.fs.path.isAbsolute so Windows paths like
        // C:\Users\... are accepted on Windows builds.
        if (!std.fs.path.isAbsolute(raw)) return error.CwdNotAbsolute;
        // Reject any control characters (\x00..\x1f or \x7f). Paths
        // with embedded NULs would crash std.fs.path.join downstream.
        for (raw) |c| {
            if (c < 0x20 or c == 0x7f) return error.CwdContainsControlChar;
        }
        break :blk raw;
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
        // When null the column is omitted from the INSERT and DEFAULT
        // '' applies (cwd-less task). Empty string serializes as the
        // SQL '' literal (canonical "no per-task cwd" sentinel). A
        // non-empty path becomes the cwd for this task's chat
        // sessions, overriding the kanban-level path + sandbox
        // fallback chain in session_create.zig::useCase. Plan:
        // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
        validated_cwd,
        // Migration 090 — video_urls (trailing param). Same contract.
        validated_video_urls,
    ) catch return error.StandardTaskCreateFailed;

    // Chunk 5 of kanban-task-notification-icon: creating a card is
    // a human touch. Stamp last_human_touched_at so the kanban card
    // never shows the orange "awaiting review" dot for a card the
    // user just made (even if the AI subsequently finishes a turn on
    // it — the user's first-interaction is the review). Fire-and-
    // forget: a failed stamp doesn't fail the create.
    ai_mod.llm_history.updateTaskLastHumanTouchedAt(allocator, db, task_id, null) catch |err| {
        std.log.warn("task_create: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
    };
    // NOTE: do NOT `defer task.deinit(allocator)` here. The slices
    // task.id, task.name, task.workspace_item_id, and task.task_type
    // are duped by createWorkspaceItemTask on the per-request arena
    // and then BORROWED into the returned StandardResult below. The
    // handler reads them after this function returns, so freeing
    // here would be a use-after-free (Zig arena free-fill = 0xAA bytes
    // end up as field values). The arena reaps everything when
    // GinwaServer.handle tears down the request arena, so the duped
    // slices need no explicit cleanup.

    // Kanban auto-assign: if the parent is a kanban, append the new
    // task to the bottom of the first column. Errors here are
    // non-fatal — the task row is already created.
    var kanban_column_id: ?[]u8 = null;
    var kanban_position: i64 = 0;
    // NOTE: do NOT `defer allocator.free(kanban_column_id)` here.
    // kanban_column_id (when set) is a dupe on the per-request arena
    // that is BORROWED into the returned StandardResult. Same use-
    // after-free reasoning as above.

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
                // Post-Migration-072: the task→column assignment lives
                // in the `kanban` join table. INSERT OR IGNORE so a
                // re-run on an already-assigned task is a no-op (the
                // SELECT MAX below handles position conflicts).
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

    // session_id is preserved for backward compatibility with the v1
    // wire format. The standard-task path no longer accepts a caller-
    // supplied session_id (the task's own id is the session per the
    // task.id == session.id convention), so input.body.session_id is
    // typically null. Pass it through as-is — valueAlloc handles the
    // optional → "session_id":<id-or-null> serialization.

    // Auto-retry-until-stop (Option A of the unattended-mode dialog
    // fix): if the request body carries `is_auto_retry_until_stop`,
    // insert a `sessions` row keyed by the new task.id so the flag
    // has somewhere to land. The standard-task create path is the
    // primary consumer (frontend's KanbanTaskDetailDialog toggle
    // sends this when the user opts in at create time). Memory tasks
    // handle their own session lifecycle separately and don't take
    // this field.
    //
    // NEW (plan: docs/superpowers/plans/2026-08-13-kanban-task-
    // session-name-match.md): bind sessions.name = task.name (NOT
    // task.id). Pre-fix the bind was task.id, which made the sidebar
    // ChatsList show "task_<timestamp>" while the kanban card showed
    // the user-facing title. Post-fix all three views (sidebar /
    // chat header / kanban card) display the same string at create
    // time. task.id == session.id is still preserved (Migration 052);
    // only the name column changes.
    if (input.body.is_auto_retry_until_stop) |flag| {
        const normalized: []const u8 = if (std.mem.eql(u8, flag, "1")) "1" else "0";
        // INSERT OR IGNORE so a concurrent PUT /api/llm/session/:id
        // that landed first (e.g. the user typed a message in the new
        // task's chat before this row was written) doesn't trip a
        // UNIQUE constraint failure. The `name` column is NOT NULL.
        // `user_id` carries the requesting owner under `--auth` so the
        // workflow's `session_llm_config.forSession` resolves the user's
        // `users.config_json` instead of falling back to `config.json`.
        // Empty binds as NULL (shared bucket) — the auth-off behaviour.
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
    // NOTE: do NOT `defer allocator.free(task_id)` here. `task_id` is
    // passed to `createMemoryTask` /
    // `createStandardTask`, which return it as `*.task_id` in their
    // `*Result` structs. The handler then reads it after this
    // function returns — freeing here is a use-after-free. The
    // per-request arena reaps `task_id` on request teardown, so no
    // explicit cleanup is needed.

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
    // query, or header field. Empty when auth is off, which leaves the row in
    // the shared legacy bucket.
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

    // Serialize the response based on the tagged outcome. Each branch
    // uses a typed struct + std.json.Stringify.valueAlloc (not hand-
    // rolled std.fmt.allocPrint) — see the doc comment above the
    // response struct definitions for the rationale.
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
                    // Migration 067 — kanban task tags. The
                    // `r.tags` slice is borrowed from the per-
                    // request arena (allocated by
                    // validateAndNormalizeTags in createStandardTask,
                    // reaped by the arena on request teardown).
                    // valueAlloc copies it into the response JSON,
                    // so no use-after-free.
                    .tags = r.tags,
                    // Migration 070 — per-task cwd override. Same
                    // borrowed-slice lifetime as `r.tags` (per-
                    // request arena, reaped on request teardown;
                    // valueAlloc copies it into the response JSON,
                    // so no use-after-free).
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

// ===== Tests merged from task_create_description_test.zig (2026-09-11 flatten) =====
//
// The description / image_urls / kanban auto-assign / 201-response-shape
// contracts this file used to assert were all source greps — they read
// `task_create.zig`, `task_delete.zig`, `llm_history.zig` and
// `http_response.zig` off disk and looked for substrings. Those pass on a
// renamed helper and stay green through a dropped UPDATE, so they are gone;
// the behaviours belong to `POST /api/workspaces/:wid/items/:iid/tasks`
// against a real server (`tests/functional/task_*_test.py`).
//
// The id generators are different: uniqueness is the ENTIRE contract, and
// it is reachable from a unit test. Both generators get driven from many
// threads on one process and must return N distinct ids.

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

/// Every mint must have succeeded, and no two ids may be equal. This is the
/// Mac ARM64 CI failure (run 31863092055): a timestamp-only generator
/// collides when 2+ inserts land in the same millisecond, and the second
/// one trips the SQLite PRIMARY KEY and returns HTTP 500.
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
    // No platform gate: the id is `<unix-ms>_<atomic counter>` and
    // both halves exist on Windows. The gate that used to sit here
    // was a leftover from before the counter became atomic, and it
    // cost Windows the only concurrency coverage this generator has.
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
    // No platform gate: the id is `<unix-ms>_<atomic counter>` and
    // both halves exist on Windows. The gate that used to sit here
    // was a leftover from before the counter became atomic, and it
    // cost Windows the only concurrency coverage this generator has.
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
// `--auth`. Without it the row is ownerless, `session_llm_config.forSession`
// cannot resolve the user's `users.config_json`, and the agent run falls
// back to the process-global `config.json` — the reported bug.
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
