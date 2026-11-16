/** buildTaskUrlQuery — helper that builds the URL query object that opens a chat dialog on a workspace item. */
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
  /** Accepted for back-compat with old call sites (some historically passed both `taskId` and `sessionId`). */
  sessionId?: string
  /** Active workspace id from the store, or null if none. */
  activeWorkspaceId?: string | null | undefined
  /** Active workspace item id from the store, or null if none. */
  activeWorkspaceItemId?: string | null | undefined
  /** Active design page id from the store, or null if none. */
  activeDesignPageId?: string | null | undefined
  /** Active workspace item's `item_type`. */
  activeItemType?: string | null | undefined
  /** Fallback current URL query. */
  currentQuery?: UrlQueryInput | null | undefined
}

/** Build a URL query object for chat-dialog navigation on a workspace item. Always emits `view */
export function buildTaskUrlQuery(input: TaskUrlContext): Record<string, string> {
  const taskId = (input.taskId ?? '').toString().trim()
  if (!taskId) {
    throw new Error('buildTaskUrlQuery: taskId is required')
  }

  const wsId = (input.activeWorkspaceId ?? '').toString().trim()
  const activeItemId = (input.activeWorkspaceItemId ?? '').toString().trim()
  const storePageId = (input.activeDesignPageId ?? '').toString().trim()
  const activeItemType = (input.activeItemType ?? '').toString()

  // Breadcrumb from current URL (used for fallback + for view-specific params like sorts/pageId that live in the URL but not the store).
  const urlBreadcrumb = input.currentQuery ? pickBreadcrumbFromQuery(input.currentQuery) : {}

  // Resolve the bare item id.
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
    // Deep-link fallback: workspaceId from URL breadcrumb, itemId derived from either store or URL (both paths land here).
    query.workspaceId = urlBreadcrumb.workspaceId
    query.itemId = buildItemIdWithChat(bareItemId, taskId)
  } else if (bareItemId) {
    // No workspaceId but we know the item id (rare — would be a malformed URL).
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
  if (urlBreadcrumb.sorts) query.sorts = urlBreadcrumb.sorts

  // ─── layout (kanban view mode, lives in URL only) ────────────────
  if (urlBreadcrumb.layout) query.layout = urlBreadcrumb.layout

  return query
}
