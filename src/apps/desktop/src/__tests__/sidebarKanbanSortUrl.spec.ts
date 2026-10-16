/** Behavioural tests for Sidebar's handleSelectItem when the user clicks a kanban workspace item
 * (kanban default-URL, 2026-08-06). Why. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref, createApp } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import * as api from '../api'

// Local SseClient stub — mirrors the pattern in sidebarActiveState.spec.ts. The real SseClient type
// isn't exported from sseBus, so the stub is typed `any` to match `__setSseBusGlobalClient`.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(initial: 'connecting'): any {
  const stub = {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
  return stub
}

// Stub the router so we don't pull in a real Router. handleSelectItem
// doesn't call the router directly — it emits `navigate` which
// AppLayout handles. Here we only need Sidebar's emit to be observed.
const { useRouterMock } = vi.hoisted(() => ({
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: vi.fn(() => ({ query: {}, path: '/', fullPath: '/' })),
  }
})

function mountSidebar() {
  return mount(Sidebar, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

const WS_ID = 'ws_sortby'
const KANBAN_ID = 'item_kanban_sortby'
const FOLDER_ID = 'item_folder_sortby'
const DESIGN_ID = 'item_design_sortby'

function makeFolderItem(overrides: Record<string, unknown> = {}) {
  return {
    id: FOLDER_ID,
    name: 'Folder',
    item_type: 'folder',
    path: '/tmp',
    isLoaded: true,
    isLoading: false,
    ...overrides,
  }
}

function makeDesignItem(overrides: Record<string, unknown> = {}) {
  return {
    id: DESIGN_ID,
    name: 'Design',
    item_type: 'design',
    path: '/tmp',
    isLoaded: true,
    isLoading: false,
    ...overrides,
  }
}

describe('Sidebar.handleSelectItem — kanban default-URL emits sortsParam (2026-08-06)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem: vi.fn(() => null),
        setItem: vi.fn(),
        removeItem: vi.fn(),
        clear: vi.fn(),
      },
      writable: true,
      configurable: true,
    })
    // ChatsList (a child of Sidebar) calls useSseBus() in setup. We
    // install a stub bus before mount so its session listener
    // registration succeeds.
    __resetSseBus()
    const busApp = createApp({})
    installSseBus(busApp)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    // Silence getChats — Sidebar's mounted children may try to fetch.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    // Stub listKanbanColumns (used by the click handler when
    // columns aren't loaded). Returns columns matching the kanban
    // item fixture so the URL gets the expected sorts param.
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({
      columns: [
        { id: 'col_a', name: 'todo', workspace_item_id: KANBAN_ID, position: 0, created_at: '2026-01-01' },
        { id: 'col_b', name: 'in_progress', workspace_item_id: KANBAN_ID, position: 1, created_at: '2026-01-01' },
      ],
      count: 2,
    })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('clicking a folder item does NOT emit sortsParam', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeFolderItem()],
       
      },
    //
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any

 

    const wrapper = mountSidebar()
    //
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any

    await layout.handleSelectItem(WS_ID, FOLDER_ID)
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    const last = navEmits![navEmits!.length - 1]!
    expect(last[0]).toBe('workspace')
    expect(last[4]).toBe(FOLDER_ID)
    expect(last[6]).toBeUndefined() // no sortsParam for folders

    wrapper.unmount()
  })

  it('clicking a design item does NOT emit sortsParam', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
         
        expanded: true,
        items: [makeDesignItem()],
      },
     
    //
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any

    const wrapper = mountSidebar()
    //
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any

    await layout.handleSelectItem(WS_ID, DESIGN_ID)
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    const last = navEmits![navEmits!.length - 1]!
    expect(last[4]).toBe(DESIGN_ID)
    expect(last[6]).toBeUndefined() // no sortsParam for designs

    wrapper.unmount()
  })
})