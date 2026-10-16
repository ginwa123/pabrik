import { beforeEach, describe, expect, it } from 'vitest'

import {
  MAX_CLOSED,
  fallbackTitle,
  homeTab,
  isBackgroundOpenEvent,
  kindOf,
  migrateLegacySettingsTab,
  newTabId,
  parseTabList,
  shouldTabify,
  stripTabParam,
  tabKeyOf,
  tabKeyVariants,
  taskChatRendersInItemTab,
  withTabParam,
  type Tab,
  type TabKind,
} from '../helpers/tabTarget'
import { __resetWindowIdForTests, getWindowId } from '../helpers/windowId'
import { makeLocalStorageStub } from './helpers'

/**  * Task 1 of the tab-mode plan: every rule that decides WHICH target a tab represents, which
 * navigations never become tabs, and how a persisted list is validated. These are pure functions on
 * purpose — the store and the strip are tested separately. */
describe('isBackgroundOpenEvent', () => {
  it('matches the browser gesture for "open in a background tab"', () => {
    expect(isBackgroundOpenEvent({ ctrlKey: true })).toBe(true)
    expect(isBackgroundOpenEvent({ metaKey: true })).toBe(true)
    expect(isBackgroundOpenEvent({ button: 1 })).toBe(true)
    expect(isBackgroundOpenEvent({})).toBe(false)
    expect(isBackgroundOpenEvent({ ctrlKey: false, metaKey: false, button: 0 })).toBe(false)
  })
})

describe('tabKeyOf', () => {
  it('keys a standalone chat by its session', () => {
    expect(tabKeyOf('/app', { view: 'chat', session: 'session-1' })).toBe('chat:session-1')
  })

  it('keys the chats list (no session) as home', () => {
    expect(tabKeyOf('/app', { view: 'chat' })).toBe('home')
    expect(tabKeyOf('/app', {})).toBe('home')
    expect(tabKeyOf('/app', { view: 'chat', session: '' })).toBe('home')
  })

  it('keys a workspace item by workspace, item and page', () => {
    expect(tabKeyOf('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' })).toBe(
      'ws:ws_1:item_7',
    )
    expect(
      tabKeyOf('/app', {
        view: 'workspace',
        workspaceId: 'ws_1',
        itemId: 'item_7',
        pageId: 'page_2',
      }),
    ).toBe('ws:ws_1:item_7:page_2')
  })

  it('gives a task chat its own tab, except for dialog item types', () => {
    const url = { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7/chat/task_9' }
    const bareBoard = tabKeyOf('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' })
    // design opens the chat as a dialog INSIDE the item's view → one tab
    expect(tabKeyOf('/app', url, 'design')).toBe('ws:ws_1:item_7')
    expect(tabKeyOf('/app', url, 'design')).toBe(bareBoard)
    // kanban and every other type render the chat as its own view → own tab
    expect(tabKeyOf('/app', url, 'kanban')).toBe('ws:ws_1:item_7:chat:task_9')
    expect(tabKeyOf('/app', url, 'agent')).toBe('ws:ws_1:item_7:chat:task_9')
    expect(tabKeyOf('/app', url, 'folder')).toBe('ws:ws_1:item_7:chat:task_9')
    // unknown type (cold boot, tree not loaded yet) leans to its own tab
    expect(tabKeyOf('/app', url)).toBe('ws:ws_1:item_7:chat:task_9')
    // only design still has two readings to reconcile
    expect(tabKeyVariants('/app', url, 'design')).toEqual([
      'ws:ws_1:item_7',
      'ws:ws_1:item_7:chat:task_9',
    ])
    // every other type (known or unknown) collapses to ONE reading — the
    // cold-boot key is already canonical, so nothing has to be adopted
    expect(tabKeyVariants('/app', url, 'agent')).toEqual(['ws:ws_1:item_7:chat:task_9'])
    expect(tabKeyVariants('/app', url, 'kanban')).toEqual(['ws:ws_1:item_7:chat:task_9'])
    expect(tabKeyVariants('/app', url)).toEqual(['ws:ws_1:item_7:chat:task_9'])
    expect(tabKeyVariants('/app', { view: 'chat', session: 'sa' }, 'kanban')).toEqual(['chat:sa'])
  })

  it('reports which item types keep a task chat inside the item tab', () => {
    expect(taskChatRendersInItemTab('kanban')).toBe(false)
    expect(taskChatRendersInItemTab('design')).toBe(true)
    expect(taskChatRendersInItemTab('agent')).toBe(false)
    expect(taskChatRendersInItemTab('folder')).toBe(false)
    expect(taskChatRendersInItemTab(null)).toBe(false)
    expect(taskChatRendersInItemTab(undefined)).toBe(false)
  })

  it('keys the legacy view=task shape as a chat', () => {
    expect(tabKeyOf('/app', { view: 'task', task: 'task_9' })).toBe('chat:task_9')
  })

  it('keys the two path-based views', () => {
    expect(tabKeyOf('/app/settings', {})).toBe('settings')
    expect(tabKeyOf('/app/kanban/item_7/settings', {})).toBe('ks:item_7')
    expect(tabKeyOf('/app/kanban/item_7/settings/', {})).toBe('ks:item_7')
  })

  it('ignores the tab param and the volatile sorts param', () => {
    const base = tabKeyOf('/app', { view: 'chat', session: 'session-1' })
    expect(tabKeyOf('/app', { view: 'chat', session: 'session-1', tab: 'tab_zzz' })).toBe(base)
    const board = tabKeyOf('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' })
    expect(
      tabKeyOf('/app', {
        view: 'workspace',
        workspaceId: 'ws_1',
        itemId: 'item_7',
        sorts: 'col_a:updated_at:desc',
      }),
    ).toBe(board)
  })

  it('coerces non-string query values instead of dropping the key', () => {
    expect(tabKeyOf('/app', { view: 'chat', session: 42 })).toBe('chat:42')
  })
})

