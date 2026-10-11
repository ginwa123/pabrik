/**
 * appUrl — the single builder / parser for the app's path-based URL
 * contract (plan: 2026-09-22-revamp-ui-chats-workspace-scoped).
 *
 * ## Contract
 *
 *   /app                                            landing (creates a workspace)
 *   /app/{workspaceId}                              workspace selected
 *   /app/{workspaceId}/chat/{sessionId}             chat open
 *   /app/{workspaceId}/doc/{documentId}             document open (Migration 095)
 *   /app/{workspaceId}/projects/{projectId}         project open
 *   /app/{workspaceId}/projects/{projectId}/chat/{taskId}
 *                                                   task chat over a project
 *                                                   (path suffix — mirrors the
 *                                                   old `itemId/chat/T` suffix)
 *
 * Project sub-state stays in the query string: `?pageId=…&detail=…&sorts=…`.
 * Canonical form has NO trailing slash (the router accepts `/…/` and the
 * AppLayout rewrite strips it via `router.replace`).
 *
 * Unchanged: `/app/settings`, `/app/kanban/:itemId/settings`.
 * Legacy (rewritten once at boot to the shapes above, never emitted):
 * `/app/chat/:sid`, `/app/task/:tid`, and every `?view=…` query URL.
 *
 * ## Why this exists
 *
 * Before this helper, every navigation call site hand-built
 * `{ path: '/app', query: { view: 'workspace', … } }` objects inline
 * (~193 `view:` matches across src + specs). The path migration would
 * have scattered string concat everywhere; instead every writer goes
 * through `buildAppUrl` and every reader through `parseAppPath`, so
 * the contract lives in exactly one file.
 *
 * Pure functions — no Vue / Pinia / vue-router imports. Trivially testable.
 */

import { parseItemIdWithChat } from './buildItemIdWithChat'
import { buildTaskUrlQuery, type TaskUrlContext } from './buildTaskUrlQuery'

export interface AppUrlTarget {
  /** Workspace id. Absent → landing (`/app`). */
  workspaceId?: string | null | undefined
  /** Standalone chat session id (sidebar CHATS row). */
  chatSessionId?: string | null | undefined
  /** Project id (= workspace item id). */
  projectId?: string | null | undefined
  /** Task chat id open over a project (requires projectId). */
  chatTaskId?: string | null | undefined
  /**
   * Document id (Migration 095). Emits `/app/{ws}/doc/{id}` — a PAGE, not
   * a query overlay: the document replaces the main view, so it must not
   * borrow the path of whatever page happened to be open underneath it.
   */
  documentId?: string | null | undefined
  /** Project sub-state (pageId / detail / sorts / panel …). Passed through. */
  query?: Record<string, string> | null | undefined
}

export interface AppUrlLocation {
  path: string
  query: Record<string, string>
}

export type ParsedAppPath =
  | { kind: 'landing' }
  | { kind: 'workspace'; workspaceId: string }
  | { kind: 'chat'; workspaceId: string; sessionId: string }
  | { kind: 'doc'; workspaceId: string; documentId: string }
  | { kind: 'project'; workspaceId: string; projectId: string }
  | { kind: 'projectChat'; workspaceId: string; projectId: string; chatTaskId: string }
  | { kind: 'other'; path: string }

/**
 * First path segments that are route keywords, never workspace ids.
 * Without this, `/app/chat/sess_9` would parse as workspace `chat` —
 * the legacy routes must stay `{ kind: 'other' }` so the boot rewrite
 * (not the normal view derivation) handles them. `doc` is here for a
 * different reason: a bare `/app/doc` is a malformed document URL, and
 * silently reading it as a workspace named "doc" would boot the user
 * into a workspace that does not exist.
 */
const RESERVED_FIRST_SEGMENTS = new Set(['chat', 'doc', 'task', 'settings', 'kanban', 'projects'])

const nonEmpty = (v: string | null | undefined): v is string =>
  typeof v === 'string' && v.length > 0

/**
 * Build a router location for the given target. Always emits the
 * canonical no-trailing-slash path. Throws when the combination is
 * incoherent (chatTaskId without projectId, chatSessionId without
 * workspaceId, or a chatSessionId alongside a project).
 */
