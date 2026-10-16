/** Regression: the code editor kept persisting across chat session switches. Root cause: the editor
 * session is global to AppLayout (not per-chat). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, reactive } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useNavigationStore } from '../stores/navigation'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState = 'open'): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const WS_ID = 'ws_editor_switch'
const SESSION_A = 'session_a'
const SESSION_B = 'session_b'

function mountWithReactiveRoute(initialQuery: Record<string, string>, initialPath: string) {
  const routeState = reactive({
    query: { ...initialQuery },
    path: initialPath,
    fullPath:
      initialPath +
      (Object.keys(initialQuery).length ? `?${new URLSearchParams(initialQuery).toString()}` : ''),
    params: {},
  })
  useRouteMock.mockReturnValue(routeState)
  const wrapper = mount(AppLayout, {
    global: {
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        ChatView: true,
        CodeViewerStage: true,
        KanbanView: true,
        DesignView: true,
      },
    },
  })
  return { wrapper, routeState }
}

// The session refs live in AppLayout setup; <script setup> bindings are proxied on wrapper.vm (same
// seam AppLayout.urlPersist.spec.ts uses for openInCodeEditor), with refs unwrapped.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const openFileOf = (wrapper: any) => wrapper.vm.codeEditorFile as unknown

describe('AppLayout — code editor clears on chat session switch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/',
      absolute: '/',
      home: '/',
      entries: [],
    } as never)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    vi.spyOn(api, 'getSession').mockResolvedValue({ id: SESSION_A, cwd: '/w' } as never)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({ cwd: '/w' } as never)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('switching the active chat clears the open file', async () => {
    vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'hello' } as never)
    const { wrapper } = mountWithReactiveRoute({}, `/app/${WS_ID}/chat/${SESSION_A}`)
    const nav = useNavigationStore()
    await nextTick()
    await nextTick()

    // Open a file in chat A (same call the sidebar explorer makes).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (wrapper.vm as any).openInCodeEditor({ filePath: 'notes.txt', cwd: '/w' })
    await nextTick()
    expect(openFileOf(wrapper)).not.toBeNull()

    // Switch to chat B the way Sidebar/ChatsList do: store first, then URL.
    nav.setActiveChat(SESSION_B, 'chat b')
    await nextTick()
    expect(openFileOf(wrapper)).toBeNull()
    wrapper.unmount()
  })

  it('a code-editor deep link still restores after the fix', async () => {
    const readMock = vi
      .spyOn(api, 'readFileContent')
      .mockResolvedValue({ content: 'deep link body' } as never)
    const { wrapper } = mountWithReactiveRoute(
      { view: 'code-editor', file: 'src/foo.ts' },
      `/app/${WS_ID}/chat/${SESSION_B}`,
    )
    await vi.waitFor(() => {
      expect(openFileOf(wrapper)).not.toBeNull()
    })
    expect(readMock).toHaveBeenCalledWith(expect.anything(), 'src/foo.ts')
    wrapper.unmount()
  })
})
