/** The tab list. */
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

import { createFunnel } from './tabFunnel'
import {
  fallbackTitle,
  homeTab,
  kindOf,
  ownerOf,
  ownerOfTarget,
  newTabId,
  sameTabTarget,
  tabKeyOf,
  tabKeyVariants,
  titleForTarget,
  WINDOW_OWNER,
  type ClosedTab,
  type Tab,
  type TabKind,
  type TabQuery,
} from '../helpers/tabTarget'
import { MAX_CLOSED, MAX_TABS, groupPayload, parseTabList } from '../helpers/tabPersistence'
import { getWindowId } from '../helpers/windowId'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'
import { dropDraft, readDraft, writeDraft } from './tabDrafts'
import { createTitles } from './tabsTitles'
import {
  boundedClosed,
  keyIn,
  lastClosedOf,
  rowOf,
  stepWithin,
  successorOf,
  withAnchor,
} from './tabsRows'
import {
  ENABLED_KEY,
  listKey,
  readEnabled,
  readStorage,
  removeStorage,
  tabQueryOf,
  writeStorage,
} from './tabsStorage'

export interface OpenTabInput {
  path?: string
  query: Record<string, unknown>
  title?: string
  kind?: TabKind
  /** The session that owns the row this tab lands in. Absent: derived from the target. */
  owner?: string
  /** The workspace item's type, when the caller knows it — decides the tab identity. */
  itemType?: string | null
}

export interface SyncResult {
  /** The navigation AppLayout should apply. */
  path: string
  query: TabQuery
  /** True when the current URL differs from `path`/`query` (apply with replace). */
  changed: boolean
}

