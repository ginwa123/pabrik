/**
 * Behavioural tests for KanbanView's per-column-sort + URL persistence +
 * per-column backend fetch wiring.
 *
 * Plan (kanban-sort-independence, take 2, 2026-08-06):
 *  - Each KanbanColumn has its own sortBy + direction (already done).
 *  - When a column's sort changes, the column emits `sort-change` with
 *    the new sortBy + direction. KanbanView's `handleColumnSortChange`
 *    listens and:
 *      a) fires `fetchKanbanTasks(col_id, sortBy, direction)` for ONLY
 *         that column — other columns' data is untouched.
 *      b) updates the URL: `?sorts=col_<id>:<sortBy>:<direction>,...`
 *  - On mount, KanbanView parses the URL's `sorts` param and applies
 *    each column's sort via setSortMode (defineExpose seam) + fires
 *    per-column `fetchKanbanTasks` for the columns mentioned in the
 *    URL.
 *
 * The CRITICAL user requirement (kanban-sort-independence): "only
 * column A endpoint that called, other column should not call
 * endpoint" — when the user picks a sort in one column, only THAT
 * column's fetch fires. The watcher's only job is URL persistence.
 *
 * URL format:
 *   ?sorts=col_1:name:asc,col_2:created_at:desc,col_3:updated_at:asc
 * Comma-separated; each entry is `col_<id>:<sortBy>:<direction>`.
 * Default sorts (position + asc) are OMITTED to keep URLs clean.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import { nextTick } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'

const WS_ID = 'ws_sortapi'
const ITEM_ID = 'item_sortapi'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'SortByApi Kanban',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    {
      id: 'col_a',
      name: 'todo',
      workspace_item_id: ITEM_ID,
      position: 0,
      created_at: '2026-01-01',
    },
    {
      id: 'col_b',
      name: 'in_progress',
      workspace_item_id: ITEM_ID,
      position: 1,
      created_at: '2026-01-01',
    },
  ],
  tasks: [],
  // NOTE (kanban-sort-independence, 2026-08-06, onmount single-fetch): tests that want to assert on
  // the per-column fetch from `loadColumnsAndTasks` (URL restore) should NOT pre-populate
  // columnPagination — that would skip the fetch.
  // Tests that want to assert on click-only fetches (e.g. the "picking a sort" describe block) DO
  // pre-populate so the initial mount's fetch doesn't muddy the assertion. See each describe block
  // for its setup.
  columnPagination: {},
  ...overrides,
})

const makeTask = (id: string, name: string, kanbanPosition: number): Task => ({
  id,
  name,
  task_type: 'standard',
  kanban_column_id: 'col_a',
  kanban_position: kanbanPosition,
  createdAt: new Date('2024-01-01T00:00:00Z'),
  updatedAt: new Date('2024-01-01T00:00:00Z'),
})

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

function mountKanbanView(query: Record<string, string> = {}, opts: { item?: WorkspaceItem } = {}) {
  useRouteMock.mockReturnValue({
    query,
    path: '/app',
    fullPath: '/app',

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const item = opts.item ?? makeItem()
  const store = useWorkspacesStore()
  store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]

  const replaceMock = vi.fn()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
  const wrapper = mount(KanbanView, {
    props: { item, workspaceId: WS_ID },
  })
  return { wrapper, replaceMock }
}

describe('KanbanView — per-column sort triggers API call (only the changed column)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('picking "Created (oldest)" on column A fires fetchKanbanTasks for col_a only (col_b is NOT called)', async () => {
    // The CRITICAL user-reported bug (kanban-sort-independence, take 2): "only column a endpoint
    // that called, other column should not call endpoint".
    // Before this fix, the watcher called fetchKanbanTasksForAllColumns which fired N parallel
    // requests (one per column) — all with the same sort_by. Now only the changed column's fetch
    // fires.
    // Pre-populate columnPagination so the initial mount's loadColumnsAndTasks doesn't fire its own
    // per-column fetch (which would muddy this click-isolation assertion). The click handler's
    // per-column fetch is the ONLY fetchKanbanTasks call in this test.
    const item = makeItem({
      columnPagination: {
        col_a: { cursor: null, hasMore: false, isLoading: false },
        col_b: { cursor: null, hasMore: false, isLoading: false },
      },
    })
    const store = useWorkspacesStore()
    const fetchAllSpy = vi.spyOn(store, 'fetchKanbanTasksForAllColumns').mockResolvedValue()
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper } = mountKanbanView(
      {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
      { item },
    )

    // Open the ⋮ menu on col_a, click Sort tasks…, pick "Oldest".
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-created-asc"]').trigger('click')
    await flushPromises()

    // fetchKanbanTasks was called for col_a with sortBy='created_at', direction='asc'.
    // Signature: (ws, item, columnId, limit, cursor, q, sortBy, direction).
    // col_id is index 2, sortBy is index 6, direction is index 7.
    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBeGreaterThan(0)
    const lastColACall = colACalls[colACalls.length - 1]!
    expect(lastColACall[6]).toBe('created_at')
    expect(lastColACall[7]).toBe('asc')

    // CRITICAL: col_b's endpoint was NOT called.
    const colBCalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_b')
    expect(colBCalls.length).toBe(0)

    // And the "all columns" helper was NOT used (we don't fan out
    // fetches on click — each click is single-column).
    expect(fetchAllSpy).not.toHaveBeenCalled()
  })

  it('picking "Manual" on column A fires fetchKanbanTasks for col_a with no sortBy param (backend default)', async () => {
    // Default sort (position + asc) has no server-side equivalent
    // — fetch with no sortBy param. Backend uses its default
    // ORDER BY (kanban_position asc).
    const store = useWorkspacesStore()
    // Pre-populate columnPagination so the initial mount's
    // loadColumnsAndTasks doesn't fire its own per-column fetch.
    const item = makeItem({
      columnPagination: {
        col_a: { cursor: null, hasMore: false, isLoading: false },
        col_b: { cursor: null, hasMore: false, isLoading: false },
      },
    })
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper } = mountKanbanView(
      {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
      { item },
    )

    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-position"]').trigger('click')
    await flushPromises()

    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBeGreaterThan(0)
    const lastColACall = colACalls[colACalls.length - 1]!
    // sortBy/direction are undefined for the default sort
    expect(lastColACall[6]).toBeUndefined()
    expect(lastColACall[7]).toBeUndefined()
  })

  it('clicking a different sort on column A fires fetchKanbanTasks again for col_a (replaces previous)', async () => {
    // Two clicks on the same column → two fetches. The second fetch
    // replaces the column's local tasks slice (see fetchKanbanTasks
    // implementation: `otherTasks = item.tasks.filter(t => t.kanban_column_id !== colId)`).
    const store = useWorkspacesStore()
    // Pre-populate columnPagination so the initial mount's
    // loadColumnsAndTasks doesn't fire its own per-column fetch.
    const item = makeItem({
      columnPagination: {
        col_a: { cursor: null, hasMore: false, isLoading: false },
        col_b: { cursor: null, hasMore: false, isLoading: false },
      },
    })
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper } = mountKanbanView(
      {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
      { item },
    )

    // First sort: name asc
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    // Second sort: name desc
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-desc"]').trigger('click')
    await flushPromises()

    // Two fetches, both for col_a. First with name+asc, second with name+desc.
    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBe(2)
    expect(colACalls[0]![6]).toBe('name')
    expect(colACalls[0]![7]).toBe('asc')
    expect(colACalls[1]![6]).toBe('name')
    expect(colACalls[1]![7]).toBe('desc')
  })
})

describe('KanbanView — URL persistence of per-column sorts', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('picking a sort on column A updates the URL with col_a sort, omits col_b', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] }]
    vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper, replaceMock } = mountKanbanView({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })

    await wrapper.find(`[data-testid="kanban-column-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-col_a-menu-sort"]`).trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    // The URL got a `sorts=col_a:name:asc` query param.
    expect(replaceMock).toHaveBeenCalled()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]!
    const query = lastCall[0].query as Record<string, string>
    expect(query.sorts).toContain('col_a:name:asc')
  })

  it('picking a sort preserves the ?layout= row-mode param', async () => {
    // Regression guard: the sorts watcher used to rebuild the query from scratch, which dropped
    // every sibling param — including the layout switch, so picking a column sort silently snapped
    // the board back to column mode.
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] }]
    vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    const { wrapper, replaceMock } = mountKanbanView({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      layout: 'rows',
    })

    // Switch to rows first so the ref is authoritative, then sort.
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()
    await wrapper.find(`[data-testid="kanban-row-group-col_a-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-row-group-col_a-menu-sort"]`).trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]!
    const query = lastCall[0].query as Record<string, string>
    expect(query.sorts).toContain('col_a:name:asc')
    expect(query.layout).toBe('rows')
  })
})

describe('KanbanView — URL restore fires per-column fetchKanbanTasks', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('mount with ?sorts=col_a:name:asc fires fetchKanbanTasks for col_a with sortBy=name', async () => {
    // User lands on the kanban with a URL carrying a per-column sort. KanbanView's onMount parses
    // the URL, calls setSortMode on each column, and fires fetchKanbanTasks for ONLY the columns
    // mentioned in the URL.
    const item = makeItem({
      tasks: [makeTask('t_z', 'Zeta', 0), makeTask('t_a', 'Alpha', 1)],
    })
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
        sorts: 'col_a:name:asc',
      },

      path: '/app',
      fullPath: '/app',

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)

    const wrapper = mount(KanbanView, {
      props: { item, workspaceId: WS_ID },
    })

    await flushPromises()
    await new Promise((resolve) => setTimeout(resolve, 50))
    await flushPromises()

    // col_a's fetch fires with sortBy=name, direction=asc.
    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBeGreaterThan(0)
    const lastColACall = colACalls[colACalls.length - 1]!
    expect(lastColACall[6]).toBe('name')
    expect(lastColACall[7]).toBe('asc')

    // col_b's fetch ALSO fires (regression fix 2026-08-06: other columns should NOT stay empty when
    // only some have URL sort entries). col_b gets default sort (no sortBy/direction params —
    // backend's natural ORDER BY).
    const colBCalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_b')
    expect(colBCalls.length).toBeGreaterThan(0)
    const lastColBCall = colBCalls[colBCalls.length - 1]!
    expect(lastColBCall[6]).toBeUndefined() // default sort
    expect(lastColBCall[7]).toBeUndefined()

    wrapper.unmount()
  })

  it('mount with ?sorts=col_a:name:asc,col_b:created_at:desc fires per-column fetches with each column own sort', async () => {
    // Two columns mentioned in the URL → two fetches, each with its
    // own sort. col_b is NOT told to use col_a's sort.
    const item = makeItem()
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,

        sorts: 'col_a:name:asc,col_b:created_at:desc',
      },

      path: '/app',
      fullPath: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)

    const wrapper = mount(KanbanView, {
      props: { item, workspaceId: WS_ID },
    })

    await flushPromises()
    await new Promise((resolve) => setTimeout(resolve, 50))
    await flushPromises()

    // col_a: name asc
    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBeGreaterThan(0)
    expect(colACalls[colACalls.length - 1]![6]).toBe('name')
    expect(colACalls[colACalls.length - 1]![7]).toBe('asc')

    // col_b: created_at desc — INDEPENDENT of col_a's sort
    const colBCalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_b')
    expect(colBCalls.length).toBeGreaterThan(0)
    expect(colBCalls[colBCalls.length - 1]![6]).toBe('created_at')
    expect(colBCalls[colBCalls.length - 1]![7]).toBe('desc')

    wrapper.unmount()
  })

  it('mount with ?sorts=col_a:position:asc (default) fetches with default sort (no URL-sort override)', async () => {
    // Default sort (position+asc) is a no-op for the URL-sort override path — nonDefaultUrlEntries
    // filters it out. But col_a IS still fetched (regression fix 2026-08-06: other columns should
    // NOT stay empty when the URL has only default entries).
    // The fetch uses NO sortBy/direction params so the backend applies its natural ORDER BY
    // (kanban_position asc) — the same default it would have used on first-time visit.
    const item = makeItem({
      tasks: [makeTask('t_z', 'Zeta', 0), makeTask('t_a', 'Alpha', 1)],
    })
    const store = useWorkspacesStore()
    store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]
    const fetchOneSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',

        workspaceId: WS_ID,
        itemId: ITEM_ID,

        sorts: 'col_a:position:asc',
      },
      path: '/app',
      fullPath: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)

    mount(KanbanView, {
      props: { item, workspaceId: WS_ID },
    })

    await flushPromises()
    await new Promise((resolve) => setTimeout(resolve, 50))
    await flushPromises()

    // col_a's fetch fires WITH default sort (no URL-sort
    // override — the URL entry was default, so nonDefaultUrlEntries
    // excluded it; the column still needs data).
    const colACalls = fetchOneSpy.mock.calls.filter((c) => c[2] === 'col_a')
    expect(colACalls.length).toBeGreaterThan(0)
    const lastColACall = colACalls[colACalls.length - 1]!
    expect(lastColACall[6]).toBeUndefined() // default sort
    expect(lastColACall[7]).toBeUndefined()
  })
})
