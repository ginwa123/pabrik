/**
 * KanbanView URL preservation — the regressions that the static-`useRoute`
 * harness could not see.
 *
 * Both pre-existing KanbanView router specs (`KanbanView.sortByApi.spec.ts`,
 * `KanbanView.rowMode.spec.ts`) mock `useRoute` with a STATIC object whose
 * `query` is frozen at mount, and `router.replace` with a bare `vi.fn()` that
 * mutates nothing. That makes two whole classes of bug structurally invisible:
 *
 *   1. **Staleness** — `flatQuery()` reads `route.query`, which vue-router only
 *      updates at navigation *finalization* (≥6 microtask hops after the call).
 *      With a frozen mock, `route.query` never changes, so a writer that reads
 *      a stale snapshot looks identical to one that reads a fresh one.
 *   2. **Path shape** — the mock hardcodes `path: '/app'`, so a writer that
 *      emits the legacy `?view=workspace` shape instead of the canonical
 *      `/app/{ws}/projects/{item}` path is indistinguishable from a correct one.
 *
 * These tests use a REAL memory router and assert on
 * `router.currentRoute.value` after `flushPromises()`, so both classes are
 * observable.
 *
 * Why the path shape matters (the actual user-visible bug): the legacy
 * `?view=workspace` URL is rewritten once at boot by
 * `AppLayout.rewriteLegacyQuery`, whose sub-state whitelist is hardcoded. Any
 * param missing from that whitelist is silently dropped on reload — which is
 * how `?layout=rows` was lost for shared links and second machines.
 */
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { nextTick, ref, type Ref } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import { makeLocalStorageStub } from './helpers'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type WorkspaceItem,
} from '../stores/workspaces'

const WS_ID = 'ws_url'
const ITEM_ID = 'item_url'

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

/** A real router with a catch-all route, so `router.replace` actually commits
 * and `route.query` actually updates. The catch-all keeps the path opaque —
 * these tests assert on the query, and on the path only where the shape is
 * the point. */
async function makeRouter(initial: {
  path: string
  query?: Record<string, string>
}): Promise<Router> {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', name: 'catch-all', component: { template: '<div/>' } }],
  })
  await router.push({ path: initial.path, query: initial.query ?? {} })
  await router.isReady()
  return router
}

async function mountWithRouter(
  router: Router,
  opts: { item?: WorkspaceItem } = {},
): Promise<ReturnType<typeof mount>> {
  const item = opts.item ?? makeItem()
  const store = useWorkspacesStore()
  store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]

  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(KanbanView, {
    props: { item, workspaceId: WS_ID },
    global: { plugins: [router], provide: { processingState } },
  })
  await flushPromises()
  return wrapper
}

describe('KanbanView — URL preservation (real router)', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
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

  // ─── B1: the sorts watcher must not emit the legacy URL shape ────────────

  it('picking a column sort keeps the canonical path (not the legacy /app?view= shape)', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { layout: 'rows' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    const route = router.currentRoute.value
    // The legacy shape is `path: '/app'` + `?view=workspace`. Emitting it
    // triggers AppLayout's boot rewrite on the next reload, whose whitelist
    // drops any param it does not know about.
    expect(route.path).not.toBe('/app')
    expect(route.query.view).toBeUndefined()
    expect(route.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}`)
  })

  it('picking a column sort preserves ?layout= in the committed URL', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { layout: 'rows' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.query.layout).toBe('rows')
    expect(router.currentRoute.value.query.sorts).toContain('col_1:name:asc')
  })

  it('picking a column sort preserves ?detail= in the committed URL', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { detail: 't1' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    // The detail panel covers the board, so drive the sort through the
    // column-mode path (the panel is an overlay, the board stays mounted).
    await wrapper.find('[data-testid="kanban-column-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-column-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.query.detail).toBe('t1')
  })

  // ─── B3: setLayout must not clobber ?sorts= from a stale snapshot ────────

  it('switching layout preserves ?sorts= in the committed URL', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { sorts: 'col_1:name:asc' },
    })
    wrapper = await mountWithRouter(router)

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.query.layout).toBe('rows')
    expect(router.currentRoute.value.query.sorts).toBe('col_1:name:asc')
  })

  it('switching layout preserves ?detail= in the committed URL', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { detail: 't1' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.query.layout).toBe('rows')
    expect(router.currentRoute.value.query.detail).toBe('t1')
  })

  it('switching layout keeps the canonical path', async () => {
    const router = await makeRouter({ path: `/app/${WS_ID}/projects/${ITEM_ID}` })
    wrapper = await mountWithRouter(router)

    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`).trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}`)
  })

  // ─── B2: closing the detail panel must not drop ?layout= ─────────────────

  it('closing the detail panel preserves ?layout= in the committed URL', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { layout: 'rows', detail: 't1' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    // The panel is open from the URL; close it via the panel's own close
    // affordance (v-model:show → the showTaskDetail watcher).
    const panel = wrapper.find('[data-testid="kanban-detail-panel"]')
    expect(panel.exists()).toBe(true)
    const closeBtn = panel.find('[data-testid="kanban-task-detail-close"]')
    if (closeBtn.exists()) {
      await closeBtn.trigger('click')
    } else {
      // Fall back to the component's own close path via the exposed handler.
      await wrapper.find('[data-testid="kanban-detail-panel"]').trigger('keydown.esc')
    }
    await flushPromises()

    expect(router.currentRoute.value.query.detail).toBeUndefined()
    expect(router.currentRoute.value.query.layout).toBe('rows')
  })

  // ─── Round-trip: the URL survives a reload ───────────────────────────────

  it('a ?layout=rows deep link restores row mode on a fresh mount', async () => {
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { layout: 'rows' },
    })
    wrapper = await mountWithRouter(router)

    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(true)
    expect(
      wrapper
        .find(`[data-testid="kanban-view-${ITEM_ID}-layout-rows"]`)
        .attributes('aria-selected'),
    ).toBe('true')
  })

  it('the URL after a sort pick is still a valid deep link for row mode', async () => {
    // The end-to-end contract: pick a sort in row mode, then re-mount from the
    // resulting URL and confirm row mode is still active. This is what a
    // shared link / second machine does.
    const router = await makeRouter({
      path: `/app/${WS_ID}/projects/${ITEM_ID}`,
      query: { layout: 'rows' },
    })
    wrapper = await mountWithRouter(router, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-row-group-col_1-menu-sort"]').trigger('click')
    await nextTick()
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await flushPromises()

    const committed = router.currentRoute.value
    wrapper.unmount()

    // Re-mount from the committed URL, as a reload would.
    const reloaded = await makeRouter({
      path: committed.path,
      query: committed.query as Record<string, string>,
    })
    wrapper = await mountWithRouter(reloaded, {
      item: makeItem({ tasks: [makeTask({ id: 't1' })] }),
    })

    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-rows"]`).exists()).toBe(true)
  })
})
