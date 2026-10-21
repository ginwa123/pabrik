/** Sidebar header → WorkspaceSwitcher wiring. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore, type Workspace } from '../stores/workspaces'
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

const SEEDED: Workspace[] = [
  { id: 'ws_a', name: 'agentic coding', icon: '📁', expanded: false, items: [] },
  { id: 'ws_b', name: 'kabelweb', icon: '📁', expanded: false, items: [] },
] as Workspace[]

function mountSidebar() {
  const store = useWorkspacesStore()
  store.workspaces.splice(0, store.workspaces.length, ...SEEDED.map((w) => ({ ...w })))
  return mount(Sidebar, {
    attachTo: document.body,
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('Sidebar header WorkspaceSwitcher wiring', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    installSseBus(createApp({}))
    __setSseBusGlobalClient(makeStubClient('open'))
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    useRouteMock.mockImplementation(() => ({ query: {}, path: '/app', fullPath: '/app' }))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('renders the resolved active workspace on the header trigger', async () => {
    const wrapper = mountSidebar()
    await nextTick()
    // No explicit selection yet → activeWorkspace getter falls back
    // to the first workspace, so the header shows a real name (the
    // hard-coded word is gone).
    expect(wrapper.find('[data-testid="workspace-switcher-trigger"]').text()).toContain(
      'agentic coding',
    )
    wrapper.unmount()
  })

  it('option click forwards selectWorkspace with the id (→ AppLayout push)', async () => {
    const wrapper = mountSidebar()
    await nextTick()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-option-ws_b"]').trigger('click')
    await nextTick()

    expect(wrapper.emitted('selectWorkspace')).toEqual([['ws_b']])
    wrapper.unmount()
  })

  it('rename action opens the RenameWorkspaceModal', async () => {
    const wrapper = mountSidebar()
    await nextTick()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-rename-ws_b"]').trigger('click')
    await nextTick()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((wrapper.vm as any).showRenameWorkspaceModal).toBe(true)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((wrapper.vm as any).renameTargetWorkspaceId).toBe('ws_b')
    wrapper.unmount()
  })

  it('delete action opens the delete-workspace ConfirmDialog', async () => {
    const wrapper = mountSidebar()
    await nextTick()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-delete-ws_b"]').trigger('click')
    await nextTick()

    // ConfirmDialog teleports to <body> (see deleteDesignPage spec).
    expect(document.body.textContent ?? '').toMatch(/delete workspace/i)
    wrapper.unmount()
  })

  it('"+ New workspace" opens the WorkspaceModal', async () => {
    const wrapper = mountSidebar()
    await nextTick()
    await wrapper.find('[data-testid="workspace-switcher-trigger"]').trigger('click')
    await wrapper.find('[data-testid="workspace-switcher-add-workspace"]').trigger('click')
    await nextTick()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((wrapper.vm as any).showAddWorkspaceModal).toBe(true)
    wrapper.unmount()
  })
})
