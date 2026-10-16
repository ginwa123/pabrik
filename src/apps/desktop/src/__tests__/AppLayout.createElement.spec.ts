/** Integration test for the full wire: DesignView `@create-element` → AppLayout
 * `handleDesignCreateElement` → `useDesignHandlers.create Element` →
 * `workspacesStore.addDesignElement` → api addDesignElement. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore, type WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'
import * as api from '../api'

const { addDesignElementMock } = vi.hoisted(() => ({
  addDesignElementMock: vi.fn().mockResolvedValue({
    id: 'el_x',
    page_id: 'page_1',
    parent_id: '',
    name: 'Created via dialog',
    type: 'rectangle',
    x: 0, y: 0, width: 100, height: 100,
    rotation: 0, opacity: 1, fill: '', stroke: '', stroke_width: 0,
    corner_radius: 0, text_content: '', text_style: '',
    image_url: '', file_path: '',
    z_index: 0, position: 0,
    created_at: '', updated_at: '',
  }),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return { ...actual, addDesignElement: addDesignElementMock }
})

const {
  useRouteMock,
  useRouterMock,
} = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

const WS_ID = 'ws_1'
const DESIGN_ITEM_ID = 'item_design_1'

function makeStubClient(): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function makeDesignItem(): WorkspaceItem {
  return {
    id: DESIGN_ITEM_ID,
    name: 'Design',
    item_type: 'design',
    tasks: [],
  } as WorkspaceItem
}

function mountAppLayout(): VueWrapper {
  return mount(AppLayout, {
    attachTo: document.body,
    global: {
      provide: { processingState: ref({}) },
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        SettingsView: true,
        CodeEditor: true,
        KanbanView: true,
        // CRITICAL: do NOT stub DesignView — we want the real <Teleport to="body"> content to
        // render so document.querySelector can find the + Element button. The dialog itself uses
        // Teleport so document.querySelector still works regardless of where DesignView mounts.
        Chats: true,
        DesignChatDialog: true,
      },
    },
  })
}

describe('AppLayout.handleDesignCreateElement wire (bug: add element manual not working)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    installSseBus()
    __setSseBusGlobalClient(makeStubClient())

    // Quiet the AppLayout init() calls.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
     
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
       
      next_cursor: null,
       
      total: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'listDesignPages').mockResolvedValue({ pages: [] } as any)
    vi.useFakeTimers()
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    // Reset the hoisted addDesignElementMock between tests (it
    // accumulates calls across tests in this describe block otherwise
    // and bleeds into the next test's assertions).
    vi.clearAllMocks()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    wrapper?.unmount()
    wrapper = null
   
  })

  function rewireApiForFixture(store: ReturnType<typeof useWorkspacesStore>) {
    // Snapshot NOW (JSON): lazy init() wipes the tree before reading mocks.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const snapshot = JSON.parse(JSON.stringify(store.workspaces)) as any[]
     
    vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => {
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { workspaces: snapshot as any }
    })
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (wsId: string) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const ws = snapshot.find((w: any) => w.id === wsId)
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { items: (ws?.items ?? []) as any, count: ws?.items?.length ?? 0 }
    })
    vi.spyOn(api, 'getTasks').mockImplementation(async () => {
      return { tasks: [], has_more: false, next_cursor: null }
    })
    vi.spyOn(api, 'listDesignPages').mockImplementation(async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { pages: [] } as any
     
    })
  }

  it('routes @create-element payload through to api.addDesignElement', async () => {
    // Mount AppLayout on a design item.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [makeDesignItem()] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveDesignPage('page_1')
    rewireApiForFixture(store)

    wrapper = mountAppLayout()
    await flushPromises()

    // The handler is exposed via defineExpose so we can invoke the SAME function the
    // @create-element template binding routes to.
    const exposed = wrapper.vm as unknown as {
      handleDesignCreateElement: (body: {
        name: string
        type: 'rectangle' | 'ellipse' | 'text' | 'image' | 'frame' | 'group'
        html: string
      }) => Promise<void>
    }
    await exposed.handleDesignCreateElement({
      name: 'Hello',
      type: 'rectangle',
      html: '<div>hi</div>',
    })

    expect(addDesignElementMock).toHaveBeenCalledTimes(1)
    expect(addDesignElementMock).toHaveBeenCalledWith(
      WS_ID,
      DESIGN_ITEM_ID,
      'page_1',
      { name: 'Hello', type: 'rectangle', html: '<div>hi</div>' },
    )
  })

  it('is a quiet no-op when activeWorkspace or activeWorkspaceItem is missing', async () => {
    // AppLayout's handler guards on the active workspace + item. If either is missing (race window
    // during workspace/item switch) the handler must NOT call the api. Defensive guard matches
    // handleDesignUpdateElement / handleDesignDeleteElement.
    const store = useWorkspacesStore()
    // No activeWorkspace/Item set — the guard fires and bails.
    rewireApiForFixture(store)

    wrapper = mountAppLayout()
    await flushPromises()

    const exposed = wrapper.vm as unknown as {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      handleDesignCreateElement: (body: any) => Promise<void>
    }
    await exposed.handleDesignCreateElement({
      name: 'X', type: 'rectangle', html: '',
    })

    expect(addDesignElementMock).not.toHaveBeenCalled()
  })
})
