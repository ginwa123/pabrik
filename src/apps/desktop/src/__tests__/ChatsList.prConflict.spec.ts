/**  * The mark column of a chat row is 16px wide and holds ONE mark, so the branch glyph stays alone
 * in it and a merge conflict rides the trailing group's status-mark slot, where the tooltip names
 * it. Contract: CONFLICTING marks the row and says so; MERGEABLE leaves the row clean. */
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

  const mountList = async () => {
    const wrapper = mount(ChatsList, {
      attachTo: document.body,
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await flushPromises()
    await nextTick()
    await nextTick()
    return wrapper
  }

  it('shows the conflict as a status mark beside the branch badge when the PR is CONFLICTING', async () => {
    mockChatWithBranch()
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = await mountList()

    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-conflict')).toBe('true')
    expect(badge.findAll('svg')).toHaveLength(1)
    expect(badge.text()).toBe('')

    const conflict = wrapper.find('[data-testid="chat-status-pr-conflict"]')
    expect(conflict.exists()).toBe(true)
    expect(conflict.find('[data-icon="alert"]').exists()).toBe(true)
    expect(badge.element.contains(conflict.element)).toBe(false)

    expect(badge.attributes('title')).toContain('merge conflicts')
    expect(conflict.attributes('title')).toContain('Merge conflicts')
    expect(conflict.attributes('title')).toContain('feature/x')
    wrapper.unmount()
  })

  it('leaves the row clean when the PR is mergeable', async () => {
    mockChatWithBranch()
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const wrapper = await mountList()

    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-conflict')).toBeUndefined()
    expect(badge.findAll('svg')).toHaveLength(1)
    expect(badge.text()).toBe('')
    expect(wrapper.find('[data-testid="chat-status-pr-conflict"]').exists()).toBe(false)
    expect(badge.attributes('title')).not.toContain('merge conflicts')
    wrapper.unmount()
  })
})
