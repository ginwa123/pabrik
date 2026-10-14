//! LLM tool: `create_kanban_task` — creates a new `workspace_item_tasks`
//! row under an existing kanban `workspace_item`.
//!
//! Flow (mirrors `task_create.zig::createStandardTask` exactly):
//!   1. Validate `workspace_id`, `item_id`, `name` (non-empty after trim).
//!   2. Verify the parent `workspace_items.id = item_id` has
//!      `item_type = 'kanban'`. Reject otherwise.
//!   3. INSERT into `workspace_item_tasks` via
//!      `pabrikcore.ai_mod.llm_history.createWorkspaceItemTask` with
//!      `task_type = 'standard'` (every kanban task is a standard task
//!      whose PARENT has `item_type='kanban'`; the schema has no
//!      `task_type='kanban'`).
//!   4. Resolve the target column id. When `column_id` is null, pick
//!      the first column by `position ASC`. When supplied, verify the
//!      column belongs to the same `workspace_item_id`.
//!   5. INSERT OR REPLACE INTO the `kanban` join table (post-
//!      Migration 072) with `kanban_column_id` and `kanban_position`
//!      (set to MAX(position)+1 within the target column).
//!   6. ALWAYS INSERT OR IGNORE INTO `sessions` keyed by the new
//!      task's id (`task.id == session.id`, `sessions.name` =
//!      card title) + INSERT the initial user `llm_history` row
//!      (`"{name}\n\n{description}"`) — HTTP `create_session`
//!      parity (plan:
//!      docs/superpowers/plans/2026-09-09-fix-agent-create-kanban-task-session.md).
//!   7. Emit `session_created` + `kanban_task created` SSE events
//!      (fire-and-forget; log + continue on error).
//!   8. Return the success JSON to the LLM.
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md
//! Parallel HTTP handler: `src/http_handlers/task_create.zig`
//!   ::createStandardTask (lines 337-503).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;
const helpers = @import("helpers");
const sanitizeControlChars = helpers.sanitize_control_chars;
const tags_validation = @import("../../../http_handlers/tags_validation.zig");
const image_urls_validation = @import("../../../http_handlers/image_urls_validation.zig");
const model_guard = @import("../../../agentic_loop/llm_history_model_guard.zig");

/// Input structure for `create_kanban_task` tool.
///
/// Required fields: `workspace_id`, `item_id`, `name`, `description`.
/// The agent must pass `workspace_id` and `item_id` from the
/// active chat context (see the "## Workspace Context" section of
/// the system prompt). `name` is the card title. `description` is
/// the card tooltip text (promoted from optional to required on
/// 2026-08-18 so every card has enough context for human triage).
/// There is no `cwd`: the card's working directory is the kanban
/// item's own `path`, read server-side by `lookupItemProjectPath`.
///
/// `column_id` is optional — when omitted, the task is auto-assigned
/// to the first column at `MAX(kanban_position) + 1` (append-to-bottom
/// semantics matching the HTTP handler).
///
/// The four remaining trailing optional fields mirror the user-facing
/// `KanbanTaskDetailDialog` form so the agent can set everything the
/// human user can set when adding a card from the UI:
///   - `tags` (JSON-encoded array string like `"[\"bug\",\"urgent\"]"`)
///   - `image_urls` (`||`-delimited `data:image/...;base64,...` URLs)
///   - `is_auto_retry_until_stop` (`"1"` to enable unattended mode)
///   - `selected_profile_model` (name of the profile to bind on the
///      created sessions row — see Path A in the
///      `2026-08-06-kanban-task-profile-selector` plan)
pub const CreateKanbanTaskInput = struct {
    /// The workspace that owns the kanban item. From chat context.
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. From chat context. Must have
    /// `item_type='kanban'` (validated up front).
    item_id: []const u8 = "",
    /// Card title shown on the kanban board. Required, must be
    /// non-empty after trim of leading/trailing whitespace.
    name: []const u8 = "",
    /// Required card description (tooltip text in the kanban UI).
    /// Must be non-empty after trim of leading/trailing whitespace —
    /// same rule as `name`. Promoted from optional to required on
    /// 2026-08-18 so the agent always records what the task is about
    /// when it creates a card (was previously allowed empty, which
    /// made the kanban card list unhelpful for human triage).
    description: []const u8 = "",
    /// Optional target column id. When omitted, the task is
    /// auto-assigned to the first column by `position ASC` at
    /// `MAX(kanban_position) + 1`. When supplied, the tool verifies
    /// the column belongs to the same kanban item.
    column_id: ?[]const u8 = null,
    /// Optional tags — JSON-encoded array string like
    /// `"[\"bug\",\"urgent\"]"`. Validated + normalized by
    /// `tags_validation.validateAndNormalizeTags` (≤50 chars,
    /// `[a-zA-Z0-9_-]` only, case-insensitive dedupe). Null/empty
    /// = no tags. Matches the wire shape `TaskCreateRequest.tags`.
    tags: ?[]const u8 = null,
    /// Optional image attachments — `||`-delimited
    /// `data:image/<mime>;base64,<payload>` URLs (10 MB cap, enforced
    /// by `image_urls_validation.validateImageUrls`). Null/empty =
    /// no images. Matches the wire shape `TaskCreateRequest.image_urls`.
    image_urls: ?[]const u8 = null,
    /// Optional unattended-mode flag. `"1"` enables the agent to
    /// retry past the 10-error TooManyRetries bail (overnight runs);
    /// any other value normalizes to `"0"`. A `sessions` row is
    /// ALWAYS created keyed by the new task's id (task.id ==
    /// session.id convention); this flag only sets its
    /// `is_auto_retry_until_stop` column. Matches the wire shape
    /// `TaskCreateRequest.is_auto_retry_until_stop`.
    is_auto_retry_until_stop: ?[]const u8 = null,
    /// Optional profile name to bind on the new sessions row. A
    /// `sessions` row is ALWAYS created; this only sets its
    /// `selected_profile_model` column. Null/empty = backend
    /// default (`""` = top-level config). Matches the wire shape
    /// used by `RequestSession.selected_profile_model` (Path A —
    /// the frontend's plain-create path also does not persist this
    /// on the task itself, only on the chat session it spawns
    /// later).
    selected_profile_model: ?[]const u8 = null,
    /// The model id the seeded `llm_history` row records for this
    /// session's chat. NOT part of the LLM tool schema — the caller
    /// (`tools_exec_create_kanban_task.zig`) always overwrites it with
    /// `ToolExecContext.model` before invoking, so a model-supplied value
    /// here is ignored. It exists only because the seed INSERT needs a
    /// real model instead of the `''` literal it used to hardcode (which
    /// wrote a blank `model` into chat history). Empty is safe: the write
    /// site resolves it to the shared sentinel. See
    /// `agentic_loop/llm_history_model_guard.zig`.
    resolved_model: []const u8 = "",
};

