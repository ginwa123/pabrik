const std = @import("std");
const llm_history = @import("../agentic_loop/llm_history.zig");

pub const WorkspaceResponse = struct { id: []const u8, name: []const u8, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };

pub const WorkspaceItemResponse = struct { id: []const u8, success: bool = true };

pub const WorkspaceItemFullResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, name: ?[]const u8 = null, path: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null, is_default: i64 = 0 };

// ─── Kanban column types ───────────────────────────────────────────────────
// Wire shape for `GET /api/workspaces/:wsId/items/:itemId/kanban/columns`
// (and the PATCH/POST variants). Mirrors the `KanbanColumn` struct in
// `src/ai_workflow/tui/kanban_model.zig` field-for-field so a future
// contract change is one struct definition to update.
//
// `id` is generated server-side (e.g. `col_<unix_nanoseconds>`).
// `position` is an `i64` because SQLite INTEGER can be 64-bit and the
// kanban model layer stores positions as i64. The frontend reads it as
// a JS number (up to 2^53 is safe; the kanban flow renumbers densely
// so positions never approach that ceiling in practice).
pub const KanbanColumnResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// Free-text description of what the column means. Empty
    /// string when the column has no description set. The frontend
    /// renders "" as the "Add a description..." placeholder.
    description: []const u8,
    position: i64,
    created_at: []const u8,
};

/// Map a `kanban_model.KanbanColumn` (or any struct with the same
/// fields) into a `KanbanColumnResponse`. The `anytype` parameter keeps
/// this helper decoupled from the data-layer struct so the two can
/// evolve independently without touching the response shape.
pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .description = col.description,
        .position = col.position,
        .created_at = col.created_at,
    };
}

/// Build the `{"columns":[...], "count": N}` envelope used by
/// `GET /kanban/columns` (and the success-path of PATCH/DELETE that
/// returns the full updated board). The inner slice is allocated from
/// the per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeKanbanColumnListResponse(allocator: std.mem.Allocator, cols: anytype) ![]u8 {
    const KanbanColumnListResponse = struct {
        columns: []const KanbanColumnResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(KanbanColumnResponse, cols.len);
    defer allocator.free(mapped);
    for (cols, 0..) |c, i| mapped[i] = makeKanbanColumnResponse(c);

    return std.json.Stringify.valueAlloc(
        allocator,
        KanbanColumnListResponse{
            .columns = mapped,
            .count = @intCast(cols.len),
        },
        .{},
    );
}

pub const LlmRunResponse = struct { status: []const u8, session_id: []const u8 };

pub const WorkspaceItemUpdateResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, success: bool = true };

pub const WorkspaceItemGetResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, name: ?[]const u8 = null, path: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null, is_default: i64 = 0 };

pub const SystemFolderErrorResponse = struct { @"error": []const u8, details: ?[]const u8 = null };

pub const SessionCreateResponse = struct { id: []const u8, name: []const u8, status: []const u8 };

pub const SessionUpdateResponse = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
    /// Migration 063 — echo the unattended-mode flag back so the
    /// frontend's reactive Pinia store refreshes from the response.
    is_auto_retry_until_stop: []const u8 = "",
};

pub const WorkerResponse = struct { id: []const u8, status: []const u8 };

pub const HealthResponse = struct { status: []const u8, timestamp: i64 };

pub const TaskDeleteResponse = struct { id: []const u8, success: bool = true };

pub const TaskCreateResponse = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    completed: bool,
    /// Lightweight media-presence flags (media-flags change). Echoed from
    /// the INSERTed row so the optimistic task knows whether to lazy-fetch.
    is_have_image: bool = false,
    is_have_video: bool = false,
};

// Request types
pub const TaskCreateRequest = struct {
    name: []const u8,
    /// Free-form text the frontend attaches to every task (the
    /// `AddTaskDialog` and `AddRoutineDialog` both emit it).
    /// Persisted on the `workspace_item_tasks.description` column
    /// (Migration 062). Optional; the DB default '' is the
    /// "no description" sentinel.
    description: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Task type. Defaults to 'standard' (preserves the existing flow).
    ///   - 'standard': interactive chat task (default; creates a session).
    ///   - 'routine':  DELETED (Migration 084) — rejected with 400
    ///     `RoutineTasksRemoved`. Create a routine workspace item instead.
    ///   - 'memory':   a local memory file scoped to the parent
    ///                 workspace_item's directory. The .md file is
    ///                 created at <workspace_item.path>/.pabrik/memories/
    ///                 so `loadLocalKnowledge` picks it up on the
    ///                 next chat. Requires `memory_name` and
    ///                 `memory_content` in the body.
    task_type: []const u8 = "standard",
    /// Filename for the memory file. Must end in `.md` and contain
    /// no path separators or `..` (validated by `memories.isValidMemoryName`).
    /// Required iff task_type='memory'.
    memory_name: ?[]const u8 = null,
    /// Initial content of the memory file. Required iff task_type='memory'.
    memory_content: ?[]const u8 = null,
    /// Auto-retry-until-stop flag (Migration 063). Mirrors the
    /// `sessions.is_auto_retry_until_stop` column for routine tasks
    /// where task.id == session.id (project convention). When set
    /// during standard-task creation, the handler ALSO inserts a
    /// `sessions` row (task.id becomes session.id) so the flag has
    /// somewhere to land. Accepts `"1"`, `"0"`, or null/absent.
    /// Frontend's KanbanTaskDetailDialog toggle sends this on
    /// create when the user flipped unattended-mode ON.
    is_auto_retry_until_stop: ?[]const u8 = null,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Null/undefined means "no tags supplied",
    /// which is the same as an empty array. The handler validates
    /// the JSON shape, char whitelist, dedupe, and length caps
    /// (see http_handlers/tags_validation.zig). Stored verbatim on
    /// the row's `tags` column. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 069 — kanban
    /// image urls column). Null/undefined means "no images
    /// supplied". The handler joins each URL with `||` before
    /// persisting on the `image_urls` column. The frontend sends
    /// raw base64 data URLs (`data:image/...;base64,...`) in the
    /// same array order they want them rendered. Plan:
    /// docs/superpowers/plans/2026-08-06-kanban-image-urls-
    /// column.md.
    image_urls: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 090 — kanban
    /// video urls column). Null/undefined means "no videos
    /// supplied". Validated via video_urls_validation.zig
    /// (data:video/... prefix + allowlist + 25 MB cap).
    video_urls: ?[]const u8 = null,
    /// Per-task cwd override (Migration 070 — kanban-cwd-session-
    /// optional plan, 2026-08-06). Null/undefined = no cwd
    /// supplied (column omitted from INSERT, DEFAULT '' applies,
    /// row is cwd-less — falls back to the kanban's `path` +
    /// the per-session sandbox). Empty string = explicit "no
    /// per-task cwd" sentinel. Non-empty string = absolute path on
    /// disk that becomes the cwd for this task's chat sessions,
    /// overriding the kanban-level cwd + the per-session sandbox.
    /// Frontend sends the raw string from the FilePickerDialog in
    /// the Add Task dialog; the backend stores it verbatim (no
    /// validation beyond `len == 0` and existence checks happen
    /// at agent-run time via the OS). The 3-level fallback chain
    /// lives in `session_create.zig::useCase`.
    cwd: ?[]const u8 = null,
};

pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Free-form description. Mirrors `TaskCreateRequest.description`.
    /// When present (non-null), overwrites the existing value; the
    /// empty string is the canonical "no description" sentinel and is
    /// stored verbatim. UI uses an "Add a description…" placeholder for
    /// empty values; the DB column has DEFAULT '' so legacy rows
    /// without a description look identical.
    description: ?[]const u8 = null,
    /// JSON-encoded array of tag strings (Migration 067).
    /// Semantics:
    ///   - null/undefined  → don't change existing tags (no-op).
    ///   - `""` (empty string) → clear all tags (sets `tags = ''`).
    ///   - `'["a","b"]'` → replace existing tags with this array
    ///     (after validation + dedupe via tags_validation.zig).
    /// The handler validates the shape, char whitelist, length cap,
    /// and dedupes case-insensitively. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 069 — kanban
    /// image urls column). Semantics mirror tags:
    ///   - null/undefined  → don't change existing images (no-op).
    ///   - `""` (empty string) → clear all images (sets `image_urls = ''`).
    ///   - `'data:image/png;base64,...||data:image/jpeg;base64,...'`
    ///     → replace existing images with this list (after validation
    ///     via image_urls_validation.zig — data URL prefix + 10 MB cap).
    /// Plan: docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
    image_urls: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 090 — kanban
    /// video urls column). Semantics mirror image_urls:
    ///   - null/undefined  → don't change existing videos (no-op).
    ///   - `""` (empty string) → clear all videos (sets `video_urls = ''`).
    ///   - `'data:video/mp4;base64,...||...'` → replace (validated
    ///     via video_urls_validation.zig — prefix + 25 MB cap).
    video_urls: ?[]const u8 = null,
    /// Per-task cwd override (Migration 070 — kanban-cwd-session-
    /// optional plan, 2026-08-06). Semantics:
    ///   - null/undefined  → don't change existing cwd (no-op).
    ///   - `""` (empty string) → clear per-task cwd (sets `cwd = ''`,
    ///     falls back to kanban-level path + sandbox).
    ///   - `"/home/me/repo-A"` → replace per-task cwd with this path
    ///     (validation: must be an absolute path; existence is
    ///     checked at agent-run time via the OS).
    /// Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
    cwd: ?[]const u8 = null,
};

pub const GitStageResponse = struct {
    success: bool,
    message: []const u8,
    staged_files: []const []const u8,
    failed_files: []const []const u8 = &.{},
};

pub const WorkerInfo = struct { id: []const u8, session_id: []const u8, working_directory: ?[]const u8, last_activity: ?[]const u8, last_activity_description: ?[]const u8, created_at: ?[]const u8, status: []const u8, is_running: bool, queue_count: u32 };

pub const WorkerListResponse = struct { workers: []const WorkerInfo, count: u32 };

pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at: []const u8,
    /// Wire-format boolean. Emitted as JSON `true`/`false` by
    /// `std.json.Stringify.valueAlloc` (called from
    /// `makeSessionMessagesResponse`). Matches the SSE
    /// `SseEventLLMHistory.is_input` shape and the TypeScript
    /// `is_input?: boolean` type. The DB column is `INTEGER` (0/1);
    /// the conversion to bool happens in `llm_history.SessionMessage`
    /// via `parseRowBool`. See
    /// docs/plans/2026-07-01-is-input-output-bool-consistency.md.
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: []const u8 = "",
    diffview_after: []const u8 = "",
    image_url: []const u8 = "",
    video_url: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_calls_json: []const u8 = "",
};

pub const SessionMessagesResponse = struct {
    messages: []const SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// Session's bound git worktree path (NULL/empty when no worktree is
    /// bound). Mirrors `sessions.git_worktree_cwd`. Populated by
    /// `sessionMessagesHandler` from `llm_history.SessionMessageResponse`.
    /// See Chunk 1 of the git-worktree-cwd-pr plan.
    git_worktree_cwd: ?[]const u8 = null,
    /// Attached PR URL (NULL/empty when no PR is bound). Mirrors
    /// `sessions.pr_url`. Populated by `sessionMessagesHandler` from
    /// `llm_history.SessionMessageResponse` for the set_pull_request tool.
    pr_url: ?[]const u8 = null,
    /// Effective PR provider. Mirrors `sessions.pr_provider`.
    pr_provider: ?[]const u8 = null,
    /// Session's selected profile name (NULL/empty when no profile is
    /// selected). Mirrors `sessions.selected_profile_model`. Populated by
    /// `sessionMessagesHandler` from `llm_history.SessionMessageResponse`.
    /// Without this field the frontend's profile chip resets to "Default"
    /// on every page refresh because the read endpoint never returned
    /// the value that PUT `/api/llm/session/:id` writes. Bug fix:
    /// 2026-08-07-profile-persist-read.
    selected_profile_model: ?[]const u8 = null,
    /// Migration 091 — resolved sub-agent name for sub-agent sessions.
    sub_agent_name: ?[]const u8 = null,
    /// Migration 091 — parent session id for sub-agent sessions.
    parent_session_id: ?[]const u8 = null,
    max_total_tokens: u32 = 0,
    max_capacity_total_tokens: u32 = 0,
    total: ?u32 = null, // Total count of messages for VirtualScroller
    skills: ?[]const llm_history.SkillInfo = null, // Skills loaded for this session
};

pub fn makeSessionMessagesResponse(allocator: std.mem.Allocator, response: SessionMessagesResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{
        .emit_strings_as_arrays = false,
    });
}

