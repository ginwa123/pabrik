const std = @import("std");
const llm_history = @import("../agentic_loop/llm_history.zig");

pub const WorkspaceResponse = struct { id: []const u8, name: []const u8, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null };

pub const WorkspaceItemResponse = struct { id: []const u8, success: bool = true };

pub const WorkspaceItemFullResponse = struct { id: []const u8, workspace_id: []const u8, item_type: []const u8, name: ?[]const u8 = null, path: ?[]const u8 = null, created_at: ?[]const u8 = null, updated_at: ?[]const u8 = null, is_default: i64 = 0 };

// ─── Kanban column types ───────────────────────────────────────────────────
// Wire shape for `GET /api/workspaces/:wsId/items/:itemId/kanban/columns`
// (and the PATCH/POST variants).
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
    /// Migration 111 — a card that lands in this column has finished the work
    /// it describes, so it stops blocking the tasks that depend on it.
    is_done: bool = false,
};

/// Map a `kanban_model.KanbanColumn` (or any struct with the same fields)
/// into a `KanbanColumnResponse`.
pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .description = col.description,
        .position = col.position,
        .created_at = col.created_at,
        // `anytype` callers that predate Migration 111 (and the test literals
        // that copy them) have no `is_done`, and a field they cannot carry must
        // not fail to compile.
        .is_done = if (@hasField(@TypeOf(col), "is_done")) col.is_done else false,
    };
}

/// Build the `{"columns":[...], "count": N}` envelope used by `GET
/// /kanban/columns` (and the success-path of PATCH/DELETE that returns the
/// full updated board).
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
    description: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Task type.
    task_type: []const u8 = "standard",
    /// Filename for the memory file. Must end in `.md` and contain
    /// no path separators or `..` (validated by `memories.isValidMemoryName`).
    /// Required iff task_type='memory'.
    memory_name: ?[]const u8 = null,
    /// Initial content of the memory file. Required iff task_type='memory'.
    memory_content: ?[]const u8 = null,
    /// Auto-retry-until-stop flag (Migration 063). Mirrors the
    /// `sessions.is_auto_retry_until_stop` column for routine tasks where
    /// task.id == session.id (project convention).
    is_auto_retry_until_stop: ?[]const u8 = null,
    /// JSON-encoded array of tag strings (Migration 067 — kanban task tags
    /// feature).
    tags: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 069 — kanban image urls
    /// column). Null/undefined means "no images supplied".
    image_urls: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 090 — kanban video urls
    /// column). Null/undefined means "no videos supplied".
    video_urls: ?[]const u8 = null,
    /// Per-task cwd override (Migration 070 — kanban-cwd-session- optional
    /// plan, 2026-08-06).
    cwd: ?[]const u8 = null,
    /// Migration 112 — the skills this task asks its agent to use, a real
    /// JSON array of names (like `depends_on`, unlike `tags`). Absent or
    /// empty means none.
    skill_names: ?[]const []const u8 = null,
    /// Migration 110's single-name field, still accepted so a client that
    /// never learned about the array keeps working. Read only when
    /// `skill_names` is absent.
    skill_name: ?[]const u8 = null,
    /// Migration 111 — the tasks this NEW task waits for. Optional; a real
    /// JSON array of task ids belonging to the same kanban.
    depends_on: ?[]const []const u8 = null,
};

pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    /// Free-form description. Mirrors `TaskCreateRequest.description`.
    description: ?[]const u8 = null,
    /// JSON-encoded array of tag strings (Migration 067).
    tags: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 069 — kanban image urls
    /// column).
    image_urls: ?[]const u8 = null,
    /// `||`-delimited base64 data URLs (Migration 090 — kanban video urls
    /// column).
    video_urls: ?[]const u8 = null,
    /// Per-task cwd override (Migration 070 — kanban-cwd-session- optional
    /// plan, 2026-08-06).
    cwd: ?[]const u8 = null,
    /// Migration 111 — the tasks this task waits for. `null` (field absent)
    /// leaves the existing set untouched; an array (including `[]`) REPLACES
    /// it. A real JSON array of task ids, unlike `tags`.
    depends_on: ?[]const []const u8 = null,
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
    /// `makeSessionMessagesResponse`).
    is_input: bool,
    is_output: bool,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: []const u8 = "",
    diffview_after: []const u8 = "",
    image_url: []const u8 = "",
    video_url: []const u8 = "",
    /// The attached files as a JSON array of `{name, mime, bytes}` — the
    /// bytes never cross the read path.
    file_attachments: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_calls_json: []const u8 = "",
};

