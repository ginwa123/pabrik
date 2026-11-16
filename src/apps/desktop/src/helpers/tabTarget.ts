/** Pure helpers for browser-style tabs. */
import { parseAppPath } from './appUrl'
import { fileKeyVariants, resolveTabPath } from './tabPath'
import { parseItemIdWithChat } from './buildItemIdWithChat'

export type TabQuery = Record<string, string>

/** Display hint only — drives the glyph and the close tooltip. */
export type TabKind =
  | 'home'
  | 'chat'
  | 'workspace'
  | 'kanban-settings'
  | 'settings'
  | 'document'
  | 'file'
  | 'diff'
  | 'other'

/** Kinds opened *inside* a session rather than picked from the app's navigation. */
export const ARTIFACT_KINDS: TabKind[] = ['file', 'diff']

export function isArtifactKind(kind: TabKind): boolean {
  return ARTIFACT_KINDS.includes(kind)
}

export interface Tab {
  /** Stable across reloads; the value in the URL's `tab` param. */
  id: string
  /** Dedupe identity — two navigations with the same key focus one tab. */
  key: string
  kind: TabKind
  title: string
  path: string
  query: TabQuery
  createdAt: number
  /** The session this tab was opened in. */
  owner?: string
  /** The session's own tab: always first in its row and never closable, so closing the last file still leaves the session on screen. */
  pinned?: boolean
  /** True when the tab's identity was decided without knowing the workspace item's type (a cold-boot deep link, before the tree loaded). */
  provisional?: boolean
}

export interface ClosedTab extends Tab {
  closedAt: number
}

/** The window's own row — no session owns these tabs. */
export const WINDOW_OWNER = ''

const SETTINGS_PATH = '/app/settings'
const KANBAN_SETTINGS_RE = /^\/app\/kanban\/([^/]+)\/settings\/?$/
const PROJECT_SETTINGS_RE = /^\/app\/[^/]+\/projects\/([^/]+)\/settings\/?$/

/** The board a kanban-settings URL names — the workspace-scoped project shape or the legacy kanban shape. */
export function kanbanSettingsItemId(path: string): string {
  const match = KANBAN_SETTINGS_RE.exec(path) ?? PROJECT_SETTINGS_RE.exec(path)
  return match?.[1] ?? ''
}

/** Views that are full-surface overlays over whatever was there before (`AppLayout.vue` mounts them `absolute inset-0 z-10` with their own Back button). */
const OVERLAY_VIEWS = ['gitfile', 'skill']

/** The read-only file viewer. */
export const CODE_EDITOR_VIEW = 'code-editor'

/** `?mode=diff` on a code-editor target is the same file's changes, as its own tab. */
export const DIFF_MODE = 'diff'

/** `ChatsList` emits this as an event flag, not as a view. */
const NON_VIEW = ['delete-chat']

/** Order-sensitive comparison of two already-normalized query objects. */
function sameNormalized(left: TabQuery, right: TabQuery): boolean {
  const leftKeys = Object.keys(left)
  if (leftKeys.length !== Object.keys(right).length) return false
  for (const key of leftKeys) {
    if (left[key] !== right[key]) return false
  }
  return true
}

/** Same target? */
export function sameTabTarget(
  a: Record<string, unknown> | null | undefined,
  b: Record<string, unknown> | null | undefined,
): boolean {
  return sameNormalized(stripTabParam(a ?? {}), stripTabParam(b ?? {}))
}

/** Same URL? */
export function sameRouteQuery(
  a: Record<string, unknown> | null | undefined,
  b: Record<string, unknown> | null | undefined,
): boolean {
  return sameNormalized(normalizeQuery(a, true), normalizeQuery(b, true))
}

/** The URL contract is flat strings. */
export function stripTabParam(query: Record<string, unknown> | null | undefined): TabQuery {
  return normalizeQuery(query, false)
}

function normalizeQuery(
  query: Record<string, unknown> | null | undefined,
  keepTab: boolean,
): TabQuery {
  const out: TabQuery = {}
  if (!query) return out
  for (const [key, value] of Object.entries(query)) {
    if (!keepTab && key === 'tab') continue
    if (value === null || value === undefined) continue
    let text = ''
    if (typeof value === 'string') text = value
    else if (typeof value === 'number' || typeof value === 'boolean') text = String(value)
    else continue
    if (text === '') continue
    out[key] = text
  }
  return out
}

/** The query to navigate to for `tab`, i.e. its target plus the tab's name. */
export function withTabParam(
  query: Record<string, unknown> | null | undefined,
  tabId: string,
): TabQuery {
  const out = stripTabParam(query)
  if (tabId) out.tab = tabId
  return out
}

// Dedupe identity.
export function isDiffQuery(query: Record<string, unknown> | null | undefined): boolean {
  return stripTabParam(query).mode === DIFF_MODE
}

