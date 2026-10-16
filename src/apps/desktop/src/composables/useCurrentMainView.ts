// src/apps/desktop/src/composables/useCurrentMainView.ts
import { computed, type ComputedRef } from 'vue'
import { useRoute } from 'vue-router'
import { parseAppPath } from '../helpers/appUrl'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'

/** The single source of truth for "what is the main content area currently showing?". */
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string; workspaceId?: string }
  | {
      /** Document page (Migration 095). `/app/{ws}/doc/{id}` — a PAGE shape, so the document
       * REPLACES the main view and the chat is not mounted underneath it. */
      /** `workspaceId` is optional: a deep link that resolves before a workspace is active still
       * renders, and an unresolvable one lets the view say so instead of guessing. */
      kind: 'document'
      documentId: string
      workspaceId?: string
    }
  | {
      kind: 'workspace'
      workspaceId?: string
      /**        * Optional: absent for a standalone `?workspaceId=X` selection with no item open (header
       * dropdown switch — revamp plan 2026-09-22). Row-highlight consumers compare against it, so
       * `undefined` simply means "no row active". */
      itemId?: string
      pageId?: string
      chatTaskId?: string
    }
  | {
      kind: 'kanban-settings'
      workspaceId?: string
      itemId: string
    }
  | { kind: 'none' }

export function useCurrentMainView(): ComputedRef<CurrentMainView> {
  const route = useRoute()
  return computed<CurrentMainView>(() => {
    // Defensive: `useRoute()` returns undefined when called outside a
    // router context (some tests mount the component without mocking
    // vue-router). Treat that as an empty query → `kind: 'none'`.
    const q = (route?.query ?? {}) as Record<string, string>

    // Path-based contract first (plan: 2026-09-22-revamp-ui-chats). A project is a workspace item,
    // so path projects map onto the existing `workspace` kind (itemId = projectId) — every
    // row-highlight consumer keeps working unchanged.
    const parsed = parseAppPath(route?.path ?? '')

    // Document page (Migration 095). No `?doc=` fallback: Migration 095 shipped that overlay shape
    // and was replaced by this path shape before it was in wide use, so there are no links in the
    // wild to keep working and no second way for the URL to name a document.
    if (parsed.kind === 'doc') {
      return { kind: 'document', documentId: parsed.documentId, workspaceId: parsed.workspaceId }
    }

    // Landing with a legacy `?view=` query is not the landing — fall
    // through to the query handling below (the boot rewrite converts
    // it to a path URL on the next tick).
    const landingWithLegacyQuery =
      parsed.kind === 'landing' &&
      (q.view === 'chat' || q.view === 'task' || q.view === 'workspace')
    if (parsed.kind === 'landing' && !landingWithLegacyQuery) return { kind: 'none' }
    if (parsed.kind === 'workspace') return { kind: 'workspace', workspaceId: parsed.workspaceId }
    if (parsed.kind === 'chat') {
      return { kind: 'chat', sessionId: parsed.sessionId, workspaceId: parsed.workspaceId }
    }
    if (parsed.kind === 'project' || parsed.kind === 'projectChat') {
      return {
        kind: 'workspace',
        workspaceId: parsed.workspaceId,
        itemId: parsed.projectId,
        pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
        chatTaskId: parsed.kind === 'projectChat' ? parsed.chatTaskId : undefined,
      }
    }
    // `other` (settings, kanban-settings, legacy routes, unknown):
    // fall through to the query + path-param handling below.
    const view = q.view
    if (view === 'chat') {
      if (typeof q.session === 'string' && q.session.length > 0) {
        return { kind: 'chat', sessionId: q.session }
      }
      return { kind: 'none' }
    }
    if (view === 'workspace') {
      if (typeof q.itemId === 'string' && q.itemId.length > 0) {
        // Parse the wire-shape itemId (may carry `/chat/<taskId>` suffix when the chat dialog is
        // open). The bare id is exposed as `itemId`; the optional chat task id is exposed as
        // `chatTaskId`.
        const parsed = parseItemIdWithChat(q.itemId)
        return {
          kind: 'workspace',
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: parsed.itemId,
          pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
          chatTaskId: parsed.chatTaskId ?? undefined,
        }
      }
      // Standalone workspace selection: `?view=workspace&workspaceId=X`
      // with no item open (header dropdown switch — revamp plan
      // 2026-09-22). itemId stays undefined → no sidebar row active.
      if (typeof q.workspaceId === 'string' && q.workspaceId.length > 0) {
        return { kind: 'workspace', workspaceId: q.workspaceId }
      }
      return { kind: 'none' }
    }
    // kanban-settings page (path route /app/kanban/:itemId/settings).
    // itemId comes from route.params (path); workspaceId is optional
    // and comes from ?workspaceId=X query (used by the back navigation
    // to round-trip back to ?view=workspace&workspaceId=X&itemId=Y).
    // itemId may be empty if Vue Router matched a malformed URL — we
    // return the empty string so the page can render a friendly hint
    // instead of crashing.
    //
    // The regex matches /app/kanban/<itemId>/settings with an empty
    // itemId ALLOWED (defensive — Vue Router would normally reject
    // this, but we degrade gracefully so the page can render a hint).
    // The regex deliberately does NOT match /app/kanban/X (no /settings)
    // — the kanban board itself stays at the existing ?view=workspace
    // URL, so a future migration to /app/kanban/:itemId would be a
    // separate plan.
    const kanbanSettingsMatch = /^\/app\/kanban\/([^/]*)\/settings\/?$/.exec(route?.path ?? '')
    if (kanbanSettingsMatch) {
      return {
        kind: 'kanban-settings',
        workspaceId:
          typeof q.workspaceId === 'string' && q.workspaceId.length > 0 ? q.workspaceId : undefined,
        itemId: kanbanSettingsMatch[1] ?? '',
      }
    }
    return { kind: 'none' }
  })
}