pub const SessionMessagesResponse = struct {
    messages: []const SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    /// Session's bound git worktree path (NULL/empty when no worktree is
    /// bound). Mirrors `sessions.git_worktree_cwd`.
    git_worktree_cwd: ?[]const u8 = null,
    /// Attached PR URL (NULL/empty when no PR is bound). Mirrors
    /// `sessions.pr_url`. Populated by `sessionMessagesHandler` from
    /// `llm_history.SessionMessageResponse` for the set_pull_request tool.
    pr_url: ?[]const u8 = null,
    /// Effective PR provider. Mirrors `sessions.pr_provider`.
    pr_provider: ?[]const u8 = null,
    /// Session's selected profile name (NULL/empty when no profile is
    /// selected). Mirrors `sessions.selected_profile_model`.
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
    // max_tokens/system_prompt) were REMOVED from the wire.
    profiles: ?std.json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Map of MCP server name to its raw JSON config (`{"url": "...", "headers": {...}}`).
    /// Sent as-is so the frontend gets full fidelity (header values, etc.).
    mcp_servers: ?std.json.Value = null,
    /// Top-level sub-agents. Each entry carries the full LLM configuration
    /// (model, base_url, thinking, temperature, url_style, api_key) plus a
    /// `system_prompt`.
    sub_agents: ?[]const SubAgentResponse = null,
    /// Opt-in OS notification flag. When true, the backend fires
    /// `notify-send` / osascript / PowerShell when an LLM response completes
    /// with `finish_reason == "stop"`. Consumed by `workflow.zig:483`.
    notify_on_complete: bool = false,
    /// Opt-in OS notification flag for the error path.
    notify_on_error: bool = false,
    /// Opt-in web-launch flag. When true, the agent may launch URLs in
    /// the user's web browser. Default `false` so a brand-new install
    /// has web launch off.
    web_launch_enabled: bool = false,
    /// How the chat draws tool calls: "dev" or "compact".
    chat_view: []const u8 = "dev",
    /// Compaction threshold in KB. Sessions whose DB-stored token
    /// estimate exceeds this value trigger context compaction.
    /// Consumed by `session_compact.zig:57`.
    model_compaction_size_kb: usize = 100,
    /// Optional top-level override for the model's context window (in
    /// tokens). `null` = fall through to per-profile override, then built-in
    /// default.
    max_capacity_token_model: ?u32 = null,
    /// Optional top-level compaction threshold as a percentage (0-100).
    /// `null` = fall through to per-profile override, then built-in 80.
    compaction_threshold_percent: ?u8 = null,
    /// Delay in milliseconds before the workflow retries a failed
    /// `callDynamicAgentNew` call. 0 = no delay.
    retry_delay_ms: u32 = 0,
    /// Default tool checklist (Tools tab, plan
    /// 2026-09-22-tools-menu-config-default-tools).
    tools: ?[]const []const u8 = null,
    /// Configured web-search providers, keyed by provider name. The
    /// credential in each entry is MASKED on the way out (see
    /// `maskWebSearchProviders`), and `PUT` treats the mask as "unchanged".
    web_search: ?std.json.Value = null,
    /// Skill Evals switch + knobs, echoed so the Settings toggle can
    /// render the current state. Borrowed slices — the caller must keep
    /// the parsed config alive until the response is serialized.
    skill_evals: SkillEvalsResponse = .{},
};

/// Wire format for a single sub-agent entry.
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

/// Wire format for the Skill Evals block. Mirrors `LlmConfig.SkillEvalsJson`
/// field-for-field, for the same reason `SubAgentResponse` lives here — the
/// response boundary serializes without importing the internal config module.
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

/// Object-wrapped variant of `makeWorkspaceItemListResponse`. Returns
/// `{"items":[...],"count":N}` to match the shape the desktop store's
/// `getWorkspacesItems` frontend wrapper expects.
pub fn makeWorkspaceItemListObjectResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    const array_json = try makeWorkspaceItemListResponse(allocator, items);
    defer allocator.free(array_json);

    return std.fmt.allocPrint(allocator, "{{\"items\":{s},\"count\":{d}}}", .{ array_json, items.len });
}

