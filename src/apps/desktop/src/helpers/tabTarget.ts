/** Pure helpers for browser-style tabs. */
import { parseAppPath } from './appUrl'
import { fileKeyVariants, resolveTabPath } from './tabPath'
import { parseItemIdWithChat } from './buildItemIdWithChat'

export type TabQuery = Record<string, string>

/**  * Display hint only — drives the glyph and the close tooltip. It is deliberately coarse: a pure
 * function cannot know a workspace item's `item_type`, and a wrong icon must never affect
 * behaviour. */
export type TabKind =
  | 'home'
  | 'chat'
  | 'workspace'
  | 'kanban-settings'
  | 'settings'
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
  /**    * The session this tab was opened in. A strip is `tabs.filter(t => t.owner === owner)`, so two
   * sessions never share one row. `''` (or absent) is the window's own row: the destinations picked
   * from the rail — settings, a board, a document — belong to the window, not to a session. */
  owner?: string
  /**    * The session's own tab: always first in its row and never closable, so closing the last file
   * still leaves the session on screen. */
  pinned?: boolean
  /**    * True when the tab's identity was decided without knowing the workspace item's type (a cold-boot
   * deep link, before the tree loaded). Such a tab may be adopted — i.e. re-keyed — once the real
   * type arrives, so the strip does not end up with two tabs for one target. */
  provisional?: boolean
}

export interface ClosedTab extends Tab {
  closedAt: number
}

export interface PersistedTabs {
  active: string
  tabs: Tab[]
  closed: ClosedTab[]
}

/**    * What a window writes to storage: one list per owner, so a row is a key rather than a filter the
 * payload has to be searched for. The store keeps the tabs flat in memory (`stripOf` filters), so this
 * shape exists only on the way in and out. */
export interface PersistedStrips {
  v: number
  strips: Record<string, Tab[]>
  active: Record<string, string>
  closed: Record<string, ClosedTab[]>
}

/** Group a flat list into the per-owner payload, in the order the rows first appear. */
export function groupPayload(tabs: Tab[], active: string, closed: ClosedTab[]): PersistedStrips {
  const strips: Record<string, Tab[]> = {}
  const activeByOwner: Record<string, string> = {}
  for (const tab of tabs) {
    const owner = ownerOf(tab)
    if (!strips[owner]) strips[owner] = []
    ;(strips[owner] as Tab[]).push(tab)
    if (tab.id === active) activeByOwner[owner] = tab.id
  }
  // A row with no active tab of its own points at its first tab, so every row restores to something.
  for (const [owner, row] of Object.entries(strips)) {
    if (!activeByOwner[owner] && row[0]) activeByOwner[owner] = row[0].id
  }
  const closedByOwner: Record<string, ClosedTab[]> = {}
  for (const tab of closed) {
    const owner = ownerOf(tab)
    if (!closedByOwner[owner]) closedByOwner[owner] = []
    ;(closedByOwner[owner] as ClosedTab[]).push(tab)
  }
  return { v: TABS_VERSION, strips, active: activeByOwner, closed: closedByOwner }
}

/** Upper bounds so a long-lived window cannot grow storage without limit. */
export const MAX_TABS = 50
export const MAX_CLOSED = 10

/** Storage format version; anything else is ignored (fresh start). */
export const TABS_VERSION = 2

/** Payloads written before ownership existed. They still parse (see `parseTabList`). */
export const TABS_VERSION_LEGACY = 1

/** The window's own row — no session owns these tabs. */
export const WINDOW_OWNER = ''

const SETTINGS_PATH = '/app/settings'
const KANBAN_SETTINGS_RE = /^\/app\/kanban\/([^/]+)\/settings\/?$/
const PROJECT_SETTINGS_RE = /^\/app\/[^/]+\/projects\/([^/]+)\/settings\/?$/

/** The board a kanban-settings URL names — the workspace-scoped project shape or the legacy
 * kanban shape. Empty when the path is not a settings page. */
export function kanbanSettingsItemId(path: string): string {
  const match = KANBAN_SETTINGS_RE.exec(path) ?? PROJECT_SETTINGS_RE.exec(path)
  return match?.[1] ?? ''
}

/**  * Views that are full-surface overlays over whatever was there before (`AppLayout.vue` mounts them
 * `absolute inset-0 z-10` with their own Back button). They are not destinations, so they never
 * become tabs — the strip stays behind them untouched. */
