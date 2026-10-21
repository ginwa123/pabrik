// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls
import { createSseClient, type SseClient } from '../helpers/sseClient'
import { readGitStatusCache, writeGitStatusCache } from '../helpers/gitStatusCache'
import { Cause, Data, Effect, Exit, Option } from 'effect'
import { describeCause } from '../helpers/effectRuntime'
import { joinMediaUrlsWire } from '../helpers/mediaUrls'

export const API_BASE = '/api'

import { useNotificationStore } from '../stores/notifications'
import { getActivePinia } from 'pinia'
import { useLoadingStore } from '../stores/loading'
import { getCurrentWorkspaceId } from '../helpers/workspaceScope'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`HTTP ${status} ${statusText}`)
    this.name = 'ApiError'
  }
}

export interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown
  /** When true, skip the error notification (caller handles UI inline). */
  silent?: boolean
  /**    * When false, skip the top loading bar. Defaults to true — the bar tracks network activity,
   * orthogonal to error visibility. Pass false for background pollers so the bar can idle while
   * they keep polling. */
  track?: boolean
  /** Timeout in ms. Default 15_000; 0 disables. A caller-provided `signal` is
   * respected and no timeout signal is added. */
  timeoutMs?: number
}

/**  * Centralized HTTP wrapper. Toasts on 4xx/5xx unless `silent: true`, and throws `ApiError` on
 * non-OK so callers can implement fallback UI. Network failures propagate without a toast —
 * SseStatusBadge covers SSE. */
export async function apiFetch<T = unknown>(url: string, opts: ApiFetchOptions = {}): Promise<T> {
  const { body, silent, track = true, timeoutMs = 15_000, ...init } = opts

  // Top loading bar: count this request while in flight. Guarded by
  // getActivePinia so specs importing the api module without an
  // installed pinia keep working — untracked in that case.
  const loading = track && getActivePinia() ? useLoadingStore() : null
  loading?.startApi()

  // Idle-freeze fix: hung backend must not park the UI forever.
  // Respect a caller-provided signal; otherwise arm a timeout signal.
  let signal: AbortSignal | undefined = init.signal as AbortSignal | undefined
  let timeoutId: ReturnType<typeof setTimeout> | undefined
  // Fallback controller when `AbortSignal.timeout` is unavailable
  // (older WebKit / jsdom). Only created when we need a timeout and
  // the caller did not provide their own signal.
  let fallbackController: AbortController | undefined
  if (!signal && timeoutMs > 0) {
    const withTimeout = (globalThis as { AbortSignal?: typeof AbortSignal }).AbortSignal
    if (withTimeout && typeof withTimeout.timeout === 'function') {
      signal = withTimeout.timeout(timeoutMs)
    } else if (typeof AbortController !== 'undefined') {
      fallbackController = new AbortController()
      signal = fallbackController.signal
      timeoutId = setTimeout(() => fallbackController?.abort(), timeoutMs)
    }
  }

  const fetchInit: RequestInit = {
    ...init,
    signal,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> | undefined),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }

  try {
    const response = await fetch(`${API_BASE}${url}`, fetchInit)

    if (!response.ok) {
      const responseBody = await response.text().catch(() => '')
      // Auth enforcement: expired/revoked session mid-use → bounce to /login?redirect=<current>
      // (router guard covers boot; this covers in-app expiry). Skip for auth endpoints themselves
      // and when already on /login to avoid loops.
      if (response.status === 401 && !url.startsWith('/auth/')) {
        try {
          const loc = globalThis.location
          if (loc && !loc.pathname.startsWith('/login')) {
            loc.href = `/login?redirect=${encodeURIComponent(loc.pathname + loc.search)}`
          }
        } catch {
          /* non-browser (vitest) — no redirect */
        }
      }

      if (!silent) {
        const parsedError = tryParseJsonErrorField(responseBody)
        const message = parsedError ?? `HTTP ${response.status} ${response.statusText}`
        const details = parsedError ? responseBody : responseBody || undefined
        useNotificationStore().notifyError(message, details)
      }

      throw new ApiError(response.status, response.statusText, responseBody)
    }

    // 204 No Content — return undefined cast to T
    if (response.status === 204) {
      return undefined as T
    }

    return (await response.json()) as T
  } finally {
    if (timeoutId !== undefined) clearTimeout(timeoutId)
    loading?.finishApi()
  }
}

function tryParseJsonErrorField(body: string): string | null {
  if (!body) return null
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') {
      return obj.error
    }
    return null
  } catch {
    return null
  }
}

// Re-export SseClient so call sites that hold a reference (e.g. `const workersSse: api.SseClient |
// null = null`) can import it from the same place they import the factory functions.
export type { SseClient } from '../helpers/sseClient'

// Types matching backend responses
export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

export interface FolderInfo {
  path: string
  absolute: string
  home: string
  parent?: string
  entries: FolderEntry[]
}

export interface Workspace {
  id: string
  name: string
  icon: string
  items: WorkspaceItem[]
  // Server-side item count, present on GET /api/workspaces rows even
  // when `is_include_items=false` (items stay `[]` until lazily
  // loaded) — keeps count badges truthful for unvisited workspaces.
  items_count?: number
  expanded: boolean
}

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /**    * Free-text description of the column's meaning. Empty string when unset; the Settings UI renders
   * an "Add a description..." placeholder. Optional for backwards compat with legacy column
   * literals in test files. */
  description?: string | null
  position: number
  created_at: string
  // NEW (kanban task dependencies). `is_done` marks a column as
  // completing: cards here no longer block their dependents.
  is_done?: boolean
}

/**  * Wire shape for `GET .../design/pages` (list envelope) and `POST .../design/pages` (single page).
 * Numeric fields are `number`, not `i64` — JSON has no integer/float distinction on the wire. */
export interface DesignPage {
  id: string
  workspace_item_id: string
  name: string
  /**    * 1:1 FK to `workspace_item_tasks.id`, set at page-create time. Resolves the page's chat task
   * directly — no name matching, no legacy migration, no `taskHasMessages` probe. */
  workspace_item_task_id: string
  width: number
  height: number
  position: number
  created_at: string
  updated_at: string
}

/** Element types emitted by the backend's `ElementType` enum. Wire form is the lowercase
 * `tagName` string; the backend maps it back to the enum at the handler boundary. */
export const normalizeDesignElementType = <
  T extends { type?: DesignElementType; elem_type?: string },
>(
  e: T,
): T & { type: DesignElementType } => {
  const fallback: DesignElementType = (e.elem_type as DesignElementType) ?? 'rectangle'
  return { ...e, type: e.type ?? fallback }
}

export type DesignElementType = 'rectangle' | 'ellipse' | 'text' | 'image' | 'frame' | 'group'

/**  * Wire shape for design elements (rows in `design_page_elements`). Mirrors the backend's
 * `http_response.DesignElementResponse`. Numeric fields are `number` (JSON has no int/float
 * distinction); optional strings use `''` as "no value". */
export interface DesignElement {
  id: string
  page_id: string
  name: string
  type: DesignElementType
  x: number
  y: number
  width: number
  height: number
  rotation: number
  fill: string
  stroke: string
  stroke_width: number
  corner_radius: number
  opacity: number
  text_content: string
  text_style: string
  image_url: string
  file_path: string
  // NEW (Chunk 5 of grouped-layers plan): FK to a `group`/`frame` element
  // on the same page. Empty string `""` (NOT `null`) is the wire form for
  // NULL. Optional for legacy elements; `undefined` means top-level.
  parent_id?: string | null
  z_index: number
  position: number
  created_at: string
  updated_at: string
}

/**  * Geometry-only patch payload for `PATCH .../design/pages/:page_id/elements/:element_id/geometry`.
 * Every field is optional — the backend sparse-merges and leaves the rest alone. */
export interface DesignElementGeometry {
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/**  * Wire shape for design-mode SSE events (`design_element_created` / `_updated` / `_deleted`). All
 * three share one payload struct; the `action` discriminator routes them. Field names are the
 * backend's snake_case JSON keys. */
export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  page_id: string
  element_id: string
  /**    * Batch event variant (`design_elements_geometry_batch_updated`). When set, the SSE handler reads
   * `element_ids` instead of `element_id` to drive the local-mutation dedupe. */
  element_ids?: string[]
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // The on-disk cwd for kanban items. Optional: legacy kanbans predate the field, folder items keep
  // their path on each child, and test fixtures omit it. `null` is allowed so the SQLite NULL →
  // JSON null round-trip type-checks; `v-if="!item.path"` treats null/undefined/"" alike.
  path?: string | null
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // `item_type === 'kanban'`, omitted otherwise. Optional so legacy
  // workspace-item literals in tests keep type-checking.
  kanban_columns?: KanbanColumn[]
}

export interface Task {
  id: string
  name: string
  description?: string
  // Task type. Optional for backwards compat with legacy task
  // literals. ('routine' was deleted in Migration 084 — routines are
  // now first-class workspace items, see WorkspaceRoutine below.)
  task_type?: 'standard' | 'memory'
  completed?: boolean
  createdAt?: Date
  // ISO datetime string from the backend; present for tasks returned by
  // getTasks() and used to sort/filter on the frontend. Backend stamps this
  // on every update (rename, complete, etc.).
  updatedAt?: Date
  // NEW (pinned-tasks feature). Both optional so legacy task literals in
  // tests keep type-checking.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for tasks under `item_type === 'kanban'`
  // parents. `kanban_column_id` is `null` (not undefined) when the task is unassigned (e.g. its
  // column was deleted). Both optional so legacy task literals keep type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (kanban task tags, Migration 067). Array of free-form tag strings. Empty array = no tags.
  // Optional so legacy task literals in tests keep type-checking. On the wire the field is a
  // JSON-encoded array string; the store normalizes via `normalizeTaskTags` at every fetch site.
  tags?: string[]
  // NEW (kanban image urls, Migration 069). Array of base64 data URLs;
  // empty array = no images. Optional so legacy task literals in tests
  // keep type-checking. On the wire it is a `||`-delimited string.
  imageUrls?: string[]
  // NEW (kanban video urls, Migration 090). Array of base64 data
  // URLs (`data:video/<mime>;base64,<payload>`). Empty array = no
  // videos. Same `||`-delimited wire convention as imageUrls.
  videoUrls?: string[]
  // NEW (Media-flags change — lightweight list/get payload). The backend list/get return only these
  // flags; the full base64 TEXT stays server-side for the lazy `getTaskMedia` endpoint below. The
  // frontend fetches media only when the flag is true.
  is_have_image?: boolean
  is_have_video?: boolean
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override (absolute path,
  // or '' for cwd-less). Optional so legacy task literals in tests keep type-checking. Threaded
  // into the 3-level cwd fallback chain: per-task cwd → kanban-level path → sandbox.
  cwd?: string
  // NEW (kanban task git-branch badge). The current git branch for the task's
  // cwd — worktree cwd if bound, else the parent item's `path`. `null` when the
  // cwd is not a git repo or HEAD is detached; the UI omits the badge.
  git_branch?: string | null
  // NEW (kanban task dependencies). `depends_on` lists ids this task waits for; `blocked_by` is
  // the incomplete subset (names for tooltips); `is_blocked` mirrors `blocked_by.length > 0`.
  depends_on?: string[]
  blocked_by?: TaskDependencyBlocker[]
  is_blocked?: boolean
}

/**
 * One incomplete dependency blocking a task's move — the 409 `blockers` entries.
 */
export interface TaskDependencyBlocker {
  task_id: string
  name: string
  column_id: string | null
  column_name: string | null
}

/**
 * Normalize `depends_on` in place; a malformed wire value becomes `[]` instead of throwing.
 */
export function normalizeTaskDependsOn<T extends { depends_on?: unknown }>(task: T): void {
  const v: unknown = task.depends_on
  if (v === undefined) return
  if (Array.isArray(v)) {
    task.depends_on = v.filter((e): e is string => typeof e === 'string')
    return
  }
  if (typeof v === 'string') {
    try {
      const parsed: unknown = JSON.parse(v)
      task.depends_on = Array.isArray(parsed)
        ? parsed.filter((e): e is string => typeof e === 'string')
        : []
    }
    // eslint-disable-next-line local/no-try-catch -- defensive wire coercion: JSON.parse has no Effect-TS spelling here, and the fallback below documents the failure mode
    catch {
      // Unparseable wire string means "no readable edges" — [] keeps
      // the card rendering (unblocked) instead of crashing on it.
      console.warn('[api] ignoring malformed depends_on wire value')
      task.depends_on = []
    }
    return
  }
  task.depends_on = []
}

/**
 * Read the 409 move-gate `blockers` off a thrown error, or null when it is another failure.
 */
export function parseMoveBlockers(err: unknown): TaskDependencyBlocker[] | null {
  if (!(err instanceof ApiError) || err.status !== 409) return null
  try {
    const parsed: unknown = JSON.parse(err.body)
    if (parsed && typeof parsed === 'object' && Array.isArray((parsed as { blockers?: unknown }).blockers)) {
      return (parsed as { blockers: TaskDependencyBlocker[] }).blockers
    }
    return null
  }
  // eslint-disable-next-line local/no-try-catch -- defensive body probe: a non-JSON 409 body simply is not the move-gate shape, and null below documents that
  catch {
    // Non-JSON body cannot carry `blockers` — null tells the
    // caller this error is not a move-gate refusal.
    console.warn('[api] move-gate probe hit a non-JSON 409 body')
    return null
  }
}

/**  * Split a mixed array of base64 data URLs into images vs videos (Migration 090). `data:video/...`
 * entries ride `video_urls`, everything else rides `image_urls`; explicit `videoUrls` args are
 * merged in. */
export function splitMediaUrls(
  urls?: string[],
  extraVideos?: string[],
): {
  images: string[]
  videos: string[]
} {
  const images: string[] = []
  const videos: string[] = [...(extraVideos ?? [])]
  for (const u of urls ?? []) {
    if (u.startsWith('data:video/')) videos.push(u)
    else images.push(u)
  }
  return { images, videos }
}

// Health check
export async function healthCheck(): Promise<{
  status: string
  timestamp: number
}> {
  return await apiFetch<{ status: string; timestamp: number }>('/health')
}

// System Folder API
export async function getSystemFolder(workspaceId?: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(`/system/folder?action=list${workspaceQuery(workspaceId)}`)
}

export async function listFolder(path: string, workspaceId?: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(
    `/system/folder?path=${encodeURIComponent(path)}&action=list${workspaceQuery(workspaceId)}`,
  )
}

/** The `workspace_id` a folder request carries: SaaS mode lists a workspace's
 *  VM, so a request that does not say which workspace it means is refused.
 *  The app shows one workspace at a time — the current one, unless named. */
function workspaceQuery(workspaceId?: string): string {
  const id = workspaceId || getCurrentWorkspaceId()
  return id ? `&workspace_id=${encodeURIComponent(id)}` : ''
}

/**  * Server-side recursive file search for the ChatView `@` picker. One round-trip replaces the old
 * N-sequential-fetch full-tree walk; uses `apiFetch` for timeout/auth handling. */
export async function searchFiles(
  cwd: string,
  q: string,
  limit = 50,
  max_depth = 8,
  signal?: AbortSignal,
): Promise<{ entries: FolderEntry[] }> {
  return await apiFetch<{ entries: FolderEntry[] }>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=search&q=${encodeURIComponent(q)}&limit=${limit}&max_depth=${max_depth}${workspaceQuery()}`,
    { signal, silent: true },
  )
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  // Items are loaded separately via getWorkspacesItems(workspace_id) — this keeps the workspaces
  // list small and lets us fetch items lazily. Persists the list to the workspacesCache
  // (fail-silent) so the next init can paint instantly and revalidate in the background.
  const res = await apiFetch<{ workspaces: Workspace[] }>('/workspaces?is_include_items=false')
  try {
    const { writeWorkspacesCache } = await import('../helpers/workspacesCache')
    writeWorkspacesCache(res?.workspaces ?? [])
  } catch {
    // cache write is best-effort — the live response still wins.
  }
  return res
}

export async function getWorkspacesItems(
  workspace_id: string,
): Promise<{ items: WorkspaceItem[]; count: number }> {
  return await apiFetch<{ items: WorkspaceItem[]; count: number }>(
    `/workspaces/${workspace_id}/items`,
  )
}

// Cold-start fallback for the "New Chat" action. This endpoint covers the one case the list cannot:
// the app was open when Migration 094 ran, so the store's list predates `is_default`.
export async function getOrCreateDefaultProject(
  workspace_id: string,
): Promise<{ item: WorkspaceItem; created: boolean }> {
  return await apiFetch<{ item: WorkspaceItem; created: boolean }>(
    `/workspaces/${workspace_id}/default-project`,
    { method: 'POST' },
  )
}

export async function createWorkspace(name: string): Promise<Workspace> {
  return await apiFetch<Workspace>('/workspaces', {
    method: 'POST',
    body: { name },
  })
}

export async function getWorkspace(id: string): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`)
}

export async function deleteWorkspace(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/${id}`, {
    method: 'DELETE',
  })
}

export async function updateWorkspace(id: string, data: Partial<Workspace>): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`, {
    method: 'PUT',
    body: data,
  })
}

/** Persist a new top-to-bottom display order for workspaces. POST /api/workspaces/reorder
 * with body `{ordered_ids: [...]}`. The server reverses the array (top of list = highest
 * position) and throws on non-2xx so the caller can roll back its optimistic update. */
export async function reorderWorkspaces(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>('/workspaces/reorder', {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

/** Persist a new top-to-bottom display order for one workspace's items. POST
 * /api/workspaces/:workspace_id/items/reorder with body `{ordered_ids: [...]}`. Mirrors
 * `reorderWorkspaces` but scoped to a single workspace; the list is the full ordered set. */
export async function reorderWorkspaceItems(
  workspaceId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/items/reorder`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}

// Task API
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 10,
  cursor?: string,
  // NEW (2026-08-06): NO default values. Pass `undefined` for both when no sort is in play and let
  // the backend's default (`updated_at desc`) handle it — same wire result, cleaner URL, less
  // coupling.
  sortBy?: 'created_at' | 'updated_at' | 'name',
  direction?: 'asc' | 'desc',
  columnId?: string,
  q?: string,
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  if (sortBy && direction) {
    params.set('sort_by', sortBy)
    params.set('direction', direction)
  }
  if (cursor) {
    params.set('cursor', cursor)
  }
  if (columnId && columnId.length > 0) {
    params.set('column_id', columnId)
  }
  if (q && q.length > 0) {
    params.set('q', q)
  }
  const data = await apiFetch<{
    tasks: Task[]
    has_more: boolean
    next_cursor: string | null
  }>(`/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`)
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}

/** Fetch ONE workspace item task by id (kanban Task details dialog). GET
 * /api/workspaces/:ws/items/:item/tasks/:task_id → { task } | 404. Resolves to the Task, or
 * null on 404 — "the task is gone" is expected, so 404 is silent. Other failures throw. */
export async function getTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<Task | null> {
  try {
    const data = await apiFetch<{ task: Task | null }>(
      `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}`,
      { silent: true },
    )
    return data.task ?? null
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Stamp `workspace_item_tasks.last_human_touched_at` so the kanban card flips from the
 * orange "AI finished — awaiting review" dot to the green "reviewed" checkmark.
 * Fire-and-forget: failures log a warning but don't surface as toasts. */
export async function getTaskMedia(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<TaskMedia | null> {
  try {
    const data = await apiFetch<{ image_urls?: string; video_urls?: string }>(
      `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}/media`,
      { silent: true },
    )
    const split = (v?: string): string[] => (!v ? [] : v.split('|').filter((seg) => seg.length > 0))
    return { imageUrls: split(data.image_urls), videoUrls: split(data.video_urls) }
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

export type TaskMedia = { imageUrls: string[]; videoUrls: string[] }

/** Parallel media fetch for MANY tasks (media-flags change). Fires one `getTaskMedia` per
 * id concurrently and settles every leg (`Promise.allSettled`): a single 404 / network blip
 * resolves that entry to null instead of rejecting the whole batch. */
export async function getTasksMedia(
  workspaceId: string,
  itemId: string,
  taskIds: string[],
): Promise<Map<string, TaskMedia | null>> {
  const settled = await Promise.allSettled(
    taskIds.map(async (taskId): Promise<[string, TaskMedia | null]> => [
      taskId,
      await getTaskMedia(workspaceId, itemId, taskId),
    ]),
  )
  const out = new Map<string, TaskMedia | null>()
  settled.forEach((entry, i) => {
    if (entry.status === 'fulfilled') out.set(entry.value[0], entry.value[1])
    // Rejected legs (non-404 throw inside getTaskMedia is already
    // narrowed to 404→null, so this is defensive): record null so the
    // caller sees every requested id exactly once.
    else out.set(taskIds[i] ?? '', null)
  })
  return out
}

export async function markTaskHumanTouched(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/touched`,
    { method: 'PUT' },
  )
}

