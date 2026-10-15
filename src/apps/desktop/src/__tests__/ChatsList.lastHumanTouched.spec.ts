/**
 * Migration 082 - ChatsList time pill + stale-dot display tests.
 *
 * The sidebar's time pill is sourced from `formatRelativeTime(
 * last_human_touched_at ?? updated_at)` (the user-facing human time
 * falls back to the AI-tainted updated_at for legacy rows). The
 * amber `chat-stale-dot` appears when `updated_at > last_human_touched_at`
 * (i.e. the AI has touched since the human's last touch).
 *
 * Six cases (per spec §4):
 *   1. populated `last_human_touched_at` - renders that time
 *   2. null/empty - falls back to `updated_at`
 *   3. populated < updated - renders human time + stale dot
 *   4. populated == updated - no stale dot (in sync)
 *   5. populated > updated (defensive, clock skew) - no stale dot
 *   6. both null/empty - renders "now" + no stale dot
 *
 * Mock pattern: use `vi.mock` with `importActual` to mock the api
 * module's `getChats` function only (matches the established
 * `apiGetChats.spec.ts` pattern - which works reliably under the
 * project's vue-test-utils + vitest setup).
 *
 * Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
 * Task 8.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import ChatsList from '../components/views/ChatsList.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import type { Chat } from '../api'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, getChatsMock, markSessionTouchedMock, routerReplaceMock } = vi.hoisted(
  () => ({
    useRouteMock: vi.fn(() => ({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })),
    getChatsMock: vi.fn(),
    markSessionTouchedMock: vi.fn(),
    routerReplaceMock: vi.fn(),
  }),
)

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: useRouteMock,
    useRouter: () => ({ replace: routerReplaceMock }),
  }
})

// Mock the api module: keep everything from the real api module, only
// override getChats so each test can drive the wire payload directly.
// `vi.spyOn(api, 'getChats')` hits under the project's vitest setup.
vi.mock('../api/index', async () => {
  const actual = await vi.importActual<typeof import('../api/index')>('../api/index')
  return {
    ...actual,
    getChats: getChatsMock,
    markSessionTouched: markSessionTouchedMock,
  }
})

// Import the mocked module AFTER vi.mock so the spy binding is in place.

function makeSession(overrides: Partial<Chat> = {}): Chat {
  return {
    session_id: 'sess_default',
    session_name: 'Test chat',
    status: 'active',
    selected_profile_model: '',
    is_auto_retry_until_stop: '0',
    last_human_touched_at: '',
    updated_at: '',
    ...overrides,
  }
}

function makeStubClient(state: 'connecting' | { next: 'open'; attempt: number }): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = state
  return stub as SseClient
}

// formatRelativeTime (src/apps/desktop/src/helpers/relativeTime.ts) accepts
// SQLite datetime UTC strings ('YYYY-MM-DD HH:MM:SS') - which is what the
// backend's SELECT layer emits via strftime() for last_human_touched_at
// (Migration 082). unix-ms would be unparseable here, so we generate
// the wire shape the backend actually produces.
function dateToSqliteUtc(agoMs: number): string {
  const date = new Date(Date.now() - agoMs)
  return date.toISOString().replace('T', ' ').slice(0, 19)
}

async function flushLoadChats() {
  // loadChats() in onMounted is async (awaits api.getChats). Wait for
  // the microtask + a couple Vue ticks before asserting on the DOM.
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

describe('ChatsList - Migration 082 time pill + stale-dot display', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient({ next: 'open', attempt: 0 }))
    getChatsMock.mockReset()
    markSessionTouchedMock.mockReset()
    routerReplaceMock.mockReset()
    markSessionTouchedMock.mockResolvedValue({ success: true, session_id: 'sess_stale' })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
    app.unmount()
  })

  function mountChatsListWithProcessing(processingState: Ref<Record<string, boolean>>) {
    const workerActivity = ref<Record<string, WorkerActivity>>({})
    const workerNow = ref(Date.now())
    const wrapper = mount(ChatsList, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState, workerActivity, workerNow },
      },
    })
    return { wrapper, workerActivity, workerNow }
  }

  function mountChatsList() {
    return mountChatsListWithProcessing(ref<Record<string, boolean>>({})).wrapper
  }

  it('renders the populated last_human_touched_at value (case 1)', async () => {
    const ONE_HOUR_AGO = dateToSqliteUtc(60 * 60 * 1000)
    const TWO_HOURS_AGO = dateToSqliteUtc(2 * 60 * 60 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_h1',
          session_name: 'Human-touched chat',
          last_human_touched_at: ONE_HOUR_AGO,
          updated_at: TWO_HOURS_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    const pill = wrapper.find('[data-testid="chat-time-pill"]')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toBe('1h')
    expect(pill.attributes('title')).toBe('Last human activity')
    // updated_at > last_human_touched_at is FALSE here (TWO_HOURS_AGO
    // is older than ONE_HOUR_AGO) - no stale dot.
    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
  })

  it('falls back to updated_at when last_human_touched_at is empty (case 2)', async () => {
    const TWO_HOURS_AGO = dateToSqliteUtc(2 * 60 * 60 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_legacy',
          session_name: 'Legacy chat',
          last_human_touched_at: '',
          updated_at: TWO_HOURS_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    const pill = wrapper.find('[data-testid="chat-time-pill"]')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toBe('2h')
    expect(pill.attributes('title')).toBe('Last activity (never touched by you yet)')
    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
  })

  it('renders human time + amber stale dot when AI has touched since (case 3)', async () => {
    const TWO_HOURS_AGO = dateToSqliteUtc(2 * 60 * 60 * 1000)
    const THIRTY_SEC_AGO = dateToSqliteUtc(30 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_stale',
          session_name: 'Stale chat',
          last_human_touched_at: TWO_HOURS_AGO,
          updated_at: THIRTY_SEC_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    const pill = wrapper.find('[data-testid="chat-time-pill"]')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toBe('2h')

    const dot = wrapper.find('[data-testid="chat-stale-dot"]')
    expect(dot.exists()).toBe(true)
    expect(dot.classes()).toContain('bg-amber-400')
    expect(dot.attributes('title')).toBe('AI is still working — your last touch was earlier')
  })

  it('hides the stale dot when human and AI touched at the same moment (case 4)', async () => {
    const SAME = dateToSqliteUtc(60 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_in_sync',
          session_name: 'In sync',
          last_human_touched_at: SAME,
          updated_at: SAME,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
  })

  it('hides the stale dot when human time is newer than updated_at (defensive case 5)', async () => {
    const HUMAN = dateToSqliteUtc(1000)
    const UPDATED = dateToSqliteUtc(60_000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_clock_skew',
          session_name: 'Clock skew',
          last_human_touched_at: HUMAN,
          updated_at: UPDATED,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
  })

  it('setActive clears the stale dot optimistically and fires markSessionTouched (yellow-dot-fix)', async () => {
    const TWO_HOURS_AGO = dateToSqliteUtc(2 * 60 * 60 * 1000)
    const THIRTY_SEC_AGO = dateToSqliteUtc(30 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_stale',
          session_name: 'Stale chat',
          last_human_touched_at: TWO_HOURS_AGO,
          updated_at: THIRTY_SEC_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })
    markSessionTouchedMock.mockResolvedValue({ success: true, session_id: 'sess_stale' })

    const wrapper = mountChatsList()
    await flushLoadChats()

    // Precondition: stale dot is visible before the click.
    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(true)

    // Click the chat row (template wires @click="setActive(item.id)").
    const row = wrapper.findAll('button').find((b) => b.text().includes('Stale chat'))
    expect(row).toBeTruthy()
    await row!.trigger('click')
    await nextTick()
    await nextTick()

    // Optimistic patch aligns human time to updated_at so isStale()
    // flips false immediately — the dot disappears without a refetch.
    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
    // Best-effort backend stamp fired (not awaited by navigation).
    expect(markSessionTouchedMock).toHaveBeenCalledTimes(1)
    expect(markSessionTouchedMock).toHaveBeenCalledWith('sess_stale')
    // Navigation still happened synchronously (UI never blocks).
    expect(routerReplaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'chat', session: 'sess_stale' },
    })
  })

  it('deep-link loadChats clears the dot for the visible chat (yellow-dot-fix)', async () => {
    const TWO_HOURS_AGO = dateToSqliteUtc(2 * 60 * 60 * 1000)
    const THIRTY_SEC_AGO = dateToSqliteUtc(30 * 1000)
    useRouteMock.mockReturnValueOnce({
      query: { view: 'chat', session: 'sess_deep' },
      path: '/app',
      fullPath: '/app?view=chat&session=sess_deep',
    })
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_deep',
          session_name: 'Deep link chat',
          last_human_touched_at: TWO_HOURS_AGO,
          updated_at: THIRTY_SEC_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })
    markSessionTouchedMock.mockResolvedValue({ success: true, session_id: 'sess_deep' })

    const wrapper = mountChatsList()
    await flushLoadChats()

    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
    expect(markSessionTouchedMock).toHaveBeenCalledWith('sess_deep')
  })

  it('renders "now" with no stale dot when both fields are empty (case 6)', async () => {
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_both_empty',
          session_name: 'Both empty',
          last_human_touched_at: '',
          updated_at: '',
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    const pill = wrapper.find('[data-testid="chat-time-pill"]')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toBe('now')
    expect(wrapper.find('[data-testid="chat-stale-dot"]').exists()).toBe(false)
  })

  it('hides the time pill while the session is processing, then restores it when idle', async () => {
    const ONE_HOUR_AGO = dateToSqliteUtc(60 * 60 * 1000)
    getChatsMock.mockResolvedValueOnce({
      sessions: [
        makeSession({
          session_id: 'sess_processing',
          session_name: 'Processing chat',
          last_human_touched_at: ONE_HOUR_AGO,
          updated_at: ONE_HOUR_AGO,
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })
    const processingState = ref<Record<string, boolean>>({})
    const { wrapper, workerActivity } = mountChatsListWithProcessing(processingState)
    await flushLoadChats()

    expect(wrapper.find('[data-testid="chat-time-pill"]').text()).toBe('1h')
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="chat-elapsed-chip"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="chat-nav-elapsed-chip"]').exists()).toBe(false)

    processingState.value = { sess_processing: true }
    const now = Date.now()
    workerActivity.value = {
      sess_processing: { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
    }
    await nextTick()
    expect(wrapper.find('[data-testid="chat-time-pill"]').exists()).toBe(false)
    // No circle spinner anymore — the elapsed time pill is the marker.
    // Recent rows use the nav test-id; pinned rows use the plain one.
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    expect(
      wrapper.find('[data-testid="chat-nav-elapsed-chip"]').exists() ||
        wrapper.find('[data-testid="chat-elapsed-chip"]').exists(),
    ).toBe(true)

    processingState.value = {}
    workerActivity.value = {}
    await nextTick()
    expect(wrapper.find('[data-testid="chat-time-pill"]').text()).toBe('1h')
    expect(wrapper.find('[data-testid="session-slider"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="chat-elapsed-chip"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="chat-nav-elapsed-chip"]').exists()).toBe(false)
  })
})
