import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { useNavigationStore } from './navigation'
import { useNotificationStore } from './notifications'
import { useSseBus } from '../helpers/sseBus'
import { designLogger } from '../helpers/designLogger'
import { readWorkspacesCache } from '../helpers/workspacesCache'
import { userScopedKey, isIdentityResolved } from '../helpers/userScope'
import { readTaskMediaCache, writeTaskMediaCache } from '../helpers/taskMediaCache'
import { TaskEngineDb, type TaskRequest } from '../sync/TaskEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../sync/runtime'
import type { DesignElement, DesignPage } from '../api'

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
  skill_names?: string}

// localStorage keys for state persistence
const STORAGE_KEY_WORKSPACE_EXPANDED = 'pabrik-workspace-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_EXPANDED = 'pabrik-workspace-item-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED = 'pabrik-workspace-item-tasks-expanded'
// Persisted header-dropdown selection.
const STORAGE_KEY_ACTIVE_WORKSPACE = 'pabrik-active-workspace'

// Kanban task tags normalization (Migration 067).
function normalizeTaskTags(task: Task): Task {
  // Kanban task dependencies ride the same fetch sites: coerce
  // `depends_on` to string[] (wire is a real array; tolerated
  // as a JSON string defensively, absent stays absent).
  normalizeTaskDependsOn(task)
  if (task.tags === undefined) {
    // Still normalize imageUrls + dates even when tags is missing
    // (the fields are independent — a task can have tags but no
    // images or vice versa).
    normalizeTaskImageUrlsInPlace(task)
    normalizeTaskVideoUrlsInPlace(task)
    normalizeTaskDatesInPlace(task)
    return task
  }
  // Coerce anything (string, already-array, missing) to a string[]. Defensive: legacy rows from
  // before Migration 067 might have undefined OR an empty string.
  if (typeof task.tags === 'string') {
    try {
      const parsed = JSON.parse(task.tags) as unknown
      task.tags = Array.isArray(parsed) ? (parsed as string[]) : []
    } catch {
      task.tags = []
    }
  } else if (!Array.isArray(task.tags)) {
    task.tags = []
  }
  normalizeTaskImageUrlsInPlace(task)
  normalizeTaskVideoUrlsInPlace(task)
  normalizeTaskDatesInPlace(task)
  return task
}

// Parse the backend's wire-format datetime string into a Date. Backend format: `"YYYY-MM-DD
// HH:MM:SS"` (UTC, from SQLite DATETIME columns) OR an ISO 8601 string (`"YYYY-MM-DDTHH:MM:SSZ"` /
// with offset).
function parseBackendDatetime(value: unknown): Date | undefined {
  if (typeof value !== 'string' || value.length === 0) return undefined
  // Normalise "YYYY-MM-DD HH:MM:SS" → "YYYY-MM-DDTHH:MM:SS" so the Date ctor parses it. Then inject
  // an explicit `Z` (UTC) when the string has no timezone marker — the backend stores UTC strings
  // without an explicit zone.
  const isoish = value.includes('T') ? value : value.replace(' ', 'T')
  const hasZone = isoish.endsWith('Z') || /[+-]\d{2}:?\d{2}$/.test(isoish)
  const d = new Date(hasZone ? isoish : isoish + 'Z')
  return Number.isNaN(d.getTime()) ? undefined : d
}

// Wire→in-memory date normalization for tasks. The backend returns `created_at` and `updated_at` as
// snake_case UTC strings (`"2026-08-05 04:24:56"`). The `Task` interface declares `createdAt?:
// Date` and `updatedAt?: Date` (camelCase, Date object).
function normalizeTaskDatesInPlace(task: Task): void {
  // The wire fields aren't declared on the local `Task` interface (only the camelCase Date variants
  // are), so we cast through `unknown` to access them. This is the same pattern used by the
  // existing tags + imageUrls normalizers in this file.
  const wire = task as unknown as Record<string, unknown>
  if (task.updatedAt === undefined) {
    const parsed = parseBackendDatetime(wire['updated_at'])
    if (parsed !== undefined) task.updatedAt = parsed
  }
  if (task.createdAt === undefined) {
    const parsed = parseBackendDatetime(wire['created_at'])
    if (parsed !== undefined) task.createdAt = parsed
  }
}

// Decode the `||`-delimited `image_urls` wire string into a `string[]` (Migration 069 — kanban
// image urls column).
function normalizeTaskImageUrlsInPlace(task: Task): void {
  // Wire→camel bridge (read-path fix, 2026-08-24): the backend's WorkspaceItemTaskResponse
  // serializes the field as snake_case `image_urls` (the ||-delimited string), but the Task
  // interface + every consumer read camelCase `imageUrls`.
  if (task.imageUrls === undefined) {
    const wire = task as unknown as Record<string, unknown>
    const wireVal = wire['image_urls']
    if (wireVal === undefined) return
    // Present the wire value to the splitter below via the camelCase
    // field (string | string[] | anything-else all handled there).
    task.imageUrls = wireVal as string[]
  }
  // Already an array (legacy code paths / optimistic local writes).
  if (Array.isArray(task.imageUrls)) return
  // Wire format: `||`-delimited base64 data URLs. '' → [] (no images) 'data:...' → ['data:...']
  // (one image) 'a||b||c' → ['a', 'b', 'c'] (multiple images) Filter empty segments so
  // trailing/consecutive `||` don't leak through as empty entries.
  if (typeof task.imageUrls === 'string') {
    const joined = task.imageUrls as string
    if (joined === '') {
      task.imageUrls = []
    } else {
      task.imageUrls = joined.split('|').filter((s) => s.length > 0)
    }
  } else {
    task.imageUrls = []
  }
}

// Decode the `||`-delimited `video_urls` wire string into a `string[]`
// (Migration 090 — kanban video urls column). Same wire→camel bridge
// + splitter contract as normalizeTaskImageUrlsInPlace above.
function normalizeTaskVideoUrlsInPlace(task: Task): void {
  if (task.videoUrls === undefined) {
    const wire = task as unknown as Record<string, unknown>
    const wireVal = wire['video_urls']
    if (wireVal === undefined) return
    task.videoUrls = wireVal as string[]
  }
  if (Array.isArray(task.videoUrls)) return
  if (typeof task.videoUrls === 'string') {
    const joined = task.videoUrls as string
    if (joined === '') {
      task.videoUrls = []
    } else {
      task.videoUrls = joined.split('|').filter((s) => s.length > 0)
    }
  } else {
    task.videoUrls = []
  }
}

// Decode the `||`-delimited `image_urls` wire string into a `string[]` (REMOVED — folded into
// normalizeTaskTags above.
export const RECENT_MUTATION_TTL_MS = 1500

const recentLocalMutations = new Map<string, number>()

export function registerRecentLocalMutations(ids: string[], expiryMs: number): void {
  const now = Date.now()
  // Lazy GC: drop expired entries on every register call to keep
  // the Map small. O(N) per PATCH is acceptable for v1 (worst case
  // bounded by the mutation rate; typically < 50 entries).
  for (const [id, exp] of recentLocalMutations) {
    if (exp < now) recentLocalMutations.delete(id)
  }
  for (const id of ids) {
    recentLocalMutations.set(id, expiryMs)
  }
}

/**  * True iff `elementId` was mutated by this client within the last `RECENT_MUTATION_TTL_MS`
 * milliseconds. Read by the SSE handler to decide whether to skip the GET fan-out for an incoming
 * event. Exported for `stores/designSse.ts`. Side effect: expired entries are lazily GC'd on read. */
export function isRecentLocalMutation(elementId: string): boolean {
  const exp = recentLocalMutations.get(elementId)
  if (exp === undefined) return false
  if (exp < Date.now()) {
    recentLocalMutations.delete(elementId)
    return false
  }
  return true
}

/**  * Test-only helper to clear the dedupe Map between tests. NOT exposed in the production API surface
 * — exported via the store's returned object only for unit tests. */
export function _clearRecentLocalMutationsForTests(): void {
  recentLocalMutations.clear()
}

import * as api from '../api'
// Aliases for design-mode API functions whose names collide with the store action wrappers below
// (Task 6.1 of design-mode-redesign plan). `getDesignPage` doesn't collide so it stays as a bare
// api lookup (no `api.getDesignPage(...)` in the action).
import {
  addDesignElement as addDesignElementApi,
  updateDesignElement as updateDesignElementApi,
  updateDesignElementHtml as updateDesignElementHtmlApi,
  deleteDesignElement as deleteDesignElementApi,
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the store owns a `designPagesByItemId`
  // cache so both the sidebar tree and DesignView read from the same source. listDesignPages is now
  // called from `fetchDesignPages` (defined below in this file) instead of the per-component.
  listDesignPages as listDesignPagesApi,
  createDesignPage as createDesignPageApi,
  deleteDesignPage as deleteDesignPageApi,
  updateDesignElementGeometry as updateDesignElementGeometryApi,
  updateDesignElementsGeometryBatch as updateDesignElementsGeometryBatchApi,
  // NEW (2026-08-06) — replace the conflated /geometry endpoint with
  // two distinct endpoints: /translate (move) and /resize.
  translateDesignElement as translateDesignElementApi,
  resizeDesignElement as resizeDesignElementApi,
  updateDesignPage as updateDesignPageApi,
  groupDesignElements as groupDesignElementsApi,
  reorderDesignElements as reorderDesignElementsApi,
  ungroupDesignElements as ungroupDesignElementsApi,
  reparentDesignElementsBatch as reparentDesignElementsBatchApi,
  moveDesignElementsBatch as moveDesignElementsBatchApi,
  type GeometryBatchUpdate,
  type MoveBatchItem,
  type GroupDesignElementsRequest,
  type ReparentDesignElementsBatchRequest,
  type ReorderMode,
  normalizeDesignElementType,
  normalizeTaskDependsOn,
  type TaskDependencyBlocker,
} from '../api'

// Re-exported so card/row/dialog components import the blocker
// shape from the store alongside Task (single import site).
export type { TaskDependencyBlocker } from '../api'

