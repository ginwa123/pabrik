/** Behavioural tests for the top-left "New Chat" action (task_1790528102260_4). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
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

const WS_ID = 'ws_new_chat'
const DEFAULT_ID = 'item_default'
const OTHER_ID = 'item_other'

// The default project, as the server sends it: `is_default: 1` and a path of $HOME. The `selected`
// item is the one the user happens to have open — the action must NOT create the chat there.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeItem(id: string, itemType: string, isDefault: number): any {
  return {
    id,
    name: id === DEFAULT_ID ? 'Project Default' : 'Some Project',
    item_type: itemType,
    path: id === DEFAULT_ID ? '/home/tester' : '/home/tester/repo',
    is_default: isDefault,
    kanban_columns: [],
    tasks: [],
    isLoaded: true,
    isLoading: false,
  }
}

/** A workspace holding both the default and an ordinary project. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeWorkspace(id = WS_ID): any {
  return {
    id,
    name: 'WS',
    items: [makeItem(DEFAULT_ID, 'agent', 1), makeItem(OTHER_ID, 'agent', 0)],
  }
}

// See the note on `replaceMock` in Sidebar.agentDirectChat.spec.ts.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let replaceMock: any

// `collapsed` is a PROP (`computed(() => props.collapsed ?? false)`),
// so the collapsed state has to be set at mount time — assigning to
// `wrapper.vm.isCollapsed` would write to a read-only computed.
function mountSidebar(collapsed = false) {
  return mount(Sidebar, {
    attachTo: document.body,
    props: { collapsed },
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

/** Flush the async resolve→create→navigate chain. */
async function flushAsync() {
  for (let i = 0; i < 6; i++) {
    await nextTick()
    await Promise.resolve()
  }
}

function newChatButton(): Element | null {
  return document.body.querySelector('[data-testid="sidebar-new-chat-button"]')
}

