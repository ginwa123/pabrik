/**
 * The tab list.
 *
 * Design notes the reviewer needs (the full rationale lives in
 * docs/superpowers/plans/2026-09-13-tab-mode-like-a-browser.md):
 *
 *  * A tab stores a router target (`path` + `query`), so activating one
 *    is just a navigation — the render chain in AppLayout is untouched.
 *  * `syncFromTarget` is the single funnel: every navigation in the app
 *    (sidebar, chats list, dialog, deep link, Back) lands here, which is
 *    why no call site has to know the tab list exists. The store never
 *    imports the router — it returns the navigation to apply and lets
 *    AppLayout perform it.
 *  * Persistence is per window (`helpers/windowId.ts`) so a second app
 *    window gets its own strip, while a reload keeps this one.
 *  * Writes are synchronous but skipped when the serialized payload is
 *    unchanged. A debounce would risk dropping the last action on an
 *    immediate reload, and the payload is tiny.
 */
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

import {
  MAX_CLOSED,
  MAX_TABS,
  TABS_VERSION,
  fallbackTitle,
  homeTab,
  kindOf,
  migrateLegacySettingsTab,
  newTabId,
  parseTabList,
  sameRouteQuery,
  sameTabTarget,
  shouldTabify,
  stripTabParam,
  tabKeyOf,
  tabKeyVariants,
  withTabParam,
  type ClosedTab,
  type Tab,
  type TabKind,
  type TabQuery,
} from '../helpers/tabTarget'
import { getWindowId } from '../helpers/windowId'
import { userScopedKey } from '../helpers/userScope'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'
import { useSseBus } from '../helpers/sseBus'

const ENABLED_KEY = 'pabrik-tabs-enabled'
const LIST_PREFIX = 'pabrik-tabs:v1:'

