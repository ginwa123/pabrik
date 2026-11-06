import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'
import { createApp } from 'vue'

import { MAX_TABS, type Tab } from '../helpers/tabTarget'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { __dispatchSseBus, __resetSseBus, installSseBus, useSseBus } from '../helpers/sseBus'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

/** Task 2 of the tab-mode plan. The invariants asserted here are the ones the reviewer signed off
 * on: 1. the list is never empty; 2. closing the active tab activates right-then-left; 3. */
const WINDOW_ID = 'w_testwindow'

const chat = (session: string) => ({ view: 'chat', session })
/** A file opened inside a session: the artifact tabs a session's strip holds. */
const fileIn = (session: string, path: string, cwd = '/repo') => ({
  view: 'code-editor',
  file: path,
  cwd,
  session,
})
const board = (itemId: string, workspaceId = 'ws_1') => ({ view: 'workspace', workspaceId, itemId })

/** Read the persisted tab list regardless of which window id keyed it. */
type RawPayload = {
  v: number
  active?: Record<string, string>
  strips?: Record<string, Tab[]>
  closed?: Record<string, unknown[]>
}

function rawList(): RawPayload | null {
  const store = localStorage
  for (let i = 0; i < store.length; i += 1) {
    const key = store.key(i)
    if (key && key.startsWith('pabrik-tabs:v1:')) {
      const value = store.getItem(key)
      return value ? JSON.parse(value) : null
    }
  }
  return null
}

function stubStorage(overrides: Partial<Storage> = {}): Storage {
  return Object.assign(makeLocalStorageStub(), overrides)
}

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: stubStorage({ getItem: () => WINDOW_ID }),
    writable: true,
    configurable: true,
  })
}

