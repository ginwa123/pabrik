/** Tests for the worktree-aware status bar in ChatView.vue. The chat status bar (the small
 * git-branch + worktree chip at the bottom of the chat) becomes a clickable button when the session
 * is bound to a worktree. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// jsdom 29 (the version used by this project's Vitest) does not implement
// `Element.prototype.scrollTo`. The VirtualScroller's `scrollToBottom` calls
// `containerRef.value.scrollTo({top, behavior})` on every render.
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: () => void } } }
  ).HTMLElement.prototype.scrollTo = function () {
    // no-op
  }
}

// ─── shared SSE stub ──────────────────────────────────────────────────────── Mirrors the helper
// in `sseBus.spec.ts` / `App.spec.ts` — kept inline rather than shared to avoid coupling between
// the two spec files.
function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

// ─── default mocks ──────────────────────────────────────────────────────────
// `installChatViewMocks` wires up the api.* dependencies the component touches in onMounted.
function installChatViewMocks(opts: {
  gitWorktreeCwd?: string
  cwd?: string
} = {}) {
  const history = {
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: opts.cwd ?? '/tmp/main-repo',
    git_worktree_cwd: opts.gitWorktreeCwd ?? '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  }
  // ChatView's mount loads through `fetchChatHistoryEffect`; `getChatHistory` alone never reaches
  // it, so the mount stalled on a 404 and never reached `startGitStatusPoll()` — the status button
  // under test is gated on the git-status payload that poll paints.
  vi.spyOn(api, 'fetchChatHistoryEffect').mockReturnValue(Effect.succeed(history))
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  // A `watch(() => sessionId.value, ...)` in ChatView fires `api.getSession(newId)` once onMounted
  // sets the sessionId. The mock must return a session-shaped object so the watch's
  // `session?.selectedProfile` lookup is safe.
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
     
    selectedAgent: null,
    cwd: '',
    git_worktree_cwd: '',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // The status poll checks `is_git_repo` to decide whether to render
  // the status button. We always return a clean repo so the button
  // shows.
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: true,
    branch: 'main',
     
    has_changes: false,
    is_clean: true,
    current: 'main',
    status: 'clean',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // loadProfiles() is called outside onMounted; the response shape
  // matches the real `/api/config/pabrik` payload.
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

// ─── mount helper ───────────────────────────────────────────────────────────
async function mountChatView(chatId = 'session_test') {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // onMounted is async: loadChatHistory → connectSse → startGitStatusPoll → getQueuedMessages. Wait
  // several ticks for all the awaits to resolve and the template to re-render with the loaded
  // values.
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

describe('ChatView worktree status button', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    // jsdom 29 in this project's Vitest does not provide localStorage. navigation.ts reads
    // localStorage at store init (loadSidebarCollapsed etc.), so we stub a minimal in-memory
    // implementation that satisfies the `localStorage.getItem/.setItem/.removeItem` calls.
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => { store[k] = String(v) },
        removeItem: (k: string) => { delete store[k] },
        clear: () => { for (const k in store) delete store[k] },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }

    // ChatView setup() now reads useNavigationStore() to wire the
    // sub-agent peek panel (@peek event + lazy peek composable).
    // Pinia must be active for any useXxxStore() call.
    setActivePinia(createPinia())

    // Install the bus BEFORE mounting ChatView so ChatView's `useSseBus()` calls in `connectSse()`
    // find an installed bus (the bus throws "useSseBus called before installSseBus" if not
    // installed).
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  it('when git_worktree_cwd is empty, the status button is still clickable and opens a context-appropriate dropdown', async () => {
    installChatViewMocks({ gitWorktreeCwd: '' })

    wrapper = await mountChatView('session_no_wt')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    // The button is ALWAYS clickable now (no `:disabled` binding). Clicking opens a dropdown with
    // the no-worktree menu items ("Open in folder", "Refresh status") — NOT the worktree-bound
    // items ("Create a PR", "Clear worktree").
    const htmlBtn = btn.element as HTMLButtonElement
    expect(htmlBtn.disabled).toBe(false)
    // The worktree-basename block should be absent (it's gated on v-if="gitWorktreeCwd"). Assert
    // the icon it would have drawn rather than the glyph's text, which `WorktreeMenu` replaced with
    // an SVG — the string check passed for the wrong reason.
    expect(wrapper!.find('[data-icon="tree"]').exists()).toBe(false)

    // Open the dropdown.
    await btn.trigger('click')
    await nextTick()
    await nextTick()

    // No-worktree menu items — "Refresh status" is the unambiguous
    // tell. "Open in folder" shares its data-testid with the
    // worktree-bound "View in folder" item.
    expect(wrapper!.find('[data-testid="worktree-menu-refresh"]').exists()).toBe(true)
    // Worktree-bound items should NOT be present.
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)
    expect(wrapper!.find('[data-testid="worktree-menu-clear"]').exists()).toBe(false)
  })

  it('when git_worktree_cwd is set, the status button shows branch + caret; worktree basename is in the menu', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    expect((btn.element as HTMLButtonElement).disabled).toBe(false)
    // The chip keeps the branch name visible. The worktree basename is intentionally NOT shown in
    // the chip anymore (it was noisy when branch and basename were nearly identical strings); the
    // menu header carries the worktree info instead.
    expect(btn.text()).toContain('main')
    expect(btn.find('[data-icon="tree"]').exists()).toBe(false)
    expect(btn.text()).not.toContain('auth-fix')
    // The dropdown caret is always rendered now (chip is always clickable).
    expect(btn.text()).toContain('▾')

    // The worktree basename surfaces inside the dropdown menu header
    // (added in the no-worktree-aware menu refactor).
    await btn.trigger('click')
    await nextTick()
    await nextTick()
    expect(wrapper!.text()).toContain('main')
    // The full worktree path is still discoverable via the title tooltip.
    expect(btn.attributes('title') ?? '').toContain('/abs/.worktrees/auth-fix')
  })

  it('when git_worktree_cwd is set, clicking the status button opens the dropdown', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt_dropdown')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)

    // The WorktreeMenu uses the three testids we created in
    // worktreeMenu.spec.ts. Before the click, none of them exist
    // (the menu is v-if-bound to showWorktreeMenu=false).
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(false)

    await btn.trigger('click')
    await nextTick()
    await nextTick()

    // The WorktreeMenu has mounted. All 3 of its items are present.
    expect(wrapper!.find('[data-testid="worktree-menu-create-pr"]').exists()).toBe(true)
    expect(wrapper!.find('[data-testid="worktree-menu-view-folder"]').exists()).toBe(true)
    expect(wrapper!.find('[data-testid="worktree-menu-clear"]').exists()).toBe(true)
  })

  it('the status button title attribute shows the full worktree path', async () => {
    installChatViewMocks({
      gitWorktreeCwd: '/abs/.worktrees/auth-fix',
    })

    wrapper = await mountChatView('session_with_wt_title')
    const btn = wrapper!.find('[data-testid="worktree-status-button"]')
    expect(btn.exists()).toBe(true)
    // The production template binds: :title="gitWorktreeCwd ? `Worktree: ${gitWorktreeCwd}\n...` :
    // `...`" The full path must appear in the title (the basename is too short to be a unique
    // identifier when the user has multiple worktrees named the same).
    const title = btn.attributes('title') ?? ''
    expect(title).toContain('/abs/.worktrees/auth-fix')
  })

  // ─── bus cross-session isolation ────────────────────────────── ChatView's SSE listener drops
  // `event.session_id !== sid`; a `chunk`'s observable outcome is the transcript row it paints, so
  // these assert on rendered text — the accumulator is `useChatSse`'s business, not the component's.
  it('bus llm events for the active session_id paint the transcript', async () => {
    installChatViewMocks({ gitWorktreeCwd: '' })

    wrapper = await mountChatView('session_bus_match')

    __dispatchSseBus('llm', {
      session_id: 'session_bus_match',
      type: 'chunk',
      content: 'hello from bus',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()
    await nextTick()

    expect(wrapper!.text()).toContain('hello from bus')
  })

  it('bus llm events for a DIFFERENT session_id do NOT paint the transcript (cross-session isolation)', async () => {
    installChatViewMocks({ gitWorktreeCwd: '' })

    wrapper = await mountChatView('session_bus_isolation')

    // A chunk for the WRONG session_id. The bus's single global EventSource delivers ALL sessions'
    // events to the listener; the filter is the layer that scopes them to the active ChatView.
    __dispatchSseBus('llm', {
      session_id: 'OTHER_SESSION',
      type: 'chunk',
      content: 'should be dropped',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()
    await nextTick()

    expect(wrapper!.text()).not.toContain('should be dropped')

    // A matching one — confirms the previous "dropped" was the filter, not broken wiring.
    __dispatchSseBus('llm', {
      session_id: 'session_bus_isolation',
      type: 'chunk',
      content: 'matching one passes',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await nextTick()
    await nextTick()

    expect(wrapper!.text()).toContain('matching one passes')
  })
})
