/**
 * Lazy per-workspace item loading (plan:
 * docs/plans/2026-09-22-revamp-ui-chats-workspace-scoped.md, Phase 4).
 *
 * init() fetches the workspace list but loads items (tasks, design
 * pages, kanban prefetch) for the ACTIVE workspace only; every other
 * workspace keeps `items: []` until visited. setActiveWorkspace
 * triggers exactly one fetch for the target — in-flight dedupe,
 * loaded-set cache on re-switch. The WorkspaceSwitcher badge reads
 * the wire `items_count` so it stays truthful for unvisited rows.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import WorkspaceSwitcher from '../components/workspace/WorkspaceSwitcher.vue'
import { makeLocalStorageStub } from './helpers'
import { workspacesCacheKey } from '../helpers/workspacesCache'
import { resetUserScopeForTest, setCurrentUserId } from '../helpers/userScope'
import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

const WS_LIST = [
  { id: 'ws_1', name: 'Workspace 1', icon: '📁' },
  { id: 'ws_2', name: 'Workspace 2', icon: '📁' },
]

const ITEMS_BY_WS: Record<string, WorkspaceItem[]> = {
  ws_1: [{ id: 'item_1', name: 'One', item_type: 'folder' } as WorkspaceItem],
  ws_2: [{ id: 'item_2', name: 'Two', item_type: 'folder' } as WorkspaceItem],
}

describe('workspaces store lazy per-workspace item loading', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()
  const listDesignPagesMock = vi.fn()
  const listKanbanColumnsMock = vi.fn()

  let localStorageStub: Storage
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // Declare the identity as resolved with no user (the auth-off case): `userScopedKey` then
    // returns the legacy unscoped key, which is what these specs write via `workspacesCacheKey()`.

    // Without this the store's first-paint gate (plan 2026-09-25, W5) refuses to read the cache,
    // because a real boot resolves `/api/auth/me` before any view mounts.
    resetUserScopeForTest()
    setCurrentUserId(null)

    // init() installs the bus-backed session handlers — install the
    // stub bus first so useSseBus() doesn't throw.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    // Clear histories AND (re)apply default impls — vi.fn histories
    // survive vi.restoreAllMocks(), so both must happen per test.
    for (const fn of [
      getWorkspacesMock,
      getWorkspacesItemsMock,
      getTasksMock,
      listDesignPagesMock,
      listKanbanColumnsMock,
    ]) {
      fn.mockReset()
    }
    getWorkspacesMock.mockResolvedValue({ workspaces: WS_LIST })
    getWorkspacesItemsMock.mockImplementation(async (wsId: string) => {
      const items = ITEMS_BY_WS[wsId] ?? []
      return { items: items.map((item) => ({ ...item })), count: items.length }
    })
    getTasksMock.mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    listDesignPagesMock.mockResolvedValue({ pages: [], count: 0 })
    listKanbanColumnsMock.mockResolvedValue({ columns: [], count: 0 })

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
    vi.spyOn(api, 'listDesignPages').mockImplementation(listDesignPagesMock)
    vi.spyOn(api, 'listKanbanColumns').mockImplementation(listKanbanColumnsMock)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('init loads items for the ACTIVE (first) workspace only', async () => {
    const store = useWorkspacesStore()
    await store.init()

    // One items fetch — for ws_1, never for ws_2.
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledWith('ws_1')
    // Per-item tasks follow the same gate.
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenCalledWith('ws_1', 'item_1')

    // Both rows are seeded; only the active one has items.
    expect(store.workspaces).toHaveLength(2)
    expect(store.workspaces[0]!.items.map((i) => i.id)).toEqual(['item_1'])
    expect(store.workspaces[1]!.items).toEqual([])
  })

  it('init prefers the persisted choice over the first workspace', async () => {
    localStorageStub.setItem('pabrik-active-workspace', 'ws_2')

    const store = useWorkspacesStore()
    await store.init()

    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledWith('ws_2')
    expect(store.workspaces[1]!.items.map((i) => i.id)).toEqual(['item_2'])
    expect(store.workspaces[0]!.items).toEqual([])
  })

  it('keeps a lazy-loaded workspace populated when revalidation lands mid-request', async () => {
    localStorageStub.setItem(
      workspacesCacheKey(),
      JSON.stringify([{ id: 'ws_1', name: 'Workspace 1', icon: '📁', items_count: 1 }]),
    )

    let resolveWorkspaces!: (value: { workspaces: typeof WS_LIST }) => void
    getWorkspacesMock.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveWorkspaces = resolve
      }),
    )

    let resolveItems!: (value: { items: WorkspaceItem[]; count: number }) => void
    getWorkspacesItemsMock.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveItems = resolve
      }),
    )

    const store = useWorkspacesStore()
    const initPromise = store.init()
    const selectionPromise = store.setActiveWorkspace('ws_1')
    expect(getWorkspacesItemsMock).toHaveBeenCalledWith('ws_1')

    // Revalidation finishes first and refreshes the cached workspace row
    // while its item request is still in flight.
    resolveWorkspaces({ workspaces: WS_LIST })
    await Promise.resolve()
    resolveItems({ items: ITEMS_BY_WS.ws_1!, count: 1 })
    await Promise.all([initPromise, selectionPromise])

    expect(store.activeWorkspace?.items.map((item) => item.id)).toEqual(['item_1'])
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
  })

  it('init prefers an explicit activeWorkspaceId over the persisted choice', async () => {
    localStorageStub.setItem('pabrik-active-workspace', 'ws_1')

    const store = useWorkspacesStore()
    store.activeWorkspaceId = 'ws_2'
    await store.init()

    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledWith('ws_2')
  })

  it('setActiveWorkspace fetches the target exactly once (dedupe + cache)', async () => {
    const store = useWorkspacesStore()
    await store.init()
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)

    // First switch → one fetch for ws_2.
    await store.setActiveWorkspace('ws_2')
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(getWorkspacesItemsMock).toHaveBeenLastCalledWith('ws_2')
    expect(store.workspaces[1]!.items.map((i) => i.id)).toEqual(['item_2'])

    // Second switch to the SAME workspace → loaded set short-circuits.
    await store.setActiveWorkspace('ws_2')
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)

    // Switching back to ws_1 → in-memory cache, no refetch.
    await store.setActiveWorkspace('ws_1')
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(store.workspaces[0]!.items.map((i) => i.id)).toEqual(['item_1'])
  })

  it('concurrent setActiveWorkspace calls share one in-flight fetch', async () => {
    const store = useWorkspacesStore()
    await store.init()

    await Promise.all([store.setActiveWorkspace('ws_2'), store.setActiveWorkspace('ws_2')])

    // ws_1 (init) + exactly one ws_2 — the second call awaited the
    // in-flight promise instead of starting a second fetch.
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(getWorkspacesItemsMock).toHaveBeenLastCalledWith('ws_2')
  })

  it('setActiveWorkspace ignores unknown ids without fetching', async () => {
    const store = useWorkspacesStore()
    await store.init()

    await store.setActiveWorkspace('ws_missing')

    expect(store.activeWorkspaceId).toBeNull()
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
  })

  it('a failed items fetch is swallowed, leaves [] and retries on next visit', async () => {
    const store = useWorkspacesStore()
    await store.init()

    getWorkspacesItemsMock.mockRejectedValueOnce(new Error('items down'))
    // Never rejects — fire-and-forget callers must not blow up.
    await store.setActiveWorkspace('ws_2')
    expect(store.workspaces[1]!.items).toEqual([])
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)

    // The failure is NOT marked loaded — the next visit retries.
    await store.setActiveWorkspace('ws_2')
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(3)
    expect(store.workspaces[1]!.items.map((i) => i.id)).toEqual(['item_2'])
  })

  it('session SSE events for tasks that are not loaded no-op without throwing', async () => {
    const store = useWorkspacesStore()
    await store.init()

    expect(() => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      __dispatchSseBus('session', { action: 'deleted', id: 'task_ghost' } as any)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      __dispatchSseBus('session', { action: 'updated', id: 'task_ghost', name: 'renamed' } as any)
    }).not.toThrow()
    // The loaded tree is untouched; ws_2 is still lazily empty.
    expect(store.workspaces[0]!.items[0]!.tasks ?? []).toEqual([])
    expect(store.workspaces[1]!.items).toEqual([])
  })

  describe('WorkspaceSwitcher badge source', () => {
    const badgeWs = (overrides: Partial<Workspace>): Workspace => ({
      id: 'ws_x',
      name: 'X',
      icon: '📁',
      expanded: false,
      items: [],
      ...overrides,
    })

    it('renders items_count even when items are [] (unvisited workspace)', async () => {
      const wrapper = mount(WorkspaceSwitcher, {
        props: { workspaces: [badgeWs({ items_count: 7 })], activeWorkspaceId: null },
      })
      await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')

      expect(wrapper.find('[data-testid="workspace-switcher-option-ws_x"]').text()).toContain('7')
    })

    it('falls back to items.length when items_count is absent', async () => {
      const wrapper = mount(WorkspaceSwitcher, {
        props: {
          workspaces: [badgeWs({ items: ITEMS_BY_WS['ws_1'] })],
          activeWorkspaceId: null,
        },
      })
      await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')

      expect(wrapper.find('[data-testid="workspace-switcher-option-ws_x"]').text()).toContain('1')
      expect(wrapper.find('[data-testid="workspace-switcher-option-ws_x"]').text()).not.toContain(
        'undefined',
      )
    })
  })
})