describe('tabs store', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
  })

  it('boots with exactly one home tab, active, tab mode on by default', () => {
    const tabs = useTabsStore()
    expect(tabs.tabCount).toBe(1)
    expect(tabs.tabs[0]?.key).toBe('home')
    expect(tabs.activeTabId).toBe(tabs.tabs[0]?.id)
    // The strip is a session's title bar now, so it starts on.
    expect(tabs.enabled).toBe(true)
    expect(tabs.activeTab?.query).toEqual({ view: 'chat' })
    expect(tabs.windowId).toBe(WINDOW_ID)
  })

  it('opens a tab after the active one and activates it', () => {
    const tabs = useTabsStore()
    const home = tabs.tabs[0] as Tab
    const opened = tabs.open({ query: chat('sa'), title: 'Chat A' })
    expect(opened.key).toBe('chat:sa')
    expect(opened.query).toEqual({ view: 'chat', session: 'sa' })
    expect(opened.query.tab).toBeUndefined()
    expect(tabs.tabs.map((t) => t.key)).toEqual(['home', 'chat:sa'])
    expect(tabs.activeTabId).toBe(opened.id)

    const third = tabs.open({ query: board('item_7') })
    expect(tabs.tabs.map((t) => t.key)).toEqual(['home', 'chat:sa', 'ws:ws_1:item_7'])
    expect(third.key).toBe('ws:ws_1:item_7')
    expect(tabs.tabs[0]?.id).toBe(home.id)
  })

  it('focuses an existing tab instead of duplicating it, and refreshes its query', () => {
    const tabs = useTabsStore()
    const first = tabs.open({ query: chat('sa') })
    tabs.open({ query: chat('sb') })
    expect(tabs.activeTab?.key).toBe('chat:sb')

    const again = tabs.open({ query: { ...chat('sa'), sorts: 'col_a:name:asc' } })
    expect(again.id).toBe(first.id)
    expect(tabs.tabCount).toBe(3)
    expect(tabs.activeTabId).toBe(first.id)
    expect(tabs.tabs.find((t) => t.id === first.id)?.query).toEqual({
      view: 'chat',
      session: 'sa',
      sorts: 'col_a:name:asc',
    })
  })

  it('keeps a caller-supplied title and kind', () => {
    const tabs = useTabsStore()
    const tab = tabs.open({ query: board('item_7'), title: 'My board', kind: 'workspace' })
    expect(tab.title).toBe('My board')
    expect(tab.kind).toBe('workspace')
  })

  it('opens in the background without touching the active tab', () => {
    const tabs = useTabsStore()
    const active = tabs.activeTabId
    const background = tabs.openInBackground({ query: chat('sa'), title: 'Chat A' })
    expect(tabs.activeTabId).toBe(active)
    expect(tabs.tabCount).toBe(2)
    expect(tabs.tabs.some((t) => t.id === background.id)).toBe(true)
    expect(tabs.openInBackground({ query: chat('sa') }).id).toBe(background.id)
    expect(tabs.tabCount).toBe(2)
  })

  it('ignores an unknown id when activating', () => {
    const tabs = useTabsStore()
    const active = tabs.activeTabId
    expect(tabs.activate('tab_nope')).toBe(false)
    expect(tabs.activeTabId).toBe(active)
    expect(tabs.activateIndex(9)).toBe(false)
    expect(tabs.activateIndex(0)).toBe(true)
  })

  it('closing an inactive tab leaves the active one alone', () => {
    const tabs = useTabsStore()
    tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    const b = tabs.open({ query: fileIn('sa', 'src/b.ts') })
    expect(tabs.activeTabId).toBe(b.id)
    expect(tabs.close(a.id)?.id).toBe(b.id)
    expect(tabs.activeTabId).toBe(b.id)
    expect(tabs.stripOf('sa')).toHaveLength(2)
    expect(tabs.closedStack[0]?.key).toBe('file:src/a.ts')
  })

  it('closing the active tab activates the right neighbour', () => {
    const tabs = useTabsStore()
    const pin = tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    const b = tabs.open({ query: fileIn('sa', 'src/b.ts') })
    const c = tabs.open({ query: fileIn('sa', 'src/c.ts') })
    expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, a.id, b.id, c.id])
    tabs.activate(b.id)
    expect(tabs.close(b.id)?.id).toBe(c.id)
    expect(tabs.activeTabId).toBe(c.id)
    expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, a.id, c.id])
  })

  it('closing the rightmost active tab activates the left neighbour', () => {
    const tabs = useTabsStore()
    const pin = tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    tabs.activate(a.id)
    expect(tabs.close(a.id)?.id).toBe(pin.id)
    expect(tabs.activeTabId).toBe(pin.id)
    expect(tabs.activeTab?.pinned).toBe(true)
  })

  it('closing the last remaining tab recreates a fresh home tab', () => {
    const tabs = useTabsStore()
    const only = tabs.tabs[0] as Tab
    const replacement = tabs.close(only.id)
    expect(tabs.tabCount).toBe(1)
    expect(replacement?.key).toBe('home')
    expect(tabs.activeTabId).toBe(replacement?.id)
    expect(tabs.tabs[0]?.id).not.toBe(only.id)
  })

  it('reports an unknown id from close', () => {
    const tabs = useTabsStore()
    expect(tabs.close('tab_nope')).toBeNull()
    expect(tabs.tabCount).toBe(1)
  })

  it('closes everything to the right, then everything else, inside one row', () => {
    const tabs = useTabsStore()
    const pin = tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    const b = tabs.open({ query: fileIn('sa', 'src/b.ts') })
    const c = tabs.open({ query: fileIn('sa', 'src/c.ts') })
    tabs.activate(b.id)

    tabs.closeToRight(b.id)
    expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, a.id, b.id])
    expect(tabs.activeTabId).toBe(b.id)
    expect(tabs.closedStack[0]?.id).toBe(c.id)

    // idempotent when there is nothing to the right
    tabs.closeToRight(b.id)
    expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, a.id, b.id])

    tabs.closeOthers(b.id)
    // the row keeps its anchor: "close others" can never end the session
    expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, b.id])
    expect(tabs.activeTabId).toBe(b.id)
    expect(tabs.closedStack.length).toBeGreaterThanOrEqual(2)

    tabs.closeOthers(b.id)
    expect(tabs.stripOf('sa')).toHaveLength(2)
  })

  it('reorders and keeps the active tab active', () => {
    const tabs = useTabsStore()
    const a = tabs.open({ query: chat('sa') })
    tabs.open({ query: chat('sb') })
    const c = tabs.open({ query: chat('sc') })
    tabs.activate(a.id)
    expect(tabs.tabs.map((t) => t.key)).toEqual(['home', 'chat:sa', 'chat:sb', 'chat:sc'])

    tabs.reorder(3, 0)
    expect(tabs.tabs.map((t) => t.key)).toEqual(['chat:sc', 'home', 'chat:sa', 'chat:sb'])
    expect(tabs.activeTabId).toBe(a.id)
    expect(tabs.tabs[0]?.id).toBe(c.id)

    tabs.reorder(0, 0)
    expect(tabs.tabs.map((t) => t.key)).toEqual(['chat:sc', 'home', 'chat:sa', 'chat:sb'])
    tabs.reorder(9, 2)
    expect(tabs.tabs.map((t) => t.key)).toEqual(['chat:sc', 'home', 'chat:sa', 'chat:sb'])
    tabs.reorder(1, 99)
    expect(tabs.tabs.map((t) => t.key)).toEqual(['chat:sc', 'chat:sa', 'chat:sb', 'home'])
  })

  it('cycles next and previous inside the row, with wrapping', () => {
    const tabs = useTabsStore()
    const pin = tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    tabs.activate(pin.id)
    expect(tabs.next()?.id).toBe(a.id)
    expect(tabs.next()?.id).toBe(pin.id)
    expect(tabs.prev()?.id).toBe(a.id)
    // another session's tabs are never part of this cycle
    tabs.open({ query: chat('sb') })
    tabs.activate(pin.id)
    expect(tabs.next()?.owner).toBe('sa')
  })

  it('reopens the last closed tab of this row, focusing it when the key is live again', () => {
    const tabs = useTabsStore()
    tabs.open({ query: chat('sa') })
    const a = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    tabs.close(a.id)
    expect(tabs.canReopenLastClosed).toBe(true)
    const reopened = tabs.reopenLastClosed()
    expect(reopened?.key).toBe('file:src/a.ts')
    expect(tabs.activeTabId).toBe(reopened?.id)
    expect(tabs.closedStack).toHaveLength(0)
    expect(tabs.reopenLastClosed()).toBeNull()

    tabs.close(reopened?.id ?? '')
    const live = tabs.open({ query: fileIn('sa', 'src/a.ts') })
    const focused = tabs.reopenLastClosed()
    expect(focused?.id).toBe(live.id)
    expect(tabs.stripOf('sa')).toHaveLength(2)
    expect(tabs.closedStack).toHaveLength(0)
  })

  it('caps a row without evicting its anchor or the active tab', () => {
    const tabs = useTabsStore()
    const pin = tabs.open({ query: chat('sa') })
    for (let i = 0; i < MAX_TABS + 12; i += 1) {
      tabs.open({ query: fileIn('sa', `src/f${i}.ts`) })
    }
    expect(tabs.stripOf('sa')).toHaveLength(MAX_TABS)
    expect(tabs.stripOf('sa').some((t) => t.id === pin.id)).toBe(true)
    expect(tabs.stripOf('sa').some((t) => t.id === tabs.activeTabId)).toBe(true)
  })

  it('persists the list per window and reloads it', () => {
    const tabs = useTabsStore()
    const a = tabs.open({ query: chat('sa'), title: 'Chat A' })
    const b = tabs.open({ query: board('item_7') })
    tabs.activate(a.id)

    const stored = rawList()
    expect(stored?.v).toBe(2)
    // one list per owner: the session's row, and the window's own row (`home` + the board)
    expect(Object.keys(stored?.strips ?? {}).sort()).toEqual(['', 'sa'])
    expect(stored?.strips?.sa?.map((t) => t.key)).toEqual(['chat:sa'])
    expect(stored?.strips?.['']?.map((t) => t.key)).toEqual(['home', 'ws:ws_1:item_7'])
    expect(stored?.active?.sa).toBe(a.id)

    // a reload = the same window id + a fresh pinia
    __resetWindowIdForTests()
    setActivePinia(createPinia())
    const reloaded = useTabsStore()
    // Rows come back contiguous (the payload is grouped by owner), so compare the rows themselves.
    expect(reloaded.stripOf('sa').map((t) => t.key)).toEqual(['chat:sa'])
    expect(reloaded.stripOf('').map((t) => t.key)).toEqual(['home', 'ws:ws_1:item_7'])
    expect(reloaded.tabCount).toBe(tabs.tabCount)
    expect(reloaded.activeTabId).toBe(a.id)
    expect(reloaded.tabCount).toBe(3)
    expect(reloaded.tabs.find((t) => t.id === b.id)?.kind).toBe('workspace')
  })

  it('does not share a tab list with a different window', () => {
    const tabs = useTabsStore()
    tabs.open({ query: chat('sa') })
    expect(tabs.tabCount).toBe(2)

    Object.defineProperty(globalThis, 'sessionStorage', {
      value: stubStorage({ getItem: () => 'w_otherwindow' }),
      writable: true,
      configurable: true,
    })
    __resetWindowIdForTests()
    setActivePinia(createPinia())
    const other = useTabsStore()
    expect(other.tabCount).toBe(1)
    expect(other.tabs[0]?.key).toBe('home')
  })

  it('starts over when the stored list is corrupt, without throwing', () => {
    localStorage.setItem(`pabrik-tabs:v1:${WINDOW_ID}`, '{')
    expect(() => useTabsStore()).not.toThrow()
    const tabs = useTabsStore()
    expect(tabs.tabCount).toBe(1)
    expect(tabs.tabs[0]?.key).toBe('home')
  })

  it('persists the enabled preference globally', () => {
    const tabs = useTabsStore()
    expect(tabs.enabled).toBe(true)
    tabs.setEnabled(false)
    expect(localStorage.getItem('pabrik-tabs-enabled')).toBe('false')
    tabs.setEnabled(true)
    expect(localStorage.getItem('pabrik-tabs-enabled')).toBe('true')
    tabs.setEnabled(false)
    setActivePinia(createPinia())
    expect(useTabsStore().enabled).toBe(false)
  })

  it('resets to a single home tab and drops the stored list', () => {
    const tabs = useTabsStore()
    tabs.open({ query: chat('sa') })
    tabs.open({ query: chat('sb') })
    const fresh = tabs.resetToHome()
    expect(tabs.tabCount).toBe(1)
    expect(tabs.activeTabId).toBe(fresh.id)
    expect(tabs.closedStack).toHaveLength(0)
    expect(rawList()?.strips?.['']?.map((t) => t.key)).toEqual(['home'])
  })

  describe('ownership: the strip belongs to the session', () => {
    it('keeps two sessions in two rows that never mix', () => {
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa') })
      const aFile = tabs.open({ query: fileIn('sa', 'src/tabs.ts') })
      const b = tabs.open({ query: chat('sb') })
      const bFile = tabs.open({ query: fileIn('sb', 'src/tabs.ts') })

      expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([a.id, aFile.id])
      expect(tabs.stripOf('sb').map((t) => t.id)).toEqual([b.id, bFile.id])
      // one file, two owners: the same key, two different tabs
      expect(aFile.key).toBe(bFile.key)
      expect(aFile.id).not.toBe(bFile.id)
      expect(tabs.tabs.filter((t) => t.key === aFile.key)).toHaveLength(2)
    })

    it('dedupes inside one row only', () => {
      const tabs = useTabsStore()
      tabs.open({ query: chat('sa') })
      const first = tabs.open({ query: fileIn('sa', 'src/tabs.ts') })
      const again = tabs.open({ query: fileIn('sa', 'src/tabs.ts') })
      expect(again.id).toBe(first.id)
      expect(tabs.stripOf('sa')).toHaveLength(2)

      const other = tabs.open({ query: fileIn('sb', 'src/tabs.ts') })
      expect(other.id).not.toBe(first.id)
      expect(tabs.tabs.filter((t) => t.key === first.key)).toHaveLength(2)
    })

    it('gives a session its own anchor tab, and a tab gesture cannot end it', () => {
      const tabs = useTabsStore()
      const pin = tabs.open({ query: chat('sa') })
      expect(pin.pinned).toBe(true)
      expect(pin.owner).toBe('sa')

      const file = tabs.open({ query: fileIn('sa', 'src/a.ts') })
      expect(file.pinned).toBeUndefined()

      expect(tabs.close(pin.id)?.id).toBe(file.id)
      expect(tabs.stripOf('sa')).toHaveLength(2)
      expect(tabs.closedStack).toHaveLength(0)

      tabs.closeOthers(file.id)
      expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([pin.id, file.id])
    })

    it('splits a file and its diff into two tabs of one row', () => {
      const tabs = useTabsStore()
      tabs.open({ query: chat('sa') })
      const file = tabs.open({ query: fileIn('sa', 'src/deep/a.ts') })
      const diff = tabs.open({ query: { ...fileIn('sa', 'src/deep/a.ts'), mode: 'diff' } })

      expect(file.key).toBe('file:src/deep/a.ts')
      expect(diff.key).toBe('diff:src/deep/a.ts')
      expect(file.kind).toBe('file')
      expect(diff.kind).toBe('diff')
      // the tab wears the file's own name, not its path
      expect(file.title).toBe('a.ts')
      expect(diff.title).toBe('a.ts')
      expect(tabs.stripOf('sa').map((t) => t.kind)).toEqual(['chat', 'file', 'diff'])
    })

    it('keeps the window row for destinations that belong to no session', () => {
      const tabs = useTabsStore()
      const home = tabs.tabs[0] as Tab
      const boardTab = tabs.open({ query: board('item_7') })
      expect(boardTab.owner).toBeUndefined()
      expect(tabs.stripOf('').map((t) => t.id)).toEqual([home.id, boardTab.id])
      expect(tabs.stripOf('sa')).toHaveLength(0)
    })

    it('opens into the owner the caller names, whatever the target says', () => {
      const tabs = useTabsStore()
      const forced = tabs.openInSession('sa', {
        query: { view: 'code-editor', file: 'x.ts', cwd: '/repo' },
      })
      expect(forced.owner).toBe('sa')
      expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([forced.id])
      expect(tabs.stripOf('').some((t) => t.id === forced.id)).toBe(false)
    })

    it('moves the whole row when the session id is renamed', () => {
      const tabs = useTabsStore()
      tabs.open({ query: chat('session-1') })
      tabs.open({ query: fileIn('session-1', 'src/a.ts') })
      expect(tabs.renameChatTab('session-1', 'real-7')).toBe(true)
      expect(tabs.stripOf('session-1')).toHaveLength(0)
      expect(tabs.stripOf('real-7').map((t) => t.kind)).toEqual(['chat', 'file'])
    })

    it('does not honour a ?tab= that belongs to another session', () => {
      const tabs = useTabsStore()
      tabs.setEnabled(true)
      const aFile = tabs.open({ query: fileIn('sa', 'src/a.ts') })
      // the URL names session sb but the tab id belongs to sa's row
      const result = tabs.syncFromTarget('/app', {
        ...chat('sb'),
        tab: aFile.id,
      })
      expect(result.query.tab).not.toBe(aFile.id)
      expect(tabs.activeTab?.owner).toBe('sb')
      expect(tabs.stripOf('sa').map((t) => t.id)).toEqual([aFile.id])
    })
  })

  describe('syncFromTarget (the route funnel)', () => {
    beforeEach(() => {
      useTabsStore().setEnabled(true)
    })
    it('creates a tab for a fresh target and names it in the URL', () => {
      const tabs = useTabsStore()
      const result = tabs.syncFromTarget('/app', chat('sa'))
      expect(result.changed).toBe(true)
      expect(result.path).toBe('/app')
      expect(result.query).toEqual({ view: 'chat', session: 'sa', tab: tabs.activeTabId })
      expect(tabs.tabs.map((t) => t.key)).toEqual(['home', 'chat:sa'])
      expect(tabs.activeTab?.key).toBe('chat:sa')
    })

    it('is a no-op when the URL already names this target', () => {
      const tabs = useTabsStore()
      const first = tabs.syncFromTarget('/app', chat('sa'))
      const second = tabs.syncFromTarget('/app', { ...chat('sa'), tab: String(first.query.tab) })
      expect(second.changed).toBe(false)
      expect(tabs.tabCount).toBe(2)
    })

    it('focuses an existing tab and normalizes the URL to its id', () => {
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa') })
      tabs.open({ query: chat('sb') })
      const result = tabs.syncFromTarget('/app', chat('sa'))
      expect(result.query.tab).toBe(a.id)
      expect(result.changed).toBe(true)
      expect(tabs.activeTabId).toBe(a.id)
      expect(tabs.tabCount).toBe(3)
    })

    it('repairs a ?tab= that does not name this target', () => {
      const tabs = useTabsStore()
      const stale = tabs.open({ query: chat('sa') })
      const result = tabs.syncFromTarget('/app', { ...chat('sb'), tab: stale.id })
      expect(result.changed).toBe(true)
      expect(result.query.tab).not.toBe(stale.id)
      const created = tabs.tabs.find((t) => t.key === 'chat:sb')
      expect(created).toBeTruthy()
      expect(result.query.tab).toBe(created?.id)
      expect(tabs.activeTabId).toBe(created?.id)
    })

    it('honours a ?tab= that names exactly this target', () => {
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa') })
      const b = tabs.open({ query: chat('sb') })
      expect(tabs.activeTabId).toBe(b.id)
      const result = tabs.syncFromTarget('/app', { ...chat('sa'), tab: a.id })
      expect(result.changed).toBe(false)
      expect(tabs.activeTabId).toBe(a.id)
    })

    it('gives every kanban task chat its own tab, leaving the board tab open', () => {
      const tabs = useTabsStore()
      const boardTab = tabs.open({ query: board('item_7'), itemType: 'kanban' })
      const withTask = { ...board('item_7'), itemId: 'item_7/chat/task_9' }

      // a card click lands on its own tab — never the board's
      const result = tabs.syncFromTarget('/app', withTask, 'kanban')
      expect(result.query.tab).not.toBe(boardTab.id)
      expect(tabs.tabCount).toBe(3)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')
      // the tab's stored target is the chat, so a reload restores the chat
      expect(tabs.activeTab?.query).toEqual(withTask)
      // ...and the board tab is untouched and still open
      expect(tabs.tabs.find((t) => t.id === boardTab.id)?.query).toEqual(board('item_7'))

      // a second card is a second tab
      tabs.syncFromTarget('/app', { ...board('item_7'), itemId: 'item_7/chat/task_10' }, 'kanban')
      expect(tabs.tabCount).toBe(4)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_10')

      // re-selecting one of them focuses that tab rather than adding another
      tabs.syncFromTarget('/app', withTask, 'kanban')
      expect(tabs.tabCount).toBe(4)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')

      // going back to the bare board focuses the board tab again
      const backToBoard = tabs.syncFromTarget('/app', board('item_7'), 'kanban')
      expect(backToBoard.query.tab).toBe(boardTab.id)
      expect(tabs.tabCount).toBe(4)
      expect(tabs.activeTabId).toBe(boardTab.id)
    })

    it('opens a separate tab for a task chat on item types that render it standalone', () => {
      const tabs = useTabsStore()
      const itemTab = tabs.open({ query: board('item_7'), itemType: 'agent' })
      const result = tabs.syncFromTarget(
        '/app',
        { ...board('item_7'), itemId: 'item_7/chat/task_9' },
        'agent',
      )
      expect(result.query.tab).not.toBe(itemTab.id)
      expect(result.changed).toBe(true)
      expect(tabs.tabCount).toBe(3)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')
      // re-selecting the same task focuses it rather than adding another
      const again = tabs.syncFromTarget(
        '/app',
        { ...board('item_7'), itemId: 'item_7/chat/task_9', tab: String(result.query.tab) },
        'agent',
      )
      expect(again.changed).toBe(false)
      expect(tabs.tabCount).toBe(3)
    })

    it('needs no adoption for a kanban task chat — the cold-boot key is canonical', () => {
      const tabs = useTabsStore()
      // the tree has not loaded yet → the type is unknown → task-level identity
      const first = tabs.syncFromTarget('/app', {
        ...board('item_7'),
        itemId: 'item_7/chat/task_9',
      })
      expect(tabs.tabCount).toBe(2)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')

      // learning the type is a no-op: same tab, same key, no re-key, no duplicate
      const second = tabs.syncFromTarget(
        '/app',
        { ...board('item_7'), itemId: 'item_7/chat/task_9' },
        'kanban',
      )
      expect(second.query.tab).toBe(first.query.tab)
      expect(tabs.tabCount).toBe(2)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')
    })

    it('adopts a cold-boot tab once the type is known (design still shares the item tab)', () => {
      const tabs = useTabsStore()
      // the tree has not loaded yet → the type is unknown → task-level identity
      const first = tabs.syncFromTarget('/app', {
        ...board('item_7'),
        itemId: 'item_7/chat/task_9',
      })
      expect(tabs.tabCount).toBe(2)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7:chat:task_9')

      // design renders its chat INSIDE the canvas tab, so the provisional tab is
      // re-keyed onto the item's identity in place — never duplicated
      const second = tabs.syncFromTarget(
        '/app',
        { ...board('item_7'), itemId: 'item_7/chat/task_9' },
        'design',
      )
      expect(second.query.tab).toBe(first.query.tab)
      expect(tabs.tabCount).toBe(2)
      expect(tabs.activeTab?.key).toBe('ws:ws_1:item_7')
      expect(tabs.tabs.some((t) => t.key === 'ws:ws_1:item_7:chat:task_9')).toBe(false)
    })

    it('never touches the URL of an overlay view and creates no tab', () => {
      const tabs = useTabsStore()
      const query = { view: 'skill', skill: 'brainstorming' }
      const result = tabs.syncFromTarget('/app', query)
      expect(result.changed).toBe(false)
      expect(result.query).toEqual(query)
      expect(tabs.tabCount).toBe(1)
    })

    it('creates no tab and cleans the URL when tab mode is off', () => {
      const tabs = useTabsStore()
      tabs.setEnabled(false)
      const result = tabs.syncFromTarget('/app', { ...chat('sa'), tab: 'tab_whatever' })
      expect(result.query).toEqual({ view: 'chat', session: 'sa' })
      expect(result.changed).toBe(true)
      expect(tabs.tabCount).toBe(1)
    })

    it('handles the path-based views', () => {
      const tabs = useTabsStore()
      const settings = tabs.syncFromTarget('/app/settings', {})
      expect(settings.changed).toBe(true)
      expect(settings.query.tab).toBe(tabs.activeTabId)
      expect(tabs.activeTab?.kind).toBe('settings')
      expect(tabs.activeTab?.key).toBe('settings')

      const kanbanSettings = tabs.syncFromTarget('/app/kanban/item_7/settings', {})
      expect(kanbanSettings.changed).toBe(true)
      expect(tabs.activeTab?.kind).toBe('kanban-settings')
      expect(tabs.activeTab?.key).toBe('ks:item_7')
      expect(tabs.tabCount).toBe(3)
    })
  })

  describe('renameChatTab (synthetic → real session id)', () => {
    it('renames the tab in place, keeping its identity and position', () => {
      const tabs = useTabsStore()
      const first = tabs.open({ query: chat('sa') })
      const synthetic = tabs.open({ query: chat('session-1789000000000'), title: 'New Chat' })
      tabs.activate(synthetic.id)

      expect(tabs.renameChatTab('session-1789000000000', 'real-7')).toBe(true)

      const renamed = tabs.tabs.find((t) => t.id === synthetic.id)
      expect(renamed?.key).toBe('chat:real-7')
      expect(renamed?.query).toEqual({ view: 'chat', session: 'real-7' })
      expect(renamed?.title).toBe('New Chat')
      expect(tabs.tabs.map((t) => t.id)).toEqual([tabs.tabs[0]?.id, first.id, synthetic.id])
      expect(tabs.activeTabId).toBe(synthetic.id)
      // and it persists under its NEW owner, so a reload does not resurrect the dead id
      const stored = rawList()?.strips ?? {}
      expect(stored['real-7']?.map((t) => t.key)).toEqual(['chat:real-7'])
      expect(
        Object.values(stored)
          .flat()
          .map((t) => t.key),
      ).not.toContain('chat:session-1789000000000')
    })

    it('drops the dead pointer when the real chat is already open', () => {
      const tabs = useTabsStore()
      const real = tabs.open({ query: chat('real-7'), title: 'Real' })
      const synthetic = tabs.open({ query: chat('session-1'), title: 'New Chat' })
      tabs.activate(synthetic.id)

      expect(tabs.renameChatTab('session-1', 'real-7')).toBe(true)

      expect(tabs.tabs.some((t) => t.id === synthetic.id)).toBe(false)
      expect(tabs.tabCount).toBe(2)
      expect(tabs.activeTabId).toBe(real.id)
    })

    it('is a no-op when there is nothing to rename', () => {
      const tabs = useTabsStore()
      tabs.open({ query: chat('sa') })
      const before = tabs.tabs.map((t) => t.key)
      expect(tabs.renameChatTab('nope', 'real-7')).toBe(false)
      expect(tabs.renameChatTab('sa', 'sa')).toBe(false)
      expect(tabs.renameChatTab('', 'real-7')).toBe(false)
      expect(tabs.renameChatTab('sa', '')).toBe(false)
      expect(tabs.tabs.map((t) => t.key)).toEqual(before)
    })
  })

  describe('titles and drafts', () => {
    it('updates the title of the matching chat tab only', () => {
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa'), title: 'Old' })
      const b = tabs.open({ query: chat('sb'), title: 'Other' })
      tabs.setChatTitle('sa', 'Renamed')
      expect(tabs.tabs.find((t) => t.id === a.id)?.title).toBe('Renamed')
      expect(tabs.tabs.find((t) => t.id === b.id)?.title).toBe('Other')
      tabs.setChatTitle('sa', '')
      tabs.setChatTitle('nope', 'X')
      expect(tabs.tabs.find((t) => t.id === a.id)?.title).toBe('Renamed')
      expect(tabs.tabs.find((t) => t.id === b.id)?.title).toBe('Other')
      expect(tabs.tabs[0]?.title).toBe('Pabrik')
    })

    it('keeps drafts per key and survives closing the tab', () => {
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa') })
      expect(tabs.getDraft('chat:sa')).toBe('')
      tabs.setDraft('chat:sa', 'half written')
      expect(tabs.getDraft('chat:sa')).toBe('half written')
      tabs.close(a.id)
      expect(tabs.getDraft('chat:sa')).toBe('half written')
      tabs.setDraft('chat:sa', '')
      expect(tabs.getDraft('chat:sa')).toBe('')
      expect(tabs.getDraft('')).toBe('')
      tabs.setDraft('', 'ignored')
      expect(tabs.drafts).toEqual({})
    })

    it('opens the chats tab, focusing it when it is already open', () => {
      const tabs = useTabsStore()
      const home = tabs.tabs[0]
      tabs.open({ query: chat('sa') })
      expect(tabs.activeTab).not.toBeNull()

      const backHome = tabs.openHomeTab()
      expect(backHome.id).toBe(home?.id)
      expect(tabs.activeTabId).toBe(home?.id)
      expect(tabs.tabCount).toBe(2)
    })

    it('tolerates a title feed with no bus installed', () => {
      __resetSseBus()
      const tabs = useTabsStore()
      // no feed (the bus is not installed yet): nothing to subscribe, nothing to throw
      expect(() => tabs.initTitleFeed(null)).not.toThrow()
      expect(() => tabs.disposeTitleFeed()).not.toThrow()
    })

    it('feeds tab titles from the session SSE channel and stops on dispose', () => {
      __resetSseBus()
      installSseBus(createApp({}))
      const tabs = useTabsStore()
      const a = tabs.open({ query: chat('sa'), title: 'Old' })
      tabs.initTitleFeed(useSseBus())

      __dispatchSseBus('session', { action: 'updated', id: 'sa', name: 'Renamed live' } as never)
      expect(tabs.tabs.find((t) => t.id === a.id)?.title).toBe('Renamed live')

      __dispatchSseBus('session', { action: 'created', id: 'sb', name: 'Brand new' } as never)
      expect(tabs.tabs.find((t) => t.key === 'chat:sb')).toBeUndefined()

      // only created/updated carry a meaningful name
      __dispatchSseBus('session', { action: 'deleted', id: 'sa', name: 'Gone' } as never)
      expect(tabs.tabs.find((t) => t.id === a.id)?.title).toBe('Renamed live')

      // idempotent registration: a second init must not double-subscribe
      tabs.initTitleFeed(useSseBus())
      tabs.disposeTitleFeed()
      __dispatchSseBus('session', { action: 'updated', id: 'sa', name: 'After dispose' } as never)
      expect(tabs.tabs.find((t) => t.id === a.id)?.title).toBe('Renamed live')
      __resetSseBus()
    })
  })
})