/** A file's key: its path resolved against the opening cwd and normalised — one file, one key. */
export function fileTabKey(file: string, cwd = ''): string {
  return `file:${resolveTabPath(file, cwd)}`
}

/** The same file's changes, as its own tab — one tab of each kind per file. */
export function diffTabKey(file: string, cwd = ''): string {
  return `diff:${resolveTabPath(file, cwd)}`
}

/** Targets the app navigates to by PATH: `/app/{ws}/chat/{sid}` is a session with no `view`. */
export function pathTarget(path: string): { owner: string; key: string; kind: TabKind } | null {
  const parsed = parseAppPath(path)
  if (parsed.kind === 'chat') {
    return { owner: parsed.sessionId, key: `chat:${parsed.sessionId}`, kind: 'chat' }
  }
  if (parsed.kind === 'projectChat') {
    return { owner: parsed.chatTaskId, key: `chat:${parsed.chatTaskId}`, kind: 'chat' }
  }
  if (parsed.kind === 'projectSettings') {
    return { owner: '', key: `ks:${parsed.projectId}`, kind: 'kanban-settings' }
  }
  // A document is a page picked from the rail, not an artifact of a session: it belongs to the window's own row, and its id is what makes it a tab of its own …
  if (parsed.kind === 'doc') {
    return { owner: '', key: `doc:${parsed.documentId}`, kind: 'document' }
  }
  return null
}

/** The owner (session id) a target belongs to, or `''` for the window's own row. */
export function ownerOfTarget(
  path: string,
  query: Record<string, unknown> | null | undefined,
): string {
  const q = stripTabParam(query)
  const view = q.view ?? ''
  if (view === 'chat') return q.session || pathTarget(path)?.owner || ''
  if (view === 'task') return q.task || q.session || ''
  if (view === CODE_EDITOR_VIEW) return q.session || pathTarget(path)?.owner || ''
  if (view === 'workspace') return parseItemIdWithChat(q.itemId ?? '').chatTaskId || ''
  // No `view` at all: a path-form destination (`/app/{ws}/chat/{sid}`) still names a session.
  if (!view) return pathTarget(path)?.owner ?? ''
  return ''
}

/** Whether this target has an identity a tab can be named after: an ARTEFACT (a file, its diff), a session, a settings page, or a document page. */
export function hasTabIdentity(
  path: string,
  query: Record<string, unknown> | null | undefined,
): boolean {
  const view = stripTabParam(query).view ?? ''
  if (view === CODE_EDITOR_VIEW) return true
  if (kanbanSettingsItemId(path)) return true
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return true
  // A document names itself by its id, so it is a tab of its own — not a second `home`.
  if (parseAppPath(path).kind === 'doc') return true
  if (view !== '') return false
  return path === '/app' || path === '/app/'
}

/** The owner of a file target, preferring the tab's own record. */
export function ownerOf(tab: Tab): string {
  return tab.owner ?? ownerOfTarget(tab.path, tab.query)
}

export function tabKeyOf(
  path: string,
  query: Record<string, unknown> | null | undefined,
  itemType?: string | null,
): string {
  const q = stripTabParam(query)
  if ((q.view ?? '') === CODE_EDITOR_VIEW) {
    const file = q.file ?? ''
    if (!file) return 'file:'
    return isDiffQuery(q) ? diffTabKey(file, q.cwd ?? '') : fileTabKey(file, q.cwd ?? '')
  }
  const kanbanSettings = kanbanSettingsItemId(path)
  if (kanbanSettings) return `ks:${kanbanSettings}`
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return 'settings'
  const byPath = pathTarget(path)
  // Any path target names itself — a session by its id, a document by its id.
  if (byPath) return byPath.key

  const view = q.view || 'chat'
  if (view === 'chat') return q.session ? `chat:${q.session}` : 'home'
  if (view === 'task') return q.task ? `chat:${q.task}` : 'home'
  if (view === 'workspace') {
    const parsed = parseItemIdWithChat(q.itemId ?? '')
    const parts = ['ws', q.workspaceId ?? '', parsed.itemId]
    if (q.pageId) parts.push(q.pageId)
    // A task chat is its own session, and WHERE it renders decides whether it gets its own tab.
    if (parsed.chatTaskId && !taskChatRendersInItemTab(itemType)) {
      parts.push(`chat:${parsed.chatTaskId}`)
    }
    return parts.join(':')
  }
  return `view:${view}`
}

/** Item types whose task chat renders as a dialog *inside* the item's view (`DesignChatDialog`) — those items keep ONE tab no matter how many chats you open. */
const DIALOG_ITEM_TYPES = ['design', 'kanban-settings']

export function taskChatRendersInItemTab(itemType?: string | null): boolean {
  return typeof itemType === 'string' && DIALOG_ITEM_TYPES.includes(itemType)
}

