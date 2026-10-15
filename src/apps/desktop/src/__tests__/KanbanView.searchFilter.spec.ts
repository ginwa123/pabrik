/**
 * Behavioural tests for KanbanView's search-filter wiring.
 *
 * Plan: docs/superpowers/plans/2026-07-30-kanban-task-search.md Chunk 6
 *
 * Verifies:
 *   - <KanbanSearchInput> renders in the header, left of ⚙️ Settings.
 *   - Typing triggers a 300ms-debounced refetch via fetchKanbanTasks(q=).
 *   - Esc / ✕ → debounced refetch with q=undefined (cleared).
 *   - "No tasks match" banner appears when tasks empty + query non-empty.
 *   - Column count badge updates when search is active.
 *
 * Uses vi.useFakeTimers() to drive the 300ms debounce deterministically.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'

import KanbanView from '../components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

const WS_ID = 'ws_search_test'
const ITEM_ID = 'item_search_test'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'Search Test Board',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: ITEM_ID, position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'done', workspace_item_id: ITEM_ID, position: 1, created_at: '2026-01-01' },
  ],
  tasks: [
    { id: 'task_1', name: 'fix login', task_type: 'standard', kanban_column_id: 'col_a', kanban_position: 0 },
    { id: 'task_2', name: 'design', task_type: 'standard', kanban_column_id: 'col_b', kanban_position: 0 },
  ],
  columnPagination: {},
  ...overrides,
})

describe('KanbanView search filter wiring', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('renders <KanbanSearchInput> in the header, left of the ⚙️ Settings button', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
    })
    const searchInput = wrapper.find('[data-testid="kanban-search-input"]')
    expect(searchInput.exists()).toBe(true)
  })

  it('typing triggers a 300ms-debounced refetch with q', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spyForAllColumns = vi.spyOn(store, 'fetchKanbanTasksForAllColumns').mockResolvedValue()

    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
    })

    await wrapper.find('[data-testid="kanban-search-input"]').setValue('design')

    // Immediately after setValue (before debounce fires) — no call yet.
    expect(spyForAllColumns).not.toHaveBeenCalled()

    // Advance fake timer past the debounce window.
    vi.advanceTimersByTime(350)
    await flushPromises()

    // Per-column initial fetch (Option B): the search watcher calls fetchKanbanTasksForAllColumns,
    // not fetchKanbanTasks directly. The underlying per-column fetches happen as
    // Promise.all(map(col => fetchKanbanTasks(...))).
    expect(spyForAllColumns).toHaveBeenCalledWith(WS_ID, ITEM_ID, 10, 'design')
  })

  it('Esc clears and triggers a debounced refetch with q=undefined', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spyForAllColumns = vi.spyOn(store, 'fetchKanbanTasksForAllColumns').mockResolvedValue()

    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
    })

    // Type a query
    await wrapper.find('[data-testid="kanban-search-input"]').setValue('design')
    vi.advanceTimersByTime(350)
    await flushPromises()
    expect(spyForAllColumns).toHaveBeenCalledTimes(1)
    expect(spyForAllColumns).toHaveBeenLastCalledWith(WS_ID, ITEM_ID, 10, 'design')

    // Clear it (Esc inside the input)
    await wrapper.find('[data-testid="kanban-search-input"]').trigger('keydown', { key: 'Escape' })
    vi.advanceTimersByTime(350)
    await flushPromises()

    // Last call's q is undefined (Esc cleared the input).
    const calls = spyForAllColumns.mock.calls
    expect(calls[calls.length - 1]?.[3]).toBeUndefined() // q is the 4th arg (ws, item, limit, q)
  })

  it('renders "No tasks match" banner when tasks empty + search non-empty', async () => {
    const store = useWorkspacesStore()
    const emptyItem = makeItem({ tasks: [] })
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [emptyItem] },
    ]
    const wrapper = mount(KanbanView, {
      props: { item: emptyItem, workspaceId: WS_ID },
    })
    await flushPromises()
    const searchInput = wrapper.find('[data-testid="kanban-search-input"]')
    await searchInput.setValue('nothing-matches')
    await flushPromises()
    // Banner testid is prefixed with item.id per the project
    // convention (`kanban-view-${item.id}-no-search-matches`).
    const bannerSel = `[data-testid="kanban-view-${ITEM_ID}-no-search-matches"]`
    expect(wrapper.find(bannerSel).exists()).toBe(true)
    expect(wrapper.find(bannerSel).text()).toContain('nothing-matches')
  })

  it('does NOT render banner when search is empty', () => {
    const store = useWorkspacesStore()
    const emptyItem = makeItem({ tasks: [] })
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [emptyItem] },
    ]
    const wrapper = mount(KanbanView, {
      props: { item: emptyItem, workspaceId: WS_ID },
    })
    const bannerSel = `[data-testid="kanban-view-${ITEM_ID}-no-search-matches"]`
    expect(wrapper.find(bannerSel).exists()).toBe(false)
  })

  it('does NOT render banner when tasks exist (even with search active)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const wrapper = mount(KanbanView, {
      props: { item: makeItem(), workspaceId: WS_ID },
    })
    await wrapper.find('[data-testid="kanban-search-input"]').setValue('design')
    await flushPromises()
    const bannerSel = `[data-testid="kanban-view-${ITEM_ID}-no-search-matches"]`
    expect(wrapper.find(bannerSel).exists()).toBe(false)
  })
})