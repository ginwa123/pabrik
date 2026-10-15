/**  * Conflict-only hint for the git-branch badge in ChatsList (quiet-when-clean). Contract:
 * CONFLICTING shows a ⚠ marker with data-pr-conflict and extends the tooltip with "merge
 * conflicts". MERGEABLE/unknown renders exactly as before (icon only, no attr). */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { clearPrStatusCache } from '../helpers/prStatusCache'
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

function mockChatWithBranch() {
  vi.spyOn(api, 'getChats').mockResolvedValue({
    sessions: [
      {
        session_id: 'chat_1',
        session_name: 'Fix open file',
        updated_at: '2026-06-18T10:00:00Z',
        cwd: '/repo',
        git_branch: 'feature/x',
      },
    ],
    has_more: false,
    next_cursor: null,
    total: 1,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

describe('ChatsList — git branch conflict hint', () => {
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
    __setSseBusGlobalClient(makeStubClient())
    clearPrStatusCache()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('shows the ⚠ marker when the PR is CONFLICTING', async () => {
    mockChatWithBranch()
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await flushPromises()
    await nextTick()
    await nextTick()
    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-conflict')).toBe('true')
    expect(badge.text()).toContain('⚠')
    expect(badge.attributes('title')).toContain('merge conflicts')
    wrapper.unmount()
  })

  it('stays quiet (icon only, no attr) when the PR is mergeable', async () => {
    mockChatWithBranch()
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await flushPromises()
    await nextTick()
    await nextTick()
    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-conflict')).toBeUndefined()
    expect(badge.text()).not.toContain('⚠')
    expect(badge.attributes('title')).not.toContain('merge conflicts')
    wrapper.unmount()
  })
})