/** Create a task under a workspace item. The third arg is a single params object: for a standard
 * task pass `{ name, description?, taskType: 'standard' }`, for a memory pass `{ name, taskType:
 * 'memory', memory: { name, content } }`. */
export async function createTask(
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
    // Auto-retry-until-stop (Migration 063, Option A fix): when the caller passes `'1'`, the
    // backend ALSO inserts a `sessions` row (task.id == session.id per the project convention) so
    // the unattended-mode flag has somewhere to land at create time.
    isAutoRetryUntilStop?: string
    // Kanban task tags (Migration 067 — kanban task tags feature). Array of free-form tag strings.
    // Empty array / undefined = no tags. Forwarded as a JSON-encoded array string on the wire.
    // Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags?: string[]
    // NEW (Migration 069 — kanban image urls column). Plan:
    // docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md. NOTE (Migration 090): may also
    // carry `data:video/...` URLs — splitMediaUrls routes those to `video_urls` at send time.
    imageUrls?: string[]
    // NEW (Migration 090 — kanban video urls column). Array of
    // base64 data URLs (`data:video/<mime>;base64,<payload>`).
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Absolute path
    // on disk or '' for cwd-less. When undefined, the backend stores NULL (cwd-less task — falls
    // back to the kanban-level path + sandbox).
    cwd?: string
  },
): Promise<Task> {
  const taskType = params.taskType ?? 'standard'
  const body: Record<string, unknown> = {
    name: params.name,
    description: params.description,
    task_type: taskType,
  }
  if (taskType === 'memory' && params.memory) {
    body.memory_name = params.memory.name
    body.memory_content = params.memory.content
  }
  // Only forward the unattended flag when the user actually flipped
  // it ON. Default '0' is the no-op default — sending it would
  // trigger an unnecessary session INSERT (a new row per task).
  if (params.isAutoRetryUntilStop === '1' && taskType === 'standard') {
    body.is_auto_retry_until_stop = '1'
  }
  // Forward tags as a JSON-encoded array string (Migration 067). The backend's
  // tags_validation.validateAndNormalizeTags parses and re-encodes the array, so the wire shape is
  // a JSON string, not an array — single source of truth for JSON shape.
  if (params.tags && params.tags.length > 0) {
    body.tags = JSON.stringify(params.tags)
  }
  // Migration 069 — image_urls. The wire shape is a `||`-delimited string (matching
  // `llm_history.image_url`). Migration 090 — split data:video/... out to video_urls.
  {
    const { images, videos } = splitMediaUrls(params.imageUrls, params.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  // Migration 070 — per-task cwd override. Forward verbatim (the backend's `validated_cwd` block
  // validates it — absolute path, ≤ 4 KiB, no control chars).
  if (params.cwd !== undefined) {
    body.cwd = params.cwd
  }
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    body,
  })
}

/** Kanban-specific task create endpoint. Plan:
 * docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md */
export type KanbanCreateMode = 'create' | 'create_session' | 'create_and_run'

export interface KanbanCreateTaskPayload {
  mode: 'create'
  name: string
  description?: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  // Migration 070 — per-task cwd override. Absolute path on disk or '' for cwd-less.
  cwd?: string
  // Migration 063 — only meaningful for create_and_run; for plain create,
  // the backend atomically inserts the sessions row when this is '1'.
  isAutoRetryUntilStop?: string
  // Migration 112 — the skills this task asks the agent to use, in pick
  // order. The exact `skills.name` values from the New-task dialog's picker.
  // Persisted on the task row; empty/undefined = no skill.
  skillNames?: string[]
}

export interface KanbanCreateAndRunPayload {
  mode: 'create_and_run'
  name: string
  description?: string
  /** Required when mode='create_and_run'. The first user message the agent sees. */
  queue_message: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  cwd?: string
  isAutoRetryUntilStop?: string
  /** Backend persists onto the sessions row. Empty/undefined = backend default. */
  selected_profile_model?: string
  /** Migration 112 — the skills this task asks the agent to use, in pick order. */
  skill_names?: string[]
}

/** New mode (`create_session`) — inserts the sessions row keyed by task.id + persists
 * selected_profile_model + emits session_created SSE, but does NOT call emit_run_agent. Returns
 * `session: { id, name, status: 'idle' }`. */
export interface KanbanCreateSessionOnlyPayload {
  mode: 'create_session'
  name: string
  description?: string
  tags?: string[]
  imageUrls?: string[]
  videoUrls?: string[]
  /** Migration 070 — per-task cwd override. */
  cwd?: string
  /** Migration 063 — persists on the sessions row. */
  isAutoRetryUntilStop?: string
  /** Persists on the sessions row. Empty/undefined = backend default. */
  selected_profile_model?: string
  /** Migration 112 — the skills this task asks the agent to use, in pick order. */
  skill_names?: string[]
}

export interface KanbanSessionInfo {
  id: string
  name: string
  status: string
}

export interface KanbanCreateResponse {
  task: Task
  session: KanbanSessionInfo | null
}

export async function createKanbanTask(
  workspaceId: string,
  itemId: string,
  payload: KanbanCreateTaskPayload | KanbanCreateSessionOnlyPayload | KanbanCreateAndRunPayload,
): Promise<KanbanCreateResponse> {
  const body: Record<string, unknown> = {
    mode: payload.mode,
    name: payload.name,
    description: payload.description,
  }
  if (payload.tags && payload.tags.length > 0) {
    body.tags = JSON.stringify(payload.tags)
  }
  {
    const { images, videos } = splitMediaUrls(payload.imageUrls, payload.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  if (payload.cwd !== undefined) {
    body.cwd = payload.cwd
  }
  if (payload.isAutoRetryUntilStop !== undefined) {
    body.is_auto_retry_until_stop = payload.isAutoRetryUntilStop
  }
  const skill_names: string[] | undefined =
    payload.mode === 'create'
      ? payload.skillNames
      : (payload as { skill_names?: string[] }).skill_names
  if (skill_names !== undefined) {
    body.skill_names = skill_names
  }
  if (payload.mode === 'create_and_run') {
    body.queue_message = payload.queue_message
    if (payload.selected_profile_model !== undefined) {
      body.selected_profile_model = payload.selected_profile_model
    }
  } else if (payload.mode === 'create_session') {
    // Persists on the new sessions row.
    if (payload.selected_profile_model !== undefined) {
      body.selected_profile_model = payload.selected_profile_model
    }
  }
  return apiFetch<KanbanCreateResponse>(`/workspaces/${workspaceId}/items/${itemId}/kanban/tasks`, {
    method: 'POST',
    body,
  })
}

export async function updateTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  data: Partial<Task>,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}

// Task API - Simple version (just task_id + optional fields) The backend's PUT
// /api/workspaces/tasks/:task_id accepts a subset of fields. The server cascades any name change to
// the linked session and re-broadcasts via SSE.
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    // NEW (kanban-task-detail-dialog plan): the per-task description
    // shown in the detail dialog. Empty string = clear (the
    // dialog's "Clear description" path sends `''`).
    description?: string
    // NEW (kanban task tags, Migration 067): array of tag strings.
    // Forwarded as JSON-encoded string. Empty array = clear tags.
    tags?: string[]
    // NEW (kanban image urls, Migration 069): array of base64 data URLs. Forwarded as
    // `||`-delimited string (matching the `llm_history.image_url` convention). Empty array = clear
    // images. Plan: docs/superpowers/plans/2026-08-06-kanban-image- urls-column.md.
    imageUrls?: string[]
    // NEW (kanban video urls, Migration 090): same contract as imageUrls.
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override. Semantics: -
    // undefined: leave unchanged (no-op). - '': clear per-task cwd (falls back to kanban-level path
    // + sandbox). - '/home/me/repo-A': set per-task cwd to this path.
    cwd?: string
    // NEW (kanban task dependencies). Replace-all dependency edit:
    // forwarded ONLY when provided (omitted = untouched, `[]` =
    // clear all). Sent as a real JSON array (unlike tags).
    depends_on?: string[]
  },
): Promise<{ success: boolean }> {
  const body: Record<string, unknown> = { ...data }
  // Encode tags array as a JSON string for the wire (Migration 067).
  if (data.tags !== undefined) {
    body.tags = JSON.stringify(data.tags)
  }
  // Migration 069 — image_urls. `||`-join the array for the wire
  // (matching `llm_history.image_url`). Empty array → empty string
  // → SQL '' literal → DB clears the column.
  if (data.imageUrls !== undefined || data.videoUrls !== undefined) {
    const { images, videos } = splitMediaUrls(data.imageUrls, data.videoUrls)
    body.image_urls = joinMediaUrlsWire(images)
    body.video_urls = joinMediaUrlsWire(videos)
  }
  return await apiFetch<{ success: boolean }>(`/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    body,
  })
}

export async function deleteTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'DELETE' },
  )
}

/** Pin or unpin a task. The backend bumps the row's `pinned_position` to MAX+1 (when pinning) so a
 * newly-pinned task lands at the BOTTOM of the pinned region; the user can drag it to a different
 * position afterwards. */
export async function pinTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{
    success: boolean
    id: string
    is_pinned: boolean
    pinned_position: number
  }>(`/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/pin`, {
    method: 'POST',
    body: { is_pinned: isPinned },
  })
}

/** Reorder the pinned subset of a single workspace item. The `orderedIds` array is the full
 * top-to-bottom display order of the pinned rows. The backend assigns `pinned_position = count - 1
 * - i` so the rows render in the user's chosen order. */
export async function reorderPinnedTasks(
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/reorder_pinned`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}

/** Manually fire a workspace routine. Returns the session_id (which equals the routine id — every
 * fire appends to the same session chat). */
export async function runWorkspaceRoutine(
  workspaceId: string,
  itemId: string,
  routineId: string,
): Promise<{ session_id: string }> {
  return await apiFetch<{ session_id: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/routines/${routineId}/run`,
    { method: 'POST' },
  )
}

/** Trigger an LLM worker on an existing task's session WITHOUT queueing a new user message. For
 * tasks with chat history, the agent resumes the conversation. Plan:
 * docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md */
export async function startAgentOnTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean; session_id?: string; status?: string }> {
  return await apiFetch<{ success: boolean; session_id?: string; status?: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/start_agent`,
    { method: 'POST' },
  )
}

/** Bulk "Run all agents" for one kanban column (plan:
 * docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md, Task 4, Option C). */
export interface RunAllAgentsSummary {
  success: boolean
  column_id?: string
  started: string[]
  skipped: string[]
  failed: string[]
}

export async function runAllAgentsInColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<RunAllAgentsSummary> {
  return await apiFetch<RunAllAgentsSummary>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}/run_all_agents`,
    { method: 'POST' },
  )
}

/** Bulk "Stop all agents" for one kanban column — the mirror of `runAllAgentsInColumn` above. */
export interface StopAllAgentsSummary {
  success: boolean
  column_id?: string
  stopped: string[]
  skipped: string[]
  failed: string[]
}

export async function stopAllAgentsInColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<StopAllAgentsSummary> {
  return await apiFetch<StopAllAgentsSummary>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}/stop_all_agents`,
    { method: 'POST' },
  )
}

// Chat API - Zig Backend Integration (Zig backend calls LLM backend internally)
export interface Chat {
  session_id: string
  session_name?: string
  status?: string
  selected_profile_model?: string
  sub_agent_name?: string
  parent_session_id?: string
  cwd?: string
  /// Bound git worktree path ("" = none). The sidebar shows the
  /// kanban-style branch badge when `git_branch` is non-empty and
  /// uses this path as the tooltip + PR-status lookup cwd.
  git_worktree_cwd?: string
  /// Current git branch for the effective cwd ("" / absent = no
  /// badge). Computed per request by the backend (`session_list.zig`
  /// via `git -C <cwd>`, same helper as the kanban task badge).
  git_branch?: string
  // Backend wall-clock timestamp of the last `sessions.UPDATE` — bumped by everything (agent loop,
  // profile change, error, etc). Plan:
  // docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
  updated_at?: string
  /// Migration 063 — "0" / "1" opt-in for unattended mode. Always
  /// present in the GET /api/sessions response (ChatsList uses this
  /// to render the `🔁 unattended` badge).
  is_auto_retry_until_stop?: string
  // Migration 082 — unix-ms string of the last time a HUMAN interacted with this session. Empty
  // string (NOT undefined) for legacy rows so the ChatsList time pill can fall back to `updated_at`
  // predictably. Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
  last_human_touched_at?: string
  /// Migration 104 — pinned sessions (PINNED section above RECENT).
  /// True when the user pinned via right-click menu. Always present
  /// in GET /api/sessions (COALESCE'd server-side).
  is_pinned?: boolean
  /// Migration 104 — position inside the pinned region (MAX+1 on pin,
  /// 0 when unpinned). PINNED section sorts by this DESC.
  pinned_position?: number
  last_finish_reason?: string
  needs_human_review?: boolean
}

export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  created_at: number
  tool_name?: string
  tool_call_id?: string
  diffview_before?: string
  diffview_after?: string
  image_url?: string
  video_url?: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  tool_calls_json?: any
  finish_reason?: string
  is_input?: boolean
  is_output?: boolean
  /**    * 2026-08-23 hidden-messages fix — thinking models' chain-of-thought. Already returned by the
   * backend REST endpoint (http_response.zig SessionMessage.reasoning_content) and the SSE payload;
   * previously unmapped so ChatView never saw it. */
  reasoning_content?: string
}

export interface SkillInfo {
  skill_name: string
  content: string
  loaded_at?: number
}

// All chat endpoints go through Zig backend at /api/llm/*
// Zig backend internally calls LLM backend
// Parse timestamp - backend sends nanoseconds as string, convert to seconds
function parseTimestamp(ts: number | string): number {
  const num = typeof ts === 'string' ? parseInt(ts, 10) : ts
  // If timestamp looks like nanoseconds (> 1e12), convert to seconds
  return num > 1e12 ? Math.floor(num / 1e9) : num
}
/** The transcript fetch failed — transport, non-2xx, or an abort. Deliberately coarse: the UI acts
 * on "the transcript is unavailable", not on which kind of unavailable it is, and the retry policy
 * is the same for all three. */
export class ChatHistoryError extends Data.TaggedError('ChatHistoryError')<{
  readonly sessionId: string
  readonly reason: string
}> {}

/** An SSE frame that arrived on a named channel with a body that is not the JSON its wire name
 * promises. */
export class SseFrameError extends Data.TaggedError('SseFrameError')<{
  readonly eventType: string
  readonly reason: string
}> {}

/**  * What a best-effort transcript caller gets when the fetch failed. Named, not inlined, so the two
 * shapes can be diffed by eye: every field is `undefined` or empty because the answer genuinely is
 * unknown, and the only place this is legitimate is `getChatHistory`'s three metadata callers. */
const EMPTY_CHAT_HISTORY: ChatHistoryResponse = {
  messages: [],
  has_more: false,
  next_cursor: null,
  cwd: undefined,
  git_worktree_cwd: undefined,
  pr_url: undefined,
  pr_provider: undefined,
  // 2026-08-07-profile-persist-read — preserve the field shape on the error path so ChatView's
  // `loadChatHistory` branch can safely read `data.selected_profile_model` (it'll be `undefined`,
  // which ChatView coerces to `null`).
  selected_profile_model: undefined,
  max_total_tokens: undefined,
  max_capacity_total_tokens: undefined,
  total_count: undefined,
  skills: [],
}

export type ChatHistoryResponse = {
  messages: Message[]
  has_more: boolean
  next_cursor: string | null
  cwd?: string
  git_worktree_cwd?: string
  /// Attached PR URL (empty/missing = none). Mirrors sessions.pr_url.
  pr_url?: string
  /// Effective PR provider. Mirrors sessions.pr_provider.
  pr_provider?: string
  // Session's selected profile name (empty/missing = "Default", i.e. no profile selected). Mirrors
  // the backend `sessions.selected_profile_model` column.
  selected_profile_model?: string
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  total_count?: number
  skills?: SkillInfo[]
}

/** The transcript endpoint, WITH the failure in the type. Returns `Effect<ChatHistoryResponse,
 * ChatHistoryError>`, so "the backend is unreachable" is a value the caller must handle — it cannot
 * be mistaken for an empty transcript. */
export function fetchChatHistoryEffect(
  sessionId: string,
  limit = 50,
  cursor?: string,
  direction: 'asc' | 'desc' = 'desc',
  timeoutMs?: number,
): Effect.Effect<ChatHistoryResponse, ChatHistoryError> {
  const params = new URLSearchParams({
    sort_by: 'created_at',
    direction,
    limit: limit.toString(),
  })
  if (cursor) {
    params.set('cursor', cursor)
  }
  // silent: true — the failure is the caller's to handle (the chatview's retry loop + inline error UI
  // for the transcript; a console.log for the metadata callers), so a toast on 404/5xx would be noise.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  const toResponse = (data: any): ChatHistoryResponse => ({
    messages: data.messages.map(
      (msg: {
        id: string
        role: string
        content: string
        created_at: number | string
        tool_name?: string
        diffview_before?: string
        diffview_after?: string
        image_url?: string
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        tool_calls_json?: any
        reasoning_content?: string
      }) => ({
        ...msg,
        content: msg.content,
        created_at: parseTimestamp(msg.created_at),
        tool_name: msg.tool_name,
        diffview_before: msg.diffview_before,
        diffview_after: msg.diffview_after,
        image_url: msg.image_url,
        tool_calls_json: msg.tool_calls_json,
        // 2026-08-23 hidden-messages fix — pass the thinking model's
        // reasoning through to ChatView (backend already returns it).
        reasoning_content: msg.reasoning_content || undefined,
      }),
    ),
    has_more: data.has_more,
    next_cursor: data.next_cursor,
    cwd: data.cwd,
    git_worktree_cwd: data.git_worktree_cwd,
    pr_url: data.pr_url,
    pr_provider: data.pr_provider,
    // 2026-08-07-profile-persist-read — read the per-session selected profile name so the chatview
    // chip can show the persisted selection on page refresh.
    selected_profile_model: data.selected_profile_model,
    max_total_tokens: data.max_total_tokens,
    max_capacity_total_tokens: data.max_capacity_total_tokens,
    total_count: data.total_count,
    skills: data.skills,
  })

  return Effect.tryPromise({
    try: () =>
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; matches `toResponse` above, which re-narrows each field.
      apiFetch<any>(`/llm/session/${encodeURIComponent(sessionId)}/messages?${params}`, {
        silent: true,
        ...(timeoutMs === undefined ? {} : { timeoutMs }),
      }),
    catch: (cause) => new ChatHistoryError({ sessionId, reason: describeCause(Cause.fail(cause)) }),
  }).pipe(Effect.map(toResponse))
}

/** Best-effort transcript: a failure yields an EMPTY transcript rather than a rejection,
 * implemented on the Effect seam so no `try`/`catch` sits between the failure and the value the
 * caller gets. */
export function getChatHistory(
  sessionId: string,
  limit = 50,
  cursor?: string,
  direction: 'asc' | 'desc' = 'desc',
): Promise<ChatHistoryResponse> {
  return Effect.runPromise(
    fetchChatHistoryEffect(sessionId, limit, cursor, direction).pipe(
      Effect.catchAll((error) => {
        // The reason is logged, not discarded — the AGENTS.md rule about
        // never letting a caught error vanish into an indistinguishable value.
        console.log(error)
        return Effect.succeed(EMPTY_CHAT_HISTORY)
      }),
    ),
  )
}

