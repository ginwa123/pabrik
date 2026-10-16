/** Behavioural tests for the workspaces store's per-column pagination (plan
 * 2026-08-06-kanban-per-column-pagination.md, Task 8). Replaces the old board-wide `loadMoreTasks`
 * tests with the new per-column `loadMoreTasksForColumn` action. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
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

const baseItem = {
  id: 'item_1a',
  name: 'Test Kanban',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: 'item_1a', position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'in_progress', workspace_item_id: 'item_1a', position: 1, created_at: '2026-01-01' },
  ],
}

const baseWorkspace = {
  id: 'ws_1',
  name: 'Workspace 1',
  icon: '📁',
}

const seedTasks = (count: number, prefix = 't', columnId?: string) =>
  Array.from({ length: count }, (_, i) => ({
    id: `${prefix}${i + 1}`,
    name: `Task ${i + 1}`,
    workspace_item_id: 'item_1a',
    task_type: 'standard',
    created_at: `2026-06-10T10:0${i}:00.000Z`,
    kanban_column_id: columnId,
    kanban_position: i,
  }))

describe('useWorkspacesStore.loadMoreTasksForColumn() — per-column pagination', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()

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

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    getWorkspacesMock.mockClear()
    getWorkspacesItemsMock.mockClear()
    getTasksMock.mockClear()

    // Mock the column fetch so the kanban_columns are populated —
    // they're not strictly required for these tests but the store
    // may fetch them as part of init().
    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  // Helper: run init() + a per-column fetch (Option B) with the
  // given first-page result so the store is in a "first page loaded"
  // state. Returns the store.
  async function initWithFirstPage(firstPage: {
    tasks: ReturnType<typeof seedTasks>
    has_more: boolean
    next_cursor: string | null
  }) {
    getWorkspacesMock.mockResolvedValueOnce({ workspaces: [baseWorkspace] })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [baseItem], count: 1 })
    // init() now skips kanban items (Option B — per-column init via KanbanView onMount). We fire
    // the per-column fetch directly to seed the store state. The `firstPage.tasks` MUST have a
    // consistent `kanban_column_id` (all of one column) since the backend filters per column.
    const store = useWorkspacesStore()
    await store.init()
    // Detect the column from the first task's kanban_column_id, fall
    // back to col_a for backwards compatibility.
    const colId = firstPage.tasks[0]?.kanban_column_id ?? 'col_a'
    getTasksMock.mockResolvedValueOnce(firstPage)
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', colId, 10, undefined, undefined,
    )
    return store
  }

  it('fetchKanbanTasks populates columnPagination[col] for the fetched column (Option B per-column)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
        icon: '📁',
         
        expanded: false,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        items: [baseItem as any],
      },
    ]
    // Option B: fetch returns ONLY the column's tasks (backend filters by column_id server-side).
    // col_b is NOT in the response — its columnPagination entry stays undefined until a separate
    // fetch for col_b fires.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    await store.fetchKanbanTasks('ws_1', 'item_1a', 'col_a', 10, undefined, undefined)

    const item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination).toBeDefined()
    expect(item.columnPagination!['col_a']).toBeDefined()
    expect(item.columnPagination!['col_a']!.hasMore).toBe(true)
    expect(item.columnPagination!['col_a']!.cursor).toBe('cursor_1')
    expect(item.columnPagination!['col_a']!.isLoading).toBe(false)
    // col_b is untouched (we only fetched col_a).
    expect(item.columnPagination!['col_b']).toBeUndefined()
    // Only col_a's tasks are present (no cross-column leak).
    expect(item.tasks).toHaveLength(2)
    expect(item.tasks!.every((t) => t.kanban_column_id === 'col_a')).toBe(true)
  })

  it('fetchKanbanTasks replaces tasks for the same column on a re-fetch (refresh semantics)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
         
        icon: '📁',
        expanded: false,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        items: [{ ...baseItem, tasks: seedTasks(2, 'a_old', 'col_a') } as any],
      },
    ]

    // New fetch for col_a — replaces the previous 2 col_a tasks.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(3, 'a_new', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.fetchKanbanTasks('ws_1', 'item_1a', 'col_a', 10, undefined, undefined)

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toHaveLength(3)
    expect(item.tasks!.map((t) => t.id)).toEqual(['a_new1', 'a_new2', 'a_new3'])
    // col_a's pagination state reflects the new cursor + hasMore.
    expect(item.columnPagination!['col_a']!.hasMore).toBe(false)
    expect(item.columnPagination!['col_a']!.cursor).toBeNull()
  })

  it('fetchKanbanTasks preserves tasks from OTHER columns when fetching a different column', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [{
          ...baseItem,
          tasks: [
             
            ...seedTasks(2, 'a', 'col_a'),
            ...seedTasks(2, 'b', 'col_b'),
          ],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any],
      },
    ]

    // Fetch col_a ONLY — col_b's tasks should NOT be touched.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a_new', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.fetchKanbanTasks('ws_1', 'item_1a', 'col_a', 10, undefined, undefined)

    const item = store.workspaces[0]!.items[0]!
    // 1 col_a task + 2 col_b tasks preserved = 3 total
    expect(item.tasks).toHaveLength(3)
    expect(item.tasks!.filter((t) => t.kanban_column_id === 'col_a')).toHaveLength(1)
    expect(item.tasks!.filter((t) => t.kanban_column_id === 'col_b')).toHaveLength(2)
  })

  it('fetchKanbanTasks is a no-op when the workspace or item does not exist', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
         
        id: 'ws_1',
        name: 'ws',
        icon: '📁',
        expanded: false,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        items: [baseItem as any],
      },
    ]
    expect(getTasksMock).toHaveBeenCalledTimes(0)

    // Bad workspace id
    await store.fetchKanbanTasks('ws_does_not_exist', 'item_1a', 'col_a', 10)
    // Bad item id
    await store.fetchKanbanTasks('ws_1', 'item_does_not_exist', 'col_a', 10)

    // No fetches in either case
    expect(getTasksMock).toHaveBeenCalledTimes(0)
  })

  it('loadMoreTasksForColumn calls api.getTasks with column_id=the column id', async () => {
    const store = await initWithFirstPage({
      tasks: [...seedTasks(2, 'a', 'col_a'), ...seedTasks(1, 'b', 'col_b')],
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    expect(getTasksMock).toHaveBeenCalledTimes(2)
    const lastCall = getTasksMock.mock.calls[1]!
    // Arg positions: workspaceId, itemId, limit, cursor, sortBy, direction, columnId, q
    expect(lastCall[0]).toBe('ws_1')
    expect(lastCall[1]).toBe('item_1a')
    expect(lastCall[2]).toBe(10) // PAGE_SIZE
    expect(lastCall[3]).toBe('cursor_1') // the previous next_cursor
    expect(lastCall[6]).toBe('col_a') // columnId — the new arg
  })

  it('loadMoreTasksForColumn appends returned tasks to item.tasks', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toHaveLength(4)
    expect(item.tasks!.map((t) => t.id)).toEqual(['a1', 'a2', 'a21', 'a22'])
  })

  it('loadMoreTasksForColumn updates columnPagination[col].cursor + .hasMore', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination!['col_a']!.cursor).toBeNull()
    expect(item.columnPagination!['col_a']!.hasMore).toBe(false)
    expect(item.columnPagination!['col_a']!.isLoading).toBe(false)
  })

  it('loadMoreTasksForColumn is a no-op when hasMore=false (no second fetch)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: false, // global: no more
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    // Only the init fetch happened.
    expect(getTasksMock).toHaveBeenCalledTimes(1)
  })

  it('loadMoreTasksForColumn is a no-op while isLoading=true (no double-click)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // Simulate an in-flight load.
    store.workspaces[0]!.items[0]!.columnPagination!['col_a']!.isLoading = true

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    expect(getTasksMock).toHaveBeenCalledTimes(1) // guard fired
  })

  it('loadMoreTasksForColumn forwards the per-item active sort (name + desc) on the API call', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // User picks 'name' / 'desc' on the kanban view. fetchKanbanTasks
    // records the active sort.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', 'col_a', 10, undefined, undefined,
      'name', 'desc',
    )

    // User clicks "Load more" for col_a — must forward 'name' / 'desc'.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[4]).toBe('name') // sortBy
    expect(lastCall[5]).toBe('desc') // direction
  })

  it('loadMoreTasksForColumn forwards the active q (search query) on the API call', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // User types 'login' in the search box. fetchKanbanTasks records it.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', 'col_a', 10, undefined, 'login',
    )

    // User clicks "Load more" for col_a — must forward q='login'.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[7]).toBe('login') // q (search query) — the 8th arg
  })

  it('loadMoreTasksForColumn on error: leaves hasMore + cursor untouched (retry-by-click still works)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockRejectedValueOnce(new Error('network down'))
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    // hasMore + cursor unchanged so the user can retry.
    expect(item.columnPagination!['col_a']!.hasMore).toBe(true)
    expect(item.columnPagination!['col_a']!.cursor).toBe('cursor_1')
    // isLoading flipped back to false (the catch block's finally resumes).
    expect(item.columnPagination!['col_a']!.isLoading).toBe(false)
  })

  it('loadMoreTasksForColumn is a no-op when the column has no pagination state', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // col_unknown never appeared in the initial fetch — no pagination state.
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_unknown')

    expect(getTasksMock).toHaveBeenCalledTimes(1) // guard fired
  })
})
