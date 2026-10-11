// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

import { createSseClient, type SseClient } from '../helpers/sseClient'
import { readGitStatusCache, writeGitStatusCache } from '../helpers/gitStatusCache'
import { Cause, Data, Effect } from 'effect'
import { describeCause } from '../helpers/effectRuntime'
import { joinMediaUrlsWire } from '../helpers/mediaUrls'

export const API_BASE = '/api'

import { useNotificationStore } from '../stores/notifications'
import { getActivePinia } from 'pinia'
import { useLoadingStore } from '../stores/loading'

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
  /**
   * When false, skip the top loading bar for this request. Defaults to
   * true — even `silent: true` requests show the bar (bar = network
   * activity, toast = error visibility; orthogonal concerns). Pass
   * `track: false` for background pollers (git status, stream snapshot)
   * so the bar can idle while they keep polling.
   */
  track?: boolean
  /**
   * Timeout in ms for the request. Default: 15_000. Set 0 to disable.
   * Uses `AbortSignal.timeout` when available, otherwise falls back to
   * an `AbortController` + `setTimeout`. A caller-provided `signal`
   * is respected and no timeout signal is added.
   */
  timeoutMs?: number
}

/**
 * Centralized HTTP wrapper. Auto-fires a toast notification on 4xx/5xx
 * responses (unless `silent: true`). Throws `ApiError` on non-OK so
 * callers can still implement fallback UI.
 *
 * Network failures (fetch rejects) propagate WITHOUT a notification —
 * those are covered by SseStatusBadge for SSE, and a global offline
 * toast is out of scope for v1.
 */
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
      // Auth enforcement: expired/revoked session mid-use → bounce to
      // /login?redirect=<current> (router guard covers boot; this covers
      // in-app expiry). Skip for auth endpoints themselves and when
      // already on /login to avoid loops.
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

// Re-export SseClient so call sites that hold a reference
// (e.g. `const workersSse: api.SseClient | null = null`) can
// import it from the same place they import the factory
// functions.
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
  /**
   * Free-text description of the column's meaning (e.g. "Awaiting
   * code review — tasks here must pass CI before merge"). Empty
   * string when no description has been set. The Settings UI
   * renders an "Add a description..." placeholder for empty
   * values. Optional for backwards compat with legacy column
   * literals in test files (see pabrik-frontend-task-literal-typing-rule).
   */
  description?: string | null
  position: number
  created_at: string
}

/**
 * Wire shape for `GET /api/workspaces/:wsId/items/:itemId/design/pages`
 * (list envelope) and `POST .../design/pages` (single page response).
 *
 * The numeric fields are `number` here even though the backend uses
 * `i64` — JSON has no integer/float distinction on the wire, so a
 * loose `number` keeps call sites that do arithmetic (e.g. position
 * comparisons) from fighting the type system. The backend's
 * `http_response.DesignPageResponse` (see src/ai_workflow/tui/http_handlers/
 * http_response.zig) is the canonical wire contract.
 *
 * Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
 *   (Chunk 5, Task 5.1)
 */
export interface DesignPage {
  id: string
  workspace_item_id: string
  name: string
  /**
   * 1:1 FK to `workspace_item_tasks.id`. Set at page-create time
   * by the backend; the frontend uses this directly to resolve the
   * page's chat task via `workspacesStore.setActiveTask(page.workspace_item_task_id)`
   * — no name matching, no legacy migration, no `taskHasMessages` probe.
   *
   * Story: introduced 2026-07-28 (plan:
   * docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md).
   * The previous design pattern-matched `"Design Chat: <page_name>"` against
   * `item.tasks` — fragile, silently broke on page renames, and left
   * orphan chat tasks when a page was deleted. The FK is the row-level
   * binding we're after.
   */
  workspace_item_task_id: string
  width: number
  height: number
  position: number
  created_at: string
  updated_at: string
}

/**
 * Element types emitted by the backend's `ElementType` enum
 * (src/ai_workflow/tui/agentic_loop/design_model.zig). Wire form is the lowercase
 * `tagName` string; the backend maps it back to the enum at the
 * handler boundary.
 */
/**
 * Normalize the `type` field on a design element from the wire.
 *
 * The `GET /design/pages/:page_id` endpoint emits `type` (matches the
 * frontend contract). The `POST .../elements/move-batch` endpoint
 * historically emitted `elem_type` (a Zig struct field name — see
 * the `makeDesignElementResponse` doc in
 * `http_handlers/http_response.zig`). After a single move-batch the
 * local store was mirrored with elements missing `type`, so
 * `props.element.type === undefined` on every subsequent drag →
 * `isGroupLike = false` → `triggerGroupDrag = false` → the cascade
 * path silently switched to the single-element translate path.
 *
 * This function accepts BOTH shapes: `type` wins when present,
 * `elem_type` falls back. Once the backend lands the
 * `makeDesignElementResponse` change for move-batch, the
 * `elem_type` branch is dead code — but we keep it as defense in
 * depth so legacy backends (e.g. an old build that didn't get
 * the fix) can't break the canvas again.
 */
export const normalizeDesignElementType = <
  T extends { type?: DesignElementType; elem_type?: string },
>(
  e: T,
): T & { type: DesignElementType } => {
  const fallback: DesignElementType = (e.elem_type as DesignElementType) ?? 'rectangle'
  return { ...e, type: e.type ?? fallback }
}

export type DesignElementType = 'rectangle' | 'ellipse' | 'text' | 'image' | 'frame' | 'group'

/**
 * Wire shape for design elements (the rows in
 * `design_page_elements`). Mirrors the backend's
 * `http_response.DesignElementResponse` struct — see
 * src/ai_workflow/tui/http_handlers/http_response.zig:709-734.
 *
 * Numeric fields are typed as `number` (not `i64`) because JSON has
 * no integer/float distinction; the backend serializes i64 values
 * as unquoted integers. `rotation` and `opacity` are f64 on the
 * backend; typed as `number` for the same reason.
 *
 * Optional string fields default to `''` on the backend (NOT NULL
 * DEFAULT ''), so an empty string is the "no value" sentinel for
 * `fill`, `stroke`, `text_content`, `text_style`, `image_url`,
 * `file_path`. The UI can therefore read these as truthy-or-empty
 * without nullability checks.
 */
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
  // NEW (Chunk 5 of grouped-layers plan): FK to a `group`/`frame`
  // element on the same page. Empty string `""` (NOT `null`) is the
  // wire form for NULL (matches the backend's empty-slice convention).
  // Optional because legacy elements returned by the API before this
  // field existed won't have it; the LayersPanel tree builder treats
  // `undefined` the same as `""` (top-level).
  parent_id?: string | null
  z_index: number
  position: number
  created_at: string
  updated_at: string
}

/**
 * Geometry-only patch payload for
 * `PATCH .../design/pages/:page_id/elements/:element_id/geometry`.
 * Every field is optional — the backend applies a sparse merge and
 * leaves omitted fields untouched. Used by the drag/resize
 * affordances in the canvas component (Chunk 7+).
 */
export interface DesignElementGeometry {
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/**
 * Wire shape for design-mode SSE events (the payload of
 * `design_element_created` / `design_element_updated` /
 * `design_element_deleted`).
 *
 * The backend emits all three with the same payload struct (see
 * `on_event_design.zig` — `DesignElement{Created,Updated,Deleted}Data`
 * are structurally identical). The `action` discriminator lets the
 * frontend route without needing separate interfaces.
 *
 * Field names match the backend's JSON keys: snake_case for ids
 * (matches the SSE wire format), `action` is the lowercase
 * discriminator string.
 */
export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  page_id: string
  element_id: string
  /**
   * Batch event variant (design_elements_geometry_batch_updated,
   * Chunk 3 of design-drag-debounce-batch). When set, the SSE
   * handler reads `element_ids` instead of `element_id` to drive
   * the local-mutation dedupe. Optional for backward compat with
   * existing single-element events.
   */
  element_ids?: string[]
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // The on-disk cwd for kanban items. Optional because:
  //   (a) legacy kanbans created before this field existed have no path
  //       (the API returns `null` from the DB, not `undefined`);
  //   (b) folder items (item_type = 'folder') never have a path here
  //       (their `path` lives on each FolderEntry child, not the item);
  //   (c) test fixtures in 5+ test files omit the field entirely.
  // Allow `null` so API responses with `path: null` (the SQLite NULL →
  // JSON null round-trip) type-check; the runtime `v-if="!item.path"`
  // already treats null AND undefined AND "" the same way.
  path?: string | null
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // `item_type === 'kanban'`; omitted for folder/chat/memory items.
  // Optional so legacy workspace-item literals (5+ test files
  // construct WorkspaceItem without this field) keep type-checking —
  // see the pabrik-frontend-task-literal-typing-rule memory.
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
  // NEW (pinned-tasks feature, plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md).
  // Both optional so legacy task literals (8+ test files construct Task
  // without these fields) keep type-checking — see the
  // pabrik-frontend-task-literal-typing-rule memory.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // tasks under `item_type === 'kanban'` parents. `kanban_column_id`
  // is `null` (not undefined) when the task is unassigned (e.g. its
  // column was deleted). Both optional so legacy task literals keep
  // type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (kanban task tags, Migration 067). Array of free-form tag
  // strings. Empty array = no tags. Optional so legacy task
  // literals in tests keep type-checking. On the wire the field is
  // a JSON-encoded array string; the store normalizes via
  // `normalizeTaskTags` at every fetch site.
  tags?: string[]
  // NEW (kanban image urls, Migration 069). Array of base64 data
  // URLs (`data:image/<mime>;base64,<payload>`). Empty array = no
  // images. Optional so legacy task literals in tests keep
  // type-checking. On the wire the field is a `||`-delimited string
  // (matching the `llm_history.image_url` convention); the store
  // splits on `|` and filters empty segments on every fetch, and
  // joins back with `||` before sending. Plan:
  // docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md.
  imageUrls?: string[]
  // NEW (kanban video urls, Migration 090). Array of base64 data
  // URLs (`data:video/<mime>;base64,<payload>`). Empty array = no
  // videos. Same `||`-delimited wire convention as imageUrls.
  videoUrls?: string[]
  // NEW (Media-flags change — lightweight list/get payload). The backend
  // list/get return only these flags; the full base64 TEXT stays
  // server-side for the lazy `getTaskMedia` endpoint below. The
  // frontend fetches media only when the flag is true.
  is_have_image?: boolean
  is_have_video?: boolean
  // NEW (Migration 070 — kanban-cwd-session-optional plan).
  // Per-task cwd override (absolute path on disk, or '' for
  // cwd-less). Optional so legacy task literals in tests keep
  // type-checking. The frontend's KanbanView reads this on every
  // task fetch and threads it into the 3-level cwd fallback chain
  // (per-task cwd → kanban-level path → sandbox) at
  // runAgentOnNewTask time. Empty string is the canonical
  // "no per-task cwd" sentinel — falls back to the kanban's
  // `path` + the per-session sandbox.
  cwd?: string
  // NEW (kanban task git-branch badge, plan:
  //   docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
  // The current git branch for the task's cwd — worktree cwd if
  // bound (`session.git_worktree_cwd`), else the parent workspace
  // item's `path`. Computed on-demand per request by the backend
  // (`git -C <cwd> symbolic-ref --short HEAD` with rev-parse
  // fallback for detached HEAD). `null` when the cwd is not a git
  // repo or the HEAD is detached; UI omits the badge in that case.
  // Mirrors the `git_branch` field on `WorkspaceItemTaskResponse`
  // (see backend `src/ai_workflow/tui/http_handlers/http_response.zig`).
  // snake_case matches the wire format and the existing convention
  // in this interface (`task_type`, `is_pinned`, `kanban_column_id`,
  // etc.) — the `api.getTasks` mapper returns `data.tasks` raw, so
  // the wire name IS the TS name. No normalization needed.
  git_branch?: string | null
}

/**
 * Split a mixed array of base64 data URLs into images vs videos
 * (Migration 090). Callers pass through whatever FileInput /
 * KanbanDescriptionEditor staged; `data:video/...` entries ride
 * `video_urls`, everything else rides `image_urls`. Explicit
 * `videoUrls` args are merged in (deduped by the backend's
 * empty-segment-tolerant split).
 */
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
export async function getSystemFolder(): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>('/system/folder?action=list')
}

export async function listFolder(path: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(`/system/folder?path=${encodeURIComponent(path)}&action=list`)
}

/**
 * Server-side recursive file search for the ChatView `@` picker
 * (plan: docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md
 * Task 2). Single round-trip — replaces the old N-sequential-fetch
 * full-tree walk. Uses `apiFetch` (not raw fetch) for timeout/auth
 * handling. Backend: `GET /api/system/folder?action=search` returns
 * `{ entries: [{name, path, is_directory, is_symlink}] }` (snake_case,
 * length <= limit, fat dirs skipped server-side).
 */