// Send a message to LLM Migration 063 — adds the optional `isAutoRetryUntilStop` flag. "1" opts
// into unattended mode (the workflow re-reads this column on entry and soft-bails past retry_count
// > 10). Default undefined = today's behavior.
export const DEFAULT_CHAT_TOOLS = [
  'search_tool',
  'view_tool',
  'use_tool',
  'command',
  'search',
  'load_memory',
  'save_memory',
  'search_skills',
  'use_skill',
  // Introspection: list the tools equipped for this session ("what tools do I have"). Read-only,
  // sub-agent-safe. Seeded here so plain chat, design mode, and routine sessions (which all use
  // this request body) get it; agent/kanban modes seed it via backend DEFAULT_AGENT_TOOLS.
  'used_tools',
  // Interactive: ask the human a question (ends the turn until they answer).
  // Seeded in every mode by default — without it here the tool would be
  // silently filtered out of plain chat sessions.
  'ask_user',
  // Workspace-scoped documents (Migration 095). Both resolve their own workspace server-side from
  // the calling session, so a plain chat is as safe as a project task: outside a workspace-linked
  // session they refuse rather than guessing a scope.
  'add_document',
  'edit_document',
  // Read-only counterpart: `edit_document` replaces the WHOLE body, so a
  // chat agent cannot revise a note it wrote earlier without a way to
  // find the row first.
  'search_documents',
  // `delete_document` is intentionally omitted — irreversible, and it does not belong in the set
  // every plain chat starts with. It stays one click away in Settings → Tools, and an agent can
  // also reach it through search_tool → use_tool, which bypasses the allowlist.
].join(',')

export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
  isAutoRetryUntilStop?: string,
  videoUrls?: string[],
  workspaceId?: string,
): Promise<{ status: string }> {
  // Migration 090 — split data:video/... out to video_urls so a pasted
  // clip never hits the image-only validator (400).
  const { images, videos } = splitMediaUrls(imageUrls, videoUrls)
  const imageUrlsStr = joinMediaUrlsWire(images)
  const videoUrlsStr = joinMediaUrlsWire(videos)

  try {
    // silent: true — ChatView already surfaces these failures inline
    // (e.g. the LLM-not-configured banner) and the new global
    // notification system would duplicate the message.
    return await apiFetch<{ status: string }>('/llm/session', {
      method: 'POST',
      body: {
        session_id: sessionId,
        queue_message: message,
        allowed_tools: DEFAULT_CHAT_TOOLS,
        cwd_session: cwdSession,
        workspace_id: workspaceId ?? '',
        image_urls: imageUrlsStr,
        video_urls: videoUrlsStr,
        selected_profile_model: selectedProfile || '',
        // Migration 063 — pass through to POST /api/session. Empty
        // / undefined => the backend's default ("0" = off).
        is_auto_retry_until_stop: isAutoRetryUntilStop ?? '',
      },
      silent: true,
    })
  } catch (err) {
    // Preserve the original return-shape semantics so ChatView can branch on `status` for
    // user-facing messages: 'bad_request'         — backend 400 'unprocessable_entity'— backend 422
    // 'http_error'          — backend 4xx/5xx other than the above 'offline'.
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}

// Update an existing session (selectedProfile, name, isAutoRetryUntilStop). Migration 063 — extends
// the update shape to carry the unattended- mode flag. Pass `isAutoRetryUntilStop: '0'` to disable,
// '1' to enable, or omit to leave unchanged (matches the backend's `len > 0` guard).
export async function updateSession(
  sessionId: string,
  updates: {
    selectedProfile?: string | null
    name?: string
    isAutoRetryUntilStop?: string
  },
): Promise<{
  id: string
  name: string
  status: string
  selected_profile_model: string
  is_auto_retry_until_stop: string
}> {
  return await apiFetch<{
    id: string
    name: string
    status: string
    selected_profile_model: string
    is_auto_retry_until_stop: string
  }>(`/llm/session/${sessionId}`, {
    method: 'PUT',
    body: {
      selected_profile_model: updates.selectedProfile ?? '',
      name: updates.name ?? '',
      is_auto_retry_until_stop: updates.isAutoRetryUntilStop ?? '',
    },
  })
}

// POST /api/llm/session/:session_id/touched — stamp the human-touch column when the user opens a
// chat (clears the amber stale-dot). Contract: body {}, response { success, session_id }.
export async function markSessionTouched(
  sessionId: string,
): Promise<{ success: boolean; session_id: string }> {
  return await apiFetch<{ success: boolean; session_id: string }>(
    `/llm/session/${sessionId}/touched`,
    {
      method: 'POST',
      body: {},
      silent: true,
    },
  )
}

// Migration 104 — pin/unpin a session for the PINNED section above RECENT. Mirrors `pinTask`
// (kanban). The backend bumps `pinned_position` to MAX+1 on pin (lands at bottom) and syncs the
// linked task row when task.id == session_id, so kanban pin buttons stay in sync.
export async function pinSession(
  sessionId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{
    success: boolean
    id: string
    is_pinned: boolean
    pinned_position: number
  }>(`/llm/session/${sessionId}/pin`, {
    method: 'POST',
    body: { is_pinned: isPinned },
  })
}

// Migration 104 — reorder the PINNED section (drag-drop). `orderedIds`
// is the full top-to-bottom display order of pinned session ids.
export async function reorderPinnedSessions(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(`/llm/session/reorder_pinned`, {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

// SSE event types matching the backend
// Note: Backend sends events without explicit 'type' field in data.
// The 'finish_reason' field indicates message completion.
export interface SseEvent {
  session_id: string
  id?: string
  content?: string
  role?: string
  finish_reason?: string
  reasoning_content?: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  tool_calls?: any
  // 2026-08-24 (task_1787545088500_6, bug A) — backend SseEventLLMHistory
  // (sse_on_event_send_llm_history.zig:150) sends the assistant row's serialized tool_calls array
  // on the wire as `tool_calls_json`.
  tool_calls_json?: string
  tool_call_id?: string
  tool_name?: string
  agent_name?: string
  loop_index?: number
  temperature?: number
  is_thinking?: boolean
  is_input?: boolean
  is_output?: boolean
  parent_session_id?: string
  parent_id?: string
  // 2026-09-04 subagent-peek fix: progress events (role="subagent_progress")
  // carry the child sid + lifecycle status on the same SseEvent wire.
  // Optional so existing llm_chunk/llm_full payloads are unaffected.
  subagent_session_id?: string
  status?: string
  created_at?: number
  // Legacy type field for compatibility (not used by backend)
  type?: 'chunk' | 'reasoning_chunk' | 'chunk_final' | 'tool_call_delta' | 'connected' | 'full'
  index?: number
  total_tokens?: number
  // Diff view data for text_replace tool
  diffview_before?: string
  diffview_after?: string
  // Pipe-separated image URLs (matches the REST SessionMessageResponse shape and the backend
  // onEventSendLLMHistory payload). Frontend splits on '|' to populate Message.image_urls.
  image_url?: string
  // Pipe-separated video URLs (Migration 090, backend
  // SseEventLLMHistory.video_url). Split on '|' into video_urls.
  video_url?: string
  // Live session skills pushed on the SSE wire (backend: sse_on_event_send_llm_history.zig:45
  // SseEventLLMHistory.session_skills, next to is_error).
  session_skills?: SkillInfo[]
  // True when this event is an agentic-loop diagnostic (retry attempt or TooManyRetries bail)
  // rather than a real chat turn. Backend: sse_on_event_send_llm_history.zig
  // SseEventLLMHistory.is_error — set by workflow.zig's 3 diagnostic sites.
  is_error?: boolean
}

// List all chat sessions with pagination
export async function getChats(
  sortBy: 'created_at' | 'updated_at' | 'session_name' | 'agent' = 'created_at',
  direction: 'asc' | 'desc' = 'desc',
  limit: number = 10,
  cursor?: string,
  // Workspace scope (plan: 2026-09-22-revamp-ui-chats). When set, the backend returns only that
  // workspace's sessions (task-linked + cwd-matched); empty/unknown → empty list (fail-closed).
  // Omitted → global list (back-compat for non-scoped callers).
  workspaceId?: string,
): Promise<{
  sessions: Chat[]
  has_more: boolean
  next_cursor: string | null
  total: number
}> {
  try {
    const params = new URLSearchParams({
      sort_by: sortBy,
      direction: direction,
      limit: limit.toString(),
    })
    if (cursor) {
      params.set('cursor', cursor)
    }
    if (workspaceId) {
      params.set('workspace_id', workspaceId)
    }
    const data = await apiFetch<{
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      sessions: any[]
      has_more?: boolean
      next_cursor?: string | null
      total?: number
    }>(`/llm/session?${params}`)

    // Fix: handle "undefined" or missing session_id in each session
    if (data.sessions && Array.isArray(data.sessions)) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      data.sessions = data.sessions.map((session: any) => {
        const sessionId = session.session_id || session.id
        if (!sessionId || sessionId === 'undefined' || sessionId === 'null') {
          // Generate proper session ID for invalid entries
          const timestamp = new Date()
            .toISOString()
            .replace(/[:-]/g, '')
            .replace('T', '_')
            .replace(/\.\d{3}Z$/, '')
          return {
            session_id: `session_${timestamp}`,
            session_name: session.session_name || session.name || 'New Session',
            status: session.status || 'active',
            created_at: session.created_at || null,
            updated_at: session.updated_at || null,
            cwd: session.cwd || '',
          }
        }
        return {
          session_id: sessionId,
          session_name: session.session_name || session.name || 'New Session',
          status: session.status || 'active',
          created_at: session.created_at || null,
          updated_at: session.updated_at || null,
          cwd: session.cwd || '',
          selected_profile_model: session.selected_profile_model || '',
          sub_agent_name: session.sub_agent_name || '',
          parent_session_id: session.parent_session_id || '',
          // Sidebar git badge — forward the bound worktree path and the per-request resolved branch
          // ("" = no badge). Empty string when absent so the ChatsList `v-if` is a defined check
          // (NOT undefined).
          git_worktree_cwd: session.git_worktree_cwd || '',
          git_branch: session.git_branch || '',
          // Migration 063 — default to "0" (off) when omitted so the
          // ChatsList badge condition `=== '1'` is a defined check.
          // Matches the SQL COALESCE default in llm_history.zig.
          is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
          // Migration 082 — forward the chat-side stamp. Empty string
          // when absent so the ChatsList `?? updated_at` fallback is
          // a defined check (NOT undefined).
          last_human_touched_at: session.last_human_touched_at || '',
          // Migration 104 — pinned sessions. Boolean on the wire;
          // default false so legacy caches read as unpinned.
          is_pinned: session.is_pinned ?? false,
          pinned_position: session.pinned_position ?? 0,
          last_finish_reason: session.last_finish_reason || '',
          // NOT `?? false`: a legacy cache row with no field must read
          // as "no badge", not "reviewed".
          needs_human_review: session.needs_human_review ?? undefined,
        }
      })
    }

    return {
      sessions: data.sessions || [],
      has_more: data.has_more || false,
      next_cursor: data.next_cursor || null,
      total: data.total || 0,
    }
  } catch (e) {
    // The empty-list shape is a deliberate contract (callers render an empty section instead of
    // crashing), but it is indistinguishable from "this scope has no sessions".
    console.error('getChats failed; returning an empty list', e)
    return { sessions: [], has_more: false, next_cursor: null, total: 0 }
  }
}

// Legacy chat functions (kept for compatibility)
export interface ChatLegacy {
  id: string
  label: string
  icon: string
  active?: boolean
}

export async function getChatsLegacy(): Promise<{ chats: ChatLegacy[] }> {
  return await apiFetch<{ chats: ChatLegacy[] }>('/chats')
}

export async function createChat(name: string, icon: string = '💬'): Promise<ChatLegacy> {
  return await apiFetch<ChatLegacy>('/chats', {
    method: 'POST',
    body: { name, icon },
  })
}

export async function deleteChat(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/chats/${id}`, { method: 'DELETE' })
}

// Session API - Fetch session info including cwd. Lightweight detail read: GET /api/llm/session/:id
// returns the sessions row (cwd, profile, worktree binding, PR binding, ...) with NO message
// payload.
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedProfile?: string
  // Migration 091 — resolved sub-agent name (e.g. "implementator").
  subAgentName?: string
  parentSessionId?: string
  // Bound git worktree path (empty string when no worktree is bound;
  // optional because older sessions predate the set_git_worktree tool).
  git_worktree_cwd?: string
  prUrl?: string
  prProvider?: string
  workspaceId?: string | null
}

// In-flight dedupe: AppLayout + ChatView mount concurrently for the same
// session, so two getSession() calls for one id share a single fetch.
const sessionInflight = new Map<string, Promise<Session | null>>()

export async function getSession(sessionId: string): Promise<Session | null> {
  const pending = sessionInflight.get(sessionId)
  if (pending) return pending
  const task = fetchSessionDetail(sessionId)
  sessionInflight.set(sessionId, task)
  try {
    return await task
  } finally {
    if (sessionInflight.get(sessionId) === task) sessionInflight.delete(sessionId)
  }
}

async function fetchSessionDetail(sessionId: string): Promise<Session | null> {
  try {
    // silent: true — AppLayout.fetchChatSessionCwd falls back to a cached
    // cwd on null, so a toast on 404/5xx would be noise.
    const data = await apiFetch<{
      session_id?: string
      name?: string
      cwd?: string
      created_at?: string
      // 2026-08-07-profile-persist-read — extract the per-session selected profile name.
      selected_profile_model?: string
      sub_agent_name?: string
      parent_session_id?: string
      git_worktree_cwd?: string
      pr_url?: string
      pr_provider?: string
      workspace_id?: string | null
    }>(`/llm/session/${encodeURIComponent(sessionId)}`, { silent: true })
    return {
      sessionId: data.session_id || sessionId,
      cwd: data.cwd || '',
      createdAt: data.created_at || '',
      agent: '',
      sessionName: data.name || '',
      // 2026-08-07-profile-persist-read — pass through the persisted profile name. Empty string (=
      // "no profile set" from the backend's COALESCE-on-NULL) is preserved here; ChatView coerces
      // empty → null.
      selectedProfile: data.selected_profile_model,
      subAgentName: data.sub_agent_name,
      parentSessionId: data.parent_session_id,
      git_worktree_cwd: data.git_worktree_cwd,
      prUrl: data.pr_url,
      prProvider: data.pr_provider,
      workspaceId: data.workspace_id,
    }
  } catch (error) {
    console.error('Failed to get session:', error)
    return null
  }
}

// Owning workspace of a session (plan: 2026-09-22-revamp-ui-chats). `GET
// /api/llm/session/:session_id` resolves via the task link first, then the cwd heuristic, and
// returns `workspace_id` (string) or null when the session belongs to no workspace.
export async function getSessionWorkspaceId(sessionId: string): Promise<string | null> {
  if (!sessionId) return null
  try {
    const data = await apiFetch<{ workspace_id?: string | null }>(`/llm/session/${sessionId}`, {
      silent: true,
    })
    return typeof data.workspace_id === 'string' && data.workspace_id.length > 0
      ? data.workspace_id
      : null
  } catch {
    return null
  }
}

// Compact chat session history
export async function compactSession(
  sessionId: string,
): Promise<{ success: boolean; message?: string }> {
  try {
    return await apiFetch<{ success: boolean; message?: string }>(`/session/${sessionId}/compact`, {
      method: 'POST',
    })
  } catch (error) {
    console.error('Failed to compact session:', error)
    return { success: false, message: 'Failed to compact session' }
  }
}

/** Stop/cancel a running LLM session by flipping the worker's `cancelled` flag in the DB. The
 * backend handler (`sessionStopHandler` in `src/ai_workflow/tui/ http_handlers/session_stop.zig`)
 * runs `llm_history.cancelSession` which sets `UPDATE worker SET cancelled = 1 WHERE id = ?`. */
export async function answerAskUser(
  sessionId: string,
  body: {
    question_id?: string
    tool_call_id?: string
    answer?: string
    skip?: boolean
  },
): Promise<{ success: boolean; status?: string; answer?: string; resumed?: boolean }> {
  try {
    return await apiFetch<{ success: boolean; status: string; answer: string; resumed: boolean }>(
      `/llm/session/${sessionId}/answer`,
      { method: 'POST', body },
    )
  } catch (error) {
    // The card renders a Retry affordance; the question row stays `pending`
    // server-side (the endpoint never resumes a run whose answer did not
    // land first), so a retry is safe.
    console.error('Failed to answer ask_user question:', error)
    return { success: false }
  }
}

export async function stopSession(
  sessionId: string,
): Promise<{ success: boolean; session_id?: string }> {
  try {
    return await apiFetch<{ success: boolean; session_id: string }>(
      `/llm/session/${sessionId}/stop`,
      { method: 'POST' },
    )
  } catch (error) {
    console.error('Failed to stop session:', error)
    return { success: false }
  }
}

// Worker API
export interface Worker {
  id: string
  session_id: string
  working_directory: string | null
  /** Unix SECONDS of the last heartbeat, as a numeric string. The backend selects
   * `w.last_activity_nano AS last_activity` and every `Row.values` entry is a `[]u8`, so the column
   * is serialised as a JSON string even though the underlying column is INTEGER. */
  last_activity: string | null
  last_activity_description: string | null
  created_at: string | null
  status: string
  is_running: boolean
  queue_count: number
}

export async function getWorkers(
  status?: string,
  limit = 50,
  sessionId?: string,
): Promise<{ workers: Worker[]; count: number }> {
  const params = new URLSearchParams({ limit: limit.toString() })
  if (status) params.set('status', status)
  if (sessionId) params.set('session_id', sessionId)
  return await apiFetch<{ workers: Worker[]; count: number }>(`/workers?${params}`)
}

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  itemType: string = 'folder',
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items`, {
    method: 'POST',
    body: { name, path, item_type: itemType },
  })
}

/** Create a new design workspace item (`item_type='design'`). The `path` is REQUIRED because design
 * elements live as HTML files under `<path>/.pabrik/design/...` (the model layer rejects
 * element-add with `ItemPathMissing` if path is NULL — see design_model.zig). */
export async function createDesign(
  workspaceId: string,
  name: string,
  path: string,
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items/design`, {
    method: 'POST',
    body: { name, path },
  })
}

export async function deleteWorkspaceItem(
  workspaceId: string,
  itemId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/${workspaceId}/items/${itemId}`, {
    method: 'DELETE',
  })
}

// Kanban API Backend endpoints (Chunk 3 of the workspace-item-kanban plan): POST
// /api/workspaces/:wsId/items/kanban → 201 GET /api/workspaces/:wsId/items/:itemId/kanban/columns →
// 200 POST /api/workspaces/:wsId/items/:itemId/kanban/columns → 201 PATCH.
export async function createKanban(
  workspaceId: string,
  name: string,
  path?: string,
): Promise<{ item: WorkspaceItem; columns: KanbanColumn[] }> {
  return await apiFetch<{ item: WorkspaceItem; columns: KanbanColumn[] }>(
    `/workspaces/${workspaceId}/items/kanban`,
    {
      method: 'POST',
      body: { name, path: path ?? '' },
    },
  )
}

/** Update a workspace item. Supports partial updates — pass only the fields you want to change.
 * Fields: - `item_type`: new type (kanban / folder / chat / memory). */
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: {
    item_type?: string
    path?: string | null
    name?: string
  },
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items/${itemId}`, {
    method: 'PUT',
    body: data,
  })
}

/**  * List the kanban columns for a single workspace item, ordered by `position` ASC. GET
 * /api/workspaces/:workspaceId/items/:itemId/kanban/columns */
export async function listKanbanColumns(
  workspaceId: string,
  itemId: string,
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
  )
}

/** Add a new column to a kanban. `position` is optional — when omitted the backend appends at the
 * end of the existing sequence (max(position)+1). Returns the newly-created column (with its
 * server-assigned `id` and `position`). */
export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
  position?: number,
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(`/workspaces/${workspaceId}/items/${itemId}/kanban/columns`, {
    method: 'POST',
    body: { name, description: description ?? '', position },
  })
}

/** Copy a kanban's column spec (names + descriptions, preserving order) from a source kanban to a
 * target kanban. Tasks are NOT copied — only the column "template". */
export async function copyKanbanSpec(
  workspaceId: string,
  targetItemId: string,
  sourceItemId: string,
  mode: 'replace' | 'append' = 'replace',
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${targetItemId}/kanban/copy_spec_from/${sourceItemId}`,
    {
      method: 'POST',
      body: { mode },
    },
  )
}

/** Patch a kanban column. Both `name` and `position` are optional; pass only the fields you want to
 * change. The backend applies the patch and re-numbers sibling positions when `position` changes.
 * Returns the FULL updated board (`{columns, count}`) — same envelope as `listKanbanColumns`. */
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number; is_done?: boolean },
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}

/** Delete a kanban column. Tasks in the column are unassigned (kanban_column_id set to NULL) — they
 * remain visible in the folder-list view as "Unassigned". Idempotent: a 200 is returned whether the
 * column existed or not (handled by the backend). */
export async function deleteKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    { method: 'DELETE' },
  )
}

/** Move a task to a new column and position within that column. The backend's `moveTask` does the
 * move + sibling re-numbering in a single transaction. */
export async function moveTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  columnId: string,
  position: number,
  force?: boolean,
): Promise<Task> {
  // `force` rides the body only when truthy — the backend
  // defaults it to false, so omitting keeps old payloads intact.
  const body: Record<string, unknown> = { column_id: columnId, position }
  if (force) body.force = true
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/move`, {
    method: 'PATCH',
    body,
  })
}

/** Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md */
export interface KanbanTagSuggestion {
  name: string
  count: number
  last_used_at: string | null
}

export interface KanbanTagSuggestionsResponse {
  tags: KanbanTagSuggestion[]
  has_more: boolean
}

export interface GetKanbanTagSuggestionsOptions {
  limit?: number
  offset?: number
}

export async function getKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: GetKanbanTagSuggestionsOptions,
): Promise<KanbanTagSuggestionsResponse> {
  const limit = options?.limit ?? 8
  const offset = options?.offset ?? 0
  // Defensive: empty args = no-op (returns empty + has_more=false).
  // Prevents 400s when the caller passes placeholder values during
  // the render tick (e.g. dialog opens before column is resolved).
  if (!workspaceId || !itemId) {
    return { tags: [], has_more: false }
  }
  const url = `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/kanban/tags?limit=${limit}&offset=${offset}`
  // Graceful degradation: a 5xx returns empty + has_more=false so a
  // broken server doesn't block the user from typing tags.
  try {
    const res = await apiFetch<KanbanTagSuggestionsResponse>(url, { method: 'GET' })
    return {
      tags: res.tags ?? [],
      has_more: res.has_more ?? false,
    }
  } catch {
    return { tags: [], has_more: false }
  }
}

// ===================================================================== Design Mode API (v6.
export async function listDesignPages(
  workspaceId: string,
  itemId: string,
): Promise<{ pages: DesignPage[]; count: number }> {
  return await apiFetch<{ pages: DesignPage[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages`,
  )
}

/**  * POST /api/workspaces/:workspaceId/items/:itemId/design/pages Create a new design page. The
 * backend assigns `id`, `position`, `created_at`, `updated_at`. The new page is appended at the end
 * of the current position order. Returns 201 Created with the full DesignPage record. */
export async function createDesignPage(
  workspaceId: string,
  itemId: string,
  name: string,
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(`/workspaces/${workspaceId}/items/${itemId}/design/pages`, {
    method: 'POST',
    body: { name },
  })
}

/** PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Update an existing design
 * page. */
export async function updateDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
  patch: { width: number; height: number; name?: string },
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'PATCH', body: patch },
  )
}

/**  * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Fetch a single page plus its
 * full element list (HTML bodies EXCLUDED — fetch lazily via `getDesignElementHtml` as the user
 * selects each element, to keep the list-page payload small for designs with many elements). */
export async function getDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ page: DesignPage; elements: DesignElement[] }> {
  return await apiFetch<{ page: DesignPage; elements: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements Add a new element
 * to a page. Required body fields: `name`, `type`, `html`. */
export async function addDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: {
    name: string
    type: DesignElementType
    html: string
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    [k: string]: any
  },
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements`,
    { method: 'POST', body },
  )
}

/** PUT /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId Full
 * update of an element. The body shape is `Partial<DesignElement>` — any subset of fields can be
 * patched. The backend applies the patch as a sparse merge (omitted fields left unchanged). */
export async function updateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  patch: Partial<DesignElement>,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'PUT', body: patch },
  )
}

/** Wire shape for `POST .../design/pages/:pageId/elements/group`. NEW (Chunk 5 of grouped-layers
 * plan). Body fields: - `child_ids`: required, 2+ element ids on the SAME page. */
export interface GroupDesignElementsRequest {
  child_ids: string[]
  name?: string
  type?: 'group' | 'frame'
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/group NEW (Chunk 5
 * of grouped-layers plan). Wraps 2+ elements into a new `group` (or `frame`) parent at the union
 * bbox of the children. */
export async function groupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: GroupDesignElementsRequest,
): Promise<{ parent: DesignElement; children: DesignElement[] }> {
  return await apiFetch<{ parent: DesignElement; children: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/group`,
    { method: 'POST', body },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reorder NEW (Chunk
 * 5 of right-click group menu plan). Reorders 1+ elements on a page along the z-axis. */
export type ReorderMode = 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'

export interface ReorderDesignElementsRequest {
  mode: ReorderMode
  element_ids: string[]
}

export async function reorderDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReorderDesignElementsRequest,
): Promise<{ reordered: DesignElement[] }> {
  return await apiFetch<{ reordered: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reorder`,
    { method: 'POST', body },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reparent-batch NEW
 * (Chunk 1b of drag-to-reparent plan). Atomic N-element reparent in a single transaction. */
export interface ReparentDesignElementsBatchRequest {
  element_ids: string[]
  /** null = top-level (leave any current group). */
  new_parent_id: string | null
  /** Currently only "last_in_parent" is supported. */
  reposition: 'last_in_parent'
}

export interface ReparentDesignElementsBatchResponse {
  updated: DesignElement[]
}

export async function reparentDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReparentDesignElementsBatchRequest,
): Promise<ReparentDesignElementsBatchResponse> {
  return await apiFetch<ReparentDesignElementsBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reparent-batch`,
    { method: 'POST', body },
  )
}

/** DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId
 * Idempotent delete. */
export async function deleteDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'DELETE' },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/ungroup Dissolve a
 * `group` or `frame` element: reparent its direct children to the group's parent (or top-level if
 * the group had no parent), then delete the group row. */
export async function ungroupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ orphaned: DesignElement[] }> {
  return await apiFetch<{ orphaned: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/ungroup`,
    { method: 'POST', body: { element_id: elementId } },
  )
}

/** DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Delete a design page. */
export async function deleteDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'DELETE' },
  )
}

/**  * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 * Lazy-load a single element's HTML body. Used by the iframe preview component as the user selects
 * elements — avoids loading all bodies up-front in the page+elements GET response. */
export async function getDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ html: string }> {
  return await apiFetch<{ html: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
  )
}

/** PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 * Persist a new HTML body for an element. Triggered by the contenteditable / Monaco save flow — the
 * content is the user- edited inner HTML of the element's iframe. */
export async function updateDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  html: string,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
    { method: 'PATCH', body: { html } },
  )
}

/** PATCH
 * /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/geometry ⚠️
 * DEPRECATED — replaced by `translateDesignElement` (move) and `resizeDesignElement` (resize). */
export async function updateDesignElementGeometry(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/geometry`,
    { method: 'PATCH', body: geometry },
  )
}

/** POST
 * /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/translate NEW
 * (2026-08-06) — single-element translate (move). */
export async function translateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  dx: number,
  dy: number,
): Promise<{ updated: DesignElement[] }> {
  return await apiFetch<{ updated: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/translate`,
    { method: 'POST', body: { dx, dy } },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/resize
 * NEW (2026-08-06) — single-element resize. The body carries absolute `(x, y, width, height,
 * rotation?)` fields. At least one field is required. */
export async function resizeDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/resize`,
    { method: 'POST', body: geometry },
  )
}

/**  * Per-element geometry patch for the batch endpoint. All fields are optional; null means "leave
 * unchanged". Mirror of the single `updateDesignElementGeometry` shape but reusable for N elements. */
export interface GeometryBatchUpdate {
  element_id: string
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/** Response from `POST .../geometry-batch`. `updated` is the
 * post-batch element list in input order. */
export interface GeometryBatchUpdateResponse {
  updated: DesignElement[]
}

/** Atomic N-element geometry update. Used by the canvas drag handler when multiple elements are
 * selected (multi-element drag, group / frame being moved) so the N per-element PATCHes collapse
 * into ONE PATCH per pointermove. */
export async function updateDesignElementsGeometryBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  updates: GeometryBatchUpdate[],
): Promise<GeometryBatchUpdateResponse> {
  return await apiFetch<GeometryBatchUpdateResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/geometry-batch`,
    { method: 'POST', body: { updates } },
  )
}

/** Server-side cascade move. Each item's `(dx, dy)` applies to the element AND every transitive
 * descendant of that element via a single recursive CTE inside one SQL transaction. */
export interface MoveBatchItem {
  element_id: string
  /** Translation delta in CSS px. Cascades to descendants. */
  dx: number
  dy: number
  /** Optional. Applies ONLY to the element_id (not descendants). */
  width?: number
  height?: number
  rotation?: number
}

export interface MoveBatchInput {
  items: MoveBatchItem[]
}

export interface MoveBatchResponse {
  updated: DesignElement[]
}

export async function moveDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  input: MoveBatchInput,
): Promise<MoveBatchResponse> {
  return await apiFetch<MoveBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/move-batch`,
    { method: 'POST', body: input },
  )
}

/** Move an element to a different page in the same design item. Mirrors the backend `POST
 * .../elements/:element_id/move-to-page` endpoint. Changes the element's `page_id` (and `position`
 * on the target page) instead of `x`/`y`. */
export interface MoveElementToPageInput {
  /** REQUIRED. The destination page id. Must be on the same design item. */
  new_page_id: string
  /** Default true. When true, every transitive descendant moves too. */
  apply_to_children?: boolean
}

export interface MoveElementToPageResponse {
  updated: DesignElement[]
}

export async function moveDesignElementToPage(
  workspaceId: string,
  itemId: string,
  sourcePageId: string,
  elementId: string,
  input: MoveElementToPageInput,
): Promise<MoveElementToPageResponse> {
  return await apiFetch<MoveElementToPageResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${sourcePageId}/elements/${elementId}/move-to-page`,
    { method: 'POST', body: input },
  )
}

// Skills API A skill is a ROW scoped to one workspace, and that scope is its whole identity: no
// `is_global`, no `cwd`, no `path`. A skill wanted in two workspaces is two rows.
export interface Skill {
  name: string
  description: string
  /** False = the human pinned this skill: every agent write tool refuses it. */
  is_can_auto_improve: boolean
}

export interface SkillDetail {
  name: string
  description: string
  content: string
  /**    * Companion files stored beside the body (`scripts/…`, `references/…`). `use_skill` materialises
   * them into a temp directory so the body's relative references resolve, so a bundled skill is
   * more than its one row. Zero for a plain single-file skill. */
  asset_count: number
  /** False = the human pinned this skill: every agent write tool refuses it. */
  is_can_auto_improve: boolean
}

export interface SkillListResponse {
  skills: Skill[]
}

export interface SkillDeleteResponse {
  success: boolean
  skill_name: string
  /** `''` on success; the reason on a refusal. */
  error_message: string
}

/** GET /api/workspaces/:workspaceId/skills */
export async function getSkills(workspaceId: string): Promise<SkillListResponse> {
  return await apiFetch<SkillListResponse>(`/workspaces/${encodeURIComponent(workspaceId)}/skills`)
}

/** GET /api/workspaces/:workspaceId/skills/:skillName */
export async function getSkillDetail(
  workspaceId: string,
  skillName: string,
): Promise<{ skill: SkillDetail | null; error_message: string }> {
  return await apiFetch<{ skill: SkillDetail | null; error_message: string }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
  )
}

/** DELETE /api/workspaces/:workspaceId/skills/:skillName */
export async function deleteSkill(
  workspaceId: string,
  skillName: string,
): Promise<SkillDeleteResponse> {
  return await apiFetch<SkillDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
    { method: 'DELETE' },
  )
}

export interface SkillCreateResponse {
  skill: SkillDetail
}

/** POST /api/workspaces/:workspaceId/skills 201 with the stored row, so the caller can render what
 * it just wrote without a second GET. */
export async function createSkill(
  workspaceId: string,
  input: { name: string; description?: string; content?: string; is_can_auto_improve?: boolean },
): Promise<SkillCreateResponse> {
  return await apiFetch<SkillCreateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills`,
    { method: 'POST', body: input },
  )
}

export interface SkillUpdateResponse {
  skill: SkillDetail
}

/** PATCH /api/workspaces/:workspaceId/skills/:skillName The name is a path param and is IMMUTABLE:
 * a rename would break every `use_skill({ name })` call and every cached `skill_eval` verdict. */
export async function updateSkill(
  workspaceId: string,
  skillName: string,
  input: { description?: string; content?: string; is_can_auto_improve?: boolean },
): Promise<SkillUpdateResponse> {
  return await apiFetch<SkillUpdateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
    { method: 'PATCH', body: input },
  )
}

// Memories API
export interface Memory {
  name: string
  title: string
  path: string
  size: number
}

export interface MemoryDetail extends Memory {
  content: string
}

export interface MemoryDetailResponse {
  memory: MemoryDetail | null
  error_message: string | null
}

export interface MemoryDeleteResponse {
  success: boolean
  name: string
  error_message: string | null
}

export async function getMemories(): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>('/memories')
}

export async function getMemoryDetail(name: string): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(`/memories/${encodeURIComponent(name)}`)
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses the returned shape to decide
    // whether to show a "create new memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original { memory: null, error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/memories', {
    method: 'POST',
    body: { name, content },
  })
}

export async function updateMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(`/memories/${encodeURIComponent(name)}`, {
    method: 'PUT',
    body: { content },
  })
}

export async function deleteMemory(name: string): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(`/memories/${encodeURIComponent(name)}`, {
    method: 'DELETE',
  })
}

// Local Memories API (per-cwd memories at `<cwd>/.pabrik/memories/`).
/** Build the `cwd` query string for a local-memory request.
 * Returns the `?cwd=...` suffix, or `''` if `cwd` is empty. */
function cwdQuery(cwd?: string): string {
  if (!cwd) return ''
  const encoded = encodeURIComponent(cwd)
  return `?cwd=${encoded}`
}

export async function listLocalMemories(cwd?: string): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>(`/local-memories${cwdQuery(cwd)}`)
}

export async function getLocalMemoryDetail(
  name: string,
  cwd?: string,
): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(
      `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    )
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses the returned shape to decide
    // whether to show a "create new memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original { memory: null, error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createLocalMemory(
  name: string,
  content: string,
  cwd: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/local-memories', {
    method: 'POST',
    body: { name, content, cwd },
  })
}

export async function updateLocalMemory(
  name: string,
  content: string,
  cwd?: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    {
      method: 'PUT',
      body: { content, cwd },
    },
  )
}

export async function deleteLocalMemory(name: string, cwd?: string): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    { method: 'DELETE' },
  )
}

// Git Status API
export interface GitStatus {
  is_git_repo: boolean
  branch: string
  has_changes: boolean
  is_clean: boolean
  current: string
  status: string
}

export interface GitFileChange {
  index_status: string
  worktree_status: string
  path: string
}

export interface GitChangesResponse {
  is_git_repo: boolean
  branch: string | null
  has_changes: boolean
  staged_files: GitFileChange[]
  modified_files: GitFileChange[]
  untracked_files: GitFileChange[]
}

export async function getGitStatus(cwd: string): Promise<GitStatus> {
  try {
    const status = await apiFetch<GitStatus>(`/git/status?path=${encodeURIComponent(cwd)}`)
    writeGitStatusCache(cwd, status)
    return status
  } catch {
    // Stale-while-revalidate: a failed refresh falls back to the last-known status for this cwd so
    // the branch chip keeps showing something real instead of blanking on a transient backend
    // error.
    return (
      readGitStatusCache(cwd) ?? {
        is_git_repo: false,
        branch: '',
        has_changes: false,
        is_clean: true,
        current: '',
        status: 'error',
      }
    )
  }
}

export async function getGitChanges(cwd: string): Promise<GitChangesResponse> {
  try {
    return await apiFetch<GitChangesResponse>(`/git/changes?path=${encodeURIComponent(cwd)}`)
  } catch {
    // Return non-repo status on error (apiFetch also fires a toast
    // notification on non-2xx; the empty status fallback ensures the
    // UI doesn't crash while the user sees the error).
    return {
      is_git_repo: false,
      branch: null,
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    }
  }
}

// Git blame — per-line author + commit time for one file, backing the
// CodeEditor's inline blame annotation.
export interface GitBlameLine {
  line: number
  commit: string
  author: string
  author_time: number
  summary: string
}

export interface GitBlameResponse {
  is_git_repo: boolean
  lines: GitBlameLine[]
}

/** The blame fetch failed — transport or non-2xx. */
export class GitBlameError extends Data.TaggedError('GitBlameError')<{
  readonly cwd: string
  readonly file: string
  readonly reason: string
}> {}

/** The blame endpoint, WITH the failure in the type — no `try`/`catch`
 * (AGENTS.md, "Frontend — No `try`/`catch` in the desktop app"). */