/// Top-level tool definition for the LLM.
///
/// The description is the LLM's primary signal for WHEN to use this
/// tool — it tells the LLM:
///   1. The tool creates a NEW card on a kanban board (use this when
///      the user says "add a task to the kanban", "create a card
///      for X", etc.).
///   2. `workspace_id` and `item_id` come from the active chat's
///      "## Workspace Context" section (no hallucinated ids).
///   3. `column_id` is OPTIONAL — omit it to auto-assign to the
///      first column (append-to-bottom). Pass it only when the user
///      explicitly names a column.
pub const create_kanban_task_tool_system_prompt =
    \\## Create Kanban Task Tool — Behavior
    \\Use `create_kanban_task` to create a new kanban card.
    \\- Requires `name` and `description`. Optionally set `column_id`, `tags`, `image_urls`.
    \\- Use when you discover follow-up work that should be tracked on the board.
    \\
;

pub const create_kanban_task_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "create_kanban_task",
        .description =
        \\Create a new task card on a kanban board, for follow-up work that should be tracked.
        \\
        \\- `workspace_id` and `item_id` come from the "## Workspace Context" section of the system prompt. Pass the backtick-quoted id, never the human-readable name — the DB columns are indexed by id, so a name lookup returns zero rows. The kanban item is the one with `item_type='kanban'` marked `*(this task)*`.
        \\
        \\- REQUIRED: `name` (card title) and `description` (card tooltip — enough context for human triage). No `cwd` is passed: the card's working directory is the kanban item's own `path`, which the server reads from `item_id`.
        \\- `column_id` is OPTIONAL: omitted, the card is auto-assigned to the first kanban column at MAX(kanban_position)+1; supplied, the column must belong to the same kanban item. Call kanban_move_task afterwards to set a specific position.
        \\- Workflow: call kanban_list first to discover the kanban item id (and a column id if the user named one), then create the card, then kanban_move_task if it needs to land in a non-default position.
        \\- On error: re-verify `item_id` against the Workspace Context — a parent item that is not a kanban is a structured error, so pick the item marked `*(this task)*`; if `column_id` was rejected, omit it and let auto-assign place the card.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "Workspace owning the kanban item, from chat context. Always starts with `ws_`.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "Kanban workspace item id (NOT the name), from chat context. The item has `item_type='kanban'`. Always starts with `item_`.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Card title, non-empty after trim. Also becomes the chat session's name when the user opens the card.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "Card tooltip text shown in the kanban UI. REQUIRED since 2026-08-18, non-empty after trim (same rule as `name`); one to three sentences on what the task is about.",
                },
                .{
                    .name = "column_id",
                    .type = "string",
                    .description = "Target column id (NOT name). Omitted: auto-assigned to the first column at MAX(kanban_position)+1. Use kanban_list to discover ids; never pass the human-readable name.",
                },
                .{
                    .name = "tags",
                    .type = "string",
                    .description = "JSON-encoded array string, e.g. \"[\"bug\",\"urgent\"]\". Letters/digits/`_`/`-` only, ≤50 chars per tag, case-insensitive dedupe. Null or empty = no tags.",
                },
                .{
                    .name = "image_urls",
                    .type = "string",
                    .description = "`||`-delimited `data:image/<mime>;base64,<payload>` URLs (10 MB cap). Null or empty = no images.",
                },
                .{
                    .name = "is_auto_retry_until_stop",
                    .type = "string",
                    .description = "Unattended-mode flag: `\"1\"` retries past the 10-error TooManyRetries bail (overnight runs), any other value normalizes to `\"0\"`. A sessions row is always created keyed by the new task's id; this flag only sets its column.",
                },
                .{
                    .name = "selected_profile_model",
                    .type = "string",
                    .description = "Profile name from `LlmConfig.profiles` to bind on the new sessions row. Null or empty = backend default (top-level config).",
                },
            },
            // Four required fields (description promoted from optional on
            // 2026-08-18; cwd dropped on 2026-10-14 — the card inherits the
            // kanban item's path). column_id, tags, image_urls,
            // is_auto_retry_until_stop, selected_profile_model remain
            // optional.
            .required = &.{ "workspace_id", "item_id", "name", "description" },
        },
        .system_prompt = create_kanban_task_tool_system_prompt,
    },
};

// =====================================================================
// Implementation (Task 4)
// =====================================================================
//
// Mirrors `task_create.zig::createStandardTask` (HTTP handler) but
// runs directly in the agent tool process — no HTTP round-trip. Reads
// and writes DB directly via the `pabrikcore.ai_mod.*` helpers, the
// same pattern used by `kanban_list` / `kanban_move_task`.

