/**
 * buildItemIdWithChat — encode / decode the `/chat/<taskId>` suffix
 * on the `itemId` query value used by AppLayout's URL scheme.
 *
 * Background: the chat-open workspace URL has the shape
 *   ?view=workspace&workspaceId=X&itemId=item_Y/chat/task_W
 * The `itemId` value carries an extra `/chat/<taskId>` suffix when
 * the chat dialog is open. This helper centralises the parse +
 * build logic so every URL writer / reader stays consistent.
 *
 * Plan: docs/superpowers/plans/2026-08-15-simplify-url-browser.md
 * Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 */

/** The literal separator between the bare item id and the chat task id. */
export const CHAT_SUFFIX = '/chat/'

/**  * Combine a workspace item id with an optional chat task id. Throws if `itemId` itself already
 * contains the `/chat/` substring (defensive — item ids never contain slashes in this codebase). */
export function buildItemIdWithChat(itemId: string, chatTaskId: string | null): string {
  if (typeof itemId !== 'string' || itemId.length === 0) {
    throw new Error(`buildItemIdWithChat: itemId must be a non-empty string`)
  }
  if (itemId.includes(CHAT_SUFFIX)) {
    throw new Error(
      `buildItemIdWithChat: item id cannot contain "${CHAT_SUFFIX}" (got "${itemId}")`,
    )
  }
  if (chatTaskId === null || chatTaskId === '') return itemId
  return `${itemId}${CHAT_SUFFIX}${chatTaskId}`
}

/**
 * Parse a raw `itemId` query value into a bare item id and an optional chat task id. /
 */
export function parseItemIdWithChat(raw: string): {
  itemId: string
  chatTaskId: string | null
} {
  if (typeof raw !== 'string' || raw.length === 0) {
    return { itemId: '', chatTaskId: null }
  }
  const idx = raw.indexOf(CHAT_SUFFIX)
  if (idx === -1) return { itemId: raw, chatTaskId: null }
  return {
    itemId: raw.slice(0, idx),
    chatTaskId: raw.slice(idx + CHAT_SUFFIX.length),
  }
}

/** Subset of vue-router LocationQuery that we accept. */
export type UrlQueryInput = Record<string, unknown>

/** Pick breadcrumb params (`workspaceId`, `itemId`, `pageId`, `sorts`)
 * from a vue-router LocationQuery and return them as a plain
 * `Record<string, string>`. Used to preserve context when building
 * task URLs that append to the current URL.
 * Moved from `buildTaskUrlQuery.ts` (where it was inlined) so the
 * helpers can be co-located and the `pickBreadcrumbFromQuery` import
 * remains a one-line re-export. */
export function pickBreadcrumbFromQuery(query: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {}
  // `layout` is the kanban columns/rows view mode. It lives in the URL only
  // (like `sorts`), so it must ride the breadcrumb to survive the
  // board → task-chat → close round-trip.
  for (const key of ['workspaceId', 'itemId', 'pageId', 'sorts', 'layout']) {
    const v = query[key]
    if (typeof v === 'string' && v.length > 0) out[key] = v
  }
  return out
}
