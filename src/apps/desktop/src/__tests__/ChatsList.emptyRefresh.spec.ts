/** Regression tests: the sidebar RECENT list must not go blank because one refresh failed. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, reactive, ref, type App as VueApp } from 'vue'
import { mount } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { sessionEngineDb } from '../sync/SessionEngineDb'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const WS_A = 'ws_A'
const WS_B = 'ws_B'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/', fullPath: '/' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function stubSseClient(): any {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    onStateChange: () => () => {},
  }
}

function makeSession(i: number, name = `Chat ${i}`): Record<string, unknown> {
  return {
    session_id: `sess_${i}`,
    session_name: name,
    updated_at: `2026-09-2${i}T10:00:00Z`,
    selected_profile_model: '',
    sub_agent_name: '',
    parent_session_id: '',
    cwd: '/repo',
    git_worktree_cwd: '',
    git_branch: '',
    is_auto_retry_until_stop: '0',
    last_human_touched_at: '',
  }
}

/** A `getChats` that walks the queued pages in call order; the last one repeats. */
function queueGetChats(pages: Record<string, unknown>[][]) {
  let call = 0
  return vi.spyOn(api, 'getChats').mockImplementation(() => {
    const page = pages[Math.min(call, pages.length - 1)] ?? []
    call += 1
    return Promise.resolve({
      sessions: page,
      has_more: false,
      next_cursor: null,
      total: page.length,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })
}

function mountChatsList() {
  return mount(ChatsList, {
    global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
  })
}

async function flush() {
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

const chatRowNames = (wrapper: ReturnType<typeof mountChatsList>): string[] =>
  wrapper
    .findAll('button')
    .map((b) => b.text())
    .filter((t) => t.includes('Chat') || t.includes('Renamed'))

describe('ChatsList — empty refresh must not blank the RECENT list', () => {
  let app: VueApp

  beforeEach(async () => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(stubSseClient())
    // The session cache is a module-level singleton with an in-memory
    // mirror; without this the rows painted by one test leak into the next.
    await Effect.runPromise(sessionEngineDb.clear(WS_A))
    await Effect.runPromise(sessionEngineDb.clear(WS_B))
    useRouteMock.mockReturnValue({
      query: {},
      path: `/app/${WS_A}`,
      fullPath: `/app/${WS_A}`,
    })
  })

  afterEach(() => {
    vi.useRealTimers()
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('keeps the painted rows when a refresh comes back empty', async () => {
    // Page 1 has rows, page 2 is what `getChats` resolves to when the
    // request fails (the failure is swallowed inside the api layer).
    queueGetChats([[makeSession(0), makeSession(1), makeSession(2)], []])
    const wrapper = mountChatsList()
    await flush()
    expect(chatRowNames(wrapper).length).toBe(3)

    // A refresh (what the SSE session-event handler triggers) returns empty.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (wrapper.vm as any).loadChats()
    await flush()

    const rows = chatRowNames(wrapper)
    expect(rows.length).toBe(3)
    expect(rows[0]).toContain('Chat 2')
    wrapper.unmount()
  })

  it('repaints when the scheduled retry finds the backend back', async () => {
    vi.useFakeTimers()
    queueGetChats([
      [makeSession(0), makeSession(1)],
      [], // failed refresh
      [makeSession(0, 'Renamed 0'), makeSession(1, 'Renamed 1')],
    ])
    const wrapper = mountChatsList()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(0)
    expect(chatRowNames(wrapper).length).toBe(2)

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (wrapper.vm as any).loadChats()
    await vi.advanceTimersByTimeAsync(0)
    // Still the old rows — the empty page did not blank the list.
    expect(chatRowNames(wrapper)[0]).toContain('Chat')

    // The retry fires (first backoff step is 1s) and the request recovers.
    await vi.advanceTimersByTimeAsync(1_000)
    await vi.advanceTimersByTimeAsync(0)
    const rows = chatRowNames(wrapper)
    expect(rows.length).toBe(2)
    expect(rows[0]).toContain('Renamed 1')
    wrapper.unmount()
  })

  it('paints an empty list when the FIRST response is empty, and stops retrying', async () => {
    vi.useFakeTimers()
    const spy = queueGetChats([[]])
    const wrapper = mountChatsList()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(0)
    expect(chatRowNames(wrapper)).toHaveLength(0)

    // Nothing to protect, so no retry storm: a genuinely empty scope
    // settles after the single request.
    await vi.advanceTimersByTimeAsync(60_000)
    expect(spy).toHaveBeenCalledTimes(1)
    expect(chatRowNames(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('resets the stale total when the scope changes', async () => {
    const route = reactive({ query: {} as Record<string, string>, path: '/', fullPath: '' })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockImplementation(() => route as any)
    route.path = `/app/${WS_A}`
    route.fullPath = route.path

    const getChats = vi
      .spyOn(api, 'getChats')
      .mockImplementation(
        (_sort: unknown, _dir: unknown, _limit: unknown, _cursor: unknown, wsId: unknown) => {
          if (wsId === WS_B) return new Promise(() => {}) // in flight forever
          return Promise.resolve({
            sessions: [
              makeSession(0),
              makeSession(1),
              makeSession(2),
              makeSession(3),
              makeSession(4),
            ],
            has_more: false,
            next_cursor: null,
            total: 5,
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
          } as any)
        },
      )
    const wrapper = mountChatsList()
    await flush()
    // Selected by name: the SFC is generic (`<script setup generic="T">`),
    // so the component value does not satisfy findComponent's overload.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const scroller = wrapper.findComponent({ name: 'VirtualScroller' }) as any
    expect(scroller.props('totalCount')).toBe(5)

    route.path = `/app/${WS_B}`
    route.fullPath = route.path
    await nextTick()
    await flush()
    // ws_B's response never lands; the total from ws_A must not survive,
    // or the scroller's `items.length < totalCount` gate pages past the end.
    expect(getChats).toHaveBeenCalled()
    expect(scroller.props('totalCount')).toBe(0)
    wrapper.unmount()
  })
})