/** The identities the same URL can have: the canonical one, plus the readings a tab created before its target was resolved still carries — the opposite item type … */
export function tabKeyVariants(
  path: string,
  query: Record<string, unknown> | null | undefined,
  itemType?: string | null,
): string[] {
  const plain = stripTabParam(query)
  if ((plain.view ?? '') === CODE_EDITOR_VIEW) {
    return fileKeyVariants(String(plain.file ?? ''), String(plain.cwd ?? ''), isDiffQuery(plain))
  }
  const canonical = tabKeyOf(path, query, itemType)
  if (!taskChatRendersInItemTab(itemType)) return [canonical]
  const other = tabKeyOf(path, query, 'agent')
  return canonical === other ? [canonical] : [canonical, other]
}

/** `Ctrl/Cmd+click` or a middle click means "open this in a background tab" — the gesture users already have in their fingers from a browser. */
export function isBackgroundOpenEvent(event: {
  ctrlKey?: boolean
  metaKey?: boolean
  button?: number
}): boolean {
  return event.ctrlKey === true || event.metaKey === true || event.button === 1
}

/** `false` means: leave the URL alone and render exactly as before. */
export function shouldTabify(
  path: string,
  query: Record<string, unknown> | null | undefined,
): boolean {
  const view = stripTabParam(query).view ?? ''
  if (OVERLAY_VIEWS.includes(view)) return false
  if (NON_VIEW.includes(view)) return false
  return true
}

export function kindOf(
  path: string,
  query: Record<string, unknown> | null | undefined,
  itemType?: string | null,
): TabKind {
  if (kanbanSettingsItemId(path)) return 'kanban-settings'
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return 'settings'
  const q = stripTabParam(query)
  const view = q.view || 'chat'
  if (view === CODE_EDITOR_VIEW) return isDiffQuery(q) ? 'diff' : 'file'
  const byPath = pathTarget(path)
  if (byPath) return byPath.kind
  if (view === 'chat') return q.session ? 'chat' : 'home'
  if (view === 'task') return q.task ? 'chat' : 'home'
  if (view === 'workspace') {
    // A task chat renders as its own view (its own session) unless the item shows it as a dialog.
    const chatTaskId = parseItemIdWithChat(q.itemId ?? '').chatTaskId
    if (chatTaskId && !taskChatRendersInItemTab(itemType)) return 'chat'
    return 'workspace'
  }
  return 'other'
}

/** Used until a live title (store or SSE) is known. */
export function fallbackTitle(kind: TabKind): string {
  switch (kind) {
    case 'home':
      return 'Pabrik'
    case 'chat':
      return 'Chat'
    case 'workspace':
      return 'Workspace'
    case 'kanban-settings':
      return 'Kanban settings'
    case 'settings':
      return 'Settings'
    case 'document':
      return 'Document'
    case 'file':
      return 'File'
    case 'diff':
      return 'Diff'
    default:
      return 'Tab'
  }
}

/** The label a tab wears before anything better is known. A file names itself. */
export function titleForTarget(
  kind: TabKind,
  query: Record<string, unknown> | null | undefined,
): string {
  if (kind === 'file' || kind === 'diff') {
    const file = stripTabParam(query).file ?? ''
    const name = file.split('/').pop() || ''
    if (name) return name
  }
  return fallbackTitle(kind)
}

/** Legacy kanban-settings deep links used `?tab=<section>` for the inner Columns/Agent switch (`columns|agent`, plus the pre-unified `tools|knowledge|memories`). */
const KANBAN_SETTINGS_LEGACY_TABS = new Set(['columns', 'agent', 'tools', 'knowledge', 'memories'])

export function migrateLegacySettingsTab(
  path: string,
  query: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
  if (!kanbanSettingsItemId(path)) return query ?? {}
  const q: Record<string, unknown> = { ...query }
  const rawSection = q.section
  const section = Array.isArray(rawSection) ? rawSection[0] : rawSection
  if (typeof section === 'string' && section !== '') return q
  const rawTab = q.tab
  const tab = Array.isArray(rawTab) ? rawTab[0] : rawTab
  if (typeof tab !== 'string' || !KANBAN_SETTINGS_LEGACY_TABS.has(tab)) return q
  const mapped = tab === 'tools' || tab === 'knowledge' || tab === 'memories' ? 'agent' : tab
  if (mapped === 'columns') {
    // Default section — keep the URL clean (the view strips it too).
    delete q.section
  } else {
    q.section = mapped
  }
  delete q.tab
  return q
}

let idSequence = 0

/** Unique per creation; the counter keeps two same-millisecond tabs apart. */
export function newTabId(): string {
  idSequence += 1
  return `tab_${Date.now().toString(36)}${idSequence.toString(36)}${Math.random().toString(36).slice(2, 6)}`
}

/** The "new tab page": the chats list. */
export function homeTab(): Tab {
  return {
    id: newTabId(),
    key: 'home',
    kind: 'home',
    title: fallbackTitle('home'),
    path: '/app',
    query: { view: 'chat' },
    createdAt: Date.now(),
  }
}