export function fetchGitBlameEffect(
  cwd: string,
  filePath: string,
): Effect.Effect<GitBlameResponse, GitBlameError> {
  return Effect.tryPromise({
    try: () =>
      apiFetch<GitBlameResponse>(
        `/git/blame?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
        { silent: true },
      ),
    catch: (cause) =>
      new GitBlameError({ cwd, file: filePath, reason: describeCause(Cause.fail(cause)) }),
  })
}

/**  * Best-effort blame: a failure yields null (the file paints without chips) on the Effect seam, so
 * no `try`/`catch` sits between the failure and the value. The reason is logged, not discarded. */
export function getGitBlame(cwd: string, filePath: string): Promise<GitBlameResponse | null> {
  return Effect.runPromise(
    fetchGitBlameEffect(cwd, filePath).pipe(
      Effect.catchAll((error) => {
        console.log(error)
        return Effect.succeed(null)
      }),
    ),
  )
}

// Git worktree info — used by the "Create a PR" dialog to pre-fill the form.
export interface GitWorktreeInfo {
  is_git_repo: boolean
  branch: string
  last_commit_sha: string
  last_commit_msg: string
  default_base: string
  commits_ahead: number
  diff_summary: string
  draft_title: string
  draft_body: string
}

export async function getGitWorktreeInfo(
  worktreePath: string,
  base?: string,
): Promise<GitWorktreeInfo> {
  try {
    const params = new URLSearchParams({ path: worktreePath })
    if (base && base.trim() !== '') {
      params.set('base', base)
    }
    return await apiFetch<GitWorktreeInfo>(`/git/worktree/info?${params}`)
  } catch (error) {
    console.error('Failed to get git worktree info:', error)
    return {
      is_git_repo: false,
      branch: '',
      last_commit_sha: '',
      last_commit_msg: '',
      default_base: base || 'main',
      commits_ahead: 0,
      diff_summary: '',
      draft_title: '',
      draft_body: '',
    }
  }
}

// Open a PR/MR in the worktree path via the forge CLI (`gh pr create` or
// `glab mr create`). The backend runs the command and returns the URL.
export interface GitPrCreateResponse {
  success: boolean
  pr_url: string
  // Renamed from `error_message` per PR review (git_pr_create.zig:60). The Zig struct field is
  // `@"error"` (because `error` is a Zig keyword) and serializes to JSON `"error"`. This frontend
  // field name matches the JSON wire format.
  error: string
  // Which forge the PR/MR was opened on. Absent on older servers.
  provider?: string
}

/** Open a PR/MR on `worktreePath`. */
export async function createGitPr(
  worktreePath: string,
  base: string,
  title: string,
  body: string,
  opts?: { provider?: string },
): Promise<GitPrCreateResponse> {
  return await apiFetch<GitPrCreateResponse>('/git/pr', {
    method: 'POST',
    body: {
      worktree_path: worktreePath,
      base,
      title,
      body,
      provider: opts?.provider || '',
    },
  })
}

// ─── Git branches (kanban worktree base-branch picker) ──────────────────── Wire shape for `GET
// /api/git/branches?path=<repo>`. Feeds the "New task" dialog's base-branch dropdown so a fresh
// worktree can branch from e.g. `origin/main` instead of whatever the repo's current HEAD is.
export interface GitBranchEntry {
  /** Short ref name, e.g. `origin/main` or `main`. This is the exact
   *  string baked into the create-task message's `Base:` line. */
  name: string
  /** True for a remote-tracking ref (`origin/...`). */
  is_remote: boolean
  /** True for the repo's currently checked-out branch (`''` in a bare
   *  repo / detached HEAD — no row is highlighted). */
  is_current: boolean
  /** True for the detected default base (`origin/main` → … ). The
   *  component uses this to preselect a sensible value. */
  is_default: boolean
}

export interface GitBranchesResponse {
  is_git_repo: boolean
  current_branch: string
  branches: GitBranchEntry[]
}

/** List the local + remote-tracking branches of the repo at `repoPath`. */
export async function listGitBranches(repoPath: string): Promise<GitBranchesResponse> {
  const empty: GitBranchesResponse = {
    is_git_repo: false,
    current_branch: '',
    branches: [],
  }
  const path = (repoPath ?? '').trim()
  if (path === '') return empty
  try {
    const params = new URLSearchParams({ path })
    return await apiFetch<GitBranchesResponse>(`/git/branches?${params}`)
  } catch (error) {
    console.error('Failed to list git branches:', error)
    return empty
  }
}

// ─── Git commits (read-only lazygit-style history) ──────────────────────── Wire shape for `GET
// /api/git/commits?path=<repo>[&limit=][&skip=]` and `GET /api/git/commit?path=<repo>&sha=<sha>`.
// Read-only: list + detail, no checkout/amend/rebase.
export interface GitCommit {
  sha: string
  short_sha: string
  author: string
  email: string
  /** Unix timestamp (seconds). */
  timestamp: number
  subject: string
  body: string
}

export interface GitCommitsResponse {
  is_git_repo: boolean
  branch: string
  /** Best-effort `rev-list --count HEAD` (0 when unresolvable). */
  total_count: number
  commits: GitCommit[]
}

export async function getGitCommits(
  cwd: string,
  limit = 100,
  skip = 0,
): Promise<GitCommitsResponse> {
  const empty: GitCommitsResponse = {
    is_git_repo: false,
    branch: '',
    total_count: 0,
    commits: [],
  }
  const path = (cwd ?? '').trim()
  if (path === '') return empty
  try {
    const params = new URLSearchParams({ path })
    params.set('limit', String(limit))
    params.set('skip', String(skip))
    return await apiFetch<GitCommitsResponse>(`/git/commits?${params}`)
  } catch (error) {
    console.error('Failed to list git commits:', error)
    return empty
  }
}

export interface GitCommitFile {
  status: string
  path: string
}

export interface GitCommitDetail extends GitCommit {
  files: GitCommitFile[]
}

export async function getGitCommitDetail(
  cwd: string,
  sha: string,
): Promise<GitCommitDetail | null> {
  const path = (cwd ?? '').trim()
  const ref = (sha ?? '').trim()
  if (path === '' || ref === '') return null
  try {
    const params = new URLSearchParams({ path, sha: ref })
    return await apiFetch<GitCommitDetail>(`/git/commit?${params}`)
  } catch (error) {
    console.error('Failed to load git commit detail:', error)
    return null
  }
}

export interface GitCommitFileDiff {
  sha: string
  path: string
  diff_content: string
}

/**  * Unified diff of one file at one commit (`git diff <sha>^ <sha>`, root-commit fallback via `git
 * show`). Powers the clickable file rows in the commits view. Returns null on any failure so the
 * row can show an inline error instead of crashing. */
export async function getGitCommitFileDiff(
  cwd: string,
  sha: string,
  file: string,
): Promise<GitCommitFileDiff | null> {
  const path = (cwd ?? '').trim()
  const ref = (sha ?? '').trim()
  const target = (file ?? '').trim()
  if (path === '' || ref === '' || target === '') return null
  try {
    const params = new URLSearchParams({ path, sha: ref, file: target })
    return await apiFetch<GitCommitFileDiff>(`/git/commit/file?${params}`)
  } catch (error) {
    console.error('Failed to load git commit file diff:', error)
    return null
  }
}

// File listing for autocomplete
export async function listFiles(cwd: string, dirPath?: string): Promise<string[]> {
  try {
    const targetPath = dirPath || cwd
    const data = await apiFetch<{ entries: FolderEntry[] }>(
      `/system/folder?path=${encodeURIComponent(targetPath)}&action=list${workspaceQuery()}`,
    )
    // Return names sorted, directories first
    const entries = data.entries || []
    return entries
      .map((e: FolderEntry) => e.name)
      .sort((a: string, b: string) => {
        const aIsDir = entries.find((e: FolderEntry) => e.name === a)?.is_directory
        const bIsDir = entries.find((e: FolderEntry) => e.name === b)?.is_directory
        if (aIsDir && !bIsDir) return -1
        if (!aIsDir && bIsDir) return 1
        return a.localeCompare(b)
      })
  } catch (error) {
    console.error('Failed to list files:', error)
    return []
  }
}

// Session event types for SSE subscription
export interface SessionEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  name: string
  status: string
  cwd: string
  created_at: string
  updated_at: string
  selected_profile_model?: string
  // Mirrors `git_worktree_cwd` on the Session interface: empty
  // string when no worktree is bound, omitted for events that don't
  // carry session fields (e.g. delete).
  git_worktree_cwd?: string
  // Mirrors sessions.is_auto_retry_until_stop (Migration 063). Only present on 'updated' events
  // where the session row carries the flag.
  is_auto_retry_until_stop?: string
  // Migration 082 — the touched POST's SSE echo carries the fresh stamp (unix-ms integer string,
  // raw column shape — NOT the SQLite datetime the REST list returns). Optional: older backends
  // omit it. ChatsList uses it only for echo detection, never for display.
  last_human_touched_at?: string
}

// Queue messages SSE event types
export type QueueMessageEvent =
  | {
      action: 'queued'
      id: string
      message: string
      image_url?: string
      video_url?: string
      session_id: string
    }
  | {
      action: 'deleted'
      id: string
      session_id: string
    }

// Background-process lifecycle SSE event (see src/agentic_loop/background_process_events.zig). Both
// granular wire names (`background_process_created` / `background_process_completed`) share this
// payload; the consumer filters by `session_id` and re-fetches the list.
export interface BackgroundProcessEvent {
  action: 'created' | 'completed'
  session_id: string
  pid: number
  command: string
}

// Skill-eval lifecycle SSE event (see src/agentic_loop/skill_eval_events.zig). All three granular
// wire names (`skill_evals_run_started` / `_run_finished` / `_result_applied`) share this payload;
// the consumer filters by `session_id` and re-fetches the eval list for the Evals tab.
export interface SkillEvalEvent {
  action: 'run_started' | 'run_finished' | 'result_applied'
  run_id: string
  session_id: string
  evaluated: number
  result_id: string
}

// File stage/unstage SSE event (see src/agentic_loop/git_file_stage_events.zig).
export interface GitFileStageEvent {
  action: 'staged' | 'unstaged'
  /** Repo-relative path that moved. */
  path: string
  /** The worktree the git command ran in. */
  cwd: string
  /** True when git failed for this path — the row must NOT move. */
  failed: boolean
}

// Change-request state SSE event (see src/agentic_loop/git_pr_state_events.zig).
export interface GitPrStateEvent {
  action: 'merged' | 'closed'
  /** The worktree the forge command ran in. */
  cwd: string
  /** The change request's head branch (`head_ref`). */
  branch: string
}

// ─── Skill Evals read surface (GET /api/skill-evals/*) ──────────────────
export interface SkillEvalRun {
  id: string
  session_id: string
  status: string
  trigger: string
  scope: string
  skill_name: string
  error: string
  total_tokens: number
  created_at: string
}

export interface SkillEvalResult {
  id: string
  skill_name: string
  skill_key: string
  status: string
  verdict: string
  freshness: number
  accuracy: number
  duplication: number
  rationale: string
  /** A JSON *string* (the stored array) — parse it before use. */
  missing_paths: string
  /** Whether the intrinsic half came from the shared fact cache. */
  shared_fact: boolean
  applied: boolean
  apply_action: string
}

export interface SkillEvalsRunsResponse {
  runs: SkillEvalRun[]
  results: SkillEvalResult[]
}

export interface SkillEvalsSummaryResponse {
  counts: { verdict: string; n: number }[]
  total: number
}

export async function getSkillEvalsRuns(
  params: {
    run_id?: string
    session_id?: string
    limit?: number
  } = {},
): Promise<SkillEvalsRunsResponse> {
  const q = new URLSearchParams()
  if (params.run_id) q.set('run_id', params.run_id)
  if (params.session_id) q.set('session_id', params.session_id)
  if (params.limit !== undefined) q.set('limit', String(params.limit))
  const suffix = q.toString() ? `?${q.toString()}` : ''
  return await apiFetch<SkillEvalsRunsResponse>(`/skill-evals/runs${suffix}`)
}

export async function getSkillEvalsSummary(sessionId = ''): Promise<SkillEvalsSummaryResponse> {
  const suffix = sessionId ? `?session_id=${encodeURIComponent(sessionId)}` : ''
  return await apiFetch<SkillEvalsSummaryResponse>(`/skill-evals/summary${suffix}`)
}

/** Record that a human accepted a verdict. `result_id` is a QUERY parameter, not a path segment —
 * the backend keeps every route under this prefix a literal so no `:param` route can shadow a later
 * one. */
export async function applySkillEvalResult(
  resultId: string,
  action = 'apply',
): Promise<{
  result_id: string
  skill_name: string
  action: string
  applied: boolean
  message: string
}> {
  const q = new URLSearchParams({ result_id: resultId, action })
  return await apiFetch(`/skill-evals/results/apply?${q.toString()}`, { method: 'POST' })
}

// GET queued messages
export interface QueuedMessage {
  id: string
  message: string
}

export async function getQueuedMessages(sessionId: string): Promise<{
  messages: QueuedMessage[]
  count: number
}> {
  return await apiFetch<{ messages: QueuedMessage[]; count: number }>(
    `/llm/session/${sessionId}/queue_messages`,
  )
}

// 2026-09-02 stream-resume-on-reselect (task_1787673548905_0) — in-flight stream snapshot.
export interface StreamSnapshot {
  active: boolean
  content: string
}

export async function getStreamSnapshot(sessionId: string): Promise<StreamSnapshot> {
  return await apiFetch<StreamSnapshot>(`/llm/session/${sessionId}/stream`)
}

// 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1) — live spawn-batch snapshot.
export interface SubAgentProgressSnapshotRow {
  agent_name: string
  status: 'launched' | 'completed' | 'failed'
  agent_index: number
  total_agents: number
  /** "" when the sub-agent session is not yet known (frontend
   * normalizes to undefined, same as the omitted live-SSE field). */
  subagent_session_id: string
  elapsed_ms: number
}

export interface SubAgentProgressSnapshot {
  tool_call_id: string
  progress: SubAgentProgressSnapshotRow[]
}

export async function getSubAgentProgress(toolCallId: string): Promise<SubAgentProgressSnapshot> {
  return await apiFetch<SubAgentProgressSnapshot>(
    `/subagent/progress/${encodeURIComponent(toolCallId)}`,
  )
}

// Workers SSE event types
export interface WorkerEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  session_id: string
  working_directory: string
  last_activity: number
  last_activity_description: string
  created_at: string
}

// Kanban SSE event types
// (see src/ai_workflow/tui/on_event_sent_kanban.zig on the backend).
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_description?: string | null
  new_position?: number | null
}

export interface KanbanTaskEvent {
  // Backend's full action enum (on_event_sent_kanban.zig KanbanTaskAction). Added in the
  // sse-kanban-move-duplicate-task plan (2026-08-06).
  action: 'assigned' | 'moved' | 'unassigned' | 'human_touched'
  workspace_id: string
  item_id: string
  task_id: string
  new_column_id?: string | null
  new_position?: number | null
  // After-action review state — present ONLY on `human_touched` events (task_mark_human_touched.zig
  // sends `false`; null on assigned/moved/unassigned).
  needs_human_review?: boolean | null
}

export interface DocumentEvent {
  // Backend's action enum (src/agentic_loop/document_events.zig).
  action: 'created' | 'updated' | 'deleted'
  workspace_id: string
  document_id: string
  // The title AFTER the mutation; `''` when the mutation did not read the row back.
  title: string
}

/** Unified SSE channel options. Each property is a per-channel callback. Only the keys present in
 * `channels` are subscribed on the backend (passed as the `?channels=` query param). */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  /** Subscribe to background-process lifecycle events. The backend emits two granular names
   * (`background_process_created` on spawn, `background_process_completed` on exit) that share the
   * same `BackgroundProcessEvent` payload. */
  backgroundProcess?: (event: BackgroundProcessEvent) => void
  /** Subscribe to skill-eval lifecycle events. The backend emits three granular names
   * (`skill_evals_run_started`, `skill_evals_run_finished`, `skill_evals_result_applied`) that
   * share the same `SkillEvalEvent` payload. */
  skillEvals?: (event: SkillEvalEvent) => void
  /** Subscribe to file stage/unstage events. The backend emits two granular names
   * (`git_file_staged` on `git add`, `git_file_unstaged` on `git restore --staged`) that share the
   * same `GitFileStageEvent` payload. */
  gitFileStage?: (event: GitFileStageEvent) => void
  /** Subscribe to change-request state events. */
  gitPrState?: (event: GitPrStateEvent) => void
  /** Subscribe to document mutations. The backend emits three granular names (`document_created`,
   * `document_updated`, `document_deleted`) sharing one `DocumentEvent` payload. Only an agent tool
   * emits these, so a tab never receives an echo of its own UI edit. */
  documents?: (event: DocumentEvent) => void
  /** Subscribe to design-mode element mutations. The backend emits three granular event names
   * (`design_element_created`, `design_element_updated`, `design_element_deleted`) that share the
   * same `DesignElementEvent` payload (the `action` discriminator tells them apart). */
  design?: (event: DesignElementEvent) => void
  /** Subscribe to LLM streaming events. When `sessionId` is provided, the factory sends `llm:<sid>`
   * (per-session routing — used by any future caller that wants server-side filtering). */
  llm?: { sessionId?: string; onEvent: (event: SseEvent) => void }
  /**    * Subscribe to queue-message events. Same pattern as `llm`: `sessionId` provided → per-session
   * routing; omitted → central key (consumer filters by `event.session_id`). */
  queue?: { sessionId?: string; onEvent: (event: QueueMessageEvent) => void }
}

export interface UnifiedSseOptions {
  channels: UnifiedChannels
  onError?: (error: Event) => void
  onConnected?: () => void
}