/// Success payload for `create_kanban_task`. Keys mirror the old
/// `<kanban_task>` child tags 1:1.
pub const CreateKanbanTaskSuccess = struct {
    success: bool,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
};

/// Error payload for `create_kanban_task`.
pub const CreateKanbanTaskError = struct {
    success: bool,
    @"error": []const u8,
};

/// Generate an error JSON payload. The error body is wrapped in
/// `{"success":false,"error":...}` so the
/// `tools_exec_create_kanban_task.zig` wrapper can detect it via the
/// `"error"` key and surface the structured error to
/// the LLM as `success=false`. The function DUPs the input so callers
/// don't need to free it (avoids a leak when the input is the
/// result of `std.fmt.allocPrint(...)`).
pub fn errorJSON(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, CreateKanbanTaskError{
        .success = false,
        .@"error" = clean,
    }, .{});
}

/// Same as `errorJSON` but TAKES OWNERSHIP of `error_msg` and frees it
/// on return. Use this when the caller already has a heap-allocated
/// message that they want to free (e.g. via defer). Errors from
/// allocPrint can be passed here without an extra dup.
pub fn errorJSONOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    const clean = try sanitizeControlChars(allocator, error_msg);
    defer allocator.free(clean);
    return std.json.Stringify.valueAlloc(allocator, CreateKanbanTaskError{
        .success = false,
        .@"error" = clean,
    }, .{});
}

/// Generate the success JSON payload.
fn successJSON(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, CreateKanbanTaskSuccess{
        .success = true,
        .task_id = task_id,
        .column_id = column_id,
        .position = position,
    }, .{});
}

/// Parsed shape of `executeCreateKanbanTaskToJSON` output, for tests.
pub const CreateKanbanTaskOutput = struct {
    success: bool,
    task_id: ?[]const u8 = null,
    column_id: ?[]const u8 = null,
    position: ?i64 = null,
    @"error": ?[]const u8 = null,
};

/// The working directory a new card gets: the kanban item's own `path`.
///
/// Read rather than asked for. The tool lost its `cwd` parameter on
/// 2026-10-14 — the card is created on an item whose `path` is the project
/// root by definition, so the model repeating it was one more chance to name
/// the wrong tree. A DB failure falls back to `""` (the same value
/// Migration 070's column defaults to, i.e. "inherit at launch") rather than
/// failing a card creation whose only problem is a missing convenience.
fn lookupItemProjectPath(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) ![]u8 {
    var q = db.query(
        allocator,
        "SELECT COALESCE(path, '') FROM workspace_items WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch {
        std.log.warn("create_kanban_task: could not read the item path for '{s}' — creating the card with no cwd override", .{item_id});
        return allocator.dupe(u8, "");
    };
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return allocator.dupe(u8, row.values[0]);
    }
    return allocator.dupe(u8, "");
}

/// Verify the parent `workspace_items` row exists and has
/// `item_type='kanban'`. Returns null on success, or an error JSON
/// string when the parent isn't a kanban (or doesn't exist).
fn validateItemTypeIsKanban(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) !?[]u8 {
    var q = db.query(
        allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "item_id '{s}' does not exist in workspace_items",
            .{item_id},
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    };
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        defer row.deinit(allocator);
        const item_type = row.values[0];
        if (std.mem.eql(u8, item_type, "kanban")) return null;
        const msg = try std.fmt.allocPrint(
            allocator,
            "item_id '{s}' has item_type='{s}', not 'kanban'. create_kanban_task only works on kanban items — pick the kanban item marked *(this task)* in the Workspace Context.",
            .{ item_id, item_type },
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "item_id '{s}' does not exist in workspace_items",
        .{item_id},
    );
    defer allocator.free(msg);
    return try errorJSON(allocator, msg);
}

/// Validate that a target column exists. Returns null on success, or an
/// XML error message (matches the `validateItemTypeIsKanban` convention)
/// on failure. Caller uses `if (try resolveTargetColumnId(...)) |err| return err;`.
fn resolveTargetColumnId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    input_column_id: ?[]const u8,
) !?[]u8 {
    if (input_column_id) |cid| {
        var q = db.query(
            allocator,
            "SELECT 1 FROM kanban_columns WHERE id = ? AND workspace_item_id = ?",
            &.{ cid, item_id },
        ) catch {
            const msg = try std.fmt.allocPrint(
                allocator,
                "DB query failed while resolving column_id '{s}'",
                .{cid},
            );
            defer allocator.free(msg);
            return try errorJSON(allocator, msg);
        };
        defer q.deinit();

        const row_opt = q.next() catch null;
        if (row_opt) |row| {
            row.deinit(allocator);
            return null;
        }

        const msg = try std.fmt.allocPrint(
            allocator,
            "column_id '{s}' does not exist in this kanban item. Call kanban_list first to discover the column ids, or omit column_id to auto-assign.",
            .{cid},
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    }

    // No explicit column — pick the first by position ASC.
    var q = db.query(
        allocator,
        "SELECT 1 FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
        &[_][]const u8{item_id},
    ) catch {
        const msg = try std.fmt.allocPrint(
            allocator,
            "DB query failed while looking up first column for item '{s}'",
            .{item_id},
        );
        defer allocator.free(msg);
        return try errorJSON(allocator, msg);
    };
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        row.deinit(allocator);
        return null;
    }

    const msg = try std.fmt.allocPrint(
        allocator,
        "kanban item '{s}' has zero columns — cannot auto-assign. The kanban may be in an inconsistent state (create_kanban requires at least one column).",
        .{item_id},
    );
    defer allocator.free(msg);
    return try errorJSON(allocator, msg);
}

