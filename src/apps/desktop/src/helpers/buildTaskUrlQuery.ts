/** buildTaskUrlQuery — helper that builds the URL query object that opens a chat dialog on a
 * workspace item. */
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
  /**    * Accepted for back-compat with old call sites (some historically passed both `taskId` and
   * `sessionId`). Ignored under the new wire shape — the chat task id in the suffix IS the session
   * id per `task.id == session_id`. */
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

/**  * Build a URL query object for chat-dialog navigation on a workspace item. Always emits `view:
 * 'workspace'` and includes the `/chat/<taskId>` suffix on `itemId`. */
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

  // ─── sorts (kanban view-specific, lives in URL only) ───────────── The kanban per-column sort
  // state (`?sorts=col_X:name:asc,...`) lives in the URL and is NOT tracked by the workspaces
  // store.
  if (urlBreadcrumb.sorts) query.sorts = urlBreadcrumb.sorts

  // ─── layout (kanban view mode, lives in URL only) ──────────────── Same reasoning as `sorts`:
  // the columns/rows choice is URL state, not store state, so it must be carried explicitly or the
  // board → chat → close round-trip silently snaps the board back to column mode.
  if (urlBreadcrumb.layout) query.layout = urlBreadcrumb.layout

  return query
}