/** Open ONE EventSource that fans out every event family the caller wired up. */
export function createUnifiedSseConnection(opts: UnifiedSseOptions): SseClient {
  // 1. Build the ?channels= comma-separated list.
  const tokens: string[] = []
  if (opts.channels.workers) tokens.push('workers')
  if (opts.channels.sessions) tokens.push('sessions')
  if (opts.channels.kanban) tokens.push('kanban')
  if (opts.channels.design) tokens.push('design_element')
  if (opts.channels.llm) {
    tokens.push(opts.channels.llm.sessionId ? `llm:${opts.channels.llm.sessionId}` : 'llm')
  }
  if (opts.channels.queue) {
    tokens.push(opts.channels.queue.sessionId ? `queue:${opts.channels.queue.sessionId}` : 'queue')
  }
  if (opts.channels.backgroundProcess) tokens.push('background_process')
  if (opts.channels.skillEvals) tokens.push('skill_evals')
  if (opts.channels.gitFileStage) tokens.push('git_file_stage')
  if (opts.channels.gitPrState) tokens.push('git_pr_state')
  if (opts.channels.documents) tokens.push('documents')

  // Empty subscriptions are meaningless; the backend would 400 anyway. Throw early with a
  // developer-friendly message.
  if (tokens.length === 0) {
    console.error(
      '[unifiedSSE] createUnifiedSseConnection: opts.channels is empty — no EventSource will be created',
      opts.channels,
    )
    throw new Error('createUnifiedSseConnection: opts.channels is empty')
  }

  // Per-channel JSON buffer for the unnamed default `message` event, if any are emitted.
  const defaultMessageBuf = { value: '' }

  return createSseClient({
    url: `${API_BASE}/events?channels=${tokens.join(',')}`,
    onConnected: opts.onConnected,
    // Every named event type the backend can emit MUST be pre-registered — the browser's
    // EventSource only dispatches each `event: <name>` to listeners registered for that exact name.
    // See the SseClient JSDoc + the project memory browser-eventsource-named-events.md.
    additionalEventTypes: [
      'kanban_column',
      'kanban_task',
      'queue_queued',
      'queue_deleted',
      'llm_chunk',
      'llm_full',
      'worker_created',
      'worker_updated',
      'worker_deleted',
      // Throw-isolation / forward-compat: the backend emits these fallback/granular names (see
      // on_event_sent.zig + on_event_sent_design.zig).
      'worker_unknown',
      'session_created',
      'session_deleted',
      'session_updated', // task_1786507100896 — auto-rename on first user message + unattended toggle
      'session_unknown',
      // Design-mode element events (see src/ai_workflow/tui/on_event_sent_design.zig). All granular
      // single-element events share the `DesignElementEvent` payload; the `action` discriminator
      // tells them apart.
      'design_element_created',
      'design_element_updated',
      'design_element_deleted',
      'design_elements_geometry_batch_updated',
      // Backend also emits `design_page_deleted` (routing key `design_page`) and `close`
      // (server-shutdown frame).
      'design_page_deleted',
      'close',
      // Background-process lifecycle (see background_process_events.zig).
      // Without pre-registration the browser drops the event before
      // onEvent ever fires — the list would never refresh.
      'background_process_created',
      'background_process_completed',
      // Auth rejection (`event: auth_error`, see unified_events_sse.zig `terminateSseStream`).
      // Without pre-registration the browser drops it before onEvent ever fires and the client sits
      // in 'connecting' until the stream closes — indistinguishable from a dead backend.
      'auth_error',
      // Skill-eval lifecycle (see src/agentic_loop/skill_eval_events.zig). Three granular names
      // share one payload; all route on the central `skill_evals` key.
      'skill_evals_run_started',
      'skill_evals_run_finished',
      'skill_evals_result_applied',
      // File stage/unstage (see src/agentic_loop/git_file_stage_events.zig). Two granular names
      // share one payload; both route on the central `git_file_stage` key.
      'git_file_staged',
      'git_file_unstaged',
      // Change-request state (see src/agentic_loop/git_pr_state_events.zig). Two granular names
      // share one payload; both route on the central `git_pr_state` key.
      'git_pr_state_merged',
      'git_pr_state_closed',
      // Document mutations (see src/agentic_loop/document_events.zig). Three granular names share
      // one payload; all route on the central `documents` key.
      'document_created',
      'document_updated',
      'document_deleted',
    ],
    // Default heartbeat filter (matches backend sse_manager.sendHeartbeat).
    heartbeatData: 'ping',
    onEvent: (raw: string, eventType: string) => {
      if (eventType === 'connected') {
        // Reset the buffer on (re)connect — leftover bytes from the
        // previous connection would corrupt the next parse.
        defaultMessageBuf.value = ''
        return
      }

      // Named events: dispatch by eventType.
      if (eventType === 'kanban_column' || eventType === 'kanban_task') {
        if (!opts.channels.kanban) return
        try {
          const data = JSON.parse(raw)
          opts.channels.kanban(data as KanbanColumnEvent | KanbanTaskEvent)
        } catch (err) {
          console.error('[unifiedSSE] kanban event parse failed:', err, raw)
        }
        return
      }

      // Design-mode element events.
      if (
        eventType === 'design_element_created' ||
        eventType === 'design_element_updated' ||
        eventType === 'design_element_deleted' ||
        eventType === 'design_elements_geometry_batch_updated'
      ) {
        if (!opts.channels.design) return
        try {
          const data = JSON.parse(raw)
          opts.channels.design(data as DesignElementEvent)
        } catch (err) {
          console.error('[unifiedSSE] design event parse failed:', err, raw)
        }
        return
      }

      if (eventType === 'queue_queued' || eventType === 'queue_deleted') {
        if (!opts.channels.queue) return
        try {
          const data = JSON.parse(raw)
          opts.channels.queue.onEvent(data as QueueMessageEvent)
        } catch (err) {
          console.error('[unifiedSSE] queue event parse failed:', err, raw)
        }
        return
      }

      // Document mutations (agent tools only — `add_document` / `edit_document` /
      // `delete_document`). All three granular names share one `DocumentEvent` payload.
      if (
        eventType === 'document_created' ||
        eventType === 'document_updated' ||
        eventType === 'document_deleted'
      ) {
        if (!opts.channels.documents) return
        const frame = Effect.runSyncExit(
          Effect.try({
            try: () => JSON.parse(raw) as DocumentEvent,
            catch: (cause) =>
              new SseFrameError({ eventType, reason: describeCause(Cause.fail(cause)) }),
          }),
        )
        if (Exit.isSuccess(frame)) {
          opts.channels.documents(frame.value)
        } else {
          const failed = Option.getOrUndefined(Cause.failureOption(frame.cause))
          console.error(
            `[unifiedSSE] ${eventType} event parse failed:`,
            failed instanceof SseFrameError ? failed.reason : describeCause(frame.cause),
            raw,
          )
        }
        return
      }

      // Background-process lifecycle. Both granular names share the
      // `BackgroundProcessEvent` payload — the consumer filters by
      // `session_id` and re-fetches the list.
      if (
        eventType === 'background_process_created' ||
        eventType === 'background_process_completed'
      ) {
        if (!opts.channels.backgroundProcess) return
        try {
          const data = JSON.parse(raw)
          opts.channels.backgroundProcess(data as BackgroundProcessEvent)
        } catch (err) {
          console.error('[unifiedSSE] background_process event parse failed:', err, raw)
        }
        return
      }

      // Skill-eval lifecycle. All three granular names share the
      // `SkillEvalEvent` payload — the consumer filters by `session_id`
      // and re-fetches the eval list for the Evals tab.
      if (
        eventType === 'skill_evals_run_started' ||
        eventType === 'skill_evals_run_finished' ||
        eventType === 'skill_evals_result_applied'
      ) {
        if (!opts.channels.skillEvals) return
        try {
          const data = JSON.parse(raw)
          opts.channels.skillEvals(data as SkillEvalEvent)
        } catch (err) {
          console.error('[unifiedSSE] skill_evals event parse failed:', err, raw)
        }
        return
      }

      // LLM streaming chunks / full responses. The backend sets `event_type = "llm_chunk"` for
      // content/reasoning/tool-call/final chunks (per `on_event_sent.zig` `sendStreamChunk*`) and
      // `event_type = "llm_full"` for non-streaming full responses (`onEventSendLLMHistory`).
      if (eventType === 'llm_chunk' || eventType === 'llm_full') {
        if (!opts.channels.llm) return
        try {
          const data = JSON.parse(raw)
          opts.channels.llm.onEvent(data as SseEvent)
        } catch (err) {
          console.error('[unifiedSSE] llm event parse failed:', err, raw)
        }
        return
      }

      // Worker events. The backend sets `worker_created` | `worker_updated` | `worker_deleted`
      // based on `OnEventInputWorkers.action` (see `on_event_sent.zig`), plus `worker_unknown` as a
      // future-proofing fallback for new actions.
      if (
        eventType === 'worker_created' ||
        eventType === 'worker_updated' ||
        eventType === 'worker_deleted' ||
        eventType === 'worker_unknown'
      ) {
        if (!opts.channels.workers) return
        try {
          const data = JSON.parse(raw)
          opts.channels.workers(data as WorkerEvent)
        } catch (err) {
          console.error('[unifiedSSE] worker event parse failed:', err, raw)
        }
        return
      }

      // Session events.
      if (
        eventType === 'session_created' ||
        eventType === 'session_updated' ||
        eventType === 'session_deleted' ||
        eventType === 'session_unknown'
      ) {
        if (!opts.channels.sessions) return
        try {
          const data = JSON.parse(raw)
          opts.channels.sessions(data as SessionEvent)
        } catch (err) {
          console.error('[unifiedSSE] session event parse failed:', err, raw)
        }
        return
      }

      // File stage/unstage. Both granular names share the `GitFileStageEvent` payload — the
      // consumer filters by `cwd` and moves ONE row between Staged / Changes / Untracked instead of
      // re-fetching the whole git-status list.
      if (eventType === 'git_file_staged' || eventType === 'git_file_unstaged') {
        if (!opts.channels.gitFileStage) return
        try {
          const data = JSON.parse(raw)
          opts.channels.gitFileStage(data as GitFileStageEvent)
        } catch (err) {
          console.error('[unifiedSSE] git_file_stage event parse failed:', err, raw)
        }
        return
      }

      // Change-request state (merged / closed).
      if (eventType === 'git_pr_state_merged' || eventType === 'git_pr_state_closed') {
        if (!opts.channels.gitPrState) return
        const frame = Effect.runSyncExit(
          Effect.try({
            try: () => JSON.parse(raw) as GitPrStateEvent,
            catch: (cause) =>
              new SseFrameError({ eventType, reason: describeCause(Cause.fail(cause)) }),
          }),
        )
        if (Exit.isSuccess(frame)) {
          opts.channels.gitPrState(frame.value)
        } else {
          const failed = Option.getOrUndefined(Cause.failureOption(frame.cause))
          console.error(
            `[unifiedSSE] ${eventType} event parse failed:`,
            failed instanceof SseFrameError ? failed.reason : describeCause(frame.cause),
            raw,
          )
        }
        return
      }

      // Server-shutdown frame (`event: close`, see sse_manager.zig). Explicitly ignored — the
      // browser fires `error` + the client reconnects via its own backoff.
      if (eventType === 'close') {
        return
      }

      // Auth rejection (`event: auth_error`, see unified_events_sse.zig `terminateSseStream`).
      if (eventType === 'auth_error') {
        try {
          const loc = globalThis.location
          if (loc && !loc.pathname.startsWith('/login')) {
            loc.href = `/login?redirect=${encodeURIComponent(loc.pathname + loc.search)}`
          }
        } catch {
          /* non-browser (vitest) — no redirect */
        }
        return
      }

      // `design_page_deleted` shares the design channel (page-level delete; the consumer
      // re-fetches). Registered so the browser doesn't drop it silently; forwarded best-effort like
      // the element events above.
      if (eventType === 'design_page_deleted') {
        if (!opts.channels.design) return
        try {
          const data = JSON.parse(raw)
          opts.channels.design(data as DesignElementEvent)
        } catch (err) {
          console.error('[unifiedSSE] design page event parse failed:', err, raw)
        }
        return
      }

      // Default `message` events: 3 distinct JSON shapes, differentiated by which consumer
      // registered the channel.
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        defaultMessageBuf.value += trimmed + '\n'
        const jsonStart = defaultMessageBuf.value.indexOf('{')
        const jsonEnd = defaultMessageBuf.value.lastIndexOf('}')
        if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
          // Incomplete JSON object — wait for more bytes. If the buffer grows unbounded (e.g.
          // server sends invalid JSON), a future fix could add a size guard; current callers trust
          // the backend's wire format.
          return
        }
        const jsonStr = defaultMessageBuf.value.slice(jsonStart, jsonEnd + 1)
        let parsed: unknown
        try {
          parsed = JSON.parse(jsonStr)
        } catch {
          // Invalid JSON; drop the leading bytes and keep accumulating. (Defensive — the backend's
          // std.json.fmt should always emit valid JSON. But a buggy future emitter shouldn't crash
          // the SSE.)
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonStart + 1)
          return
        }

        const obj = parsed as Record<string, unknown>
        // Order matters: check session BEFORE worker because both have `action`; the discriminator
        // is `working_directory` (worker has it, session doesn't) plus `status` (session has it,
        // worker doesn't). Either combination uniquely identifies.
        try {
          if (
            opts.channels.sessions &&
            typeof obj.action === 'string' &&
            typeof obj.status === 'string' &&
            typeof obj.cwd === 'string'
          ) {
            try {
              opts.channels.sessions(obj as unknown as SessionEvent)
            } catch (err) {
              console.error('[unifiedSSE] session channel subscriber threw:', err)
            }
          } else if (
            opts.channels.workers &&
            typeof obj.action === 'string' &&
            typeof obj.working_directory === 'string'
          ) {
            try {
              opts.channels.workers(obj as unknown as WorkerEvent)
            } catch (err) {
              console.error('[unifiedSSE] worker channel subscriber threw:', err)
            }
          } else if (opts.channels.llm && (obj.type === 'chunk' || obj.type === 'full')) {
            try {
              opts.channels.llm.onEvent(obj as unknown as SseEvent)
            } catch (err) {
              console.error('[unifiedSSE] llm channel subscriber threw:', err)
            }
          }
        } finally {
          // ALWAYS advance past the consumed JSON object, regardless of whether a consumer matched
          // or threw.
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonEnd + 1)
        }
      } catch (e) {
        console.error('[unifiedSSE] default message dispatch error:', e)
      }
    },
    onStateChange: (state, info) => {
      // Match the convention of the 5 old factories: terminal-failure only. Transient errors are
      // retried internally by the SseClient. See memory pabrik-sse-incomplete-chunked-encoding.md
      // for why ChatView's isStreaming flag flips ONLY on 'failed'.
      if (state === 'failed') {
        try {
          opts.onError?.(info.lastError ?? new Event('error'))
        } catch (err) {
          console.error('[unifiedSSE] onError subscriber threw:', err)
        }
      }
    },
  })
}

// Pabrik Config API
export interface PabrikProfile {
  model?: string
  base_url?: string
  thinking?: string
  temperature?: string
  url_style?: string
  api_key?: string
  /** Which TRANSPORT runs this profile's calls: `"http"` (default), `"claude-code"` (the local
   * `claude` CLI, subscription auth via `claude login`), or `"opencode"` (the local `opencode` CLI,
   * auth via `opencode login`). Mirrors the backend's `LlmProfile.backend`. */
  backend?: string
  /**    * Claude Code only: `CLAUDE_CONFIG_DIR` for this profile. Two profiles pointing at two
   * directories are two different `claude login` sessions — the way per-profile identity works when
   * there is no API key. Mirrors `LlmProfile.config_dir`. Null = CLI default (`~/.claude`). */
  config_dir?: string | null
  /** Claude Code only: agentic turn ceiling passed as `--max-turns`.
   * Mirrors `LlmProfile.max_turns`. Null = the CLI's own default. */
  max_turns?: number | null
  /**    * Per-profile sub-agents. Same shape as the top-level `PabrikConfig.sub_agents` field — profiles
   * can override the default sub-agent set with their own. */
  sub_agents?: SubAgent[]
  /** Optional override for this profile's context window (in tokens). When null (or omitted), the
   * backend's built-in per-model default is used (e.g. 200_000 for MiniMax-M2.7, 500_000 for
   * MiniMax-M3, 200_000 fallback). Useful for self-hosted models with a non-standard window. */
  max_capacity_tokens?: number | null
  /** Compaction threshold as a percentage (0-100) of this profile's context window. When null (or
   * omitted), defaults to 80. Out-of-range values are rejected by the backend with
   * `error.InvalidThresholdPercent`. */
  compaction_threshold_percent?: number | null
  /** Anthropic-only override for `thinking.budget_tokens`. Plan 2026-08-23-model-thinking. Mirrors
   * `LlmProfile.thinking_budget_tokens`. Hidden when `thinking === "off"`. Range (0, 2_000_000]
   * enforced server-side. */
  thinking_budget_tokens?: number | null
  /**    * OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). Plan 2026-08-23-model-thinking.
   * Mirrors `LlmProfile.reasoning_effort`. Hidden when `thinking === "off"`. Server-side validation
   * via `parse_thinking.parseReasoningEffort` (low|medium|high|auto). */
  reasoning_effort?: 'low' | 'medium' | 'high' | 'auto' | null
}

export interface SubAgent {
  name: string
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  system_prompt: string
  /**    * Transport discriminator, mirroring `PabrikProfile.backend`. `"http"` (default) |
   * `"claude-code"` | `"opencode"`. Empty/absent = inherit the parent profile's backend. */
  backend?: string
  /** Claude Code only: `CLAUDE_CONFIG_DIR` override. */
  config_dir?: string | null
  /** Claude Code only: `--max-turns` override. */
  max_turns?: number | null
  /**    * Anthropic-only override for `thinking.budget_tokens`. Plan 2026-08-23-model-thinking. Mirrors
   * `LlmProfile.thinking_budget_tokens`. Optional in the wire shape — old configs without this
   * field hydrate as undefined and are coerced to null in the form. */
  thinking_budget_tokens?: number | null
  /** OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1).
   * Mirrors `LlmProfile.reasoning_effort`. Optional. */
  reasoning_effort?: 'low' | 'medium' | 'high' | 'auto' | null
}

export interface McpHeader {
  key: string
  value: string
}

export interface McpServer {
  name: string
  /**    * Transport discriminator. Defaults to 'http' on legacy entries that predate this field. Mutually
   * exclusive with itself — a server is either HTTP or stdio, never both. */
  transport?: 'http' | 'stdio'
  /** HTTP transport — required when transport === 'http'. */
  url?: string
  /** Optional list of HTTP headers to send with MCP requests (e.g. API keys). */
  headers?: McpHeader[]
  /**    * stdio transport — required when transport === 'stdio'. The command (executable name or absolute
   * path) the agent will spawn as a child process and talk MCP JSON-RPC to. */
  command?: string
  /** stdio transport — argv (excluding argv[0]). One entry per line in the UI. */
  args?: string[]
  /**    * stdio transport — "KEY=VALUE" per line, ADDED on top of inherited env. v1 limitation: Zig
   * 0.16's std.process.Child has no clean .env_map setter, so a custom env requires a
   * pre-fork+execve helper — not in v1. The UI exposes this for documentation + forward-compat. */
  env?: string[]
  /** stdio transport — optional child working directory (absolute path). */
  cwd?: string
  /**    * When false the agent skips this server (no tools listed, no calls). Missing/undefined renders
   * as enabled. Omitted on the wire when enabled so legacy configs stay clean. */
  enabled?: boolean
}

/** One entry of the top-level `web_search` map in `config.json` — the wire shape of a single
 * web-search provider. The map key is the provider name the agent passes to `web_search`; the agent
 * discovers the names through `list_web_search_providers`. */
export interface PabrikWebSearchProvider {
  /** Host pin. The ONLY host whose requests may carry `key`. Must be
   *  `https` and must not name a loopback, private or link-local host. */
  url: string
  /** Credential, stored separately from `curl` so nothing derived from
   *  the template can leak it. Optional. */
  key?: string
  /**    * Request template copied from the provider's docs, carrying the literal text `{key}` where the
   * credential goes. Must contain `{key}` when the provider declares a `key`, and must NOT when it
   * does not. */
  curl: string
  /** Free-text note about when to prefer this provider. Optional. */
  description?: string
  /** Defaults to true. `false` keeps the provider configured but hides
   *  it from `list_web_search_providers`. */
  enabled?: boolean
}

/** The Skill Evals block of `config.json`, as the wire carries it (snake_case, matching
 * `SkillEvalsJson` in `Config.zig`). `enabled` is the master switch the Settings toggle writes. */
export interface PabrikSkillEvalsConfig {
  enabled?: boolean
  max_skills_per_run?: number
  max_evals_per_day?: number
  fact_lease_seconds?: number
  include_listed_without_loading?: boolean
  /** `'off' | 'propose' | 'auto_low_risk'`. Null = not set on disk. */
  apply_mode?: string | null
}

export interface PabrikConfig {
  // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM defaults
  // (api_endpoint/api_key/model/url_style/temperature/max_tokens/system_prompt) were REMOVED from
  // config.json.
  profiles?: Record<string, PabrikProfile>
  active_profile?: string
  /** Map of MCP server name to its raw JSON config (snake_case). Each value follows the `{"url":
   * "...", "headers": {...}}` shape used by the LLM config. Sent verbatim to the backend on save. */
  mcp_servers?: Record<
    string,
    | { url: string; headers?: Record<string, string>; enabled?: boolean }
    | { command: string; args?: string[]; env?: string[]; cwd?: string; enabled?: boolean }
  >
  /**    * Default tool checklist (Tools tab). `null` / absent = the key is not in config.json — the
   * backend treats those as "no change" on PUT and the built-in defaults apply. An array (including
   * `[]`) replaces the whole list. */
  tools?: string[] | null
  /** Map of web-search provider name to its configuration — the top-level `web_search` key in
   * config.json. Keys of this map are the names the agent passes to `web_search`'s `provider`
   * argument; the agent discovers them through `list_web_search_providers`. */
  web_search?: Record<string, PabrikWebSearchProvider> | null
  /** @deprecated Per-profile only (plan 2026-09-04-subagents-per-profile). The backend (`GET
   * /api/config/pabrik`) always returns `sub_agents: null` at the top level; each profile owns its
   * list via `PabrikProfile.sub_agents`. */
  sub_agents?: SubAgent[]
  /**    * Opt-in OS notification flag. When true, the backend fires `notify-send` / osascript /
   * PowerShell when an LLM response completes with `finish_reason === 'stop'`. Defaults to `false`
   * when absent (matches the `LlmConfigJson` default in `Config.zig`). */
  notify_on_complete?: boolean
  /** Plan 2026-08-25-notify-on-error — opt-in OS notification flag for the error path. When true,
   * the backend fires a desktop notification when the workflow hits a transport error, exhausts
   * retries (TooManyRetries), or fails the outer agentic loop. */
  notify_on_error?: boolean
  /** Skill Evals block — the master switch for the `run_skill_eval` tool and the budget knobs
   * around it. */
  skill_evals?: PabrikSkillEvalsConfig
  /**    * Compaction threshold in KB. Sessions whose DB-stored token estimate exceeds this value trigger
   * context compaction. Defaults to `100` when absent. Not exposed in the UI — power users can edit
   * `config.json` directly. */
  model_compaction_size_kb?: number
  /** Optional top-level override for the model's context window (in tokens). `null` = fall through
   * to per-profile override, then built-in default. Restored in plan 2026-07-07-compaction-inline
   * so the Defaults tab can show + edit the top-level compaction defaults. */
  max_capacity_token_model?: number | null
  /**    * Optional top-level compaction threshold as a percentage (0-100). `null` = fall through to
   * per-profile override, then built-in 80. Mirrors `LlmConfig.compaction_threshold_percent`. */
  compaction_threshold_percent?: number | null
  /** Delay in milliseconds before the workflow retries a failed `callDynamicAgentNew` call. 0 = no
   * delay (current behavior, the retry fires immediately on the next loop iteration). Range: 0–60
   * 000. The backend clamps values > 60 000 to 60 000. */
  retry_delay_ms?: number
  /** Plan 2026-09-10-web-launch-toggle — browser-mode flag. When true, the settings General tab
   * advertises the same UI in the system browser (URL pill + auto-open) and the server defaults to
   * a random local port at startup. Defaults to `false` when absent (matches `LlmConfigJson`). */
  web_launch_enabled?: boolean
  // Per-profile compaction overrides (`max_capacity_tokens` /
  // `compaction_threshold_percent`) live on `PabrikProfile` (Chunk
  // 7.6) and remain there. Both layers coexist.
}

export async function getPabrikConfig(): Promise<PabrikConfig> {
  try {
    return await apiFetch<PabrikConfig>('/config/pabrik')
  } catch {
    return {}
  }
}

export async function savePabrikConfig(config: PabrikConfig): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>('/config/pabrik', {
    method: 'PUT',
    body: config,
  })
}

// ─── Per-workspace config overlay (Migration 105) ──────────────────────── The workspace-scope
// twin of the pair above.
export async function getWorkspaceConfig(workspaceId: string): Promise<PabrikConfig> {
  return await apiFetch<PabrikConfig>(`/workspaces/${encodeURIComponent(workspaceId)}/config`)
}