/// Fetch the actual column id (assumes `resolveTargetColumnId` returned
/// null). Heap-owned; caller frees via `defer allocator.free`.
fn fetchTargetColumnId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    input_column_id: ?[]const u8,
) ![]u8 {
    if (input_column_id) |cid| {
        return try allocator.dupe(u8, cid);
    }

    var q = try db.query(
        allocator,
        "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
        &[_][]const u8{item_id},
    );
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Compute the next position for a column = `MAX(kanban_position) + 1`.
/// Returns 0 when the column is empty. Falls back to 0 on DB error.
fn computeNextPosition(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    column_id: []const u8,
) i64 {
    var q = db.query(
        allocator,
        "SELECT COALESCE(MAX(k.kanban_position), -1) + 1 FROM kanban k WHERE k.kanban_column_id = ?",
        &[_][]const u8{column_id},
    ) catch return 0;
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

/// Execute the tool. Returns a JSON string for the LLM.
pub fn executeKanbanTaskToJSON(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: CreateKanbanTaskInput,
) ![]u8 {
    // 1. Validate required fields.
    if (input.workspace_id.len == 0) {
        return errorJSON(allocator, "workspace_id is required (pass it from the Workspace Context listing)");
    }
    if (input.item_id.len == 0) {
        return errorJSON(allocator, "item_id is required (pass the kanban item's id from the Workspace Context listing)");
    }
    const trimmed_name = std.mem.trim(u8, input.name, " \t\n\r");
    if (trimmed_name.len == 0) {
        return errorJSON(allocator, "name is required and must be non-empty after trim");
    }
    // description + cwd were promoted from optional to required on
    // 2026-08-18. Both are validated here (right after `name`) so the
    // LLM sees a structured `<error>` mentioning the missing field
    // before any DB work happens. description follows the same
    // "non-empty after trim" rule as name; cwd is checked below in
    // the existing absolute-path block (the empty-string short-
    // circuit there was removed in the same change).
    const trimmed_description = std.mem.trim(u8, input.description, " \t\n\r");
    if (trimmed_description.len == 0) {
        return errorJSON(allocator, "description is required and must be non-empty after trim (one-to-three sentences about what this task is about)");
    }

    // 2. Validate parent item_type='kanban'.
    if (try validateItemTypeIsKanban(allocator, db, input.item_id)) |err_xml| {
        return err_xml;
    }

    // 3. Resolve target column BEFORE inserting — if invalid, we
    //    must not have created the task row yet.
    if (try resolveTargetColumnId(allocator, db, input.item_id, input.column_id)) |err_xml| {
        return err_xml;
    }
    const target_column_id = try fetchTargetColumnId(allocator, db, input.item_id, input.column_id);
    defer allocator.free(target_column_id);

    // 4. Validate tags (Migration 067) — JSON-encoded array string.
    //    The validator returns a heap-allocated, normalized
    //    JSON-encoded array string (or "" for "no tags"). On any
    //    validation failure (non-array, empty tag, illegal chars,
    //    >50 chars, etc.) we surface a structured error to the LLM.
    const validated_tags = tags_validation.validateAndNormalizeTags(
        allocator,
        input.tags,
    ) catch |err| {
        // errorJSONOwned takes ownership of `msg` — do NOT also
        // `defer allocator.free(msg)` (would be a double-free).
        const msg = std.fmt.allocPrint(
            allocator,
            "tags validation failed: {s}. tags must be a JSON-encoded array of strings — letters/digits/`_`/`-` only, ≤50 chars per tag, e.g. \"[\\\"bug\\\",\\\"urgent\\\"]\".",
            .{@errorName(err)},
        ) catch return errorJSON(allocator, "Out of memory while formatting tags validation error");
        return try errorJSONOwned(allocator, msg);
    };
    defer allocator.free(validated_tags);

    // 5. Validate image_urls (Migration 069) — `||`-delimited
    //    data:image/<mime>;base64,... URLs. The validator returns
    //    the input borrowed (no allocation); we just check it.
    const validated_image_urls = image_urls_validation.validateImageUrls(
        input.image_urls orelse "",
    ) catch |err| switch (err) {
        error.ImageUrlsTooLarge => {
            return errorJSON(allocator, "image_urls payload too large (max 10 MB)");
        },
        error.InvalidImageUrl => {
            return errorJSON(allocator, "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs");
        },
    };

    // 6. The card's working directory comes from the KANBAN ITEM, not from an
    //    argument. Dropped `cwd` on 2026-10-14: the card is created on an item
    //    whose `path` already IS the project root, and `workspace_id`/`item_id`
    //    pin the board — so the parameter was a second, weaker way to say
    //    something the server already knows, and the one way to name the wrong
    //    tree. Migration 070's per-task `cwd` column keeps its meaning for the
    //    UI form (`KanbanTaskDetailDialog`), which still sets it by hand.
    const owned_cwd = try lookupItemProjectPath(allocator, db, input.item_id);
    defer allocator.free(owned_cwd);
    const validated_cwd: []const u8 = owned_cwd;

    // 7. Generate task id.
    const timestamp_ns = @import("helpers").unixTimestampNanos();
    const task_id = std.fmt.allocPrint(allocator, "task_{d}", .{timestamp_ns}) catch {
        return errorJSON(allocator, "Out of memory while generating task id");
    };
    defer allocator.free(task_id);

    // 8. INSERT task row.
    const task = pabrikcore.ai_mod.llm_history.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        trimmed_name,
        input.item_id,
        "standard",
        // Pass `trimmed_description` (validated non-empty above) so
        // any leading/trailing whitespace the LLM accidentally added
        // doesn't leak into the stored tooltip text.
        trimmed_description,
        // Migration 067 — tags. Pass `""` (not null) when no tags
        // so the SQL `''` literal is bound (the dynamic-SQL builder
        // at `llm_history.zig:4047-4056` maps null → omitted
        // (DEFAULT ''), "" → SQL '' literal (canonical sentinel),
        // and a non-empty validated JSON array string → bound `?`.
        // Both null and "" produce the same on-disk value (`''`),
        // so passing `""` here is unambiguous.
        if (validated_tags.len == 0) "" else validated_tags,
        // Migration 069 — image_urls. Same pattern: "" sentinel for
        // no images; validated `||`-joined string when supplied.
        if (validated_image_urls.len == 0) "" else validated_image_urls,
        // Migration 070 — per-task cwd override. Borrowed from the
        // validated block above; empty string stays empty.
        validated_cwd,
        // Migration 090 — video_urls. Tool input is image-only;
        // null omits the column (DEFAULT '' applies).
        null,
    ) catch {
        // NOTE: do NOT `defer allocator.free(msg)` here — `errorJSONOwned`
        // takes ownership of `msg` and frees it on success. The previous
        // `defer free` before `errorJSONOwned` was a latent double-free
        // that fired only when the INSERT actually failed; my changes to
        // pass `""` instead of `null` for tags/image_urls/cwd made this
        // path reachable from the happy-path tests (the test schema was
        // missing the new columns). Ownership now lives entirely with
        // `errorJSONOwned`.
        const msg = std.fmt.allocPrint(
            allocator,
            "Failed to INSERT task row into workspace_item_tasks",
            .{},
        ) catch return errorJSON(allocator, "Out of memory");
        return try errorJSONOwned(allocator, msg);
    };
    defer task.deinit(allocator);

    // 9. Compute position + UPDATE kanban fields.
    const position = computeNextPosition(allocator, db, target_column_id);
    const position_str = std.fmt.allocPrint(allocator, "{d}", .{position}) catch "0";
    defer allocator.free(position_str);
    db.exec(
        allocator,
        "INSERT OR REPLACE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
        &[_][]const u8{ task_id, target_column_id, position_str },
    ) catch |err| {
        std.log.warn("create_kanban_task: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 10. Stamp last_human_touched_at (Migration 065) — mirrors
    //     `task_create.zig:467-469`. Fire-and-forget; without it
    //     the new card would show "awaiting review" until the user
    //     manually interacts with it.
    pabrikcore.ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        db,
        task_id,
        null,
    ) catch |err| {
        std.log.warn("create_kanban_task: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 11. INSERT OR IGNORE INTO `sessions` — ALWAYS (HTTP
    //     `create_session` parity, plan:
    //     docs/superpowers/plans/2026-09-09-fix-agent-create-kanban-task-session.md).
    //     Uses the `task.id == session.id` convention so downstream
    //     SELECTs that join `sessions` see a consistent id pair.
    //     Fixed column list mirrors
    //     `kanban_tasks_create.zig:248-249` verbatim:
    //     (id, name, status, cwd, created_at, updated_at,
    //     selected_profile_model, is_auto_retry_until_stop).
    //     INSERT OR IGNORE so a concurrent chat-spawn that landed
    //     first doesn't trip a UNIQUE constraint failure.
    //
    //     `sessions.name` is bound to `trimmed_name` (NOT `task_id`),
    //     so the sidebar / chat header / kanban card all show the
    //     user-facing title (plan:
    //     docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md).
    //     trimmed_name is already non-empty after the step-1
    //     validation, so this is safe.
    //
    //     Pre-fix this block was guarded by
    //     `if (is_auto_retry_until_stop != null or profile set)` —
    //     plain agent-created cards got NO sessions row and opened
    //     as empty chats with the description silently dropped.
    {
        const normalized: []const u8 = blk: {
            if (input.is_auto_retry_until_stop) |flag| {
                if (std.mem.eql(u8, flag, "1")) break :blk "1";
            }
            break :blk "0";
        };
        const profile: []const u8 = input.selected_profile_model orelse "";

        db.exec(
            allocator,
            "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) " ++
                "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)",
            &[_][]const u8{
                task_id,
                trimmed_name,
                validated_cwd,
                profile,
                normalized,
            },
        ) catch |err| {
            std.log.warn("create_kanban_task: session INSERT failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    // 12. Seed the initial user `llm_history` row so the chatview
    //     lands on the user's description instead of the empty
    //     "How can I help you?" state. Mirrors the
    //     `if (is_create_session)` block at
    //     `kanban_tasks_create.zig:300-352` verbatim:
    //     content is `"{name}\n\n{description}"`, `image_urls` wire
    //     value attached, `model` bound from the session's resolved
    //     model (guarded so it can never be empty). Non-fatal on
    //     error — the card + session already exist.
    {
        const initial_message = std.fmt.allocPrint(
            allocator,
            "{s}\n\n{s}",
            .{ trimmed_name, trimmed_description },
        ) catch null;
        if (initial_message) |msg| {
            defer allocator.free(msg);
            const now_ns = @import("helpers").unixTimestampNanos();
            const id_str = std.fmt.allocPrint(allocator, "{d}", .{now_ns}) catch null;
            if (id_str) |ids| {
                defer allocator.free(ids);
                const created_at_str = std.fmt.allocPrint(allocator, "{d}", .{now_ns}) catch null;
                if (created_at_str) |cas| {
                    defer allocator.free(cas);
                    db.exec(
                        allocator,
                        "INSERT INTO llm_history " ++
                            "(id, session_id, model, response_content, finish_reason, role, " ++
                            "agent, parent_id, parent_session_id, is_input, image_url, " ++
                            "is_feed_to_llm, created_at_nano, created_iso) " ++
                            "VALUES (?, ?, ?, ?, 'null', 'user', 'Agent', ?, ?, 1, ?, 1, ?, '')",
                        &[_][]const u8{
                            ids,
                            task_id,
                            // Never empty: an empty bind lands as SQL NULL and
                            // fails `model TEXT NOT NULL`, dropping the seed row.
                            // See agentic_loop/llm_history_model_guard.zig.
                            model_guard.resolve(input.resolved_model),
                            msg,
                            task_id,
                            task_id,
                            validated_image_urls,
                            cas,
                        },
                    ) catch |err| {
                        std.log.warn("create_kanban_task: initial user llm_history insert failed (non-fatal): {s}", .{@errorName(err)});
                    };
                }
            }
        }
    }

    // 13. Emit SSE events: `session_created` so the sidebar's
    //     ChatsList picks up the new session without a manual
    //     refetch (mirrors `kanban_tasks_create.zig:362-376`), then
    //     the existing `kanban_task created` event for kanban
    //     multi-tab sync. Both fire-and-forget.
    //
    //     The session event is gated on the step-11 INSERT having
    //     actually created the row: `INSERT OR IGNORE` no-ops when the
    //     task already has a sessions row, and a `session_created` for
    //     an existing row makes every connected sidebar re-fetch its
    //     whole list for nothing.
    if (db.changes() > 0) {
        const normalized: []const u8 = blk: {
            if (input.is_auto_retry_until_stop) |flag| {
                if (std.mem.eql(u8, flag, "1")) break :blk "1";
            }
            break :blk "0";
        };
        const profile: []const u8 = input.selected_profile_model orelse "";
        pabrikcore.ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "created",
            .id = task_id,
            .name = trimmed_name,
            .status = "active",
            .cwd = validated_cwd,
            .created_at = "",
            .updated_at = "",
            .selected_profile_model = profile,
            .is_auto_retry_until_stop = normalized,
            .last_finish_reason = "",
        }) catch |err| {
            std.log.info("create_kanban_task: session_created SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    }
    pabrikcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "created",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = task_id,
        .new_column_id = target_column_id,
        .new_position = position,
    }) catch |err| {
        std.log.warn("create_kanban_task: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 14. Return success JSON.
    return successJSON(allocator, task_id, target_column_id, position);
}

const testing = std.testing;
const create_kanban_task = @import("create_kanban_task.zig");
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────────
//
// These tests exercise `executeKanbanTaskToJSON` end-to-end:
// they seed a workspace + kanban item + columns + (optionally) tasks,
// call the tool with crafted inputs, and assert on the returned XML
// + the DB state.
//
// Mirrors the pattern from `kanban_move_task_test.zig::setupDb`.
// See plan Task 3.

/// Open a fresh in-memory SQLite DB. Caller owns the returned
/// `db` + `threaded` and must `defer s.threaded.deinit();
/// defer s.db.deinit();`.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  -- The card's working directory now comes from this column (the
        \\  -- tool lost its `cwd` parameter on 2026-10-14).
        \\  path TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  task_type TEXT,
        \\  last_human_touched_at_nano INTEGER,
        \\  -- Migrations 067 / 069 / 071: the agent tool now writes
        \\  -- these columns via the new optional `tags` / `image_urls`
        \\  -- / `cwd` input fields. The schema here mirrors the
        \\  -- post-migration shape so the createWorkspaceItemTask
        \\  -- INSERT path can bind them (the dynamic-SQL builder
        \\  -- at llm_history.zig:4047-4056 emits `''` literals when
        \\  -- the caller passes `""` — which fails fast without
        \\  -- these columns present).
        \\  tags TEXT NOT NULL DEFAULT '',
        \\  image_urls TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    // sessions table — ALWAYS written by the tool (HTTP
    // `create_session` parity). Full production shape for the
    // columns the tool binds: id, name, status, cwd,
    // created_at/updated_at (SQL timestamps), plus the
    // unattended/profile columns.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  status TEXT,
        \\  cwd TEXT NOT NULL DEFAULT '',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  is_auto_retry_until_stop TEXT,
        \\  selected_profile_model TEXT
        \\)
    , &[_][]const u8{});
    // llm_history table — the tool seeds one initial user row per
    // created card (HTTP `create_session` parity). Only the
    // columns the INSERT writes are modeled here.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\  id TEXT PRIMARY KEY,
        \\  session_id TEXT NOT NULL,
        \\  model TEXT NOT NULL,
        \\  response_content TEXT,
        \\  finish_reason TEXT,
        \\  role TEXT,
        \\  agent TEXT DEFAULT 'Agent',
        \\  parent_id TEXT,
        \\  parent_session_id TEXT,
        \\  is_input INTEGER,
        \\  image_url TEXT,
        \\  is_feed_to_llm INTEGER,
        \\  created_at_nano DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  created_iso TEXT
        \\)
    , &[_][]const u8{});
    // Post-Migration-072: task→column mapping lives in `kanban` join table
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &[_][]const u8{});
    // Default seeded item — a kanban named 'Sprint' with 3 columns.
    try db.exec(
        alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path) " ++
            "VALUES ('item_k1', 'ws_1', 'kanban', 'Sprint', '/fixture/proj')",
        &[_][]const u8{},
    );
    try db.exec(
        alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_todo', 'item_k1', 'todo', 0)",
        &[_][]const u8{},
    );
    try db.exec(
        alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_ip', 'item_k1', 'in progress', 1)",
        &[_][]const u8{},
    );
    try db.exec(
        alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_done', 'item_k1', 'done', 2)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `workspace_item_tasks` matching `WHERE id = ?`.
/// Used to assert the tool inserted exactly one row.
fn taskRowExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, task_id: []const u8) !bool {
    var q = try db.query(
        alloc,
        "SELECT 1 FROM workspace_item_tasks WHERE id = ?",
        &.{task_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    defer row.deinit(alloc);
    return true;
}

/// Read the first column of the first row returned by `sql`.
/// Returns a heap-owned slice; caller frees with `alloc.free`.
/// Returns an empty slice when no row matches (NOT an error) so
/// callers can do `readColumn(...) == ""` for "row absent" assertions.
fn readColumn(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    const row = (try q.next()) orelse return try alloc.dupe(u8, "");
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

/// Extract the task_id from the success JSON returned by the tool.
/// Returns an allocator-owned dupe the caller frees.
fn extractTaskId(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(
        CreateKanbanTaskOutput,
        allocator,
        json,
        .{ .allocate = .alloc_always },
    ) catch return error.MissingTaskIdTag;
    defer parsed.deinit();
    const task_id = parsed.value.task_id orelse return error.MissingTaskIdTag;
    return allocator.dupe(u8, task_id);
}

test "executeKanbanTaskToJSON returns success JSON on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "new task",
        .description = "happy path task",
    });
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(create_kanban_task.CreateKanbanTaskOutput, alloc, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.success);
    try std.testing.expect((parsed.value.task_id orelse @as([]const u8, "")).len > 0);
    try std.testing.expectEqualStrings("col_todo", parsed.value.column_id orelse "");
    try std.testing.expectEqual(@as(i64, 0), parsed.value.position orelse -1);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "executeKanbanTaskToJSON inserts a row into workspace_item_tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "insert me",
        .description = "insert me desc",
    });
    defer alloc.free(json);

    // Extract the task_id from the JSON payload.
    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);

    try testing.expect(try taskRowExists(alloc, &s.db, task_id));
}

