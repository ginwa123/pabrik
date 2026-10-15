/**  * Regression tests for the Recent list in ChatsList. The section title is "Recent". A row shows the
 * icon-only `chat-git-branch` badge only when the session has both a branch and a known
 * pull-request status. Worktree bindings and branches without a pull request show no git badge. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'

import * as api from '../api'
import ChatsList from '../components/views/ChatsList.vue'
import { flushPromises, mount } from '@vue/test-utils'
import { makeLocalStorageStub } from './helpers'
import { clearPrStatusCache, invalidatePrStatus } from '../helpers/prStatusCache'
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

// ChatsList calls useRouter() in setup; the `mocks: { $router: ... }` option below only patches
// `this.$router` (Options API), so we stub the composable at module level — same as
// sidebarActiveState.spec.ts.
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
      // Real Vue ref — ChatsList has `watch(processingState, ..., { deep: true })`.
      // A plain `{ value: {} }` object would log `[Vue warn]: Invalid watch source`
      // and turn the watchers into silent no-ops.
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('ChatsList git icon', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // ChatsList setup calls workspacesStore.onSessionEvent(cb) synchronously, which now requires
    // the sseBus to be installed (Chunk 6 of unify-frontend-sse). Install a stub bus before
    // mounting the component.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    clearPrStatusCache()
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: '',
      state: '',
      mergeable: '',
      merge_state: '',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('labels the section Recent and omits git icons for worktrees without a PR', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_abc',
          session_name: 'My Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          git_worktree_cwd: '/abs/.worktrees/worktree/session_abc',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await flushPromises()
    await nextTick()

    expect(wrapper.get('[data-testid="recent-section-title"]').text()).toBe('Recent')
    expect(wrapper.find('[data-testid="chat-git-branch"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })

  it('does NOT render the worktree icon when git_worktree_cwd is empty', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_plain',
          session_name: 'Plain Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          git_worktree_cwd: '',
        },
      ],
      has_more: false,

      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })

  it('does NOT render the worktree icon when git_worktree_cwd is missing from the session', async () => {
    // Belt-and-suspenders: some old sessions predate the set_git_worktree tool, so the field is
    // absent (undefined) on the wire. The ChatsList loadChats mapper uses `session.git_worktree_cwd
    // || ''` which collapses both empty and missing into the falsy default, hiding the badge.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_legacy',
          session_name: 'Legacy Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          // no git_worktree_cwd key at all
        },
      ],

      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })

  it('does NOT render a model badge even when selected_profile_model is set', async () => {
    // Chat rows show only the chat name, optional PR badge, and time.
    // A worktree binding without a pull request stays visually plain.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_both',
          session_name: 'Both',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: 'gpt-4o',
          git_worktree_cwd: '/worktrees/feature-x',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    await nextTick()

    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-icon="robot"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('gpt-4o')
  })

  it('renders the icon-only branch badge when the session has a pull request', async () => {
    // Sidebar parity with WorkspaceItemTaskCard's SVG icon, but
    // icon-only: no branch-name text, no legacy chip. The branch +
    // worktree path stay discoverable via the tooltip.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_branch',
          session_name: 'Branched Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          cwd: '/repo',
          git_worktree_cwd: '/repo/.worktrees/feature-x',
          git_branch: 'worktree/feature-x',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await flushPromises()
    await nextTick()

    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-status')).toBe('open')
    // Icon-only: the SVG icon with no branch-name text.
    expect(badge.html()).toContain('M6 3v12')
    expect(badge.text()).not.toContain('worktree/feature-x')
    // The row still shows the chat name.
    expect(wrapper.text()).toContain('Branched Chat')
    // Legacy chip yields to the branch badge.
    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
    // Tooltip surfaces the branch + full worktree path.
    expect(badge.attributes('title')).toContain('worktree/feature-x')
    expect(badge.attributes('title')).toContain('/repo/.worktrees/feature-x')
  })

  it('re-reads the branch icon after a merge invalidates the shared cache', async () => {
    // The reported bug: the RECENT row's branch icon kept the `open` green it
    // fetched before the merge, because a row reads the shared 60s cache once on
    // mount and again only when its branch/cwd key changes. The invalidation
    // (MergeBox for this tab, the `git_pr_state` SSE event for every other one)
    // drops the entry and ticks; the row must then re-read and recolour.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_merged',
          session_name: 'Merged Chat',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          cwd: '/repo',
          git_worktree_cwd: '/repo/.worktrees/feature-x',
          git_branch: 'worktree/feature-x',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await flushPromises()
    await nextTick()
    const badge = wrapper.find('[data-testid="chat-git-branch"]')
    expect(badge.attributes('data-pr-status')).toBe('open')
    expect(badge.attributes('style')).toContain('var(--color-green)')

    // The forge has now merged it — and the cache entry from before is dropped.
    vi.spyOn(api, 'getPrStatus').mockResolvedValue({
      status: 'merged',
      state: 'MERGED',
      mergeable: '',
      merge_state: '',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    invalidatePrStatus('/repo/.worktrees/feature-x', 'worktree/feature-x')
    await flushPromises()
    await nextTick()

    const after = wrapper.find('[data-testid="chat-git-branch"]')
    expect(after.attributes('data-pr-status')).toBe('merged')
    expect(after.attributes('style')).toContain('var(--color-violet)')
    expect(after.attributes('title')).toContain('PR merged — worktree/feature-x')
  })

  it('does NOT render a git badge when the branch has no pull request', async () => {
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [
        {
          session_id: 'session_branch_no_pr',
          session_name: 'Branch Without PR',
          updated_at: '2026-06-18T10:00:00Z',
          selected_profile_model: '',
          cwd: '/repo',
          git_worktree_cwd: '/repo/.worktrees/no-pr',
          git_branch: 'worktree/no-pr',
        },
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const wrapper = mountChatsList()
    await flushPromises()
    await nextTick()

    expect(wrapper.find('[data-testid="chat-git-branch"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="worktree-badge"]').exists()).toBe(false)
  })
})
