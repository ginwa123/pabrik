/** How a window's tab list is written to storage and read back. Split from `tabTarget` (identity)
 * so neither file has to carry the other's weight. */
import {
  fallbackTitle,
  homeTab,
  kindOf,
  ownerOf,
  ownerOfTarget,
  stripTabParam,
  tabKeyOf,
  type ClosedTab,
  type Tab,
  type TabKind,
  type TabQuery,
} from './tabTarget'

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
    'document',
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
