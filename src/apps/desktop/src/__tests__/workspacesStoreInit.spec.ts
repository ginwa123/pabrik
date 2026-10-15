/**  * Unit tests for the workspaces store's init() flow. Mocks api.getWorkspaces,
 * api.getWorkspacesItems, and api.getTasks to assert the 3-call flow + task-attachment logic. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
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

describe('useWorkspacesStore.init()', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()
  // NEW (auto-expand-design-pages plan, 2026-08-06): init() now fires listDesignPages for every
  // design item in parallel with the tasks fetch.
  // Track it separately so we can assert the new behaviour without polluting the existing tests
  // (which have no design items in their fixtures — listDesignPages should never fire for them).
  const listDesignPagesMock = vi.fn()
  // NEW (kanban-prefetch-on-init plan, 2026-08-06): init() now
  // fires listKanbanColumns + per-column getTasks (with column_id)
  // for every kanban item. Track the new mocks separately.
  const listKanbanColumnsMock = vi.fn()

  // Re-created per beforeEach so tests start with a clean Map. The shared
  // helper just builds the stub; lifecycle is the test's responsibility.
  let localStorageStub: Storage
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    // Reset stub + re-install (beforeEach may run after a previous test cleared it).
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // init() calls installSessionEventHandlers() which uses
    // useSseBus() — install a stub bus before the store's init()
    // runs so the install path doesn't throw.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
    // NEW (auto-expand-design-pages plan): mock listDesignPages so the design-page fetch in init()
    // doesn't hit the network.
    // The default is an empty pages array — tests that want a populated response call
    // listDesignPagesMock.mockResolvedValueOnce(...) per item they expect to be fetched.
    vi.spyOn(api, 'listDesignPages').mockImplementation(listDesignPagesMock)
    // NEW (kanban-prefetch-on-init plan): mock listKanbanColumns so
    // the kanban-columns fetch in init() doesn't hit the network.
    vi.spyOn(api, 'listKanbanColumns').mockImplementation(listKanbanColumnsMock)
    // Reset call history so toHaveBeenCalledTimes assertions stay
    // scoped to a single test. vi.restoreAllMocks() (in afterEach)
    // restores spy implementations but does NOT clear vi.fn()
    // call history, so without this the second test sees the first
    // test's calls and the call-count assertion below flakes.
    listDesignPagesMock.mockClear()
    listKanbanColumnsMock.mockClear()
    // getTasks is reused for per-column kanban task fetches. Clear its call history too so the
    // kanban-prefetch tests can assert call counts for column_id-tagged calls without seeing the
    // earlier board-wide tests' state.
    getTasksMock.mockClear()
  })

  // Helper for design-item fixtures: produces the shape the backend returns so we can assert
  // against `design_pages` and the `item_type === 'design'` branch in init() without breaking
  // existing tests.
  function makeDesignItem(overrides: Record<string, unknown> = {}) {
    return {
      id: 'item_design',
      name: 'design',
      item_type: 'design',
      workspace_id: 'ws_1',
      // Other fields the in-memory WorkspaceItem type requires —
      // init() doesn't read them so we can pass empty values.
      ...overrides,
    }
  }

  // Helper for kanban-item fixtures. Mirrors makeDesignItem but
  // uses item_type='kanban' so init() routes it through the
  // kanban-prefetch fan-out.
  function makeKanbanItem(overrides: Record<string, unknown> = {}) {
    return {
      id: 'item_kanban',
      name: 'kanban',
      item_type: 'kanban',
      workspace_id: 'ws_1',
      // kanban_columns are populated by listKanbanColumns in init(); start with an empty array so
      // the per-column fetches have no work to do unless the test stubs a populated columns
      // response.
      kanban_columns: [],
      tasks: [],
      ...overrides,
    }
  }

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('fetches the workspace list, then items + tasks for the ACTIVE workspace only', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [
        { id: 'ws_1', name: 'Workspace 1', icon: '📁' },
        { id: 'ws_2', name: 'Workspace 2', icon: '📁' },
      ],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [{ id: 'item_1a', name: 'A' }],
      count: 1,
    })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(getWorkspacesMock).toHaveBeenCalledTimes(1)
    // Lazy loading (2026-09-22 revamp plan): only the active workspace (first row — no
    // explicit/persisted choice here) is fetched; the other row stays seeded-empty until visited
    // via ensureWorkspaceItemsLoaded.
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(1, 'ws_1')
    expect(store.workspaces.find((ws) => ws.id === 'ws_2')!.items).toEqual([])
    // item_1a triggers one getTasks call — per-item tasks follow the
    // same active-only gate.
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenCalledWith('ws_1', 'item_1a')
  })

  it('attaches tasks from getTasks(wsId, itemId) to the matching item', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_a', name: 'A' },
        { id: 'item_b', name: 'B' },
      ],
      count: 2,
    })
    // Tasks for item_a
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        { id: 't1', name: 'T1', workspace_item_id: 'item_a' },
        { id: 't2', name: 'T2', workspace_item_id: 'item_a' },
      ],
      has_more: false,
      next_cursor: null,
    })
    // Tasks for item_b
    getTasksMock.mockResolvedValueOnce({
      tasks: [{ id: 't3', name: 'T3', workspace_item_id: 'item_b' }],
      has_more: false,
      next_cursor: null,
    })

    const store = useWorkspacesStore()
    await store.init()

    const items = store.workspaces[0]!.items
    expect(items).toHaveLength(2)
    const itemA = items.find((i) => i.id === 'item_a')!
    const itemB = items.find((i) => i.id === 'item_b')!
    expect(itemA.tasks).toHaveLength(2)
    expect(itemA.tasks!.map((t) => t.id).sort()).toEqual(['t1', 't2'])
    expect(itemB.tasks).toHaveLength(1)
    expect(itemB.tasks![0]!.id).toBe('t3')
  })

  it('restores expanded state from localStorage for workspaces and items', async () => {
    localStorage.setItem('pabrik-workspace-expanded', JSON.stringify(['ws_1']))
    localStorage.setItem('pabrik-workspace-item-expanded', JSON.stringify(['item_1a']))

    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [{ id: 'item_1a', name: 'A' }],
      count: 1,
    })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces[0]!.expanded).toBe(true)
    expect(store.workspaces[0]!.items[0]!.expanded).toBe(true)
  })

  it('falls back to empty workspaces array when init fails', async () => {
    getWorkspacesMock.mockRejectedValueOnce(new Error('network down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toEqual([])
    expect(store.loadingError).toBe('network down')
    expect(store.isLoading).toBe(false)
  })

  it('keeps the workspace with empty tasks when a per-item tasks fetch fails', async () => {
    // Per-item task failure is non-fatal (logged + best-effort).
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_a', name: 'A' }], count: 1 })
    getTasksMock.mockRejectedValueOnce(new Error('tasks down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0]!.items[0]!.tasks).toEqual([])
    expect(store.loadingError).toBeNull()
  })

  // NEW (auto-expand-design-pages plan, 2026-08-06): init() must fetch design pages for every
  // design item in parallel with the tasks fetch.
  // The pre-fix code only fired listDesignPages lazily on chevron click — which meant a refresh
  // left the sidebar's design-pages section empty until the user clicked the design item's chevron.
  // The user's report ("see workspace design, when refresh its empty, but when i click it the
  // header it show, can you make all of that instant open") is exactly this regression.
  // The fix awaits the fetch in init() so the sidebar's <DesignPageRow> children render populated
  // as soon as init() resolves.

  it('fetches design pages for every design item in init()', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        makeDesignItem({ id: 'item_design_a', name: 'design A' }),
        { id: 'item_folder_b', name: 'folder B', item_type: 'folder' },
        makeDesignItem({ id: 'item_design_c', name: 'design C' }),
      ],
      count: 3,
    })
    // Two design items → two listDesignPages calls. Folder item does
    // NOT fire listDesignPages.
    listDesignPagesMock
      .mockResolvedValueOnce({
        pages: [
          { id: 'page_a1', workspace_item_id: 'item_design_a', name: 'A1', position: 0 },
          { id: 'page_a2', workspace_item_id: 'item_design_a', name: 'A2', position: 1 },
        ],
        count: 2,
      })
      .mockResolvedValueOnce({
        pages: [{ id: 'page_c1', workspace_item_id: 'item_design_c', name: 'C1', position: 0 }],
        count: 1,
      })

    const store = useWorkspacesStore()
    await store.init()

    // One listDesignPages call per design item — never for non-design.
    expect(listDesignPagesMock).toHaveBeenCalledTimes(2)
    expect(listDesignPagesMock).toHaveBeenNthCalledWith(1, 'ws_1', 'item_design_a')
    expect(listDesignPagesMock).toHaveBeenNthCalledWith(2, 'ws_1', 'item_design_c')
    // Sidebar's <DesignPageRow> reads from this cache; populated
    // entries mean the rows will render as soon as init() resolves.
    expect(store.designPagesByItemId['item_design_a']).toHaveLength(2)
    expect(store.designPagesByItemId['item_design_c']).toHaveLength(1)
    expect(store.designPagesByItemId['item_design_a']?.[0]?.id).toBe('page_a1')
    expect(store.designPagesByItemId['item_design_c']?.[0]?.id).toBe('page_c1')
  })

  it('does NOT fire listDesignPages for non-design items in init()', async () => {
    // Belt-and-braces: the folder item in the previous test never triggered a listDesignPages call.
    // This test makes that contract explicit so a future refactor doesn't accidentally broaden the
    // filter and fetch pages for, e.g., kanban items.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_folder', name: 'folder', item_type: 'folder' },
        { id: 'item_chat', name: 'chat', item_type: 'chat' },
        { id: 'item_kanban', name: 'kanban', item_type: 'kanban' },
      ],
      count: 3,
    })

    const store = useWorkspacesStore()
    await store.init()

    // Zero design items → zero listDesignPages calls.
    expect(listDesignPagesMock).toHaveBeenCalledTimes(0)
    expect(store.designPagesByItemId).toEqual({})
  })

  it('keeps the workspace when a per-design-item pages fetch fails', async () => {
    // Best-effort contract — same as the per-item tasks fetch. A single bad listDesignPages call
    // logs and leaves the cache empty for that item, but the workspace tree still loads. The
    // chevron-toggle lazy fetch in WorkspaceItem.vue is the fallback that retries the failing item.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [makeDesignItem({ id: 'item_design_a' }), makeDesignItem({ id: 'item_design_b' })],
      count: 2,
    })
    // First design item succeeds, second rejects.
    listDesignPagesMock
      .mockResolvedValueOnce({
        pages: [{ id: 'page_a', workspace_item_id: 'item_design_a', name: 'A', position: 0 }],
        count: 1,
      })
      .mockRejectedValueOnce(new Error('pages down'))

    const store = useWorkspacesStore()
    await store.init()

    // Init didn't throw and the workspace tree is intact.
    expect(store.loadingError).toBeNull()
    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0]!.items).toHaveLength(2)
    // Succeeded design item: cache populated.
    expect(store.designPagesByItemId['item_design_a']).toHaveLength(1)
    // Failed design item: cache entry absent (fetchDesignPages
    // never assigned to designPagesByItemId on rejection).
    expect(store.designPagesByItemId['item_design_b']).toBeUndefined()
  })

  it('init populates the cache before isLoading flips to false (instant open)', async () => {
    // The whole point of the fix: when init() resolves, the sidebar's design-pages section should
    // be ready to render with the page list — no "click the chevron to populate" gate.
    // Verify by checking that store.designPagesByItemId is populated at the exact moment isLoading
    // transitions to false.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [makeDesignItem({ id: 'item_design' })],
      count: 1,
    })
    listDesignPagesMock.mockResolvedValueOnce({
      pages: [
        { id: 'page_1', workspace_item_id: 'item_design', name: 'AI Chat View', position: 0 },
      ],
      count: 1,
    })

    const store = useWorkspacesStore()
    expect(store.isLoading).toBe(false) // before init
    await store.init()
    // After init() resolves, isLoading is false AND the cache is populated.
    expect(store.isLoading).toBe(false)
    expect(store.designPagesByItemId['item_design']).toHaveLength(1)
    expect(store.designPagesByItemId['item_design']?.[0]?.name).toBe('AI Chat View')
  })

  // NEW (kanban-prefetch-on-init plan, 2026-08-06): init() must fire per-column task fetches for
  // every kanban item so the board renders populated when the user clicks the kanban (matches the
  // design-pages eager-fetch contract).
  // Pre-fix, KanbanView's onMount was responsible for these fetches — meaning a click on a kanban
  // showed columns-with-counts but empty bodies until the fetches landed. The user reported
  // "spinner is show after i click a kanban workspace" — exactly this gap.
  // The fix awaits the fetches in init() so the kanban renders fully when isLoading flips to false.

  it('fetches kanban columns + per-column tasks for every kanban item in init()', async () => {
    // 1 kanban item with 2 columns → 1 listKanbanColumns call +
    // 2 getTasks calls (one per column, both with column_id set).
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        makeKanbanItem({ id: 'item_kanban_a' }),
        { id: 'item_folder', name: 'folder', item_type: 'folder' },
      ],
      count: 2,
    })
    listKanbanColumnsMock.mockResolvedValueOnce({
      columns: [
        { id: 'col_a', workspace_item_id: 'item_kanban_a', name: 'todo', position: 0 },
        { id: 'col_b', workspace_item_id: 'item_kanban_a', name: 'done', position: 1 },
      ],
      count: 2,
    })
    // Mock the board-wide fetch for the folder item (which fires in the existing tasks block
    // because folder is not kanban/design). This must be queued FIRST because Promise.all runs in
    // parallel — the order of consumption is non-deterministic from the test's perspective.
    // Without this mock, one of the 3 total getTasks calls returns undefined and the destructure
    // throws.
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })
    // 2 per-column task fetches — each with a unique column_id.
    getTasksMock
      .mockResolvedValueOnce({
        tasks: [
          {
            id: 'task_a1',
            name: 'A1',
            workspace_item_id: 'item_kanban_a',
            kanban_column_id: 'col_a',
          },
        ],
        has_more: false,
        next_cursor: null,
      })
      .mockResolvedValueOnce({
        tasks: [
          {
            id: 'task_b1',
            name: 'B1',
            workspace_item_id: 'item_kanban_a',
            kanban_column_id: 'col_b',
          },
          {
            id: 'task_b2',
            name: 'B2',
            workspace_item_id: 'item_kanban_a',
            kanban_column_id: 'col_b',
          },
        ],
        has_more: false,
        next_cursor: null,
      })

    const store = useWorkspacesStore()
    await store.init()

    // 1 listKanbanColumns call for the kanban item — never for the folder.
    expect(listKanbanColumnsMock).toHaveBeenCalledTimes(1)
    expect(listKanbanColumnsMock).toHaveBeenNthCalledWith(1, 'ws_1', 'item_kanban_a')
    // Filter getTasks calls to the KANBAN branch: every getTasks call from the kanban-prefetch
    // block passes column_id as the 7th argument (after wsId, itemId, limit, cursor, sortBy,
    // direction).
    // The board-wide fetch (for the folder item) does NOT pass column_id — only 5 positional args.
    // So we assert that exactly 2 column_id-tagged calls fire — one per kanban column.
    const kanbanCalls = getTasksMock.mock.calls.filter(
      (call) => call[6] !== undefined, // 7th arg = column_id
    )
    expect(kanbanCalls).toHaveLength(2)
    expect(kanbanCalls[0]).toEqual([
      'ws_1',
      'item_kanban_a',
      10, // limit
      undefined, // cursor — page 1
      undefined, // sortBy — default sort
      undefined, // direction — default sort
      'col_a', // column_id — per-column filter
      undefined, // q — no search
    ])
    expect(kanbanCalls[1]).toEqual([
      'ws_1',
      'item_kanban_a',
      10,
      undefined,
      undefined,
      undefined,
      'col_b',
      undefined,
    ])
    // Cache populated — kanban_columns has the loaded columns,
    // item.tasks has the merged tasks from both columns.
    const item = store.workspaces[0]!.items.find((i) => i.id === 'item_kanban_a')!
    expect(item.kanban_columns).toHaveLength(2)
    expect(item.tasks).toHaveLength(3)
    expect(item.tasks!.map((t) => t.id).sort()).toEqual(['task_a1', 'task_b1', 'task_b2'])
    // columnPagination entries are set so the onMount path
    // (KanbanView.loadColumnsAndTasks) sees them as already
    // fetched — its `needFetch` filter excludes them.
    expect(item.columnPagination).toBeDefined()
    expect(item.columnPagination!['col_a']?.hasMore).toBe(false)
    expect(item.columnPagination!['col_b']?.hasMore).toBe(false)
  })

  it('does NOT fire kanban fetches for non-kanban items in init()', async () => {
    // Regression guard: a future refactor must not broaden the
    // filter to fetch kanban columns for folder/chat/design items.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_folder', name: 'folder', item_type: 'folder' },
        { id: 'item_chat', name: 'chat', item_type: 'chat' },
        makeDesignItem({ id: 'item_design' }),
      ],
      count: 3,
    })
    // Mock the BOARD-WIDE getTasks fires for folder + chat. The design item skips it (design has no
    // tasks list per the design-pages-in-workspace-tree plan, 2026-08-06).
    // The assertion below isolates the KANBAN branch by checking the call shape — kanban fetches
    // must include column_id, board-wide fetches don't.
    getTasksMock.mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    listDesignPagesMock.mockResolvedValueOnce({
      pages: [{ id: 'page_x', workspace_item_id: 'item_design', name: 'X', position: 0 }],
      count: 1,
    })

    const store = useWorkspacesStore()
    await store.init()

    // Zero kanban items → zero listKanbanColumns calls. The kanban
    // branch is gated on item_type === 'kanban'; a future refactor
    // that broadens the filter would be caught here.
    expect(listKanbanColumnsMock).toHaveBeenCalledTimes(0)
    // Filter getTasks calls to the KANBAN branch: every getTasks call from the kanban-prefetch
    // block passes column_id as the 7th argument. The board-wide fetch (folder + chat) does NOT
    // pass column_id. So we assert zero column_id-tagged calls.
    const kanbanCalls = getTasksMock.mock.calls.filter(
      (call) => call[6] !== undefined, // 7th arg = column_id
    )
    expect(kanbanCalls).toHaveLength(0)
  })

  it('keeps the workspace when a per-column kanban fetch fails', async () => {
    // Best-effort contract — same as the per-item tasks fetch. A single bad column fetch logs and
    // leaves that column's pagination entry missing, but the workspace tree still loads and other
    // columns' tasks populate.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [makeKanbanItem({ id: 'item_kanban' })],
      count: 1,
    })
    listKanbanColumnsMock.mockResolvedValueOnce({
      columns: [
        { id: 'col_a', workspace_item_id: 'item_kanban', name: 'A', position: 0 },
        { id: 'col_b', workspace_item_id: 'item_kanban', name: 'B', position: 1 },
      ],
      count: 2,
    })
    // First column succeeds, second rejects. The try/catch in
    // init()'s kanban block logs the error but doesn't fail init.
    getTasksMock
      .mockResolvedValueOnce({
        tasks: [
          { id: 'task_a', name: 'A', workspace_item_id: 'item_kanban', kanban_column_id: 'col_a' },
        ],
        has_more: false,
        next_cursor: null,
      })
      .mockRejectedValueOnce(new Error('column b down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.loadingError).toBeNull()
    const item = store.workspaces[0]!.items.find((i) => i.id === 'item_kanban')!
    expect(item.tasks).toHaveLength(1)
    expect(item.tasks![0]?.id).toBe('task_a')
    // col_a pagination entry set; col_b NOT set (failed fetch).
    expect(item.columnPagination!['col_a']).toBeDefined()
    expect(item.columnPagination!['col_b']).toBeUndefined()
  })

  it('init populates the kanban cache before isLoading flips to false (instant open)', async () => {
    // The "instant open" invariant — when init() resolves, the kanban item's tasks should be ready
    // to render without needing a click.
    // The KanbanView onMount's `needFetch` filter uses the columnPagination entries to skip
    // already-fetched columns, so this test verifies both: (a) the cache is populated at init()
    // resolve time, and (b) the pagination entries gate the onMount re-fetch path.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [makeKanbanItem({ id: 'item_kanban' })],
      count: 1,
    })
    listKanbanColumnsMock.mockResolvedValueOnce({
      columns: [{ id: 'col_a', workspace_item_id: 'item_kanban', name: 'A', position: 0 }],
      count: 1,
    })
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        { id: 'task_a', name: 'A', workspace_item_id: 'item_kanban', kanban_column_id: 'col_a' },
      ],
      has_more: false,
      next_cursor: null,
    })

    const store = useWorkspacesStore()
    expect(store.isLoading).toBe(false) // before init
    await store.init()
    expect(store.isLoading).toBe(false) // after init
    const item = store.workspaces[0]!.items.find((i) => i.id === 'item_kanban')!
    expect(item.tasks).toHaveLength(1)
    expect(item.tasks![0]?.id).toBe('task_a')
    expect(item.columnPagination!['col_a']).toBeDefined()
  })
})