export const useWorkspacesStore = defineStore('workspaces', () => {
  // Loading state
  const isLoading = ref(false)
  const loadingError = ref<string | null>(null)

  // Current active workspace item (for main content/FolderExplorer)
  const activeWorkspaceItemId = ref<string | null>(null)

  // Explicitly selected workspace (header dropdown + Projects section).
  const activeWorkspaceId = ref<string | null>(null)

  // Set of expanded workspace item IDs (for showing tasks list - allows multiple)
  const expandedItemIds = ref<Record<string, boolean>>({})

  // Active task within the selected workspace item
  const activeTaskId = ref<string | null>(null)

  // FIX (task-url-overwrite, task_1785959660154, 2026-08-06): Navigation flag the AppLayout URL
  // sync watcher checks before mirroring activeWorkspaceItemId / activeDesignPageId to the URL. Set
  // true at the start of Sidebar.handleSelectTask and cleared after the router.push resolves.
  const isNavigatingToTask = ref(false)

  // Kanban sort-by round-trip preservation (plan 2026-08-06-kanban- sort-by.md): when the user
  // opens a kanban task from the kanban board, Sidebar snapshots the current `?sorts=` into this
  // field.
  const savedSortsParam = ref<string>('')

  // NEW (Chunk 1 of design-element-drag-and-drop plan). The currently active design page id, set by
  // DesignView on mount / tab switch and cleared on unmount.
  const activeDesignPageId = ref<string>('')
  function setActiveDesignPage(pageId: string): void {
    activeDesignPageId.value = pageId
  }

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): single source of truth for design pages,
  // keyed by workspace item id. Both the sidebar tree (WorkspaceItem.vue) and the design canvas
  // (DesignView.vue) read from this map.
  const designPagesByItemId = ref<Record<string, DesignPage[]>>({})

  // In-flight guard for `fetchDesignPages` — if a fetch is already pending for the same
  // workspaceItemId, return its promise instead of starting a second one.
  const designPagesInFlight = new Map<string, Promise<DesignPage[]>>()

  // Reset design-pages cache for an item. Used on store init so a
  // re-init doesn't show stale pages from the previous session.
  // Currently called from `init()` at the bottom of the file.
  function resetDesignPagesCache(): void {
    designPagesByItemId.value = {}
    designPagesInFlight.clear()
  }

  // NEW (kanban task search feature). Map<itemId, q> — the active search query per board.
  const activeSearchQueries: Map<string, string> = new Map()

  // NEW (kanban-sort-by).
  // Map<itemId, sortField> + Map<itemId, direction> — the active per-board sort.
  const activeSortBy: Map<string, 'created_at' | 'updated_at' | 'name'> = new Map()
  const activeSortDirection: Map<string, 'asc' | 'desc'> = new Map()

  // Per-column FIRST-PAGE loading signal. A reactive Set of `${itemId}:${columnId}` keys, true
  // while that column's page-1 fetch is in flight.
  const firstPageLoadingColumns = ref<Set<string>>(new Set())

  const firstPageLoadingKey = (itemId: string, columnId: string) => `${itemId}:${columnId}`

  function isFirstPageLoading(itemId: string, columnId: string): boolean {
    return firstPageLoadingColumns.value.has(firstPageLoadingKey(itemId, columnId))
  }

  // Design-element fetch signal. Holds `${itemId}:${pageId}` while that page's elements are in
  // flight, null otherwise.
  const designElementsLoadingKey = ref<string | null>(null)

  function isDesignElementsLoading(itemId: string, pageId: string): boolean {
    return designElementsLoadingKey.value === `${itemId}:${pageId}`
  }

  const taskEngineDb = new TaskEngineDb()

  function taskRequest(
    workspaceId: string,
    itemId: string,
    columnId?: string,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): TaskRequest {
    return {
      workspaceId,
      itemId,
      ...(columnId ? { columnId } : {}),
      ...(q ? { q } : {}),
      ...(sortBy ? { sortBy } : {}),
      ...(direction ? { direction } : {}),
    }
  }

  function taskCacheContexts(
    workspaceId: string,
    itemId: string,
    columnId?: string,
  ): TaskRequest[] {
    return [taskRequest(workspaceId, itemId, columnId), taskRequest(workspaceId, itemId)]
  }

  function replaceItemTasksForColumn(item: WorkspaceItem, columnId: string, rows: Task[]): void {
    const normalized = rows.map(normalizeTaskTags)
    const freshIds = new Set(normalized.map((task) => task.id))
    const otherTasks = (item.tasks ?? []).filter(
      (task) => task.kanban_column_id !== columnId && !freshIds.has(task.id),
    )
    item.tasks = [...otherTasks, ...normalized]
  }

  async function cacheTaskMutation(
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ): Promise<void> {
    await runSyncVoid(
      taskEngineDb.putTaskInContexts(taskCacheContexts(workspaceId, itemId, columnId), task),
      'tasks.putTaskInContexts',
    )
  }

  // Evict one task from every cache context it could live in (the
  // task's column context plus the board-wide context). Every cache
  // write goes through taskCacheContexts, so these two cover it.
  async function removeTaskFromCache(
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId?: string,
  ): Promise<void> {
    for (const request of taskCacheContexts(workspaceId, itemId, columnId)) {
      await runSyncVoid(taskEngineDb.removeTask(request, taskId), 'tasks.removeTask')
    }
  }

  async function primeTaskCache(
    workspaceId: string,
    itemId: string,
    columnId: string | undefined,
    limit: number,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<Task[]> {
    const request = taskRequest(workspaceId, itemId, columnId, q, sortBy, direction)
    const rows = await runSyncEffectOr(
      taskEngineDb.primeFromCache(request, limit),
      [],
      'tasks.primeFromCache',
    )
    return rows.map((row) => normalizeTaskTags(row.raw))
  }

  async function revalidateTaskCache(
    workspaceId: string,
    itemId: string,
    columnId: string | undefined,
    limit: number,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<{ tasks: Task[]; has_more: boolean; next_cursor: string | null } | null> {
    const request = taskRequest(workspaceId, itemId, columnId, q, sortBy, direction)
    const delta = await runSyncEffect(taskEngineDb.loadDelta(request, limit), 'tasks.loadDelta')
    if (!delta) return null
    return {
      tasks: delta.items.map((row) => normalizeTaskTags(row.raw)),
      has_more: delta.hasMore,
      next_cursor: delta.paginationCursor,
    }
  }

  // System folder info from API
  const systemFolderInfo = ref<SystemFolderInfo | null>(null)
  const systemFolderLoading = ref(false)
  const systemFolderError = ref<string | null>(null)

  // Workspaces with their items
  const workspaces = ref<Workspace[]>([])

  // Load expanded workspace IDs from localStorage
  function loadExpandedWorkspaces(): Set<string> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          return new Set(parsed)
        }
      } catch (e) {
        console.error('Failed to parse expanded workspaces:', e)
      }
    }
    return new Set()
  }

  // Load expanded workspace item IDs from localStorage (for nested folder expansion)
  function loadExpandedItems(): Set<string> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          return new Set(parsed)
        }
      } catch (e) {
        console.error('Failed to parse expanded items:', e)
      }
    }
    return new Set()
  }

  // Load expanded workspace item IDs for tasks list from localStorage
  function loadExpandedItemIds(): Record<string, boolean> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          const record: Record<string, boolean> = {}
          for (const id of parsed) {
            record[id] = true
          }
          return record
        }
      } catch (e) {
        console.error('Failed to parse expanded item IDs:', e)
      }
    }
    return {}
  }

  // Save expanded workspace IDs to localStorage
  function saveExpandedWorkspaces(expandedIds: Set<string>) {
    localStorage.setItem(STORAGE_KEY_WORKSPACE_EXPANDED, JSON.stringify(Array.from(expandedIds)))
  }

  // Save expanded workspace item IDs to localStorage (for nested folder expansion)
  function saveExpandedItems(expandedIds: Set<string>) {
    localStorage.setItem(
      STORAGE_KEY_WORKSPACE_ITEM_EXPANDED,
      JSON.stringify(Array.from(expandedIds)),
    )
  }

  // Save expanded workspace item IDs for tasks list to localStorage
  function saveExpandedItemIds(expandedIds: Record<string, boolean>) {
    localStorage.setItem(
      STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED,
      JSON.stringify(Object.keys(expandedIds)),
    )
  }

  // jsdom 29 dropped localStorage from the default globals — specs
  // that don't install the stub must not crash the getter.
  function readActiveWorkspaceKey(): string | null {
    try {
      return localStorage.getItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE))
    } catch {
      return null
    }
  }

  function writeActiveWorkspaceKey(value: string | null) {
    try {
      if (value === null) {
        localStorage.removeItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE))
      } else {
        localStorage.setItem(userScopedKey(STORAGE_KEY_ACTIVE_WORKSPACE), value)
      }
    } catch {
      // Storage unavailable — the selection just isn't persisted.
    }
  }

  // The persisted dropdown selection, validated against the loaded
  // list — a stale id (workspace deleted in another tab / by API)
  // falls through to the item-derived / first-workspace fallbacks.
  function storedActiveWorkspace(): Workspace | undefined {
    const saved = readActiveWorkspaceKey()
    if (!saved) return undefined
    return workspaces.value.find((ws) => ws.id === saved)
  }

  // ─── Lazy per-workspace item loading ──────────────────────────────── init seeds every workspace row
  // with `items: []` and loads items only for the ACTIVE workspace.
  let currentInit: Promise<void> | null = null
  const workspaceItemsLoaded = new Set<string>()
  const workspaceItemsInFlight = new Map<string, Promise<void>>()

  /** Fetch + attach ONE workspace's items: per-item tasks (kanban and design skip — kanban
   * populates per-column on mount, design has no task list), eager design pages, and kanban
   * column/task prefetch. */
  async function loadWorkspaceItems(ws: Workspace): Promise<void> {
    // Items for this workspace.
    const { items } = await api.getWorkspacesItems(ws.id)
    const expandedItems = loadExpandedItems()

    // Tasks for each item in this workspace (per-item, in parallel).
    const tasksByItem = new Map<string, Task[]>()
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type === 'kanban' || item.item_type === 'design') {
          // Kanban: defer to KanbanView onMount — fires per-column fetches with column_id set (per
          // Option B). Design: design items have no tasks list; the sidebar shows design pages
          // instead (see design-pages-in-workspace-tree plan).
          return
        }
        try {
          const cached = await primeTaskCache(ws.id, item.id, undefined, 10)
          if (cached.length > 0) tasksByItem.set(item.id, cached)
          const fresh = await revalidateTaskCache(ws.id, item.id, undefined, 10)
          if (fresh) {
            // A complete page (has_more=false) lists every row in this context —
            // cached rows it omits were deleted or moved out, so they are dropped
            // instead of merged back in.
            const merged = new Map((fresh.has_more ? cached : []).map((task) => [task.id, task]))
            for (const task of fresh.tasks) merged.set(task.id, task)
            tasksByItem.set(item.id, [...merged.values()])
          } else if (cached.length > 0) {
            tasksByItem.set(item.id, cached)
          }
        } catch (err) {
          console.error(`Failed to fetch tasks for item ${item.id}:`, err)
        }
      }),
    )

    // NEW (auto-expand-design-pages plan, 2026-08-06): design pages for each design item.
    // Best-effort — a single bad fetch logs but doesn't block init (the chevron-toggle lazy fetch
    // still works as a fallback).
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type !== 'design') return
        try {
          await fetchDesignPages(ws.id, item.id)
        } catch (err) {
          console.error(`Failed to fetch design pages for item ${item.id}:`, err)
        }
      }),
    )

    // NEW (kanban-prefetch-on-init plan, 2026-08-06): kanban columns + per-column task fetches for
    // each kanban item.
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type !== 'kanban') return
        try {
          // Step 1: load columns (id list for per-column fetches).
          const { columns } = await api.listKanbanColumns(ws.id, item.id)
          item.kanban_columns = [...columns].sort((a, b) => a.position - b.position)
          // Step 2: fire per-column task fetches with DEFAULT sort (page 1). Same inline reason as
          // Step 1 — fetchKanTasks uses findItem too.
          await Promise.all(
            item.kanban_columns.map(async (col) => {
              const cached = await primeTaskCache(ws.id, item.id, col.id, 10)
              if (cached.length > 0) replaceItemTasksForColumn(item, col.id, cached)
              const fresh = await revalidateTaskCache(ws.id, item.id, col.id, 10)
              if (fresh) {
                // A complete page (has_more=false) lists every row in this context —
                // cached rows it omits were deleted or moved out, so they are dropped
                // instead of merged back in.
                const merged = new Map(
                  (fresh.has_more ? cached : []).map((task) => [task.id, task]),
                )
                for (const task of fresh.tasks) merged.set(task.id, task)
                replaceItemTasksForColumn(item, col.id, [...merged.values()])
                item.columnPagination ??= {} as Record<string, ColumnPaginationState>
                item.columnPagination[col.id] = {
                  cursor: fresh.next_cursor,
                  hasMore: fresh.has_more,
                  isLoading: false,
                }
              } else if (cached.length > 0) {
                item.columnPagination ??= {} as Record<string, ColumnPaginationState>
                item.columnPagination[col.id] = {
                  cursor: null,
                  hasMore: false,
                  isLoading: false,
                }
              }
            }),
          )
        } catch (err) {
          console.error(`Failed to fetch kanban tasks for item ${item.id}:`, err)
        }
      }),
    )

    ws.items = (items || []).map((item: WorkspaceItem) => ({
      ...item,
      // Restore expanded state from localStorage
      expanded: expandedItems.has(item.id),
      // Attach tasks for this item: - Non-kanban: from tasksByItem (the api response). - Kanban:
      // PRESERVE the input's tasks (test fixtures inject tasks directly; per-column fetches via
      // KanbanView onMount will eventually replace this).
      tasks: item.item_type === 'kanban' ? (item.tasks ?? []) : (tasksByItem.get(item.id) ?? []),
      // Per-column pagination state — empty for non-kanban / non-pre-fetched items; PRESERVE the
      // kanban-prefetch entries for kanban items so the onMount loadColumnsAndTasks `needFetch`
      // filter excludes them (no redundant fetch on the user's first click).
      columnPagination:
        item.item_type === 'kanban' &&
        item.columnPagination &&
        Object.keys(item.columnPagination).length > 0
          ? item.columnPagination
          : ({} as Record<string, ColumnPaginationState>),
    }))
  }

  /** Idempotent loader for ONE workspace's items (lazy loading — plan above). Already loaded →
   * no-op; in flight → shares the same promise (dedupe); not yet loaded → loadWorkspaceItems +
   * mark. */
  async function ensureWorkspaceItemsLoaded(workspaceId: string): Promise<void> {
    if (workspaceItemsLoaded.has(workspaceId)) return
    const pending = workspaceItemsInFlight.get(workspaceId)
    if (pending) return pending

    let target = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!target && isLoading.value && currentInit) {
      // Called before init() seeded the list (URL restore racing boot) — wait for init, then
      // re-check (init's own load may cover this id meanwhile). Without this, the await below would
      // resolve while the workspace's items are still unloaded.
      try {
        await currentInit
      } catch {
        // init reports its own loadingError; nothing to do here.
      }
      if (workspaceItemsLoaded.has(workspaceId)) return
      const raced = workspaceItemsInFlight.get(workspaceId)
      if (raced) return raced
      target = workspaces.value.find((ws) => ws.id === workspaceId)
    }
    if (!target) return

    // Seeded rows already carry items (spec fixtures that assign `ws.workspaces` directly, or a row
    // populated before the loaded set was cleared): treat them as loaded so the fetch below does
    // not clobber fixture data with a mocked-empty response.
    if (target.items && target.items.length > 0) {
      workspaceItemsLoaded.add(workspaceId)
      return
    }

    const ws = target
    const run = (async () => {
      try {
        await loadWorkspaceItems(ws)
        workspaceItemsLoaded.add(workspaceId)
      } catch (err) {
        console.error(`Failed to load items for workspace ${workspaceId}:`, err)
      } finally {
        workspaceItemsInFlight.delete(workspaceId)
      }
    })()
    workspaceItemsInFlight.set(workspaceId, run)
    return run
  }

  // Initialize the store: fetch the workspace list, seed every row with empty items, then load
  // items for the ACTIVE workspace only.
  function init(): Promise<void> {
    const run = runInit()
    currentInit = run
    return run
  }

  async function runInit(): Promise<void> {
    isLoading.value = true
    loadingError.value = null

    // Wipe the design-pages cache so re-inits don't show stale pages from the previous session (the
    // chevron-click lazy fetch remains the fallback for anything not eagerly reloaded).
    resetDesignPagesCache()
    workspaceItemsLoaded.clear()
    workspaceItemsInFlight.clear()

    // Install the bus-backed session-event listeners (idempotent — safe to call on every init,
    // including HMR re-mounts). The bus is opened once by App.vue, so we don't own the SSE
    // connection here anymore (Chunk 6 of unify-frontend-sse).
    installSessionEventHandlers()

    // Seed helper: every row starts with EMPTY items — the list
    // (dropdown, sidebar, items_count badges) is complete right away;
    // the items tree fills in per visit.
    const seedList = (wsList: Workspace[]) => {
      const expandedWorkspaces = loadExpandedWorkspaces()
      const expandedIds = loadExpandedItemIds()
      // Load expanded item IDs for tasks list from localStorage
      expandedItemIds.value = expandedIds
      workspaces.value = (wsList || []).map((ws: Workspace) => ({
        ...ws,
        // Restore expanded state from localStorage
        expanded: expandedWorkspaces.has(ws.id),
        items: [],
      }))
    }

    // Merge helper for the background revalidate: refresh rows in place without clobbering items
    // already loaded for the active workspace (or expanded UI state) while the fetch was in flight.
    const mergeList = (wsList: Workspace[]) => {
      const expandedWorkspaces = loadExpandedWorkspaces()
      const prevById = new Map(workspaces.value.map((w) => [w.id, w]))
      workspaces.value = (wsList || []).map((ws: Workspace) => {
        const prev = prevById.get(ws.id)
        if (!prev) {
          return {
            ...ws,
            expanded: expandedWorkspaces.has(ws.id),
            items: [],
          }
        }
        return Object.assign(prev, ws, {
          expanded: prev.expanded ?? expandedWorkspaces.has(ws.id),
          items: prev.items ?? [],
          items_count: ws.items_count,
        })
      })
    }

    // Stale-while-revalidate: paint the last-known list synchronously so the dropdown/sidebar shows
    // rows instantly on boot, then the live fetch below refreshes it in the same init.
    // api.getWorkspaces persists every success to the cache (fail-silent).
    const cached = isIdentityResolved() ? readWorkspacesCache() : null
    const hasCache = !!cached && cached.length > 0
    if (hasCache) {
      seedList(cached as Workspace[])
      // Drop the list spinner now — rows are already visible. The
      // active workspace items still load below.
      isLoading.value = false
    }

    try {
      // Step 1: fetch the workspaces list (no items — those come separately).
      const { workspaces: wsList } = await api.getWorkspaces()
      if (hasCache) {
        mergeList(wsList || [])
      } else {
        // Step 2 (cold boot): seed every workspace row with EMPTY items.
        seedList(wsList || [])
      }

      // Step 3: load items for the ACTIVE workspace only.
      const activeId =
        activeWorkspaceId.value ?? storedActiveWorkspace()?.id ?? workspaces.value[0]?.id
      if (activeId) {
        await ensureWorkspaceItemsLoaded(activeId)
      }
    } catch (err) {
      // With a cached paint on screen, a failed revalidate keeps the
      // stale rows (and surfaces the error) instead of wiping to [].
      if (!hasCache) {
        loadingError.value = err instanceof Error ? err.message : 'Failed to load workspaces'
        console.error('Failed to load workspaces:', err)
        // Initialize with empty array on error
        workspaces.value = []
      } else {
        loadingError.value = err instanceof Error ? err.message : 'Failed to refresh workspaces'
        console.error('Failed to refresh workspaces (keeping cached list):', err)
      }
    } finally {
      isLoading.value = false
    }
  }

  // Computed: get flattened list of all workspace items
  const allWorkspaceItems = computed(() => {
    return workspaces.value.flatMap((ws) => ws.items)
  })

  // Get active workspace item details
  const activeWorkspaceItem = computed(() => {
    return allWorkspaceItems.value.find((item) => item.id === activeWorkspaceItemId.value)
  })

  // Get active workspace. Precedence (plan decision log): explicit selection (dropdown / URL
  // restore) → persisted choice → workspace owning the active item (legacy fallback) → first
  // workspace, so the dropdown and Projects section always have a target once any workspace exists.
  const activeWorkspace = computed(() => {
    return (
      workspaces.value.find((ws) => ws.id === activeWorkspaceId.value) ||
      storedActiveWorkspace() ||
      workspaces.value.find((ws) =>
        ws.items.some((item) => item.id === activeWorkspaceItemId.value),
      ) ||
      workspaces.value[0]
    )
  })

  // Get active task details
  const activeTask = computed(() => {
    if (!activeTaskId.value || !activeWorkspaceItemId.value) return null

    const workspace = workspaces.value.find((ws) =>
      ws.items.some((item) => item.id === activeWorkspaceItemId.value),
    )
    if (!workspace) return null

    const item = workspace.items.find((i) => i.id === activeWorkspaceItemId.value)
    if (!item?.tasks) return null

    return item.tasks.find((t) => t.id === activeTaskId.value) || null
  })

  // NEW (kanban-embed-chatview plan, Task 1): "which item owns the active task". Walks every
  // workspace's items + tasks looking for activeTaskId; returns the containing item's id or null.
  const activeTaskWorkspaceItemId = computed(() => {
    const taskId = activeTaskId.value
    if (!taskId) return null
    for (const ws of workspaces.value) {
      for (const item of ws.items) {
        if (item.tasks?.some((t) => t.id === taskId)) {
          return item.id
        }
      }
    }
    return null
  })

  // Actions
  async function fetchSystemFolder(folderPath?: string) {
    systemFolderLoading.value = true
    systemFolderError.value = null

    try {
      const data = folderPath ? await api.listFolder(folderPath) : await api.getSystemFolder()
      systemFolderInfo.value = {
        path: data.path,
        absolute: data.absolute,
        home: data.home,
        parent: data.parent,
        entries: data.entries,
      }
      return data
    } catch (err) {
      systemFolderError.value = err instanceof Error ? err.message : 'Failed to fetch'
      console.error('Failed to fetch system folder:', err)
      throw err
    } finally {
      systemFolderLoading.value = false
    }
  }

  // Fetch folder contents for a specific workspace item
  async function fetchFolderContents(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.path) return

    // Mark as loading
    item.isLoading = true

    try {
      const data = await fetchSystemFolder(item.path)

      // Update entries
      item.entries = data.entries || []
      item.isLoaded = true
      // Don't auto-expand - let user control expanded state
    } catch (err) {
      console.error('Failed to fetch folder contents:', err)
      item.entries = []
    } finally {
      item.isLoading = false
    }
  }

  // Toggle workspace item expansion (for nested folder contents)
  function toggleWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return

    item.expanded = !item.expanded
    // Persist to localStorage
    const expandedItems = loadExpandedItems()
    if (item.expanded) {
      expandedItems.add(itemId)
    } else {
      expandedItems.delete(itemId)
    }
    saveExpandedItems(expandedItems)
  }

  function setActiveWorkspaceItem(itemId: string | null) {
    activeWorkspaceItemId.value = itemId
  }

  // Select a workspace (header dropdown / URL restore). Clears an active item/task that belongs to
  // a DIFFERENT workspace so the Projects section and main view never mix two workspace contexts
  async function setActiveWorkspace(workspaceId: string): Promise<void> {
    if (workspaces.value.length > 0 && !workspaces.value.some((ws) => ws.id === workspaceId)) {
      return
    }
    activeWorkspaceId.value = workspaceId
    writeActiveWorkspaceKey(workspaceId)
    if (activeWorkspaceItemId.value) {
      const owner = workspaces.value.find((ws) =>
        ws.items.some((item) => item.id === activeWorkspaceItemId.value),
      )
      if (owner && owner.id !== workspaceId) {
        activeWorkspaceItemId.value = null
        activeTaskId.value = null
      }
    }
    await ensureWorkspaceItemsLoaded(workspaceId)
  }

  // Toggle expanded state for workspace item (show/hide tasks list)
  function toggleExpandedItem(itemId: string) {
    console.log(
      '[toggleExpandedItem] Before:',
      JSON.stringify(expandedItemIds.value),
      'itemId:',
      itemId,
    )
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
    } else {
      expandedItemIds.value[itemId] = true
    }
    // Trigger reactivity
    expandedItemIds.value = { ...expandedItemIds.value }
    console.log('[toggleExpandedItem] After:', JSON.stringify(expandedItemIds.value))
    saveExpandedItemIds(expandedItemIds.value)
  }

  // Returns the new workspace id on BOTH paths (API success and the
  // local offline fallback) so callers can navigate into it — the
  // /app landing pushes `/app/<id>` right after creation.
  async function addWorkspace(name: string): Promise<string> {
    const defaultIcon = '📂'
    try {
      const newWorkspace = await api.createWorkspace(name)
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        ...newWorkspace,
        expanded: expandedWorkspaces.has(newWorkspace.id),
        items: newWorkspace.items || [],
      })
      return newWorkspace.id
    } catch (err) {
      console.error('Failed to create workspace:', err)
      // Fallback to local creation if API fails
      const id = `workspace-${Date.now()}`
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        id,
        name,
        icon: defaultIcon,
        expanded: expandedWorkspaces.has(id),
        items: [],
      })
      return id
    }
  }

  async function addWorkspaceItem(
    workspaceId: string,
    name: string,
    path: string,
    itemType: string = 'folder',
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    try {
      const newItem = await api.createWorkspaceItem(workspaceId, name, path, itemType)
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        ...newItem,
        expanded: expandedItems.has(newItem.id),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return newItem.id
    } catch (err) {
      console.error('Failed to create workspace item:', err)
      // Fallback to local creation if API fails
      const itemId = `item-${Date.now()}`
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        id: itemId,
        name,
        item_type: itemType,
        path,
        expanded: expandedItems.has(itemId),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return itemId
    }
  }

  // Add a task to a workspace item. The third arg is a single params object. For a standard task
  // (the default), pass `{ name, description? }`.
  async function addTask(
    workspaceId: string,
    itemId: string,
    params: {
      name: string
      description?: string
      taskType?: 'standard' | 'memory'
      memory?: {
        name: string
        content: string
      }
      // Auto-retry-until-stop (Migration 063, Option A fix): when `'1'`, the backend ALSO inserts a
      // `sessions` row keyed by the new task.id so the unattended-mode flag persists from creation.
      // Forwarded only for standard tasks (memory has its own session lifecycle).
      isAutoRetryUntilStop?: string
      // NEW (Migration 067 — kanban task tags): array of free-form
      // tag strings. Forwarded to api.createTask which JSON-encodes
      // for the wire. Empty array / undefined = no tags.
      tags?: string[]
      // NEW (Migration 069 — kanban image urls column): array of base64 data URLs. Forwarded to
      // api.createTask which `||`-joins for the wire (matching `llm_history.image_url` convention).
      imageUrls?: string[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Forwarded to
      // api.createTask as `cwd` on the wire. Absolute path on disk or '' for cwd-less.
      cwd?: string
    },
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return undefined

    if (!item.tasks) {
      item.tasks = []
    }

    const taskType: 'standard' | 'memory' = params.taskType ?? 'standard'

    try {
      const newTask = await api.createTask(workspaceId, itemId, {
        name: params.name,
        description: params.description,
        taskType,
        memory: params.memory,
        isAutoRetryUntilStop: params.isAutoRetryUntilStop,
        // Migration 067 — pass tags through.
        tags: params.tags,
        // Migration 069 — pass image_urls through (the api helper
        // `||`-joins the array for the wire).
        imageUrls: params.imageUrls,
        // Migration 070 — pass the per-task cwd through (absolute path on disk or '' for cwd-less).
        // The api helper forwards verbatim; the backend's validated_cwd block re-validates
        // (absolute, ≤ 4 KiB, no control chars) before INSERT.
        cwd: params.cwd,
      })
      item.tasks.unshift(newTask)
      await cacheTaskMutation(workspaceId, itemId, newTask, newTask.kanban_column_id ?? undefined)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails. Match the pre-existing fallback contract (returns
      // a taskId, populates the item's tasks list) and now also carry task_type + memory so the
      // offline UI still branches correctly.
      const taskId = `task-${Date.now()}`
      item.tasks.unshift({
        id: taskId,
        name: params.name,
        description: params.description,
        task_type: taskType,
        memory_name: params.memory?.name,
        is_auto_retry_until_stop: params.isAutoRetryUntilStop,
        completed: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      })
      return taskId
    }
  }

  // Return the workspace's default project — the agent-mode item whose `path` is the server user's
  // home directory, and where the "New Chat" action creates its chat (Migration 094).
  async function ensureDefaultProject(workspaceId: string): Promise<WorkspaceItem | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const existing = workspace.items.find((item) => item.is_default === 1)
    if (existing) return existing

    try {
      const { item } = await api.getOrCreateDefaultProject(workspaceId)
      // Adopt the response's own fields when the store already holds a row
      // for that id, so an item's fetched `tasks` array is not clobbered.
      const known = workspace.items.find((it) => it.id === item.id)
      if (known) {
        Object.assign(known, item)
        return known
      }
      workspace.items.unshift(item)
      return item
    } catch (err) {
      console.error('Failed to resolve the default project for workspace', workspaceId, err)
      return undefined
    }
  }

  // ─── Kanban actions (Chunk 5 of workspace-item-kanban plan) ───────────── These five actions
  // back the kanban board UI.
  function findItem(workspaceId: string, itemId: string): WorkspaceItem | undefined {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined
    return workspace.items.find((i) => i.id === itemId)
  }

  // Create a new kanban workspace item. The backend seeds three default columns (todo / in progress
  // / done) and returns them alongside the item. We push the item into the workspace's items array
  // and pre-populate `kanban_columns` + `tasks` so the board renders immediately.
  async function addKanbanItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, columns } = await api.createKanban(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          // Defensive merge: mirror the `addDesignItem` pattern (workspaces.ts:721-748).
          name: item.name ?? name,
          item_type: item.item_type ?? 'kanban',
          path: item.path ?? path,
          kanban_columns: columns || [],
          tasks: [],
        })
        // Auto-expand the workspace to surface the new kanban and
        // persist the expansion (same UX as addWorkspaceItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addKanbanItem] API call failed:', err)
      return undefined
    }
  }

  /** Create a new design workspace item and select it. `path` is REQUIRED — design elements live as
   * HTML files at `<path>/.pabrik/design/<page>/<element>.html`. */
  async function addDesignItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const item = await api.createDesign(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        // Defensive merge: the backend now returns the full CreateDesignResponse (id, workspace_id,
        // item_type, name, path, position).
        ws.items.push({
          ...item,
          // WorkspaceItem interface fields — fall back to the form values when the response is
          // missing them.
          name: item.name ?? name,
          item_type: item.item_type ?? 'design',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        // Auto-expand the workspace + select the new item so the
        // user lands in the new DesignView (mirror addKanbanItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addDesignItem] API call failed:', err)
      return undefined
    }
  }

  // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0). Mirrors addDesignItem — POST
  // /api/workspaces/:wsId/items/agent and push the new item + a default Agent metadata block into
  // the local store.
  async function addAgentItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, agent } = await api.createAgent(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          name: item.name ?? name,
          item_type: item.item_type ?? 'agent',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      // Agent metadata is fetched lazily by AgentView via api.getAgent
      // on mount; no eager push here. We just return the new item id.
      void agent // silence unused-variable lint
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addAgentItem] API call failed:', err)
      return undefined
    }
  }

  // Backfill (or change) the `path` of a kanban workspace item. Used by the KanbanView "Set project
  // root" banner that surfaces when a kanban was created before the path field existed (the user's
  // existing kanbans all have `path = NULL`).
  async function updateKanbanItemPath(
    workspaceId: string,
    itemId: string,
    path: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { path })
      if (item) item.path = path
    } catch (err) {
      console.error('[workspacesStore.updateKanbanItemPath] API call failed:', err)
      throw err
    }
  }

  // Update kanban item name from the Settings dialog or KanbanView inline-rename pencil.
  // Optimistic: mutate `item.name` BEFORE the API call resolves so the UI updates immediately; roll
  // back on error.
  async function updateKanbanItemName(
    workspaceId: string,
    itemId: string,
    newName: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    const previousName = item?.name
    // Optimistic update.
    if (item) item.name = newName
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { name: newName })
    } catch (err) {
      // Restore the previous name on failure so the UI doesn't lie.
      if (item && previousName !== undefined) item.name = previousName
      console.error('[workspacesStore.updateKanbanItemName] API call failed:', err)
      throw err
    }
  }

  // Fetch the columns for a kanban from the backend and populate `item.kanban_columns`. Called when
  // a kanban item is expanded (mirrors the folder-item `fetchFolderContents` pattern).
  async function fetchKanbanColumns(workspaceId: string, itemId: string): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      const { columns } = await api.listKanbanColumns(workspaceId, itemId)
      // Sort defensively (the backend already orders by position, but
      // a stale local snapshot from before a backend reorder would
      // otherwise keep the old ordering).
      item.kanban_columns = [...columns].sort((a, b) => a.position - b.position)
    } catch (err) {
      console.error('[workspacesStore.fetchKanbanColumns] API call failed:', err)
      // Leave whatever columns we have (or undefined) so the UI can
      // show an empty-state rather than a hard error.
    }
  }

  // Refresh an item's tasks from the backend and merge the response into the local `item.tasks`
  // array.
  async function fetchKanbanTasks(
    workspaceId: string,
    itemId: string,
    columnId: string, // NEW (Option B) — required for per-column fetch
    limit = 10,
    cursor?: string,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mark this column's first page as in-flight so KanbanColumn / KanbanRowView can show a
    // skeleton instead of the "No tasks yet" empty state. Only for page-1 (no cursor) — a "Load
    // more" fetch already has rows on screen and its own `isLoading` flag.
    const isFirstPage = !cursor
    if (isFirstPage) {
      firstPageLoadingColumns.value.add(firstPageLoadingKey(itemId, columnId))
    }
    try {
      const cached = cursor
        ? []
        : await primeTaskCache(workspaceId, itemId, columnId, limit, q, sortBy, direction)
      if (cached.length > 0) replaceItemTasksForColumn(item, columnId, cached)
      const fresh = await revalidateTaskCache(
        workspaceId,
        itemId,
        columnId,
        limit,
        q,
        sortBy,
        direction,
      )
      if (fresh) {
        // A complete page (has_more=false) lists every row in this context —
        // cached rows it omits were deleted or moved out, so they are dropped
        // instead of merged back in.
        const merged = new Map((fresh.has_more ? cached : []).map((task) => [task.id, task]))
        for (const task of fresh.tasks) merged.set(task.id, task)
        replaceItemTasksForColumn(item, columnId, [...merged.values()])
        if (!item.columnPagination) item.columnPagination = {}
        item.columnPagination[columnId] = {
          cursor: fresh.next_cursor,
          hasMore: fresh.has_more,
          isLoading: false,
        }
      } else if (cached.length > 0) {
        if (!item.columnPagination) item.columnPagination = {}
        item.columnPagination[columnId] = {
          cursor: null,
          hasMore: false,
          isLoading: false,
        }
      }

      // Track the active q so SSE handlers + loadMoreTasks can
      // forward it on subsequent refetches.
      if (q && q.length > 0) {
        activeSearchQueries.set(itemId, q)
      } else {
        activeSearchQueries.delete(itemId)
      }

      // Track the active sort so loadMoreTasksForColumn + kanbanSse
      // can forward it on subsequent refetches.
      if (sortBy && direction) {
        activeSortBy.set(itemId, sortBy)
        activeSortDirection.set(itemId, direction)
      } else {
        activeSortBy.delete(itemId)
        activeSortDirection.delete(itemId)
      }

      // Card-first async media: cards already rendered from the
      // flag-only payload above; queue thumbnail loads behind it.
      queueCardMediaLoad(workspaceId, itemId)
    } catch (err) {
      console.error(
        `[workspacesStore.fetchKanbanTasks] API call failed for column ${columnId}:`,
        err,
      )
      // Leave the existing tasks array untouched so the UI doesn't
      // flash to empty on a transient network blip. The next SSE
      // event will trigger another fetch.
    } finally {
      // Clear the first-page flag on BOTH paths — a failed fetch must not park the skeleton forever
      // (the column falls back to its empty state, which is the honest answer when the request
      // failed).
      if (isFirstPage) {
        firstPageLoadingColumns.value.delete(firstPageLoadingKey(itemId, columnId))
      }
    }
  }

  // Fire `fetchKanbanTasks` for every column of a kanban item. Per-column pagination (Option B,
  // 2026-08-06 amendment): every task fetch must carry a `column_id`, including the initial page-1
  // fetch.
  async function fetchKanbanTasksForAllColumns(
    workspaceId: string,
    itemId: string,
    limit = 10,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    let columns = item.kanban_columns ?? []
    if (columns.length === 0) {
      // No columns loaded yet — fetch them first so we have ids.
      // fetchKanbanColumns is idempotent (just an HTTP GET), safe
      // to call even if the columns are already in flight.
      await fetchKanbanColumns(workspaceId, itemId)
      columns = item.kanban_columns ?? []
    }
    if (columns.length === 0) return // still empty → board has no columns
    // Fire one fetch per column in parallel. Each fetch updates
    // its own slice of item.tasks + its own columnPagination entry.
    await Promise.all(
      columns.map((col) =>
        fetchKanbanTasks(
          workspaceId,
          itemId,
          col.id,
          limit,
          undefined, // cursor — reset to page 1 of the filtered set
          q,
          sortBy,
          direction,
        ),
      ),
    )
    // Card-first async media: every column's cards rendered from the
    // flag-only payload; queue thumbnail loads behind them in one batch.
    queueCardMediaLoad(workspaceId, itemId)
  }

  // Add a column to a kanban and append it to the local item's `kanban_columns` array, sorted by
  // position. The backend returns the column with its server-assigned id and position.
  async function addKanbanColumn(
    workspaceId: string,
    itemId: string,
    name: string,
    description: string = '',
  ): Promise<void> {
    const col = await api.addKanbanColumn(workspaceId, itemId, name, description)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = [...(item.kanban_columns ?? []), col].sort(
        (a, b) => a.position - b.position,
      )
    }
  }

  // Patch a kanban column's name, description, and/or position.
  async function updateKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    patch: { name?: string; description?: string; position?: number; is_done?: boolean },
  ): Promise<void> {
    const result = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mirror the backend's full board — replaces the previous `item.kanban_columns[i] = result`
    // bug, which corrupted the single-column slot with the `{columns, count}` envelope and made
    // every UI field on the saved column read as undefined.
    item.kanban_columns = [...result.columns].sort((a, b) => a.position - b.position)
  }

  // Copy the column spec from `sourceItemId` to `targetItemId`. Destructive for the target in
  // 'replace' mode (existing columns are deleted via the backend's `deleteColumn` path which
  // unassigns tasks).
  async function copyKanbanSpecFrom(
    workspaceId: string,
    targetItemId: string,
    sourceItemId: string,
    mode: 'replace' | 'append' = 'replace',
  ): Promise<void> {
    const result = await api.copyKanbanSpec(workspaceId, targetItemId, sourceItemId, mode)
    const item = findItem(workspaceId, targetItemId)
    if (!item) return
    item.kanban_columns = [...result.columns].sort((a, b) => a.position - b.position)
  }

  // Reorder a kanban column via drag-and-drop.
  async function reorderKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    targetColumnId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item?.kanban_columns) return
    const target = item.kanban_columns.find((c) => c.id === targetColumnId)
    if (!target) return
    // PATCH the moved column to the target's position. The backend's reorderColumn shifts the
    // siblings (dense renumber) and returns the moved column's NEW position; we ignore the return
    // value because we'll re-fetch the whole list next.
    await api.updateKanbanColumn(workspaceId, itemId, columnId, {
      position: target.position,
    })
    // Re-fetch so local state matches the backend's renumbered
    // sibling positions.
    await fetchKanbanColumns(workspaceId, itemId)
  }

  // Delete a kanban column. The backend unassigns tasks in the column (sets kanban_column_id to
  // NULL) — we mirror that by clearing `kanban_column_id` on any matching tasks in the local store
  // so the "Unassigned" view is consistent.
  async function deleteKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<void> {
    await api.deleteKanbanColumn(workspaceId, itemId, columnId)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = (item.kanban_columns ?? []).filter((c) => c.id !== columnId)
      // Mirror the backend's NULL-unassign for tasks in the column.
      if (item.tasks) {
        const unassigned: Task[] = []
        for (const t of item.tasks) {
          if (t.kanban_column_id === columnId) {
            t.kanban_column_id = null
            unassigned.push(t)
          }
        }
        for (const t of unassigned) {
          await removeTaskFromCache(workspaceId, itemId, t.id, columnId)
          await cacheTaskMutation(workspaceId, itemId, t)
        }
      }
    }
  }

  // Reposition a task within `item.tasks` so it renders at `position` among its column's cards.
  // `cardsInColumn` (KanbanColumn.vue) just filters by column id — display order IS array order —
  // so a bare column_id flip leaves the card at its old array slot until the next full fetch.
  function placeTaskAtColumnPosition(
    item: WorkspaceItem,
    taskId: string,
    columnId: string,
    position: number,
  ): void {
    if (!item.tasks) return
    const idx = item.tasks.findIndex((t) => t.id === taskId)
    if (idx === -1) return
    const removed = item.tasks.splice(idx, 1)
    const task = removed[0]
    if (!task) return
    const destIndices: number[] = []
    item.tasks.forEach((t, i) => {
      if (t.kanban_column_id === columnId) destIndices.push(i)
    })
    const at = Math.max(0, Math.min(Math.floor(position), destIndices.length))
    const insertIdx = at === destIndices.length ? item.tasks.length : destIndices[at]!
    item.tasks.splice(insertIdx, 0, task)
  }

  // Move a task to a different column and/or position. The backend does the move + sibling
  // re-numbering in a single transaction; we update the local task's `kanban_column_id` +
  // `kanban_position` so the UI snaps to the new position.
  async function moveTaskToColumn(
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId: string,
    position: number,
    force = false,
  ): Promise<void> {
    // Awaits the API BEFORE mutating: a 409 move-gate refusal
    // throws here with local state untouched, so the card stays
    // in its original column (the ApiError body keeps `blockers`).
    await api.moveTask(workspaceId, itemId, taskId, columnId, position, force)
    const item = findItem(workspaceId, itemId)
    if (item && item.tasks) {
      const task = item.tasks.find((t) => t.id === taskId)
      if (task) {
        task.kanban_column_id = columnId
        task.kanban_position = position
        placeTaskAtColumnPosition(item, taskId, columnId, position)
        await cacheTaskMutation(workspaceId, itemId, task, columnId)
      }
    }
    // Local-mutation dedupe (same pattern as design drags): the backend fans the `kanban_task
    // moved` SSE event back to the mover too, and the kanbanSse handler refetches the destination
    // column (tasks?limit=100) on every event.
    registerRecentLocalMutations([taskId], Date.now() + RECENT_MUTATION_TTL_MS)
  }

  // Mirror a kanban task's column (and optional position) into the local store WITHOUT an HTTP
  // round-trip.Contract:
  // - `newColumnId`: the destination column id (`null` for unassign).
  function mirrorKanbanTaskMove(
    workspaceId: string,
    itemId: string,
    taskId: string,
    newColumnId: string | null,
    newPosition?: number,
  ): void {
    const item = findItem(workspaceId, itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return
    task.kanban_column_id = newColumnId
    if (newPosition !== undefined) {
      task.kanban_position = newPosition
    }
    if (newColumnId !== null && newColumnId.length > 0 && newPosition !== undefined) {
      placeTaskAtColumnPosition(item, taskId, newColumnId, newPosition)
    }
    void cacheTaskMutation(workspaceId, itemId, task, newColumnId ?? undefined)
  }

  // Patch a task's `needs_human_review` flag IN PLACE (zero network).
  function applyHumanTouched(
    workspaceId: string,
    itemId: string,
    taskId: string,
    needsHumanReview: boolean,
  ): void {
    const item = findItem(workspaceId, itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return
    task.needs_human_review = needsHumanReview
    void cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
  }

  // ─── Design mode actions (Chunk 6 of design-mode-redesign plan) ────── These 5 actions back the
  // design canvas / layers panel / properties panel UI of the v6 Figma-lite design mode.
  async function fetchDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mark this page's element fetch in flight so DesignView's canvas, LayersPanel and
    // PropertiesPanel can hold a skeleton instead of rendering their empty states — "Click +
    // Element to add your first element" is a false statement while the fetch is outstanding.
    designElementsLoadingKey.value = `${itemId}:${pageId}`
    try {
      const { elements } = await api.getDesignPage(workspaceId, itemId, pageId)
      // Mirror in PLACE (per-id replace + splice + append) rather than `item.design_elements =
      // elements`.
      if (!item.design_elements) {
        item.design_elements = elements
        designLogger.warn({
          reason: 'fetch:replaced-array',
          caller: 'workspacesStore.fetchDesignElements',
          endpoint: '/design/pages/:page_id (GET)',
          workspaceId,
          itemId,
          pageId,
          mirrorCount: elements.length,
          extra: {
            note: 'item.design_elements was undefined — assigned the full array (the OLD bug pattern)',
          },
        })
        return
      }
      designLogger.info({
        reason: 'fetch:in-place-mirror',
        caller: 'workspacesStore.fetchDesignElements',
        endpoint: '/design/pages/:page_id (GET)',
        workspaceId,
        itemId,
        pageId,
        mirrorCount: elements.length,
        extra: { preExistingCount: item.design_elements.length },
      })
      // Build a Map<id, incomingElement> for O(1) lookup.
      const incomingById = new Map<string, (typeof elements)[number]>()
      for (const el of elements) incomingById.set(el.id, el)
      // Walk the local array. For each existing row: - if its id is in the incoming set, replace in
      // place - if its id is NOT in the incoming set, mark for splice We splice from the end so the
      // live indices stay valid.
      const toSplice: number[] = []
      for (let i = 0; i < item.design_elements.length; i++) {
        const existing = item.design_elements[i]!
        const next = incomingById.get(existing.id)
        if (next) {
          item.design_elements[i] = next
          incomingById.delete(existing.id)
        } else {
          toSplice.push(i)
        }
      }
      // Splice deletions from the end (preserves earlier indices).
      for (let i = toSplice.length - 1; i >= 0; i--) {
        item.design_elements.splice(toSplice[i]!, 1)
      }
      // Append any incoming elements that weren't already in the
      // array (newly created elsewhere — LLMs, other tabs).
      for (const remaining of incomingById.values()) {
        item.design_elements.push(remaining)
      }
    } catch (err) {
      console.error('[workspacesStore.fetchDesignElements] API call failed:', err)
      // Leave the existing elements array untouched so the UI
      // doesn't flash to empty on a transient network blip. The
      // next SSE event will trigger another fetch.
    } finally {
      // Cleared on BOTH paths so a failed fetch cannot park the
      // skeleton — the surfaces fall back to their empty states, which
      // is the honest answer when the request failed.
      designElementsLoadingKey.value = null
    }
  }

  // Add an element to a design page and append it to the local item's `design_elements` array. The
  // backend returns the full element with server-assigned id / position / timestamps. We push (not
  // unshift) to match the backend's ordering (oldest first by position).
  async function addDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: {
      name: string
      type: DesignElement['type']
      html: string
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      [k: string]: any
    },
  ): Promise<DesignElement> {
    const newElem = await addDesignElementApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      item.design_elements.push(newElem)
    }
    return newElem
  }

  // Patch an element's fields (full update — backend applies a sparse merge). Replaces the local
  // copy in place so the canvas re-renders the patched element immediately. Used by the
  // PropertiesPanel (form input changes) and the LLM tool-driven update_element handler.
  async function updateDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    patch: Partial<DesignElement>,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementApi(workspaceId, itemId, pageId, elementId, patch)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // HTML body-only update (Monaco Save button). Mirrors the `updateDesignElement` shape: PATCHes
  // the dedicated html endpoint, mirrors the response into the local design_elements array.
  async function updateDesignElementHtml(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    html: string,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementHtmlApi(workspaceId, itemId, pageId, elementId, html)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // Geometry-only update path (drag/resize fires at the 50 ms throttle, i.e. ≤20 Hz).
  async function updateDesignElementGeometry(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    geometry: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<DesignElement> {
    const result = await updateDesignElementGeometryApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      geometry,
    )
    // Mirror the response into the local cache. Defensive no-op when
    // the item isn't in the local store (stale SSE callers).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = result
    }
    registerRecentLocalMutations([elementId], Date.now() + RECENT_MUTATION_TTL_MS)
    return result
  }

  // NEW (2026-08-06, split-move-resize plan) — single-element translate (move). Body carries a (dx,
  // dy) DELTA. If the target is a `group`/`frame`, the server cascades to every transitive
  // descendant via the existing recursive CTE.
  async function translateDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    dx: number,
    dy: number,
  ): Promise<DesignElement[]> {
    designLogger.info({
      reason: 'store:translateDesignElement:api',
      caller: 'workspacesStore.translateDesignElement',
      endpoint: '/translate',
      dx,
      dy,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    const result = await translateDesignElementApi(workspaceId, itemId, pageId, elementId, dx, dy)
    // Build a Map<id, index> for O(1) lookup; cascade can return
    // 10+ elements (group + children + grandchildren).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idxById = new Map<string, number>()
      for (let i = 0; i < item.design_elements.length; i++) {
        idxById.set(item.design_elements[i]!.id, i)
      }
      for (const updated of result.updated) {
        const idx = idxById.get(updated.id)
        if (idx !== undefined) item.design_elements[idx] = updated
      }
    }
    registerRecentLocalMutations(
      result.updated.map((e) => e.id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    designLogger.info({
      reason: 'store:translateDesignElement:mirror',
      caller: 'workspacesStore.translateDesignElement',
      ids: result.updated.map((e) => e.id),
      mirrorCount: result.updated.length,
      endpoint: '/translate',
      dx,
      dy,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    return result.updated
  }

  // NEW (2026-08-06, split-move-resize plan) — single-element resize. Body carries absolute
  // x/y/width/height/rotation fields. Server returns a single DesignElement.
  async function resizeDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    geometry: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<DesignElement> {
    designLogger.info({
      reason: 'store:resizeDesignElement:api',
      caller: 'workspacesStore.resizeDesignElement',
      endpoint: '/resize',
      patch: geometry,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    const result = await resizeDesignElementApi(workspaceId, itemId, pageId, elementId, geometry)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = result
    }
    registerRecentLocalMutations([elementId], Date.now() + RECENT_MUTATION_TTL_MS)
    designLogger.info({
      reason: 'store:resizeDesignElement:mirror',
      caller: 'workspacesStore.resizeDesignElement',
      endpoint: '/resize',
      ids: [elementId],
      mirrorCount: 1,
      workspaceId,
      itemId,
      pageId,
      extra: { x: result.x, y: result.y, w: result.width, h: result.height, r: result.rotation },
    })
    return result
  }

  // Atomic N-element geometry update. Used by the canvas drag handler for multi-element drag so the
  // N per-element PATCHes collapse into ONE PATCH per pointermove.
  async function updateDesignElementsGeometryBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    updates: GeometryBatchUpdate[],
  ): Promise<DesignElement[]> {
    if (updates.length === 0) return []
    const result = await updateDesignElementsGeometryBatchApi(workspaceId, itemId, pageId, updates)
    // Mirror every updated row into the local design_elements array
    // in input order (preserves the array's existing order).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    // Register all affected element ids so the SSE handler skips the
    // GET fan-out. Strict superset semantics in the SSE listener:
    // a missing id falls through to the fetch path (defensive).
    registerRecentLocalMutations(
      updates.map((u) => u.element_id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    return result.updated
  }

  // Update a design page's width/height (UI resize from the canvas header W × H inputs). Backend's
  // PATCH /pages/:page_id validates the ranges (width 320-4096, height 240-4096) and returns 400
  // with an explicit error message otherwise.
  async function updateDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    patch: { width: number; height: number; name?: string },
  ): Promise<DesignPage> {
    return await updateDesignPageApi(workspaceId, itemId, pageId, patch)
  }

  // NEW (2026-08-06 — design page rename menu). Rename a single design page in-place. Mirrors the
  // optimistic-update + rollback pattern from `renameTask`: 1. Trim the new name; refuse empty /
  // unchanged (no-op → return). 2.
  async function renameDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    newName: string,
  ): Promise<void> {
    const cached = designPagesByItemId.value[itemId] ?? []
    const idx = cached.findIndex((p) => p.id === pageId)
    if (idx === -1) return
    const page = cached[idx]
    if (!page) return

    const trimmed = newName.trim()
    if (!trimmed || trimmed === page.name) return

    const previousName = page.name
    // Optimistic update on the cached struct (Pinia's reactive proxy
    // sees this assignment and re-renders the sidebar tree).
    page.name = trimmed

    try {
      await updateDesignPageApi(workspaceId, itemId, pageId, {
        width: page.width,
        height: page.height,
        name: trimmed,
      })
    } catch (err) {
      // Roll back to the previous name on any error. The cache ref
      // is the same — the rollback re-assignment is visible to
      // every active component reading from the store.
      page.name = previousName
      console.error('Failed to rename design page:', err)
      throw err
    }
  }

  // Server-side cascade move. Each item's (dx, dy) applies to the element AND every transitive
  // descendant of that element. Optional width/height/rotation apply ONLY to the root.
  async function moveDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    items: MoveBatchItem[],
  ): Promise<DesignElement[]> {
    if (items.length === 0) return []
    designLogger.info({
      reason: 'store:moveDesignElementsBatch:api',
      caller: 'workspacesStore.moveDesignElementsBatch',
      endpoint: '/move-batch',
      ids: items.map((i) => i.element_id),
      workspaceId,
      itemId,
      pageId,
      extra: {
        itemCount: items.length,
        sample: items[0] ? { id: items[0].element_id, dx: items[0].dx, dy: items[0].dy } : null,
      },
    })
    const result = await moveDesignElementsBatchApi(workspaceId, itemId, pageId, { items })
    // Mirror every updated row into the local design_elements array (preserves the array's existing
    // order for non-affected elements). See `api.normalizeDesignElementType` for the full
    // rationale.
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      // Build a Map<id, index> for O(1) lookup; the cascade can
      // include 10+ elements (group + children + grandchildren) and
      // repeated findIndex inside the loop is O(n²).
      const idxById = new Map<string, number>()
      for (let i = 0; i < item.design_elements.length; i++) {
        idxById.set(item.design_elements[i]!.id, i)
      }
      for (const updated of result.updated) {
        const idx = idxById.get(updated.id)
        if (idx !== undefined) {
          // Normalize `type` from either `type` (canonical) or `elem_type` (legacy). Without this
          // the local mirror clobbers the element's `type` field with `undefined`, which silently
          // disables the cascade path on every drag after the first (BUG 2026-08-06).
          item.design_elements[idx] = normalizeDesignElementType(updated) as DesignElement
        }
      }
    }
    // Register all cascaded ids so the SSE handler skips the GET fan-out. The cascade can include
    // descendants the user didn't explicitly select (e.g. clicking a group with 4 children follows
    // with all 4 ids).
    registerRecentLocalMutations(
      result.updated.map((e) => e.id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    designLogger.info({
      reason: 'store:moveDesignElementsBatch:mirror',
      caller: 'workspacesStore.moveDesignElementsBatch',
      endpoint: '/move-batch',
      ids: result.updated.map((e) => e.id),
      mirrorCount: result.updated.length,
      workspaceId,
      itemId,
      pageId,
      extra: {
        inputItemCount: items.length,
        cascadeExpandedTo: result.updated.length,
        cascade: result.updated.length > items.length,
      },
    })
    return result.updated
  }

  // Delete an element. Idempotent on the backend (returns
  // `{success: true}` whether the row existed or not). Filters
  // the local `design_elements` array to remove the row.
  async function deleteDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<void> {
    await deleteDesignElementApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      item.design_elements = item.design_elements.filter((e) => e.id !== elementId)
    }
  }

  // Wrap 2+ elements into a new `group` (or `frame`) parent at the union bbox. The backend returns
  // the full new parent + the updated children (with `parent_id` set).
  async function reorderDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    mode: ReorderMode,
    elementIds: string[],
  ): Promise<DesignElement[]> {
    const result = await reorderDesignElementsApi(workspaceId, itemId, pageId, {
      mode,
      element_ids: elementIds,
    })
    // Mirror the server's `reordered` rows into the local design_elements array so the layers panel
    // + canvas re-render immediately. We replace matching ids in place (preserves the local array's
    // ordering for any ids NOT in the response).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.reordered) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.reordered
  }

  async function groupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: GroupDesignElementsRequest,
  ): Promise<{ parent: DesignElement; children: DesignElement[] }> {
    const result = await groupDesignElementsApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      // Append the new parent (preserves backend ordering: highest
      // position last).
      item.design_elements.push(result.parent)
      // Replace each child in place. We don't filter the array first because the backend's returned
      // children are already updated versions; the originals are still useful for comparison in
      // tests but the in-place replace keeps the array length stable.
      for (const updated of result.children) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result
  }

  // Atomic N-element reparent (1 OR many). Used by the LayersPanel drag-and-drop affordance. The
  // whole batch is all-or-nothing — the backend rejects with 400 BadReparent if ANY element would
  // close a cycle, and 0 writes happen.
  async function reparentDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: Omit<ReparentDesignElementsBatchRequest, 'reposition'> & {
      reposition?: ReparentDesignElementsBatchRequest['reposition']
    },
  ): Promise<DesignElement[]> {
    const reposition = body.reposition ?? 'last_in_parent'
    const result = await reparentDesignElementsBatchApi(workspaceId, itemId, pageId, {
      element_ids: body.element_ids,
      new_parent_id: body.new_parent_id,
      reposition,
    })
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.updated
  }

  // Dissolve a group/frame: reparent its direct children to the group's parent (or top-level if the
  // group had no parent), then delete the group row.
  async function ungroupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<{ orphaned: DesignElement[] }> {
    const result = await ungroupDesignElementsApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item && item.design_elements) {
      // Replace each orphaned child in place.
      for (const updated of result.orphaned) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
      // Remove the group row itself.
      const group_idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (group_idx !== -1) item.design_elements.splice(group_idx, 1)
    }
    return result
  }

  // Delete a page. Idempotent on the backend (404 = already gone).
  async function deleteDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    await deleteDesignPageApi(workspaceId, itemId, pageId)
    // 1. Drop from cache (sidebar tree re-renders without the row).
    const cached = designPagesByItemId.value[itemId] ?? []
    const idx = cached.findIndex((p) => p.id === pageId)
    const remaining = cached.filter((p) => p.id !== pageId)
    designPagesByItemId.value = {
      ...designPagesByItemId.value,
      [itemId]: remaining,
    }
    // 2. If the deleted page was active, fall back to a sensible next page. The pre-fix convention
    // (VS Code / Figma parity): prefer the page AT THE SAME INDEX in the OLD order (i.e. what used
    // to be next), or the previous one if we deleted the last.
    if (activeDesignPageId.value === pageId) {
      if (remaining.length === 0) {
        activeDesignPageId.value = ''
      } else {
        const nextIdx = idx >= remaining.length ? remaining.length - 1 : idx
        activeDesignPageId.value = remaining[nextIdx]?.id ?? ''
      }
    }
  }

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06). Fetch pages for a design workspace item
  // from the backend and cache them in `designPagesByItemId`. Concurrent calls for the same item
  // share the same in-flight promise (no double-fetch on sidebar-expand + DesignView-mount race).
  async function fetchDesignPages(workspaceId: string, itemId: string): Promise<DesignPage[]> {
    const inFlight = designPagesInFlight.get(itemId)
    if (inFlight) return await inFlight
    const p = (async (): Promise<DesignPage[]> => {
      try {
        const { pages } = await listDesignPagesApi(workspaceId, itemId)
        designPagesByItemId.value = {
          ...designPagesByItemId.value,
          [itemId]: pages,
        }
        return pages
      } finally {
        designPagesInFlight.delete(itemId)
      }
    })()
    designPagesInFlight.set(itemId, p)
    return await p
  }

  // NEW: append a new design page to the cache + mirror it on the server, AND set it as the active
  // page so the user immediately sees the empty canvas they can start populating. Returns the
  // created page (with backend-assigned id, timestamps) on success, or `undefined` on failure.
  async function addDesignPage(
    workspaceId: string,
    itemId: string,
    name: string,
  ): Promise<DesignPage | undefined> {
    const created = await createDesignPageApi(workspaceId, itemId, name)
    const existing = designPagesByItemId.value[itemId] ?? []
    designPagesByItemId.value = {
      ...designPagesByItemId.value,
      [itemId]: [...existing, created],
    }
    activeDesignPageId.value = created.id
    return created
  }

  // Move a single element (and its subtree when apply_to_children=true) from `sourcePageId` to
  // `newPageId`. Backend returns the moved elements; we mirror by: 1.
  async function moveDesignElementToPage(
    workspaceId: string,
    itemId: string,
    sourcePageId: string,
    elementId: string,
    input: {
      new_page_id: string
      apply_to_children?: boolean
    },
  ): Promise<DesignElement[] | undefined> {
    try {
      const { updated } = await api.moveDesignElementToPage(
        workspaceId,
        itemId,
        sourcePageId,
        elementId,
        input,
      )
      const item = findItem(workspaceId, itemId)
      // Mirror: remove moved ids from the source page's elements if
      // they're in local memory (the source page is the active page).
      if (item && item.design_elements && activeDesignPageId.value === sourcePageId) {
        const movedIds = new Set(updated.map((el) => el.id))
        for (let i = item.design_elements.length - 1; i >= 0; i--) {
          if (movedIds.has(item.design_elements[i]!.id)) {
            item.design_elements.splice(i, 1)
          }
        }
      }
      // Q6 default: navigate to the target page. Also triggers the
      // existing watcher to refetch the target page's elements.
      activeDesignPageId.value = input.new_page_id
      // Re-fetch the target page explicitly so the canvas reflects the
      // moved elements immediately (the watcher's debounce may add
      // latency the user notices on click).
      await fetchDesignElements(workspaceId, itemId, input.new_page_id)
      return updated
    } catch (err) {
      console.error('[workspacesStore.moveDesignElementToPage] API call failed:', err)
      return undefined
    }
  }

  // Manually fire a workspace routine. Returns the backend's `{ session_id }` on success, or
  // `undefined` on failure (the caller's responsibility to navigate / show an error). We
  // deliberately do NOT navigate here — that's a UI concern owned by the RoutineView.
  async function runRoutineItem(
    workspaceId: string,
    itemId: string,
    routineId: string,
  ): Promise<{ session_id: string } | undefined> {
    try {
      return await api.runWorkspaceRoutine(workspaceId, itemId, routineId)
    } catch (err) {
      console.error('Failed to run routine:', err)
      return undefined
    }
  }

  // Kanban "Start agent" flow.
  async function startAgentOnTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<{ success: boolean; session_id?: string; status?: string } | undefined> {
    try {
      return await api.startAgentOnTask(workspaceId, itemId, taskId)
    } catch (err) {
      console.error('Failed to start agent on task:', err)
      return undefined
    }
  }

  // Column "Run all agents" flow.
  async function runAllAgentsInColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<api.RunAllAgentsSummary> {
    try {
      return await api.runAllAgentsInColumn(workspaceId, itemId, columnId)
    } catch (err) {
      console.error('Failed to run all agents in column:', err)
      return { success: false, started: [], skipped: [], failed: [] }
    }
  }

  // Column "Stop all agents" flow — the mirror of `runAllAgentsInColumn` above. Thin wrapper around
  // api.stopAllAgentsInColumn (POST .../kanban/columns/:columnId/stop_all_agents) so KanbanView
  // doesn't import the wire shape directly.
  async function stopAllAgentsInColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<api.StopAllAgentsSummary> {
    try {
      return await api.stopAllAgentsInColumn(workspaceId, itemId, columnId)
    } catch (err) {
      console.error('Failed to stop all agents in column:', err)
      return { success: false, stopped: [], skipped: [], failed: [] }
    }
  }

  // Kanban "create task & run agent" flow. Wraps api.sendChatMessage
  // so KanbanView doesn't import the wire shape directly.
  async function runAgentOnNewTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    params: {
      queueMessage: string
      cwd: string
      isAutoRetryUntilStop?: '0' | '1'
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty / undefined = backend default
      // ("Default (top-level config)"). When set, the chatview's picker will reflect the chosen
      // profile immediately on landing.
      selectedAgent?: string
      // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
      // 2026-08-06-kanban-image-attach-in-chatview). Base64 data URLs of images the user pasted in
      // the create-mode description.
      imageUrls?: string[]
      videoUrls?: string[]
    },
  ): Promise<{ status: string } | undefined> {
    try {
      return await api.sendChatMessage(
        taskId,
        params.queueMessage,
        params.cwd,
        params.imageUrls, // was: undefined (bug — see plan)
        params.selectedAgent ?? '', // CHANGED — was ''
        params.isAutoRetryUntilStop ?? '', // forwards '1' when toggle ON, else ''
        params.videoUrls, // Migration 090 — clips ride video_urls
      )
    } catch (err) {
      console.error('Failed to run agent on new task:', err)
      return undefined
    }
  }

  // Kanban-specific task create.
  async function addKanbanTask(
    workspaceId: string,
    itemId: string,
    mode: 'create' | 'create_session' | 'create_and_run',
    params: {
      name: string
      description?: string
      queue_message?: string
      tags?: string[]
      imageUrls?: string[]
      videoUrls?: string[]
      cwd?: string
      isAutoRetryUntilStop?: string
      selected_profile_model?: string
      /** Migration 112 — the skills this task asks the agent to use, in pick order. */
      skillNames?: string[]
    },
  ): Promise<api.KanbanCreateResponse> {
    const wirePayload:
      | api.KanbanCreateTaskPayload
      | api.KanbanCreateSessionOnlyPayload
      | api.KanbanCreateAndRunPayload =
      mode === 'create_and_run'
        ? {
            mode: 'create_and_run',
            name: params.name,
            description: params.description,
            queue_message: params.queue_message ?? '',
            tags: params.tags,
            imageUrls: params.imageUrls,
            videoUrls: params.videoUrls,
            cwd: params.cwd,
            isAutoRetryUntilStop: params.isAutoRetryUntilStop,
            selected_profile_model: params.selected_profile_model,
            skill_names: params.skillNames,
          }
        : mode === 'create_session'
          ? {
              mode: 'create_session',
              name: params.name,
              description: params.description,
              tags: params.tags,
              imageUrls: params.imageUrls,
              videoUrls: params.videoUrls,
              cwd: params.cwd,
              isAutoRetryUntilStop: params.isAutoRetryUntilStop,
              // Persists on the new sessions row (see Task 2's
              // KanbanCreateSessionOnlyPayload comment in api/index.ts).
              selected_profile_model: params.selected_profile_model,
              skill_names: params.skillNames,
            }
          : {
              mode: 'create',
              name: params.name,
              description: params.description,
              tags: params.tags,
              imageUrls: params.imageUrls,
              videoUrls: params.videoUrls,
              cwd: params.cwd,
              isAutoRetryUntilStop: params.isAutoRetryUntilStop,
              skillNames: params.skillNames,
            }

    try {
      const res = await api.createKanbanTask(workspaceId, itemId, wirePayload)
      // Media-flags change — the create response carries only `is_have_image` / `is_have_video`
      // flags (no base64 payload). Normalize in place for tags/dates; the detail dialog lazy-loads
      // media via fetchTaskMedia when a flag is true.
      if (res.task) normalizeTaskTags(res.task)
      return res
    } catch (err) {
      if (mode === 'create_and_run') {
        // Partial-success path: the backend's task INSERT may have succeeded even when the run step
        // failed (the session INSERT might have failed but the task row is still there). Surface
        // the error as a toast so the user can click the card to retry.
        const msg = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError(msg, 'Task created — agent did not start')
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        return { task: null as any, session: null }
      }
      if (mode === 'create_session') {
        // Partial-success path: create_session can fail AFTER the task INSERT succeeded (rare — the
        // sessions INSERT or session_created SSE emit failed).
        const msg = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError(msg, 'Task created — session init failed')
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        return { task: null as any, session: null }
      }
      throw err
    }
  }

  // Workspace routine item (Migration 084, plan 2026-09-10-workspace-items-routines). Mirrors
  // addAgentItem — POST /api/workspaces/:wsId/items/routine and push the new item into the local
  // store. Routine metadata is fetched lazily by RoutineView via api.getRoutineItem on mount.
  async function addRoutineItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, routine } = await api.createRoutineItem(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          name: item.name ?? name,
          item_type: item.item_type ?? 'routine',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      void routine // silence unused-variable lint
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addRoutineItem] API call failed:', err)
      return undefined
    }
  }

  /** Pin or unpin a task and persist the change via `POST /api/.../tasks/:task_id/pin`. Optimistic:
   * the local task's `is_pinned` flag is flipped immediately and the `pinned_position` is bumped to
   * MAX+1 (matching the backend's behavior). */
  async function pinTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    isPinned: boolean,
  ): Promise<{ success: boolean; pinned_position: number } | undefined> {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return undefined
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return undefined
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return undefined

    // Snapshot for rollback.
    const previousIsPinned = task.is_pinned ?? false
    const previousPinnedPosition = task.pinned_position ?? 0

    // Compute the optimistic pinned_position. When pinning, bump to MAX+1 across the item's
    // currently-pinned tasks (excluding the row being pinned — its current value would otherwise be
    // the new MAX). When unpinning, reset to 0 (the value is irrelevant for unpinned rows).
    let optimisticPosition = previousPinnedPosition
    if (isPinned) {
      const maxPinned = item.tasks.reduce<number>((acc, t) => {
        if (t.id === taskId) return acc
        const p = t.pinned_position ?? 0
        return p > acc ? p : acc
      }, -1)
      optimisticPosition = maxPinned + 1
    }

    task.is_pinned = isPinned
    task.pinned_position = optimisticPosition

    try {
      const result = await api.pinTask(workspaceId, itemId, taskId, isPinned)
      // The backend may assign a different pinned_position if a
      // concurrent pin raced with ours. Echo the backend's value.
      if (result.pinned_position !== undefined) {
        task.pinned_position = result.pinned_position
      }
      await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      return { success: true, pinned_position: result.pinned_position }
    } catch (err) {
      console.error('[workspacesStore.pinTask] API call failed, rolling back:', err)
      task.is_pinned = previousIsPinned
      task.pinned_position = previousPinnedPosition
      return undefined
    }
  }

  /** Reorder the pinned subset of a single workspace item and persist the new order via `POST
   * /api/.../tasks/reorder_pinned`. Optimistic: the item's pinned tasks are reordered in the local
   * array immediately so the UI snaps on drop. */
  async function reorderPinnedTasks(workspaceId: string, itemId: string, orderedIds: string[]) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const currentPinned = item.tasks.filter((t) => t.is_pinned)
    if (currentPinned.length === 0) return

    if (orderedIds.length !== currentPinned.length) {
      console.error(
        `[workspacesStore.reorderPinnedTasks] orderedIds length ${orderedIds.length} != current pinned ${currentPinned.length}; refusing reorder`,
      )
      return
    }

    // Snapshot for rollback.
    const previousOrder = item.tasks.slice()

    // Optimistic local reorder: rebuild the tasks array as [ordered pinned rows in the new order,
    // ...unpinned rows]. Unpinned rows keep their existing relative order (the unpinned-region
    // ORDER BY is unchanged by the reorder).
    const pinnedById = new Map(currentPinned.map((t) => [t.id, t]))
    const reorderedPinned: Task[] = []
    for (const id of orderedIds) {
      const t = pinnedById.get(id)
      if (t) reorderedPinned.push(t)
    }
    // Defensive: any pinned rows missed in the payload are
    // appended at the end (should not happen given the length
    // check).
    for (const t of currentPinned) {
      if (!orderedIds.includes(t.id)) reorderedPinned.push(t)
    }
    const unpinned = item.tasks.filter((t) => !t.is_pinned)
    item.tasks = [...reorderedPinned, ...unpinned]

    try {
      await api.reorderPinnedTasks(workspaceId, itemId, orderedIds)
      for (const task of reorderedPinned) {
        await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      }
    } catch (err) {
      console.error('[workspacesStore.reorderPinnedTasks] API call failed, rolling back:', err)
      item.tasks = previousOrder
    }
  }

  // Toggle task completion
  async function toggleTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const task = item.tasks.find((t) => t.id === taskId)
    if (task) {
      task.completed = !task.completed
      // Sync with API
      try {
        await api.updateTask(workspaceId, itemId, taskId, { completed: task.completed })
        await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
      } catch (err) {
        console.error('Failed to update task:', err)
        // Revert on error
        task.completed = !task.completed
      }
    }
  }

  // Delete a task
  async function deleteTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    // Store reference for potential rollback
    const taskIndex = item.tasks.findIndex((t) => t.id === taskId)
    if (taskIndex === -1) return

    const deletedTask = item.tasks[taskIndex]
    item.tasks = item.tasks.filter((t) => t.id !== taskId)

    // Clear active task if it was the deleted one
    if (activeTaskId.value === taskId) {
      activeTaskId.value = null
    }

    // Sync with API
    try {
      await api.deleteTask(workspaceId, itemId, taskId)
      await removeTaskFromCache(
        workspaceId,
        itemId,
        taskId,
        deletedTask?.kanban_column_id ?? undefined,
      )
    } catch (err) {
      console.error('Failed to delete task:', err)
      // Rollback on error
      if (deletedTask) {
        item.tasks.splice(taskIndex, 0, deletedTask)
        await cacheTaskMutation(
          workspaceId,
          itemId,
          deletedTask,
          deletedTask.kanban_column_id ?? undefined,
        )
      }
    }
  }

  // Load the next page of tasks for ONE column of a kanban item (per-column pagination, plan
  // 2026-08-06-kanban-per-column- pagination.md).
  async function loadMoreTasksForColumn(workspaceId: string, itemId: string, columnId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return
    const colState = item.columnPagination?.[columnId]
    if (!colState) return
    if (colState.isLoading) return
    if (!colState.hasMore) return
    if (!colState.cursor) return

    colState.isLoading = true
    try {
      // Kanban task search (Chunk 4): forward the active q so "Load more" fetches the next page of
      // MATCHES, not the next page of everything. Read from activeSearchQueries (set by
      // fetchKanbanTasks(q)).
      const activeQ = activeSearchQueries.get(itemId)
      // Kanban sort-by (Chunk 3): forward the active sort. The cursor is tied to the sort order —
      // using a different sort here would fetch a meaningless slice. Read from activeSortBy +
      // activeSortDirection (set by the most recent fetchKanbanTasks with both args defined).
      const activeSort = activeSortBy.get(itemId)
      const activeDirection = activeSortDirection.get(itemId)
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        10, // PAGE_SIZE — keep in sync with the default in api/index.ts
        colState.cursor,
        activeSort,
        activeDirection,
        columnId, // per-column filter (the new arg)
        activeQ,
      )
      // Append the new page to the existing list. We push (not unshift) because tasks are ordered
      // newest-first, so older tasks go at the end of the list. Migration 067 — normalize tags from
      // wire string to in-memory string[] at every fetch site.
      if (!item.tasks) item.tasks = []
      const seenIds = new Set(item.tasks.map((t) => t.id))
      for (const t of tasks.map(normalizeTaskTags)) {
        if (seenIds.has(t.id)) continue
        seenIds.add(t.id)
        item.tasks.push(t)
      }
      await runSyncVoid(
        taskEngineDb.putLocal(
          taskRequest(workspaceId, itemId, columnId, activeQ, activeSort, activeDirection),
          tasks.map((task) => ({
            id: task.id,
            sortKey: (task as unknown as { updated_at?: unknown }).updated_at as string,
            raw: task,
          })),
        ),
        'tasks.putLocal',
      )
      // Update this column's pagination state with the new cursor +
      // hasMore. The backend tells us if THIS column has more pages.
      colState.cursor = next_cursor
      colState.hasMore = has_more
      // Card-first async media: appended cards rendered from the
      // flag-only payload; queue their thumbnail loads behind them.
      queueCardMediaLoad(workspaceId, itemId)
    } catch (err) {
      console.error(`Failed to load more tasks for item ${itemId} column ${columnId}:`, err)
      // Leave hasMore/cursor as-is so the user can retry by
      // clicking the button again. Do not surface a toast — keep the
      // failure mode quiet (same pattern as addTask's catch block).
    } finally {
      colState.isLoading = false
    }
  }

  // Set active task - also ensures parent workspace is expanded
  function setActiveTask(taskId: string | null) {
    // FIX (2026-07-14): clear the navigation store's active chat so a subsequent SSE
    // session_created event (fired on every send) cannot navigate back into the previous chat when
    // the user is typing into a task. Mirrors navigationStore.setActiveTask (navigation.ts:123).
    if (taskId !== null) {
      useNavigationStore().clearActiveChat()
    }

    activeTaskId.value = taskId
    if (taskId) {
      // Find parent workspace and item, then expand workspace
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === taskId)) {
            // Found the parent - set active item
            activeWorkspaceItemId.value = item.id
            // Expand workspace and persist if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            // Chunk 7 of kanban-task-notification-icon: opening the chat counts as a human touch —
            // stamp `last_human_touched_at` so the kanban card's orange "AI finished — awaiting
            // review" dot flips to the green "reviewed" checkmark.
            void api.markTaskHumanTouched(workspace.id, item.id, taskId).catch((err: unknown) => {
              console.warn(
                '[workspacesStore.setActiveTask] markTaskHumanTouched failed (non-fatal):',
                err,
              )
            })
            return
          }
        }
      }
    }
  }

  async function removeWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    // Store for potential rollback
    const itemIndex = workspace.items.findIndex((i) => i.id === itemId)
    if (itemIndex === -1) return

    const removedItem = workspace.items[itemIndex]
    workspace.items = workspace.items.filter((item) => item.id !== itemId)

    if (activeWorkspaceItemId.value === itemId) {
      activeWorkspaceItemId.value = null
    }

    // Remove from expandedItemIds if present
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
      expandedItemIds.value = { ...expandedItemIds.value }
      saveExpandedItemIds(expandedItemIds.value)
    }

    // Sync with API
    try {
      await api.deleteWorkspaceItem(workspaceId, itemId)
    } catch (err) {
      console.error('Failed to delete workspace item:', err)
      // Rollback on error
      if (removedItem) {
        workspace.items.splice(itemIndex, 0, removedItem)
      }
    }
  }

  // Rename a workspace
  async function renameWorkspace(workspaceId: string, newName: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const trimmed = newName.trim()
    if (!trimmed || trimmed === workspace.name) return

    const previousName = workspace.name
    // Optimistic update
    workspace.name = trimmed

    // Sync with API
    try {
      await api.updateWorkspace(workspaceId, { name: trimmed })
    } catch (err) {
      console.error('Failed to rename workspace:', err)
      // Rollback on error
      workspace.name = previousName
    }
  }

  // Rename a task. Cascades to the linked session via the backend (`updateTaskName` in
  // llm_history.zig, then onEventSendSessions SSE broadcast) so the ChatsList picks up the new
  // name. Mirrors the optimistic-update + rollback pattern from `renameWorkspace`.
  async function renameTask(workspaceId: string, itemId: string, taskId: string, newName: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    const trimmed = newName.trim()
    if (!trimmed || trimmed === task.name) return

    const previousName = task.name
    // Optimistic update
    task.name = trimmed

    // Keep the chat-view / chat-list header in sync if this is the
    // active task.
    const wasActive = activeTaskId.value === taskId
    if (wasActive) {
      useNavigationStore().setActiveChatName(trimmed)
    }

    // Sync with API. The backend PUT /api/workspaces/tasks/:task_id
    // cascades the rename to the linked session row and broadcasts
    // a session.updated SSE event (see backend tasks_update.zig).
    try {
      await api.updateTaskSimple(taskId, { name: trimmed })
      await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
    } catch (err) {
      console.error('Failed to rename task:', err)
      // Rollback on error
      task.name = previousName
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
    }
  }

  // Update a task's name AND/OR description in a single round-trip (kanban-task-detail-dialog plan,
  // Chunk 2). Mirrors the optimistic-update + rollback pattern from `renameTask`. The patch object
  // only includes fields the caller actually sent — missing fields are left unchanged server-side.
  async function updateTaskDetails(
    workspaceId: string,
    itemId: string,
    taskId: string,
    fields: {
      name?: string
      description?: string
      tags?: string[]
      // NEW (kanban task dependencies). Replace-all edit: `[]` clears all; undefined = leave untouched.
      depends_on?: string[]
      // NEW (Migration 069 — kanban image urls column). Empty array = clear all images; undefined =
      // leave unchanged.
      imageUrls?: string[]
      // NEW (Migration 090 — kanban video urls column). Same
      // contract as imageUrls.
      videoUrls?: string[]
    },
  ) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    // Build the patch — only include fields the caller actually sent.
    // A no-op patch (all undefined) is rejected early so we don't
    // burn an API call.
    const patch: {
      name?: string
      description?: string
      tags?: string[]
      depends_on?: string[]
      imageUrls?: string[]
      videoUrls?: string[]
    } = {}
    if (fields.name !== undefined) {
      const trimmed = fields.name.trim()
      if (!trimmed) return // empty name is never a valid update
      patch.name = trimmed
    }
    if (fields.description !== undefined) {
      patch.description = fields.description
    }
    // Migration 067 — kanban task tags. Empty array = clear all tags; undefined = leave unchanged.
    // The api.updateTaskSimple helper detects `tags !== undefined` and JSON-encodes the array for
    // the wire; the backend validates + persists.
    if (fields.tags !== undefined) {
      patch.tags = fields.tags
    }
    // Dependencies: replace-all; `[]` clears, undefined skips.
    if (fields.depends_on !== undefined) {
      patch.depends_on = fields.depends_on
    }
    // Migration 069 — kanban image urls. Empty array = clear all
    // images; undefined = leave unchanged. The api.updateTaskSimple
    // helper `||`-joins the array for the wire.
    if (fields.imageUrls !== undefined) {
      patch.imageUrls = fields.imageUrls
    }
    // Migration 090 — kanban video urls. Same contract as imageUrls.
    if (fields.videoUrls !== undefined) {
      patch.videoUrls = fields.videoUrls
    }
    if (Object.keys(patch).length === 0) return

    // Optimistic update — capture previous values for rollback.
    const previousName = task.name
    const previousDescription = task.description
    const previousTags = task.tags
    const previousDependsOn = task.depends_on
    const previousImageUrls = task.imageUrls
    const previousVideoUrls = task.videoUrls
    if (patch.name !== undefined) task.name = patch.name
    if (patch.description !== undefined) task.description = patch.description
    if (patch.tags !== undefined) task.tags = patch.tags
    if (patch.depends_on !== undefined) task.depends_on = patch.depends_on
    if (patch.imageUrls !== undefined) {
      task.imageUrls = patch.imageUrls
      task.is_have_image = patch.imageUrls.length > 0
    }
    if (patch.videoUrls !== undefined) {
      task.videoUrls = patch.videoUrls
      task.is_have_video = patch.videoUrls.length > 0
    }

    // Keep the chat-view / chat-list header in sync if this is the
    // active task and a name change is part of the patch.
    const wasActive = activeTaskId.value === taskId
    if (wasActive && patch.name !== undefined) {
      useNavigationStore().setActiveChatName(patch.name)
    }

    try {
      await api.updateTaskSimple(taskId, patch)
    } catch (err) {
      console.error('Failed to update task details:', err)
      // Rollback on error
      task.name = previousName
      task.description = previousDescription
      task.tags = previousTags
      task.depends_on = previousDependsOn
      task.imageUrls = previousImageUrls
      task.videoUrls = previousVideoUrls
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
      // Rethrow so the dialog can show a retry option. Mirrors the
      // renameTask contract — the dialog (Chunk 3) catches this in
      // its own Save handler.
      throw err
    }
    await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
  }

  // Refetch ONE task from the server and patch the in-store copy in place.
  async function refreshTask(workspaceId: string, itemId: string, taskId: string): Promise<void> {
    try {
      const fetched = await api.getTask(workspaceId, itemId, taskId)
      if (!fetched) return
      // Migration 067 — normalize tags from wire string to in-memory
      // string[] (also folds in image_urls splitting) before splicing
      // into the store.
      const freshTask = normalizeTaskTags(fetched)
      for (const ws of workspaces.value) {
        if (ws.id !== workspaceId) continue
        for (const item of ws.items) {
          if (item.id !== itemId) continue
          if (!item.tasks) continue
          const idx = item.tasks.findIndex((t) => t.id === taskId)
          if (idx === -1) continue
          // Replace the cached task object entirely. The Task interface is loose enough (mostly
          // optional fields) that this preserves all caller state. The dialog re-derives its local
          // form state from the new task via its watcher.
          item.tasks.splice(idx, 1, freshTask)
          await cacheTaskMutation(
            workspaceId,
            itemId,
            freshTask,
            freshTask.kanban_column_id ?? undefined,
          )
          return
        }
      }
    } catch (err) {
      console.warn('Failed to refresh task before dialog open:', err)
    }
  }

  // In-flight media requests, keyed by task id. Concurrent callers
  // (dialog re-open, batch prefetch racing a dialog open) share one
  // promise instead of firing duplicate GETs for the same task.
  const mediaInflight = new Map<string, Promise<void>>()

  function findCachedTask(workspaceId: string, itemId: string, taskId: string): Task | undefined {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return undefined
    return item.tasks.find((t) => t.id === taskId)
  }

  function taskNeedsMedia(task: Task): boolean {
    const wantImage =
      task.is_have_image === true && (!task.imageUrls || task.imageUrls.length === 0)
    const wantVideo =
      task.is_have_video === true && (!task.videoUrls || task.videoUrls.length === 0)
    return wantImage || wantVideo
  }

  // Card-first async media. The flag-only list payload lets cards render immediately (badge state);
  // this queues the thumbnail fetch behind it via GET .../tasks/:id/media.
  function queueCardMediaLoad(workspaceId: string, itemId: string): void {
    const item = findItem(workspaceId, itemId)
    if (!item?.tasks || item.tasks.length === 0) return
    const ids = item.tasks.filter(taskNeedsMedia).map((t) => t.id)
    if (ids.length === 0) return
    let painted = false
    for (const id of ids) {
      const task = findCachedTask(workspaceId, itemId, id)
      if (task) painted = applyCachedMedia(task) || painted
    }
    void fetchTasksMedia(workspaceId, itemId, ids, painted ? { revalidate: true } : undefined)
  }

  // Paints a task's last-known thumbnail from the local media cache.
  // Returns true when anything was painted — the caller then revalidates
  // that task in the background instead of treating it as loaded.
  function applyCachedMedia(task: Task): boolean {
    if (!taskNeedsMedia(task)) return false
    const hit = readTaskMediaCache(task.id)
    if (!hit) return false
    let painted = false
    if (
      task.is_have_image === true &&
      (!task.imageUrls || task.imageUrls.length === 0) &&
      hit.imageUrls.length > 0
    ) {
      task.imageUrls = hit.imageUrls
      painted = true
    }
    if (
      task.is_have_video === true &&
      (!task.videoUrls || task.videoUrls.length === 0) &&
      hit.videoUrls.length > 0
    ) {
      task.videoUrls = hit.videoUrls
      painted = true
    }
    return painted
  }

  // Lazy media fetch (media-flags change). When list/get report `is_have_image` / `is_have_video`,
  // the detail dialog calls this once to populate the cached task's imageUrls/videoUrls in place
  // (shared with the board card thumbnail).
  async function fetchTaskMedia(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<void> {
    const task = findCachedTask(workspaceId, itemId, taskId)
    if (!task) return
    const painted = applyCachedMedia(task)
    if (!taskNeedsMedia(task) && !painted) return
    const inflight = mediaInflight.get(taskId)
    if (inflight) {
      await inflight
      return
    }
    const run = (async (): Promise<void> => {
      try {
        const current = findCachedTask(workspaceId, itemId, taskId)
        if (!current || (!taskNeedsMedia(current) && !painted)) return
        const media = await api.getTaskMedia(workspaceId, itemId, taskId)
        if (!media) return
        writeTaskMediaCache(taskId, media)
        const fresh = findCachedTask(workspaceId, itemId, taskId)
        if (!fresh) return
        if (
          fresh.is_have_image === true &&
          (!fresh.imageUrls || fresh.imageUrls.length === 0 || painted)
        )
          fresh.imageUrls = media.imageUrls
        if (
          fresh.is_have_video === true &&
          (!fresh.videoUrls || fresh.videoUrls.length === 0 || painted)
        )
          fresh.videoUrls = media.videoUrls
        await cacheTaskMutation(workspaceId, itemId, fresh, fresh.kanban_column_id ?? undefined)
      } catch (err) {
        console.warn('Failed to fetch task media:', err)
      } finally {
        mediaInflight.delete(taskId)
      }
    })()
    mediaInflight.set(taskId, run)
    await run
  }

  // Parallel batch prefetch (media-flags change). Fetches media for every flagged-but-unloaded task
  // concurrently via one `api.getTasksMedia` round (≈ one round-trip, not N sequential).
  async function fetchTasksMedia(
    workspaceId: string,
    itemId: string,
    taskIds: string[],
    opts?: { revalidate?: boolean },
  ): Promise<void> {
    const revalidate = opts?.revalidate === true
    const pending = taskIds.filter((id) => {
      const task = findCachedTask(workspaceId, itemId, id)
      return task !== undefined && (taskNeedsMedia(task) || revalidate) && !mediaInflight.has(id)
    })
    const alreadyRunning = taskIds
      .map((id) => mediaInflight.get(id))
      .filter((p): p is Promise<void> => p !== undefined)
    if (pending.length === 0) {
      await Promise.allSettled(alreadyRunning)
      return
    }
    // Note: the `finally` below deletes map entries unconditionally. Safe: a new request for the
    // same id can only start when the map holds no entry, and entries are removed only here — no
    // caller can replace an in-flight entry mid-run (single-threaded).
    const run = (async (): Promise<void> => {
      try {
        const results = await api.getTasksMedia(workspaceId, itemId, pending)
        for (const [id, media] of results) {
          if (!media) continue
          writeTaskMediaCache(id, media)
          const task = findCachedTask(workspaceId, itemId, id)
          if (!task) continue
          if (
            task.is_have_image === true &&
            (!task.imageUrls || task.imageUrls.length === 0 || revalidate)
          )
            task.imageUrls = media.imageUrls
          if (
            task.is_have_video === true &&
            (!task.videoUrls || task.videoUrls.length === 0 || revalidate)
          )
            task.videoUrls = media.videoUrls
          await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
        }
      } catch (err) {
        console.warn('Failed to fetch tasks media:', err)
      } finally {
        for (const id of pending) mediaInflight.delete(id)
      }
    })()
    for (const id of pending) mediaInflight.set(id, run)
    await run
    await Promise.allSettled(alreadyRunning)
  }

  async function removeWorkspace(workspaceId: string) {
    const workspaceIndex = workspaces.value.findIndex((ws) => ws.id === workspaceId)
    if (workspaceIndex === -1) return

    const removedWorkspace = workspaces.value[workspaceIndex]
    workspaces.value = workspaces.value.filter((ws) => ws.id !== workspaceId)

    // Clear active if affected
    if (removedWorkspace) {
      removedWorkspace.items.forEach((item) => {
        if (activeWorkspaceItemId.value === item.id) {
          activeWorkspaceItemId.value = null
        }
      })
    }
    // Deleting the selected workspace falls back down the
    // activeWorkspace precedence chain; drop the stale persisted id
    // so the next load doesn't resurrect it.
    if (activeWorkspaceId.value === workspaceId) {
      activeWorkspaceId.value = null
      writeActiveWorkspaceKey(null)
    }

    // Sync with API
    try {
      await api.deleteWorkspace(workspaceId)
      // The row is gone — drop its lazy-load mark. Only on success:
      // the rollback below restores the in-memory items, which are
      // still a valid loaded state.
      workspaceItemsLoaded.delete(workspaceId)
    } catch (err) {
      console.error('Failed to delete workspace:', err)
      // Rollback on error
      if (removedWorkspace) {
        workspaces.value.splice(workspaceIndex, 0, removedWorkspace)
      }
    }
  }

  /** Reorder the workspaces array to match `orderedIds` and persist the new order via `POST
   * /api/workspaces/reorder`. Optimistic: the local array is reordered immediately so the UI snaps
   * to the new position on drop. */
  async function reorderWorkspaces(orderedIds: string[]) {
    const current = workspaces.value
    if (orderedIds.length === 0) return

    // Defensive: the client must send a complete ordering. A partial
    // list (e.g. drag-reordering 2 of 5 workspaces) would lose the
    // other 3. Refuse early.
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaces] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // sidebar size.
    const currentIdSet = new Set(current.map((w) => w.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((w, i) => w.id === orderedIds[i])) {
      return
    }

    // Snapshot for rollback. Vue's ref returns the inner array;
    // copying the slice gives us a moment-in-time view.
    const previousOrder = current.slice()

    // Optimistic local reorder: build a new array by looking up each id in the current array. If an
    // id is missing (defensive — the length-mismatch check above should have caught this), fall
    // back to keeping the original row at its original position.
    const byId = new Map(current.map((w) => [w.id, w]))
    const reordered: Workspace[] = []
    for (const id of orderedIds) {
      const ws = byId.get(id)
      if (ws) reordered.push(ws)
    }
    // If any current rows were missed, append them at the end (should
    // not happen given the length check, but defensive).
    for (const ws of current) {
      if (!orderedIds.includes(ws.id)) reordered.push(ws)
    }
    workspaces.value = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaces(orderedIds)
    } catch (err) {
      console.error('[workspacesStore.reorderWorkspaces] API call failed, rolling back:', err)
      workspaces.value = previousOrder
    }
  }

  /** Reorder the items of one workspace to match `orderedIds` and persist the new order via `POST
   * /api/workspaces/:workspace_id/items/reorder`. Mirrors `reorderWorkspaces` but scoped to a
   * single workspace's items. */
  async function reorderWorkspaceItems(workspaceId: string, orderedIds: string[]) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) {
      console.error(`[workspacesStore.reorderWorkspaceItems] workspace ${workspaceId} not found`)
      return
    }
    const current = workspace.items
    if (orderedIds.length === 0) return
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaceItems] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // items-per-workspace count.
    const currentIdSet = new Set(current.map((i) => i.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((i, idx) => i.id === orderedIds[idx])) {
      return
    }

    // Snapshot for rollback.
    const previousOrder = current.slice()

    // Optimistic local reorder. The workspace is a ref inside the workspaces array; mutating
    // `workspace.items` in place preserves Vue reactivity (the workspace's items array is what the
    // sidebar's v-for is bound to).
    const byId = new Map(current.map((i) => [i.id, i]))
    const reordered: WorkspaceItem[] = []
    for (const id of orderedIds) {
      const item = byId.get(id)
      if (item) reordered.push(item)
    }
    // If any current rows were missed, append them at the end
    // (should not happen given the length check, but defensive).
    for (const item of current) {
      if (!orderedIds.includes(item.id)) reordered.push(item)
    }
    workspace.items = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaceItems(workspaceId, orderedIds)
    } catch (err) {
      console.error('[workspacesStore.reorderWorkspaceItems] API call failed, rolling back:', err)
      workspace.items = previousOrder
    }
  }

  // Update workspace item path from system folder
  function updateWorkspaceItemPath(workspaceId: string, itemId: string, newPath: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      const item = workspace.items.find((i) => i.id === itemId)
      if (item) {
        item.path = newPath
      }
    }
  }

  // ─── Session events via sseBus ───────────────────────────────────────────── The backend cascade
  // for task rename (updateTaskName → updateSessionName → onEventSendSessions → SSE
  // session.updated) emits a `session.updated` event on `/api/sessions/stream`.
  let sessionHandlersInstalled = false

  /** Subscribe to session events. The callback fires once per session event (after the internal
   * workspacesStore handler runs). Returns an unsubscribe function. */
  function onSessionEvent(cb: (event: api.SessionEvent) => void): () => void {
    const bus = useSseBus()
    return bus.on('session', (event) => {
      try {
        cb(event)
      } catch (e) {
        // Swallow subscriber errors so a buggy callback can't take down sibling subscribers (the
        // bus's own dispatch already wraps the listener call in try/catch — this is defense in
        // depth: it also covers the case where a future bus implementation drops that wrapping).
        console.error('[workspacesStore] session event subscriber threw:', e)
      }
    })
  }

  function installSessionEventHandlers() {
    if (sessionHandlersInstalled) {
      // Already installed — don't double-register on HMR.
      return
    }
    sessionHandlersInstalled = true

    const bus = useSseBus()
    bus.on('session', (event) => {
      if (event.action === 'updated') {
        // Find the task (task.id == session_id) and update its name + unattended flag. We also keep
        // navigationStore.activeChatName in sync if the renamed task is active — this is the same
        // pattern as renameTask (workspaces.ts:renameTask).
        for (const ws of workspaces.value) {
          for (const item of ws.items) {
            if (!item.tasks) continue
            const task = item.tasks.find((t) => t.id === event.id)
            if (task) {
              task.name = event.name || task.name
              if (event.is_auto_retry_until_stop !== undefined) {
                task.is_auto_retry_until_stop = event.is_auto_retry_until_stop
              }
              if (activeTaskId.value === task.id) {
                useNavigationStore().setActiveChatName(task.name)
              }
              void cacheTaskMutation(ws.id, item.id, task, task.kanban_column_id ?? undefined)
              return
            }
          }
        }
      } else if (event.action === 'deleted') {
        // Find and remove the task. If it was active, clear the
        // active state so the chat view doesn't render a stale
        // task id.
        for (const ws of workspaces.value) {
          for (const item of ws.items) {
            if (!item.tasks) continue
            const idx = item.tasks.findIndex((t) => t.id === event.id)
            if (idx !== -1) {
              const doomed = item.tasks[idx]
              item.tasks.splice(idx, 1)
              if (activeTaskId.value === event.id) {
                activeTaskId.value = null
              }
              if (doomed) {
                void removeTaskFromCache(
                  ws.id,
                  item.id,
                  event.id,
                  doomed.kanban_column_id ?? undefined,
                )
              }
              return
            }
          }
        }
      }
      // 'created' events are deliberately ignored here: tasks are only ever created via POST
      // /workspaces/:w/items/:i/tasks (which the addTask action handles directly). A 'created' SSE
      // event for an unbound session is a no-op for the workspace tree.
    })
  }

  // Initialize workspace items from system folder. A deep link can pass
  // its workspace id so boot hydration does not prefer the persisted
  // selection and leave the URL-restored item inactive.
  async function initializeFromSystemFolder(preferredWorkspaceId?: string) {
    // First, load workspaces from API
    await init()
    if (preferredWorkspaceId) {
      await setActiveWorkspace(preferredWorkspaceId)
    }

    // Also fetch system folder info for navigation
    await fetchSystemFolder()

    // Restore active task if it was set before workspaces were loaded
    // This handles the case where setActiveTask was called before init() completed
    if (activeTaskId.value) {
      // Find and set the parent workspace item for the active task
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === activeTaskId.value)) {
            // Found the parent - ensure it's set correctly
            activeWorkspaceItemId.value = item.id
            // Expand workspace if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            return
          }
        }
      }
    }
  }

  return {
    // State
    workspaces,
    activeWorkspaceItemId,
    expandedItemIds,
    activeTaskId,
    // FIX (task-url-overwrite, task_1785959660154, 2026-08-06): Navigation flag the AppLayout URL
    // sync watcher checks before mirroring activeWorkspaceItemId / activeDesignPageId to the URL.
    // Set true at the start of Sidebar.handleSelectTask and cleared after the router.push resolves.
    isNavigatingToTask,
    // Kanban sort-by round-trip preservation (plan 2026-08-06): snapshots the active `?sorts=` when
    // the user enters a task view, read back by AppLayout.handleCloseTaskView to restore the sort
    // URL on close.
    savedSortsParam,
    // NEW (Chunk 1 of design-element-drag-and-drop plan): the currently
    // active design page id, mirrored from DesignView so AppLayout's
    // design handlers can route PATCH/PUT/DELETE to the right page.
    activeDesignPageId,
    // Kanban task search (Chunk 4): exposed so SSE handlers can read
    // the active q and forward it on refetch.
    activeSearchQueries,
    // Kanban sort-by (Chunk 3): exposed so SSE handlers can read the active sort and forward it on
    // refetch. The cursor is tied to the sort order — using a different sort on a refetch would
    // fetch a meaningless page.
    activeSortBy,
    activeSortDirection,
    // Per-column first-page loading signal (see the declaration above
    // for why it is not `columnPagination[colId].isLoading`).
    firstPageLoadingColumns,
    isFirstPageLoading,
    // Design-element fetch signal (see the declaration above).
    designElementsLoadingKey,
    isDesignElementsLoading,
    systemFolderInfo,
    systemFolderLoading,
    systemFolderError,
    isLoading,
    loadingError,
    // Computed
    allWorkspaceItems,
    activeWorkspaceItem,
    activeWorkspace,
    activeTask,
    activeTaskWorkspaceItemId,
    // Actions
    init,
    // Lazy per-workspace items (plan: 2026-09-22-revamp-ui-chats): loads one workspace's
    // items/tasks/design pages on demand; runInit uses it for the active workspace,
    // setActiveWorkspace for every switch. Idempotent + in-flight deduped.
    ensureWorkspaceItemsLoaded,
    toggleWorkspaceItem,
    toggleExpandedItem,
    setActiveWorkspaceItem,
    setActiveTask,
    // NEW (Chunk 1 of design-element-drag-and-drop plan): mirror the
    // active design page id from DesignView. Called on mount + tab
    // switch, and cleared on unmount.
    setActiveDesignPage,
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the design-pages cache + the actions
    // that mutate it. Both WorkspaceItem.vue (sidebar tree) and DesignView.vue consume
    // `designPagesByItemId.value[itemId]` directly.
    designPagesByItemId,
    fetchDesignPages,
    addDesignPage,
    resetDesignPagesCache,
    addWorkspace,
    activeWorkspaceId,
    setActiveWorkspace,
    addWorkspaceItem,
    removeWorkspaceItem,
    removeWorkspace,
    renameWorkspace,
    reorderWorkspaces,
    reorderWorkspaceItems,
    updateWorkspaceItemPath,
    addTask,
    ensureDefaultProject,
    toggleTask,
    deleteTask,
    // Per-column pagination (kanban-per-column-pagination plan, 2026-08-06). Replaces the old
    // board-wide `loadMoreTasks`. Each kanban column paginates independently — the column's
    // auto-load sentinel + manual "Load more" button call this action with the column's id.
    loadMoreTasksForColumn,
    renameTask,
    // NEW (kanban-task-detail-dialog plan, Chunk 2). Edit a task's name and/or description in one
    // API call from the detail dialog. Uses the same PUT /api/workspaces/tasks/:task_id endpoint as
    // renameTask — only the body shape is wider.
    updateTaskDetails,
    // NEW (auto-retry-until-stop fix): re-fetch a single task from the server (with the JOINed
    // is_auto_retry_until_stop column) and patch the in-store copy.
    refreshTask,
    fetchTaskMedia,
    fetchTasksMedia,
    runRoutineItem,
    runAgentOnNewTask,
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Triggers a worker on an existing
    // task's session without queueing a new user message. Sibling of runAgentOnNewTask
    // (create-time) and runRoutineItem (workspace-routine manual fire).
    startAgentOnTask,
    // NEW (plan: 2026-09-09-run-all-agents-by-column, Task 4, Option C).
    // Bulk run for one column — server owns the task list.
    runAllAgentsInColumn,
    // Bulk stop for one column — the mirror of runAllAgentsInColumn.
    stopAllAgentsInColumn,
    addKanbanTask,
    pinTask,
    reorderPinnedTasks,
    addKanbanItem,
    // NEW (design-mode feature): creates a design-mode workspace item.
    addDesignItem,
    // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
    // creates an agent-mode workspace item. POSTs to
    // /api/workspaces/:wsId/items/agent and pushes the new item.
    addAgentItem,
    // Workspace routines (Migration 084, plan 2026-09-10-workspace-items-routines): creates a
    // routine-mode workspace item. POSTs to /api/workspaces/:wsId/items/routine and pushes the new
    // item.
    addRoutineItem,
    addKanbanColumn,
    updateKanbanColumn,
    copyKanbanSpecFrom,
    deleteKanbanColumn,
    reorderKanbanColumn,
    moveTaskToColumn,
    // NEW (sse-kanban-move-duplicate-task plan, 2026-08-06): SSE handler calls this BEFORE
    // triggering the refetch on a kanban_task move/assign/unassign event so the local task's
    // `kanban_column_id` matches the wire state.
    mirrorKanbanTaskMove,
    // Read helper for the kanbanSse single-row fast path: a moved/assigned task that is already
    // cached needs only a refreshTask (1 row), while an uncached one still needs the full column
    // fetch to materialize the missing row.
    findCachedTask,
    // NEW (chatview-open api-spam fix, 2026-08-24): in-place needs_human_review patch for
    // `human_touched` SSE events — replaces the 7× tasks?limit=100 refetch that fired every time
    // the user opened a task's chatview.
    applyHumanTouched,
    updateKanbanItemPath,
    updateKanbanItemName,
    fetchKanbanColumns,
    fetchKanbanTasks,
    // Per-column initial fetch helper (Option B). Iterates
    // kanban_columns and fires one fetch each, all with column_id
    // set. Replaces the previous "one board-wide fetch" pattern.
    fetchKanbanTasksForAllColumns,
    // Design mode actions (Chunk 6 of design-mode-redesign plan)
    fetchDesignElements,
    addDesignElement,
    updateDesignElement,
    updateDesignElementGeometry,
    translateDesignElement,
    resizeDesignElement,
    updateDesignElementsGeometryBatch,
    moveDesignElementsBatch,
    moveDesignElementToPage,
    updateDesignElementHtml,
    deleteDesignElement,
    deleteDesignPage,
    updateDesignPage,
    renameDesignPage,
    groupDesignElements,
    ungroupDesignElements,
    reparentDesignElementsBatch,
    reorderDesignElements,
    initializeFromSystemFolder,
    onSessionEvent,
    fetchSystemFolder,
    fetchFolderContents,
  }
})