export function buildAppUrl(input: AppUrlTarget): AppUrlLocation {
  const workspaceId = (input.workspaceId ?? '').toString().trim()
  const chatSessionId = (input.chatSessionId ?? '').toString().trim()
  const projectId = (input.projectId ?? '').toString().trim()
  const chatTaskId = (input.chatTaskId ?? '').toString().trim()
  const documentId = (input.documentId ?? '').toString().trim()
  const query: Record<string, string> = { ...input.query }

  if (!workspaceId) {
    if (chatSessionId || projectId || chatTaskId || documentId) {
      throw new Error('buildAppUrl: workspaceId is required for chat/project/document targets')
    }
    return { path: '/app', query }
  }
  // A document is a PAGE that replaces the main view, so it is exclusive
  // with chat/project the same way chatSessionId and projectId are. Two of
  // these at once means a caller lost track of what it is navigating to.
  if (documentId && (chatSessionId || projectId || chatTaskId)) {
    throw new Error('buildAppUrl: documentId cannot combine with a chat/project target')
  }
  if (chatSessionId && (projectId || chatTaskId)) {
    throw new Error('buildAppUrl: chatSessionId cannot combine with a project target')
  }
  if (chatTaskId && !projectId) {
    throw new Error('buildAppUrl: chatTaskId requires projectId')
  }

  let path = `/app/${workspaceId}`
  if (documentId) {
    path += `/doc/${documentId}`
  } else if (chatSessionId) {
    path += `/chat/${chatSessionId}`
  } else if (projectId) {
    path += `/projects/${projectId}`
    if (chatTaskId) path += `/chat/${chatTaskId}`
  }
  return { path, query }
}

/**
 * Parse an app path into its kind + ids. Trailing slashes are ignored
 * (canonical form has none). Anything that is not one of the five app
 * shapes — settings, kanban-settings, legacy routes, unknown — comes
 * back as `{ kind: 'other', path }` so callers can fall through.
 */
export function parseAppPath(rawPath: string): ParsedAppPath {
  const path = normalizeAppPath(rawPath)
  if (path === '/app') return { kind: 'landing' }
  let m = /^\/app\/([^/]+)\/chat\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'chat', workspaceId: m[1], sessionId: m[2] }
  // `doc` before the project/workspace branches: `/app/{ws}/doc/{id}` has
  // the same segment count as `/app/{ws}/chat/{sid}`, and matching it after
  // them would let a future `chat` branch swallow a document.
  m = /^\/app\/([^/]+)\/doc\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'doc', workspaceId: m[1], documentId: m[2] }
  m = /^\/app\/([^/]+)\/projects\/([^/]+)\/chat\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2] && m[3]) {
    return { kind: 'projectChat', workspaceId: m[1], projectId: m[2], chatTaskId: m[3] }
  }
  m = /^\/app\/([^/]+)\/projects\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'project', workspaceId: m[1], projectId: m[2] }
  m = /^\/app\/([^/]+)$/.exec(path)
  if (m?.[1] && !RESERVED_FIRST_SEGMENTS.has(m[1])) return { kind: 'workspace', workspaceId: m[1] }
  return { kind: 'other', path }
}

/**
 * Canonicalize a path: strip trailing slashes (root `/` is kept).
 * `/app/ws_1/` → `/app/ws_1`. Ids never contain slashes in this
 * codebase, so a trailing slash is always noise, never content.
 */
export function normalizeAppPath(rawPath: string): string {
  if (typeof rawPath !== 'string' || rawPath.length === 0) return '/app'
  if (rawPath === '/') return '/'
  return rawPath.replace(/\/+$/, '') || '/'
}

/** True when the path is one of the five app shapes (landing included). */
export function isAppPath(rawPath: string): boolean {
  return parseAppPath(rawPath).kind !== 'other'
}

/**
 * Path-shaped twin of `buildTaskUrlQuery` (same `TaskUrlContext`
 * input, same workspace/item/pageId/sorts resolution incl. URL
 * breadcrumb fallback). Emits `/app/{ws}/projects/{item}/chat/{task}`
 * instead of the `?view=workspace&itemId=Y/chat/T` query object, so
 * overlay-close handlers and task navigations don't duplicate the
 * resolution rules. The `view` key `buildTaskUrlQuery` always emits
 * is dropped — the path carries it.
 */
export function buildTaskAppUrl(input: TaskUrlContext): AppUrlLocation {
  const q = buildTaskUrlQuery(input)
  const wsId = q.workspaceId ?? ''
  const { itemId, chatTaskId } = parseItemIdWithChat(q.itemId ?? '')
  const sub: Record<string, string> = {}
  if (q.pageId) sub.pageId = q.pageId
  if (q.sorts) sub.sorts = q.sorts
  if (wsId && itemId) {
    return buildAppUrl({
      workspaceId: wsId,
      projectId: itemId,
      chatTaskId: chatTaskId ?? undefined,
      query: sub,
    })
  }
  if (wsId) return buildAppUrl({ workspaceId: wsId, query: sub })
  return { path: '/app', query: sub }
}

