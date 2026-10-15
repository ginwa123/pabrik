/**
 * The sidebar status badge on the RECENT and PINNED rows — the same
 * red / yellow / green trio the kanban card renders.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { useAgentErrorStore } from '../stores/agentError'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

const { useRouterMock } = vi.hoisted(() => ({
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolve: (target: any) => ({
      href: `/app?view=${target.query.view}&session=${target.query.session}`,
    }),
  })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting',
    onStateChange: () => () => {},
  }
}

const RETRY_CONTENT =
  '[Retry 3/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.\n' +
  'Server said: {"error":{"message":"Provider returned error","code":429}}'

/** A session row as `getChats` maps it off the wire. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function session(id: string, name: string, extra: Record<string, any> = {}): any {
  return {
    session_id: id,
    session_name: name,
    updated_at: '2026-10-14T10:00:00Z',
    is_pinned: false,
    pinned_position: 0,
    ...extra,
  }
}

/** Mount with a fixed session list and wait for the rows to paint. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function mountWith(sessions: any[]) {
  vi.spyOn(api, 'getChats').mockResolvedValue({
    sessions,
    has_more: false,
    next_cursor: null,
    total: sessions.length,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const wrapper = mount(ChatsList, {
    attachTo: document.body,
    global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
  })
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
  return wrapper
}

/** The badge testids a row currently shows, in DOM order. */
function badgesIn(row: Element): string[] {
  return Array.from(
    row.querySelectorAll(
      '[data-testid="chat-status-awaiting-review"], [data-testid="chat-status-reviewed"], [data-testid="chat-status-agent-error"]',
    ),
  ).map((el) => el.getAttribute('data-testid') ?? '')
}

function rowFor(id: string): Element | null {
  return document.body.querySelector(`[data-testid="chat-row-${id}"]`)
}

describe('ChatsList — status badge (red / yellow / green)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
  })

  it('shows the orange awaiting-review dot when the AI finished and no human has touched since', async () => {
    const wrapper = await mountWith([
      session('chat_await', 'Awaiting', {
        last_finish_reason: 'stop',
        needs_human_review: true,
      }),
    ])
    const row = rowFor('chat_await')!
    expect(badgesIn(row)).toEqual(['chat-status-awaiting-review'])
    expect(
      row.querySelector('[data-testid="chat-status-awaiting-review"]')?.getAttribute('title'),
    ).toBe('AI finished — awaiting your review')
    wrapper.unmount()
  })

  it('shows the green reviewed check when the AI finished and a human has touched since', async () => {
    const wrapper = await mountWith([
      session('chat_reviewed', 'Reviewed', {
        last_finish_reason: 'stop',
        needs_human_review: false,
      }),
    ])
    const row = rowFor('chat_reviewed')!
    expect(badgesIn(row)).toEqual(['chat-status-reviewed'])
    expect(row.querySelector('[data-testid="chat-status-reviewed"]')?.getAttribute('title')).toBe(
      'Reviewed',
    )
    wrapper.unmount()
  })

  it('shows no badge for a session that never finished a turn', async () => {
    const wrapper = await mountWith([
      session('chat_fresh', 'Fresh', { last_finish_reason: '', needs_human_review: false }),
      session('chat_midturn', 'Mid turn', {
        last_finish_reason: 'tool_calls',
        needs_human_review: false,
      }),
    ])
    expect(badgesIn(rowFor('chat_fresh')!)).toEqual([])
    expect(badgesIn(rowFor('chat_midturn')!)).toEqual([])
    wrapper.unmount()
  })

  it('shows the red warning when the agent errored, alongside the review state', async () => {
    const store = useAgentErrorStore()
    store.setError('chat_err', RETRY_CONTENT)
    const wrapper = await mountWith([
      session('chat_err', 'Errored', {
        last_finish_reason: 'stop',
        needs_human_review: true,
      }),
    ])
    const row = rowFor('chat_err')!
    // The error badge is additive — the awaiting-review dot stays.
    expect(badgesIn(row)).toEqual(['chat-status-awaiting-review', 'chat-status-agent-error'])
    const err = row.querySelector('[data-testid="chat-status-agent-error"]')!
    expect(err.getAttribute('title')).toContain('Agent error')
    expect(err.getAttribute('title')).toContain('3/10')
    wrapper.unmount()
  })

  it('paints the same badge in the PINNED section as in RECENT', async () => {
    const wrapper = await mountWith([
      session('pin_await', 'Pinned awaiting', {
        last_finish_reason: 'stop',
        needs_human_review: true,
        is_pinned: true,
        pinned_position: 2,
      }),
      session('pin_reviewed', 'Pinned reviewed', {
        last_finish_reason: 'stop',
        needs_human_review: false,
        is_pinned: true,
        pinned_position: 1,
      }),
      session('recent_await', 'Recent awaiting', {
        last_finish_reason: 'stop',
        needs_human_review: true,
      }),
      session('recent_reviewed', 'Recent reviewed', {
        last_finish_reason: 'stop',
        needs_human_review: false,
      }),
    ])

    const pinned = document.body.querySelector('[data-testid="pinned-section"]')!
    expect(badgesIn(pinned.querySelector('[data-testid="chat-row-pin_await"]')!)).toEqual([
      'chat-status-awaiting-review',
    ])
    expect(badgesIn(pinned.querySelector('[data-testid="chat-row-pin_reviewed"]')!)).toEqual([
      'chat-status-reviewed',
    ])

    // RECENT rows live inside the VirtualScroller slot.
    expect(badgesIn(rowFor('recent_await')!)).toEqual(['chat-status-awaiting-review'])
    expect(badgesIn(rowFor('recent_reviewed')!)).toEqual(['chat-status-reviewed'])
    wrapper.unmount()
  })

  it('shows a single badge when awaiting-review overlaps the stale condition', async () => {
    const wrapper = await mountWith([
      session('chat_double', 'Double', {
        last_finish_reason: 'stop',
        needs_human_review: true,
        last_human_touched_at: '2026-10-14 08:00:00',
        updated_at: '2026-10-14 10:00:00',
      }),
    ])
    const row = rowFor('chat_double')!
    expect(badgesIn(row)).toEqual(['chat-status-awaiting-review'])
    expect(row.querySelector('[data-testid="chat-stale-dot"]')).toBeNull()
    wrapper.unmount()
  })
})