export async function searchFiles(
  cwd: string,
  q: string,
  limit = 50,
  max_depth = 8,
  signal?: AbortSignal,
): Promise<{ entries: FolderEntry[] }> {
  return await apiFetch<{ entries: FolderEntry[] }>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=search&q=${encodeURIComponent(q)}&limit=${limit}&max_depth=${max_depth}`,
    { signal, silent: true },
  )
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  // Items are loaded separately via getWorkspacesItems(workspace_id) —
  // this keeps the workspaces list small and lets us fetch items lazily.
  // Persists the list to the workspacesCache (fail-silent) so the next
  // init can paint instantly and revalidate in the background.
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

// Cold-start fallback for the "New Chat" action.
//
// The invariant is "every workspace has a default project, and a miss
// creates one" — and `GET /workspaces/:id/items` (above) already enforces
// it server-side, so `getWorkspacesItems` normally comes back with the
// default in it and a client lookup is a pure local find.
//
// This endpoint exists for the one case the list cannot cover: the app
// was open when Migration 094 ran, so the list the store already holds
// predates the `is_default` column. Without this, a New Chat tap would be
// a no-op until the user manually refetched.
//
// Idempotent — 200 + `created: false` when it already existed, 201 +
// `created: true` when this call created it. Takes no body: it is a
// command ("give me the default"), and the name and path are fixed by the
// invariant.
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

/**
 * Persist a new top-to-bottom display order for workspaces.
 * POST /api/workspaces/reorder with body `{ordered_ids: [...]}`. The
 * server reverses the array when assigning position values (top of
 * list = highest position). On any non-2xx response, throws
 * `new Error("HTTP <status>")` so the caller can roll back its
 * optimistic update.
 *
 * The list shape is the *full* ordered set, not a delta. Reordering
 * two adjacent rows means re-sending ALL workspace IDs in their new
 * order. The backend is idempotent — a second call with the same
 * array leaves the data unchanged.
 *
 * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
 */
export async function reorderWorkspaces(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>('/workspaces/reorder', {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

/**
 * Persist a new top-to-bottom display order for the items of a single
 * workspace. POST /api/workspaces/:workspace_id/items/reorder with
 * body `{ordered_ids: [...]}`. The server reverses the array when
 * assigning position values (top of list = highest position). On any
 * non-2xx response, throws `new Error("HTTP <status>")` so the caller
 * can roll back its optimistic update.
 *
 * Mirrors `reorderWorkspaces` but scoped to a single workspace's
 * items. The list shape is the *full* ordered set for that
 * workspace, not a delta.
 *
 * Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
 */
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
/**
 * Fetch tasks for a workspace item, with optional cursor pagination.
 *
 * @param workspaceId  - owning workspace
 * @param itemId       - workspace item (e.g. a project folder)
 * @param limit        - page size (default 20; backend clamps at 100)
 * @param cursor       - the encoded "<sort_value>|<id>" from the
 *                       previous page's `next_cursor`; pass undefined
 *                       for the first page
 * @param sortBy       - field to sort by: 'created_at' | 'updated_at'
 *                       | 'name'. Default: undefined — the backend
 *                       applies its own default ('updated_at'). Send
 *                       an explicit value when the URL has a sort
 *                       param (`?sorts=col_X:updated_at:desc`) and
 *                       the user wants the backend to honour it.
 *                       Both `sortBy` AND `direction` must be provided
 *                       together; otherwise the backend defaults apply.
 * @param direction    - 'asc' | 'desc'. Default: undefined (backend
 *                       default 'desc'). See sortBy for the pairing
 *                       rule.
 * @param columnId     - optional kanban column id (per-column
 *                       pagination, plan 2026-08-06-kanban-per-column-
 *                       pagination.md). When set, the backend's WHERE
 *                       clause restricts results to tasks whose
 *                       `kanban_column_id` matches (or IS NULL,
 *                       preserving legacy rows). When unset, the
 *                       full board-wide result is returned (the
 *                       initial page of every kanban view).
 * @param q            - optional case-insensitive substring filter
 *                       applied at the SQL level against `name`,
 *                       `description`, and `tags`. Pass undefined or
 *                       '' to disable the filter. The backend escapes
 *                       `%`/`_`/`\` in the input before binding, so a
 *                       user typing `%` matches a literal `%` in the
 *                       data (not every row). Pagination advances
 *                       through the filtered set, not the unfiltered
 *                       set, when q is set.
 * @returns `{ tasks, has_more, next_cursor }`. `next_cursor` is null
 *          when there are no more pages.
 */
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 10,
  cursor?: string,
  // NEW (2026-08-06): NO default values. The frontend used to send
  // `sort_by=updated_at&direction=desc` on every task-fetch — even
  // when the user hadn't picked a sort, the URL had no sort, and
  // the backend would have used its own identical default. The
  // user feedback was "no need set default when load task kanban" —
  // pass `undefined` for both when no sort is in play, and let the
  // backend's default (`updated_at desc`) handle it. Same wire
  // result, cleaner URL, less coupling.
  //
  // Both must be provided together — we don't send `sort_by` without
  // `direction` (or vice versa) because the backend's cursor format
  // depends on the sort field. If only one is passed, we fall back
  // to "no sort params" and let the backend default apply.
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

/**
 * Fetch ONE workspace item task by id (kanban Task details dialog).
 * GET /api/workspaces/:ws/items/:item/tasks/:task_id → { task } | 404.
 *
 * Resolves to the Task, or null on 404 (task deleted / wrong item in
 * the path). Replaces the old refreshTask list-refetch (limit=100) —
 * one row on the wire instead of the whole board.
 *
 * 404 is silent (no error toast) — "the task is gone" is an expected
 * state, not an error worth surfacing. Other failures (network, 5xx)
 * throw ApiError; the store's best-effort catch handles them.
 *
 * Plan: docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md
 */
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

/**
 * Stamp `workspace_item_tasks.last_human_touched_at` so the kanban
 * card flips from the orange "AI finished — awaiting review" dot
 * to the green "reviewed" checkmark. Fire-and-forget: the caller
 * does NOT await this — failures log a warning but don't surface
 * as toasts (the user's primary action has already succeeded).
 *
 * Idempotent on the server side (re-stamping is harmless — the
 * column is just a monotonic timestamp). The backend also emits
 * a `kanban_task.human_touched` SSE event so other connected
 * clients refresh without a manual round-trip.
 *
 * Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md
 *   (Chunk 7 — frontend open-task stamp).
 */
/**
 * Lazy media fetch for ONE task (media-flags change).
 * GET /api/workspaces/:ws/items/:item/tasks/:task_id/media
 *   → { image_urls, video_urls } (`||`-delimited raw strings).
 *
 * List/get return only `is_have_image` / `is_have_video` flags so
 * board fetches stay small; call this only when a flag is true.
 * Resolves to split arrays (empty when the column is '').
 * 404 → null (task deleted / wrong item).
 */
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

/**
 * Parallel media fetch for MANY tasks (media-flags change).
 *
 * Fires one `getTaskMedia` per id concurrently and settles every leg
 * (`Promise.allSettled`): a single 404 / network blip resolves that
 * entry to null instead of rejecting the whole batch. Callers awaiting
 * N tasks pay ~one round-trip, not N sequential ones.
 */
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

/**
 * Create a task under a workspace item.
 *
 * The third arg is a single params object. For a standard task
 * (the default), pass `{ name, description?, taskType: 'standard' }`.
 * For a memory, pass `{ name, taskType: 'memory', memory: { name, content } }`.
 *
 * NOTE: `taskType: 'routine'` was deleted (Migration 084) — routines
 * are now first-class workspace items, see `createRoutineItem`.
 *
 * The backend stores `task_type` on `workspace_item_tasks`.
 * For memories, the backend creates the .md file
 * at `<workspace_item.path>/.pabrik/memories/<name>.md` AND inserts
 * the task row pointing at it.
 */
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
    // Auto-retry-until-stop (Migration 063, Option A fix): when the
    // caller passes `'1'`, the backend ALSO inserts a `sessions`
    // row (task.id == session.id per the project convention) so the
    // unattended-mode flag has somewhere to land at create time.
    // Only meaningful for `taskType: 'standard'` — memory tasks
    // manage their own session lifecycle elsewhere.
    // `'0'` and undefined/empty are treated equivalently (no
    // session INSERT).
    isAutoRetryUntilStop?: string
    // Kanban task tags (Migration 067 — kanban task tags feature).
    // Array of free-form tag strings. Empty array / undefined = no
    // tags. Forwarded as a JSON-encoded array string on the wire.
    // The backend validates (char whitelist [a-zA-Z0-9_-], length
    // cap 50 chars per tag, case-insensitive dedupe). Plan:
    // docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags?: string[]
    // NEW (Migration 069 — kanban image urls column). Array of
    // base64 data URLs (`data:image/<mime>;base64,<payload>`).
    // Empty array / undefined = no images. Forwarded as a
    // `||`-delimited string on the wire (matching the
    // `llm_history.image_url` convention). The backend validates
    // each segment's `data:image/...;base64,...` prefix + the
    // total 10 MB byte cap. Plan: docs/superpowers/plans/
    // 2026-08-06-kanban-image-urls-column.md.
    // NOTE (Migration 090): may also carry `data:video/...` URLs —
    // splitMediaUrls routes those to `video_urls` at send time.
    imageUrls?: string[]
    // NEW (Migration 090 — kanban video urls column). Array of
    // base64 data URLs (`data:video/<mime>;base64,<payload>`).
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    // Per-task cwd override. Absolute path on disk or '' for
    // cwd-less. When undefined, the backend stores NULL (cwd-less
    // task — falls back to the kanban-level path + sandbox).
    // The frontend's KanbanTaskDetailDialog passes the picked
    // folder via this field on task-create. The session_create
    // 3-level fallback chain reads the persisted value via the
    // task fetch + threads it into `runAgentOnNewTask` →
    // `api.sendChatMessage`'s `cwdSession` arg.
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
  // Forward tags as a JSON-encoded array string (Migration 067).
  // The backend's tags_validation.validateAndNormalizeTags parses
  // and re-encodes the array, so the wire shape is a JSON string,
  // not an array — single source of truth for JSON shape.
  if (params.tags && params.tags.length > 0) {
    body.tags = JSON.stringify(params.tags)
  }
  // Migration 069 — image_urls. The wire shape is a `||`-delimited
  // string (matching `llm_history.image_url`). The backend's
  // image_urls_validation.validateImageUrls validates each segment's
  // data URL prefix + the total 10 MB byte cap.
  // Migration 090 — split data:video/... out to video_urls.
  {
    const { images, videos } = splitMediaUrls(params.imageUrls, params.videoUrls)
    if (images.length > 0) body.image_urls = joinMediaUrlsWire(images)
    if (videos.length > 0) body.video_urls = joinMediaUrlsWire(videos)
  }
  // Migration 070 — per-task cwd override. Forward verbatim
  // (the backend's `validated_cwd` block validates it — absolute
  // path, ≤ 4 KiB, no control chars). Empty string forwards as
  // the explicit "no per-task cwd" sentinel; undefined forwards
  // as null (column omitted from INSERT, DEFAULT '' applies).
  if (params.cwd !== undefined) {
    body.cwd = params.cwd
  }
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    body,
  })
}

/**
 * Kanban-specific task create endpoint.
 *
 * The backend (POST /api/workspaces/:wid/items/:iid/kanban/tasks) accepts
 * a `mode` discriminator:
 *   - mode='create'         — create the task only (analogous to /tasks POST)
 *   - mode='create_and_run' — create + insert sessions row + queue the
 *                             first message (analogous to /llm/session POST
 *                             with session_id=task.id). Returns the session
 *                             in `response.session`.
 *
 * The endpoint rejects 404 when the parent item is not a kanban (the
 * generic /tasks route is the fallback for non-kanban items).
 *
 * Plan: docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md
 */
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
}

/**
 * New mode (`create_session`) — inserts the sessions row keyed by
 * task.id + persists selected_profile_model + emits session_created
 * SSE, but does NOT call emit_run_agent. Returns
 * `session: { id, name, status: 'idle' }`. No `queue_message` field
 * (the agent never starts on this path).
 *
 * Plan: docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md
 */
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
  if (payload.mode === 'create_and_run') {
    body.queue_message = payload.queue_message
    if (payload.selected_profile_model !== undefined) {
      body.selected_profile_model = payload.selected_profile_model
    }
  } else if (payload.mode === 'create_session') {
    // Persists on the new sessions row. Path A (from the 2026-08-06
    // kanban-task-profile-selector plan) used to skip this for plain
    // create; with the new mode inserting the session row, persisting
    // the profile is now free and the chatview reflects the choice
    // immediately when the user clicks the card.
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

// Task API - Simple version (just task_id + optional fields)
//
// The backend's PUT /api/workspaces/tasks/:task_id accepts a
// subset of fields. The server cascades any name change to the
// linked session and re-broadcasts via SSE.
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
    // NEW (kanban image urls, Migration 069): array of base64 data
    // URLs. Forwarded as `||`-delimited string (matching the
    // `llm_history.image_url` convention). Empty array = clear
    // images. Plan: docs/superpowers/plans/2026-08-06-kanban-image-
    // urls-column.md.
    imageUrls?: string[]
    // NEW (kanban video urls, Migration 090): same contract as imageUrls.
    videoUrls?: string[]
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    // Per-task cwd override. Semantics:
    //   - undefined: leave unchanged (no-op).
    //   - '': clear per-task cwd (falls back to kanban-level path
    //     + sandbox).
    //   - '/home/me/repo-A': set per-task cwd to this path.
    // Forwarded verbatim on the wire (the backend's
    // `validated_cwd` block in task_update.zig re-validates on
    // every PUT).
    cwd?: string
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

/**
 * Pin or unpin a task. The backend bumps the row's
 * `pinned_position` to MAX+1 (when pinning) so a newly-pinned task
 * lands at the BOTTOM of the pinned region; the user can drag it
 * to a different position afterwards. Returns the new
 * `pinned_position` so the store can confirm the row landed where
 * the user expects.
 *
 * 404: task not found
 * 500: DB write failed
 */
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

/**
 * Reorder the pinned subset of a single workspace item. The
 * `orderedIds` array is the full top-to-bottom display order of
 * the pinned rows. The backend assigns `pinned_position =
 * count - 1 - i` so the rows render in the user's chosen order.
 *
 * Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md
 */
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

/**
 * Manually fire a workspace routine. Returns the session_id (which
 * equals the routine id — every fire appends to the same session
 * chat). The backend responds 200 + body as soon as the fire is
 * submitted — the actual LLM call happens asynchronously.
 *
 * 404: routine does not exist (or doesn't belong to this item)
 * 409: routine is disabled or another fire is in progress
 * 500: fire failed
 */
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

/**
 * Trigger an LLM worker on an existing task's session WITHOUT queueing
 * a new user message. For tasks with chat history, the agent resumes
 * the conversation. For tasks with no chat history, the agent responds
 * based on its system prompt alone (typically a clarification message).
 *
 *   200: `{ success: true, session_id, status: 'triggered' }`
 *   404: task does not exist (or doesn't belong to this workspace/item)
 *   409: a worker is already running for this session
 *   500: server error
 *
 * The response shape is the raw JSON body — the caller checks
 * `success` to determine whether to close the dialog. The status code
 * is in the `Response` object (use `fetch` directly for status-aware
 * dispatch; this helper returns the parsed body).
 *
 * Distinct from `runWorkspaceRoutine` (workspace-routine manual fire)
 * and `sendChatMessage` (POST /api/llm/session, which always queues a new
 * user message). Plan: docs/superpowers/specs/
 * 2026-08-18-kanban-task-detail-start-agent.md
 */
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

/**
 * Bulk "Run all agents" for one kanban column (plan:
 * docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md,
 * Task 4, Option C).
 *
 *   POST /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents
 *   200: `{ success: true, column_id, started: string[], skipped: string[], failed: string[] }`
 *   404: unknown column
 *   500: server error
 *
 * The server owns the task list (SELECTs all task ids for the column
 * server-side and loops the single-task startAgentUseCase per id), so
 * pagination is irrelevant — the frontend calls this once and surfaces
 * the `{started, skipped, failed}` summary. No new SSE event; run-state
 * visuals stay on the existing `processingState`/SessionSlider flow.
 */
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
  /// Backend wall-clock timestamp of the last `sessions.UPDATE` —
  /// bumped by everything (agent loop, profile change, error, etc).
  /// `ChatsList.vue` renders this as the time pill's fallback when
  /// `last_human_touched_at` is empty (pre-Migration-082 legacy rows).
  /// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
  updated_at?: string
  /// Migration 063 — "0" / "1" opt-in for unattended mode. Always
  /// present in the GET /api/sessions response (ChatsList uses this
  /// to render the `🔁 unattended` badge).
  is_auto_retry_until_stop?: string
  /// Migration 082 — unix-ms string of the last time a HUMAN interacted
  /// with this session. Empty string (NOT undefined) for legacy rows so
  /// the ChatsList time pill can fall back to `updated_at` predictably.
  /// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
  last_human_touched_at?: string
  /// Migration 104 — pinned sessions (PINNED section above RECENT).
  /// True when the user pinned via right-click menu. Always present
  /// in GET /api/sessions (COALESCE'd server-side).
  is_pinned?: boolean
  /// Migration 104 — position inside the pinned region (MAX+1 on pin,
  /// 0 when unpinned). PINNED section sorts by this DESC.
  pinned_position?: number
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
  /**
   * 2026-08-23 hidden-messages fix — thinking models' chain-of-thought.
   * Already returned by the backend REST endpoint (http_response.zig
   * SessionMessage.reasoning_content) and the SSE payload; previously
   * unmapped so ChatView never saw it.
   */
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
/**
 * The transcript fetch failed — transport, non-2xx, or an abort.
 *
 * Deliberately coarse: the UI acts on "the transcript is unavailable", not on
 * which kind of unavailable it is, and the retry policy is the same for all
 * three. The point of the tag is only that the failure is DISTINGUISHABLE
 * from an empty transcript — see the empty-state bug this replaced.
 */
export class ChatHistoryError extends Data.TaggedError('ChatHistoryError')<{
  readonly sessionId: string
  readonly reason: string
}> {}

/**
 * What a best-effort transcript caller gets when the fetch failed. Named, not
 * inlined, so the two shapes can be diffed by eye: every field is `undefined`
 * or empty because the answer genuinely is unknown, and the only place this is
 * legitimate is `getChatHistory`'s three metadata callers.
 */
const EMPTY_CHAT_HISTORY: ChatHistoryResponse = {
  messages: [],
  has_more: false,
  next_cursor: null,
  cwd: undefined,
  git_worktree_cwd: undefined,
  pr_url: undefined,
  pr_provider: undefined,
  // 2026-08-07-profile-persist-read — preserve the field shape on
  // the error path so ChatView's `loadChatHistory` branch can
  // safely read `data.selected_profile_model` (it'll be
  // `undefined`, which ChatView coerces to `null`).
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
  /// Session's selected profile name (empty/missing = "Default", i.e.
  /// no profile selected). Mirrors the backend `sessions.selected_profile_model`
  /// column. Populated by the backend's `GET /api/llm/session/:id/messages`
  /// handler so the chatview's profile chip survives a page refresh
  /// (fixes "profiles in chatview not persistent" — the chatview
  /// dropdown writes via PUT /api/llm/session/:id but the read endpoint
  /// never returned the value, so the chip reset to "Default" on
  /// refresh).
  selected_profile_model?: string
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  total_count?: number
  skills?: SkillInfo[]
}

/**
 * The transcript endpoint, WITH the failure in the type.
 *
 * Returns `Effect<ChatHistoryResponse, ChatHistoryError>`, so "the backend is
 * unreachable" is a value the caller must handle — it cannot be mistaken for
 * an empty transcript. That distinction is the whole fix: a slow or erroring
 * backend previously returned `messages: []`, the empty state's `v-if` went
 * true, and the chatview claimed a full session was empty ("How can I help
 * you?"). See AGENTS.md, "Frontend — No `try`/`catch` in the desktop app".
 *
 * `getChatHistory` (below) is the explicitly-named best-effort variant built
 * on this one, for the three metadata callers whose fallback chains depend on
 * degrading quietly.
 *
 * `timeoutMs` lets the transcript load outlive apiFetch's 15 s default: a
 * `limit=1000` page carrying base64 image_urls and tool JSON routinely needs
 * longer, and that abort is what turned a slow server into a phantom empty
 * session.
 */
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
  // silent: true — the failure is the caller's to handle (the chatview's retry
  // loop + inline error UI for the transcript; a console.log for the
  // best-effort metadata callers), so a toast on 404/5xx would be noise.
  //
  // `timeoutMs` is forwarded so the initial transcript load can outlive
  // apiFetch's 15 s default: a `limit=1000` page carrying base64 image_urls
  // and tool JSON routinely needs longer, and that abort is what turned a slow
  // server into a phantom empty session. Left undefined, the default stands.
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
    // 2026-08-07-profile-persist-read — read the per-session
    // selected profile name so the chatview chip can show the
    // persisted selection on page refresh. Empty string from the
    // backend (= "no profile set") is preserved here; ChatView
    // coerces empty → null before assigning to selectedProfile.
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

/**
 * Best-effort transcript: a failure yields an EMPTY transcript rather than a
 * rejection, implemented on the Effect seam so no `try`/`catch` sits between
 * the failure and the value the caller gets.
 *
 * Correct ONLY for the three metadata callers — AppLayout's cwd fallback,
 * ChatView's `refreshWorktreeBinding` (`limit=1`), and the older-page
 * prefetch — whose fallback chains depend on degrading quietly. The initial
 * transcript load must use `fetchChatHistoryEffect`, so "the backend is
 * unreachable" can never be handed to the UI as "this session is empty".
 */
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

// Send a message to LLM
//
// Migration 063 — adds the optional `isAutoRetryUntilStop` flag.
// "1" opts into unattended mode (the workflow re-reads this column
// on entry and soft-bails past retry_count > 10). Default undefined
// = today's behavior.
// Default tools for a new chat session (created from a workspace item).
// Minimal progressive-disclosure set: the agent discovers everything else
// via search_tool / view_tool / use_tool. `command` for shell,
// `load_memory` / `save_memory` for recall, `search_skills` + `use_skill` for skills.
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
  // Introspection: list the tools equipped for this session ("what
  // tools do I have"). Read-only, sub-agent-safe. Seeded here so
  // plain chat, design mode, and routine sessions (which all use
  // this request body) get it; agent/kanban modes seed it via
  // backend DEFAULT_AGENT_TOOLS.
  'used_tools',
  // Interactive: ask the human a question (ends the turn until they answer).
  // Seeded in every mode by default — without it here the tool would be
  // silently filtered out of plain chat sessions.
  'ask_user',
  // Workspace-scoped documents (Migration 095). Both resolve their own
  // workspace server-side from the calling session, so a plain chat is as
  // safe as a project task: outside a workspace-linked session they refuse
  // rather than guessing a scope. Seeded here because a chat is exactly
  // where a user says "write that down".
  'add_document',
  'edit_document',
  // Read-only counterpart: `edit_document` replaces the WHOLE body, so a
  // chat agent cannot revise a note it wrote earlier without a way to
  // find the row first.
  'search_documents',
  // `delete_document` is intentionally omitted — irreversible, and it does
  // not belong in the set every plain chat starts with. It stays one click
  // away in Settings → Tools, and an agent can also reach it through
  // search_tool → use_tool, which bypasses the allowlist.
].join(',')

export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
  isAutoRetryUntilStop?: string,
  videoUrls?: string[],
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
    // Preserve the original return-shape semantics so ChatView can
    // branch on `status` for user-facing messages:
    //   'bad_request'         — backend 400
    //   'unprocessable_entity'— backend 422
    //   'http_error'          — backend 4xx/5xx other than the above
    //   'offline'             — network failure / fetch rejected
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}

// Update an existing session (selectedProfile, name, isAutoRetryUntilStop).
//
// Migration 063 — extends the update shape to carry the unattended-
// mode flag. Pass `isAutoRetryUntilStop: '0'` to disable, '1' to
// enable, or omit to leave unchanged (matches the backend's
// `len > 0` guard).
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

// POST /api/llm/session/:session_id/touched — stamp the human-touch
// column when the user opens a chat (clears the amber stale-dot).
// Contract: body {}, response { success, session_id }.
// Silent: the caller (ChatsList fireSessionTouched) already logs failures
// via console.error and retries by clearing its once-per-lifetime guard.
// A toast here would spam "Session not found" on every New Chat open
// while the session row is still being lazy-created.
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

// Migration 104 — pin/unpin a session for the PINNED section above RECENT.
// Mirrors `pinTask` (kanban). The backend bumps `pinned_position` to MAX+1
// on pin (lands at bottom) and syncs the linked task row when
// task.id == session_id, so kanban pin buttons stay in sync.
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
  // 2026-08-24 (task_1787545088500_6, bug A) — backend
  // SseEventLLMHistory (sse_on_event_send_llm_history.zig:150) sends
  // the assistant row's serialized tool_calls array on the wire as
  // `tool_calls_json`. ChatView.vue:groupToolNames walks
  // `parsed[i].id` against the renderedToolCallIds set to suppress
  // the redundant "tools" pill when every tool_call has a matching
  // tool row. Without this field, the SSE-pushed message has
  // tool_calls_json=undefined, the suppression check is bypassed,
  // and the pill flashes between every tool card. Frontend parse is
  // mirrored on the REST path at getChatHistory (~line 1198).
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
  // Pipe-separated image URLs (matches the REST SessionMessageResponse
  // shape and the backend onEventSendLLMHistory payload). Frontend
  // splits on '|' to populate Message.image_urls. Null for messages
  // without attached images (most assistant responses, error paths,
  // tool results that don't carry image data).
  image_url?: string
  // Pipe-separated video URLs (Migration 090, backend
  // SseEventLLMHistory.video_url). Split on '|' into video_urls.
  video_url?: string
  // Live session skills pushed on the SSE wire (backend:
  // sse_on_event_send_llm_history.zig:45 SseEventLLMHistory.session_skills,
  // next to is_error). REST-vs-SSE key note: the REST GET /messages path
  // exposes these as `skills` (getChatHistory) while SSE uses
  // `session_skills` — keep both keys, don't unify.
  session_skills?: SkillInfo[]
  // True when this event is an agentic-loop diagnostic (retry attempt or
  // TooManyRetries bail) rather than a real chat turn. Backend:
  // sse_on_event_send_llm_history.zig SseEventLLMHistory.is_error — set
  // by workflow.zig's 3 diagnostic sites. ChatView routes these into
  // AgentErrorCard instead of the message list.
  is_error?: boolean
}

// List all chat sessions with pagination
export async function getChats(
  sortBy: 'created_at' | 'updated_at' | 'session_name' | 'agent' = 'created_at',
  direction: 'asc' | 'desc' = 'desc',
  limit: number = 10,
  cursor?: string,
  // Workspace scope (plan: 2026-09-22-revamp-ui-chats). When set, the
  // backend returns only that workspace's sessions (task-linked +
  // cwd-matched); empty/unknown → empty list (fail-closed). Omitted
  // → global list (back-compat for non-scoped callers).
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
          // Sidebar git badge — forward the bound worktree path and
          // the per-request resolved branch ("" = no badge). Empty
          // string when absent so the ChatsList `v-if` is a defined
          // check (NOT undefined).
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
    // The empty-list shape is a deliberate contract (callers render an
    // empty section instead of crashing), but it is indistinguishable
    // from "this scope has no sessions" — so a swallowed transport
    // failure used to blank a populated sidebar with nothing in the
    // console to explain it. Log the reason; the caller decides whether
    // an empty page is believable (see ChatsList's empty-refresh guard).
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

// Session API - Fetch session info including cwd.
// Lightweight detail read: GET /api/llm/session/:id returns the sessions
// row (cwd, profile, worktree binding, PR binding, ...) with NO message
// payload. Previously this used GET .../messages?limit=1, which returned
// the oldest message (backend defaults to asc) — a single row carrying
// full tool JSON / base64 that routinely weighed ~194 kB. Two mount-time
// callers (AppLayout.fetchChatSessionCwd + ChatView.onSessionChanged) fired
// it concurrently for the same session, doubling the waste.
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
      // 2026-08-07-profile-persist-read — extract the per-session
      // selected profile name. Without this, the onSessionChanged load
      // in ChatView that reads `selectedProfile` from `getSession()`
      // would always see undefined and clobber any value loaded
      // earlier from `getChatHistory()`. The detail endpoint returns it
      // straight from the sessions row (no message JOIN needed).
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
      // 2026-08-07-profile-persist-read — pass through the persisted
      // profile name. Empty string (= "no profile set" from the
      // backend's COALESCE-on-NULL) is preserved here; ChatView
      // coerces empty → null.
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

// Owning workspace of a session (plan: 2026-09-22-revamp-ui-chats).
// `GET /api/llm/session/:session_id` resolves via the task link first,
// then the cwd heuristic, and returns `workspace_id` (string) or null
// when the session belongs to no workspace. Used by the AppLayout boot
// rewrite to place legacy chat URLs (`/app/chat/:sid`,
// `?view=chat&session=X`) under their workspace path. Null on 404 /
// network failure — callers fail closed to `/app`.
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

/**
 * Stop/cancel a running LLM session by flipping the worker's
 * `cancelled` flag in the DB.
 *
 * The backend handler (`sessionStopHandler` in `src/ai_workflow/tui/
 * http_handlers/session_stop.zig`) runs `llm_history.cancelSession`
 * which sets `UPDATE worker SET cancelled = 1 WHERE id = ?`. The
 * workflow's loop checks this flag at the top of every iteration
 * (`workflow.zig:500`) and inside the retry delay
 * (`retry_delay_ms.zig:42`) — once it sees `cancelled`, it breaks
 * out, calls `deleteWorker`, and the SSE `worker deleted` event
 * removes the session from `processingState` on the frontend.
 *
 * Idempotent: calling stop on a session with no worker row returns
 * 200 OK (the UPDATE matches 0 rows; the handler doesn't inspect
 * the row count). Calling stop on an already-cancelled session is
 * also a 200 OK (the flag is already 1).
 *
 * POST /api/llm/session/:session/stop
 *
 * Returns `{ success: true, session_id }` on success.
 * Returns `{ success: false }` on network/transport failure (the
 * `apiFetch` wrapper turns non-2xx into a thrown error which we
 * swallow + log here, so callers always get a typed response).
 */
// Answer a pending `ask_user` question (Migration 088).
//
// The ask_user agent tool ends the turn: it records a question and returns
// immediately. THIS call settles that question, rewrites the tool-result row
// the model will read, and starts a new run so the conversation resumes.
//
// `question_id` is preferred; `tool_call_id` is the fallback the card always
// has (it is on the tool row). Idempotent — answering an already-answered
// question returns 200 with the stored status, so a double-click or a
// retry-after-timeout is never an error.
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
  /**
   * Unix SECONDS of the last heartbeat, as a numeric string.
   *
   * The backend selects `w.last_activity_nano AS last_activity` and every
   * `Row.values` entry is a `[]u8`, so the column is serialised as a JSON
   * string even though the underlying column is INTEGER. The SSE
   * `WorkerEvent.last_activity` is a bare number — the two wire shapes
   * disagree, which is why consumers normalise both (see `toMillis` in
   * App.vue).
   */
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

/**
 * Create a new design workspace item (`item_type='design'`). The
 * `path` is REQUIRED because design elements live as HTML files
 * under `<path>/.pabrik/design/...` (the model layer rejects
 * element-add with `ItemPathMissing` if path is NULL — see
 * design_model.zig).
 *
 * Mirrors `createKanban(workspaceId, name, path)` but requires the
 * path (no cwd-less design). Returns the new `WorkspaceItem`.
 *
 * POST /api/workspaces/:workspaceId/items/design
 */
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

// Kanban API
//
// Backend endpoints (Chunk 3 of the workspace-item-kanban plan):
//   POST   /api/workspaces/:wsId/items/kanban                 → 201
//   GET    /api/workspaces/:wsId/items/:itemId/kanban/columns → 200
//   POST   /api/workspaces/:wsId/items/:itemId/kanban/columns → 201
//   PATCH  /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId → 200
//   DELETE /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId → 200
//   PATCH  /api/workspaces/:wsId/items/:itemId/tasks/:taskId/move        → 200
//
// All wrappers route through `apiFetch` (NOT raw `fetch`) so the
// error-toast-on-non-2xx contract is consistent with the rest of the
// app. On 4xx/5xx the call throws `ApiError`; the toast is fired
// before the throw so the user sees the message inline.

/**
 * Create a new kanban workspace item. The backend seeds three default
 * columns (todo / in progress / done) and returns the item plus the
 * freshly-created columns so the caller can render the board without
 * a second round-trip.
 *
 * POST /api/workspaces/:workspaceId/items/kanban
 */
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

/**
 * Update a workspace item. Supports partial updates — pass only
 * the fields you want to change.
 *
 * Fields:
 *   - `item_type`: new type (kanban / folder / chat / memory). The
 *     caller historically always sent this; current callers may
 *     omit it when only `name`/`path` change (the backend treats a
 *     missing `item_type` as "leave unchanged" since the rename
 *     branch doesn't read it).
 *   - `path`: new on-disk path (kanban cwd) or `null` to clear.
 *     Presence-detected by the backend (omitted → leave unchanged,
 *     `null` or `""` → clear, non-empty string → set).
 *   - `name`: new display name (used by the Kanban Settings rename
 *     pencil and the KanbanView header pencil). Presence-detected
 *     and rejected with 400 if empty/null.
 *
 * PUT /api/workspaces/:workspaceId/items/:itemId
 *
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
 */
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

/**
 * List the kanban columns for a single workspace item, ordered by
 * `position` ASC.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/kanban/columns
 */
export async function listKanbanColumns(
  workspaceId: string,
  itemId: string,
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
  )
}

/**
 * Add a new column to a kanban. `position` is optional — when omitted
 * the backend appends at the end of the existing sequence
 * (max(position)+1). Returns the newly-created column (with its
 * server-assigned `id` and `position`).
 *
 * POST /api/workspaces/:workspaceId/items/:itemId/kanban/columns
 */
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

/**
 * Copy a kanban's column spec (names + descriptions, preserving
 * order) from a source kanban to a target kanban. Tasks are NOT
 * copied — only the column "template". Destructive for the target:
 * in `replace` mode, the target's existing columns are deleted
 * (with task unassignment) and replaced with copies of the
 * source's. In `append` mode, the source's columns are appended
 * after the target's existing MAX(position).
 *
 * Returns the target's new full column list `{columns, count}`
 * (same envelope as `listKanbanColumns`). The frontend replaces
 * its local `kanban_columns` array with this list in one round
 * trip — backend's atomic emit/replace pattern matches every
 * other kanban mutation endpoint.
 *
 * POST /api/workspaces/:workspaceId/items/:itemId/kanban/copy_spec_from/:sourceItemId
 *
 * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
 *   (Chunk 3, Task 3.1)
 */
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

/**
 * Patch a kanban column. Both `name` and `position` are optional;
 * pass only the fields you want to change. The backend applies the
 * patch and re-numbers sibling positions when `position` changes.
 *
 * Returns the FULL updated board (`{columns, count}`) — same envelope
 * as `listKanbanColumns`. The backend emits the full board on every
 * successful PATCH so the frontend never needs a follow-up GET to see
 * the post-rename ordering or sibling positions. The store replaces
 * its local `kanban_columns` array with the backend's returned list
 * (defensively re-sorted by position), so sibling columns (which the
 * backend may have renumbered when `position` changed) are mirrored
 * in the same round-trip.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/kanban/columns/:columnId
 */
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number },
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}

/**
 * Delete a kanban column. Tasks in the column are unassigned
 * (kanban_column_id set to NULL) — they remain visible in the
 * folder-list view as "Unassigned". Idempotent: a 200 is returned
 * whether the column existed or not (handled by the backend).
 *
 * DELETE /api/workspaces/:workspaceId/items/:itemId/kanban/columns/:columnId
 */
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

/**
 * Move a task to a new column and position within that column. The
 * backend's `moveTask` does the move + sibling re-numbering in a
 * single transaction. Returns the updated task with the new
 * `kanban_column_id` and `kanban_position` so the caller can confirm
 * the move landed where expected.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/tasks/:taskId/move
 */
export async function moveTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  columnId: string,
  position: number,
): Promise<Task> {
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/move`, {
    method: 'PATCH',
    body: { column_id: columnId, position },
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

// =====================================================================
// Design Mode API (v6 — Figma-lite, file-backed HTML model)
// =====================================================================
//
// 9 endpoints for the new design-mode surface, replacing the v5
// panzoom-canvas API. The backend (src/ai_workflow/tui/http_handlers/
// design_*.zig + src/ai_workflow/tui/agentic_loop/design_model.zig) is fully
// implemented and tested; this section is the thin TypeScript wrapper.
//
// Every endpoint routes through the per-request arena on the backend,
// so the responses are built via `std.json.Stringify.valueAlloc` and
// are guaranteed to be valid JSON with all user-provided content
// (HTML bodies, names) properly escaped.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 5, Task 5.1 + 5.2)

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages
 *
 * List all pages in a design workspace item, ordered by `position`
 * ascending. Returns `{ pages, count }` envelope.
 */
export async function listDesignPages(
  workspaceId: string,
  itemId: string,
): Promise<{ pages: DesignPage[]; count: number }> {
  return await apiFetch<{ pages: DesignPage[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages`,
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages
 *
 * Create a new design page. The backend assigns `id`, `position`,
 * `created_at`, `updated_at`. The new page is appended at the end
 * of the current position order.
 *
 * Returns 201 Created with the full DesignPage record.
 */
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

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Update an existing design page. Backend validates the ranges
 * (width 320-4096, height 240-4096) and rejects empty `name` with
 * 400; otherwise the same name + size semantics apply.
 *
 * - `width` + `height` are required (the canvas header W × H inputs).
 * - `name` is optional (NEW for the rename menu, 2026-08-06).
 *   When present, the page is renamed in place. When omitted
 *   (or explicitly `undefined`), the name is left unchanged — the
 *   backend distinguishes "absent in JSON" from "null" by treating
 *   `null` as "leave unchanged" too (per the useCase's `?[]const u8`
 *   → `?null` coercion in `updateDesignPage`).
 *
 * Returns 200 OK with the full DesignPage record (post-update name +
 * width + height + updated_at).
 */
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

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Fetch a single page plus its full element list (HTML bodies
 * EXCLUDED — fetch lazily via `getDesignElementHtml` as the user
 * selects each element, to keep the list-page payload small for
 * designs with many elements).
 */
export async function getDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ page: DesignPage; elements: DesignElement[] }> {
  return await apiFetch<{ page: DesignPage; elements: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements
 *
 * Add a new element to a page. Required body fields: `name`, `type`,
 * `html`. All other DesignElement fields are optional and fall back to
 * the backend's defaults (`x=y=width=height=rotation=0`, `fill=''`,
 * etc.) when omitted.
 *
 * The `html` body is written to a per-element file at
 * `<item.path>/.design/<page_id>/<element_id>.html` BEFORE the DB
 * insert, so a DB failure after the file write leaves an orphan —
 * the backend reaps orphans on the next insert for the same page.
 *
 * Returns 201 Created with the full DesignElement record.
 */
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

/**
 * PUT /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId
 *
 * Full update of an element. The body shape is `Partial<DesignElement>` —
 * any subset of fields can be patched. The backend applies the patch
 * as a sparse merge (omitted fields left unchanged).
 *
 * Returns the full updated DesignElement record (so the frontend can
 * sync its local Pinia store from the response).
 */
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

/**
 * Wire shape for `POST .../design/pages/:pageId/elements/group`.
 * NEW (Chunk 5 of grouped-layers plan). Body fields:
 *   - `child_ids`: required, 2+ element ids on the SAME page. The
 *     backend rejects cross-page children with 400 (ChildAcrossDifferentPages)
 *     and already-parented children with 409 (ChildAlreadyParented).
 *   - `name`: optional, default `"Group"`. The new parent element's
 *     `name` field.
 *   - `type`: optional, default `'group'`. Valid values: `'group'`
 *     (non-clipping logical bundle) or `'frame'` (clipping container).
 */
export interface GroupDesignElementsRequest {
  child_ids: string[]
  name?: string
  type?: 'group' | 'frame'
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/group
 *
 * NEW (Chunk 5 of grouped-layers plan). Wraps 2+ elements into a new
 * `group` (or `frame`) parent at the union bbox of the children. The
 * backend sets `parent_id` on each child to the new group's id in a
 * single transaction.
 *
 * Response 201: `{ parent: DesignElement, children: DesignElement[] }`.
 * Error shape: 400 (BadChildId / ChildAcrossDifferentPages), 404
 * (PageNotFound), 409 (ChildAlreadyParented).
 */
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

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reorder
 *
 * NEW (Chunk 5 of right-click group menu plan). Reorders 1+ elements
 * on a page along the z-axis. The 4 modes:
 *   - `bring_to_front`: selected ids jump above all non-selected elements
 *     in the user-specified input order (first id = topmost).
 *   - `send_to_back`: mirror of bring_to_front (first id = bottommost).
 *   - `bring_forward`: each selected swaps with its next non-selected
 *     sibling above (the multi-selection moves up by one slot).
 *   - `send_backward`: mirror of bring_forward.
 *
 * Response 200: `{ reordered: DesignElement[] }` — the updated rows
 * in their new top-to-bottom z-order.
 *
 * Error shape: 400 (BadMode / NoElementIds / EmptyElementIds /
 * BadElementId / ChildAcrossDifferentPages), 404 (PageNotFound),
 * 409 (CrossPageIds).
 */
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

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reparent-batch
 *
 * NEW (Chunk 1b of drag-to-reparent plan). Atomic N-element reparent
 * in a single transaction. Used by the LayersPanel drag-and-drop
 * affordance so dragging 1 or N selected rows into a group uses ONE
 * round-trip instead of N parallel PUTs. The whole batch is
 * all-or-nothing — if ANY element would close a cycle, the batch
 * fails with 400 BadReparent and no DB writes happen.
 *
 * Body shape: `{ element_ids: [...], new_parent_id: ... | null,
 *                reposition: 'last_in_parent' }`.
 *
 * Response 200: `{ updated: DesignElement[] }` in input order.
 *
 * Error shape: 400 (EmptyElementIds / BadElementId / BadNewParentId /
 * BadReparent), 404 (PageNotFound), 409 (CrossPageIds).
 */
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

/**
 * DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId
 *
 * Idempotent delete. Returns `{ success: true }` whether the row
 * existed or not (the backend returns 200 either way — a missing
 * element is not a 404 here because the canonical "I want this gone"
 * semantic should be idempotent).
 */
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

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/ungroup
 *
 * Dissolve a `group` or `frame` element: reparent its direct children
 * to the group's parent (or top-level if the group had no parent), then
 * delete the group row. Children keep their absolute x/y — their geometry
 * is independent of the group's bbox.
 *
 * Body: `{ element_id: 'elem_g' }`.
 *
 * Response 200: `{ orphaned: DesignElement[] }` — the children in their
 * new post-reparent state.
 *
 * Error shape: 400 (BadGroupId / NotAGroup / EmptyGroup), 500 (DbError).
 */
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

/**
 * DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Delete a design page. The backend (design_model.deletePage) handles
 * the SQL DELETE on design_pages (FK ON DELETE CASCADE cleans up the
 * child design_page_elements rows) and recursively rmdirs the
 * on-disk `<item_path>/.pabrik/design/<sanitized_page_name>/` folder.
 *
 * UI-only — no LLM tool exposes this endpoint, only the DesignView
 * tab-strip × button. Returns 200 with `{success:true}`. 404 if the
 * page didn't exist (idempotent — caller treats 404 as success).
 *
 * Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
 *   (Chunk 2)
 */
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

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 *
 * Lazy-load a single element's HTML body. Used by the iframe preview
 * component as the user selects elements — avoids loading all
 * bodies up-front in the page+elements GET response.
 */
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

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 *
 * Persist a new HTML body for an element. Triggered by the
 * contenteditable / Monaco save flow — the content is the user-
 * edited inner HTML of the element's iframe.
 *
 * Returns the full updated DesignElement record.
 */
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

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/geometry
 *
 * ⚠️  DEPRECATED — replaced by `translateDesignElement` (move) and
 * `resizeDesignElement` (resize). Kept for back-compat with any
 * existing client still wired to the old endpoint. See
 * `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 *
 * Geometry-only update path — separate from the full PUT for two
 * reasons: (1) drag/resize fires 60+/sec, so the smaller payload +
 * sparser validation saves backend CPU; (2) the SSE event is
 * emitted at lower frequency for geometry vs. text/html updates
 * (the `update` event fires for HTML changes; geometry uses the
 * same `update` event but the frontend debounces by diffing).
 *
 * Returns the full updated DesignElement record.
 */
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

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/translate
 *
 * NEW (2026-08-06) — single-element translate (move). The body
 * carries a `(dx, dy)` DELTA (not absolute `x, y`). If the target
 * element is a `group`/`frame`, the server cascades the delta to
 * every transitive descendant via the existing recursive CTE.
 *
 * Returns `{updated: [DesignElement, ...]}`:
 *   - 1 element for leaves
 *   - 1 + N elements for group/frame cascade (root + every cascadee)
 *
 * Replaces `updateDesignElementGeometry` for the move use case
 * (delta-based). See
 * `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 */
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

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/resize
 *
 * NEW (2026-08-06) — single-element resize. The body carries
 * absolute `(x, y, width, height, rotation?)` fields. At least one
 * field is required. Resize NEVER cascades (Figma convention — only
 * the dragged element's bounding box changes; children keep their
 * own positions).
 *
 * Returns the single updated DesignElement.
 *
 * Replaces `updateDesignElementGeometry` for the resize use case.
 * See `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 */
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

/**
 * Per-element geometry patch for the batch endpoint. All fields are
 * optional; null means "leave unchanged". Mirror of the single
 * `updateDesignElementGeometry` shape but reusable for N elements.
 */
export interface GeometryBatchUpdate {
  element_id: string
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/**
 * Response from `POST .../geometry-batch`. `updated` is the
 * post-batch element list in input order.
 */
export interface GeometryBatchUpdateResponse {
  updated: DesignElement[]
}

/**
 * Atomic N-element geometry update. Used by the canvas drag handler
 * when multiple elements are selected (multi-element drag, group /
 * frame being moved) so the N per-element PATCHes collapse into ONE
 * PATCH per pointermove. Combined with the trailing-edge debounce in
 * `useDesignDragDebounce`, this drops the request rate from ~200
 * req/sec to ~2 req/sec for a 5-element drag.
 *
 * Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
 *   (Chunk 3, Task 3.1)
 */
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

/**
 * Server-side cascade move. Each item's `(dx, dy)` applies to the
 * element AND every transitive descendant of that element via a
 * single recursive CTE inside one SQL transaction. Optional
 * `width`/`height`/`rotation` apply ONLY to the root element (Figma
 * convention — resize is per-element, not per-subtree).
 *
 * Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
 *   (Chunk 3, Task 3.1)
 */
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

/**
 * Move an element to a different page in the same design item.
 *
 * Mirrors the backend `POST .../elements/:element_id/move-to-page`
 * endpoint. Changes the element's `page_id` (and `position` on the
 * target page) instead of `x`/`y`. When `apply_to_children=true` (the
 * default), the move cascades to every transitive descendant via a
 * recursive CTE in one SQL transaction (same semantics as
 * `moveDesignElementsBatch` but cross-page).
 *
 * Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 4)
 */
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

// Skills API
//
// A skill is a ROW scoped to one workspace, and that scope is its whole
// identity: no `is_global`, no `cwd`, no `path`. A skill wanted in two
// workspaces is two rows. So every route here carries the workspace id in
// the URL — the same shape `documents` uses — and "list the skills" is
// never answerable without one.
export interface Skill {
  name: string
  description: string
}

export interface SkillDetail {
  name: string
  description: string
  content: string
  /**
   * Companion files stored beside the body (`scripts/…`, `references/…`).
   * `use_skill` materialises them into a temp directory so the body's
   * relative references resolve, so a bundled skill is more than its one
   * row. Zero for a plain single-file skill.
   */
  asset_count: number
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

/**
 * POST /api/workspaces/:workspaceId/skills
 *
 * 201 with the stored row, so the caller can render what it just wrote
 * without a second GET. A duplicate name in the SAME workspace is a 409 —
 * the store's `upsertSkill` is create-or-replace by design (the importer
 * runs on every start-up), so the refusal has to live on this route, where
 * the caller is a human who pressed a button.
 */
export async function createSkill(
  workspaceId: string,
  input: { name: string; description?: string; content?: string },
): Promise<SkillCreateResponse> {
  return await apiFetch<SkillCreateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills`,
    { method: 'POST', body: input },
  )
}

export interface SkillUpdateResponse {
  skill: SkillDetail
}

/**
 * PATCH /api/workspaces/:workspaceId/skills/:skillName
 *
 * The name is a path param and is IMMUTABLE: a rename would break every
 * `use_skill({ name })` call and every cached `skill_eval` verdict. A
 * `name` in the body is therefore a claim about which row is being
 * addressed, and a claim that does not match answers 404 — the same
 * answer a foreign workspace gets.
 *
 * An omitted field keeps its value; an explicit `''` clears it. That
 * distinction is why the body fields are optional rather than defaulted.
 */
export async function updateSkill(
  workspaceId: string,
  skillName: string,
  input: { description?: string; content?: string },
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
    // Preserve the "404 = not found" semantics — the caller uses the
    // returned shape to decide whether to show a "create new memory"
    // prompt vs. an error toast. apiFetch surfaces 404 as ApiError,
    // so we translate it back into the original { memory: null,
    // error_message } shape.
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
//
// Distinct from the global memories above: local memories are scoped
// to a specific project directory (the cwd) and are auto-injected
// into every chat as the "Local Knowledge" section of the system
// prompt (see `loadLocalKnowledge` in
// `src/modules/agent/prompts.zig`). The `cwd` is passed in the body
// (POST/PUT) or the query string (GET/DELETE) and is required for
// the request to be useful. The backend falls back to the pabrik
// server's CWD when no cwd is provided.

/**
 * Build the `cwd` query string for a local-memory request.
 * Returns the `?cwd=...` suffix, or `''` if `cwd` is empty.
 */
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
    // Preserve the "404 = not found" semantics — the caller uses
    // the returned shape to decide whether to show a "create new
    // memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original
    // { memory: null, error_message } shape.
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
    // Stale-while-revalidate: a failed refresh falls back to the
    // last-known status for this cwd so the branch chip keeps showing
    // something real instead of blanking on a transient backend error.
    // Only when there is no cache at all do we return the empty
    // non-repo status (apiFetch also fires a toast notification on
    // non-2xx; the empty status fallback ensures the UI doesn't crash
    // while the user sees the error).
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

/**
 * The blame fetch failed — transport or non-2xx. Deliberately coarse:
 * blame is annotation, not content, so the viewer acts on "no chips",
 * and the only thing the tag must guarantee is that the failure is
 * distinguishable from an empty-but-successful blame (same contract as
 * `ChatHistoryError` above).
 */
export class GitBlameError extends Data.TaggedError('GitBlameError')<{
  readonly cwd: string
  readonly file: string
  readonly reason: string
}> {}

/**
 * The blame endpoint, WITH the failure in the type — no `try`/`catch`
 * (AGENTS.md, "Frontend — No `try`/`catch` in the desktop app").
 */
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

/**
 * Best-effort blame: a failure yields null (the file paints without
 * chips) on the Effect seam, so no `try`/`catch` sits between the
 * failure and the value. The reason is logged, not discarded.
 */
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

// Git worktree info — used by the "Create a PR" dialog to pre-fill
// the form. The optional `base` parameter is forwarded as
// `?base=<branch>` to the backend (Chunk 2 design decision #12): when
// the user changes the base branch and clicks Auto-fill, we want the
// diff re-computed against the new base.
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
  // Renamed from `error_message` per PR review (git_pr_create.zig:60).
  // The Zig struct field is `@"error"` (because `error` is a Zig keyword)
  // and serializes to JSON `"error"`. This frontend field name matches
  // the JSON wire format.
  error: string
  // Which forge the PR/MR was opened on. Absent on older servers.
  provider?: string
}

/**
 * Open a PR/MR on `worktreePath`.
 *
 * `provider` is optional and forwarded verbatim: omitting it lets the
 * backend detect the forge from the worktree's `origin` remote, which is
 * the right answer whenever the caller never learned a provider (a board
 * badge, a worktree opened without an attached PR).
 */
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

// ─── Git branches (kanban worktree base-branch picker) ────────────────────
// Wire shape for `GET /api/git/branches?path=<repo>`. Feeds the "New task"
// dialog's base-branch dropdown so a fresh worktree can branch from e.g.
// `origin/main` instead of whatever the repo's current HEAD is.

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

/**
 * List the local + remote-tracking branches of the repo at `repoPath`.
 *
 * Never throws and never rejects: a missing/unreachable repo path, a
 * non-git directory (backend 404), or a backend that is down all degrade
 * to the empty response so the picker gracefully falls back to a plain
 * text input. The user can always type a ref by hand.
 */
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

// ─── Git commits (read-only lazygit-style history) ────────────────────────
// Wire shape for `GET /api/git/commits?path=<repo>[&limit=][&skip=]` and
// `GET /api/git/commit?path=<repo>&sha=<sha>`. Read-only: list + detail,
// no checkout/amend/rebase.

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

/**
 * Unified diff of one file at one commit (`git diff <sha>^ <sha>`,
 * root-commit fallback via `git show`). Powers the clickable file rows
 * in the commits view. Returns null on any failure so the row can show
 * an inline error instead of crashing.
 */
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
      `/system/folder?path=${encodeURIComponent(targetPath)}&action=list`,
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
  // Mirrors sessions.is_auto_retry_until_stop (Migration 063). Only
  // present on 'updated' events where the session row carries the
  // flag. Used by the workspaces store's SSE handler to keep
  // task.is_auto_retry_until_stop in sync so the
  // KanbanTaskDetailDialog toggle shows the live value.
  is_auto_retry_until_stop?: string
  // Migration 082 — the touched POST's SSE echo carries the fresh
  // stamp (unix-ms integer string, raw column shape — NOT the SQLite
  // datetime the REST list returns). Optional: older backends omit
  // it. ChatsList uses it only for echo detection, never for display.
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

// Background-process lifecycle SSE event (see
// src/agentic_loop/background_process_events.zig). Both granular wire
// names (`background_process_created` / `background_process_completed`)
// share this payload; the consumer filters by `session_id` and
// re-fetches the list.
export interface BackgroundProcessEvent {
  action: 'created' | 'completed'
  session_id: string
  pid: number
  command: string
}

// Skill-eval lifecycle SSE event (see
// src/agentic_loop/skill_eval_events.zig). All three granular wire names
// (`skill_evals_run_started` / `_run_finished` / `_result_applied`) share
// this payload; the consumer filters by `session_id` and re-fetches the
// eval list for the Evals tab.
export interface SkillEvalEvent {
  action: 'run_started' | 'run_finished' | 'result_applied'
  run_id: string
  session_id: string
  evaluated: number
  result_id: string
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

/**
 * Record that a human accepted a verdict.
 *
 * `result_id` is a QUERY parameter, not a path segment — the backend keeps
 * every route under this prefix a literal so no `:param` route can shadow a
 * later one. A 409 means either "already applied" or "the body changed since
 * this verdict was computed"; both are surfaced to the caller rather than
 * swallowed, because the UI must offer a re-evaluate in the second case.
 */
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

// 2026-09-02 stream-resume-on-reselect (task_1787673548905_0) —
// in-flight stream snapshot. When the user closes/re-selects a chat
// session mid-stream, ChatView drops its streaming-* placeholder; this
// endpoint returns the backend's authoritative partial text so the
// re-mounted view can resume seamlessly.
export interface StreamSnapshot {
  active: boolean
  content: string
}

export async function getStreamSnapshot(sessionId: string): Promise<StreamSnapshot> {
  return await apiFetch<StreamSnapshot>(`/llm/session/${sessionId}/stream`)
}

// 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1) —
// live spawn-batch snapshot. A page refresh mid-run wipes ChatView's
// in-memory subAgentProgressMap with no SSE replay; this endpoint
// returns the backend's authoritative rows so loadChatHistory can
// rehydrate placeholder spawn cards.
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
  // Backend's full action enum (on_event_sent_kanban.zig
  // KanbanTaskAction). `human_touched` was added when the kanban
  // card UI started listening for the human-interaction stamp
  // (see task_mark_human_touched.zig); the frontend interface
  // was missing the action here even though the SSE bus already
  // dispatched `human_touched` payloads, which made the SSE
  // handler in kanbanSse.ts unreachable for those events under
  // strict TS narrowing. Added in the
  // sse-kanban-move-duplicate-task plan (2026-08-06).
  action: 'assigned' | 'moved' | 'unassigned' | 'human_touched'
  workspace_id: string
  item_id: string
  task_id: string
  new_column_id?: string | null
  new_position?: number | null
  // After-action review state — present ONLY on `human_touched`
  // events (task_mark_human_touched.zig sends `false`; null on
  // assigned/moved/unassigned). Read by the kanbanSse handler to
  // patch the local task in place instead of refetching every
  // column (chatview-open api-spam fix, 2026-08-24).
  needs_human_review?: boolean | null
}

/**
 * Unified SSE channel options.
 *
 * Each property is a per-channel callback. Only the keys present in
 * `channels` are subscribed on the backend (passed as the
 * `?channels=` query param). The factory always registers all
 * known named event types (`kanban_column`, `kanban_task`,
 * `queue_queued`, `queue_deleted`, `llm_chunk`, `llm_full`,
 * `worker_created`, `worker_updated`, `worker_deleted`,
 * `session_created`, `session_deleted`, `design_element_created`,
 * `design_element_updated`, `design_element_deleted`) with the
 * SseClient so the browser dispatches them; the actual dispatch to
 * a consumer's callback is filtered by `eventType` inside the
 * factory.
 */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  /**
   * Subscribe to background-process lifecycle events. The backend emits
   * two granular names (`background_process_created` on spawn,
   * `background_process_completed` on exit) that share the same
   * `BackgroundProcessEvent` payload. Both route on the central
   * `background_process` key — the consumer filters by
   * `event.session_id` JS-side and re-fetches the list.
   */
  backgroundProcess?: (event: BackgroundProcessEvent) => void
  /**
   * Subscribe to skill-eval lifecycle events. The backend emits three
   * granular names (`skill_evals_run_started`, `skill_evals_run_finished`,
   * `skill_evals_result_applied`) that share the same `SkillEvalEvent`
   * payload. All three route on the central `skill_evals` key — the
   * consumer filters by `event.session_id` JS-side and re-fetches the
   * eval list for the Evals tab.
   */
  skillEvals?: (event: SkillEvalEvent) => void
  /**
   * Subscribe to design-mode element mutations. The backend emits
   * three granular event names (`design_element_created`,
   * `design_element_updated`, `design_element_deleted`) that share
   * the same `DesignElementEvent` payload (the `action` discriminator
   * tells them apart). All three route on the central `design_element`
   * event_bus key — the consumer filters by `action` if it cares
   * about the distinction (the `designSse` store treats all three
   * uniformly: re-fetch the page's element list).
   */
  design?: (event: DesignElementEvent) => void
  /**
   * Subscribe to LLM streaming events. When `sessionId` is provided,
   * the factory sends `llm:<sid>` (per-session routing — used by any
   * future caller that wants server-side filtering). When omitted,
   * the factory sends bare `llm` — the backend broadcasts ALL
   * sessions' LLM events on the central key, and the consumer
   * filters by `event.session_id` on the JS side.
   */
  llm?: { sessionId?: string; onEvent: (event: SseEvent) => void }
  /**
   * Subscribe to queue-message events. Same pattern as `llm`:
   * `sessionId` provided → per-session routing; omitted → central
   * key (consumer filters by `event.session_id`).
   */
  queue?: { sessionId?: string; onEvent: (event: QueueMessageEvent) => void }
}

export interface UnifiedSseOptions {
  channels: UnifiedChannels
  onError?: (error: Event) => void
  onConnected?: () => void
}

/**
 * Open ONE EventSource that fans out every event family the caller
 * wired up. Replaces the 5 dedicated `create*SseConnection` factories
 * (workers / sessions / kanban / queue / llm) plus the design channel
 * — they all route to `/api/events?channels=…` under the hood.
 *
 * **Why 1 SSE endpoint doesn't mean "1 EventSource globally":**
 * For apps that subscribe to a session-scoped channel via the per-
 * session routing keys (`llm:<sid>`, `queue:<sid>`), one EventSource
 * per active session would still be needed. To avoid that, pass the
 * `llm` / `queue` channels WITHOUT a `sessionId` — the factory
 * sends bare `llm` / `queue` tokens; the backend broadcasts all
 * sessions' events on central keys; the consumer filters by
 * `event.session_id` on the JS side. Result: ONE EventSource per
 * app for the app's lifetime (see
 * docs/plans/2026-06-30-single-sse-all-sessions-design.md).
 */
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

  // Empty subscriptions are meaningless; the backend would 400 anyway.
  // Throw early with a developer-friendly message. The console.error
  // before the throw matters: without it the only signal is an
  // uncaught exception at the call site, which is easy to mistake for
  // "SSE never receives data" when the real cause is "no EventSource
  // was ever created because channels was empty".
  if (tokens.length === 0) {
    console.error(
      '[unifiedSSE] createUnifiedSseConnection: opts.channels is empty — no EventSource will be created',
      opts.channels,
    )
    throw new Error('createUnifiedSseConnection: opts.channels is empty')
  }

  // Per-channel JSON buffer for the unnamed default `message` event,
  // if any are emitted. As of the granular `event:` names commit, EVERY
  // emitted event type sets an explicit `event:` line (worker_*,
  // session_*, llm_chunk, llm_full, queue_queued, queue_deleted,
  // kanban_column, kanban_task), so the default-message path below is
  // only hit by future unnamed events. The buffer stays in place so any
  // such addition is handled correctly without re-wiring the buffer.
  //
  // ONE shared buffer (not N per-channel buffers) — the SSE wire format
  // is a SINGLE stream of `data:` lines; the buffer holds the
  // accumulated bytes until a complete JSON object is parsed, then
  // the consumer that matches the shape dispatches and the buffer is
  // sliced past the consumed bytes. Using N buffers and feeding all
  // of them the same bytes leaks memory on the long-lived global
  // SSE — see Plan Reviewer finding #1.
  const defaultMessageBuf = { value: '' }

  return createSseClient({
    url: `${API_BASE}/events?channels=${tokens.join(',')}`,
    onConnected: opts.onConnected,
    // Every named event type the backend can emit MUST be pre-registered
    // — the browser's EventSource only dispatches each `event: <name>`
    // to listeners registered for that exact name. See the SseClient
    // JSDoc + the project memory browser-eventsource-named-events.md.
    // Set names MUST match the `event_type` values emitted by
    // on_event_sent.zig and llm_history.zig.
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
      // Throw-isolation / forward-compat: the backend emits these
      // fallback/granular names (see on_event_sent.zig +
      // on_event_sent_design.zig). Without pre-registration the
      // browser's EventSource drops them silently before onEvent
      // ever fires — indistinguishable from "stream is dead".
      // Registered here so they always reach the fan-out below,
      // which routes (or explicitly ignores) each one.
      'worker_unknown',
      'session_created',
      'session_deleted',
      'session_updated', // task_1786507100896 — auto-rename on first user message + unattended toggle
      'session_unknown',
      // Design-mode element events (see src/ai_workflow/tui/on_event_sent_design.zig).
      // All granular single-element events share the `DesignElementEvent`
      // payload; the `action` discriminator tells them apart. The single
      // `design_element` channel token in `tokens` subscribes to all of
      // them at once — no per-action channel routing needed because the
      // frontend treats them uniformly (re-fetch the page's element list).
      // The BATCH event (`design_elements_geometry_batch_updated`) is
      // emitted by `updateElementsBatch` AND by `moveElementsWithDescendantsBatch`
      // — both endpoints share the same SSE event type. Without this
      // registration, the browser's EventSource drops the event before
      // our `onEvent` handler ever sees it (see project memory
      // browser-eventsource-named-events.md), which means the dedupe
      // check in `stores/designSse.ts` never runs and the local-mutation
      // skip path is dead code for batch updates.
      'design_element_created',
      'design_element_updated',
      'design_element_deleted',
      'design_elements_geometry_batch_updated',
      // Backend also emits `design_page_deleted` (routing key
      // `design_page`) and `close` (server-shutdown frame). Neither
      // has a dedicated frontend channel today — registered so the
      // browser doesn't drop them silently; the fan-out below
      // handles each explicitly (design page → design channel,
      // close → ignored).
      'design_page_deleted',
      'close',
      // Background-process lifecycle (see background_process_events.zig).
      // Without pre-registration the browser drops the event before
      // onEvent ever fires — the list would never refresh.
      'background_process_created',
      'background_process_completed',
      // Auth rejection (`event: auth_error`, see unified_events_sse.zig
      // `terminateSseStream`). Without pre-registration the browser
      // drops it before onEvent ever fires and the client sits in
      // 'connecting' until the stream closes — indistinguishable
      // from a dead backend.
      'auth_error',
      // Skill-eval lifecycle (see src/agentic_loop/skill_eval_events.zig).
      // Three granular names share one payload; all route on the central
      // `skill_evals` key. Without pre-registration the browser drops them
      // before onEvent ever fires, so the Evals tab would never refresh
      // after an eval finished — indistinguishable from a dead stream.
      'skill_evals_run_started',
      'skill_evals_run_finished',
      'skill_evals_result_applied',
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

      // Design-mode element events. The backend emits four event names:
      //   - `design_element_created` / `_updated` / `_deleted` — single
      //     element; all share the same `DesignElementEvent` payload
      //     (the `action` discriminator tells them apart).
      //   - `design_elements_geometry_batch_updated` — batch event with
      //     `element_ids[]` (the `DesignElementEvent` interface has
      //     `element_ids?: string[]` for this variant). Emitted by
      //     `updateElementsBatch` AND `moveElementsWithDescendantsBatch`.
      //   - src/ai_workflow/tui/on_event_sent_design.zig — all four
      //     are dispatched to the same `design` channel; the consumer
      //     can switch on `event.action` or check `event.element_ids`
      //     if it cares about the distinction.
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

      // LLM streaming chunks / full responses. The backend sets
      // `event_type = "llm_chunk"` for content/reasoning/tool-call/final
      // chunks (per `on_event_sent.zig` `sendStreamChunk*`) and
      // `event_type = "llm_full"` for non-streaming full responses
      // (`onEventSendLLMHistory`). Both shapes are the same `SseEvent`
      // — the frontend doesn't need to distinguish them; the channel
      // callback receives the object either way.
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

      // Worker events. The backend sets `worker_created` |
      // `worker_updated` | `worker_deleted` based on
      // `OnEventInputWorkers.action` (see `on_event_sent.zig`), plus
      // `worker_unknown` as a future-proofing fallback for new actions.
      // Unknown actions are still forwarded — the consumer dispatches
      // by `event.action` and can ignore what it doesn't know.
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

      // Session events. The backend emits `session_created` (on first
      // message of a fresh chat), `session_updated` (on auto-rename after
      // the first user message + on unattended-mode toggle + on
      // last_finish_reason refresh; see llm_history.zig:2896 + the cascade
      // in update_session_name.zig:24), and `session_deleted`. All three
      // share the `SessionEvent` payload shape; the consumer dispatches by
      // `event.action`. The pre-registration in `additionalEventTypes`
      // above is what wires the browser's EventSource to fire onEvent
      // for these names — without it, the wire event is dropped on the
      // floor (see project memory browser-eventsource-named-events.md).
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

      // Server-shutdown frame (`event: close`, see sse_manager.zig).
      // Explicitly ignored — the browser fires `error` + the client
      // reconnects via its own backoff. Without this branch the event
      // would fall through to the default-message JSON buffer below
      // and pollute it with non-JSON bytes.
      if (eventType === 'close') {
        return
      }

      // Auth rejection (`event: auth_error`, see unified_events_sse.zig
      // `terminateSseStream`). The SSE 200 headers are already sent
      // before the backend checks the session cookie, so a 401 can
      // never arrive as HTTP status — this event is the rejection
      // signal. Mirror the fetch-401 path: bounce to /login (the
      // router guard covers boot; this covers streams that were
      // never authed or whose session died mid-use).
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

      // `design_page_deleted` shares the design channel (page-level
      // delete; the consumer re-fetches). Registered so the browser
      // doesn't drop it silently; forwarded best-effort like the
      // element events above.
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

      // Default `message` events: 3 distinct JSON shapes, differentiated
      // by which consumer registered the channel. The backend sends
      // these as multi-line JSON strings (one `data:` line per JSON
      // object's newline-delimited line), so we accumulate + parse
      // in a single shared buffer, then dispatch by JSON-shape check.
      //
      // Shape discrimination: `action` is present in worker and session
      // events but NOT in LLM chunk/full events (LLM uses `type`).
      // - `{action, id, working_directory, ...}`    → WorkerEvent
      // - `{action, id, name, status, cwd, ...}`   → SessionEvent
      // - `{type, content, session_id, ...}`      → SseEvent (LLM)
      //
      // Single buffer (not per-channel): the SSE wire format is ONE
      // stream; each `data:` line goes to exactly one consumer based on
      // its shape. After dispatch, the buffer is sliced past the
      // consumed JSON object so the next event starts fresh.
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        defaultMessageBuf.value += trimmed + '\n'
        const jsonStart = defaultMessageBuf.value.indexOf('{')
        const jsonEnd = defaultMessageBuf.value.lastIndexOf('}')
        if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
          // Incomplete JSON object — wait for more bytes. If the
          // buffer grows unbounded (e.g. server sends invalid JSON),
          // a future fix could add a size guard; current callers
          // trust the backend's wire format.
          return
        }
        const jsonStr = defaultMessageBuf.value.slice(jsonStart, jsonEnd + 1)
        let parsed: unknown
        try {
          parsed = JSON.parse(jsonStr)
        } catch {
          // Invalid JSON; drop the leading bytes and keep accumulating.
          // (Defensive — the backend's std.json.fmt should always
          // emit valid JSON. But a buggy future emitter shouldn't
          // crash the SSE.)
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonStart + 1)
          return
        }

        const obj = parsed as Record<string, unknown>
        // Order matters: check session BEFORE worker because both have
        // `action`; the discriminator is `working_directory` (worker
        // has it, session doesn't) plus `status` (session has it,
        // worker doesn't). Either combination uniquely identifies.
        // We dispatch to AT MOST ONE consumer — the first matching
        // shape wins. If no shape matches, the event is silently
        // dropped (after the buffer advance below) so the buffer
        // stays bounded.
        //
        // Throw-isolation: each channel callback runs in its own
        // try/catch so a throwing consumer can never skip the buffer
        // advance below. Previously a throw here jumped straight to
        // the outer catch, leaving the consumed bytes in the buffer —
        // every subsequent default-message event then re-parsed the
        // same stale bytes (unbounded growth + apparent stream stall).
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
          // ALWAYS advance past the consumed JSON object, regardless of
          // whether a consumer matched or threw. The single-stream design means
          // every default-message event MUST produce forward progress —
          // if a caller subscribed only to `kanban` and the backend
          // emits a worker-shaped default-message event, we must still
          // slice past it so the buffer doesn't grow unboundedly.
          // (Code Reviewer Critical Fix, 2026-06-30.)
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonEnd + 1)
        }
      } catch (e) {
        console.error('[unifiedSSE] default message dispatch error:', e)
      }
    },
    onStateChange: (state, info) => {
      // Match the convention of the 5 old factories: terminal-failure
      // only. Transient errors are retried internally by the SseClient.
      // See memory pabrik-sse-incomplete-chunked-encoding.md for why
      // ChatView's isStreaming flag flips ONLY on 'failed'.
      // Throw-isolation: a throwing onError must never break emitState's
      // per-subscriber loop (emitState already guards, but guard here too
      // so the error is attributed to the right channel).
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
  /**
   * Per-profile sub-agents. Same shape as the top-level
   * `PabrikConfig.sub_agents` field — profiles can override the default
   * sub-agent set with their own.
   */
  sub_agents?: SubAgent[]
  /**
   * Optional override for this profile's context window (in tokens).
   * When null (or omitted), the backend's built-in per-model default
   * is used (e.g. 200_000 for MiniMax-M2.7, 500_000 for MiniMax-M3,
   * 200_000 fallback). Useful for self-hosted models with a
   * non-standard window.
   *
   * Mirrors the backend's `LlmProfile.max_capacity_tokens` field
   * (added in the configurable-compaction Chunk 7 reshape).
   */
  max_capacity_tokens?: number | null
  /**
   * Compaction threshold as a percentage (0-100) of this profile's
   * context window. When null (or omitted), defaults to 80. Out-of-range
   * values are rejected by the backend with `error.InvalidThresholdPercent`.
   *
   * Mirrors the backend's `LlmProfile.compaction_threshold_percent`.
   */
  compaction_threshold_percent?: number | null
  /**
   * Anthropic-only override for `thinking.budget_tokens`. Plan
   * 2026-08-23-model-thinking. Mirrors `LlmProfile.thinking_budget_tokens`.
   * Hidden when `thinking === "off"`. Range (0, 2_000_000] enforced
   * server-side. When null/omitted, the backend uses the 50%-of-max
   * heuristic (or Anthropic `type: "adaptive"` when
   * `thinking === "auto"`).
   */
  thinking_budget_tokens?: number | null
  /**
   * OpenAI-style reasoning effort (o1/o3/GPT-5/DeepSeek-R1). Plan
   * 2026-08-23-model-thinking. Mirrors `LlmProfile.reasoning_effort`.
   * Hidden when `thinking === "off"`. Server-side validation via
   * `parse_thinking.parseReasoningEffort` (low|medium|high|auto).
   */
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
  /** Anthropic-only override for `thinking.budget_tokens`. Plan
   * 2026-08-23-model-thinking. Mirrors `LlmProfile.thinking_budget_tokens`.
   * Optional in the wire shape — old configs without this field
   * hydrate as undefined and are coerced to null in the form. */
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
  /** Transport discriminator. Defaults to 'http' on legacy entries
   *  that predate this field. Mutually exclusive with itself — a
   *  server is either HTTP or stdio, never both. */
  transport?: 'http' | 'stdio'
  /** HTTP transport — required when transport === 'http'. */
  url?: string
  /** Optional list of HTTP headers to send with MCP requests (e.g. API keys). */
  headers?: McpHeader[]
  /** stdio transport — required when transport === 'stdio'. The
   *  command (executable name or absolute path) the agent will spawn
   *  as a child process and talk MCP JSON-RPC to. */
  command?: string
  /** stdio transport — argv (excluding argv[0]). One entry per line in the UI. */
  args?: string[]
  /** stdio transport — "KEY=VALUE" per line, ADDED on top of inherited env.
   *  v1 limitation: Zig 0.16's std.process.Child has no clean .env_map setter,
   *  so a custom env requires a pre-fork+execve helper — not in v1.
   *  The UI exposes this for documentation + forward-compat. */
  env?: string[]
  /** stdio transport — optional child working directory (absolute path). */
  cwd?: string
  /** When false the agent skips this server (no tools listed, no calls).
   *  Missing/undefined renders as enabled. Omitted on the wire when
   *  enabled so legacy configs stay clean. */
  enabled?: boolean
}

/**
 * One entry of the top-level `web_search` map in `config.json` — the
 * wire shape of a single web-search provider. The map key is the
 * provider name the agent passes to `web_search`; the agent discovers
 * the names through `list_web_search_providers`.
 *
 * `key` and `description` are OMITTED when absent, never sent as `""` —
 * a self-hosted provider has no credential and `"key": ""` is not the
 * same thing to the backend (an empty slice binds as SQL NULL, and
 * `isUsable` treats it as a declared-but-blank credential).
 *
 * `key` may come back MASKED rather than as the secret, so the value the
 * form holds is not necessarily the credential. Round-tripping it
 * unchanged is therefore required — replacing it with `""` would blank
 * the stored secret. See `components/pabrik/webSearchProviders.ts`.
 */
export interface PabrikWebSearchProvider {
  /** Host pin. The ONLY host whose requests may carry `key`. Must be
   *  `https` and must not name a loopback, private or link-local host. */
  url: string
  /** Credential, stored separately from `curl` so nothing derived from
   *  the template can leak it. Optional. */
  key?: string
  /** Request template copied from the provider's docs, carrying the
   *  literal text `{key}` where the credential goes. Must contain
   *  `{key}` when the provider declares a `key`, and must NOT when it
   *  does not. */
  curl: string
  /** Free-text note about when to prefer this provider. Optional. */
  description?: string
  /** Defaults to true. `false` keeps the provider configured but hides
   *  it from `list_web_search_providers`. */
  enabled?: boolean
}

/**
 * The Skill Evals block of `config.json`, as the wire carries it
 * (snake_case, matching `SkillEvalsJson` in `Config.zig`).
 *
 * `enabled` is the master switch the Settings toggle writes. The other
 * fields are the budgets around it and are sent back unchanged so a save
 * from the toggle can never reset a value the user hand-edited.
 */
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
  // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
  // defaults (api_endpoint/api_key/model/url_style/temperature/max_tokens/
  // system_prompt) were REMOVED from config.json. LLM access is configured
  // exclusively via `profiles`; the backend derives effective credentials
  // from the active profile at load time.
  profiles?: Record<string, PabrikProfile>
  active_profile?: string
  /**
   * Map of MCP server name to its raw JSON config (snake_case).
   * Each value follows the `{"url": "...", "headers": {...}}` shape used by
   * the LLM config. Sent verbatim to the backend on save.
   */
  /**
   * Raw wire shape of a single MCP server entry (snake_case, matches
   * `mcp_servers` in config.json). Discriminated by which top-level
   * field is present: `command` ⇒ stdio, `url` ⇒ http.
   *
   * Note: this type is also re-exported and re-used by the
   * `PabrikConfigEditor.vue` parser/serializer pair so the frontend
   * round-trips config.json unchanged. If you add a field here, add
   * it to the `McpServer` interface above too (camelCase).
   */
  mcp_servers?: Record<
    string,
    | { url: string; headers?: Record<string, string>; enabled?: boolean }
    | { command: string; args?: string[]; env?: string[]; cwd?: string; enabled?: boolean }
  >
  /**
   * Default tool checklist (Tools tab). `null` / absent = the key is
   * not in config.json — the backend treats those as "no change" on
   * PUT and the built-in defaults apply. An array (including `[]`)
   * replaces the whole list.
   */
  tools?: string[] | null
  /**
   * Map of web-search provider name to its configuration — the
   * top-level `web_search` key in config.json. Keys of this map are the
   * names the agent passes to `web_search`'s `provider` argument; the
   * agent discovers them through `list_web_search_providers`.
   *
   * `null` / absent = the key is not in config.json. Sent verbatim to
   * the backend on save; see `PabrikWebSearchProvider` for the value
   * shape and the rules the backend enforces on it.
   */
  web_search?: Record<string, PabrikWebSearchProvider> | null
  /**
   * @deprecated Per-profile only (plan 2026-09-04-subagents-per-profile).
   * The backend (`GET /api/config/pabrik`) always returns `sub_agents: null`
   * at the top level; each profile owns its list via `PabrikProfile.sub_agents`.
   * Kept as an optional field so legacy payloads still type-check — do NOT
   * read or write it in new code.
   */
  sub_agents?: SubAgent[]
  /**
   * Opt-in OS notification flag. When true, the backend fires
   * `notify-send` / osascript / PowerShell when an LLM response
   * completes with `finish_reason === 'stop'`. Defaults to `false`
   * when absent (matches the `LlmConfigJson` default in
   * `Config.zig`).
   */
  notify_on_complete?: boolean
  /**
   * Plan 2026-08-25-notify-on-error — opt-in OS notification flag
   * for the error path. When true, the backend fires a desktop
   * notification when the workflow hits a transport error, exhausts
   * retries (TooManyRetries), or fails the outer agentic loop.
   * Defaults to `false` when absent (matches `LlmConfigJson`).
   * Independent from `notify_on_complete` — toggling one doesn't
   * affect the other.
   */
  notify_on_error?: boolean
  /**
   * Skill Evals block — the master switch for the `run_skill_eval` tool
   * and the budget knobs around it. `enabled: true` injects the tool into
   * the main agent's tool list and lets the agent evaluate the skills the
   * session actually loaded; `false` (the default, and what a config with
   * no `skill_evals` key reads as) removes the tool entirely.
   *
   * The backend always sends this object (never `null`), so the toggle
   * can always render a real on/off rather than guessing. Sending it back
   * in the PUT persists the switch; omitting it leaves the on-disk value
   * untouched.
   */
  skill_evals?: PabrikSkillEvalsConfig
  /**
   * Compaction threshold in KB. Sessions whose DB-stored token
   * estimate exceeds this value trigger context compaction. Defaults
   * to `100` when absent. Not exposed in the UI — power users can
   * edit `config.json` directly.
   */
  model_compaction_size_kb?: number
  /**
   * Optional top-level override for the model's context window (in
   * tokens). `null` = fall through to per-profile override, then
   * built-in default. Restored in plan 2026-07-07-compaction-inline
   * so the Defaults tab can show + edit the top-level compaction
   * defaults. Mirrors `LlmConfig.max_capacity_token_model`.
   */
  max_capacity_token_model?: number | null
  /**
   * Optional top-level compaction threshold as a percentage (0-100).
   * `null` = fall through to per-profile override, then built-in 80.
   * Mirrors `LlmConfig.compaction_threshold_percent`.
   */
  compaction_threshold_percent?: number | null
  /**
   * Delay in milliseconds before the workflow retries a failed
   * `callDynamicAgentNew` call. 0 = no delay (current behavior, the
   * retry fires immediately on the next loop iteration). Range: 0–60 000.
   * The backend clamps values > 60 000 to 60 000. Mirrors
   * `LlmConfig.retry_delay_ms` in `Config.zig`.
   */
  retry_delay_ms?: number
  /**
   * Plan 2026-09-10-web-launch-toggle — browser-mode flag. When true,
   * the settings General tab advertises the same UI in the system
   * browser (URL pill + auto-open) and the server defaults to a random
   * local port at startup. Defaults to `false` when absent (matches
   * `LlmConfigJson`). Lifecycle A: the server keeps running when false.
   */
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

// ─── Per-workspace config overlay (Migration 105) ────────────────────────
//
// The workspace-scope twin of the pair above. Same wire shape: `GET` returns
// the EFFECTIVE config (user config with the workspace's overlay merged over
// it), so the page shows what actually runs here rather than a sparse diff the
// user has to reconcile by hand. There is no reset/copy call: the boot seeding
// IS the migration.
//
// `PUT` takes the same body as `savePabrikConfig`; the backend stores only
// the workspace-scoped slice of it and 400s if the body carries none, so a
// save that would silently do nothing is refused instead of reported as
// successful.

/** `GET /api/workspaces/:id/config` — throws on a non-2xx (unlike the
 * user-scope `getPabrikConfig`, which swallows the failure into `{}`): the
 * workspace page must be able to tell "inheriting" from "could not look". */
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

/**
 * Plan 2026-09-10-web-launch-toggle — browser-mode status.
 *
 * `GET /api/web/status` is read-only (lifecycle A: no server-side
 * start/stop). `url` is always the live bound port
 * (`http://127.0.0.1:<port>/`, loopback-only). `null` on network/API
 * failure so the pill can render a waiting hint.
 */
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

/**
 * Response shape from `DELETE /api/config/pabrik/profiles/:name`.
 *
 * `active_profile_was_cleared` is `true` when the deleted profile was
 * the active one (the backend also cleared `active_profile` on disk).
 * `error_message` is set when the request succeeded (HTTP 200) but a
 * downstream concern (live reload) failed — the deletion still
 * persisted.
 */
export interface ProfileDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/**
 * DELETE /api/config/pabrik/profiles/:name
 *
 * Removes a profile from `config.json` and live-reloads the backend's
 * in-memory LLM config. Throws an Error (with the HTTP status) on
 * non-2xx responses; the composable wraps this for UI concerns
 * (optimistic update, rollback, notification).
 */
export async function deleteProfile(name: string): Promise<ProfileDeleteResponse> {
  return await apiFetch<ProfileDeleteResponse>(
    `/config/pabrik/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// ─── MCP server test probe ──────────────────────────────────────────────────
// Wire shape mirrors the backend `POST /api/mcp/test` handler in
// src/ai_workflow/tui/http_handlers/mcp_test.zig. The probe fires a
// `tools/list` request against the candidate config without persisting
// anything — used by the "Test" button in McpServerModal so the user
// can verify command / args / env / cwd (or URL + headers) actually
// work before clicking Save.
//
// Success: `{ ok: true, transport: 'stdio' | 'http', tools: McpToolPreview[] }`
// Failure: `{ ok: false, error: <message>, details: <error-name> }`
// Always HTTP 200 — failure is carried in the `ok` field, not the status.
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
  // We deliberately DON'T use the shared `apiFetch` wrapper here
  // because (a) the endpoint always returns HTTP 200 with a payload
  // that may carry `{ ok: false, ... }`, and (b) we want the modal's
  // inline result panel to render the error message rather than
  // firing a toast notification. Direct fetch + manual JSON parse
  // gives us that without bypassing the API base constant.
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

// ─── LLM profile test probe ─────────────────────────────────────────────────
// Wire shape mirrors the backend `POST /api/llm/test` handler in
// src/http_handlers/llm_test.zig. The probe fires one minimal
// non-streaming chat call ("Reply with exactly: ok") against the
// candidate model + base_url + api_key + url_style without persisting
// anything — used by the "Test" button in LlmConfigModal (Add/Edit
// profile + sub-agent dialogs) so the user can verify the profile
// actually works before clicking Save.
//
// Success: `{ ok: true, model, reply, latency_ms }`
// Failure: `{ ok: false, error, details }`
// Always HTTP 200 — failure is carried in the `ok` field, not the status.
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
  // Deliberately NOT the shared `apiFetch` wrapper (same reason as
  // `testMcpServer` above): the endpoint always returns HTTP 200 with
  // a payload that may carry `{ ok: false, ... }`, and we want the
  // modal's inline result panel to render the error rather than
  // firing a toast notification.
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

// Batch file diffs — one POST replaces N parallel GET /git/file/diff.
// Collapses the SidebarDiffPanel fan-out (20 files = 20 git spawns
// holding 20 Io workers) into at most 2 server-side `git diff`
// invocations. LIST mode: the client names the paths.
export interface GitFileDiffsBatchItem {
  file: string
  staged: boolean
}

export interface GitFileDiffsResponse {
  diffs: GitFileDiff[]
  /** Whole-file mode only: the file's full-context diff exceeded the
   * server's budget and was REFUSED (`diff_content` is empty) rather than
   * truncated into something that reads as a complete file. */
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

// Folder mode — one POST for a whole folder. The server enumerates the
// changed paths itself (`git status --porcelain -uall -- <folder>`), so the
// caller neither has to fetch `GET /api/git/changes` first nor send a
// path-per-file body. Cost is 3 git spawns regardless of how many files
// changed; `folder: ''` means the whole repo.
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

// WHOLE-FILE mode — `git diff -U<all>` for exactly ONE path, so the caller can
// render every line of the file with the changes still marked. One request per
// file by construction (the server 400s on a folder or a multi-file body), and
// all-or-nothing: `whole_file_refused` means "too big to serve in full", never
// a partial file.
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

/**
 * PR CI checks (GET /api/git/pr/checks via `gh pr checks`).
 *
 * `checks` is one row per CI job; `steps` is filled in for failed and
 * cancelled jobs only — "which job failed" is already on the PR page,
 * "which process or task failed" is what the user comes here for.
 *
 * `steps_error` is the contract that matters: when the backend tried to
 * read a job's steps and could not, the reason lands here so the panel
 * can say so. An empty `steps` with an empty `steps_error` is a real
 * answer (an external check has no steps); an empty `steps` with a
 * message is a gap.
 */
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

// Which-files-conflict API. `getPrStatus` tells us a PR is CONFLICTING but
// not what blocks it — no forge API exposes that, so the backend runs the
// same three-way merge locally (`git merge-tree --write-tree --name-only`)
// and names the paths. Fetched only while a conflict is showing: a clean PR
// costs zero extra spawns and renders exactly as before.
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

// File download URL builders for the `present_files` agent tool card
// (PresentFiles.vue). Cookie-based auth like every other /api route,
// so plain `<a href>` (download) and `<img src>` (thumbnail preview)
// carry credentials — no fetch/blob/objectURL dance needed (unlike
// the kanban thumbnail rehydrate in KanbanDescriptionEditor, which
// needs File objects, not navigation).
//
// NOT via apiFetch: apiFetch only speaks JSON (`response.json()` +
// 15s timeout + auto-toast). These return URL strings the template
// binds directly.
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

// `uploadTaskAttachment` REMOVED 2026-08-06 (kanban-image-urls-column
// plan). Task images now live inline on `workspace_item_tasks
// .image_urls` as `||`-delimited base64 data URLs — no upload path,
// no `GET` endpoint, no filesystem writes. The frontend converts
// pasted/picked files to data URLs via `FileReader.readAsDataURL`
// (in `KanbanView.handleCreateTaskSave` + the new editor
// `pendingFiles` flow) and PATCHes the column with the joined
// string via `api.updateTaskSimple`.
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md.

// =====================================================================
// Agent Mode API (plan 2026-08-15-agent-mode, task_1786962724740_0)
//
// 12 endpoints exposed by the backend for the new `item_type='agent'`
// workspace item. Mirrors the kanban wrappers above — same error
// contract (ApiError on 4xx/5xx), same {item, agent} envelope shape
// on create, same comma-joined tool_names semantics on the allowlist
// CRUD.
// =====================================================================

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

export interface AgentRegistryEntry {
  name: string
  description: string
}

/**
 * Create a new agent workspace item. The backend seeds the agent
 * with an empty knowledge list AND an empty tool allowlist
 * (secure-by-default — empty allowlist = zero tools per spec D1).
 *
 * POST /api/workspaces/:workspaceId/items/agent
 */
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

/**
 * Get agent + knowledge + tools + system prompts for a workspace_item.
 * Returns the 4 sections AgentView needs in one round-trip.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/agent
 */
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

/**
 * Update an agent's description.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent
 */
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

// =====================================================================
// Workspace routines (Migration 084) — first-class `item_type='routine'`
// items beside `agent`. Replaces the deleted per-task routines.
// Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md
// =====================================================================

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

/**
 * Create a new routine workspace item.
 *
 * POST /api/workspaces/:workspaceId/items/routine
 */
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

/**
 * Get the routine bound to a workspace_item.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/routine
 */
export async function getRoutineItem(
  workspaceId: string,
  itemId: string,
): Promise<{ routine: WorkspaceRoutine }> {
  return await apiFetch<{ routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/routine`,
  )
}

/**
 * Update a routine's description / instruction / schedule / enabled.
 * Schedule/enabled changes recompute next_run_at server-side.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/routine
 */
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

/**
 * Add a knowledge entry to an agent — either a markdown file path on
 * disk (`filePath`) or inline manual text (`content`). Exactly one of
 * the two must be non-empty (backend XOR-validates).
 *
 * POST /api/agents/:agentId/knowledge
 */
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

/**
 * Add a named system-prompt block to an agent. `content` is required
 * (non-empty after trim); `title` optional ('' = untitled).
 *
 * POST /api/agents/:agentId/system_prompt
 */
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

/**
 * Get the canonical tool registry. The Tools panel renders
 * checkboxes from this list. Sourced from the runtime's
 * UNIFIED_TOOL_REGISTRY (single source of truth per spec D4).
 *
 * GET /api/agent-tools/registry
 */
export async function getAgentToolsRegistry(): Promise<{ tools: AgentRegistryEntry[] }> {
  return await apiFetch<{ tools: AgentRegistryEntry[] }>(`/agent-tools/registry`)
}

/**
 * Get the enabled tool names for an agent. Empty array = secure-by-default.
 *
 * GET /api/agents/:agentId/tools
 */
export async function getAgentTools(agentId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agents/${agentId}/tools`)
}

/**
 * Enable a tool for the agent. Backend validates `tool_name`
 * against the registry (400 if unknown) and returns 409 on duplicate.
 *
 * POST /api/agents/:agentId/tools
 */
export async function enableAgentTool(agentId: string, toolName: string): Promise<AgentToolRow> {
  return await apiFetch<AgentToolRow>(`/agents/${agentId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/**
 * Disable a tool for the agent (deletes the row).
 *
 * `tool_name` must match a tool the agent currently has enabled
 * (the registry name; backend returns 404 on unknown / not-enabled).
 *
 * DELETE /api/agents/:agentId/tools/:toolName
 */
export async function disableAgentTool(agentId: string, toolName: string): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/tools/${toolName}`, { method: 'DELETE' })
}

// ─── Agent-Kanbans Mirror (Migration 081) ───────────────────────────────
//
// Mirrors the Agent Mode block above onto kanban boards. The config row
// (`agent_kanbans`) is OPT-IN — `getAgentKanban` resolves to `null`
// (silently, no error toast) when the board has no config yet.

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

/**
 * Get the agent-kanbans config + children for a kanban workspace_item.
 * Returns null (silent) on 404 "not configured" — an unconfigured board
 * is an expected state, not an error worth surfacing.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/agent_kanban
 */
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

/**
 * Update the agent-kanbans config's description.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_kanban
 */
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

/**
 * Add a knowledge entry to a board's config — file path XOR inline text.
 *
 * POST /api/agent-kanbans/:kanbanId/knowledge
 */
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

/**
 * Add a named system-prompt block to a board's config. `content`
 * required; `title` optional.
 *
 * POST /api/agent-kanbans/:kanbanId/system_prompt
 */
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

/**
 * Get the enabled tool names for a board's config. Empty array = no
 * tools configured for this board.
 *
 * GET /api/agent-kanbans/:kanbanId/tools
 */
export async function getAgentKanbanTools(kanbanId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-kanbans/${kanbanId}/tools`)
}

/**
 * Enable a tool for the board. Backend validates against the registry
 * (400 if unknown) and returns 409 on duplicate.
 *
 * POST /api/agent-kanbans/:kanbanId/tools
 */
export async function enableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<AgentKanbanToolRow> {
  return await apiFetch<AgentKanbanToolRow>(`/agent-kanbans/${kanbanId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/**
 * Disable a tool for the board (deletes the row).
 *
 * DELETE /api/agent-kanbans/:kanbanId/tools/:toolName
 */
export async function disableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

// ─── Agent-Routines Mirror (Migration 088) ─────────────────────────────
//
// Mirrors the Agent-Kanbans block above onto routine items. Unlike kanbans,
// the config row (`agent_routines`) is SEEDED on routine creation and
// backfilled for pre-existing routines (Migration 088) — same silent-null
// contract on 404 kept anyway.

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

/**
 * Get the agent-routines config + children for a routine workspace_item.
 * Returns null (silent) on 404 "not configured" — an unconfigured routine
 * is an expected state, not an error worth surfacing.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/agent_routine
 */
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

/**
 * Update the agent-routines config's description.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_routine
 */
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

/**
 * Add a knowledge entry to a routine's config — file path XOR inline text.
 *
 * POST /api/agent-routines/:routineId/knowledge
 */
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

/**
 * Add a named system-prompt block to a routine's config. `content`
 * required; `title` optional.
 *
 * POST /api/agent-routines/:routineId/system_prompt
 */
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

/**
 * Get the enabled tool names for a routine's config. Empty array = no
 * tools configured for this routine.
 *
 * GET /api/agent-routines/:routineId/tools
 */
export async function getAgentRoutineTools(routineId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-routines/${routineId}/tools`)
}

/**
 * Enable a tool for the routine. Backend validates against the registry
 * (400 if unknown) and returns 409 on duplicate.
 *
 * POST /api/agent-routines/:routineId/tools
 */
export async function enableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<AgentRoutineToolRow> {
  return await apiFetch<AgentRoutineToolRow>(`/agent-routines/${routineId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/**
 * Disable a tool for the routine (deletes the row).
 *
 * DELETE /api/agent-routines/:routineId/tools/:toolName
 */
export async function disableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

// ─── Session background processes (bg-completion) ────────────────────────────
// Backend: background_processes_list.zig + background_process_log_get.zig
// (commit b69111f7). `running` is live per row (OS truth, not the status
// column). Empty session -> `{ processes: [], count: 0 }` (200, not 404).
// Log content is the TAIL; a missing log file returns 200 with the
// `(log file not found)` marker content; unknown (session, pid) is 404.
//
// Both fns pass `silent: true` — the list is SSE-push driven
// (`background_process_created/completed`) with manual + resync refetch,
// and the log tail polls every 2s only while expanded, so a toast on
// every transient 404/5xx would be noise. Callers render
// inline state (empty / error / marker) instead.

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

/**
 * List all background processes (`command background=true` rows) for a
 * session, ordered by started_at ASC.
 *
 * GET /api/llm/session/:sid/background_processes
 */
export async function getBackgroundProcesses(
  sessionId: string,
): Promise<BackgroundProcessListResponse> {
  return await apiFetch<BackgroundProcessListResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes`,
    { silent: true },
  )
}

/**
 * Read the TAIL of one background process's log file.
 *
 * GET /api/llm/session/:sid/background_processes/:pid/log?max_bytes=20480
 * `maxBytes` defaults to 20480, clamped server-side to [1, 1048576].
 */
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

// ─── Right-sidebar terminal (PTY over REST + poll) ───────────────────────────
// Backend: terminal_create/input/output/resize/delete.zig (in-memory PTY
// registry, no migration). All fns pass `silent: true` — output is a
// ~300ms poll, so a toast on every transient failure would be noise.
// Callers render inline state instead.

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

/**
 * Spawn a shell on a fresh PTY.
 *
 * POST /api/terminal/sessions { cwd, shell?, cols?, rows? } -> 201 { id, pid }
 */
export async function createTerminalSession(
  cwd: string,
  opts: { shell?: string; cols?: number; rows?: number } = {},
): Promise<TerminalSession> {
  return await apiFetch<TerminalSession>(`/terminal/sessions`, {
    method: 'POST',
    // NOTE: apiFetch stringifies `body` itself — pass the object, NOT
    // JSON.stringify (double-encoding yields a JSON string the server
    // rejects with 400; caught live 2026-09-16 via DevTools payload).
    body: { cwd, ...opts },
    silent: true,
  })
}

/**
 * Write keystrokes to the PTY.
 *
 * POST /api/terminal/sessions/:id/input { data } -> 200 { ok, bytes }
 */
export async function sendTerminalInput(
  id: string,
  data: string,
): Promise<{ ok: boolean; bytes: number }> {
  return await apiFetch<{ ok: boolean; bytes: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/input`,
    { method: 'POST', body: { data }, silent: true },
  )
}

/**
 * Poll output since `cursor`.
 *
 * GET /api/terminal/sessions/:id/output?cursor=N
 * -> 200 { data, cursor, exited, exit_code }
 */
export async function getTerminalOutput(id: string, cursor = 0): Promise<TerminalOutput> {
  const params = new URLSearchParams({ cursor: String(cursor) })
  return await apiFetch<TerminalOutput>(
    `/terminal/sessions/${encodeURIComponent(id)}/output?${params}`,
    { silent: true },
  )
}

/**
 * Resize the PTY window.
 *
 * POST /api/terminal/sessions/:id/resize { cols, rows } -> 200 { ok, cols, rows }
 */
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

/**
 * Kill the shell and drop the session.
 *
 * DELETE /api/terminal/sessions/:id -> 200 { ok }
 */
export async function deleteTerminalSession(id: string): Promise<{ ok: boolean }> {
  return await apiFetch<{ ok: boolean }>(`/terminal/sessions/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    silent: true,
  })
}

// ─── Documents (Migration 095) ───────────────────────────────────────────
// Workspace-scoped markdown documents. A document belongs to a workspace
// directly — it is NOT a `workspace_items` row and never appears in the
// project tree; the sidebar's Documents section is its only home.
//
// The backend scopes every read AND every write by `workspace_id` taken
// from the path, so a workspace id that is not the active one returns 404
// on detail and an empty list on collection. There is no client-side
// filter doing that work, and adding one would be a false guarantee.

/** One row of the `documents` table. Mirrors `documents_store.DocumentRow`. */
export interface Document {
  id: string
  workspace_id: string
  title: string
  /**
   * The markdown body. Always a string — the backend flattens SQL NULL to
   * `''`, so there is no null case to handle here.
   */
  content: string
  /** `'markdown'` in v1. Reserved for future formats. */
  format: string
  created_at: string
  updated_at: string
}

/**
 * GET /api/workspaces/:workspaceId/documents
 *
 * All documents in one workspace, most-recently-updated first. Backs the
 * sidebar's Documents section, so it runs on every sidebar load.
 */
export async function listDocuments(
  workspaceId: string,
): Promise<{ documents: Document[]; count: number }> {
  return await apiFetch<{ documents: Document[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { track: false },
  )
}

/**
 * GET /api/workspaces/:workspaceId/documents/:documentId
 *
 * Returns 404 for an id that does not exist AND for one that belongs to
 * another workspace — the backend reports both identically so this call
 * cannot be used to probe another workspace's row ids.
 */
export async function getDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { track: false },
  )
}

/**
 * POST /api/workspaces/:workspaceId/documents
 *
 * Body: `{ title, content?, format? }`. `title` is required and must be
 * non-blank; `content` may be empty (a blank note is a legitimate
 * starting state and round-trips as `''` rather than tripping the
 * column's NOT NULL). Returns 201 with the stored row.
 */
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

/**
 * PATCH /api/workspaces/:workspaceId/documents/:documentId
 *
 * Partial update. An OMITTED field keeps its current value; `content: ''`
 * genuinely clears the body. Omitting `content` does not clear it — the
 * two are different and the backend treats them differently.
 */
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

/**
 * DELETE /api/workspaces/:workspaceId/documents/:documentId
 *
 * Returns 404 for another workspace's id, and deletes nothing in that
 * case.
 */
export async function deleteDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'DELETE' },
  )
}

// ─── Workspace secrets (Migration 101) ───────────────────────────────────
// Named credentials scoped to one workspace: an API key the agent's tools
// can substitute into a request, never displayed back to the browser.
//
// NO RESPONSE EVER CONTAINS THE VALUE. `listSecrets`, `createSecret` and
// `updateSecret` all return rows with `{ id, name, created_at, updated_at }`
// and nothing else — no HTTP read path ever carries the stored value. There is
// deliberately no `value` field on
// `Secret` and no `key_hint`: a hint is a partial disclosure of the very
// thing being stored, and the UI has no use for it that is not a leak.
//
// The write path DOES carry a value — `createSecret`/`updateSecret` take it
// as the request body — but that value exists only for the duration of the
// POST/PATCH. Nothing above this module should retain one: a value held in
// a Pinia ref, a component ref or a `title=` attribute is exactly how a
// write-only secret becomes a readable one.
//
// Like documents, the backend scopes every read AND every write by the
// `workspace_id` taken from the path, so there is no client-side filter
// doing that work — adding one would be a second, weaker copy of a rule
// that already lives in SQL, and the kind of duplicate that drifts.

/**
 * One row of the `workspace_secrets` table.
 *
 * The absence of a value field is the contract, not an oversight. A row
 * this shape cannot be rendered with its credential in it because the
 * credential is not on it.
 */
export interface Secret {
  id: string
  name: string
  created_at: string
  updated_at: string
}

/**
 * GET /api/workspaces/:workspaceId/secrets
 *
 * Metadata only. A workspace with no secrets returns `{ secrets: [],
 * count: 0 }` — which is a different answer from a failed request, and
 * callers must keep the two apart.
 */
export async function listSecrets(
  workspaceId: string,
): Promise<{ secrets: Secret[]; count: number }> {
  return await apiFetch<{ secrets: Secret[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets`,
    { track: false },
  )
}

/**
 * POST /api/workspaces/:workspaceId/secrets
 *
 * Body: `{ name, value }`. `name` must be non-blank and unique within the
 * workspace; `value` is write-only — the response carries the created row
 * WITHOUT it. The caller drops its copy of `value` on the floor once this
 * resolves; there is nothing to read back later.
 */
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

/**
 * PATCH /api/workspaces/:workspaceId/secrets/:secretId
 *
 * Body: `{ name?, value? }`. Both fields are partial — send `{ value }` to
 * rotate a credential without touching its name, or `{ name }` to rename
 * without re-supplying a value. An omitted field keeps its current value;
 * `value: ''` is a rejected empty credential, not a clear operation. Like
 * the reads, the response never carries the value back.
 */
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

/**
 * DELETE /api/workspaces/:workspaceId/secrets/:secretId
 *
 * Returns 404 for another workspace's id, and deletes nothing in that
 * case.
 */
export async function deleteSecret(
  workspaceId: string,
  secretId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/secrets/${encodeURIComponent(secretId)}`,
    { method: 'DELETE' },
  )
}
