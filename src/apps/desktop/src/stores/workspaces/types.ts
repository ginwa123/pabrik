import type { DesignElement, TaskDependencyBlocker } from '../../api'

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /** Free-text description of the column's meaning. Empty string when no description has been set.
   * Mirrors the `KanbanColumn` interface in `api/index.ts` so test fixtures that import this type
   * see the same shape. */
  description?: string | null
  position: number
  created_at: string
  // NEW (kanban task dependencies). `is_done` marks a column as
  // completing: cards here no longer block their dependents.
  is_done?: boolean
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // 1 when this is the workspace's default project (Migration 094) — an `item_type: 'agent'` item
  // whose `path` is the server user's home directory, and where the "New Chat" action creates its
  // chat.
  is_default?: number
  // The on-disk cwd for kanban items. Optional (matches the API interface in api/index.ts): legacy
  // kanbans have no path (the API returns `null` for unset rows), folder items never set it, test
  // fixtures may omit it.
  path?: string | null
  lastAccessed?: Date
  entries?: FolderEntry[] // Nested folder contents
  isLoaded?: boolean // Whether contents have been fetched
  isLoading?: boolean // Loading state
  expanded?: boolean // Whether nested contents are expanded
  tasks?: Task[] // Tasks within this project
  // Per-column pagination state (kanban-per-column-pagination plan, 2026-08-06). Replaces the
  // board-wide `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` triple. See
  // `loadMoreTasksForColumn` action below.
  columnPagination?: Record<string, ColumnPaginationState>
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for `item_type === 'kanban'` items.
  // Optional so legacy literals (5+ test files construct WorkspaceItem without this field) keep
  // type-checking — see the pabrik-frontend-task-literal-typing-rule memory.
  kanban_columns?: KanbanColumn[]
  // NEW (Chunk 6 of design-mode-redesign plan). Populated for `item_type === 'design'` items when
  // the active page is open.
  design_elements?: DesignElement[]
}

// Per-column pagination state (kanban-per-column-pagination plan, 2026-08-06). Each kanban column
// has its own cursor + hasMore flag so the auto-load sentinel + manual "Load more" button in
// `KanbanColumn.vue` can fetch the next page for ONE column without touching the others.
export interface ColumnPaginationState {
  cursor: string | null
  hasMore: boolean
  isLoading: boolean
}

export interface Workspace {
  id: string
  name: string
  icon: string
  items: WorkspaceItem[]
  // Server-side item count (GET /api/workspaces sends it even with
  // is_include_items=false), so count badges don't depend on whether
  // this workspace's items have been lazily loaded yet.
  items_count?: number
  // Whether the workspace's work runs in a microVM on this server. False on
  // a local server (no Firecracker at all), true for the VM-backed workspaces
  // of a `--saas` server.
  is_vm?: boolean
  expanded: boolean
}

export interface SystemFolderInfo {
  path: string
  absolute: string
  home: string
  parent?: string
  entries?: FolderEntry[]
}

export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

// Task interface for project tasks `task_type` distinguishes standard chat tasks from markdown
// memories. ('routine' was deleted in Migration 084 — routines are now first-class workspace items,
// see `WorkspaceRoutine` in api.)
export interface Task {
  id: string
  name: string
  description?: string
  // NEW (Chunk 5 of task-routines plan, deleted Migration 084). Optional for backwards compat with
  // legacy task literals (tests + offline fallbacks). 'memory' added in 2026-06-20 for the
  // markdown-memory feature.
  task_type?: 'standard' | 'memory'
  // NEW: present iff task_type === 'memory'. Captures the .md
  // file name (no extension in the path; just the basename like
  // 'project-notes.md') for the UI badge.
  memory_name?: string
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
  // NEW (pinned-tasks feature, plan:
  // Task without these fields) keep type-checking — see the
  // pabrik-frontend-task-literal-typing-rule memory.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for tasks under `item_type === 'kanban'`
  // parents. `kanban_column_id` is `null` (not undefined) when the task is unassigned. Both
  // optional so legacy task literals keep type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (Chunk 5 of auto-retry-until-stop plan). Mirrors the sessions.is_auto_retry_until_stop
  // column (Migration 063). task.id == session.id (project convention) so the flag can be persisted
  // via PUT /api/llm/session/<id>.
  is_auto_retry_until_stop?: string
  // NEW (kanban-task-notification-icon feature). Backend-computed boolean from
  // Migration 065 + sessions.last_finish_reason.
  needs_human_review?: boolean
  // NEW: denormalized cache of the session's last_finish_reason (joined from
  // sessions.last_finish_reason on the kanban SELECT). Empty string when no session row exists.
  last_finish_reason?: string
  // NEW (kanban task tags feature).
  // Array of free-form tag strings (Migration 067). Empty array = no tags. Optional for backwards
  // compat with legacy task literals in tests.
  tags?: string[]
  // NEW (kanban image urls)
  // Migration 069). Array of base64 data URLs (`data:image/<mime>;base64,<payload>`). Empty array =
  // no images. Optional for backwards compat with legacy task literals in tests.
  imageUrls?: string[]
  // NEW (Migration 090 — kanban video urls column). Same contract
  // as imageUrls, normalized by normalizeTaskVideoUrlsInPlace.
  videoUrls?: string[]
  // NEW (Media-flags change — lightweight list/get payload). Backend
  // list/get return only these flags; imageUrls/videoUrls above are
  // populated lazily via fetchTaskMedia when a flag is true.
  is_have_image?: boolean
  is_have_video?: boolean
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Absolute path on
  // disk or '' for cwd-less. Optional for backwards compat with legacy task literals in tests.
  cwd?: string
  // NEW (kanban task git-branch badge).
  git_branch?: string | null
  // NEW (kanban task dependencies). `depends_on` lists ids this task waits for; `blocked_by` is
  // the incomplete subset; `is_blocked` mirrors `blocked_by.length > 0`.
  depends_on?: string[]
  blocked_by?: TaskDependencyBlocker[]
  is_blocked?: boolean
  skill_names?: string
}