// Workspace Item Task types NOTE: RoutineMetaResponse deleted with the
// per-task `routines` table (Migration 084, plan
// 2026-09-10-workspace-items-routines).

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
    /// Unattended-mode flag, joined from `sessions` for tasks (where `task.id
    /// == session.id` per the project convention).
    is_auto_retry_until_stop: []const u8 = "",

    /// Last `finish_reason` from the joined `sessions` row (Migration 065 /
    /// kanban notification icon feature).
    last_finish_reason: []const u8 = "",

    /// Computed boolean for the kanban card "AI finished — awaiting review"
    /// orange dot.
    needs_human_review: bool = false,

    /// JSON-encoded array of tag strings (Migration 067 — kanban task tags
    /// feature).
    tags: []const u8 = "",

    /// Lightweight media-presence flags (media-flags change).
    is_have_image: bool = false,
    is_have_video: bool = false,

    /// Per-task cwd override (Migration 070 — kanban-cwd-session- optional
    /// plan, 2026-08-06).
    cwd: []const u8 = "",

    /// The branch the task's cwd has checked out, read from its `.git/HEAD`
    /// (`session.git_worktree_cwd` if bound, otherwise
    /// `workspace_items.path`).
    git_branch: ?[]const u8 = null,

    /// Migration 111 — ids of the tasks this task waits for. Always present
    /// (an empty array means "no dependencies").
    depends_on: []const []const u8 = &.{},

    /// The SUBSET of `depends_on` that has NOT completed, with enough context
    /// for the UI to say which card is in the way. A dependency whose column
    /// was deleted counts as incomplete.
    blocked_by: []const TaskDependencyBlocker = &.{},

    /// `blocked_by.len > 0`, mirrored so the client does not have to walk the
    /// array to decide whether to render the badge.
    is_blocked: bool = false,
};

/// One blocking dependency in a task payload (Migration 111).
pub const TaskDependencyBlocker = struct {
    task_id: []const u8,
    name: []const u8,
    /// `null` when the dependency is unassigned (its column was deleted).
    column_id: ?[]const u8 = null,
    column_name: ?[]const u8 = null,
};

/// The three dependency fields of a task payload.
pub const TaskDependencyFields = struct {
    depends_on: []const []const u8,
    blocked_by: []const TaskDependencyBlocker,
    is_blocked: bool,
};

/// Build the dependency fields for ONE task out of its board's flat edge list —
/// one `listEdgesForItem` call serves a whole page. `edges` is `anytype` (any
/// slice of structs with the same fields) so this module never names the type.
pub fn makeTaskDependencyFields(
    allocator: std.mem.Allocator,
    edges: anytype,
    task_id: []const u8,
) !TaskDependencyFields {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    var blockers: std.ArrayList(TaskDependencyBlocker) = .empty;
    errdefer blockers.deinit(allocator);

    for (edges) |e| {
        if (!std.mem.eql(u8, e.task_id, task_id)) continue;
        try ids.append(allocator, e.depends_on_task_id);
        if (e.is_done) continue;
        try blockers.append(allocator, .{
            .task_id = e.depends_on_task_id,
            .name = e.name,
            // "" from the JOIN means "unassigned" — report it as null so the
            // client can tell "no column" from "a column with no name".
            .column_id = if (e.column_id.len == 0) null else e.column_id,
            .column_name = if (e.column_name.len == 0) null else e.column_name,
        });
    }

    // `toOwnedSlice` resets the list, so read the count first.
    const is_blocked = blockers.items.len > 0;
    return .{
        .depends_on = try ids.toOwnedSlice(allocator),
        .blocked_by = try blockers.toOwnedSlice(allocator),
        .is_blocked = is_blocked,
    };
}

pub const WorkspaceItemTaskListResponse = struct {
    tasks: []const WorkspaceItemTaskResponse,
    count: u32,
    // Pagination fields.
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
};

// NOTE: RoutinesListEntry / RoutinesListResponse / makeRoutinesListResponse
// deleted with the per-task `routines` table + `GET /api/routines` (Migration
// 084, plan 2026-09-10-workspace-items-routines).

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

