import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { createApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore, type WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const WS_ID = 'ws_settings_shortcut'
const ITEM_ID = 'item_settings_shortcut'

const { useRouteMock, useRouterMock, resolveMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(),
  resolveMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

function makeItem(itemType: 'agent' | 'routine' | 'kanban'): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Settings item',
    item_type: itemType,
    path: '/tmp/settings-item',
    tasks: [],
  }
}

function makeSseClient() {
  return {
    state: 'open',
    lastError: null,
    getState: () => 'open',
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    reconnect: () => {},
    close: () => {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any
}

function mountSidebar(item: WorkspaceItem) {
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: WS_ID,
      name: 'Settings workspace',
      expanded: true,
      items: [item],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any,
  ]
  return mount(Sidebar, {
    attachTo: document.body,
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

async function clickGoToSettings(item: WorkspaceItem) {
  const wrapper = mountSidebar(item)
  const row = wrapper.find('[data-testid="item-name"]').element.closest('button')!
  row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 120, clientY: 160 }))
  await nextTick()
  const entry = document.body.querySelector(
    '[data-testid="go-to-settings-item"]',
  ) as HTMLButtonElement | null
  expect(entry).not.toBeNull()
  entry!.click()
  await nextTick()
  wrapper.unmount()
}

describe('Sidebar Go to settings browser URL', () => {
  let openSpy: ReturnType<typeof vi.spyOn>

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
    __setSseBusGlobalClient(makeSseClient())
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' })
    resolveMock.mockImplementation(
      (location: { path: string; query?: Record<string, string> }) => ({
        href: `${location.path}${new URLSearchParams(location.query ?? {}).toString() ? `?${new URLSearchParams(location.query ?? {})}` : ''}`,
      }),
    )
    useRouterMock.mockReturnValue({ replace: vi.fn(), push: vi.fn(), resolve: resolveMock })
    openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
  })

  afterEach(() => {
    document.body.innerHTML = ''
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('opens the item project URL for an agent in a new browser tab', async () => {
    await clickGoToSettings(makeItem('agent'))

    expect(openSpy).toHaveBeenCalledTimes(1)
    expect(openSpy).toHaveBeenCalledWith(`/app/${WS_ID}/projects/${ITEM_ID}`, '_blank', 'noopener')
  })

  it('opens the item project URL for a routine in a new browser tab', async () => {
    await clickGoToSettings(makeItem('routine'))

    expect(openSpy).toHaveBeenCalledWith(`/app/${WS_ID}/projects/${ITEM_ID}`, '_blank', 'noopener')
  })

  it('opens the workspace-scoped kanban settings URL in a new browser tab', async () => {
    await clickGoToSettings(makeItem('kanban'))

    expect(openSpy).toHaveBeenCalledWith(
      `/app/${WS_ID}/projects/${ITEM_ID}/settings`,
      '_blank',
      'noopener',
    )
  })
})
