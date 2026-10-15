/** KanbanView row mode — the URL-backed Columns/Rows layout toggle. Row mode renders the same board
 * as a vertical list grouped by column. */

/** The choice lives in `?layout=rows` so refresh, Back/Forward and shared links restore it (repo
 * rule: "Every View Switch Must Update the Browser URL"). `columns` is the default and is stripped
 * from the URL. Precedence: URL (deep link) → localStorage (`pabrik-kanban-layout`) → `columns`. */

/** The router is mocked with the `vi.hoisted` pair used by KanbanView.sortByApi.spec.ts so we can
 * assert the exact query object passed to `router.replace`. */
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref, type Ref } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import { makeLocalStorageStub } from './helpers'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type WorkspaceItem,
} from '../stores/workspaces'

const WS_ID = 'ws_row_mode'
const ITEM_ID = 'item_row_mode'

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

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_1',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'A task',
  kanban_column_id: 'col_1',
  ...overrides,
})

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [makeColumn()],
  tasks: [],
  ...overrides,
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
  const pushMock = vi.fn()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(KanbanView, {
    props: { item, workspaceId: WS_ID },
    global: { provide: { processingState } },
  })
  return { wrapper, replaceMock, pushMock }
}

const lastQuery = (replaceMock: ReturnType<typeof vi.fn>): Record<string, string> => {
  const calls = replaceMock.mock.calls
  expect(calls.length).toBeGreaterThan(0)
  return calls[calls.length - 1]![0].query as Record<string, string>
}