/// One entry in the kanban tag suggestions dropdown. Returned by `GET
/// /api/workspaces/:ws/items/:item/kanban/tags` ordered by frequency DESC,
/// last_used_at DESC.
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
// consumed by the desktop app's CreatePrDialog.
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
    /// Which forge the PR/MR was opened on ("github" / "gitlab"). Empty on
    /// failure, and on responses from a server predating GitLab support —
    /// clients must treat "" as "unknown, assume GitHub", not as an error.
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
// Wire shape for `GET
// /api/git/pr/status?path=<repo>[&pr=<n|url>][&provider=]`.
pub const GitPrStatusResponse = struct {
    /// Which forge answered: "github" or "gitlab".
    provider: []const u8 = "",
    has_pr: bool = true,
    reason: []const u8 = "",
    pr_url: []const u8 = "",
    number: i64 = 0,
    title: []const u8 = "",
    /// Raw forge state (GitHub OPEN/CLOSED/MERGED, GitLab opened/closed/merged).
    state: []const u8 = "",
    /// Normalized lowercase status (open/closed/merged).
    status: []const u8 = "",
    mergeable: []const u8 = "",
    merge_state: []const u8 = "",
    /// The commit the head branch pointed at when the forge answered. GitHub:
    /// `headRefOid`. GitLab: `sha`.
    head_sha: []const u8 = "",
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
    /// APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED, or "" when the forge
    /// has no verdict to give. The sentence behind "Merging is blocked".
    review_decision: []const u8 = "",
    /// The CI rollup, counted. The merge box and the header chips read it.
    checks: GitPrChecksSummary = .{},
};

