// Regression test for the agent-tool checkbox render bug.
//
// Bug: when the user lands directly on the agent view
// (?view=workspace&itemId=AGENT_ID, no chat task), the AppLayout
// watcher on `activeTask.value` never fires (activeTask is null),
// so `agentTools` stays empty. The checkboxes render as unchecked
// even when the rows exist in agent_tools with enabled=1.
//
// Symptom: clicking any checkbox sent a POST that returned 409
// "tool already enabled for this agent" because the row was
// already in the DB from a prior session.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { createApp, ref, nextTick } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
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
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

const WS_ID = 'ws_agent_view'
const AGENT_ITEM_ID = 'item_agent_xxx'

const makeAgentItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: AGENT_ITEM_ID,
  name: 'My Agent',
  item_type: 'agent',
  tasks: [],
  ...overrides,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any)

function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient() as SseClient)
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return {
    state: 'open',
    lastError: null,
    getState: () => 'open',
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
    reconnect: () => {},
  }
}

function setRoute(q: Record<string, string>, path = '/app') {
  useRouteMock.mockReturnValue({
    query: q,
    path,
    fullPath: path + '?' + new URLSearchParams(q).toString(),
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

/**  * Mount AppLayout with an agent item as the active workspace item and NO chat task. Returns the
 * wrapper so the test can inspect the props passed to the AgentView stub. */
function mountAgentView(): VueWrapper {
  const ws = useWorkspacesStore()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeAgentItem()] }] as any
  // Serve the fixtures from the API mocks so init() populates
  // instead of wiping (lazy-init safe snapshot).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const snapshot = JSON.parse(JSON.stringify(ws.workspaces)) as any[]
  vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: snapshot })
  vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({
    items: snapshot[0].items,
    count: snapshot[0].items.length,
  })
  setRoute(
    {},
    `/app/${WS_ID}/projects/${AGENT_ITEM_ID}`,
  )
  return mount(AppLayout, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
    attachTo: document.body,
  })
}

describe('AppLayout — agent tools fetch on agent view mount (no chat task)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(), writable: true, configurable: true,
    })
    installBusForTests()
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [], has_more: false, next_cursor: null, total: 0,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/', absolute: '/', home: '/', entries: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    useRouteMock.mockReset()
    useRouterMock.mockReset()
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('calls api.getAgent when the user lands directly on an agent view (no chat task)', async () => {
    const getAgentSpy = vi.spyOn(api, 'getAgent').mockResolvedValue({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: { id: AGENT_ITEM_ID, workspace_item_id: AGENT_ITEM_ID, description: '', created_at: '', updated_at: '' } as any,
      knowledge: [],
      tools: ['bash', 'read_file'],
      system_prompts: [],
    })

    const wrapper = mountAgentView()
    await flushPromises()
    await nextTick()

    expect(getAgentSpy).toHaveBeenCalledWith(WS_ID, AGENT_ITEM_ID)
    wrapper.unmount()
  })

  it('passes the loaded enabled tools to AgentView so the checkboxes render as checked', async () => {
    vi.spyOn(api, 'getAgent').mockResolvedValue({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: { id: AGENT_ITEM_ID, workspace_item_id: AGENT_ITEM_ID, description: '', created_at: '', updated_at: '' } as any,
      knowledge: [],
      tools: ['bash', 'read_file'],
      system_prompts: [],
    })

    // Stub AgentView so we can inspect the props it receives.
    let lastProps: Record<string, unknown> | undefined
    const AgentViewStub = {
      template: '<div data-testid="agent-view-stub" />',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      props: ['item', 'workspaceId', 'itemId', 'knowledge', 'tools'] as any,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      setup(props: any) {
        lastProps = props as unknown as Record<string, unknown>
        return () => null
      },
    }

    setRoute({}, `/app/${WS_ID}/projects/${AGENT_ITEM_ID}`)
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeAgentItem()] }] as any
    // Serve the fixtures from the API mocks so init() populates
    // instead of wiping (lazy-init safe snapshot).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const snapshot = JSON.parse(JSON.stringify(ws.workspaces)) as any[]
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: snapshot })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({
      items: snapshot[0].items,
      count: snapshot[0].items.length,
    })

    const wrapper = mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
        stubs: {
          // The stub MUST be defined this way so the props are captured
          // synchronously during the first render.
          AgentView: AgentViewStub,
        },
      },
      attachTo: document.body,
    })
    await flushPromises()
    await nextTick()

    expect(lastProps).toBeDefined()
    expect(lastProps!.tools).toEqual(['bash', 'read_file'])
    wrapper.unmount()
  })

  it('re-fetches agent tools when the user navigates to a different agent', async () => {
    const getAgentSpy = vi.spyOn(api, 'getAgent').mockResolvedValue({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      agent: { id: AGENT_ITEM_ID, workspace_item_id: AGENT_ITEM_ID, description: '', created_at: '', updated_at: '' } as any,
      knowledge: [],
      tools: ['bash'],
      system_prompts: [],
    })

    const wrapper = mountAgentView()
    await flushPromises()
    await nextTick()
    const firstCallCount = getAgentSpy.mock.calls.length
    expect(firstCallCount).toBeGreaterThan(0)

    // Now switch to a different agent and confirm a re-fetch.
    const OTHER_AGENT_ID = 'item_agent_yyy'
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeAgentItem({ id: OTHER_AGENT_ID })] }] as any
    ws.activeWorkspaceItemId = OTHER_AGENT_ID
    await flushPromises()
    await nextTick()

    expect(getAgentSpy).toHaveBeenCalledWith(WS_ID, OTHER_AGENT_ID)
    expect(getAgentSpy.mock.calls.length).toBeGreaterThan(firstCallCount)
    wrapper.unmount()
  })
})