test "executeKanbanTaskToJSON always inserts sessions row without flag or profile" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "plain card",
        .description = "no flag no profile",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const name = try readColumn(alloc, &s.db, "SELECT name FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(name);
    try testing.expectEqualStrings("plain card", name);
    const status = try readColumn(alloc, &s.db, "SELECT status FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(status);
    try testing.expectEqualStrings("active", status);
    const cwd = try readColumn(alloc, &s.db, "SELECT cwd FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(cwd);
    try testing.expectEqualStrings("/fixture/proj", cwd);
    const flag = try readColumn(alloc, &s.db, "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(flag);
    try testing.expectEqualStrings("0", flag);
}

test "executeKanbanTaskToJSON sessions row honors flag and profile" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "flagged card",
        .description = "with flag and profile",
        .is_auto_retry_until_stop = "1",
        .selected_profile_model = "code",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const flag = try readColumn(alloc, &s.db, "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);
    const profile = try readColumn(alloc, &s.db, "SELECT selected_profile_model FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(profile);
    try testing.expectEqualStrings("code", profile);
}

test "executeKanbanTaskToJSON inserts initial user llm_history row" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "seed me",
        .description = "seed desc here",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const content = try readColumn(alloc, &s.db, "SELECT response_content FROM llm_history WHERE session_id = ?", &.{task_id});
    defer alloc.free(content);
    try testing.expectEqualStrings("seed me\n\nseed desc here", content);
    const role = try readColumn(alloc, &s.db, "SELECT role FROM llm_history WHERE session_id = ?", &.{task_id});
    defer alloc.free(role);
    try testing.expectEqualStrings("user", role);
}

test "executeKanbanTaskToJSON appends at MAX(kanban_position)+1 when column has existing tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Seed 2 existing tasks in the todo column at positions 0 and 1.
    try s.db.exec(
        alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_1', 'item_k1', 'first', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(
        alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_2', 'item_k1', 'second', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(
        alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) " ++
            "VALUES ('t_existing_1', 'col_todo', 0), ('t_existing_2', 'col_todo', 1)",
        &[_][]const u8{},
    );

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "third",
        .description = "third desc",
    });
    defer alloc.free(json);

    // The first column is col_todo — position 2 should be appended.
    try testing.expect(contains(json, "\"column_id\":\"col_todo\""));
    try testing.expect(contains(json, "\"position\":2"));
}

