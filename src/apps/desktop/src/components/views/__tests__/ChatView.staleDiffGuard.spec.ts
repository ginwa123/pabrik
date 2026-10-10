/**
 * Regression: clicking a left-sidebar chat after opening a right-sidebar
 * file did nothing (first click dead, second click worked).
 *
 * Root cause: the dying ChatView's diff writers raced ChatsList's
 * navigation on path-based URLs. This spec drives the REAL vue-router
 * (memory history) + the REAL ChatView component: mount session A with a
 * diff open, navigate to session B the way ChatsList.setActive does
 * (store + router.replace with an empty query), then fire a late write
 * from the dying instance and prove B's URL stays clean.
 *
 * Behavioural: asserts on router.currentRoute (the wire), never on source.
 */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import * as api from '../../../api'
import ChatView from '../ChatView.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../../helpers/sseBus'
import type { SseClient, SseState } from '../../../helpers/sseClient'
import { makeLocalStorageStub } from '../../../__tests__/helpers'

if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: () => void } } }
  ).HTMLElement.prototype.scrollTo = function () {}
}

function makeStubClient(initial: SseState = 'open'): SseClient {
  const stub = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => (stub as { _state: SseState })._state,
    onStateChange: () => () => {},
    _state: initial,
  } as unknown as SseClient
  return stub
}

const WS = 'ws_guard_repro'
const SESSION_A = 'sess_guard_A'
const SESSION_B = 'sess_guard_B'

function makeRouter(initialPath: string) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [
      { path: '/app', component: { template: '<div />' } },
      { path: '/app/:workspaceId', component: { template: '<div />' } },
      { path: '/app/:workspaceId/chat/:sessionId', component: { template: '<div />' } },
    ],
  })
  router.push(initialPath)
  return router
}

describe('ChatView stale diff guard — dying view cannot corrupt new chat URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))
    vi.spyOn(api, 'getSession').mockResolvedValue({ id: SESSION_A, cwd: '/w' } as never)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      cwd: '/w',
    } as never)
    vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false } as never)
    vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
    vi.spyOn(api, 'getGitStatus').mockResolvedValue(null as never)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('late write from dying session A leaves session B URL clean', async () => {
    const router = makeRouter(`/app/${WS}/chat/${SESSION_A}`)
    await router.isReady()

    const wrapper = mount(ChatView, {
      props: { chatId: `chat-${SESSION_A}`, chatName: 'A', cwd: '/w' },
      global: {
        plugins: [router],
        stubs: {
          ChatRightSidebar: { template: '<div />' },
          CenterDiffSection: { template: '<div />' },
          SidebarDiffView: { template: '<div />' },
          CodeViewerStage: { template: '<div />' },
        },
      },
    })
    await flushPromises()
    await nextTick()

    // Sanity: we boot on A's path with no diff param.
    expect(router.currentRoute.value.path).toBe(`/app/${WS}/chat/${SESSION_A}`)
    expect(router.currentRoute.value.query.diff).toBeUndefined()

    // ChatsList.setActive(B): store first (omitted here — the guard reads
    // the route, not the store), then replace to B with an empty query.
    await router.replace({ path: `/app/${WS}/chat/${SESSION_B}`, query: {} })
    expect(router.currentRoute.value.path).toBe(`/app/${WS}/chat/${SESSION_B}`)

    // The dying instance (still mounted in this test, sessionId=A) fires a
    // late diff write — scroll-spy, collapse toggle, or mode switch via the
    // proxied setup binding. The wire (router.currentRoute) is the assertion.
    const vm = wrapper.vm as unknown as Record<string, unknown>
    const setDiffMode = vm['setDiffMode'] as ((m: 'unified' | 'split') => void) | undefined
    expect(typeof setDiffMode).toBe('function')
    ;(setDiffMode as (m: 'unified' | 'split') => void)('split')
    await flushPromises()
    await nextTick()

    // B's URL must stay clean: no diff param from A's late write, path intact.
    expect(router.currentRoute.value.path).toBe(`/app/${WS}/chat/${SESSION_B}`)
    expect(router.currentRoute.value.query.diff).toBeUndefined()
    expect(router.currentRoute.value.query.diffmode).toBeUndefined()

    wrapper.unmount()
  })

  it('fresh write on own session still lands (positive control)', async () => {
    const router = makeRouter(`/app/${WS}/chat/${SESSION_A}`)
    await router.isReady()

    const wrapper = mount(ChatView, {
      props: { chatId: `chat-${SESSION_A}`, chatName: 'A', cwd: '/w' },
      global: {
        plugins: [router],
        stubs: {
          ChatRightSidebar: { template: '<div />' },
          CenterDiffSection: { template: '<div />' },
          SidebarDiffView: { template: '<div />' },
          CodeViewerStage: { template: '<div />' },
        },
      },
    })
    await flushPromises()
    await nextTick()

    const vm = wrapper.vm as unknown as Record<string, unknown>
    const setDiffMode = vm['setDiffMode'] as ((m: 'unified' | 'split') => void) | undefined
    expect(typeof setDiffMode).toBe('function')
    ;(setDiffMode as (m: 'unified' | 'split') => void)('split')
    await flushPromises()
    await nextTick()
    // Own session: the write lands.
    expect(router.currentRoute.value.query.diffmode).toBe('split')

    wrapper.unmount()
  })
})
