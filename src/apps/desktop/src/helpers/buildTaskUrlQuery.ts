/**
 * buildTaskUrlQuery — helper that builds the URL query object that
 * opens a chat dialog on a workspace item. The wire shape is:
 *
 *   ?view=workspace&workspaceId=X&itemId=item_Y/chat/task_W[&pageId=Z][&sorts=…]
 *
 * The chat task id is encoded as a `/chat/<taskId>` suffix on the
 * `itemId` value (see `buildItemIdWithChat`). This replaces the
 * legacy shape `?view=task&task=X&workspaceId=Y&itemId=Z` which
 * carried the same context under two different `view` values.
 *
 * Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 *
 * ## Why this exists
 *
 * Before this helper, several Vue call sites wrote task-URL
 * navigation with only `task` (and sometimes `itemId`), never
 * `workspaceId`. The user originally reported
 * (task_1785774094183): "add workspace_id params when view the
 * task, like in kanban mode or design mode" — the URL
 * `?view=task&task=X&itemId=Y` was missing `workspaceId`, breaking
 * URL-based persistence for deep-link / refresh / share. The 2026-08-06
 * fix moved the resolution logic into this helper.
 *
 * The 2026-08-15 simplify-url-browser refactor updated the wire shape:
 * this helper now emits `view=workspace` (NOT `view=task`) with the
 * chat task id encoded as the `/chat/<taskId>` suffix on `itemId`.
 * The redundant `session` query param is dropped (it's equal to the
 * task id per `task.id == session_id`).
 *
 * ## Algorithm
 *
 * Resolution order for workspaceId / itemId (first non-empty wins):
 *
 *   1. Active store state (`activeWorkspaceId`, `activeWorkspaceItemId`).
 *      AUTHORITATIVE — the user clicked the task from a workspace
 *      context, so the URL must reflect it.
 *   2. URL breadcrumb fallback (`route.query.workspaceId` etc.) for
 *      deep-link / share-link round-trips.
 *
 * `pageId` is gated on the active item type being `'design'` (avoids
 * cross-leak from a stale design page into a kanban URL).
 *
 * `sorts` is preserved from the URL breadcrumb (kanban per-column
 * sort state — survives the workspace → chat round-trip via the
 * existing `savedSortsParam` snapshot).
 *
 * ## Pure function
 *
 * No Vue / Pinia / vue-router imports. Pass in the active state.
 * Trivially testable.
 */
import {
  buildItemIdWithChat,
  parseItemIdWithChat,
  pickBreadcrumbFromQuery,
  type UrlQueryInput,
} from './buildItemIdWithChat'

export type { UrlQueryInput } from './buildItemIdWithChat'
export { pickBreadcrumbFromQuery }

export interface TaskUrlContext {
  /** The task id to put in the `/chat/<taskId>` suffix (required). */
  taskId: string
  /**
   * Accepted for back-compat with old call sites (some historically
   * passed both `taskId` and `sessionId`).
   * Ignored under the new wire shape — the chat task id in the
   * suffix IS the session id per `task.id == session_id`.
   */
  sessionId?: string
  /** Active workspace id from the store, or null if none. */
  activeWorkspaceId?: string | null | undefined
  /** Active workspace item id from the store, or null if none. */
  activeWorkspaceItemId?: string | null | undefined
  /** Active design page id from the store, or null if none. */
  activeDesignPageId?: string | null | undefined
  /**
   * Active workspace item's `item_type`. Gates `pageId` (design-only).
   */
  activeItemType?: string | null | undefined
  /**
   * Fallback current URL query. Used when no active store state.
   */
  currentQuery?: UrlQueryInput | null | undefined
}

/** Build a URL query object for chat-dialog navigation on a
 * workspace item. Always emits `view: 'workspace'` and includes the
 * `/chat/<taskId>` suffix on `itemId`. */
export function buildTaskUrlQuery(input: TaskUrlContext): Record<string, string> {
  const taskId = (input.taskId ?? '').toString().trim()
  if (!taskId) {
    throw new Error('buildTaskUrlQuery: taskId is required')
  }

  const wsId = (input.activeWorkspaceId ?? '').toString().trim()
  const activeItemId = (input.activeWorkspaceItemId ?? '').toString().trim()
  const storePageId = (input.activeDesignPageId ?? '').toString().trim()
  const activeItemType = (input.activeItemType ?? '').toString()

  // Breadcrumb from current URL (used for fallback + for view-specific
  // params like sorts/pageId that live in the URL but not the store).
  const urlBreadcrumb = input.currentQuery ? pickBreadcrumbFromQuery(input.currentQuery) : {}

  // Resolve the bare item id. Precedence: 1. Active store (authoritative) 2. URL breadcrumb — strip
  // any existing /chat/ suffix so we don't pass a wire-shape value through to buildItemIdWithChat
  // (which would throw).
  let bareItemId = activeItemId
  if (!bareItemId && urlBreadcrumb.itemId) {
    bareItemId = parseItemIdWithChat(urlBreadcrumb.itemId).itemId
  }

  const query: Record<string, string> = { view: 'workspace' }

  // ─── workspaceId + itemId (with /chat/<taskId> suffix) ──────────
  if (wsId && bareItemId) {
    query.workspaceId = wsId
    query.itemId = buildItemIdWithChat(bareItemId, taskId)
  } else if (urlBreadcrumb.workspaceId && bareItemId) {
    // Deep-link fallback: workspaceId from URL breadcrumb, itemId
    // derived from either store or URL (both paths land here).
    query.workspaceId = urlBreadcrumb.workspaceId
    query.itemId = buildItemIdWithChat(bareItemId, taskId)
  } else if (bareItemId) {
    // No workspaceId but we know the item id (rare — would be a
    // malformed URL). Emit the bare item id with the chat suffix so
    // the URL is self-describing.
    query.itemId = buildItemIdWithChat(bareItemId, taskId)
  }

  // ─── pageId (design-only) ────────────────────────────────────────
  const isActiveDesign = activeItemType === 'design'
  const urlPageId = urlBreadcrumb.pageId ?? ''
  if (isActiveDesign) {
    if (storePageId) query.pageId = storePageId
    else if (urlPageId) query.pageId = urlPageId
  }

  // ─── sorts (kanban view-specific, lives in URL only) ─────────────
  // The kanban per-column sort state (`?sorts=col_X:name:asc,...`)
  // lives in the URL and is NOT tracked by the workspaces store.
  // The user expects it to survive the workspace → chat round-trip
  // (the close-restore flow in AppLayout.handleCloseTaskView reads
  // savedSortsParam, which is snapshot from route.query.sorts at
  // handleSelectTask time). Preserve it in the new task URL so the
  // URL stays self-describing ("I'm on kanban X with sort S,
  // viewing chat Y").
  if (urlBreadcrumb.sorts) query.sorts = urlBreadcrumb.sorts

  // ─── layout (kanban view mode, lives in URL only) ──────────────── Same reasoning as `sorts`:
  // the columns/rows choice is URL state, not store state, so it must be carried explicitly or the
  // board → chat → close round-trip silently snaps the board back to column mode.
  if (urlBreadcrumb.layout) query.layout = urlBreadcrumb.layout

  return query
}