test "executeKanbanTaskToJSON returns error when workspace_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "workspace_id"));
}

test "executeKanbanTaskToJSON returns error when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "",
        .name = "x",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "item_id"));
}

test "executeKanbanTaskToJSON returns error when name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "name"));
}

test "executeKanbanTaskToJSON returns error when name is whitespace-only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "   \t\n  ",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "name"));
}

// ─── description + cwd became required on 2026-08-18 ──────────────────
//
// description: must be non-empty after trim of leading/trailing whitespace.
// cwd: must be non-empty (and an absolute path — see the "rejects relative
//      cwd" test below for the format check).
//
// We add these validation tests right after the matching "name" tests so
// the three required-text-field tests live together. The order matters for
// the test runner's narrative — name first because it has been required
// longest, then description + cwd because they were promoted together.

test "executeKanbanTaskToJSON returns error when description is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "no desc",
        .description = "",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "description"));
}

test "executeKanbanTaskToJSON returns error when description is whitespace-only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "whitespace desc",
        .description = "   \t\n  ",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "description"));
}

test "executeKanbanTaskToJSON returns error when parent item_type is not kanban" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Replace the kanban item with a chat item.
    try s.db.exec(
        alloc,
        "UPDATE workspace_items SET item_type = 'chat' WHERE id = 'item_k1'",
        &[_][]const u8{},
    );

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    // The error must mention the parent type so the LLM can self-correct.
    try testing.expect(contains(json, "kanban") or contains(json, "item_type"));
}

