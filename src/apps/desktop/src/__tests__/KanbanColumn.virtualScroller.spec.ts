/** Behavioural tests for KanbanColumn + VirtualScroller integration (kanban-virtual-scroll,
 * 2026-08-06). Why this exists. Plan: docs/superpowers/plans/2026-08-06-kanban-virtual-scroll.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import KanbanColumn from '../components/kanban/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'
import { useWorkspacesStore } from '../stores/workspaces'
import * as api from '../api'

const COL_TODO = 'col_todo'

const makeColumn = (overrides: Partial<KanbanColumnType> = {}): KanbanColumnType => ({
  id: COL_TODO,
  workspace_item_id: 'item_1',
  name: 'todo',
  position: 0,
  created_at: '2026-08-06 12:00:00',
  ...overrides,
})

const makeTasks = (count: number, columnId = COL_TODO): Task[] =>
  Array.from(
    { length: count },
    (_, i) =>
      ({
        id: `t${i + 1}`,
        name: `Task ${i + 1}`,
        kanban_column_id: columnId,
        kanban_position: i,
        workspace_item_id: 'item_1',
        task_type: 'standard',
        created_at: `2026-08-06T1${i % 9}:00:00.000Z`,
      }) as Task,
  )

/** Mount a KanbanColumn with a pre-populated workspaces store so `parentItem.columnPagination` is
 * non-null. Without this the `loadMoreTasksForColumn` no-ops at the store level (and so does the
 * @load-more handler — the action is the source of truth). */
function mountColumnWithPagination(
  column: KanbanColumnType,
  tasks: Task[],
  pagination: { hasMore: boolean; isLoading?: boolean; cursor?: string | null } = {
    hasMore: true,
    cursor: 'cursor_xyz',
  },
  workspaceId = 'ws_1',
  itemId = 'item_1',
) {
  // Build the store BEFORE mounting so the workspaces.value.find(...)
  // chain in KanbanColumn can resolve `parentItem`.
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: workspaceId,
      name: 'Workspace 1',
      icon: '📁',
      expanded: false,
      items: [
        {
          id: itemId,
          name: 'Kanban',
          item_type: 'kanban',
          path: '/tmp',
          kanban_columns: [column],
          tasks,
          columnPagination: {
            [column.id]: {
              cursor: pagination.cursor ?? null,
              hasMore: pagination.hasMore,
              isLoading: pagination.isLoading ?? false,
            },
          },
        },
      ],
    },
  ]

  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanColumn, {
    props: { column, tasks, workspaceId, itemId },
    global: {
      provide: { processingState },
    },
  })
}