pub fn makeSystemFolderErrorResponse(allocator: std.mem.Allocator, message: []const u8, err: anytype) ![]u8 {
    const response = SystemFolderErrorResponse{
        .@"error" = message,
        .details = @errorName(err),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionCreateResponse(allocator: std.mem.Allocator, response: SessionCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionUpdateResponse(allocator: std.mem.Allocator, response: SessionUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerResponse(allocator: std.mem.Allocator, response: WorkerResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeHealthResponse(allocator: std.mem.Allocator, response: HealthResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskDeleteResponse(allocator: std.mem.Allocator, response: TaskDeleteResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskCreateResponse(allocator: std.mem.Allocator, response: TaskCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerListResponse(allocator: std.mem.Allocator, workers: []const WorkerInfo, count: u32) ![]u8 {
    const response = WorkerListResponse{
        .workers = workers,
        .count = count,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const ErrorResponse = struct { @"error": []const u8 };

pub fn makeErrorResponse(allocator: std.mem.Allocator, response: ErrorResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const PabrikConfigResponse = struct {
    // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
    // defaults (api_endpoint/api_key/model/url_style/temperature/
    // max_tokens/system_prompt) were REMOVED from the wire. The backend
    // derives effective credentials from the active profile at load time;
    // profiles are the only config surface.
    profiles: ?std.json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Map of MCP server name to its raw JSON config (`{"url": "...", "headers": {...}}`).
    /// Sent as-is so the frontend gets full fidelity (header values, etc.).
    mcp_servers: ?std.json.Value = null,
    /// Top-level sub-agents. Each entry carries the full LLM
    /// configuration (model, base_url, thinking, temperature, url_style,
    /// api_key) plus a `system_prompt`. Borrowed slices — the caller
    /// must keep the source alive until the response is serialized.
    sub_agents: ?[]const SubAgentResponse = null,
    /// Opt-in OS notification flag. When true, the backend fires
    /// `notify-send` / osascript / PowerShell when an LLM response
    /// completes with `finish_reason == "stop"`. Consumed by
    /// `workflow.zig:483`.
    notify_on_complete: bool = false,
    /// Opt-in OS notification flag for the error path. When true, the
    /// backend fires a desktop notification when the workflow hits a
    /// transport error, exhausts retries (TooManyRetries), or fails
    /// the outer agentic loop. Default `false` so a brand-new install
    /// is silent on errors. Consumed by `workflow.zig` at the same
    /// sites as `notify_on_complete`.
    notify_on_error: bool = false,
    /// Opt-in web-launch flag. When true, the agent may launch URLs in
    /// the user's web browser. Default `false` so a brand-new install
    /// has web launch off.
    web_launch_enabled: bool = false,
    /// Compaction threshold in KB. Sessions whose DB-stored token
    /// estimate exceeds this value trigger context compaction.
    /// Consumed by `session_compact.zig:57`.
    model_compaction_size_kb: usize = 100,
    /// Optional top-level override for the model's context window (in tokens).
    /// `null` = fall through to per-profile override, then built-in default.
    /// Restored in plan 2026-07-07-compaction-inline so the Defaults tab
    /// can show + edit the top-level compaction defaults.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold as a percentage (0-100).
    /// `null` = fall through to per-profile override, then built-in 80.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before the workflow retries a failed
    /// `callDynamicAgentNew` call. 0 = no delay. Consumed by
    /// `workflow.zig:513` (the `callDynamicAgentNew` retry catch) and
    /// `workflow.zig:595` (the `else` finish_reason branch).
    retry_delay_ms: u32 = 0,
    /// Default tool checklist (Tools tab, plan
    /// 2026-09-22-tools-menu-config-default-tools). Serialized as-is —
    /// `null` when the on-disk key is absent, so the frontend can tell
    /// "legacy defaults" from an explicit `[]` (zero tools). Borrowed
    /// slices — the caller keeps the parsed config alive until the
    /// response is serialized.
    tools: ?[]const []const u8 = null,
    /// Configured web-search providers, keyed by provider name. The
    /// credential in each entry is MASKED on the way out (see
    /// `maskWebSearchProviders`), and `PUT` treats the mask as "unchanged".
    /// Borrowed — the caller keeps the source alive until serialization.
    web_search: ?std.json.Value = null,
    /// Skill Evals switch + knobs, echoed so the Settings toggle can
    /// render the current state. Borrowed slices — the caller must keep
    /// the parsed config alive until the response is serialized.
    skill_evals: SkillEvalsResponse = .{},
};

/// Wire format for a single sub-agent entry. Mirrors
/// `LlmConfig.SubAgentJson` field-for-field; lives here as a separate
/// type so the response boundary doesn't need to import the internal
/// `LlmConfig` module just to serialize a list of sub-agents.
pub const SubAgentResponse = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    url_style: []const u8,
    api_key: []const u8,
    system_prompt: []const u8,
};

/// Wire format for the Skill Evals block. Mirrors
/// `LlmConfig.SkillEvalsJson` field-for-field, for the same reason
/// `SubAgentResponse` lives here — the response boundary serializes
/// without importing the internal config module.
pub const SkillEvalsResponse = struct {
    enabled: bool = false,
    max_skills_per_run: u32 = 8,
    max_evals_per_day: u32 = 10,
    fact_lease_seconds: u32 = 300,
    include_listed_without_loading: bool = true,
    apply_mode: ?[]const u8 = null,
};

pub fn makePabrikConfigResponse(allocator: std.mem.Allocator, response: PabrikConfigResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceResponse(allocator: std.mem.Allocator, response: WorkspaceResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemResponse(allocator: std.mem.Allocator, response: WorkspaceItemResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeLlmRunResponse(allocator: std.mem.Allocator, response: LlmRunResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemUpdateResponse(allocator: std.mem.Allocator, response: WorkspaceItemUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemGetResponse(allocator: std.mem.Allocator, response: WorkspaceItemGetResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemFullResponse(allocator: std.mem.Allocator, response: WorkspaceItemFullResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemListResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (items, 0..) |item, i| {
        if (i > 0) try list.appendSlice(allocator, ",");
        const json_str = try std.json.Stringify.valueAlloc(allocator, WorkspaceItemFullResponse{
            .id = item.id,
            .workspace_id = item.workspace_id,
            .item_type = item.item_type,
            .name = item.name,
            .path = item.path,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
            .is_default = item.is_default,
        }, .{});
        defer allocator.free(json_str);
        try list.appendSlice(allocator, json_str);
    }
    try list.appendSlice(allocator, "]");
    return try list.toOwnedSlice(allocator);
}

/// Object-wrapped variant of `makeWorkspaceItemListResponse`.
/// Returns `{"items":[...],"count":N}` to match the shape the desktop store's
/// `getWorkspacesItems` frontend wrapper expects. Delegates the inner array
/// build to the bare-array helper to avoid duplicating the item-shape logic.
pub fn makeWorkspaceItemListObjectResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    const array_json = try makeWorkspaceItemListResponse(allocator, items);
    defer allocator.free(array_json);

    return std.fmt.allocPrint(allocator, "{{\"items\":{s},\"count\":{d}}}", .{ array_json, items.len });
}

// Workspace Item Task types
// NOTE: RoutineMetaResponse deleted with the per-task `routines`
// table (Migration 084, plan 2026-09-10-workspace-items-routines).
// The `routine` inline field on WorkspaceItemTaskResponse is gone
// with it.

pub const WorkspaceItemTaskResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    /// Free-form description (Migration 062). Empty string is the
    /// canonical "no description" sentinel; the column is NOT NULL
    /// DEFAULT '' so this is never null.
    description: []const u8 = "",
    /// Task type. Always present; 'standard' for legacy rows.
    /// (Legacy per-task cron rows were normalized to 'standard' by
    /// Migration 084 — see the workspace-level replacement.)
    task_type: []const u8 = "standard",
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    /// Pin flag. `true` when the user has pinned this task. Default
    /// `false` so older call sites that don't supply it still compile.
    /// Mirrors `WorkspaceItemTaskInfo.is_pinned` in `llm_history.zig`.
    is_pinned: bool = false,
    /// Position within the pinned subset of a single workspace item.
    /// Only meaningful when `is_pinned == true`. Mirrors
    /// `WorkspaceItemTaskInfo.pinned_position`.
    pinned_position: i64 = 0,
    /// Kanban column this task belongs to (when the parent workspace
    /// item is a kanban). `null` for tasks under non-kanban parents.
    /// Mirrors `WorkspaceItemTaskInfo.kanban_column_id` (Migration 048).
    kanban_column_id: ?[]const u8 = null,
    /// Position within the kanban column. `0` for non-kanban tasks.
    /// Mirrors `WorkspaceItemTaskInfo.kanban_position` (Migration 048).
    kanban_position: i64 = 0,
    /// Unattended-mode flag, joined from `sessions` for tasks
    /// (where `task.id == session.id` per the project
    /// convention). `'0'` for standard tasks that have no
    /// session row, and the literal session value otherwise.
    /// Empty string when the join didn't find a row — the
    /// frontend's KanbanTaskDetailDialog defaults to off in that
    /// case.
    is_auto_retry_until_stop: []const u8 = "",

    /// Last `finish_reason` from the joined `sessions` row (Migration
    /// 065 / kanban notification icon feature). Empty string when
    /// the LEFT JOIN found no session row — the frontend treats this
    /// as "AI never ran on this task". Drives the green checkmark
    /// vs no-icon decision in the kanban card.
    last_finish_reason: []const u8 = "",

    /// Computed boolean for the kanban card "AI finished — awaiting
    /// review" orange dot. SQL CASE produces 1 when the AI has
    /// finished (last_finish_reason='stop') and no human has touched
    /// the task since. The kanban card UI uses this directly:
    ///   - true  → orange pulsing dot
    ///   - false AND last_finish_reason==='stop' → green checkmark
    ///   - false AND last_finish_reason==='' → no icon (never ran)
    needs_human_review: bool = false,

    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Empty string is the canonical "no tags"
    /// sentinel (NOT NULL DEFAULT ''). Frontend decodes via
    /// JSON.parse. Plan:
    /// docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags: []const u8 = "",

    /// Lightweight media-presence flags (media-flags change). List/get
    /// return only these; the full `||`-delimited base64 TEXT columns
    /// stay server-side for the lazy `GET .../tasks/:task_id/media`
    /// endpoint. The frontend fetches media only when the flag is true.
    is_have_image: bool = false,
    is_have_video: bool = false,

    /// Per-task cwd override (Migration 070 — kanban-cwd-session-
    /// optional plan, 2026-08-06). Empty string is the canonical
    /// "no per-task cwd" sentinel (NOT NULL DEFAULT ''). Mirrors
    /// `WorkspaceItemTaskInfo.cwd`. The frontend's
    /// KanbanTaskDetailDialog (edit mode) renders this read-only
    /// strip; KanbanView's `runAgentOnNewTask` flow uses it as the
    /// per-task cwd in the 3-level fallback chain (per-task cwd →
    /// kanban-level path → per-session sandbox).
    cwd: []const u8 = "",

    /// Computed `git rev-parse --abbrev-ref HEAD` output for the
    /// task's cwd (`session.git_worktree_cwd` if bound, otherwise
    /// `workspace_items.path`). Computed on-demand per task by the
    /// handler — no DB column. Null when the cwd is empty, the path
    /// is not a git repo, the HEAD is detached, or the subprocess
    /// fails. Used by the frontend's kanban card to render the
    /// GitHub-style fork/branch badge in the meta row. Plan:
    /// docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md
    git_branch: ?[]const u8 = null,
};

pub const WorkspaceItemTaskListResponse = struct {
    tasks: []const WorkspaceItemTaskResponse,
    count: u32,
    // Pagination fields. `has_more` is true when at least one more page
    // exists after this one; `next_cursor` is the `created_at` of the
    // last task in this page, to be passed back as `?cursor=` for the
    // next page. `next_cursor` is null when there are no more pages.
    // Both default to "end of list" so older call sites that don't
    // supply them still compile.
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
};

// NOTE: RoutinesListEntry / RoutinesListResponse /
// makeRoutinesListResponse deleted with the per-task `routines`
// table + `GET /api/routines` (Migration 084, plan
// 2026-09-10-workspace-items-routines).

/// One entry in the kanban tag suggestions dropdown. Returned by
pub fn makeWorkspaceItemTaskResponse(allocator: std.mem.Allocator, response: WorkspaceItemTaskResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemTaskListResponse(
    allocator: std.mem.Allocator,
    tasks: []const WorkspaceItemTaskResponse,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    const response = WorkspaceItemTaskListResponse{
        .tasks = tasks,
        .count = @intCast(tasks.len),
        .has_more = has_more,
        .next_cursor = next_cursor,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

/// One entry in the kanban tag suggestions dropdown. Returned by
/// `GET /api/workspaces/:ws/items/:item/kanban/tags` ordered by
/// frequency DESC, last_used_at DESC.
/// Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md
pub const KanbanTagSuggestionResponse = struct {
    name: []const u8,
    count: u32,
    last_used_at: ?[]const u8 = null,
};

pub const KanbanTagsListResponse = struct {
    tags: []const KanbanTagSuggestionResponse,
    /// True when more tags exist past this page. The frontend uses
    /// this to decide whether to render the scroll sentinel + load
    /// another page (or stop paginating).
    has_more: bool,
};

pub fn makeKanbanTagsListResponse(
    allocator: std.mem.Allocator,
    suggestions: []const KanbanTagSuggestionResponse,
    has_more: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, KanbanTagsListResponse{
        .tags = suggestions,
        .has_more = has_more,
    }, .{});
}

// Git status types
pub const GitStatusResponse = struct { is_git_repo: bool, branch: ?[]const u8 = null, has_changes: bool = false, is_clean: bool = true, status: ?[]const u8 = null };

pub const GitStatusErrorResponse = struct { @"error": []const u8 };

pub fn makeGitStatusResponse(allocator: std.mem.Allocator, response: GitStatusResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStatusErrorResponse(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const response = GitStatusErrorResponse{
        .@"error" = message,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStageResponse(allocator: std.mem.Allocator, response: GitStageResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git commit-create types ─────────────────────────────────────────────
// Wire shape for `POST /api/git/commit/create?path=<repo>&message=<msg>`.
// Answers the new HEAD SHA so the caller can refresh history without
// another round-trip.
pub const GitCommitCreateResponse = struct {
    success: bool,
    message: []const u8,
    commit_sha: []const u8 = "",
};

pub fn makeGitCommitCreateResponse(allocator: std.mem.Allocator, response: GitCommitCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git worktree info types ───────────────────────────────────────────────
// Wire shape for `GET /api/git/worktree/info?path=<worktree>[&base=<branch>]`
// consumed by the desktop app's CreatePrDialog. Mirrors the response
// struct in `git_worktree_info.zig` so a future contract change is one
// struct definition to update. See Chunk 2 of the
// git-worktree-cwd-pr plan.
pub const GitWorktreeInfoResponse = struct {
    is_git_repo: bool = false,
    branch: []const u8 = "",
    last_commit_sha: []const u8 = "",
    last_commit_msg: []const u8 = "",
    default_base: []const u8 = "",
    commits_ahead: i64 = 0,
    diff_summary: []const u8 = "",
    draft_title: []const u8 = "",
    draft_body: []const u8 = "",
};

pub fn makeGitWorktreeInfoResponse(allocator: std.mem.Allocator, response: GitWorktreeInfoResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR create types ──────────────────────────────────────────────────
// Wire shape for `POST /api/git/pr`. See Chunk 3 of the
// git-worktree-cwd-pr plan.
pub const GitPrCreateResponse = struct {
    success: bool = false,
    pr_url: []const u8 = "",
    /// Which forge the PR/MR was opened on ("github" / "gitlab").
    /// Empty on failure, and on responses from a server predating
    /// GitLab support — clients must treat "" as "unknown, assume
    /// GitHub", not as an error.
    provider: []const u8 = "",
    // Renamed from `error_message` per PR review (line 60 of git_pr_create.zig).
    // `error` is a Zig keyword, so the field is `@"error"` here; it serializes
    // to JSON `"error"` via std.json.Stringify.
    @"error": []const u8 = "",
};

pub fn makeGitPrCreateResponse(allocator: std.mem.Allocator, response: GitPrCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR status types ──────────────────────────────────────────────────
// Wire shape for `GET /api/git/pr/status?path=<repo>[&pr=<n|url>][&provider=]`.
// Wraps `gh pr view --json ...` so the CLI can show open/merged/closed
// without shelling to `gh` itself.
pub const GitPrStatusResponse = struct {
    /// Which forge answered: "github" or "gitlab". The frontend needs
    /// this to label the item correctly (pull request vs merge request)
    /// — without it a GitLab MR is rendered with GitHub's wording and
    /// links to a GitHub-only `/conflicts` route.
    provider: []const u8 = "",
    pr_url: []const u8 = "",
    number: i64 = 0,
    title: []const u8 = "",
    /// Raw forge state (GitHub OPEN/CLOSED/MERGED, GitLab opened/closed/merged).
    state: []const u8 = "",
    /// Normalized lowercase status (open/closed/merged).
    status: []const u8 = "",
    mergeable: []const u8 = "",
    merge_state: []const u8 = "",
    head_ref: []const u8 = "",
    base_ref: []const u8 = "",
    author: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    merged_at: []const u8 = "",
    closed_at: []const u8 = "",
    additions: i64 = 0,
    deletions: i64 = 0,
    changed_files: i64 = 0,
};

pub fn makeGitPrStatusResponse(allocator: std.mem.Allocator, response: GitPrStatusResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR checks types ──────────────────────────────────────────────────
// Wire shape for `GET /api/git/pr/checks?path=<repo>[&pr=<n|url>][&provider=]`.
// One row per CI job, plus the steps inside a failed one — "which job failed"
// is already on the PR page; "which process or task failed" is not.
pub const GitPrCheckStep = struct {
    name: []const u8 = "",
    /// Position in the job's step list. 0 when the CLI omitted it.
    number: u32 = 0,
    /// `success` | `failure` | `cancelled` | `skipped` | `neutral` |
    /// `timed_out`, or "" while the step runs.
    conclusion: []const u8 = "",
    /// `queued` | `in_progress` | `completed`.
    status: []const u8 = "",
    started_at: []const u8 = "",
    completed_at: []const u8 = "",
};

pub const GitPrCheckEntry = struct {
    name: []const u8 = "",
    /// Owning workflow ("ci", "release"). Empty for an app-posted status.
    workflow: []const u8 = "",
    /// gh's rollup of `state`: pass | fail | pending | skipping | cancel. The UI
    /// switches on this; `state` is free-form text.
    bucket: []const u8 = "",
    /// Raw forge state, for display and debugging.
    state: []const u8 = "",
    /// Deep link to the job. Empty when the status has no web UI.
    link: []const u8 = "",
    started_at: []const u8 = "",
    completed_at: []const u8 = "",
    /// Steps, for failed / cancelled jobs only (see the handler). Empty is a
    /// legitimate answer, not a failure.
    steps: []const GitPrCheckStep = &.{},
    /// Why `steps` is empty when we tried and failed. Renders inline so "could
    /// not read the steps" never looks like "there were none".
    steps_error: []const u8 = "",
};

pub const GitPrChecksSummary = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    pending: u32 = 0,
    skipped: u32 = 0,
    cancelled: u32 = 0,
};

pub const GitPrChecksResponse = struct {
    /// Always "github" today — other forges get a 422, not invented rows.
    provider: []const u8 = "",
    /// Echoed back so the panel can label itself when `pr` was a branch name.
    pr_url: []const u8 = "",
    checks: []const GitPrCheckEntry = &.{},
    summary: GitPrChecksSummary = .{},
    /// The run-lookup budget ran out and some failed jobs have no steps. The
    /// panel says so instead of showing a quietly partial list.
    steps_truncated: bool = false,
};

pub fn makeGitPrChecksResponse(allocator: std.mem.Allocator, response: GitPrChecksResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR conflicts types ───────────────────────────────────────────────
// Wire shape for
// `GET /api/git/pr/conflicts?path=<repo>&pr_url=<url>[&provider=][&base=][&head=]`.
// `mergeable: CONFLICTING` says a PR cannot merge but never says *what* blocks
// it — no forge API exposes that — so the backend runs the same three-way
// merge locally (`git merge-tree --write-tree --name-only`) and names the
// files.
pub const GitPrConflictsResponse = struct {
    pr_url: []const u8 = "",
    /// The ref the merge was computed against, e.g. `refs/remotes/origin/main`.
    /// Echoed so an empty list can be read as "clean as of THIS ref" rather
    /// than as "the backend found nothing to look at".
    base_ref: []const u8 = "",
    /// Short commit `base_ref` pointed at. "" when rev-parse failed (cosmetic).
    base_commit: []const u8 = "",
    /// The head the merge was computed against (default "HEAD").
    head: []const u8 = "",
    /// Paths git refused to merge cleanly. Empty is a legitimate answer.
    conflicting_files: []const []const u8 = &.{},
    count: usize = 0,
    /// True when the server capped `conflicting_files` at its MAX_CONFLICT_FILES.
    truncated: bool = false,
};

pub fn makeGitPrConflictsResponse(allocator: std.mem.Allocator, response: GitPrConflictsResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git branches list types ──────────────────────────────────────────────
// Wire shape for `GET /api/git/branches?path=<repo>`. Consumed by the
// kanban "New task" dialog's base-branch picker so the user can choose
// which ref a fresh worktree branches from (e.g. `origin/main`).
pub const GitBranchEntry = struct {
    /// Short ref name, e.g. `origin/main` (remote-tracking) or `main`
    /// (local). This is the exact string the agent passes as the
    /// `set_git_worktree` tool's `base` argument.
    name: []const u8 = "",
    is_remote: bool = false,
    is_current: bool = false,
    is_default: bool = false,
};

pub const GitBranchesResponse = struct {
    is_git_repo: bool = false,
    current_branch: []const u8 = "",
    branches: []const GitBranchEntry = &.{},
};

pub fn makeGitBranchesResponse(allocator: std.mem.Allocator, response: GitBranchesResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git commits list types ───────────────────────────────────────────────
// Wire shape for `GET /api/git/commits?path=<repo>[&limit=100][&skip=0]`.
// Read-only lazygit-style history: short SHA + author + subject per row,
// paged with skip/limit. `total_count` is best-effort (`rev-list --count
// HEAD`, zero when unresolvable).
pub const GitCommitEntry = struct {
    sha: []const u8 = "",
    short_sha: []const u8 = "",
    author: []const u8 = "",
    email: []const u8 = "",
    timestamp: i64 = 0,
    subject: []const u8 = "",
    body: []const u8 = "",
};

pub const GitCommitsResponse = struct {
    is_git_repo: bool = false,
    branch: []const u8 = "",
    total_count: i64 = 0,
    commits: []const GitCommitEntry = &.{},
};

pub fn makeGitCommitsResponse(allocator: std.mem.Allocator, response: GitCommitsResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git commit detail types ──────────────────────────────────────────────
// Wire shape for `GET /api/git/commit?path=<repo>&sha=<sha>`. Full message
// plus the touched-file list (`git diff-tree --name-status`); per-file
// diffs reuse the existing file-diff flow.
pub const GitCommitFileEntry = struct {
    status: []const u8 = "",
    path: []const u8 = "",
};

pub const GitCommitDetailResponse = struct {
    sha: []const u8 = "",
    short_sha: []const u8 = "",
    author: []const u8 = "",
    email: []const u8 = "",
    timestamp: i64 = 0,
    subject: []const u8 = "",
    body: []const u8 = "",
    files: []const GitCommitFileEntry = &.{},
};

pub fn makeGitCommitDetailResponse(allocator: std.mem.Allocator, response: GitCommitDetailResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git commit file-diff types ───────────────────────────────────────────
// Wire shape for `GET /api/git/commit/file?path=<repo>&sha=<sha>&file=<path>`.
// Unified diff of one file at one commit; powers the clickable file rows
// in the commits view.
pub const GitCommitFileDiffResponse = struct {
    sha: []const u8 = "",
    path: []const u8 = "",
    diff_content: []const u8 = "",
};

pub fn makeGitCommitFileDiffResponse(allocator: std.mem.Allocator, response: GitCommitFileDiffResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// Profile types
pub const LlmProfileResponse = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    api_key: []const u8,
    /// Per-profile sub-agents. Borrowed slices from the source profile;
    /// the caller must keep the source alive until the response is
    /// serialized.
    sub_agents: ?[]const SubAgentResponse = null,
};

pub const ProfilesListResponse = struct {
    profiles: []const LlmProfileResponse,
    count: u32,
    active_profile: ?[]const u8 = null,
};

pub fn makeProfilesListResponse(allocator: std.mem.Allocator, profiles: []const LlmProfileResponse, active_profile: ?[]const u8) ![]u8 {
    const response = ProfilesListResponse{
        .profiles = profiles,
        .count = @intCast(profiles.len),
        .active_profile = active_profile,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Workspaces reorder ────────────────────────────────────────────────────
// Typed response for `POST /api/workspaces/reorder`. Uses the same
// `std.json.Stringify.valueAlloc` pattern as every other response
// in this file — never manual `std.fmt.allocPrint` of JSON strings
// (those break on field names with special characters and drift
// away from the struct definition on every refactor).
pub const WorkspacesReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspacesReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspacesReorderResponse{ .count = count }, .{});
}

// Typed response for `POST /api/workspaces/:workspace_id/items/reorder`.
// Mirrors WorkspacesReorderResponse — same shape, same std.json.Stringify
// pattern. The frontend reads `{success, count}` to confirm the reorder
// took effect.
pub const WorkspaceItemReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspaceItemReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{ .count = count }, .{});
}

/// Typed response for `POST /api/.../tasks/:task_id/pin`. Returns the
/// new `pinned_position` so the client can confirm the row landed at
/// the bottom of the pinned region. `is_pinned` echoes the requested
/// state.
pub const TaskPinResponse = struct {
    success: bool = true,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
};

pub fn makeTaskPinResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TaskPinResponse{
            .id = id,
            .is_pinned = is_pinned,
            .pinned_position = pinned_position,
        },
        .{},
    );
}

/// Typed response for `POST /api/.../tasks/reorder_pinned`. Returns
/// the number of rows in the payload (a row that isn't currently
/// pinned is silently skipped by the WHERE clause, but the count
/// still reflects the input list size so the client can verify the
/// request reached the server).
pub const TasksReorderPinnedResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeTasksReorderPinnedResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TasksReorderPinnedResponse{ .count = count },
        .{},
    );
}

/// Typed response for `POST /api/llm/session/:id/pin` (Migration 104).
/// Mirrors `TaskPinResponse` so the frontend reuses the same handling.
pub const SessionPinResponse = struct {
    success: bool = true,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
};

pub fn makeSessionPinResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        SessionPinResponse{
            .id = id,
            .is_pinned = is_pinned,
            .pinned_position = pinned_position,
        },
        .{},
    );
}

// ─── Design-mode response types ────────────────────────────────────────────
// Wire shapes for `GET/POST/PUT/PATCH/DELETE /api/.../design/...`.
// Mirrors the `DesignPage` and `DesignElement` structs in
// `src/agentic_loop/design_model.zig` field-for-field so a future
// contract change is one struct definition to update.
//
// `DesignElementResponse` deliberately omits the `html` body — the
// full HTML is fetched lazily via a separate `GET .../elements/:eid/html`
// endpoint (`DesignElement.loadElementHtml`). This keeps the page+elements
// JSON payload small even for designs with 50+ elements, and lets the
// iframe preview opt in to fetching bodies only when the element is
// selected.
//
// The model's `elem_type` field is renamed to `type` on the wire (the
// SQL column is `type` too — `elem_type` is a Zig-only name because
// `type` is a Zig keyword).
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 3, Task 3.1).
pub const DesignPageResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// 1:1 FK to `workspace_item_tasks.id`. Set atomically by
    /// `design_model.setDesignPage` at create time. The frontend
    /// uses this directly to resolve the page's chat task via
    /// `workspacesStore.setActiveTask(page.workspace_item_task_id)`
    /// — no name matching, no legacy migration.
    workspace_item_task_id: []const u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignPage` (or any struct with the same
/// fields) into a `DesignPageResponse`. The `anytype` parameter keeps
/// this helper decoupled from the data-layer struct so the two can
/// evolve independently without touching the response shape.
pub fn makeDesignPageResponse(page: anytype) DesignPageResponse {
    return .{
        .id = page.id,
        .workspace_item_id = page.workspace_item_id,
        .name = page.name,
        .workspace_item_task_id = page.workspace_item_task_id,
        .width = page.width,
        .height = page.height,
        .position = page.position,
        .created_at = page.created_at,
        .updated_at = page.updated_at,
    };
}

/// Build the `{"pages":[...], "count": N}` envelope used by
/// `GET /design/pages`. The inner slice is allocated from the
/// per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeDesignPageListResponse(allocator: std.mem.Allocator, pages: anytype) ![]u8 {
    const DesignPageListResponse = struct {
        pages: []const DesignPageResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(DesignPageResponse, pages.len);
    defer allocator.free(mapped);
    for (pages, 0..) |p, i| mapped[i] = makeDesignPageResponse(p);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignPageListResponse{
            .pages = mapped,
            .count = @intCast(pages.len),
        },
        .{},
    );
}

pub const DesignElementResponse = struct {
    id: []const u8,
    page_id: []const u8,
    name: []const u8,
    /// Element type — wire string from `ElementType` enum tagName.
    /// One of: "rectangle" | "ellipse" | "text" | "image" | "frame" | "group".
    type: []const u8,
    file_path: []const u8,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    rotation: f64,
    fill: []const u8,
    stroke: []const u8,
    stroke_width: i64,
    corner_radius: i64,
    opacity: f64,
    text_content: []const u8,
    text_style: []const u8,
    image_url: []const u8,
    /// FK to a `group`/`frame` element on the same page (empty string
    /// for top-level elements). Empty-slice convention matches the
    /// data-layer (NULL parent_id round-trips to `""`). See the
    /// 2026-07-28-grouped-layers plan (Chunk 1).
    parent_id: []const u8,
    z_index: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignElement` (or any struct with the same
/// fields) into a `DesignElementResponse`. The model's `elem_type`
/// field (renamed from SQL `type` because `type` is a Zig keyword)
/// is exposed on the wire as `type`.
pub fn makeDesignElementResponse(elem: anytype) DesignElementResponse {
    return .{
        .id = elem.id,
        .page_id = elem.page_id,
        .name = elem.name,
        .type = elem.elem_type,
        .file_path = elem.file_path,
        .x = elem.x,
        .y = elem.y,
        .width = elem.width,
        .height = elem.height,
        .rotation = elem.rotation,
        .fill = elem.fill,
        .stroke = elem.stroke,
        .stroke_width = elem.stroke_width,
        .corner_radius = elem.corner_radius,
        .opacity = elem.opacity,
        .text_content = elem.text_content,
        .text_style = elem.text_style,
        .image_url = elem.image_url,
        .parent_id = elem.parent_id,
        .z_index = elem.z_index,
        .position = elem.position,
        .created_at = elem.created_at,
        .updated_at = elem.updated_at,
    };
}

/// Build the `{"elements":[...], "count": N}` envelope used by
/// callers that want to return a flat element list (currently
/// unused by the 9 HTTP handlers — all of them wrap the elements
/// inside a `DesignPageWithElements` payload — but exported for
/// future endpoints, e.g. a search-by-name route).
pub fn makeDesignElementListResponse(allocator: std.mem.Allocator, elements: anytype) ![]u8 {
    const DesignElementListResponse = struct {
        elements: []const DesignElementResponse,
        count: u32,
    };

    const mapped = try allocator.alloc(DesignElementResponse, elements.len);
    defer allocator.free(mapped);
    for (elements, 0..) |e, i| mapped[i] = makeDesignElementResponse(e);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignElementListResponse{
            .elements = mapped,
            .count = @intCast(elements.len),
        },
        .{},
    );
}

/// Bundle used by `GET /design/pages/:page_id` — returns the page
/// metadata + all elements in one payload (HTML bodies excluded —
/// fetch lazily via `GET .../elements/:eid/html`).
pub const DesignPageWithElementsResponse = struct {
    page: DesignPageResponse,
    elements: []const DesignElementResponse,
};

/// Build the `{"page":..., "elements":[...]}` envelope for
/// `getPageWithElements`. Mirrors the `kanban_model.PageWithElements`
/// pattern: the page is the parent, elements are the children, both
/// in the same JSON object. The inner slices are allocated from the
/// per-request arena and freed before this function returns; the
/// outer envelope JSON is what the caller receives.
pub fn makeDesignPageWithElementsResponse(
    allocator: std.mem.Allocator,
    page: anytype,
    elements: anytype,
) ![]u8 {
    const mapped_elements = try allocator.alloc(DesignElementResponse, elements.len);
    defer allocator.free(mapped_elements);
    for (elements, 0..) |e, i| mapped_elements[i] = makeDesignElementResponse(e);

    return std.json.Stringify.valueAlloc(
        allocator,
        DesignPageWithElementsResponse{
            .page = makeDesignPageResponse(page),
            .elements = mapped_elements,
        },
        .{},
    );
}

// ─── Documents response types ─────────────────────────────────────────────
// Wire shapes for `/api/workspaces/:wsId/documents[/:documentId]`
// (Migration 098). Mirrors `src/agentic_loop/documents_store.DocumentRow`
// field-for-field.
//
// The list envelope is `{documents, count}` rather than a bare array so a
// future paginated variant can add `has_more` / `next_cursor` without a
// breaking shape change — the same reason `DesignPageListResponse` and
// `WorkspaceItemTaskListResponse` are objects.
pub const DocumentResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    /// The markdown body. Always a string — `documents_store` flattens
    /// SQL NULL to "" so the frontend never has to null-check it.
    content: []const u8,
    format: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `documents_store.DocumentRow` (or any struct with the same
/// fields) into the wire shape. The `anytype` parameter keeps this
/// helper decoupled from the data-layer struct so the two can evolve
/// independently without touching the response shape — same pattern as
/// `makeDesignPageResponse`.
pub fn makeDocumentResponse(doc: anytype) DocumentResponse {
    return .{
        .id = doc.id,
        .workspace_id = doc.workspace_id,
        .title = doc.title,
        .content = doc.content,
        .format = doc.format,
        .created_at = doc.created_at,
        .updated_at = doc.updated_at,
    };
}

pub const DocumentListResponse = struct {
    documents: []const DocumentResponse,
    count: u32,
};

/// Build the `{"documents":[...], "count": N}` envelope. The inner
/// slice is allocated from the per-request arena and freed before this
/// function returns; the outer envelope JSON is what the caller
/// receives.
pub fn makeDocumentListResponse(allocator: std.mem.Allocator, documents: anytype) ![]u8 {
    const mapped = try allocator.alloc(DocumentResponse, documents.len);
    defer allocator.free(mapped);
    for (documents, 0..) |d, i| mapped[i] = makeDocumentResponse(d);

    return std.json.Stringify.valueAlloc(
        allocator,
        DocumentListResponse{
            .documents = mapped,
            .count = @intCast(documents.len),
        },
        .{},
    );
}

// ─── Secrets response types ───────────────────────────────────────────────
// Wire shapes for `/api/workspaces/:wsId/secrets[/:secretId]`
// (Migration 103). Mirrors `src/agentic_loop/secrets_store.SecretRow`
// field-for-field, and `SecretRow` has no `value` either — so this type
// cannot carry one either.
//
// THERE IS NO `value` FIELD HERE, AND THAT IS THE DESIGN. A secret's value
// travels in POST/PATCH request bodies and stops there: no read path
// returns it, not masked, not as a `key_hint`, not truncated. A response
// that carried it would put a live credential in the browser, where "we
// chose not to render it" is one XSS away from a leak (Design Decision 9,
// docs/superpowers/plans/2026-10-02-workspace-secrets.md). The cost is
// that rotation cannot be read back — it is confirmed by having saved it.
// DO NOT add a value field here to make some later feature easier.
//
// The list envelope is `{secrets, count}` rather than a bare array for the
// same reason `DocumentListResponse` is an object: a future paginated
// variant can add `has_more` / `next_cursor` without a breaking change.
pub const SecretResponse = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `secrets_store.SecretRow` (or any struct with the same fields)
/// into the wire shape. `anytype` for the same reason as
/// `makeDocumentResponse`: the data layer and the wire shape must be
/// able to move independently.
pub fn makeSecretResponse(secret: anytype) SecretResponse {
    return .{
        .id = secret.id,
        .name = secret.name,
        .created_at = secret.created_at,
        .updated_at = secret.updated_at,
    };
}

pub const SecretListResponse = struct {
    secrets: []const SecretResponse,
    count: u32,
};

/// Build the `{"secrets":[...], "count": N}` envelope. The inner slice is
/// a scratch allocation, freed before this returns; the envelope JSON is
/// what the caller receives.
pub fn makeSecretListResponse(allocator: std.mem.Allocator, secrets: anytype) ![]u8 {
    const mapped = try allocator.alloc(SecretResponse, secrets.len);
    defer allocator.free(mapped);
    for (secrets, 0..) |s, i| mapped[i] = makeSecretResponse(s);

    return std.json.Stringify.valueAlloc(
        allocator,
        SecretListResponse{
            .secrets = mapped,
            .count = @intCast(secrets.len),
        },
        .{},
    );
}

// ─── Frontend error log response types ────────────────────────────────────
// Wire shapes for `POST /api/logs` (no response body, 204 No Content)
// and `GET /api/logs` (returns `{ logs: [...], count: N }`). Mirrors
// the `logs` table column-for-column. `stack`/`source`/`line`/
// `route_path`/`session_id` are nullable per the table schema.
// Plan: docs/plans/2026-07-17-frontend-error-logs-design.md.
pub const FrontendLogRow = struct {
    id: []const u8,
    created_at: i64,
    level: []const u8,
    kind: []const u8,
    message: []const u8,
    stack: ?[]const u8 = null,
    source: ?[]const u8 = null,
    line: ?i64 = null,
    route_path: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    count: i64,
};

pub const FrontendLogListResponse = struct {
    logs: []const FrontendLogRow,
    count: u32,
};

pub fn makeFrontendLogListResponse(allocator: std.mem.Allocator, logs: []const FrontendLogRow) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        FrontendLogListResponse{ .logs = logs, .count = @intCast(logs.len) },
        .{},
    );
}

/// One skill as it goes on the wire: the body plus the companion count.
///
/// `asset_count` rather than the asset list — the detail pane shows
/// "11 companion files", and shipping every companion body to render that
/// number would put the whole bundle in the response payload. Shared by
/// `skill_detail.zig`, `skill_create.zig` and `skill_update.zig` so the
/// three cannot drift into three shapes for the same row.
pub const SkillDetailResponse = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    asset_count: usize,
};

/// Map a `skills_store.SkillRow` (or any struct with the same fields) into
/// the wire shape. `anytype` for the same reason as `makeSecretResponse`:
/// the data layer and the wire shape must be able to move independently.
pub fn makeSkillDetailResponse(skill: anytype) SkillDetailResponse {
    return .{
        .name = skill.name,
        .description = skill.description,
        .content = skill.content,
        .asset_count = skill.asset_count,
    };
}