export async function saveWorkspaceConfig(
  workspaceId: string,
  config: PabrikConfig,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/config`,
    { method: 'PUT', body: config },
  )
}

/** Plan 2026-09-10-web-launch-toggle — browser-mode status. `GET /api/web/status` is read-only
 * (lifecycle A: no server-side start/stop). `url` is always the live bound port
 * (`http://127.0.0.1:<port>/`, loopback-only). */
export interface WebStatus {
  enabled: boolean
  running: boolean
  url: string
  port: number
}

export async function getWebStatus(): Promise<WebStatus | null> {
  try {
    return await apiFetch<WebStatus>('/web/status')
  } catch {
    return null
  }
}

/** Response shape from `DELETE /api/config/pabrik/profiles/:name`. `active_profile_was_cleared` is
 * `true` when the deleted profile was the active one (the backend also cleared `active_profile` on
 * disk). */
export interface ProfileDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/**  * DELETE /api/config/pabrik/profiles/:name Removes a profile from `config.json` and live-reloads
 * the backend's in-memory LLM config. Throws an Error (with the HTTP status) on non-2xx responses;
 * the composable wraps this for UI concerns (optimistic update, rollback, notification). */
export async function deleteProfile(name: string): Promise<ProfileDeleteResponse> {
  return await apiFetch<ProfileDeleteResponse>(
    `/config/pabrik/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

/**  * `DELETE /api/workspaces/:workspace_id/config/profiles/:name` Removes the profile from this
 * workspace's overlay AND from the user config it inherits from, so deleting it from the workspace
 * Profiles list actually removes it (dropping it from the overlay alone would inherit it back). */
export async function deleteWorkspaceProfile(
  workspaceId: string,
  name: string,
): Promise<ProfileDeleteResponse> {
  return await apiFetch<ProfileDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/config/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// ─── MCP server test probe ────────────────────────────────────────────────── Wire shape mirrors
// the backend `POST /api/mcp/test` handler in src/ai_workflow/tui/http_handlers/mcp_test.zig.
export interface McpToolPreview {
  name: string
  description: string
}
export type McpTestResult =
  | { ok: true; transport: 'http' | 'stdio'; tools: McpToolPreview[] }
  | { ok: false; error: string; details?: string }

export async function testMcpServer(body: {
  transport: 'http' | 'stdio'
  command?: string
  args?: string[]
  env?: string[]
  cwd?: string
  url?: string
  headers?: Record<string, string>
}): Promise<McpTestResult> {
  // We deliberately DON'T use the shared `apiFetch` wrapper here because (a) the endpoint always
  // returns HTTP 200 with a payload that may carry `{ ok: false, ... }`, and (b) we want the
  // modal's inline result panel to render the error message rather than firing a toast.
  const res = await fetch(`${API_BASE}/mcp/test`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await res.text().catch(() => '')
  let parsed: unknown = null
  try {
    parsed = text.length > 0 ? JSON.parse(text) : null
  } catch {
    // Non-JSON response — fall through to the generic error shape.
  }
  if (parsed && typeof parsed === 'object') {
    return parsed as McpTestResult
  }
  return {
    ok: false,
    error: `Unexpected response (HTTP ${res.status})`,
    details: text.slice(0, 200),
  }
}

// ─── LLM profile test probe ───────────────────────────────────────────────── Wire shape mirrors
// the backend `POST /api/llm/test` handler in src/http_handlers/llm_test.zig.
export interface LlmTestRequest {
  model: string
  base_url: string
  api_key: string
  url_style: string
}
export type LlmTestResult =
  | { ok: true; model: string; reply: string; latency_ms: number }
  | { ok: false; error: string; details?: string }

export async function testLlmProfile(body: LlmTestRequest): Promise<LlmTestResult> {
  // Deliberately NOT the shared `apiFetch` wrapper (same reason as `testMcpServer` above): the
  // endpoint always returns HTTP 200 with a payload that may carry `{ ok: false, ... }`, and we
  // want the modal's inline result panel to render the error rather than firing a toast.
  const res = await fetch(`${API_BASE}/llm/test`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const text = await res.text().catch(() => '')
  let parsed: unknown = null
  try {
    parsed = text.length > 0 ? JSON.parse(text) : null
  } catch {
    // Non-JSON response — fall through to the generic error shape.
  }
  if (parsed && typeof parsed === 'object') {
    return parsed as LlmTestResult
  }
  return {
    ok: false,
    error: `Unexpected response (HTTP ${res.status})`,
    details: text.slice(0, 200),
  }
}

// Git File Diff API
export interface GitFileDiff {
  path: string
  diff_content: string // Unified diff output from git diff command
  staged: boolean
}

// Batch file diffs — one POST replaces N parallel GET /git/file/diff. Collapses the
// SidebarDiffPanel fan-out (20 files = 20 git spawns holding 20 Io workers) into at most 2
// server-side `git diff` invocations. LIST mode: the client names the paths.
export interface GitFileDiffsBatchItem {
  file: string
  staged: boolean
}

export interface GitFileDiffsResponse {
  diffs: GitFileDiff[]
  /**    * Whole-file mode only: the file's full-context diff exceeded the server's budget and was REFUSED
   * (`diff_content` is empty) rather than truncated into something that reads as a complete file. */
  whole_file_refused?: boolean
}

export async function getGitFileDiffs(
  cwd: string,
  files: GitFileDiffsBatchItem[],
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, files },
    silent: true,
  })
}

// Folder mode — one POST for a whole folder. The server enumerates the changed paths itself (`git
// status --porcelain -uall -- <folder>`), so the caller neither has to fetch `GET /api/git/changes`
// first nor send a path-per-file body.
export async function getGitFolderDiffs(
  cwd: string,
  folder: string = '',
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, folder },
    silent: true,
  })
}

// WHOLE-FILE mode — `git diff -U<all>` for exactly ONE path, so the caller can render every line of
// the file with the changes still marked.
export async function getGitWholeFileDiff(
  cwd: string,
  filePath: string,
  staged: boolean,
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, files: [{ file: filePath, staged }], whole_file: true },
    silent: true,
  })
}

