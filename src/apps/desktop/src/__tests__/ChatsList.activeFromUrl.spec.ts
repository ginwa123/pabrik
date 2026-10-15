/**
 * Behavioural tests for `ChatsList.vue` chat row active state.
 *
 * **Spec:** the chat row's `active` background is driven by the URL
 * (`?view=chat&session=X`), not by `navigationStore.sessionId` (which
 * can drift after refresh, deep-link, or `setActive` calls that
 * bypass the URL).
 *
 * **Pre-fix:** `loadChats()` set `active: savedSessionId === session.session_id`
 * where `savedSessionId` was `navigationStore.sessionId`. The URL was
 * not consulted.
 *
 * **Post-fix:** `loadChats()` derives `active` from the URL via
 * `useCurrentMainView()`. A chat row is active iff the URL is
 * `?view=chat&session=<row.id>`.
 *
 * **Deviation from the plan's verbatim test code:** the plan's
 * `pushItem` approach bypasses `loadChats()` (which is what the fix
 * actually changes), so the pushed item's `active: false` flag
 * overrides whatever `loadChats` set. The result: tests would never
 * go GREEN with the surgical fix alone.
 *
 * This file instead uses the existing `api.getChats` mock pattern
 * (mirrors `chatsListGitWorktree.spec.ts`) so `loadChats()` populates
 * `navItems` with the URL-driven active flag, then asserts on the
 * rendered DOM style.
 *
 * No static-contract checks — every assertion is on the live DOM
 * style attribute after the URL is mocked.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// Stub vue-router — ChatsList calls useRouter() in setup. The `mocks: { $router: ... }` option only
// patches `this.$router`, so we stub the composables at module level. Same pattern as
// sidebarHandleSelectTaskUrl.spec.ts:57-77.
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

const baseSession = {
  session_id: 'chat_abc',
  session_name: 'My Chat',
  updated_at: '2026-06-18T10:00:00Z',
  selected_profile_model: '',
  git_worktree_cwd: '',
  is_auto_retry_until_stop: '0',
}

 

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mockGetChatsWith(extraSessions: any[] = []) {
  vi.spyOn(api, 'getChats').mockResolvedValue({
    sessions: [baseSession, ...extraSessions],
    has_more: false,
     
    next_cursor: null,
    total: 1 + extraSessions.length,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      // Real Vue ref — ChatsList has `watch(processingState, ..., { deep: true })`.
      // A plain `{ value: {} }` object would log `[Vue warn]: Invalid watch source`
      // and turn the watchers into silent no-ops.
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

async function flushLoadChats() {
  // loadChats() in onMounted is async (awaits api.getChats). The mocked api.getChats resolves on
  // the next microtask. Wait one macrotask + two Vue ticks so the render queue flushes before we
  // assert on the DOM.
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

describe('ChatsList — chat row active state from URL', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatsList setup calls workspacesStore.onSessionEvent(cb)
    // synchronously, which requires the sseBus to be installed.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })
  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('chat row is active when URL is ?view=chat&session=X (URL-driven)', async () => {
    useRouteMock.mockReturnValue({
       
      query: { view: 'chat', session: 'chat_abc' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_abc',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    mockGetChatsWith()
    const wrapper = mountChatsList()
    await flushLoadChats()
    // Find the chat row button by content
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    // The active bg must be applied via inline style
    expect(chatButton!.attributes('style')).toContain('--semantic-active-bg')
  })

  it('chat row is NOT active when URL is ?view=workspace (different section)', async () => {
     
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_x' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_x',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    mockGetChatsWith()
    const wrapper = mountChatsList()
    await flushLoadChats()
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

   
  it('chat row is NOT active when URL is ?view=chat&session=OTHER (different chat)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_other' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    mockGetChatsWith()
    const wrapper = mountChatsList()
    await flushLoadChats()
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('chat row active state reflects the URL at the time loadChats runs', async () => {
    // The fix's invariant: loadChats() derives active from
    // useCurrentMainView() at call time. So calling loadChats()
    // with a different URL between renders should produce a
     
    // different active state.
    const route = reactive({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(route as any)
    mockGetChatsWith()
    const wrapper = mountChatsList()
    await flushLoadChats()

    // Initially URL is empty (kind=none) → no active bg.
    let buttons = wrapper.findAll('button')
    let chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    // URL changes to chat+session=chat_abc, then loadChats re-runs.
    // Post-fix: navItems[0].active becomes true.
    route.query = { view: 'chat', session: 'chat_abc' }
    await nextTick()
    await wrapper.vm.loadChats()
    await flushLoadChats()
    buttons = wrapper.findAll('button')
    chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton!.attributes('style')).toContain('--semantic-active-bg')
  })
})