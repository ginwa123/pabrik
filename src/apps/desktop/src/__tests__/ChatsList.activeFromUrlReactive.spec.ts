/**
 * Regression test for the ChatsList stale-active bug
 * (sidebar-single-active follow-up, 2026-08-06).
 *
 * Bug: `active` was set in `loadChats()` from `currentMainView.value.kind`
 * at the time loadChats ran. After the URL navigated away from
 * `?view=chat`, the chat row's `active: true` stayed — the template
 * never re-rendered.
 *
 * Fix: derive active state in the template from `isCurrentChat(id)`,
 * which is reactive on `currentMainView.value`.
 *
 * Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ChatsList from '../components/views/ChatsList.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import * as api from '../api'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      // Real Vue ref — see comment in chatview-stop-button plan.
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

describe('ChatsList — chat row active state stays in sync with URL', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatsList calls `workspacesStore.onSessionEvent(cb)` synchronously
    // in setup which now requires the sseBus to be installed (Chunk 6
    // of unify-frontend-sse plan). Install a stub bus.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'chat_abc',
          session_name: 'My Chat',
           
          updated_at: '2026-08-06T00:00:00Z',
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      has_more: false,
       
      next_cursor: null,
      total: 1,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })
  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('chat row active STAYS IN SYNC when URL changes (regression)', async () => {
    // Phase 1: user is on the chat URL → row is highlighted.
    const route = reactive({
      query: { view: 'chat', session: 'chat_abc' } as Record<string, string>,
       
      path: '/app',
      fullPath: '/app?view=chat&session=chat_abc',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockImplementation(() => route as any)
    const wrapper = mountChatsList()
    await flushLoadChats()

    let buttons = wrapper.findAll('button')
    let chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style')).toContain('--semantic-active-bg')

    // Phase 2: user navigates to a workspace view → row should NOT be highlighted anymore. Pre-fix,
    // the `active` flag set in loadChats() stayed truthy. Post-fix, the template's
    // `isCurrentChat(item.id)` re-evaluates reactively.
    route.query = { view: 'workspace', itemId: 'item_x' }
    await nextTick()
    buttons = wrapper.findAll('button')
    chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })
})