test "executeKanbanTaskToJSON returns error when kanban has zero columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Delete all 3 seeded columns — the kanban is now column-less.
    try s.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'item_k1'", &[_][]const u8{});

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "column") or contains(json, "Column"));
}

test "executeKanbanTaskToJSON honors explicit column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "explicit placement",
        .description = "explicit placement desc",
        .column_id = "col_ip",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":true"));
    try testing.expect(contains(json, "\"column_id\":\"col_ip\""));
    try testing.expect(contains(json, "\"position\":0"));
}

test "executeKanbanTaskToJSON rejects column_id that does not belong to the item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Add a column under a DIFFERENT kanban item.
    try s.db.exec(
        alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES ('item_k2', 'ws_1', 'kanban', 'Other Sprint')",
        &[_][]const u8{},
    );
    try s.db.exec(
        alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_other', 'item_k2', 'todo', 0)",
        &[_][]const u8{},
    );

    // Try to place the new task in 'col_other' while item_id points
    // to 'item_k1'. The tool must reject this — the column does not
    // belong to the item.
    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
        .column_id = "col_other",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "column") or contains(json, "Column"));
}

//
// These tests exercise the 5 new optional input fields that were added
// to mirror the user-facing KanbanTaskDetailDialog form (Migrations
// 067 / 069 / 070-071 + 063 + 040). They follow the same static + DB
// pattern as the existing tests.