describe('shouldTabify', () => {
  it('refuses the full-surface overlays', () => {
    expect(shouldTabify('/app', { view: 'gitfile', file: 'aGk=' })).toBe(false)
    expect(shouldTabify('/app', { view: 'skill', skill: 'brainstorming' })).toBe(false)
    expect(shouldTabify('/app', { view: 'code-editor', file: 'aGk=' })).toBe(false)
  })

  it('refuses the delete-chat event flag', () => {
    expect(shouldTabify('/app', { view: 'delete-chat' })).toBe(false)
  })

  it('accepts the real destinations', () => {
    expect(shouldTabify('/app', { view: 'chat' })).toBe(true)
    expect(shouldTabify('/app', { view: 'chat', session: 's1' })).toBe(true)
    expect(shouldTabify('/app', { view: 'workspace', itemId: 'item_7' })).toBe(true)
    expect(shouldTabify('/app', {})).toBe(true)
    expect(shouldTabify('/app/settings', {})).toBe(true)
    expect(shouldTabify('/app/kanban/item_7/settings', {})).toBe(true)
  })
})

describe('stripTabParam + withTabParam', () => {
  it('drops tab and empty values, keeps everything else as strings', () => {
    expect(stripTabParam({ view: 'chat', tab: 'tab_1', session: '', other: 'x', n: 3 })).toEqual({
      view: 'chat',
      other: 'x',
      n: '3',
    })
    expect(stripTabParam(null)).toEqual({})
    expect(stripTabParam({ a: null, b: ['x'], c: { d: 1 }, e: undefined })).toEqual({})
  })

  it('round-trips through withTabParam', () => {
    const target = { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7' }
    const withTab = withTabParam(target, 'tab_1')
    expect(withTab).toEqual({ ...target, tab: 'tab_1' })
    expect(stripTabParam(withTab)).toEqual(target)
  })

  it('omits tab when the id is empty', () => {
    expect(withTabParam({ view: 'chat' }, '')).toEqual({ view: 'chat' })
  })
})

describe('kindOf + fallbackTitle', () => {
  it('derives the display hint from the target', () => {
    expect(kindOf('/app', { view: 'chat' })).toBe('home')
    expect(kindOf('/app', { view: 'chat', session: 's1' })).toBe('chat')
    expect(kindOf('/app', { view: 'workspace', itemId: 'item_7' })).toBe('workspace')
    expect(kindOf('/app/settings', {})).toBe('settings')
    expect(kindOf('/app/kanban/item_7/settings', {})).toBe('kanban-settings')
    expect(kindOf('/app', { view: 'routine' })).toBe('other')
  })

  it('always has a title for every kind', () => {
    const kinds: TabKind[] = ['home', 'chat', 'workspace', 'kanban-settings', 'settings', 'other']
    for (const kind of kinds) {
      expect(fallbackTitle(kind)).toBeTruthy()
    }
  })
})

describe('homeTab + newTabId', () => {
  it('describes the chats list and is usable as a target', () => {
    const tab = homeTab()
    expect(tab.key).toBe('home')
    expect(tab.kind).toBe('home')
    expect(tab.path).toBe('/app')
    expect(tab.query).toEqual({ view: 'chat' })
    expect(tabKeyOf(tab.path, tab.query)).toBe('home')
  })

  it('never repeats an id', () => {
    const ids = new Set([newTabId(), newTabId(), newTabId(), newTabId()])
    expect(ids.size).toBe(4)
  })
})

describe('parseTabList', () => {
  const stored = (tabs: Tab[], active: string, extra: Record<string, unknown> = {}) =>
    JSON.stringify({ v: 1, active, tabs, closed: [], ...extra })

  const chatTab = (id: string, session: string): Tab => ({
    id,
    key: `chat:${session}`,
    kind: 'chat',
    title: `Title ${session}`,
    path: '/app',
    query: { view: 'chat', session },
    createdAt: 1,
  })

  it('starts over for every unusable input', () => {
    for (const raw of [
      null,
      '',
      '{',
      '{}',
      '[]',
      '"x"',
      '{"v":99,"tabs":[]}',
      '{"v":1}',
      '{"v":1,"tabs":{}}',
    ]) {
      const list = parseTabList(raw)
      expect(list.tabs).toHaveLength(1)
      expect(list.tabs[0]?.key).toBe('home')
      expect(list.active).toBe(list.tabs[0]?.id)
      expect(list.closed).toEqual([])
    }
  })

  it('drops malformed entries and keeps the good ones in order', () => {
    const malformed = [chatTab('tab_a', 'sa'), { id: 42 }, { key: 'no-id' }, chatTab('tab_b', 'sb')]
    const list = parseTabList(stored(malformed as unknown as Tab[], 'tab_b'))
    expect(list.tabs.map((t) => t.id)).toEqual(['tab_a', 'tab_b'])
    expect(list.active).toBe('tab_b')
  })

  it('starts over when no entry survives validation', () => {
    const list = parseTabList(stored([{ id: '' }, null, 'x'] as unknown as Tab[], 'nope'))
    expect(list.tabs).toHaveLength(1)
    expect(list.tabs[0]?.key).toBe('home')
  })

  it('falls back to the first tab when active is unknown, and de-dupes by key', () => {
    const list = parseTabList(
      stored([chatTab('tab_a', 'sa'), chatTab('tab_b', 'sa')], 'tab_missing'),
    )
    expect(list.tabs.map((t) => t.id)).toEqual(['tab_a'])
    expect(list.active).toBe('tab_a')
  })

  it('rebuilds a missing key and an unknown kind instead of rejecting the entry', () => {
    const list = parseTabList(
      stored(
        [
          {
            id: 'tab_a',
            kind: 'martian',
            title: '',
            path: '/app',
            query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_7/chat/task_9' },
            createdAt: 5,
          } as unknown as Tab,
        ],
        'tab_a',
      ),
    )
    const tab = list.tabs[0]
    expect(tab?.key).toBe('ws:ws_1:item_7:chat:task_9')
    expect(tab?.kind).toBe('workspace')
    expect(tab?.title).toBe('Workspace')
  })

  it('caps the reopen stack', () => {
    const closed = Array.from({ length: MAX_CLOSED + 5 }, (_, i) => ({
      ...chatTab(`tab_c${i}`, `sc${i}`),
      closedAt: i,
    }))
    const list = parseTabList(
      JSON.stringify({ v: 1, active: 'tab_a', tabs: [chatTab('tab_a', 'sa')], closed }),
    )
    expect(list.closed).toHaveLength(MAX_CLOSED)
  })

  it('preserves a valid list unchanged', () => {
    const tabs = [chatTab('tab_a', 'sa'), chatTab('tab_b', 'sb')]
    const list = parseTabList(stored(tabs, 'tab_a'))
    expect(list.tabs).toEqual(tabs)
    expect(list.active).toBe('tab_a')
  })
})

describe('getWindowId', () => {
  beforeEach(() => {
    __resetWindowIdForTests()
  })

  it('creates once and then reuses the stored id', () => {
    const storage = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: storage,
      writable: true,
      configurable: true,
    })

    const first = getWindowId()
    expect(first).toMatch(/^w_[a-z0-9]+$/)
    __resetWindowIdForTests()
    expect(getWindowId()).toBe(first)
    __resetWindowIdForTests()
    expect(storage.getItem('pabrik-window-id')).toBe(first)
  })

  it('returns a stable id when storage throws', () => {
    const storage = makeLocalStorageStub()
    storage.getItem = () => {
      throw new Error('denied')
    }
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: storage,
      writable: true,
      configurable: true,
    })

    const first = getWindowId()
    expect(first).toMatch(/^w_/)
    expect(getWindowId()).toBe(first)
  })

  it('still works without sessionStorage at all', () => {
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: undefined,
      writable: true,
      configurable: true,
    })
    const first = getWindowId()
    expect(first).toMatch(/^w_/)
    expect(getWindowId()).toBe(first)
  })
})