describe('KanbanColumn — VirtualScroller integration', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // Silence the real fetch call from `loadMoreTasksForColumn` → `api.getTasks`. Default mock
    // returns `has_more: true` so the auto-fetch watcher (2026-08-06) keeps the column in the
    // "still loading more" state — matches the manual-button visibility test scenarios.
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: true,
      next_cursor: 'cursor_p2',
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  // ─── 1. Renders VirtualScroller with the column's cards as items ──────
  it('renders a <VirtualScroller> when the column has cards', () => {
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(5))

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    expect(scroller.exists()).toBe(true)
    // The scroller receives the same cardsInColumn we filtered.
    expect((scroller.props('items') as Task[]).length).toBe(5)
    // defaultItemHeight is the pre-measurement estimate. We picked
    // 100px (~96 card + 4 px pb-1 gap) so the first paint lines up
    // with reality before the first measurement cycle (~150 ms).
    expect(scroller.props('defaultItemHeight')).toBe(100)
    // loadMoreAtTop defaults to false — kanban appends, not prepends.
    expect(scroller.props('loadMoreAtTop')).toBe(false)
  })

  it("passes only this column's tasks to the scroller (filters by column id)", () => {
    // Mix tasks for two different columns. The scroller must only
    // see tasks for the column it belongs to.
    const tasks = [...makeTasks(3, COL_TODO), ...makeTasks(2, 'col_other')]
    wrapper = mountColumnWithPagination(makeColumn(), tasks)

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    const items = scroller.props('items') as Task[]
    expect(items).toHaveLength(3)
    expect(items.map((t) => t.id)).toEqual(['t1', 't2', 't3'])
  })

  // ─── 2. Only a slice of cards is in the DOM ─────────────────────────────
  it('does NOT mount every card to the DOM when there are many', async () => {
    // 50 tasks but the scroller only mounts the visible range. jsdom doesn't have a real layout, so
    // the visible range may include more than the production default of ~10 — but it MUST be far
    // less than 50.
    const tasks = makeTasks(50)
    wrapper = mountColumnWithPagination(makeColumn(), tasks)
    await nextTick()
    // Allow the scroller's measurement setTimeout (50ms) to fire so
    // the buffer is computed against measured heights, not the
    // 96px default.
    await new Promise((r) => setTimeout(r, 100))
    await nextTick()

    const renderedCards = wrapper.findAll('[data-kanban-card]')
    expect(renderedCards.length).toBeGreaterThan(0)
    expect(renderedCards.length).toBeLessThan(50)
  })

  // ─── 3. @load-more from VirtualScroller → calls loadMoreTasksForColumn
  it('emitting @load-more from the scroller calls loadMoreTasksForColumn', async () => {
    const tasks = makeTasks(3)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: true,
      cursor: 'cursor_abc',
    })

    // Let the auto-fetch watcher's immediate run + its async fetch settle. `flushPromises` rather
    // than a fixed tick count: the mount path primes the local task cache through Effect, which
    // takes more microtask hops than the direct api call it replaced.
    await flushPromises()

    // Spy on api.getTasks (set up in beforeEach) so we can verify the @load-more path forwards the
    // columnId correctly. The auto-fetch watcher fires once during mount — we capture the LATEST
    // call (the @load-more driven one).
    const getTasksSpy = vi.mocked(api.getTasks)
    const callsBefore = getTasksSpy.mock.calls.length

    // Drive the scroller's @load-more emit directly. In production this fires when the user scrolls
    // within loadMoreThreshold of the bottom; in jsdom we trigger it manually because there's no
    // real scroll layout.
    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('loadMore')
    await nextTick()

    expect(getTasksSpy.mock.calls.length).toBeGreaterThan(callsBefore)
    const lastCall = getTasksSpy.mock.calls[getTasksSpy.mock.calls.length - 1]!
    // Arg positions: workspaceId, itemId, limit, cursor, sortBy, direction, columnId, q
    expect(lastCall[0]).toBe('ws_1')
    expect(lastCall[1]).toBe('item_1')
    expect(lastCall[6]).toBe(COL_TODO) // columnId
  })

  it('does NOT call loadMoreTasksForColumn when hasMore=false (from scroller)', async () => {
    const tasks = makeTasks(3)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: false,
      cursor: null,
    })

    const getTasksSpy = vi.mocked(api.getTasks)
    const callsBefore = getTasksSpy.mock.calls.length

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('loadMore')
    await nextTick()

    expect(getTasksSpy.mock.calls.length).toBe(callsBefore)
  })

  // ─── 4. @scrollability-change drives the manual "Load more" button ─────
  it('manual "Load more" button is hidden when the scroller IS scrollable', async () => {
    const tasks = makeTasks(10)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: true,
      cursor: 'cursor_1',
    })
    await flushPromises()

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    // Drive the scrollability event with `true` (scrollable).
    scroller.vm.$emit('scrollabilityChange', true)
    await nextTick()

    const loadMore = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-load-more"]`)
    expect(loadMore.exists()).toBe(false)
  })

  it('manual "Load more" button IS visible when the scroller is NOT scrollable', async () => {
    const tasks = makeTasks(2)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: true,
      cursor: 'cursor_1',
    })
    await flushPromises()

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('scrollabilityChange', false)
    await nextTick()

    const loadMore = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-load-more"]`)
    expect(loadMore.exists()).toBe(true)
  })

  it('clicking the manual "Load more" button calls loadMoreTasksForColumn', async () => {
    const tasks = makeTasks(2)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: true,
      cursor: 'cursor_1',
    })
    await flushPromises()

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('scrollabilityChange', false)
    await nextTick()

    const getTasksSpy = vi.mocked(api.getTasks)
    const callsBefore = getTasksSpy.mock.calls.length

    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-load-more"]`).trigger('click')
    await flushPromises()

    expect(getTasksSpy.mock.calls.length).toBeGreaterThan(callsBefore)
    const lastCall = getTasksSpy.mock.calls[getTasksSpy.mock.calls.length - 1]!
    expect(lastCall[0]).toBe('ws_1')
    expect(lastCall[1]).toBe('item_1')
    expect(lastCall[6]).toBe(COL_TODO)
  })

  it('manual "Load more" button is hidden when hasMore=false', async () => {
    const tasks = makeTasks(2)
    wrapper = mountColumnWithPagination(makeColumn(), tasks, {
      hasMore: false,
      cursor: null,
    })
    await flushPromises()

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('scrollabilityChange', false)
    await nextTick()

    const loadMore = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-load-more"]`)
    expect(loadMore.exists()).toBe(false)
  })

  // ─── 5. Empty column → no VirtualScroller, empty placeholder shows ─────
  it('does NOT render VirtualScroller when the column has no cards', () => {
    wrapper = mountColumnWithPagination(makeColumn(), [], {
      hasMore: false,
      cursor: null,
    })

    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    expect(scroller.exists()).toBe(false)

    const empty = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-empty"]`)
    expect(empty.exists()).toBe(true)
    expect(empty.text()).toContain('No tasks yet')
  })

  // ─── 7. Auto-fetch when the viewport fits the page (2026-08-06 fix) ─── Bug: when the entire
  // page fits in the viewport (e.g. a column with 10 cards on a tall screen), the VirtualScroller's
  // container is NOT scrollable, so its scroll-driven @load-more never fires.
  it('auto-fetches when hasMore=true and the page fits in the viewport', async () => {
    // 9 cards (< PAGE_SIZE=10) so the watcher's `cardsInColumn.length < PAGE_SIZE` branch fires.
    // hasMore=true so `moreTasksAvailable` is true. scrollerIsScrollable defaults to false (no
    // @scrollability-change has fired yet). All three conditions for auto-fetch are met.
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(9), {
      hasMore: true,
      cursor: 'cursor_p2',
    })

    await nextTick()

    const getTasksSpy = vi.mocked(api.getTasks)
    // Find the call that included our cursor — the auto-fetch should
    // have fired with cursor='cursor_p2'.
    const callsWithOurCursor = getTasksSpy.mock.calls.filter((call) => call[3] === 'cursor_p2')
    expect(callsWithOurCursor.length).toBeGreaterThan(0)
    expect(callsWithOurCursor[0]![6]).toBe(COL_TODO) // columnId
  })

  it('does NOT auto-fetch when the column is already scrollable (no overlap with VirtualScroller @load-more)', async () => {
    // Mount FIRST. The watcher runs immediately — with 9 cards and
    // scrollerIsScrollable=false, it fires once. We then flip
    // scrollerIsScrollable to true and assert no additional fetches.
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(9), {
      hasMore: true,
      cursor: 'cursor_p2',
    })
    await nextTick()
    const getTasksSpy = vi.mocked(api.getTasks)
    const callsAfterMount = getTasksSpy.mock.calls.length
    expect(callsAfterMount).toBeGreaterThan(0) // initial auto-fetch fired

    // Now flip scrollability to true. The watcher re-evaluates and
    // should NOT fire again (scrollerIsScrollable=true → bail).
    const scroller = wrapper.findComponent({ name: 'VirtualScroller' })
    scroller.vm.$emit('scrollabilityChange', true)
    await nextTick()

    expect(getTasksSpy.mock.calls.length).toBe(callsAfterMount)
  })

  it('does NOT auto-fetch when cardsInColumn.length >= PAGE_SIZE (page full)', async () => {
    // 10 cards == PAGE_SIZE. The watcher's "viewport fits the page" condition is
    // `cardsInColumn.length < PAGE_SIZE` — false here — so no auto-fetch. VirtualScroller's
    // scroll-driven @load-more is the path that fires in that case.
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(10), {
      hasMore: true,
      cursor: 'cursor_p2',
    })
    await nextTick()

    const getTasksSpy = vi.mocked(api.getTasks)
    const callsWithOurCursor = getTasksSpy.mock.calls.filter((call) => call[3] === 'cursor_p2')
    expect(callsWithOurCursor.length).toBe(0)
  })

  it('does NOT auto-fetch when hasMore=false', async () => {
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(3), {
      hasMore: false,
      cursor: null,
    })
    await nextTick()

    const getTasksSpy = vi.mocked(api.getTasks)
    // The default cursor in the seeded pagination is null when hasMore=false — and the store action
    // bails on null cursor before calling api.getTasks. We check that no api.getTasks call was made
    // for this column at all.
    const callsForCol = getTasksSpy.mock.calls.filter((call) => call[6] === COL_TODO)
    expect(callsForCol.length).toBe(0)
  })

  // ─── 6. Drop zone handlers still fire on the wrapper ───────────────────
  it('dragover on the cards wrapper sets the visual feedback', async () => {
    const tasks = makeTasks(3)
    wrapper = mountColumnWithPagination(makeColumn(), tasks)

    const cardsWrapper = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-cards"]`)
    expect(cardsWrapper.exists()).toBe(true)

    // Dispatch a real DragEvent so the handler's `event.dataTransfer` reads as a live object
    // (vue-test-utils' `trigger` synthesises a generic Event, which makes `dataTransfer` undefined
    // and the handler bails before calling preventDefault).
    const el = cardsWrapper.element as HTMLElement
    const dragOver = new Event('dragover', { bubbles: true, cancelable: true }) as Event & {
      dataTransfer?: { types: string[]; dropEffect: string }
    }
    Object.defineProperty(dragOver, 'dataTransfer', {
      value: {
        types: ['application/x-kanban-task-id'],
        dropEffect: 'none',
      },
    })
    el.dispatchEvent(dragOver)

    expect(dragOver.defaultPrevented).toBe(true)
    expect(dragOver.dataTransfer?.dropEffect).toBe('move')
  })
})

