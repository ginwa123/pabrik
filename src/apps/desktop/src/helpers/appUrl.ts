/** appUrl. */
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
  /** Kanban add-task page (`/add` appended to the project path; requires projectId). */
  addTask?: boolean | null | undefined
  /**    * Document id (Migration 095). Emits `/app/{ws}/doc/{id}` — a PAGE, not a query overlay: the
   * document replaces the main view, so it must not borrow the path of whatever page happened to be
   * open underneath it. */
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
  | { kind: 'projectAdd'; workspaceId: string; projectId: string }
  | { kind: 'other'; path: string }

/** First path segments that are route keywords, never workspace ids. Without this,
 * `/app/chat/sess_9` would parse as workspace `chat` — the legacy routes must stay `{ kind: 'other'
 * }` so the boot rewrite (not the normal view derivation) handles them. */
const RESERVED_FIRST_SEGMENTS = new Set(['chat', 'doc', 'task', 'settings', 'kanban', 'projects'])

const nonEmpty = (v: string | null | undefined): v is string =>
  typeof v === 'string' && v.length > 0

/**  * Build a router location for the given target. Always emits the canonical no-trailing-slash path.
 * Throws when the combination is incoherent (chatTaskId without projectId, chatSessionId without
 * workspaceId, or a chatSessionId alongside a project). */
export function buildAppUrl(input: AppUrlTarget): AppUrlLocation {
  const workspaceId = (input.workspaceId ?? '').toString().trim()
  const chatSessionId = (input.chatSessionId ?? '').toString().trim()
  const projectId = (input.projectId ?? '').toString().trim()
  const chatTaskId = (input.chatTaskId ?? '').toString().trim()
  const documentId = (input.documentId ?? '').toString().trim()
  const addTask = input.addTask === true
  const query: Record<string, string> = { ...input.query }

  if (!workspaceId) {
    if (chatSessionId || projectId || chatTaskId || documentId || addTask) {
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
  if (addTask && !projectId) {
    throw new Error('buildAppUrl: addTask requires projectId')
  }
  if (addTask && chatTaskId) {
    throw new Error('buildAppUrl: addTask cannot combine with chatTaskId')
  }

  let path = `/app/${workspaceId}`
  if (documentId) {
    path += `/doc/${documentId}`
  } else if (chatSessionId) {
    path += `/chat/${chatSessionId}`
  } else if (projectId) {
    path += `/projects/${projectId}`
    if (chatTaskId) path += `/chat/${chatTaskId}`
    if (addTask) path += '/add'
  }
  return { path, query }
}

/** Where Settings lives, given the workspace in scope and a remembered section. The workspace rides
 * in the PATH, so no settings page ever has to guess which workspace it is about. */
export function buildSettingsUrl(
  workspaceId: string | null | undefined,
  section?: string | null,
): AppUrlLocation {
  const id = (workspaceId ?? '').toString().trim()
  if (!id) return { path: '/app/settings', query: {} }
  const query: Record<string, string> = {}
  if (section) query.section = section
  return { path: `/app/${id}/settings`, query }
}

/**  * Parse an app path into its kind + ids. Trailing slashes are ignored (canonical form has none).
 * Anything that is not one of the six app shapes — settings, kanban-settings, legacy routes,
 * unknown — comes back as `{ kind: 'other', path }` so callers can fall through. */
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
  // `/add` extends the `/projects/{pid}` shape and is matched before it: both
  // branches are anchored, so order changes no result today, but the shorter
  // pattern must never get the first chance to claim this page.
  m = /^\/app\/([^/]+)\/projects\/([^/]+)\/add$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'projectAdd', workspaceId: m[1], projectId: m[2] }
  m = /^\/app\/([^/]+)\/projects\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'project', workspaceId: m[1], projectId: m[2] }
  m = /^\/app\/([^/]+)$/.exec(path)
  if (m?.[1] && !RESERVED_FIRST_SEGMENTS.has(m[1])) return { kind: 'workspace', workspaceId: m[1] }
  return { kind: 'other', path }
}

/**  * Canonicalize a path: strip trailing slashes (root `/` is kept). `/app/ws_1/` → `/app/ws_1`. Ids
 * never contain slashes in this codebase, so a trailing slash is always noise, never content. */
export function normalizeAppPath(rawPath: string): string {
  if (typeof rawPath !== 'string' || rawPath.length === 0) return '/app'
  if (rawPath === '/') return '/'
  return rawPath.replace(/\/+$/, '') || '/'
}

/** True when the path is one of the six app shapes (landing included). */
export function isAppPath(rawPath: string): boolean {
  return parseAppPath(rawPath).kind !== 'other'
}

/** Path-shaped twin of `buildTaskUrlQuery` (same `TaskUrlContext` input, same
 * workspace/item/pageId/sorts resolution incl. URL breadcrumb fallback). */
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

/** Detect a legacy URL that needs the one-time boot rewrite to the path contract. */
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

/** Stale-write guard for ChatView's diff URL writers (`syncDiffParam`, `syncDiffQuery`). Path-based
 * URLs carry the session in the path, not the query, so the legacy `route.query.view/session`
 * guards are no-ops there. */
export function isChatRouteStaleForSession(routePath: string, sessionId: string): boolean {
  // parseAppPath is pure string matching with no throws (no I/O, no JSON),
  // so no try/catch: a malformed path returns { kind: 'other' } below.
  const parsed: ParsedAppPath = parseAppPath(routePath)
  if (parsed.kind === 'chat') return parsed.sessionId !== sessionId
  if (parsed.kind === 'projectChat') return parsed.chatTaskId !== sessionId
  if (
    parsed.kind === 'workspace' ||
    parsed.kind === 'project' ||
    parsed.kind === 'projectAdd' ||
    parsed.kind === 'doc'
  ) {
    return true
  }
  return false
}