describe('migrateLegacySettingsTab', () => {
  const KS = '/app/kanban/item_1/settings'

  it('moves legacy ?tab=memories to ?section=agent', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'memories' })).toEqual({
      section: 'agent',
    })
  })

  it('moves legacy ?tab=tools and ?tab=knowledge to ?section=agent', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'tools' })).toEqual({
      section: 'agent',
    })
    expect(migrateLegacySettingsTab(KS, { tab: 'knowledge' })).toEqual({
      section: 'agent',
    })
  })

  it('moves legacy ?tab=agent to ?section=agent', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'agent' })).toEqual({
      section: 'agent',
    })
  })

  it('drops legacy ?tab=columns (default stays clean)', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'columns' })).toEqual({})
  })

  it('leaves browser tab IDs (?tab=tab_xxx) untouched', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'tab_mu0lle6j940yz' })).toEqual({
      tab: 'tab_mu0lle6j940yz',
    })
  })

  it('leaves unknown ?tab= values untouched', () => {
    expect(migrateLegacySettingsTab(KS, { tab: 'totally-bogus' })).toEqual({
      tab: 'totally-bogus',
    })
  })

  it('prefers an explicit ?section= over legacy ?tab=', () => {
    expect(migrateLegacySettingsTab(KS, { section: 'agent', tab: 'tab_abc' })).toEqual({
      section: 'agent',
      tab: 'tab_abc',
    })
  })

  it('ignores non-settings paths', () => {
    expect(migrateLegacySettingsTab('/app', { tab: 'memories' })).toEqual({
      tab: 'memories',
    })
    expect(migrateLegacySettingsTab('/app/settings', { tab: 'agent' })).toEqual({ tab: 'agent' })
  })
})