describe('Sidebar.handleNewChat — creates a chat in the workspace default project', () => {
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

  it('creates the chat in the DEFAULT project, not the selected one, and navigates to it', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
    store.setActiveWorkspace(WS_ID)
    // The user happens to have the ORDINARY project open. The action must
    // ignore that — that is the entire point of having a default.
    store.setActiveWorkspaceItem(OTHER_ID)
    const ensureSpy = vi
      .spyOn(store, 'ensureDefaultProject')
      .mockResolvedValue(makeItem(DEFAULT_ID, 'agent', 1))
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    const activeSpy = vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    expect(ensureSpy).toHaveBeenCalledWith(WS_ID)
    expect(addSpy).toHaveBeenCalledTimes(1)
    expect(addSpy).toHaveBeenCalledWith(WS_ID, DEFAULT_ID, { name: 'New Chat' })
    expect(activeSpy).toHaveBeenCalledWith('task_new_1')

    // The URL is the state: deep-linkable, refresh-safe, Back/Forward
    // correct. Asserted because a local-only ref here would make the new
    // chat unreachable by reload.
    expect(replaceMock).toHaveBeenCalledTimes(1)
    const target = replaceMock.mock.calls[0][0]
    expect(target.path).toBe(`/app/${WS_ID}/projects/${DEFAULT_ID}/chat/task_new_1`)
    wrapper.unmount()
  })

  it('D12 fast path: the default is already in the list, so NO network call', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
    store.setActiveWorkspace(WS_ID)
    // The real action, not a mock — the point is that the store's own
    // lookup finds the default and never reaches the fallback endpoint.
    const endpointSpy = vi.spyOn(api, 'getOrCreateDefaultProject')
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const found = await store.ensureDefaultProject(WS_ID)
    expect(found?.id).toBe(DEFAULT_ID)
    // The server guarantees exactly one default per workspace, so the
    // client must never pay for a round trip to learn what it already has.
    expect(endpointSpy).not.toHaveBeenCalled()

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    expect(addSpy).toHaveBeenCalledWith(WS_ID, DEFAULT_ID, { name: 'New Chat' })
    expect(endpointSpy).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('cold start: the list predates the migration, so the fallback endpoint runs once', async () => {
    const store = useWorkspacesStore()
    // A workspace with ordinary projects but NO default — the shape a
    // client holds if it was already open when Migration 094 ran.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem(OTHER_ID, 'agent', 0)] }] as any
    store.setActiveWorkspace(WS_ID)
    const endpointSpy = vi.spyOn(api, 'getOrCreateDefaultProject').mockResolvedValue({
      item: makeItem(DEFAULT_ID, 'agent', 1),
      created: true,
    })
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    expect(endpointSpy).toHaveBeenCalledTimes(1)
    expect(endpointSpy).toHaveBeenCalledWith(WS_ID)
    expect(addSpy).toHaveBeenCalledWith(WS_ID, DEFAULT_ID, { name: 'New Chat' })
    // And the new default was adopted into the store, so the Projects list
    // shows it without a refetch.
    expect(store.workspaces[0]?.items.some((i) => i.id === DEFAULT_ID)).toBe(true)
    wrapper.unmount()
  })

  it('no active workspace: the button is disabled and clicking does nothing', async () => {
    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [] as any
    const ensureSpy = vi.spyOn(store, 'ensureDefaultProject')
    const addSpy = vi.spyOn(store, 'addTask')

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    // A chat cannot exist without a workspace, and quietly creating one
    // from a sidebar click would be a surprising side effect.
    expect(ensureSpy).not.toHaveBeenCalled()
    expect(addSpy).not.toHaveBeenCalled()
    expect(replaceMock).not.toHaveBeenCalled()

    const btn = newChatButton() as HTMLButtonElement | null
    expect(btn).not.toBeNull()
    expect(btn?.disabled).toBe(true)
    expect(btn?.getAttribute('title')).toBe('Select a workspace first')
    wrapper.unmount()
  })

  it('double click creates exactly one chat', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
    store.setActiveWorkspace(WS_ID)
    // A slow resolve, so both clicks land while the first is still in the gap between "resolve the
    // default" and "create the task". The database's partial unique index protects the *project*;
    // this guard protects the *chat*.
    let releaseResolve: (() => void) | undefined
    vi.spyOn(store, 'ensureDefaultProject').mockImplementation(
      () =>
        new Promise((resolve) => {
          releaseResolve = () => resolve(makeItem(DEFAULT_ID, 'agent', 1))
        }),
    )
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    const first = sidebar.handleNewChat()
    const second = sidebar.handleNewChat()
    await nextTick()
    releaseResolve?.()
    await first
    await second
    await flushAsync()

    expect(addSpy).toHaveBeenCalledTimes(1)
    wrapper.unmount()
  })

  it('a failed ensure does NOT navigate and does NOT fabricate a local project', async () => {
    const store = useWorkspacesStore()
    // NO default in the store, so the local find misses and the endpoint is actually reached —
    // otherwise this test would pass without ever exercising the failure path.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem(OTHER_ID, 'agent', 0)] }] as any
    store.setActiveWorkspace(WS_ID)
    vi.spyOn(api, 'getOrCreateDefaultProject').mockRejectedValue(new Error('500'))
    const addSpy = vi.spyOn(store, 'addTask')
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    // Doing nothing is the right outcome. A fabricated id would navigate to
    // a project that does not exist, which is worse than a no-op.
    expect(addSpy).not.toHaveBeenCalled()
    expect(replaceMock).not.toHaveBeenCalled()
    // Still just the one ordinary project: no fabricated row.
    expect(store.workspaces[0]?.items).toHaveLength(1)
    expect(consoleSpy).toHaveBeenCalled()
    wrapper.unmount()
  })

  it('the collapse chevron is re-pinned below the New Chat row (top-24, not top-16)', () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
    store.setActiveWorkspace(WS_ID)

    const wrapper = mountSidebar()
    const toggle = document.body.querySelector('[data-testid="sidebar-collapse-toggle"]')
    // Absolutely positioned, so inserting the 40px row above the content
    // does NOT move it. At `top-16` (64px) it would sit on top of the New
    // Chat row (which ends at 88px) and swallow its clicks.
    expect(toggle?.className).toContain('top-24')
    expect(toggle?.className).not.toContain('top-16')
    wrapper.unmount()
  })

  it('fresh boot with no explicit selection: falls back to first workspace instead of staying disabled', async () => {
    const store = useWorkspacesStore()
    // Fresh boot: workspaces loaded but `activeWorkspaceId` ref never set (no dropdown pick, no
    // ?workspaceId= URL). The header already shows the first workspace via the `activeWorkspace`
    // computed — the button must follow the same precedence instead of staying disabled.
    store.workspaces = [makeWorkspace()]
    // NOTE: no setActiveWorkspace call — this is the regression.
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const wrapper = mountSidebar()
    await nextTick()
    await flushAsync()

    const btn = newChatButton() as HTMLButtonElement | null
    expect(btn).not.toBeNull()
    expect(btn?.disabled).toBe(false)

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await sidebar.handleNewChat()
    await flushAsync()

    expect(addSpy).toHaveBeenCalledWith(WS_ID, DEFAULT_ID, { name: 'New Chat' })
    expect(replaceMock).toHaveBeenCalledTimes(1)
    wrapper.unmount()
  })

  it('collapsed: the row becomes an icon but keeps its accessible name', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace()]
    store.setActiveWorkspace(WS_ID)
    const addSpy = vi.spyOn(store, 'addTask').mockResolvedValue('task_new_1')
    vi.spyOn(store, 'setActiveTask').mockImplementation(() => {})

    const wrapper = mountSidebar(true)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    await nextTick()

    const btn = newChatButton() as HTMLButtonElement | null
    // A 64px rail must not drop the only always-visible chat affordance —
    // the word does not fit, so the label moves to the accessible name.
    expect(btn).not.toBeNull()
    expect(btn?.getAttribute('aria-label')).toBe('New Chat')
    expect(btn?.textContent).not.toContain('New Chat')

    // And it still works from the collapsed state.
    await sidebar.handleNewChat()
    await flushAsync()
    expect(addSpy).toHaveBeenCalledWith(WS_ID, DEFAULT_ID, { name: 'New Chat' })
    wrapper.unmount()
  })
})
