import type { DesignElement, TaskDependencyBlocker } from '../../api'

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /** Free-text description of the column's meaning. */
  description?: string | null
  position: number
  created_at: string
  // NEW (kanban task dependencies).
  is_done?: boolean
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // 1 when this is the workspace's default project (Migration 094) — an `item_type: 'agent'` item whose `path` is the server user's home directory, and where the …
  is_default?: number
  // The on-disk cwd for kanban items.
  path?: string | null
  // Migration 147 — the project's own glyph name, or null/absent for "no override".
  icon?: string | null
  lastAccessed?: Date
  entries?: FolderEntry[] // Nested folder contents
  isLoaded?: boolean // Whether contents have been fetched
  isLoading?: boolean // Loading state
  expanded?: boolean // Whether nested contents are expanded
  tasks?: Task[] // Tasks within this project
  // Per-column pagination state (kanban-per-column-pagination plan, 2026-08-06).
  columnPagination?: Record<string, ColumnPaginationState>
  // NEW (Chunk 4 of workspace-item-kanban plan).
  kanban_columns?: KanbanColumn[]
  // NEW (Chunk 6 of design-mode-redesign plan).
  design_elements?: DesignElement[]
}

// Per-column pagination state (kanban-per-column-pagination plan, 2026-08-06).
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
  // Server-side item count (GET /api/workspaces sends it even with is_include_items=false), so count badges don't depend on whether this workspace's items have …
  items_count?: number
  // Whether the workspace's work runs in a microVM on this server.
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

// Task interface for project tasks `task_type` distinguishes standard chat tasks from markdown memories.
export interface Task {
  id: string
  name: string
  description?: string
  // NEW (Chunk 5 of task-routines plan, deleted Migration 084).
  task_type?: 'standard' | 'memory'
  // NEW: present iff task_type === 'memory'.
  memory_name?: string
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
  // NEW (pinned-tasks feature, plan
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan).
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (Chunk 5 of auto-retry-until-stop plan).
  is_auto_retry_until_stop?: string
  // NEW (kanban-task-notification-icon feature).
  needs_human_review?: boolean
  // NEW: denormalized cache of the session's last_finish_reason (joined from sessions.last_finish_reason on the kanban SELECT).
  last_finish_reason?: string
  // NEW (kanban task tags feature).
  tags?: string[]
  // NEW (kanban image urls) Migration 069).
  imageUrls?: string[]
  // NEW (Migration 090 — kanban video urls column).
  videoUrls?: string[]
  // NEW (Media-flags change — lightweight list/get payload).
  is_have_image?: boolean
  is_have_video?: boolean
  // NEW (Migration 070 — kanban-cwd-session-optional plan).
  cwd?: string
  // NEW (kanban task git-branch badge).
  git_branch?: string | null
  // NEW (kanban task dependencies).
  depends_on?: string[]
  blocked_by?: TaskDependencyBlocker[]
  is_blocked?: boolean
  skill_names?: string
}