pub fn makeGitPrStatusResponse(allocator: std.mem.Allocator, response: GitPrStatusResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR conversation types ─────────────────────────────────────────────
// Wire shape for `GET
// /api/git/pr/conversation?path=<repo>[&pr=<n|url>][&provider=]`.
pub const GitPrConversationComment = struct {
    author: []const u8 = "",
    body: []const u8 = "",
    created_at: []const u8 = "",
    url: []const u8 = "",
};

pub const GitPrConversationReview = struct {
    author: []const u8 = "",
    /// APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED.
    state: []const u8 = "",
    body: []const u8 = "",
    created_at: []const u8 = "",
    url: []const u8 = "",
};

pub const GitPrConversationResponse = struct {
    provider: []const u8 = "",
    number: i64 = 0,
    title: []const u8 = "",
    /// The request's own description, in markdown.
    body: []const u8 = "",
    author: []const u8 = "",
    created_at: []const u8 = "",
    review_decision: []const u8 = "",
    comments: []GitPrConversationComment = &.{},
    reviews: []GitPrConversationReview = &.{},
    /// Comments plus reviews: how many entries the thread holds.
    comment_count: i64 = 0,
    /// A non-fatal note about the answer, rendered inline.
    detail: []const u8 = "",
};

pub fn makeGitPrConversationResponse(allocator: std.mem.Allocator, response: GitPrConversationResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR merge types ───────────────────────────────────────────────────
// Wire shape for `POST /api/git/pr/merge`.
pub const GitPrMergeResponse = struct {
    /// True only when the forge reports the change request as merged NOW.
    /// False with `pending` true is the honest "accepted, not merged yet".
    success: bool = false,
    /// "merge" | "squash" | "rebase" — echoed so the UI can say what it did.
    method: []const u8 = "",
    /// The command was accepted but the forge has not merged: a merge queue,
    /// or an armed auto-merge. The UI must say so rather than render
    /// "Merged".
    pending: bool = false,
    /// The forge's answer, re-read.
    status: GitPrStatusResponse = .{},
};

pub fn makeGitPrMergeResponse(allocator: std.mem.Allocator, response: GitPrMergeResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR list types ────────────────────────────────────────────────────
// Wire shape for `GET
// /api/git/pr/list?path=<repo>[&state=open|closed|merged|all][&limit=30][&provider=]`.
pub const GitPrListItem = struct {
    number: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    /// Normalized: `open` | `closed` | `merged` (anything else passes
    /// through lowercased). GitHub says OPEN/CLOSED/MERGED, GitLab says
    /// opened/closed/merged, and the UI must not have to know both.
    state: []const u8 = "",
    is_draft: bool = false,
    head_ref: []const u8 = "",
    base_ref: []const u8 = "",
    author: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const GitPrListResponse = struct {
    /// Which forge answered ("github" | "gitlab") — the frontend labels the
    /// whole surface from this (pull requests vs merge requests).
    provider: []const u8 = "",
    /// The CLI that produced the rows (`gh` | `glab`), named in error text
    /// and in the "via gh" line so a failure tells the user which program to
    /// look at.
    program: []const u8 = "",
    /// Echoed back: which filter actually produced this page.
    state: []const u8 = "",
    changes: []const GitPrListItem = &.{},
    /// Exactly `limit` rows came back, so there may be more. The UI says so
    /// rather than presenting one page as the whole truth.
    truncated: bool = false,
    /// A non-fatal note about the answer — empty unless there is something
    /// worth saying (e.g. the CLI printed nothing at all). Errors are status
    /// codes, never this field.
    detail: []const u8 = "",
};

pub fn makeGitPrListResponse(allocator: std.mem.Allocator, response: GitPrListResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR close types ───────────────────────────────────────────────────
// Wire shape for `POST /api/git/pr/close`.
pub const GitPrCloseResponse = struct {
    /// True only when the forge now reports the change request as closed.
    closed: bool = false,
    /// The forge's own sentence when `closed` is false: the re-read still
    /// shows it open, or the close command itself failed (which is a 502
    /// instead — this field is for the honest in-between).
    detail: []const u8 = "",
    provider: []const u8 = "",
    /// The post-close status, so the row can render the same shape the PR
    /// tab's badge uses.
    status: GitPrStatusResponse = .{},
};

pub fn makeGitPrCloseResponse(allocator: std.mem.Allocator, response: GitPrCloseResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// ─── Git PR checks types ──────────────────────────────────────────────────
// Wire shape for `GET
// /api/git/pr/checks?path=<repo>[&pr=<n|url>][&provider=]`.
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
// Wire shape for `GET
// /api/git/pr/conflicts?path=<repo>&pr_url=<url>[&provider=][&base=][&head=]`.
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
// Wire shape for `GET /api/git/branches?path=<repo>`.
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
// Wire shape for `GET /api/git/commit?path=<repo>&sha=<sha>`.
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
// Wire shape for `GET
// /api/git/commit/file?path=<repo>&sha=<sha>&file=<path>`.
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
// Typed response for `POST /api/workspaces/reorder`.
pub const WorkspacesReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspacesReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspacesReorderResponse{ .count = count }, .{});
}

// Typed response for `POST /api/workspaces/:workspace_id/items/reorder`.
// Mirrors WorkspacesReorderResponse — same shape, same std.json.Stringify
// pattern.
pub const WorkspaceItemReorderResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeWorkspaceItemReorderResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, WorkspaceItemReorderResponse{ .count = count }, .{});
}

/// Typed response for `POST /api/.../tasks/:task_id/pin`. Returns the new
/// `pinned_position` so the client can confirm the row landed at the bottom
/// of the pinned region. `is_pinned` echoes the requested state.
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

/// Typed response for `POST /api/.../tasks/reorder_pinned`.
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
pub const DesignPageResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// 1:1 FK to `workspace_item_tasks.id`. Set atomically by
    /// `design_model.setDesignPage` at create time.
    workspace_item_task_id: []const u8,
    width: i64,
    height: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignPage` (or any struct with the same fields) into
/// a `DesignPageResponse`.
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

/// Build the `{"pages":[...], "count": N}` envelope used by `GET
/// /design/pages`.
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
    /// FK to a `group`/`frame` element on the same page (empty string for
    /// top-level elements).
    parent_id: []const u8,
    z_index: i64,
    position: i64,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `design_model.DesignElement` (or any struct with the same fields)
/// into a `DesignElementResponse`.
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

/// Build the `{"elements":[...], "count": N}` envelope used by callers that
/// want to return a flat element list (currently unused by the 9 HTTP
/// handlers — all of them wrap the elements inside a `DesignPageWithElements`
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
/// `getPageWithElements`.
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
// Wire shapes for `/api/workspaces/:wsId/documents[/:documentId]` (Migration
// 098).
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
    position: i64,
};

/// Map a `documents_store.DocumentRow` (or any struct with the same fields)
/// into the wire shape.
pub fn makeDocumentResponse(doc: anytype) DocumentResponse {
    return .{
        .id = doc.id,
        .workspace_id = doc.workspace_id,
        .title = doc.title,
        .content = doc.content,
        .format = doc.format,
        .created_at = doc.created_at,
        .updated_at = doc.updated_at,
        .position = doc.position,
    };
}

pub const DocumentListResponse = struct {
    documents: []const DocumentResponse,
    count: u32,
};

/// Build the `{"documents":[...], "count": N}` envelope. The inner slice is
/// allocated from the per-request arena and freed before this function
/// returns; the outer envelope JSON is what the caller receives.
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
// Wire shapes for `/api/workspaces/:wsId/secrets[/:secretId]` (Migration
// 103).
pub const SecretResponse = struct {
    id: []const u8,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

/// Map a `secrets_store.SecretRow` (or any struct with the same fields) into
/// the wire shape. `anytype` for the same reason as `makeDocumentResponse`:
/// the data layer and the wire shape must be able to move independently.
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

/// `GET /api/workspaces/:workspace_id/secrets/:secret_id/reveal` — the ONE
/// response in this file that carries a credential. Only built after the
/// membership gate has passed.
pub const SecretRevealResponse = struct {
    id: []const u8,
    name: []const u8,
    value: []const u8,
};

pub fn makeSecretRevealResponse(revealed: anytype) SecretRevealResponse {
    return .{
        .id = revealed.id,
        .name = revealed.name,
        .value = revealed.value,
    };
}

// ─── Frontend error log response types ────────────────────────────────────
// Wire shapes for `POST /api/logs` (no response body, 204 No Content) and
// `GET /api/logs` (returns `{ logs: [...], count: N }`).
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

/// One `skill_metadata` row as it goes on the wire: a SKILL.md frontmatter
/// key that has no column of its own (`origin`, `tags`, `license`, …).
pub const SkillMetadataEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// One skill as it goes on the wire: the body, the companion count, and the
/// metadata the `skills` columns do not carry.
pub const SkillDetailResponse = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    asset_count: usize,
    is_can_auto_improve: bool,
    metadata: []const SkillMetadataEntry,
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
        .is_can_auto_improve = skill.is_can_auto_improve,
        .metadata = skill.metadata,
    };
}