// ─── DB behavior tests for new optional fields ──────────────────────────

test "executeKanbanTaskToJSON persists tags when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "tagged",
        .description = "tagged desc",
        .tags = "[\"bug\",\"urgent\"]",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT tags FROM workspace_item_tasks WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", stored);
}

test "executeKanbanTaskToJSON persists image_urls when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with images",
        .description = "with images desc",
        .image_urls = "data:image/png;base64,abc||data:image/jpeg;base64,def",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT image_urls FROM workspace_item_tasks WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("data:image/png;base64,abc||data:image/jpeg;base64,def", stored);
}

test "executeKanbanTaskToJSON takes the card's cwd from the kanban item's path" {
    // The tool has no `cwd` parameter (dropped 2026-10-14): the card is
    // created on an item whose own `path` IS the project root, so the stored
    // value must come from `workspace_items.path` and nowhere else.
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "inherits item path",
        .description = "inherits item path desc",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":true"));
    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT cwd FROM workspace_item_tasks WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("/fixture/proj", stored);
    // The session the tool seeds must agree with the card.
    const session_cwd = try readColumn(alloc, &s.db, "SELECT cwd FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(session_cwd);
    try testing.expectEqualStrings("/fixture/proj", session_cwd);
}

test "executeKanbanTaskToJSON stamps last_human_touched_at on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "stamped",
        .description = "stamped desc",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT COALESCE(last_human_touched_at_nano, '') FROM workspace_item_tasks WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    // The stamp must be non-empty (a unix-ms integer string). The
    // pre-stamp default is NULL → COALESCE returns ''. After the
    // stamp it's a non-empty digit string.
    try testing.expect(stored.len > 0);
    try testing.expect(stored.len > 0 and stored[0] >= '0' and stored[0] <= '9');
}

test "executeKanbanTaskToJSON creates sessions row when is_auto_retry_until_stop=1" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "unattended",
        .description = "unattended desc",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("1", stored);
}

test "executeKanbanTaskToJSON persists selected_profile_model when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with profile",
        .description = "with profile desc",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT selected_profile_model FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("fast-model", stored);
}

test "executeKanbanTaskToJSON writes both unattended and profile in single sessions row" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "combined",
        .description = "combined desc",
        .is_auto_retry_until_stop = "1",
        .selected_profile_model = "my-profile",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const flag = try readColumn(alloc, &s.db, "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);

    const profile = try readColumn(alloc, &s.db, "SELECT selected_profile_model FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(profile);
    try testing.expectEqualStrings("my-profile", profile);
}

// ─── Kanban task name = session name (plan: 2026-08-13-kanban-task-session-name-match.md) ──
//
// Pre-fix, the tool INSERT OR IGNORE INTO sessions keyed by task_id
// bound `name = task_id` (the literal id like "task_1786626864861"),
// while the kanban card showed the user-facing title. The sidebar
// (ChatsList / session_name) and the chat header (ChatView.chatName)
// read sessions.name and therefore displayed a different string than
// the kanban card. Post-fix the bind is `trimmed_name` so all three
// views show the same string the user typed.
//
// Behavioural regression: assert SELECT name FROM sessions WHERE id = task_id
// returns the trimmed user-facing title in both the unattended-only
// and profile-only code paths.

test "executeKanbanTaskToJSON persists sessions.name == trimmed task name (unattended)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "workspace item task nama and session name",
        .description = "sessions.name == trimmed desc",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT name FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    // Pre-fix this returned task_id (the literal task id). Post-fix it
    // must equal the trimmed user-facing title.
    try testing.expectEqualStrings("workspace item task nama and session name", stored);
}

test "executeKanbanTaskToJSON persists sessions.name == trimmed task name (profile)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        // Leading/trailing whitespace; the tool trims before INSERT
        // (see executeKanbanTaskToJSON line 463-466), so the
        // sessions.name must be the trimmed value.
        .name = "   my chatty task   ",
        .description = "sessions.name == trimmed profile desc",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(json);

    const task_id = try extractTaskId(alloc, json);
    defer alloc.free(task_id);
    const stored = try readColumn(alloc, &s.db, "SELECT name FROM sessions WHERE id = ?", &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("my chatty task", stored);
}

test "executeKanbanTaskToJSON rejects malformed tags" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad tags",
        .description = "bad tags desc",
        .tags = "not-a-json-array",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "tags"));
}

test "executeKanbanTaskToJSON rejects invalid image_urls" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const json = try create_kanban_task.executeKanbanTaskToJSON(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad images",
        .description = "bad images desc",
        .image_urls = "not-a-data-url",
    });
    defer alloc.free(json);

    try testing.expect(contains(json, "\"success\":false"));
    try testing.expect(contains(json, "\"error\":"));
    try testing.expect(contains(json, "image_urls"));
}

//
// Pin the registration contract: a future refactor that drops
// `create_kanban_task` from any of the registry / re-export /
// tools_equipped surfaces would silently disable the tool. These
// tests catch that.