/** First-page skeleton. Before this, a column whose page-1 fetch was still in flight rendered its
 * "No tasks yet" empty state — a false statement about the user's data, since the column may well
 * have tasks. */
describe('KanbanColumn — first-page skeleton', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: true,
      next_cursor: 'cursor_p2',
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('shows the skeleton (not the empty state) while the first page is in flight', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'W',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: 'item_1',
            name: 'Kanban',
            item_type: 'kanban',
            path: '/tmp',
            kanban_columns: [makeColumn()],
            tasks: [],
            // No columnPagination entry — the column has not been
            // fetched yet, which is exactly the state the skeleton
            // covers.
          },
        ],
      },
    ]
    // Pinia unwraps refs on setup stores, so this is the Set itself.
    store.firstPageLoadingColumns.add('item_1:col_todo')

    wrapper = mount(KanbanColumn, {
      props: { column: makeColumn(), tasks: [], workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()

    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-skeleton"]`).exists()).toBe(true)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-empty"]`).exists()).toBe(false)
  })

  it('shows the empty state (not the skeleton) once the first page has landed', async () => {
    wrapper = mountColumnWithPagination(makeColumn(), [], { hasMore: false, cursor: null })
    await nextTick()

    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-skeleton"]`).exists()).toBe(false)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-empty"]`).exists()).toBe(true)
  })

  it('shows neither skeleton nor empty state when cards are present', async () => {
    wrapper = mountColumnWithPagination(makeColumn(), makeTasks(3), {
      hasMore: false,
      cursor: null,
    })
    await nextTick()

    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-skeleton"]`).exists()).toBe(false)
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-empty"]`).exists()).toBe(false)
  })
})
