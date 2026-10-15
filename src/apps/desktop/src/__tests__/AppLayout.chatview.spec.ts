/**
 * Regression test for the `?view=chat&session=X` welcome-page bug
 * (2026-07-16): when the URL pointed at a chat session, AppLayout
 * rendered <Chats/> (the static welcome page) instead of
 * <ChatView/>, even though the navigation store's `activeChatId`
 * was set correctly to `'chat-<session>'` during onMounted.
 *
 * Root cause: `workspacesStore.setActiveTask(null)` was called by
 * the chat-nav paths in Sidebar.vue:321 and ChatsList.vue:227 to
 * "clear any active task before activating the chat". The
 * unconditional `useNavigationStore().clearActiveChat()` inside
 * `setActiveTask` (added 2026-07-14 to fix a separate SSE race
 * condition) was ALSO firing on the null taskId path, undoing the
 * just-set `setActiveChat(...)` two lines earlier. The
 * v-else-if chain at AppLayout.vue:1611 then failed
 * (`activeChatId.startsWith('chat-')` was false on the empty
 * string) and fell through to <Chats/>.
 *
 * Fix: gate the `clearActiveChat()` inside both navigationStore.setActiveTask
 * and workspacesStore.setActiveTask on `taskId !== null` (task
 * ACTIVATION clears the chat, task CLEARING does not).
 * AppLayout.handleCloseTaskView now explicitly calls
 * `navigationStore.clearActiveChat()` since that's the one path
 * that needs both clear.
 */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

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

function installBusForTests() {
  __resetSseBus()
  installSseBus()
  __setSseBusGlobalClient(makeStubClient())
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const SESSION_ID = 'task_xxx'

function mountAppLayoutForChatTest() {
  // Pre-seed stores the same way AppLayout's onMounted would, so
  // the route watcher doesn't have to wait for any fetch.
  const ws = useWorkspacesStore()
  ws.workspaces = [] // empty workspace tree (no kanban / no parent task)
  return mount(AppLayout, {
    global: {
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        // STUB ChatView with a stub-active flag so the test can
        // assert it actually mounted.
        ChatView: {
          template: '<div data-testid="chatview-stub" />',
          props: [
            'chatId',
            'chatName',
            'type',
            'cwd',
            'taskId',
            'taskName',
            'projectName',
            'showHeader',
          ],
        },
        // STUB Chats with a stub-active flag too.
        Chats: {
          template: '<div data-testid="chats-stub" />',
        },
        SettingsView: true,
        CodeEditor: true,
        KanbanView: true,
        DesignView: true,
      },
    },
  })
}

describe('AppLayout — ?view=chat&session=X renders <ChatView>, not <Chats/> (regression: 2026-07-16 welcome-page bug)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Mock the workspace-store API calls fired by onMounted →
    // initializeFromSystemFolder → init()/fetchSystemFolder().
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    // fetchChatSessionCwd (AppLayout.vue) fires from onMounted when the URL has a `session` query
    // param. Stub the session detail read (getSession) plus getChatHistory (used by other mount
    // paths).

    // Without these, jsdom's fetch throws an ERR_INVALID_URL on every test (no test server) — the
    // error is caught by AppLayout's own try/catch so the test still passes, but it floods the
    // output.

    // Boot rewrite for ?view=chat resolves the owning workspace via the session-detail endpoint.
    // Mock it so the async rewrite completes within the test's ticks (a real fetch would stall).
    vi.spyOn(api, 'getSessionWorkspaceId').mockResolvedValue('ws_chatview')
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,

      next_cursor: null,
      total: 0,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // Default the route mock to the failing URL.
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: SESSION_ID } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=chat&session=${SESSION_ID}`,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('navigationStore.activeChatId ends up as `chat-<session>` (the onMounted URL-init path fires)', async () => {
    const wrapper = mountAppLayoutForChatTest()
    await nextTick()
    const nav = useNavigationStore()
    expect(nav.activeChatId).toBe(`chat-${SESSION_ID}`)
    wrapper.unmount()
  })

  it('renders <ChatView/> (not <Chats/>) when URL is ?view=chat&session=X', async () => {
    // This is the core regression: before the fix, the v-else-if
    // chain at AppLayout.vue:1611 evaluated
    // `activeChatId.startsWith('chat-')` to false (because the
    // unconditional clearActiveChat() in setActiveTask had
    // re-cleared the activeChatId that onMounted had just set),
    // and the chain fell through to <Chats/> (the static welcome
    // page). The user-visible symptom: navigating to
    // `?view=chat&session=task_X` showed "Hello! I am your AI
    // coding assistant" instead of the actual chat history.
    const wrapper = mountAppLayoutForChatTest()
    // Two ticks: the async boot rewrite sets the chat on the first,
    // Vue re-renders the ChatView branch on the second.
    await nextTick()
    await nextTick()
    expect(wrapper.find('[data-testid="chatview-stub"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chats-stub"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('regression: explicitly invoking the chat-nav sequence (setActiveChat + setActiveTask(null)) does NOT clear activeChatId', async () => {
    // Simulates the exact sequence that Sidebar.vue:316-322 and
    // ChatsList.vue:220-232 perform when the user clicks a chat:
    //
    //   navigationStore.setActiveChat(sessionId, name)
    //   workspacesStore.setActiveWorkspaceItem(null)
    //   workspacesStore.setActiveTask(null)        // ← used to clear chat
    //   router.replace({ ..., view: 'chat', session: sessionId })
    //
    // Pre-fix: setActiveTask(null) inside the workspacesStore
    // called clearActiveChat() unconditionally, so
    // nav.activeChatId ended up '' instead of `chat-<session>`.
    const ws = useWorkspacesStore()
    const nav = useNavigationStore()

    nav.setActiveChat(SESSION_ID, 'Test Chat')
    expect(nav.activeChatId).toBe(`chat-${SESSION_ID}`)

    ws.setActiveWorkspaceItem(null)
    ws.setActiveTask(null)

    expect(nav.activeChatId).toBe(`chat-${SESSION_ID}`)
    expect(nav.activeChatName).toBe('Test Chat')
  })

  it('regression: activating a task STILL clears the chat (the opposite-direction invariant)', async () => {
    // The 2026-07-14 original fix wanted this property: when the user clicks a task, any active
    // chat should be cleared so subsequent SSE session_created events can't navigate back into the
    // previous chat.

    // Gating the clear on `taskId !== null` preserves this property for the activation path while
    // fixing the null path.
    const ws = useWorkspacesStore()
    const nav = useNavigationStore()

    nav.setActiveChat('pre_task', 'Pre-Task Chat')
    expect(nav.activeChatId).toBe('chat-pre_task')

    ws.setActiveTask('task_xyz')

    expect(nav.activeChatId).toBe('')
    expect(ws.activeTaskId).toBe('task_xyz')
  })
})