export interface OpenTabInput {
  path?: string
  query: Record<string, unknown>
  title?: string
  kind?: TabKind
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

function listKey(windowId: string): string {
  return userScopedKey(`${LIST_PREFIX}${windowId}`)
}

function readStorage(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function writeStorage(key: string, value: string): void {
  try {
    localStorage.setItem(key, value)
  } catch {
    /* quota / private mode / no storage — the strip still works in memory */
  }
}

function removeStorage(key: string): void {
  try {
    localStorage.removeItem(key)
  } catch {
    /* see writeStorage */
  }
}

function readEnabled(): boolean {
  const raw = readStorage(ENABLED_KEY)
  // Tab mode defaults to OFF — users found the strip confusing.
  // Opt-in via Settings → General → "Browser-style tabs".
  return raw === null ? false : raw === 'true'
}

function tabQueryOf(query: Record<string, unknown>): TabQuery {
  return stripTabParam(query)
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

  const tabCount = computed(() => tabs.value.length)
  const canReopenLastClosed = computed(() => closedStack.value.length > 0)

  let lastSerialized = ''

  function persist(): void {
    const payload = JSON.stringify({
      v: TABS_VERSION,
      active: activeTabId.value,
      tabs: tabs.value,
      closed: closedStack.value,
    })
    if (payload === lastSerialized) return
    lastSerialized = payload
    writeStorage(listKey(windowId.value), payload)
  }

  function persistClosed(): void {
    if (closedStack.value.length > MAX_CLOSED) {
      closedStack.value = closedStack.value.slice(0, MAX_CLOSED)
    }
  }

  function byId(id: string): Tab | null {
    return tabs.value.find((tab) => tab.id === id) ?? null
  }

  function byKey(key: string): Tab | null {
    return tabs.value.find((tab) => tab.key === key) ?? null
  }

  /** Keep the list bounded without ever evicting the tab the user is on. */
  function enforceLimit(): void {
    while (tabs.value.length > MAX_TABS) {
      const victim = tabs.value.find((tab) => tab.id !== activeTabId.value)
      if (!victim) return
      tabs.value = tabs.value.filter((tab) => tab.id !== victim.id)
    }
  }

  function insertAfterActive(tab: Tab): void {
    const index = tabs.value.findIndex((candidate) => candidate.id === activeTabId.value)
    if (index === -1) {
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
    const kind = input.kind ?? kindOf(path, query)
    const hasChatSuffix = !!parseItemIdWithChat(query.itemId ?? '').chatTaskId
    return {
      id: newTabId(),
      key: tabKeyOf(path, query, input.itemType),
      kind,
      title: input.title || fallbackTitle(kind),
      path,
      query,
      createdAt: Date.now(),
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

  /** Find the tab this target already has: the canonical key first, then — only for a tab whose
   * identity was provisional — the other reading of the same URL. */
  /** Without the provisional guard, two legitimately distinct tabs (an item and one of its task
   * chats on a standalone item type) would be merged. */
  function findExisting(variants: string[]): Tab | null {
    const canonical = variants[0]
    if (canonical) {
      const exact = byKey(canonical)
      if (exact) return exact
    }
    for (const variant of variants.slice(1)) {
      const candidate = byKey(variant)
      if (candidate?.provisional) return candidate
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
    const existing = findExisting(variants)
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
    enforceLimit()
    persist()
    return tab
  }

  /** Open without leaving the current tab (`Ctrl/Cmd+click`). The URL is
   * deliberately untouched — the target is only remembered. */
  function openInBackground(input: OpenTabInput): Tab {
    const path = input.path || '/app'
    const query = tabQueryOf(input.query)
    const variants = tabKeyVariants(path, query, input.itemType)
    const canonical = variants[0] ?? ''
    const existing = findExisting(variants)
    if (existing) {
      rekeyTab(existing.id, canonical, query)
      return existing
    }
    const tab = createTab(input)
    tabs.value = [...tabs.value, tab]
    enforceLimit()
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
    const index = tabs.value.findIndex((tab) => tab.id === id)
    if (index === -1) return null
    const tab = tabs.value[index]
    if (!tab) return null
    const wasActive = activeTabId.value === id
    const remaining = tabs.value.filter((candidate) => candidate.id !== id)

    if (remaining.length === 0) {
      const fresh = homeTab()
      tabs.value = [fresh]
      activeTabId.value = fresh.id
      closedStack.value = [{ ...tab, closedAt: Date.now() }, ...closedStack.value]
      persistClosed()
      persist()
      return fresh
    }

    tabs.value = remaining
    closedStack.value = [{ ...tab, closedAt: Date.now() }, ...closedStack.value]
    persistClosed()
    if (wasActive) {
      const right = remaining[index]
      const left = remaining[index - 1]
      const successor = right ?? left
      if (successor) activeTabId.value = successor.id
    }
    persist()
    return byId(activeTabId.value) ?? null
  }

  function closeOthers(id: string): void {
    const keep = byId(id) ?? activeTab.value
    if (!keep) return
    const dropped = tabs.value.filter((tab) => tab.id !== keep.id)
    tabs.value = [keep]
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
    const index = tabs.value.findIndex((tab) => tab.id === id)
    if (index === -1) return
    const dropped = tabs.value.slice(index + 1)
    if (dropped.length === 0) return
    tabs.value = tabs.value.slice(0, index + 1)
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
    if (tabs.value.length === 0) return null
    const current = tabs.value.findIndex((tab) => tab.id === activeTabId.value)
    const size = tabs.value.length
    const base = current === -1 ? 0 : current
    const index = (((base + step) % size) + size) % size
    const tab = tabs.value[index]
    if (!tab) return null
    activate(tab.id)
    return tab
  }

  const next = () => neighbour(1)
  const prev = () => neighbour(-1)

  /** `Shift+Alt+Z` — put the most recently closed tab back. */
  function reopenLastClosed(): Tab | null {
    const entry = closedStack.value[0]
    if (!entry) return null
    closedStack.value = closedStack.value.slice(1)
    const already = byKey(entry.key)
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
    }
    tabs.value = [...tabs.value, tab]
    activeTabId.value = tab.id
    persist()
    return tab
  }

  /**    * The funnel. Returns the navigation to apply for the current URL: create a tab, focus an
   * existing one, honour a `?tab=` that names exactly this target, or (when disabled / an overlay)
   * leave the target alone. */
  function syncFromTarget(
    path: string,
    query: Record<string, unknown>,
    itemType?: string | null,
  ): SyncResult {
    // Migrate pre-tab-mode kanban-settings deep links (`?tab=<section>`) to `?section=` before the
    // tab ID logic runs — otherwise a legacy value like `?tab=memories` is mistaken for an unknown
    // browser tab ID and rewritten to a fresh `tab_xxx`, dropping the section.
    query = migrateLegacySettingsTab(path, query)
    const plain = tabQueryOf(query)
    const urlTabId = typeof query.tab === 'string' ? query.tab : ''

    if (!enabled.value) {
      return { path, query: plain, changed: !sameRouteQuery(plain, query) }
    }
    if (!shouldTabify(path, query)) {
      // Overlay views: never touch the URL, never create a tab.
      return { path, query: plain, changed: !sameRouteQuery(plain, query) }
    }

    const variants = tabKeyVariants(path, query, itemType)
    const canonical = variants[0] ?? ''
    const named = urlTabId ? byId(urlTabId) : null
    if (named && variants.includes(named.key)) {
      const desired = withTabParam(plain, named.id)
      refreshFromInput(named, { path, query: plain })
      rekeyTab(named.id, canonical, plain)
      activate(named.id)
      return { path, query: desired, changed: !sameRouteQuery(desired, query) }
    }

    const existing = findExisting(variants)
    if (existing) {
      const desired = withTabParam(plain, existing.id)
      refreshFromInput(existing, { path, query: plain })
      rekeyTab(existing.id, canonical, plain)
      activate(existing.id)
      return { path, query: desired, changed: !sameRouteQuery(desired, query) }
    }

    const created = open({ path, query: plain, itemType })
    const desired = withTabParam(plain, created.id)
    return { path, query: desired, changed: !sameRouteQuery(desired, query) }
  }

  function setEnabled(value: boolean): void {
    enabled.value = value
    writeStorage(ENABLED_KEY, value ? 'true' : 'false')
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
  let offTitleFeed: (() => void) | null = null

  function initTitleFeed(): void {
    if (offTitleFeed) return
    try {
      offTitleFeed = useSseBus().on('session', (event) => {
        if (event.action !== 'created' && event.action !== 'updated') return
        setChatTitle(event.id, event.name)
      })
    } catch {
      // No bus yet (early boot / unit test): titles keep whatever the chats
      // list last published.
      offTitleFeed = null
    }
  }

  function disposeTitleFeed(): void {
    if (!offTitleFeed) return
    offTitleFeed()
    offTitleFeed = null
  }

  /** Follow a session-id change *in place*. */
  /** `ChatsList` mints a synthetic `session-<timestamp>` id for a brand-new chat; when the real id
   * arrives (the `update-chat-id` path), a tab still keyed on the old id is a dead pointer — and
   * the route funnel would add a second tab for the same chat. */
  /** Ids are stable across a rename, so the strip (and the user's muscle memory) sees one tab that
   * simply became the real chat. */
  function renameChatTab(oldSessionId: string, newSessionId: string): boolean {
    if (!oldSessionId || !newSessionId || oldSessionId === newSessionId) return false
    const oldKey = `chat:${oldSessionId}`
    const newKey = `chat:${newSessionId}`
    const renamed = byKey(oldKey)
    if (!renamed) return false

    const alreadyOpen = byKey(newKey)
    if (alreadyOpen && alreadyOpen.id !== renamed.id) {
      // The live chat is already open: drop the dead pointer and focus it.
      close(renamed.id)
      activate(alreadyOpen.id)
      return true
    }

    tabs.value = tabs.value.map((tab) =>
      tab.id === renamed.id
        ? { ...tab, key: newKey, query: { ...tab.query, session: newSessionId } }
        : tab,
    )
    persist()
    return true
  }

  /** Live title feed (session SSE + the chats list). */
  function setChatTitle(sessionId: string, name: string): void {
    const tab = tabs.value.find(
      (candidate) => candidate.kind === 'chat' && candidate.key === `chat:${sessionId}`,
    )
    if (tab) setTabTitle(tab.id, name)
  }

  /**    * Store a title the caller resolved from live state (the workspace tree, the chats list, a rename
   * event). Used by the strip so the persisted label is a real name rather than the generic kind
   * fallback. */
  function setTabTitle(id: string, title: string): void {
    if (!id || !title) return
    let touched = false
    tabs.value = tabs.value.map((tab) => {
      if (tab.id !== id || tab.title === title) return tab
      touched = true
      return { ...tab, title }
    })
    if (touched) persist()
  }

  function getDraft(key: string): string {
    if (!key) return ''
    return drafts.value[key] ?? ''
  }

  function setDraft(key: string, text: string): void {
    if (!key) return
    if (!text) {
      clearDraft(key)
      return
    }
    if (drafts.value[key] === text) return
    drafts.value = { ...drafts.value, [key]: text }
  }

  function clearDraft(key: string): void {
    if (!key || !(key in drafts.value)) return
    const remaining = { ...drafts.value }
    delete remaining[key]
    drafts.value = remaining
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
    tabCount,
    canReopenLastClosed,
    // actions
    open,
    openInBackground,
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
    byKey,
  }
})