const OVERLAY_VIEWS = ['gitfile', 'skill']

/** The read-only file viewer. It is a tab target now, not an overlay: a file opened inside a session
 * keeps its place in that session's row. */
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

/** Same target? Ignores `tab`, because the tab's stored target must not
 * change just because it became active. */
export function sameTabTarget(
  a: Record<string, unknown> | null | undefined,
  b: Record<string, unknown> | null | undefined,
): boolean {
  return sameNormalized(stripTabParam(a ?? {}), stripTabParam(b ?? {}))
}

/** Same URL? Includes `tab` — used to decide whether a navigation is
 * actually needed, so naming a different tab IS a difference. */
export function sameRouteQuery(
  a: Record<string, unknown> | null | undefined,
  b: Record<string, unknown> | null | undefined,
): boolean {
  return sameNormalized(normalizeQuery(a, true), normalizeQuery(b, true))
}

/**  * The URL contract is flat strings. Values that are arrays/objects (or empty) are dropped so two
 * URLs that mean the same thing produce the same key. */
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

/** Dedupe identity. `tab` and `sorts` are excluded: the first names a tab rather than a target, the
 * second is per-column kanban UI state that changes without the user going anywhere. */
/** `?mode=diff` marks a code-editor target as that file's changes. */
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

/** Whether this target has an identity a tab can be named after: an ARTEFACT (a file, its diff), not
 * a session and not a document page. */
export function hasTabIdentity(
  path: string,
  query: Record<string, unknown> | null | undefined,
): boolean {
  const view = stripTabParam(query).view ?? ''
  if (view === CODE_EDITOR_VIEW) return true
  if (kanbanSettingsItemId(path)) return true
  if (path === SETTINGS_PATH || path === `${SETTINGS_PATH}/`) return true
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
  if (byPath && byPath.owner) return byPath.key

  const view = q.view || 'chat'
  if (view === 'chat') return q.session ? `chat:${q.session}` : 'home'
  if (view === 'task') return q.task ? `chat:${q.task}` : 'home'
  if (view === 'workspace') {
    const parsed = parseItemIdWithChat(q.itemId ?? '')
    const parts = ['ws', q.workspaceId ?? '', parsed.itemId]
    if (q.pageId) parts.push(q.pageId)
    // A task chat is its own session, and WHERE it renders decides whether it gets its own tab. A
    // kanban card click opens the chat as its own view, so it gets its own tab; design opens it as
    // a dialog INSIDE the canvas view, so that item keeps one tab total.
    if (parsed.chatTaskId && !taskChatRendersInItemTab(itemType)) {
      parts.push(`chat:${parsed.chatTaskId}`)
    }
    return parts.join(':')
  }
  return `view:${view}`
}

/** Item types whose task chat renders as a dialog *inside* the item's view (`DesignChatDialog`) —
 * those items keep ONE tab no matter how many chats you open. Every other type — kanban included —
 * renders the chat as its own view, so each chat is a tab of its own. */
const DIALOG_ITEM_TYPES = ['design', 'kanban-settings']

export function taskChatRendersInItemTab(itemType?: string | null): boolean {
  return typeof itemType === 'string' && DIALOG_ITEM_TYPES.includes(itemType)
}

/** The identities the same URL can have: the canonical one, plus the readings a tab created before
 * its target was resolved still carries — the opposite item type, or a file's unresolved spelling. */
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

/** `Ctrl/Cmd+click` or a middle click means "open this in a background
 * tab" — the gesture users already have in their fingers from a browser. */
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

/** Legacy kanban-settings deep links used `?tab=<section>` for the inner Columns/Agent switch
 * (`columns|agent`, plus the pre-unified `tools|knowledge|memories`). */
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

/** The "new tab page": the chats list. Reused both for the initial tab
 * and whenever the last tab is closed, so the strip is never empty. */
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

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function asKind(value: unknown, path: string, query: TabQuery): TabKind {
  const allowed: TabKind[] = [
    'home',
    'chat',
    'workspace',
    'kanban-settings',
    'settings',
    'file',
    'diff',
    'other',
  ]
  if (typeof value === 'string' && (allowed as string[]).includes(value)) return value as TabKind
  return kindOf(path, query)
}

