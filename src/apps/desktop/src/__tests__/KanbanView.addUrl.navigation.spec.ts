/** KanbanView navigation between the board and the add page, over the app's real route table: the
 * board (`/projects/{id}`) and the add page (`/projects/{id}/add`) are ONE route record, so the
 * route guard sees every move between them — the browser Back button included. */
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import { defineComponent, ref, type PropType, type Ref } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import { appRoutes } from '../router/index'
import { makeLocalStorageStub } from './helpers'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type WorkspaceItem,
} from '../stores/workspaces'

const WS_ID = 'ws_nav'
const ITEM_ID = 'item_nav'
const BOARD_PATH = `/app/${WS_ID}/projects/${ITEM_ID}`
const ADD_PATH = `${BOARD_PATH}/add`

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

/** The routed component: the board, rendered INSIDE a <router-view> (so the route guards see a
 * real matched record, exactly like in the app). */
const makeBoard = () =>
  defineComponent({
    components: { KanbanView },
    props: {
      item: { type: Object as PropType<WorkspaceItem>, required: true },
      workspaceId: { type: String, required: true },
    },
    template: '<KanbanView :item="item" :workspace-id="workspaceId" />',
  })

const Root = defineComponent({ template: '<router-view />' })

/** The app's REAL route table: the board and the add page are ONE record. */
async function makeRouter(initial: {
  path: string
  query?: Record<string, string>
}): Promise<{ router: Router; wrapper: ReturnType<typeof mount> }> {
  const item = makeItem()
  const board = makeBoard()
  const projectRoute = appRoutes.find((r) => r.name === 'project')
  if (!projectRoute) throw new Error('the app route table has no "project" record')
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      {
        path: projectRoute.path,
        name: projectRoute.name,
        component: board,
        props: { item, workspaceId: WS_ID },
      },
    ],
  })
  await router.push({ path: initial.path, query: initial.query ?? {} })
  await router.isReady()

  const store = useWorkspacesStore()
  store.workspaces = [{ id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [item] }]

  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(Root, {
    global: { plugins: [router], provide: { processingState } },
  })
  await flushPromises()
  return { router, wrapper }
}

describe('KanbanView — navigating between the board and the add page', () => {
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

  it('going back to the board URL leaves the add page and shows the board again', async () => {
    const { router, wrapper: w } = await makeRouter({ path: BOARD_PATH })
    wrapper = w

    await w.find('[data-testid="kanban-add-task-button"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.path).toBe(ADD_PATH)
    expect(w.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)

    // The browser Back button: the URL is the board again, so the board must be showing.
    router.back()
    await flushPromises()
    await flushPromises()

    expect(router.currentRoute.value.path).toBe(BOARD_PATH)
    expect(w.find('[data-testid="kanban-detail-panel"]').exists()).toBe(false)
    expect(w.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(false)
  })

  it('leaving the add page for the board URL shows the board again', async () => {
    const { router, wrapper: w } = await makeRouter({ path: ADD_PATH, query: { column: 'col_b' } })
    wrapper = w
    expect(w.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)

    await router.push(BOARD_PATH)
    await flushPromises()

    expect(router.currentRoute.value.path).toBe(BOARD_PATH)
    expect(w.find('[data-testid="kanban-detail-panel"]').exists()).toBe(false)
  })

  it('navigating to the add URL opens the add page with the column the URL names', async () => {
    const { router, wrapper: w } = await makeRouter({ path: BOARD_PATH })
    wrapper = w
    expect(w.find('[data-testid="kanban-detail-panel"]').exists()).toBe(false)

    await router.push({ path: ADD_PATH, query: { column: 'col_b' } })
    await flushPromises()

    expect(w.find('[data-testid="kanban-task-detail-create-name"]').exists()).toBe(true)
    const picker = w.find('[data-testid="kanban-task-detail-column-picker"]')
    expect(picker.text()).toContain('doing')
  })
})
