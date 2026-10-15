/**
 * Regression tests for the "active state leaks across Chats ↔ workspace
 * item" bug. Selecting a chat must clear `activeWorkspaceItemId` in the
 * workspaces store, and vice versa. Before the fix these tests fail.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, reactive, ref } from 'vue'

import * as api from '../api'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import ChatsList from '../components/views/ChatsList.vue'
import AppLayout from '../components/AppLayout.vue'
import { flushPromises, mount } from '@vue/test-utils'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

// ChatsList calls useRouter() in setup; the `mocks: { $router: ... }`
// option below only patches `this.$router` (Options API), so we must
// stub the composable at module level. The AppLayout tests below
// override `useRouteMock.mockReturnValue(...)` per-test to drive the
// URL-driven chat navigation paths. We pass-through the real
// `createMemoryHistory` / `createRouter` from `importActual` so any
// future test that wants a real router can use it.
const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/', fullPath: '/' })),
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

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      // Real Vue ref — ChatsList has `watch(processingState, ..., { deep: true })` (lines 110-119
      // and 367-372). A plain `{ value: {} }` object logs `[Vue warn]: Invalid watch source` and
      // turns the watchers into silent no-ops, hiding reactivity regressions.
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('sidebar active-state exclusivity', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatsList and AppLayout both call workspacesStore.onSessionEvent(cb) synchronously in setup,
    // which now requires the sseBus to be installed (Chunk 6 of unify-frontend-sse). Install a stub
    // bus before mounting.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('clicking a chat row clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_42')
    expect(ws.activeWorkspaceItemId).toBe('item_42')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push fake item into the local navItems ref
    wrapper.vm.navItems = [{ id: 'chat_abc', name: 'My Chat', active: false, processing: false }]
    // @ts-expect-error: invoke internal method
    await wrapper.vm.setActive('chat_abc')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('createChat is gone (removed 2026-09-22) — no method, no "+" button', async () => {
    // New chats are created from workspace items (projects), not from
    // a "+" button — every chat belongs to a workspace so the list
    // can stay scoped. This pins the removal.
    const wrapper = mountChatsList()
    await nextTick()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((wrapper.vm as any).createChat).toBeUndefined()
    expect(wrapper.find('[data-testid="chats-new-chat-button"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="collapsed-new-chat-button"]').exists()).toBe(false)
  })

  it('removing the active chat clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_77')
    const nav = useNavigationStore()
    nav.setActiveChat('chat_del', 'Doomed Chat')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push a fake active chat
    wrapper.vm.navItems = [{ id: 'chat_del', name: 'Doomed Chat', active: true, processing: false }]
    vi.spyOn(api, 'deleteChat').mockResolvedValue({ success: true })
    await wrapper.vm.removeChat('chat_del')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('removing a non-active chat does NOT clear activeWorkspaceItemId', async () => {
    // Guards the `if (wasActive)` reset in removeChat: deleting an
    // inactive chat must not disturb the workspace-item selection.
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_keep')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push a fake navItems with a different ACTIVE chat
    wrapper.vm.navItems = [
      { id: 'chat_active', name: 'Active', active: true, processing: false },
      { id: 'chat_doomed', name: 'Doomed', active: false, processing: false },
    ]
    vi.spyOn(api, 'deleteChat').mockResolvedValue({ success: true })
    // No @ts-expect-error needed here: `removeChat` is exposed via ChatsList.vue's `defineExpose({
    // ...removeChat, ... })`. Compare with the first test, which DOES need it for `setActive`
    // (closure-only, not exposed). The asymmetry reflects `defineExpose` membership.
    await wrapper.vm.removeChat('chat_doomed')

    expect(ws.activeWorkspaceItemId).toBe('item_keep')
  })

  // Inverse direction (task → chat) regressions: clicking a chat must also
  // clear the workspacesStore.activeTaskId, not just activeWorkspaceItemId.
  it('clicking a chat row clears activeTaskId (inverse direction)', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveTask('task_old')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push fake item
    wrapper.vm.navItems = [{ id: 'chat_abc', name: 'My Chat', active: false, processing: false }]
    // @ts-expect-error: invoke internal method
    await wrapper.vm.setActive('chat_abc')

    expect(ws.activeTaskId).toBeNull()
  })

  it('clicking a chat row clears both item and task (inverse direction)', async () => {
    // Combined coverage for the removed createChat clearing: a chat
    // activation clears the workspace item AND the active task.
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_99')
    ws.setActiveTask('task_old')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push fake item
    wrapper.vm.navItems = [{ id: 'chat_abc', name: 'My Chat', active: false, processing: false }]
    // @ts-expect-error: invoke internal method
    await wrapper.vm.setActive('chat_abc')

    expect(ws.activeWorkspaceItemId).toBeNull()
    expect(ws.activeTaskId).toBeNull()
  })
})

describe('AppLayout URL-driven chat navigation', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // AppLayout now includes <SseStatusBadge /> (Chunk 7), which calls
    // `useSseBus()` synchronously in setup. Without a bus install, the
    // badge throws "useSseBus called before installSseBus" and the
    // whole mount fails. Install a stub bus first — the badge only
    // reads `state` and doesn't subscribe to any event channels.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    // Mock the workspace API calls triggered by `workspacesStore.initializeFromSystemFolder()` in
    // onMounted. The call is fire-and-forget (no `await` in AppLayout) but we still mock it to
    // avoid unhandled promise rejections / noisy console output in test logs.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })

    // Mock the chat session API calls triggered by
    // `fetchChatSessionCwd()` when the URL is `?view=chat&session=X`.
    vi.spyOn(api, 'getSession').mockResolvedValue({
      sessionId: 'chat_url',
      sessionName: 'URL Chat',
      cwd: '/tmp',
      createdAt: '',
      agent: '',
    })
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
      next_cursor: null,
    })

    // Reset the route mock to a clean default. Individual tests below
    // override this to drive specific URL→state transitions in
    // AppLayout.onMounted and the route.query watcher.
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',

      fullPath: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('clears activeWorkspaceItemId when URL is ?view=chat&session=X on mount', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_stale')
    expect(ws.activeWorkspaceItemId).toBe('item_stale')

    // Drive AppLayout's onMounted chat-view branch by pretending the
    // page was reloaded with a chat-session URL.
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_url' },

      path: '/app',
      fullPath: '/app?view=chat&session=chat_url',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mount(AppLayout, {
      global: {
        stubs: {
          Sidebar: true,
          RightSidebar: true,
          GitFileViewer: true,
          SkillDetail: true,
          ChatView: true,
          Chats: true,
          SettingsView: true,
          CodeEditor: true,
        },
      },
    })
    await flushPromises()
    wrapper.unmount()

    // The fix: onMounted's chat branch must reset the workspace-item
    // active state — the URL is the source of truth, and it points
    // to a chat.
    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('clears activeWorkspaceItemId when URL watch fires for chat view', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_from_url_watch')
    expect(ws.activeWorkspaceItemId).toBe('item_from_url_watch')

    // Mount with a non-chat initial route so onMounted's chat branch
    // (lines 38-43) does NOT fire. This test exercises site 4 of the 5
    // reset sites: the `watch(() => route.query, ...)` callback in
    // AppLayout.vue (lines 403-508), specifically the
    // `view === 'chat' && sessionId` branch at lines 479-496.
    //
    // NOTE on the reactive wrapper: `route = useRoute()` is captured
    // at setup time (AppLayout.vue line 23), so a post-mount
    // `useRouteMock.mockReturnValue(...)` would NOT update `route`
    // and the watch would never fire. We instead return a `reactive`
    // object from the mock and mutate its `query` directly — that's
    // the only way to trigger Vue's reactivity for a captured
    // (non-reactive) mock return value.
    const routeObj = reactive({
      query: { view: 'workspace' } as Record<string, string>,

      path: '/app',
      fullPath: '/app?view=workspace',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(routeObj as any)

    const wrapper = mount(AppLayout, {
      global: {
        stubs: {
          Sidebar: true,
          RightSidebar: true,
          GitFileViewer: true,
          SkillDetail: true,
          ChatView: true,
          Chats: true,
          SettingsView: true,
          CodeEditor: true,
        },
      },
    })
    await flushPromises()

    // Sanity: onMounted ran but didn't touch activeWorkspaceItemId
    // (initial URL was workspace, not chat).
    expect(ws.activeWorkspaceItemId).toBe('item_from_url_watch')

    // Now navigate to a chat URL — the watch's chat branch must fire and reset the workspace-item
    // active state. The guard `activeChatId.value !== 'chat-${sessionId}'` is true here
    // (activeChatId is empty after the workspace mount), so the reset block executes.
    routeObj.query = { view: 'chat', session: 'chat_new' }
    await flushPromises()
    wrapper.unmount()

    expect(ws.activeWorkspaceItemId).toBeNull()
  })
})