export async function readGitFile(
  cwd: string,
  filePath: string,
): Promise<{ content: string; encoding: string }> {
  return await apiFetch<{ content: string; encoding: string }>(
    `/git/file/read?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
  )
}

// PR Diff API — full unified diff for the PR attached to a session
// (set_pull_request tool). Consumed by the ChatView right panel's
// PR mode, which splits per file client-side.
export interface GitPrDiff {
  pr_url: string
  base: string
  head: string
  diff_content: string // Full unified diff output
  truncated: boolean
}

export async function getPrDiff(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string; base?: string; head?: string },
): Promise<GitPrDiff> {
  const params = new URLSearchParams({
    path: cwd,
    pr_url: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  if (opts?.base) params.set('base', opts.base)
  if (opts?.head) params.set('head', opts.head)
  return await apiFetch<GitPrDiff>(`/git/pr/diff?${params.toString()}`)
}

// PR status API — open/merged/closed state for the attached PR
// (GET /api/git/pr/status via `gh pr view`). The PR tab polls this
// so a merge on GitHub flips the badge without a manual refresh.
export interface GitPrStatus {
  // Which forge answered: `github` | `gitlab`. Absent on older servers.
  provider?: string
  pr_url: string
  number: number
  title: string
  state: string
  status: string // open | closed | merged (lowercased by backend)
  mergeable: string
  merge_state: string
  /**    * The commit the head branch points at (`headRefOid` / GitLab `sha`). It is the merge box's head
   * guard: `--match-head-commit` / `--sha`, so a merge cannot land on a commit the user never saw.
   * `''` on older servers. */
  head_sha: string
  head_ref: string
  base_ref: string
  author: string
  created_at: string
  updated_at: string
  merged_at: string
  closed_at: string
  additions: number
  deletions: number
  changed_files: number
  /** APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED, or "" when the forge has no
   *  verdict to give. It is the sentence behind "Merging is blocked". */
  review_decision: string
  /** The CI rollup, counted. The header chips and the merge box read it. */
  checks: GitPrChecksSummary
}

export async function getPrStatus(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrStatus> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  return await apiFetch<GitPrStatus>(`/git/pr/status?${params.toString()}`, { silent: true })
}

// The change request's conversation (GET /api/git/pr/conversation): the body,
// the comments and the review verdicts. Every body here is authored by someone
// who can comment on the repo, so it is rendered through helpers/markdown.ts.
export interface GitPrConversationComment {
  author: string
  body: string
  created_at: string
  url: string
}

export interface GitPrConversationReview {
  author: string
  /** APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED */
  state: string
  body: string
  created_at: string
  url: string
}

export interface GitPrConversation {
  provider: string
  number: number
  title: string
  /** The request's own description, in markdown. */
  body: string
  author: string
  created_at: string
  review_decision: string
  comments: GitPrConversationComment[]
  reviews: GitPrConversationReview[]
  /** Comments plus reviews: how many entries the thread holds. */
  comment_count: number
  /** A non-fatal note about the answer, rendered inline. */
  detail: string
}

export async function getPrConversation(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrConversation> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  // silent: true — the Conversation tab renders the server's own error
  // sentence inline, so a toast would only repeat it.
  return await apiFetch<GitPrConversation>(`/git/pr/conversation?${params.toString()}`, { silent: true })
}

// PR/MR list for a repo (GET /api/git/pr/list via `gh pr list` /
// `glab mr list`). Powers the board-level change-request list — one
// call for the whole repo, not one per card.
export interface GitPrListItem {
  number: number
  title: string
  url: string
  state: string
  is_draft: boolean
  head_ref: string
  base_ref: string
  author: string
  updated_at: string
}

export interface GitPrListResponse {
  provider: string
  program: string
  state: string
  truncated: boolean
  detail: string
  changes: GitPrListItem[]
}

export async function listPrs(
  cwd: string,
  opts?: { provider?: string; state?: string; limit?: number },
): Promise<GitPrListResponse> {
  const params = new URLSearchParams({
    path: cwd,
  })
  if (opts?.state) params.set('state', opts.state)
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts?.provider) params.set('provider', opts.provider)
  // silent: true — the list view renders the forge's own error
  // sentence inline (an error banner, not a toast), and the board
  // button leaves its badge absent on failure.
  return await apiFetch<GitPrListResponse>(`/git/pr/list?${params.toString()}`, { silent: true })
}

// Close a PR/MR (POST /api/git/pr/close). `closed: false` with a `detail` is NOT an error status —
// the forge accepted the command but the re-read still shows it open, so the UI must render the
// forge's sentence rather than claim success.
export interface GitPrCloseResponse {
  closed: boolean
  detail: string
  provider: string
  status: GitPrStatus
}

export async function closePr(
  cwd: string,
  pr: string,
  opts?: { provider?: string },
): Promise<GitPrCloseResponse> {
  // silent: true — the list view renders both the `closed: false`
  // detail and the 502 `{ error }` sentence inline next to the row.
  return await apiFetch<GitPrCloseResponse>('/git/pr/close', {
    method: 'POST',
    silent: true,
    timeoutMs: 90_000,
    body: {
      path: cwd,
      pr,
      provider: opts?.provider || undefined,
    },
  })
}

/** Merge a PR/MR (POST /api/git/pr/merge). `method` is REQUIRED: the backend refuses an empty one
 * with a 400 rather than spawning, because `gh pr merge` without a strategy flag prompts for the
 * method and a non-tty child cannot answer it. */
export interface GitPrMerge {
  success: boolean
  method: string
  pending: boolean
  status: GitPrStatus
}

export interface MergePrOptions {
  provider?: string
  method: 'merge' | 'squash' | 'rebase'
  /** Commit message for the merge/squash commit. */
  title?: string
  body?: string
  /** Delete the source branch after merging. Off by default in the UI: the
   *  source branch is usually the session's own worktree branch. */
  delete_branch?: boolean
  /** The head commit the user was looking at. Both CLIs guard on it. */
  head_sha?: string
}

export async function mergePr(
  cwd: string,
  prUrl: string,
  opts: MergePrOptions,
): Promise<GitPrMerge> {
  // The route spawns a forge CLI against a network, so it is given a far larger budget than the 15
  // s default — the same reason `git_pr_merge.zig` runs the child under a 60 s deadline. `silent`
  // because the box renders the server's own words inline instead of a toast.
  return await apiFetch<GitPrMerge>('/git/pr/merge', {
    method: 'POST',
    silent: true,
    timeoutMs: 90_000,
    body: {
      path: cwd,
      pr: prUrl,
      provider: opts.provider || undefined,
      method: opts.method,
      title: opts.title || undefined,
      body: opts.body || undefined,
      delete_branch: !!opts.delete_branch,
      head_sha: opts.head_sha || undefined,
    },
  })
}

/** PR CI checks (GET /api/git/pr/checks via `gh pr checks`). `checks` is one row per CI job;
 * `steps` is filled in for failed and cancelled jobs only — "which job failed" is already on the PR
 * page, "which process or task failed" is what the user comes here for. */
export interface GitPrCheckStep {
  name: string
  number: number
  conclusion: string // success | failure | cancelled | skipped | neutral | timed_out | ''
  status: string // queued | in_progress | completed
  started_at: string
  completed_at: string
}

export interface GitPrCheck {
  name: string
  workflow: string
  bucket: string // pass | fail | pending | skipping | cancel
  state: string
  link: string
  started_at: string
  completed_at: string
  steps: GitPrCheckStep[]
  steps_error: string
}

export interface GitPrChecksSummary {
  total: number
  passed: number
  failed: number
  pending: number
  skipped: number
  cancelled: number
}

export interface GitPrChecks {
  provider: string
  pr_url: string
  checks: GitPrCheck[]
  summary: GitPrChecksSummary
  /** Some failed jobs have no steps because the run-lookup budget ran out. */
  steps_truncated: boolean
}

export async function getPrChecks(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrChecks> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  // `silent: true`: the Checks tab renders its own error inline, and a
  // toast per poll would be noise on top of it.
  return await apiFetch<GitPrChecks>(`/git/pr/checks?${params.toString()}`, { silent: true })
}

// Which-files-conflict API. `getPrStatus` tells us a PR is CONFLICTING but not what blocks it — no
// forge API exposes that, so the backend runs the same three-way merge locally (`git merge-tree
// --write-tree --name-only`) and names the paths.
export interface GitPrConflicts {
  pr_url: string
  /** The ref the merge was computed against, e.g. `refs/remotes/origin/main`. */
  base_ref: string
  /** Short commit `base_ref` pointed at. '' when rev-parse failed (cosmetic). */
  base_commit: string
  head: string
  /** Paths git refused to merge cleanly. Empty is a legitimate answer. */
  conflicting_files: string[]
  count: number
  /** True when the server capped `conflicting_files`. */
  truncated: boolean
}

export async function getPrConflicts(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string; base?: string; head?: string },
): Promise<GitPrConflicts> {
  const params = new URLSearchParams({
    path: cwd,
    pr_url: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  if (opts?.base) params.set('base', opts.base)
  if (opts?.head) params.set('head', opts.head)
  // silent: true — the PR tab renders this failure inline next to the badge,
  // so a toast on top of that would double-report the same problem.
  return await apiFetch<GitPrConflicts>(`/git/pr/conflicts?${params.toString()}`, { silent: true })
}

// Read file content API (for CodeEditor)
export interface ReadFileResponse {
  content: string
  encoding: string
}

export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  // silent: true — AppLayout shows a fullscreen error view in the
  // code editor; a toast on every read failure would be redundant noise.
  return await apiFetch<ReadFileResponse>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=read&file=${encodeURIComponent(filePath)}`,
    { silent: true },
  )
}

// File download URL builders for the `present_files` agent tool card (PresentFiles.vue).
export function fileDownloadUrl(
  sessionId: string,
  filePath: string,
  disposition: 'inline' | 'attachment' = 'attachment',
): string {
  return `${API_BASE}/files/download?session_id=${encodeURIComponent(sessionId)}&path=${encodeURIComponent(filePath)}&disposition=${disposition}`
}

// Git Stage/Unstage API
export interface GitStageResponse {
  success: boolean
  message: string
  staged_files: string[]
  failed_files: string[]
}

export async function stageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/stage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

export async function unstageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/unstage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

// Git commit API — commits the staged index with a message typed in the
// Files tab's commit box (SidebarDiffPanel). Answers the new HEAD SHA so
// the panel can refresh history without another round-trip.
export interface GitCommitCreateResponse {
  success: boolean
  message: string
  commit_sha: string
}

export async function commitGitChanges(
  cwd: string,
  message: string,
): Promise<GitCommitCreateResponse> {
  return await apiFetch<GitCommitCreateResponse>(
    `/git/commit/create?path=${encodeURIComponent(cwd)}&message=${encodeURIComponent(message)}`,
    { method: 'POST' },
  )
}

// `uploadTaskAttachment` REMOVED 2026-08-06 (kanban-image-urls-column plan).
export interface Agent {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentKnowledgeRow {
  id: string
  agent_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentToolRow {
  id: string
  agent_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/** One parameter of a registry entry's schema. */
export interface AgentRegistryParameter {
  name: string
  /** JSON Schema type, e.g. 'string' | 'array' | 'number' | 'boolean'. */
  type: string
  /**    * True when the JSON schema lists it in `required`. A REQUIRED `cwd` is what stops a path-taking
   * tool from silently acting on the server's working directory instead of the one the agent is
   * editing. */
  required: boolean
}

export interface AgentRegistryEntry {
  name: string
  description: string
  /**    * The tool's full parameter list, in declaration order. Optional on the type only so older mocks
   * in specs keep compiling; the backend always sends it (`GET /api/agent-tools/registry`). */
  parameters?: AgentRegistryParameter[]
}

/**  * Create a new agent workspace item. The backend seeds the agent with an empty knowledge list AND
 * an empty tool allowlist (secure-by-default — empty allowlist = zero tools per spec D1). POST
 * /api/workspaces/:workspaceId/items/agent */
export async function createAgent(
  workspaceId: string,
  name: string,
  path: string,
): Promise<{ item: WorkspaceItem; agent: Agent }> {
  return await apiFetch<{ item: WorkspaceItem; agent: Agent }>(
    `/workspaces/${workspaceId}/items/agent`,
    { method: 'POST', body: { name, path } },
  )
}

/**  * Get agent + knowledge + tools + system prompts for a workspace_item. Returns the 4 sections
 * AgentView needs in one round-trip. GET /api/workspaces/:workspaceId/items/:itemId/agent */
export async function getAgent(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent: Agent
  knowledge: AgentKnowledgeRow[]
  tools: string[]
  /** Migration 080 — per-agent named prompt blocks, position DESC. */
  system_prompts: AgentSystemPromptRow[]
}> {
  return await apiFetch<{
    agent: Agent
    knowledge: AgentKnowledgeRow[]
    tools: string[]
    system_prompts: AgentSystemPromptRow[]
  }>(`/workspaces/${workspaceId}/items/${itemId}/agent`)
}

/** Update an agent's description.
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent */
export async function updateAgent(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent: Agent }> {
  return await apiFetch<{ agent: Agent }>(`/workspaces/${workspaceId}/items/${itemId}/agent`, {
    method: 'PATCH',
    body: { description },
  })
}

// ===================================================================== Workspace routines
// (Migration 084) — first-class `item_type='routine'` items beside `agent`.
export interface WorkspaceRoutine {
  id: string
  workspace_item_id: string
  description: string
  /** The agent prompt fired on each tick. */
  instruction: string
  /** 5-field cron. '' = manual-run only (no auto-fire). */
  schedule: string
  enabled: boolean
  last_run_at: string
  /** '' when manual-only or disabled. */
  next_run_at: string
  last_status: string
  last_error: string
  created_at: string
  updated_at: string
}

/** Create a new routine workspace item.
 * POST /api/workspaces/:workspaceId/items/routine */
export async function createRoutineItem(
  workspaceId: string,
  name: string,
  path: string,
  opts?: {
    description?: string
    instruction?: string
    schedule?: string
    enabled?: boolean
  },
): Promise<{ item: WorkspaceItem; routine: WorkspaceRoutine }> {
  return await apiFetch<{ item: WorkspaceItem; routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/routine`,
    {
      method: 'POST',
      body: {
        name,
        path,
        description: opts?.description ?? '',
        instruction: opts?.instruction ?? '',
        schedule: opts?.schedule ?? '',
        enabled: opts?.enabled ?? true,
      },
    },
  )
}

/** Get the routine bound to a workspace_item.
 * GET /api/workspaces/:workspaceId/items/:itemId/routine */
export async function getRoutineItem(
  workspaceId: string,
  itemId: string,
): Promise<{ routine: WorkspaceRoutine }> {
  return await apiFetch<{ routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/routine`,
  )
}

/**  * Update a routine's description / instruction / schedule / enabled. Schedule/enabled changes
 * recompute next_run_at server-side. PATCH /api/workspaces/:workspaceId/items/:itemId/routine */
export async function updateRoutineItem(
  workspaceId: string,
  itemId: string,
  data: {
    description?: string
    instruction?: string
    schedule?: string
    enabled?: boolean
  },
): Promise<{ routine: WorkspaceRoutine }> {
  return await apiFetch<{ routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/routine`,
    { method: 'PATCH', body: data },
  )
}

/**  * Add a knowledge entry to an agent — either a markdown file path on disk (`filePath`) or inline
 * manual text (`content`). Exactly one of the two must be non-empty (backend XOR-validates). POST
 * /api/agents/:agentId/knowledge */
export async function addAgentKnowledge(
  agentId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentKnowledgeRow> {
  return await apiFetch<AgentKnowledgeRow>(`/agents/${agentId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentKnowledge(
  agentId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentKnowledgeRow> {
  return await apiFetch<AgentKnowledgeRow>(`/agents/${agentId}/knowledge/${knowledgeId}`, {
    method: 'PATCH',
    body: updates,
  })
}

export async function deleteAgentKnowledge(
  agentId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKnowledge(
  agentId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

// ─── Agent System Prompt (Migration 080) ────────────────────────────────
export interface AgentSystemPromptRow {
  id: string
  agent_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

/**  * Add a named system-prompt block to an agent. `content` is required (non-empty after trim);
 * `title` optional ('' = untitled). POST /api/agents/:agentId/system_prompt */
export async function addAgentSystemPrompt(
  agentId: string,
  title: string,
  content: string,
): Promise<AgentSystemPromptRow> {
  return await apiFetch<AgentSystemPromptRow>(`/agents/${agentId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentSystemPrompt(
  agentId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentSystemPromptRow> {
  return await apiFetch<AgentSystemPromptRow>(`/agents/${agentId}/system_prompt/${promptId}`, {
    method: 'PATCH',
    body: updates,
  })
}

export async function deleteAgentSystemPrompt(
  agentId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentSystemPrompts(
  agentId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Get the canonical tool registry. The Tools panel renders checkboxes from this list. Sourced from
 * the runtime's UNIFIED_TOOL_REGISTRY (single source of truth per spec D4). GET
 * /api/agent-tools/registry */
export async function getAgentToolsRegistry(): Promise<{ tools: AgentRegistryEntry[] }> {
  return await apiFetch<{ tools: AgentRegistryEntry[] }>(`/agent-tools/registry`)
}

/** Get the enabled tool names for an agent. Empty array = secure-by-default.
 * GET /api/agents/:agentId/tools */
export async function getAgentTools(agentId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agents/${agentId}/tools`)
}

/**  * Enable a tool for the agent. Backend validates `tool_name` against the registry (400 if unknown)
 * and returns 409 on duplicate. POST /api/agents/:agentId/tools */
export async function enableAgentTool(agentId: string, toolName: string): Promise<AgentToolRow> {
  return await apiFetch<AgentToolRow>(`/agents/${agentId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/**  * Disable a tool for the agent (deletes the row). `tool_name` must match a tool the agent currently
 * has enabled (the registry name; backend returns 404 on unknown / not-enabled). DELETE
 * /api/agents/:agentId/tools/:toolName */
export async function disableAgentTool(agentId: string, toolName: string): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/tools/${toolName}`, { method: 'DELETE' })
}

// ─── Agent-Kanbans Mirror (Migration 081) ─────────────────────────────── Mirrors the Agent Mode
// block above onto kanban boards. The config row (`agent_kanbans`) is OPT-IN — `getAgentKanban`
// resolves to `null` (silently, no error toast) when the board has no config yet.
export interface AgentKanban {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentKanbanKnowledgeRow {
  id: string
  kanban_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentKanbanSystemPromptRow {
  id: string
  kanban_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentKanbanToolRow {
  id: string
  kanban_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/**  * Get the agent-kanbans config + children for a kanban workspace_item. Returns null (silent) on 404
 * "not configured" — an unconfigured board is an expected state, not an error worth surfacing. GET
 * /api/workspaces/:workspaceId/items/:itemId/agent_kanban */
export async function getAgentKanban(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent_kanban: AgentKanban
  knowledges: AgentKanbanKnowledgeRow[]
  tools: string[]
  system_prompts: AgentKanbanSystemPromptRow[]
} | null> {
  try {
    return await apiFetch<{
      agent_kanban: AgentKanban
      knowledges: AgentKanbanKnowledgeRow[]
      tools: string[]
      system_prompts: AgentKanbanSystemPromptRow[]
    }>(`/workspaces/${workspaceId}/items/${itemId}/agent_kanban`, { silent: true })
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Update the agent-kanbans config's description.
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_kanban */
export async function updateAgentKanban(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent_kanban: AgentKanban }> {
  return await apiFetch<{ agent_kanban: AgentKanban }>(
    `/workspaces/${workspaceId}/items/${itemId}/agent_kanban`,
    { method: 'PATCH', body: { description } },
  )
}

/** Add a knowledge entry to a board's config — file path XOR inline text.
 * POST /api/agent-kanbans/:kanbanId/knowledge */
export async function addAgentKanbanKnowledge(
  kanbanId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentKanbanKnowledgeRow> {
  return await apiFetch<AgentKanbanKnowledgeRow>(`/agent-kanbans/${kanbanId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentKanbanKnowledge(
  kanbanId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentKanbanKnowledgeRow> {
  return await apiFetch<AgentKanbanKnowledgeRow>(
    `/agent-kanbans/${kanbanId}/knowledge/${knowledgeId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentKanbanKnowledge(
  kanbanId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKanbanKnowledge(
  kanbanId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Add a named system-prompt block to a board's config. `content` required; `title` optional. POST
 * /api/agent-kanbans/:kanbanId/system_prompt */
export async function addAgentKanbanSystemPrompt(
  kanbanId: string,
  title: string,
  content: string,
): Promise<AgentKanbanSystemPromptRow> {
  return await apiFetch<AgentKanbanSystemPromptRow>(`/agent-kanbans/${kanbanId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentKanbanSystemPrompt(
  kanbanId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentKanbanSystemPromptRow> {
  return await apiFetch<AgentKanbanSystemPromptRow>(
    `/agent-kanbans/${kanbanId}/system_prompt/${promptId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentKanbanSystemPrompt(
  kanbanId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKanbanSystemPrompts(
  kanbanId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Get the enabled tool names for a board's config. Empty array = no tools configured for this
 * board. GET /api/agent-kanbans/:kanbanId/tools */
export async function getAgentKanbanTools(kanbanId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-kanbans/${kanbanId}/tools`)
}

/**  * Enable a tool for the board. Backend validates against the registry (400 if unknown) and returns
 * 409 on duplicate. POST /api/agent-kanbans/:kanbanId/tools */
export async function enableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<AgentKanbanToolRow> {
  return await apiFetch<AgentKanbanToolRow>(`/agent-kanbans/${kanbanId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/** Disable a tool for the board (deletes the row).
 * DELETE /api/agent-kanbans/:kanbanId/tools/:toolName */
export async function disableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

// ─── Agent-Routines Mirror (Migration 088) ───────────────────────────── Mirrors the Agent-Kanbans
// block above onto routine items.
export interface AgentRoutine {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentRoutineKnowledgeRow {
  id: string
  routine_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentRoutineSystemPromptRow {
  id: string
  routine_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentRoutineToolRow {
  id: string
  routine_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/**  * Get the agent-routines config + children for a routine workspace_item. Returns null (silent) on
 * 404 "not configured" — an unconfigured routine is an expected state, not an error worth
 * surfacing. GET /api/workspaces/:workspaceId/items/:itemId/agent_routine */
export async function getAgentRoutine(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent_routine: AgentRoutine
  knowledges: AgentRoutineKnowledgeRow[]
  tools: string[]
  system_prompts: AgentRoutineSystemPromptRow[]
} | null> {
  try {
    return await apiFetch<{
      agent_routine: AgentRoutine
      knowledges: AgentRoutineKnowledgeRow[]
      tools: string[]
      system_prompts: AgentRoutineSystemPromptRow[]
    }>(`/workspaces/${workspaceId}/items/${itemId}/agent_routine`, { silent: true })
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Update the agent-routines config's description.
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_routine */
export async function updateAgentRoutine(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent_routine: AgentRoutine }> {
  return await apiFetch<{ agent_routine: AgentRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/agent_routine`,
    { method: 'PATCH', body: { description } },
  )
}

/** Add a knowledge entry to a routine's config — file path XOR inline text.
 * POST /api/agent-routines/:routineId/knowledge */
export async function addAgentRoutineKnowledge(
  routineId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentRoutineKnowledgeRow> {
  return await apiFetch<AgentRoutineKnowledgeRow>(`/agent-routines/${routineId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentRoutineKnowledge(
  routineId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentRoutineKnowledgeRow> {
  return await apiFetch<AgentRoutineKnowledgeRow>(
    `/agent-routines/${routineId}/knowledge/${knowledgeId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentRoutineKnowledge(
  routineId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentRoutineKnowledge(
  routineId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Add a named system-prompt block to a routine's config. `content` required; `title` optional. POST
 * /api/agent-routines/:routineId/system_prompt */
export async function addAgentRoutineSystemPrompt(
  routineId: string,
  title: string,
  content: string,
): Promise<AgentRoutineSystemPromptRow> {
  return await apiFetch<AgentRoutineSystemPromptRow>(`/agent-routines/${routineId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentRoutineSystemPrompt(
  routineId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentRoutineSystemPromptRow> {
  return await apiFetch<AgentRoutineSystemPromptRow>(
    `/agent-routines/${routineId}/system_prompt/${promptId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentRoutineSystemPrompt(
  routineId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentRoutineSystemPrompts(
  routineId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Get the enabled tool names for a routine's config. Empty array = no tools configured for this
 * routine. GET /api/agent-routines/:routineId/tools */
export async function getAgentRoutineTools(routineId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-routines/${routineId}/tools`)
}

/**  * Enable a tool for the routine. Backend validates against the registry (400 if unknown) and
 * returns 409 on duplicate. POST /api/agent-routines/:routineId/tools */
export async function enableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<AgentRoutineToolRow> {
  return await apiFetch<AgentRoutineToolRow>(`/agent-routines/${routineId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/** Disable a tool for the routine (deletes the row).
 * DELETE /api/agent-routines/:routineId/tools/:toolName */
export async function disableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

// ─── Session background processes (bg-completion) ──────────────────────────── Backend:
// background_processes_list.zig + background_process_log_get.zig (commit b69111f7). `running` is
// live per row (OS truth, not the status column).
export interface BackgroundProcess {
  pid: number
  command: string
  log_path: string
  started_at: number
  status: string
  running: boolean
}

export interface BackgroundProcessListResponse {
  processes: BackgroundProcess[]
  count: number
}

export interface BackgroundProcessLogResponse {
  pid: number
  log_path: string
  total_bytes: number
  truncated: boolean
  content: string
}

/**  * List all background processes (`command background=true` rows) for a session, ordered by
 * started_at ASC. GET /api/llm/session/:sid/background_processes */
export async function getBackgroundProcesses(
  sessionId: string,
): Promise<BackgroundProcessListResponse> {
  return await apiFetch<BackgroundProcessListResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes`,
    { silent: true },
  )
}

/**  * Read the TAIL of one background process's log file. GET
 * /api/llm/session/:sid/background_processes/:pid/log?max_bytes=20480 `maxBytes` defaults to 20480,
 * clamped server-side to [1, 1048576]. */
export async function getBackgroundProcessLog(
  sessionId: string,
  pid: number,
  maxBytes = 20480,
): Promise<BackgroundProcessLogResponse> {
  const params = new URLSearchParams({ max_bytes: String(maxBytes) })
  return await apiFetch<BackgroundProcessLogResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes/${pid}/log?${params}`,
    { silent: true },
  )
}

// ─── Right-sidebar terminal (PTY over REST + poll) ─────────────────────────── Backend:
// terminal_create/input/output/resize/delete.zig (in-memory PTY registry, no migration).
export interface TerminalSession {
  id: string
  pid: number
}

export interface TerminalOutput {
  data: string
  cursor: number
  exited: boolean
  exit_code: number | null
}

/** Spawn a shell on a fresh PTY.
 * POST /api/terminal/sessions { workspace_id, cwd, shell?, cols?, rows? } -> 201 { id, pid }
 * `workspaceId` names whose VM hosts it; `--saas` refuses without one. */
export async function createTerminalSession(
  workspaceId: string,
  cwd: string,
  opts: { shell?: string; cols?: number; rows?: number } = {},
): Promise<TerminalSession> {
  return await apiFetch<TerminalSession>(`/terminal/sessions`, {
    method: 'POST',
    // NOTE: apiFetch stringifies `body` itself — pass the object, NOT
    // JSON.stringify (double-encoding yields a JSON string the server
    // rejects with 400; caught live 2026-09-16 via DevTools payload).
    body: { workspace_id: workspaceId, cwd, ...opts },
    silent: true,
  })
}

/** Write keystrokes to the PTY.
 * POST /api/terminal/sessions/:id/input { data } -> 200 { ok, bytes } */
export async function sendTerminalInput(
  id: string,
  data: string,
): Promise<{ ok: boolean; bytes: number }> {
  return await apiFetch<{ ok: boolean; bytes: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/input`,
    { method: 'POST', body: { data }, silent: true },
  )
}

/**  * Poll output since `cursor`. GET /api/terminal/sessions/:id/output?cursor=N -> 200 { data, cursor,
 * exited, exit_code } */
export async function getTerminalOutput(id: string, cursor = 0): Promise<TerminalOutput> {
  const params = new URLSearchParams({ cursor: String(cursor) })
  return await apiFetch<TerminalOutput>(
    `/terminal/sessions/${encodeURIComponent(id)}/output?${params}`,
    { silent: true },
  )
}

/** Resize the PTY window.
 * POST /api/terminal/sessions/:id/resize { cols, rows } -> 200 { ok, cols, rows } */
export async function resizeTerminal(
  id: string,
  cols: number,
  rows: number,
): Promise<{ ok: boolean; cols: number; rows: number }> {
  return await apiFetch<{ ok: boolean; cols: number; rows: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/resize`,
    { method: 'POST', body: { cols, rows }, silent: true },
  )
}

/** Kill the shell and drop the session.
 * DELETE /api/terminal/sessions/:id -> 200 { ok } */
export async function deleteTerminalSession(id: string): Promise<{ ok: boolean }> {
  return await apiFetch<{ ok: boolean }>(`/terminal/sessions/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    silent: true,
  })
}

// ─── Documents (Migration 095) ─────────────────────────────────────────── Workspace-scoped
// markdown documents. A document belongs to a workspace directly — it is NOT a `workspace_items`
// row and never appears in the project tree; the sidebar's Documents section is its only home.
export interface Document {
  id: string
  workspace_id: string
  title: string
  /** The markdown body. Always a string — the backend flattens SQL NULL to
   * `''`, so there is no null case to handle here. */
  content: string
  /** `'markdown'` in v1. Reserved for future formats. */
  format: string
  created_at: string
  updated_at: string
}

/**  * GET /api/workspaces/:workspaceId/documents All documents in one workspace, most-recently-updated
 * first. Backs the sidebar's Documents section, so it runs on every sidebar load. */
export async function listDocuments(
  workspaceId: string,
): Promise<{ documents: Document[]; count: number }> {
  return await apiFetch<{ documents: Document[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { track: false },
  )
}

/**  * GET /api/workspaces/:workspaceId/documents/:documentId Returns 404 for an id that does not exist
 * AND for one that belongs to another workspace — the backend reports both identically so this call
 * cannot be used to probe another workspace's row ids. */
export async function getDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/documents Body: `{ title, content?, format? }`. `title` is
 * required and must be non-blank; `content` may be empty (a blank note is a legitimate starting
 * state and round-trips as `''` rather than tripping the column's NOT NULL). */
export async function createDocument(
  workspaceId: string,
  title: string,
  content = '',
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { method: 'POST', body: { title, content } },
  )
}

/**  * PATCH /api/workspaces/:workspaceId/documents/:documentId Partial update. An OMITTED field keeps
 * its current value; `content: ''` genuinely clears the body. Omitting `content` does not clear it
 * — the two are different and the backend treats them differently. */
export async function updateDocument(
  workspaceId: string,
  documentId: string,
  patch: { title?: string; content?: string },
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'PATCH', body: patch },
  )
}

/**  * DELETE /api/workspaces/:workspaceId/documents/:documentId Returns 404 for another workspace's id,
 * and deletes nothing in that case. */
export async function deleteDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'DELETE' },
  )
}

// ─── Workspace secrets (Migration 101) ─────────────────────────────────── Named credentials
// scoped to one workspace: an API key the agent's tools can substitute into a request, never
// displayed back to the browser. NO RESPONSE EVER CONTAINS THE VALUE.
export interface Secret {
  id: string
  name: string
  created_at: string
  updated_at: string
}

/**  * GET /api/workspaces/:workspaceId/secrets Metadata only. A workspace with no secrets returns `{
 * secrets: [], count: 0 }` — which is a different answer from a failed request, and callers must
 * keep the two apart. */
export async function listSecrets(
  workspaceId: string,
): Promise<{ secrets: Secret[]; count: number }> {
  return await apiFetch<{ secrets: Secret[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/secrets Body: `{ name, value }`. `name` must be non-blank and
 * unique within the workspace; `value` is write-only — the response carries the created row WITHOUT
 * it. */
export async function createSecret(
  workspaceId: string,
  name: string,
  value: string,
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { method: 'POST', body: { name, value } },
  )
}

/** PATCH /api/workspaces/:workspaceId/secrets/:secretId Body: `{ name?, value? }`. Both fields are
 * partial — send `{ value }` to rotate a credential without touching its name, or `{ name }` to
 * rename without re-supplying a value. */
export async function updateSecret(
  workspaceId: string,
  secretId: string,
  patch: { name?: string; value?: string },
): Promise<{ secret: Secret }> {
  return await apiFetch<{ secret: Secret }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'PATCH', body: patch },
  )
}

/**  * DELETE /api/workspaces/:workspaceId/secrets/:secretId Returns 404 for another workspace's id, and
 * deletes nothing in that case. */
export async function deleteSecret(
  workspaceId: string,
  secretId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'DELETE' },
  )
}

// ─── models.dev catalog (Migration 106) ───────────────────────────────── The catalog is a
// machine-wide snapshot, cached in the DB and synced hourly in the background.
export type ModelCatalogState = 'fresh' | 'stale' | 'absent'

export interface ModelCatalogEntry {
  provider_id: string
  provider_name: string
  model_id: string
  model_name: string
  context_window: number | null
  output_tokens: number | null
  reasoning: string
  temperature: boolean
}

export interface ModelCatalogResponse {
  total: number
  returned: number
  catalog: ModelCatalogState
  fetched_at_ms: number
  models: ModelCatalogEntry[]
  /** The last background sync's failure, when it failed. ABSENT when the last
   * attempt succeeded or none has run yet — so its presence is itself the news. */
  last_sync_error?: string
  last_sync_at_ms?: number
}

export interface ModelResolve {
  model: string
  catalog: ModelCatalogState
  /** `catalog` = we know this model; `builtin` = pabrik's fallback guess. */
  source: 'catalog' | 'builtin'
  context_window: number
  output_tokens?: number | null
  provider_id?: string
  provider_name?: string
  model_name?: string
  base_url?: string
  url_style?: string
  reasoning?: string
  /** The model's own effort values, e.g. `low · high · max`. */
  effort_values?: string[]
  /** The subset of those pabrik can actually send. */
  effort_values_sendable?: string[]
  budget_min?: number | null
  temperature?: boolean
  cost?: { input: number; output: number } | null
  fetched_at_ms?: number
  /** Present only when the model could not be resolved. */
  reason?: string
  /** The last sync attempt failed with this error name (e.g. `InvalidPayloadJson`).
   * Absent otherwise. Without it the UI can only report a state, never a cause —
   * which is how "no catalog yet" stayed unexplained. */
  last_sync_error?: string
  last_sync_at_ms?: number
}

/** `GET /api/models/catalog` — the model picker's data. Filtered server-side. */
export async function getModelCatalog(
  q?: string,
  provider?: string,
  limit?: number,
): Promise<ModelCatalogResponse> {
  const params = new URLSearchParams()
  if (q) params.set('q', q)
  if (provider) params.set('provider', provider)
  if (limit) params.set('limit', String(limit))
  const qs = params.toString()
  return await apiFetch<ModelCatalogResponse>(`/models/catalog${qs ? `?${qs}` : ''}`)
}

/** `GET /api/models/resolve` — what a (model, provider) pair resolves to. */
export async function resolveModel(model: string, provider?: string): Promise<ModelResolve> {
  const params = new URLSearchParams({ model })
  if (provider) params.set('provider', provider)
  return await apiFetch<ModelResolve>(`/models/resolve?${params.toString()}`)
}

/** `POST /api/models/refresh` — fetch models.dev now instead of waiting an hour. */
export async function refreshModelCatalog(): Promise<{
  ok: boolean
  providers: number
  models: number
  fetched_at_ms: number
  bytes_raw: number
  bytes_trimmed: number
}> {
  return await apiFetch('/models/refresh', { method: 'POST' })
}

/** Best-effort `resolveModel`. The failure is a DISCRIMINATED RESULT, not a swallowed value:
 * `{kind:'error', message}` is not something a caller can mistake for `context_window: 0`, which is
 * exactly the bug the Effect-style rule exists to prevent. */
export type ModelResolveOutcome =
  { kind: 'ok'; value: ModelResolve } | { kind: 'error'; message: string }

export async function resolveModelOutcome(
  model: string,
  provider?: string,
): Promise<ModelResolveOutcome> {
  try {
    return { kind: 'ok', value: await resolveModel(model, provider) }
  } catch (err) {
    return { kind: 'error', message: err instanceof Error ? err.message : String(err) }
  }
}