export const useTabsStore = defineStore('tabs', () => {
  const windowId = ref(getWindowId())
  const restored = parseTabList(readStorage(listKey(windowId.value)))

  const tabs = ref<Tab[]>(restored.tabs)
  const activeTabId = ref<string>(restored.active)
  const closedStack = ref<ClosedTab[]>(restored.closed)
  const enabled = ref<boolean>(readEnabled())

  /** Unsent composer text, keyed by draft key (usually `chat:<sessionId>`). */
  const drafts = ref<Record<string, string>>({})

  const activeTab = computed<Tab | null>(() => {
    const found = tabs.value.find((tab) => tab.id === activeTabId.value)
    return found ?? tabs.value[0] ?? null
  })

  /** The row a session owns: the whole design in one line. */
  function stripOf(owner: string): Tab[] {
    return rowOf(tabs.value, owner)
  }

  /** The owner of the row that is on screen right now. */
  const activeOwner = computed(() => (activeTab.value ? ownerOf(activeTab.value) : WINDOW_OWNER))
  const activeStrip = computed(() => stripOf(activeOwner.value))

  /** A row never lacks its anchor, even when the session was entered through a file link. */
  function ensureAnchor(owner: string): void {
    const next = withAnchor(tabs.value, owner)
    if (!next) return
    tabs.value = next
    persist()
  }

  /**    * The session's row, created by the surface that shows it: the anchor first, and focused when it
   * is new. ChatView calls this on mount, so a deep link into a file still has a way back. */
  function ensureRow(owner: string): void {
    if (!owner) return
    const before = stripOf(owner).length
    ensureAnchor(owner)
    const anchor = stripOf(owner).find((tab) => tab.pinned)
    if (anchor && (stripOf(owner).length !== before || !activeTabId.value)) activate(anchor.id)
  }

  function byKeyIn(owner: string, key: string): Tab | null {
    return keyIn(tabs.value, owner, key)
  }

  const tabCount = computed(() => tabs.value.length)
  const canReopenLastClosed = computed(() =>
    closedStack.value.some((tab) => ownerOf(tab) === activeOwner.value),
  )

  let lastSerialized = ''

  function persist(): void {
    // One list per owner: the payload mirrors the rows, the store keeps them flat.
    const payload = JSON.stringify(groupPayload(tabs.value, activeTabId.value, closedStack.value))
    if (payload === lastSerialized) return
    lastSerialized = payload
    writeStorage(listKey(windowId.value), payload)
  }

  function persistClosed(): void {
    closedStack.value = boundedClosed(closedStack.value, MAX_CLOSED)
  }

  function byId(id: string): Tab | null {
    return tabs.value.find((tab) => tab.id === id) ?? null
  }

  function byKey(key: string): Tab | null {
    return tabs.value.find((tab) => tab.key === key) ?? null
  }

  /** Keep every row bounded without ever evicting the tab the user is on. */
  function enforceLimit(owner?: string): void {
    const scope = owner ?? activeOwner.value
    while (stripOf(scope).length > MAX_TABS) {
      const victim = stripOf(scope).find((tab) => tab.id !== activeTabId.value && !tab.pinned)
      if (!victim) return
      const victimId = victim.id
      tabs.value = tabs.value.filter((tab) => tab.id !== victimId)
    }
  }

  /** A new tab lands beside the active one when they share a row, else at the end. */
  function insertAfterActive(tab: Tab): void {
    const index = tabs.value.findIndex((candidate) => candidate.id === activeTabId.value)
    const sameRow = index !== -1 && ownerOf(tabs.value[index] as Tab) === ownerOf(tab)
    if (!sameRow) {
      tabs.value = [...tabs.value, tab]
      return
    }
    const next = [...tabs.value]
    next.splice(index + 1, 0, tab)
    tabs.value = next
  }

  function createTab(input: OpenTabInput): Tab {
    const path = input.path || '/app'
    const query = tabQueryOf(input.query)
    const kind = input.kind ?? kindOf(path, query, input.itemType)
    const hasChatSuffix = !!parseItemIdWithChat(query.itemId ?? '').chatTaskId
    const owner = input.owner ?? ownerOfTarget(path, query)
    return {
      id: newTabId(),
      key: tabKeyOf(path, query, input.itemType),
      kind,
      title: input.title || titleForTarget(kind, query),
      path,
      query,
      createdAt: Date.now(),
      ...(owner ? { owner } : {}),
      // A session's own tab is the row's anchor: first, and never closable.
      ...(owner && kind === 'chat' ? { pinned: true } : {}),
      // Identity decided without knowing the item type (cold boot): the tab may
      // be adopted once the type arrives, instead of being duplicated.
      ...(hasChatSuffix && !input.itemType ? { provisional: true } : {}),
    }
  }

  /**    * Re-key a tab in place. Used when the same target turns out to have a different canonical
   * identity than the one it was created with (the item type was not known yet, or a session id was
   * renamed). */
  function rekeyTab(id: string, key: string, query: TabQuery): void {
    let touched = false
    tabs.value = tabs.value.map((tab) => {
      if (tab.id !== id || tab.key === key) return tab
      touched = true
      const { provisional: _provisional, ...rest } = tab
      void _provisional
      return { ...rest, key, query }
    })
    if (touched) persist()
  }

  /** Find the tab this target already has **in this row**: the canonical key first, then the other
   * readings of the same URL. A file's unresolved spelling is provably the same file; a workspace
   * URL's other reading is only adopted by a tab that is still provisional. */
  function findExisting(variants: string[], owner: string): Tab | null {
    const canonical = variants[0]
    if (canonical) {
      const exact = byKeyIn(owner, canonical)
      if (exact) return exact
    }
    for (const variant of variants.slice(1)) {
      const candidate = byKeyIn(owner, variant)
      if (!candidate) continue
      if (candidate.provisional || candidate.kind === 'file' || candidate.kind === 'diff') {
        return candidate
      }
    }
    return null
  }

  function refreshFromInput(tab: Tab, input: OpenTabInput): void {
    const path = input.path || tab.path
    const query = tabQueryOf(input.query)
    const patch: Partial<Tab> = {}
    if (!sameTabTarget(tab.query, query)) patch.query = query
    if (path !== tab.path) patch.path = path
    if (input.title && input.title !== tab.title) patch.title = input.title
    if (input.kind && input.kind !== tab.kind) patch.kind = input.kind
    if (Object.keys(patch).length === 0) return
    tabs.value = tabs.value.map((candidate) =>
      candidate.id === tab.id ? { ...candidate, ...patch } : candidate,
    )
  }

  /** Create or focus the tab for `input`, and make it active. */
  function open(input: OpenTabInput): Tab {
    const path = input.path || '/app'
    const query = tabQueryOf(input.query)
    const variants = tabKeyVariants(path, query, input.itemType)
    const canonical = variants[0] ?? ''
    const owner = input.owner ?? ownerOfTarget(path, query)
    const existing = findExisting(variants, owner)
    if (existing) {
      refreshFromInput(existing, input)
      rekeyTab(existing.id, canonical, query)
      activeTabId.value = existing.id
      persist()
      return byId(existing.id) ?? existing
    }
    const tab = createTab(input)
    insertAfterActive(tab)
    activeTabId.value = tab.id
    enforceLimit(ownerOf(tab))
    persist()
    return tab
  }

  /** Open (or focus) a target **inside one session's row**. The owner is explicit so a caller can
   * never accidentally drop an artifact into the window's row. */
  function openInSession(owner: string, input: Omit<OpenTabInput, 'owner'>): Tab {
    return open({ ...input, owner })
  }

  /** Open without leaving the current tab (`Ctrl/Cmd+click`). The URL is
   * deliberately untouched — the target is only remembered. */
  function openInBackground(input: OpenTabInput): Tab {
    const path = input.path || '/app'
    const query = tabQueryOf(input.query)
    const variants = tabKeyVariants(path, query, input.itemType)
    const canonical = variants[0] ?? ''
    const owner = input.owner ?? ownerOfTarget(path, query)
    const existing = findExisting(variants, owner)
    if (existing) {
      rekeyTab(existing.id, canonical, query)
      return existing
    }
    const tab = createTab(input)
    tabs.value = [...tabs.value, tab]
    enforceLimit(ownerOf(tab))
    persist()
    return tab
  }

  function activate(id: string): boolean {
    if (!byId(id)) return false
    if (activeTabId.value !== id) {
      activeTabId.value = id
      persist()
    }
    return true
  }

  function activateIndex(index: number): boolean {
    const tab = tabs.value[index]
    if (!tab) return false
    return activate(tab.id)
  }

  /**    * Close `id` and report which tab should be activated next (the right neighbour, else the left —
   * the browser rule). The caller decides whether to navigate; `null` means the id was unknown. */
  function close(id: string): Tab | null {
    const tab = byId(id)
    if (!tab) return null
    // The session's own tab is the row's anchor: a tab gesture cannot end the session.
    if (tab.pinned) return byId(activeTabId.value) ?? tab

    const owner = ownerOf(tab)
    const row = stripOf(owner)
    const remaining = tabs.value.filter((candidate) => candidate.id !== id)
    const remainingRow = row.filter((candidate) => candidate.id !== id)
    const successor = successorOf(row, id)
    const wasActive = activeTabId.value === id

    closedStack.value = [{ ...tab, closedAt: Date.now() }, ...closedStack.value]
    persistClosed()

    if (remainingRow.length === 0 && owner === WINDOW_OWNER) {
      const fresh = homeTab()
      tabs.value = [fresh, ...remaining]
      activeTabId.value = fresh.id
      persist()
      return fresh
    }

    tabs.value = remaining
    if (wasActive && successor) activeTabId.value = successor.id
    persist()
    return byId(activeTabId.value) ?? null
  }

  function closeOthers(id: string): void {
    const keep = byId(id) ?? activeTab.value
    if (!keep) return
    const owner = ownerOf(keep)
    // Other rows are untouched: "close others" is a gesture inside one strip.
    const dropped = stripOf(owner).filter((tab) => tab.id !== keep.id && !tab.pinned)
    const droppedIds = new Set(dropped.map((tab) => tab.id))
    tabs.value = tabs.value.filter((tab) => !droppedIds.has(tab.id))
    activeTabId.value = keep.id
    closedStack.value = [
      ...dropped
        .slice()
        .reverse()
        .map((tab) => ({ ...tab, closedAt: Date.now() })),
      ...closedStack.value,
    ]
    persistClosed()
    persist()
  }

  function closeToRight(id: string): void {
    const anchor = byId(id)
    if (!anchor) return
    const row = stripOf(ownerOf(anchor))
    const index = row.findIndex((tab) => tab.id === id)
    if (index === -1) return
    const dropped = row.slice(index + 1).filter((tab) => !tab.pinned)
    if (dropped.length === 0) return
    const droppedIds = new Set(dropped.map((tab) => tab.id))
    tabs.value = tabs.value.filter((tab) => !droppedIds.has(tab.id))
    closedStack.value = [
      ...dropped
        .slice()
        .reverse()
        .map((tab) => ({ ...tab, closedAt: Date.now() })),
      ...closedStack.value,
    ]
    persistClosed()
    if (!byId(activeTabId.value)) activeTabId.value = id
    persist()
  }

  function reorder(from: number, to: number): void {
    if (from === to) return
    const next = [...tabs.value]
    const [moved] = next.splice(from, 1)
    if (!moved) return
    const index = Math.max(0, Math.min(next.length, to))
    next.splice(index, 0, moved)
    tabs.value = next
    persist()
  }

  function neighbour(step: number): Tab | null {
    const tab = stepWithin(activeStrip.value, activeTabId.value, step)
    if (!tab) return null
    activate(tab.id)
    return tab
  }

  const next = () => neighbour(1)
  const prev = () => neighbour(-1)

  /** `Shift+Alt+Z` — put the most recently closed tab of this row back. */
  function reopenLastClosed(owner: string = activeOwner.value): Tab | null {
    const found = lastClosedOf(closedStack.value, owner)
    if (!found) return null
    const { entry } = found
    closedStack.value = found.rest
    const already = byKeyIn(owner, entry.key)
    if (already) {
      activeTabId.value = already.id
      persist()
      return already
    }
    const tab: Tab = {
      id: entry.id,
      key: entry.key,
      kind: entry.kind,
      title: entry.title,
      path: entry.path,
      query: entry.query,
      createdAt: entry.createdAt,
      ...(entry.owner ? { owner: entry.owner } : {}),
      ...(entry.pinned ? { pinned: true } : {}),
    }
    tabs.value = [...tabs.value, tab]
    activeTabId.value = tab.id
    persist()
    return tab
  }

  /**    * The funnel. Returns the navigation to apply for the current URL: create a tab, focus an
   * existing one, honour a `?tab=` that names exactly this target, or (when disabled / an overlay)
   * leave the target alone. */
  const syncFromTarget = createFunnel({
    enabled: () => enabled.value,
    byId,
    findExisting,
    refreshFromInput,
    rekeyTab,
    activate,
    activeId: () => activeTabId.value,
    ensureAnchor,
    open: (input) => open(input),
  })

  function setEnabled(value: boolean): void {
    enabled.value = value
    writeStorage(ENABLED_KEY, value ? 'true' : 'false')
  }

  /** `Shift+Alt+T`: back to the session's own tab — the row's anchor — never a new session. */
  function goHome(): Tab | null {
    const pinned = stripOf(activeOwner.value).find((tab) => tab.pinned)
    if (pinned) {
      activate(pinned.id)
      return byId(pinned.id) ?? pinned
    }
    return openHomeTab()
  }

  /** The `+` button and `Shift+Alt+T`: open (or focus) the chats-list tab. */
  function openHomeTab(): Tab {
    return open({
      path: '/app',
      query: { view: 'chat' },
      title: fallbackTitle('home'),
      kind: 'home',
    })
  }

  /**    * Live tab titles. The backend already announces renames on the `session` channel (`SessionEvent
   * { action, id, name }`), so a chat tab keeps up with the auto-rename-on-first-message cascade
   * without polling. Guarded because the bus is not installed until App.vue mounts. */
  const titles = createTitles({ tabs, activeTabId, persist, byKey })
  const { initTitleFeed, disposeTitleFeed, renameChatTab, setChatTitle, setTabTitle } = titles

  function getDraft(key: string): string {
    return readDraft(drafts.value, key)
  }

  function setDraft(key: string, text: string): void {
    const next = writeDraft(drafts.value, key, text)
    if (next) drafts.value = next
  }

  function clearDraft(key: string): void {
    const next = dropDraft(drafts.value, key)
    if (next) drafts.value = next
  }

  /** Forget everything this window knows (used by the "reset tabs" escape hatch). */
  function resetToHome(): Tab {
    const fresh = homeTab()
    tabs.value = [fresh]
    activeTabId.value = fresh.id
    closedStack.value = []
    removeStorage(listKey(windowId.value))
    persist()
    return fresh
  }

  return {
    // state
    windowId,
    tabs,
    activeTabId,
    closedStack,
    enabled,
    drafts,
    // computed
    activeTab,
    activeOwner,
    activeStrip,
    tabCount,
    canReopenLastClosed,
    // actions
    open,
    openInBackground,
    openInSession,
    activate,
    activateIndex,
    close,
    closeOthers,
    closeToRight,
    reorder,
    next,
    prev,
    reopenLastClosed,
    syncFromTarget,
    goHome,
    renameChatTab,
    setEnabled,
    openHomeTab,
    initTitleFeed,
    disposeTitleFeed,
    setChatTitle,
    setTabTitle,
    getDraft,
    setDraft,
    clearDraft,
    resetToHome,
    // helpers other components need
    stripOf,
    byKey,
    byKeyIn,
    ensureAnchor,
    ensureRow,
  }
})