function coerceTab(value: unknown): Tab | null {
  const entry = asRecord(value)
  if (!entry) return null
  const id = asString(entry.id)
  if (!id) return null
  const query = stripTabParam(asRecord(entry.query) ?? {})
  const path = asString(entry.path) || '/app'
  const title = asString(entry.title) || fallbackTitle(kindOf(path, query))
  const createdAt =
    typeof entry.createdAt === 'number' && Number.isFinite(entry.createdAt) ? entry.createdAt : 0
  const owner = asString(entry.owner) || ownerOfTarget(path, query)
  const pinned = entry.pinned === true
  return {
    id,
    key: asString(entry.key) || tabKeyOf(path, query),
    kind: asKind(entry.kind, path, query),
    title,
    path,
    query,
    createdAt,
    ...(owner ? { owner } : {}),
    ...(pinned ? { pinned: true } : {}),
    ...(entry.provisional === true ? { provisional: true } : {}),
  }
}

function coerceClosedTab(value: unknown): ClosedTab | null {
  const tab = coerceTab(value)
  if (!tab) return null
  const entry = asRecord(value)
  const raw = entry ? entry.closedAt : 0
  const closedAt = typeof raw === 'number' && Number.isFinite(raw) ? raw : 0
  return { ...tab, closedAt }
}

function freshList(): PersistedTabs {
  const tab = homeTab()
  return { active: tab.id, tabs: [tab], closed: [] }
}

function parseStrips(root: Record<string, unknown>): PersistedTabs {
  const strips = asRecord(root.strips)
  if (!strips) return freshList()
  const tabs: Tab[] = []
  const seenIds = new Set<string>()
  for (const [owner, row] of Object.entries(strips)) {
    if (!Array.isArray(row)) continue
    for (const value of row) {
      const tab = coerceTab(value)
      if (!tab || seenIds.has(tab.id)) continue
      seenIds.add(tab.id)
      // The row a tab was filed under is authoritative: it is what made it two strips.
      tabs.push({ ...tab, ...(owner ? { owner } : {}) })
    }
  }
  if (tabs.length === 0) return freshList()

  const closed: ClosedTab[] = []
  const closedByOwner = asRecord(root.closed)
  if (closedByOwner) {
    for (const row of Object.values(closedByOwner)) {
      if (!Array.isArray(row)) continue
      for (const value of row) {
        const tab = coerceClosedTab(value)
        if (tab) closed.push(tab)
      }
    }
  }

  const activeByOwner = asRecord(root.active)
  const firstOwnerActive = activeByOwner
    ? Object.values(activeByOwner).find((value): value is string => typeof value === 'string')
    : ''
  const active =
    firstOwnerActive && tabs.some((tab) => tab.id === firstOwnerActive)
      ? firstOwnerActive
      : (tabs[0]?.id ?? '')
  return { active, tabs, closed: closed.slice(0, MAX_CLOSED) }
}

/** Total: any input at all yields a usable list. A corrupt, older-version
 * or hand-edited value must never throw at boot — it starts over. */
export function parseTabList(raw: string | null | undefined): PersistedTabs {
  if (!raw) return freshList()
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return freshList()
  }
  const root = asRecord(parsed)
  if (!root) return freshList()
  const version = typeof root.v === 'number' ? root.v : 0
  if (version !== TABS_VERSION && version !== TABS_VERSION_LEGACY) return freshList()
  // v2 writes one list per owner; v1 wrote one flat list. Both parse, and the flat list is what the
  // store works with.
  if (root.strips) return parseStrips(root)
  if (!Array.isArray(root.tabs)) return freshList()

  const tabs: Tab[] = []
  const seenIds = new Set<string>()
  const seenKeys = new Set<string>()
  for (const raw of root.tabs) {
    const tab = coerceTab(raw)
    if (!tab) continue
    if (seenIds.has(tab.id) || seenKeys.has(tab.key)) continue
    seenIds.add(tab.id)
    seenKeys.add(tab.key)
    tabs.push(tab)
  }
  if (tabs.length === 0) return freshList()

  const closed: ClosedTab[] = []
  if (Array.isArray(root.closed)) {
    for (const raw of root.closed) {
      const tab = coerceClosedTab(raw)
      if (tab) closed.push(tab)
    }
  }

  const first = tabs[0]
  const activeId = asString(root.active)
  const active = first && tabs.some((tab) => tab.id === activeId) ? activeId : first ? first.id : ''
  return { active, tabs, closed: closed.slice(0, MAX_CLOSED) }
}