export interface LegacyAppUrl {
  /** The path-shape rewrite target, when the path alone decides it. */
  path: string | null
  /** Query params the rewrite must preserve (sorts/detail/pageId/tab…). */
  query: Record<string, string>
}

/**
 * Detect a legacy URL that needs the one-time boot rewrite to the path
 * contract. Returns null when the URL is already canonical.
 *
 * Legacy shapes:
 * - `/app/chat/:sid` → `/app/{ws}/chat/:sid` (ws resolved via session detail)
 * - `/app/task/:tid` → `/app/{ws}/projects/{item}/chat/:tid` (ws+item via task lookup)
 * - `?view=chat&session=X`, `?view=task&task=X…`, `?view=workspace&…` on `/app`
 * - any trailing-slash path (normalize only — no workspace lookup needed)
 *
 * The caller fills in the workspace-dependent path: this function reports
 * WHAT kind of legacy URL it is and carries the preservable query through.
 * Session/task → workspace resolution lives in AppLayout (it owns the
 * store + the session-detail `workspace_id` fetch), not here.
 */
export function detectLegacyAppUrl(
  rawPath: string,
  rawQuery: Record<string, unknown> | null | undefined,
): LegacyAppUrl | null {
  const path = typeof rawPath === 'string' ? rawPath : '/app'
  const query: Record<string, string> = {}
  if (rawQuery) {
    for (const [k, v] of Object.entries(rawQuery)) {
      if (typeof v === 'string' && v.length > 0) query[k] = v
    }
  }

  // Trailing slash on an otherwise-canonical path: normalize only.
  if (path !== normalizeAppPath(path) && isAppPath(path)) {
    return { path: normalizeAppPath(path), query }
  }

  // Legacy path routes (kept registered so AppLayout mounts for the rewrite).
  let m = /^\/app\/chat\/([^/]+)\/?$/.exec(path)
  if (m?.[1]) return { path: null, query: { ...query, __legacy: `chat:${m[1]}` } }
  m = /^\/app\/task\/([^/]+)\/?$/.exec(path)
  if (m?.[1]) return { path: null, query: { ...query, __legacy: `task:${m[1]}` } }

  // Legacy query URLs on /app.
  if (normalizeAppPath(path) === '/app' && nonEmpty(query.view)) {
    const view = query.view
    if (view === 'chat' || view === 'task' || view === 'workspace') {
      const { view: _dropped, ...rest } = query
      void _dropped
      return { path: null, query: { ...rest, __legacy: `view:${view}` } }
    }
  }
  return null
}

/**
 * Stale-write guard for ChatView's diff URL writers (`syncDiffParam`,
 * `syncDiffQuery`).
 *
 * Path-based URLs carry the session in the path, not the query, so the
 * legacy `route.query.view/session` guards are no-ops there. A dying view
 * (chat A unmounting while ChatsList navigates to chat B) must not issue
 * `router.replace` once the path names another session: it either cancels
 * B's pending navigation (view snaps back to A) or stamps A's `?diff=` onto
 * B's URL — the "click a left chat after opening a right-sidebar file does
 * nothing" repro.
 *
 * Returns true when the view owning `sessionId` must NOT touch `routePath`:
 * - `/app/{ws}/chat/{sid}` with `sid !== sessionId` (including the
 *   post-switch path `/app/{ws}/chat/B` seen from dying A);
 * - `/app/{ws}/projects/{p}/chat/{tid}` with `tid !== sessionId`;
 * - `/app/{ws}`, `/app/{ws}/projects/{p}`, `/app/{ws}/doc/{d}` — ChatView
 *   never owns those surfaces, so any write from it is stale.
 * Landing (`/app`) and unknown paths return false and defer to the legacy
 * query guards (deep links, router-less mounts).
 */
export function isChatRouteStaleForSession(routePath: string, sessionId: string): boolean {
  // parseAppPath is pure string matching with no throws (no I/O, no JSON),
  // so no try/catch: a malformed path returns { kind: 'other' } below.
  const parsed: ParsedAppPath = parseAppPath(routePath)
  if (parsed.kind === 'chat') return parsed.sessionId !== sessionId
  if (parsed.kind === 'projectChat') return parsed.chatTaskId !== sessionId
  if (parsed.kind === 'workspace' || parsed.kind === 'project' || parsed.kind === 'doc') return true
  return false
}