describe('KanbanView row mode', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // jsdom 29 dropped localStorage from its default globals.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  // ─── Toggle rendering ────────────────────────────────────────────────────

  it('renders both layout buttons in the header', () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-columns"]`).exists()).toBe(
      true,
    )
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).exists()).toBe(true)
  })

  it('defaults to columns: the columns button is selected and the board renders', () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    expect(
      wrapper
        .find(`[data-testid="kanban-view-${ITEM_ID}-layout-columns"]`)
        .attributes('aria-selected'),
    ).toBe('true')
    expect(
      wrapper
        .find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`)
        .attributes('aria-selected'),
    ).toBe('false')
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-columns"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(false)
  })

  // ─── URL writes ──────────────────────────────────────────────────────────

  it('clicking Rows writes ?layout=rows via router.replace', async () => {
    const mounted = mountKanbanView({ view: 'workspace', workspaceId: WS_ID, itemId: ITEM_ID })
    wrapper = mounted.wrapper

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await nextTick()

    expect(mounted.replaceMock).toHaveBeenCalled()
    expect(lastQuery(mounted.replaceMock).layout).toBe('rows')
  })

  it('clicking Columns strips ?layout= from the URL (default value)', async () => {
    const mounted = mountKanbanView({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      layout: 'rows',
    })
    wrapper = mounted.wrapper

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-columns"]`).trigger('click')
    await nextTick()

    expect(lastQuery(mounted.replaceMock).layout).toBeUndefined()
  })

  it('uses router.replace, not push, for the layout switch', async () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await nextTick()
    expect(mounted.replaceMock).toHaveBeenCalled()
  })

  // ─── URL restore ─────────────────────────────────────────────────────────

  it('mount with ?layout=rows restores the row view', () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper
    expect(
      wrapper
        .find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`)
        .attributes('aria-selected'),
    ).toBe('true')
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-columns"]`).exists()).toBe(false)
  })

  it('mount with ?layout=columns keeps the board', () => {
    const mounted = mountKanbanView({ layout: 'columns' })
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-columns"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(false)
  })

  it('an unknown ?layout= value falls back to columns', () => {
    const mounted = mountKanbanView({ layout: 'diagonal' })
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-columns"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(false)
  })

  // ─── localStorage precedence ─────────────────────────────────────────────

  it('uses the stored preference when the URL has no ?layout=', () => {
    localStorage.setItem('pabrik-kanban-layout', 'rows')
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(true)
  })

  it('the URL wins over the stored preference', () => {
    localStorage.setItem('pabrik-kanban-layout', 'rows')
    const mounted = mountKanbanView({ layout: 'columns' })
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-columns"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(false)
  })

  it('persists the picked layout to localStorage', async () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await nextTick()
    expect(localStorage.getItem('pabrik-kanban-layout')).toBe('rows')
  })

  // ─── Sibling-param preservation (the ?sorts= watcher regression) ─────────

  it('toggling layout preserves ?sorts=', async () => {
    const mounted = mountKanbanView({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_1:name:asc',
    })
    wrapper = mounted.wrapper

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()

    // The ?sorts= watcher can fire in the same tick as the layout switch
    // (it runs from loadColumnsAndTasks' nextTick). Assert on the LAST
    // write so we catch a clobber regardless of ordering.
    const query = lastQuery(mounted.replaceMock)
    expect(query.sorts).toBe('col_1:name:asc')
    expect(query.layout).toBe('rows')
  })

  it('toggling layout preserves ?detail=', async () => {
    const task = makeTask({ id: 'task_detail' })
    const mounted = mountKanbanView(
      { view: 'workspace', workspaceId: WS_ID, itemId: ITEM_ID, detail: 'task_detail' },
      { item: makeItem({ tasks: [task] }) },
    )
    wrapper = mounted.wrapper

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()

    expect(lastQuery(mounted.replaceMock).detail).toBe('task_detail')
  })

  // ─── Row rendering ───────────────────────────────────────────────────────

  it('renders one group per column, in position order', () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      {
        item: makeItem({
          kanban_columns: [
            makeColumn({ id: 'col_b', name: 'done', position: 2 }),
            makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
            makeColumn({ id: 'col_c', name: 'in progress', position: 1 }),
          ],
        }),
      },
    )
    wrapper = mounted.wrapper

    const groups = wrapper.findAll('[data-kanban-row-group]')
    expect(groups.map((g) => g.attributes('data-kanban-row-group'))).toEqual([
      'col_a',
      'col_c',
      'col_b',
    ])
  })

  it('renders a row per task, grouped by kanban_column_id', () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      {
        item: makeItem({
          kanban_columns: [
            makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
            makeColumn({ id: 'col_b', name: 'done', position: 1 }),
          ],
          tasks: [
            makeTask({ id: 't1', name: 'First', kanban_column_id: 'col_a' }),
            makeTask({ id: 't2', name: 'Second', kanban_column_id: 'col_b' }),
            makeTask({ id: 't3', name: 'Third', kanban_column_id: 'col_a' }),
          ],
        }),
      },
    )
    wrapper = mounted.wrapper

    const groupA = wrapper.find('[data-testid="kanban-row-group-col_a-rows"]')
    const groupB = wrapper.find('[data-testid="kanban-row-group-col_b-rows"]')
    expect(groupA.findAll('[data-kanban-row]').map((r) => r.attributes('data-kanban-row'))).toEqual(
      ['t1', 't3'],
    )
    expect(groupB.findAll('[data-kanban-row]').map((r) => r.attributes('data-kanban-row'))).toEqual(
      ['t2'],
    )
  })

  it('shows the loaded-row count per group', () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      {
        item: makeItem({
          tasks: [
            makeTask({ id: 't1', kanban_column_id: 'col_1' }),
            makeTask({ id: 't2', kanban_column_id: 'col_1' }),
          ],
        }),
      },
    )
    wrapper = mounted.wrapper
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-count"]').text()).toBe('2')
  })

  it('renders the board-level empty state when there are no columns', () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ kanban_columns: [], tasks: [] }) },
    )
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows-empty"]`).exists()).toBe(true)
    expect(wrapper.text()).toContain('No columns on this board')
  })

  it('renders the per-group empty placeholder for a column with no tasks', () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No tasks yet')
  })

  // ─── Collapse ────────────────────────────────────────────────────────────

  it('collapsing a group hides its rows and persists to localStorage', async () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper

    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rows"]').exists()).toBe(true)

    await wrapper.find('[data-testid="kanban-row-group-col_1-toggle"]').trigger('click')
    await nextTick()

    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rows"]').exists()).toBe(false)
    expect(
      JSON.parse(localStorage.getItem(`pabrik-kanban-row-collapsed:${ITEM_ID}`) ?? '[]'),
    ).toEqual(['col_1'])
  })

  it('restores collapsed groups from localStorage on mount', () => {
    localStorage.setItem(`pabrik-kanban-row-collapsed:${ITEM_ID}`, JSON.stringify(['col_1']))
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper
    expect(wrapper.find('[data-testid="kanban-row-group-col_1-rows"]').exists()).toBe(false)
  })

  it('expanding a collapsed group removes it from localStorage', async () => {
    localStorage.setItem(`pabrik-kanban-row-collapsed:${ITEM_ID}`, JSON.stringify(['col_1']))
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper

    await wrapper.find('[data-testid="kanban-row-group-col_1-toggle"]').trigger('click')
    await nextTick()

    expect(
      JSON.parse(localStorage.getItem(`pabrik-kanban-row-collapsed:${ITEM_ID}`) ?? '[]'),
    ).toEqual([])
  })

  // ─── Event pass-through ──────────────────────────────────────────────────

  it('clicking a row emits selectTask', async () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper

    await wrapper.find('[data-kanban-row="t1"] [data-task-row]').trigger('click')
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])
  })

  it('clicking the ⋯ details button opens the detail panel and pushes ?detail=', async () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper

    await wrapper.find('[data-testid="kanban-row-t1-details"]').trigger('click')
    await nextTick()

    // KanbanView consumes viewTaskDetail internally (it owns the panel),
    // so the observable effect is the panel + the ?detail= push.
    expect(wrapper.find('[data-testid="kanban-detail-panel"]').exists()).toBe(true)
    const pushCalls = mounted.pushMock.mock.calls
    expect(pushCalls.length).toBeGreaterThan(0)
    const query = pushCalls[pushCalls.length - 1]![0].query as Record<string, string>
    expect(query.detail).toBe('t1')
    // The layout param survives the push.
    expect(query.layout).toBe('rows')
  })

  it('the group ⋮ menu emits requestRenameColumn', async () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-rename"]').trigger('click')

    expect(wrapper.emitted('requestRenameColumn')?.[0]).toEqual(['col_1'])
  })

  it('the group ⋮ menu emits requestDeleteColumn', async () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-delete"]').trigger('click')

    expect(wrapper.emitted('requestDeleteColumn')?.[0]).toEqual(['col_1'])
  })

  it('the group ⋮ menu Run all agents calls the store for that column', async () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper
    const store = useWorkspacesStore()
    const runAllSpy = vi.spyOn(store, 'runAllAgentsInColumn').mockResolvedValue({
      success: true,
      started: [],
      skipped: [],
      failed: [],
    })
    // handleRunAllAgents gates on a confirm() dialog.
    const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true)

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-run-all"]').trigger('click')
    await flushPromises()

    // KanbanView consumes requestRunAllAgents internally (it owns the
    // bulk-run state), so the observable effect is the store call.
    expect(confirmSpy).toHaveBeenCalled()
    expect(runAllSpy).toHaveBeenCalled()
    expect(runAllSpy.mock.calls[0]![2]).toBe('col_1')
  })

  it('picking a sort in the group modal refetches that column and writes ?sorts=', async () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper
    const store = useWorkspacesStore()
    const fetchSpy = vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    // KanbanView consumes sortChange internally: it fires the per-column
    // fetch and mirrors the pick into `?sorts=`.
    const sortedCalls = fetchSpy.mock.calls.filter((c) => c[2] === 'col_1' && c[6] === 'name')
    expect(sortedCalls.length).toBeGreaterThan(0)
    expect(sortedCalls[0]![7]).toBe('asc')
    expect(lastQuery(mounted.replaceMock).sorts).toContain('col_1:name:asc')
  })

  // ─── Column mode is untouched ────────────────────────────────────────────

  it('column mode still renders KanbanColumn and no row groups', () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    expect(wrapper.find('[data-kanban-column="col_1"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-kanban-row-group]')).toHaveLength(0)
  })

  // ─── Row density (comfortable ⇄ compact) ──────────────────────────────── Density is a
  // localStorage preference, NOT a URL param — it is a legibility trade-off, not a distinct view,
  // so a deep link should not carry it (same rule as group collapse).

  it('hides the density toggle in column mode', () => {
    const mounted = mountKanbanView()
    wrapper = mounted.wrapper
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`).exists()).toBe(
      false,
    )
  })

  it('shows the density toggle in row mode, defaulting to comfortable', () => {
    const mounted = mountKanbanView({ layout: 'rows' })
    wrapper = mounted.wrapper
    const toggle = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`)
    expect(toggle.exists()).toBe(true)
    expect(toggle.text()).toContain('Comfortable')
    expect(toggle.attributes('aria-pressed')).toBe('false')
  })

  it('clicking the density toggle switches the rows to compact', async () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`).trigger('click')
    await nextTick()
    expect(wrapper.find(`[data-kanban-row="t1"]`).attributes('data-kanban-row-density')).toBe(
      'compact',
    )
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`).text()).toContain(
      'Compact',
    )
  })

  it('the density choice persists to localStorage and survives a remount', async () => {
    const first = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    await first.wrapper
      .find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`)
      .trigger('click')
    await nextTick()
    expect(localStorage.getItem('pabrik-kanban-row-density')).toBe('compact')
    first.wrapper.unmount()

    // Remount with no `?layout=` density hint — the stored value wins.
    const second = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = second.wrapper
    expect(wrapper.find(`[data-kanban-row="t1"]`).attributes('data-kanban-row-density')).toBe(
      'compact',
    )
  })

  it('toggling density does not write anything to the URL', async () => {
    const mounted = mountKanbanView(
      { layout: 'rows' },
      { item: makeItem({ tasks: [makeTask({ id: 't1' })] }) },
    )
    wrapper = mounted.wrapper
    const before = mounted.replaceMock.mock.calls.length
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-density-toggle"]`).trigger('click')
    await nextTick()
    // No router.replace at all — density is deliberately not URL state.
    expect(mounted.replaceMock.mock.calls.length).toBe(before)
  })
})
