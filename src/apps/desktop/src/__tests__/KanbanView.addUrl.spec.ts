/** KanbanView `/add` (add-task page) URL behaviour, pinned against a real router. Plan: the kanban
 * add-task page is `/app/{ws}/projects/{item}/add`, with the target column in `?column=`, and the
 * board's own query (`?layout=`, `?sorts=`, …) must survive the round trip. */
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { ref, type Ref } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import { makeLocalStorageStub } from './helpers'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type WorkspaceItem,
} from '../stores/workspaces'

const WS_ID = 'ws_add'
const ITEM_ID = 'item_add'
const BOARD_PATH = `/app/${WS_ID}/projects/${ITEM_ID}`
const ADD_PATH = `${BOARD_PATH}/add`

/** Two columns, deliberately handed over out of order: `col_a` is the leftmost (position 0), so it
 * is the one the header's "Add task" button must pre-select. */
const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'A task',
  kanban_column_id: 'col_a',
  ...overrides,
})

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn({ id: 'col_b', name: 'doing', position: 1 }),
    makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
  ],
  tasks: [makeTask()],
  ...overrides,
})

/** A real router with a catch-all route, so `router.push`/`replace` actually commit and
 * `route.query` really updates. The catch-all keeps the path opaque — `/add` is parsed by
 * `parseAppPath`, not by a route table. */
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

describe('KanbanView — the /add (add-task page) URL', () => {
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

  it('clicking the header "Add task" button pushes /add with the first column in ?column=', async () => {
    const router = await makeRouter({ path: BOARD_PATH })
    wrapper = await mountWithRouter(router)

    await wrapper.find('[data-testid="kanban-add-task-button"]').trigger('click')
    await flushPromises()

    const route = router.currentRoute.value
    expect(route.path).toBe(ADD_PATH)
    // `col_a` is position 0 and therefore the leftmost column — not the first array entry.
    expect(route.query.column).toBe('col_a')
    expect(wrapper.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)
  })

  it('a /add?column=<other> deep link opens the create panel with that column selected', async () => {
    const router = await makeRouter({ path: ADD_PATH, query: { column: 'col_b' } })
    wrapper = await mountWithRouter(router)

    expect(wrapper.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)
    // The picker prints the selected column's name, so this pins the deep-linked column itself.
    const picker = wrapper.find('[data-testid="kanban-task-detail-column-picker"]')
    expect(picker.exists()).toBe(true)
    expect(picker.text()).toContain('doing')
  })

  it('a bare /add deep link falls back to the leftmost column', async () => {
    const router = await makeRouter({ path: ADD_PATH })
    wrapper = await mountWithRouter(router)

    expect(wrapper.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-task-detail-column-picker"]').text()).toContain(
      'todo',
    )
  })

  it('closing the create panel replaces the URL back to the board path with no ?column=', async () => {
    const router = await makeRouter({ path: ADD_PATH, query: { column: 'col_b' } })
    wrapper = await mountWithRouter(router)

    const panel = wrapper.find('[data-testid="kanban-detail-panel"]')
    expect(panel.exists()).toBe(true)
    await panel.find('[data-testid="kanban-task-detail-close"]').trigger('click')
    await flushPromises()

    const route = router.currentRoute.value
    expect(route.path).toBe(BOARD_PATH)
    expect(route.query.column).toBeUndefined()
    // The page is gone with the URL.
    expect(wrapper.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(false)
  })

  it('?column= on the board path alone does NOT open the create panel', async () => {
    const router = await makeRouter({ path: BOARD_PATH, query: { column: 'col_b' } })
    wrapper = await mountWithRouter(router)

    expect(wrapper.find('[data-testid="kanban-detail-panel"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(false)
    expect(router.currentRoute.value.path).toBe(BOARD_PATH)
  })

  it('a sibling ?layout=rows survives opening the create page and closing it again', async () => {
    const router = await makeRouter({ path: BOARD_PATH, query: { layout: 'rows' } })
    wrapper = await mountWithRouter(router)

    await wrapper.find('[data-testid="kanban-add-task-button"]').trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.path).toBe(ADD_PATH)
    expect(router.currentRoute.value.query.layout).toBe('rows')
    expect(router.currentRoute.value.query.column).toBe('col_a')

    const panel = wrapper.find('[data-testid="kanban-detail-panel"]')
    await panel.find('[data-testid="kanban-task-detail-close"]').trigger('click')
    await flushPromises()

    expect(router.currentRoute.value.path).toBe(BOARD_PATH)
    expect(router.currentRoute.value.query.layout).toBe('rows')
    expect(router.currentRoute.value.query.column).toBeUndefined()
  })
})
