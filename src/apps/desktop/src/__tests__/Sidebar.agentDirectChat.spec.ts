/** Behavioural tests for agent-mode direct-to-chat (2026-09-09). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(initial: 'connecting'): any {
  return {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/app', fullPath: '/app' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

const WS_ID = 'ws_agent_direct_chat'
const ITEM_ID = 'item_agent_direct_chat'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeItem(itemType: string): any {
  return {
    id: ITEM_ID,
    name: itemType,
    item_type: itemType,
    path: '/tmp',
    kanban_columns: [],
    tasks: [],
    isLoaded: true,
    isLoading: false,
  }
}

// `any`: `ReturnType<typeof vi.fn>` resolves to `Mock<Procedure | Constructable>` in this vitest
// version, which `vue-tsc --build` rejects at the `mockReturnValue({ replace })` call below (TS2322).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let replaceMock: any

function mountSidebar() {
  return mount(Sidebar, {
    attachTo: document.body,
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

function pickerInDom(): Element | null {
  return document.body.querySelector('[data-testid="add-task-picker"]')
}

/** Flush the async create+navigate chain (`addTask` → `setActiveTask` → `router.replace`). */
async function flushAsync() {
  await nextTick()
  await Promise.resolve()
  await nextTick()
  await Promise.resolve()
  await nextTick()
}

describe('Sidebar.handleAddTask — agent-mode skips picker, opens chat directly (2026-09-09)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting') as SseClient)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    useRouteMock.mockImplementation(() => ({
      query: {},
      path: '/app',
      fullPath: '/app',
    }))
    replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('agent item: skips the picker, creates a New Chat task and navigates', async () => {
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    const activeSpy = vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem('agent')] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleAddTask(WS_ID, makeItem('agent'))
    await flushAsync()

    // Direct create — same payload as the picker Standard-Chat path.
    expect(addSpy).toHaveBeenCalledTimes(1)
    expect(addSpy).toHaveBeenCalledWith(WS_ID, ITEM_ID, { name: 'New Chat' })
    // Open the chat.
    expect(activeSpy).toHaveBeenCalledWith('task_new_1')
    expect(replaceMock).toHaveBeenCalledTimes(1)
    // No picker dialog was ever shown.
    expect(pickerInDom()).toBeNull()
    wrapper.unmount()
  })

  it('folder item (regression): still opens the picker, creates nothing yet', async () => {
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem('folder')] }] as any

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.handleAddTask(WS_ID, makeItem('folder'))
    await nextTick()

    expect(addSpy).not.toHaveBeenCalled()
    expect(replaceMock).not.toHaveBeenCalled()
    expect(pickerInDom()).not.toBeNull()
    wrapper.unmount()
  })
})
