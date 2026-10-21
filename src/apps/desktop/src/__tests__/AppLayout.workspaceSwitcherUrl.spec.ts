/** URL contract pair for the header workspace switcher: 1. click-writes: Sidebar emits
 * select-workspace → AppLayout.handleSelectWorkspace PUSHES `?view=workspace&workspaceId=X`. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState = 'open'): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => initial,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => () => {
      void cb
      return () => {}
    },
  }
  stub.__stateListeners = []
  return stub as SseClient
}

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
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

const WS_1 = { id: 'ws_1', name: 'Work', icon: '📁', expanded: false, items: [] }
const WS_2 = { id: 'ws_2', name: 'Kabel', icon: '📁', expanded: false, items: [] }
const SEEDED = [WS_1, WS_2] as Workspace[]

const SidebarStub = {
  name: 'Sidebar',
  template: '<div data-sidebar-stub />',
  emits: ['navigate', 'select-workspace', 'toggle-collapse', 'resize'],
}

function mountAppLayout(routeQuery: Record<string, string>, routePath = '/app') {
  useRouteMock.mockReturnValue({
    query: routeQuery,
    path: routePath,
    fullPath:
      routePath +
      (Object.keys(routeQuery).length ? `?${new URLSearchParams(routeQuery).toString()}` : ''),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const ws = useWorkspacesStore()
  ws.workspaces.splice(0, ws.workspaces.length, ...SEEDED.map((w) => ({ ...w })))
  return mount(AppLayout, {
    global: {
      stubs: {
        Sidebar: SidebarStub,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        ChatView: true,
        CodeEditor: true,
        KanbanView: { template: '<div />', props: ['item', 'workspaceId', 'itemId'] },
        DesignView: { template: '<div />', props: ['item', 'workspaceId', 'itemId'] },
      },
    },
  })
}

describe('AppLayout — workspace switcher URL contract', () => {
  let replaceMock: ReturnType<typeof vi.fn>
  let pushMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    setActivePinia(createPinia())
    __resetSseBus()
    installSseBus(createApp({}))
    __setSseBusGlobalClient(makeStubClient('open'))
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    replaceMock = vi.fn()
    pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: SEEDED })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('click-writes: select-workspace PUSHES /app/{ws} (history entry)', async () => {
    const wrapper = mountAppLayout({}, '/app/ws_1')
    await nextTick()
    await nextTick()
    const ws = useWorkspacesStore()
    // mount-restores half of the pair (standalone ?workspaceId).
    expect(ws.activeWorkspaceId).toBe('ws_1')

    wrapper.findComponent({ name: 'Sidebar' }).vm.$emit('select-workspace', 'ws_2')
    await nextTick()
    await nextTick()

    expect(pushMock).toHaveBeenCalledWith({
      path: '/app/ws_2',
      query: {},
    })
    // User decision log: switches must create history entries — a
    // replace here would erase the previous workspace from Back.
    expect(replaceMock).not.toHaveBeenCalled()
    expect(ws.activeWorkspaceId).toBe('ws_2')
    wrapper.unmount()
  })

  it('mount-restores: ?view=workspace&workspaceId=X (no itemId) selects that workspace', async () => {
    const wrapper = mountAppLayout({ view: 'workspace', workspaceId: 'ws_2' })
    await nextTick()
    await nextTick()
    const ws = useWorkspacesStore()

    expect(ws.activeWorkspaceId).toBe('ws_2')
    expect(ws.activeWorkspace?.id).toBe('ws_2')
    // No item was open — selection-only restore must not invent one.
    expect(ws.activeWorkspaceItemId).toBeNull()
    wrapper.unmount()
  })
})