// ─── Workspace member response types ────────────────────────────────
// Wire shapes for `/api/workspaces/:wsId/members[/:userId]`.
pub const WorkspaceMemberResponse = struct {
    workspace_id: []const u8,
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
    role: []const u8,
    joined_at: []const u8,
    invited_by: []const u8,
};

/// Map a `workspace_members_store.MemberRow` (or any struct with the same
/// fields) into the wire shape, for the same reason as
/// `makeSecretResponse`: the data layer and the wire must move independently.
pub fn makeWorkspaceMemberResponse(member: anytype) WorkspaceMemberResponse {
    return .{
        .workspace_id = member.workspace_id,
        .user_id = member.user_id,
        .email = member.email,
        .name = member.name,
        .role = member.role,
        .joined_at = member.joined_at,
        .invited_by = member.invited_by,
    };
}

pub const WorkspaceMemberListResponse = struct {
    members: []const WorkspaceMemberResponse,
    count: u32,
};

pub fn makeWorkspaceMemberListResponse(allocator: std.mem.Allocator, members: anytype) ![]u8 {
    const mapped = try allocator.alloc(WorkspaceMemberResponse, members.len);
    defer allocator.free(mapped);
    for (members, 0..) |m, i| mapped[i] = makeWorkspaceMemberResponse(m);

    return std.json.Stringify.valueAlloc(
        allocator,
        WorkspaceMemberListResponse{
            .members = mapped,
            .count = @intCast(members.len),
        },
        .{},
    );
}

// ─── Workspace invitation response types ────────────────────────────
// Wire shapes for `/api/workspaces/:wsId/invitations` and `/api/invitations`.
pub const WorkspaceInvitationResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    invitee_user_id: []const u8,
    invitee_email: []const u8,
    invitee_name: []const u8,
    role: []const u8,
    invited_by: []const u8,
    created_at: []const u8,
};

pub fn makeWorkspaceInvitationResponse(invitation: anytype) WorkspaceInvitationResponse {
    return .{
        .id = invitation.id,
        .workspace_id = invitation.workspace_id,
        .workspace_name = invitation.workspace_name,
        .invitee_user_id = invitation.invitee_user_id,
        .invitee_email = invitation.invitee_email,
        .invitee_name = invitation.invitee_name,
        .role = invitation.role,
        .invited_by = invitation.invited_by,
        .created_at = invitation.created_at,
    };
}

pub const WorkspaceInvitationListResponse = struct {
    invitations: []const WorkspaceInvitationResponse,
    count: u32,
};

pub fn makeWorkspaceInvitationListResponse(allocator: std.mem.Allocator, invitations: anytype) ![]u8 {
    const mapped = try allocator.alloc(WorkspaceInvitationResponse, invitations.len);
    defer allocator.free(mapped);
    for (invitations, 0..) |invitation, i| mapped[i] = makeWorkspaceInvitationResponse(invitation);

    return std.json.Stringify.valueAlloc(
        allocator,
        WorkspaceInvitationListResponse{
            .invitations = mapped,
            .count = @intCast(invitations.len),
        },
        .{},
    );
}
