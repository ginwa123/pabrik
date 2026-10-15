/**
 * Tests for ChatView's profile chip + picker — the cascade display.
 *
 * The chip in the chat status bar must reflect the EFFECTIVE profile the
 * backend will use, not just the per-session `selected_profile_model`.
 *
 * Cascade precedence (per workflow.zig::resolveProfileField):
 *   1. per-session `selected_profile_model` (when non-empty AND profile exists)
 *   2. `config.active_profile`         (when non-null AND non-empty)
 *   3. top-level config               (default fallback)
 *
 * Pre-fix, the chip only showed `selectedProfile ?? 'Default'` with tooltip
 * "Using default (top-level config)". That misled the user into thinking
 * the top-level was used when the active profile was actually applied.
 *
 * The fix: ChatView loads `active_profile` from getPabrikConfig() alongside
 * `profiles`. The chip displays the effective profile (per-session selection
 * or active profile, falling back to "Default" only when neither exists).
 * The tooltip reflects the actual cascade; the picker shows ✓ on the
 * effective row + an `(active)` badge next to the active profile.
 *
 * Plan: docs/superpowers/plans/2026-08-06-chatview-profile-cascade-display.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref } from 'vue'
import { mount, flushPromises, type VueWrapper, type DOMWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

// jsdom 29 dropped Element.prototype.scrollTo; polyfill for VirtualScroller.
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

// ─── mocks ──────────────────────────────────────────────────────────────── Per-test overrides via
// setup() so each test can change getPabrikConfig / getSession responses without re-mounting the
// global vi.mock() harness.
function installChatViewMocks(opts: {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  config?: any
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  session?: any
}) {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',

    git_worktree_cwd: '',

    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue(
    opts.session ?? {
      session_id: 'placeholder',
      session_name: '',

      selectedProfile: null,
      cwd: '',
      git_worktree_cwd: '',
    },
  )
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({ is_git_repo: false } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue(opts.config ?? { profiles: {} })
}

// ─── mount helper ──────────────────────────────────────────────────────── Mounts ChatView with
// the provided sessionId. Returns the wrapper plus resolved refs once the component is mounted and
// the initial async data (getPabrikConfig + getSession) has resolved.
async function mountChatViewWithSession(sessionId: string) {
  const processingState = ref<Record<string, boolean>>({})

  const wrapper = mount(ChatView, {
    props: { chatId: sessionId, chatName: 'Test Chat' },
    attachTo: document.body,
    global: {
      provide: { processingState },
    },
  })
  // Wait for the onMounted loadProfiles + watch on sessionId to settle.
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await flushPromises()
  await nextTick()
  return wrapper
}

// ─── shared SseBus wiring (parity with chatViewWorktree.spec.ts) ────────
let vueApp: ReturnType<typeof createApp> | null = null
let sseBusGlobalClient: SseClient | null = null

beforeEach(() => {
  setActivePinia(createPinia())
  vueApp = createApp({})
  installSseBus(vueApp)
  sseBusGlobalClient = makeStubClient('open')
  __setSseBusGlobalClient(sseBusGlobalClient)
  // jsdom 29 dropped localStorage from its default globals. Several stores (navigation.ts,
  // designSse.ts, kanbanSse.ts) call localStorage.getItem() on init — without this stub every test
  // crashes with "Cannot read properties of undefined (reading 'getItem')".
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

afterEach(() => {
  __resetSseBus()
  vueApp = null
  sseBusGlobalClient = null
  vi.restoreAllMocks()
})

// ─── Helper: read chip text + tooltip ─────────────────────────────────────
function readChip(wrapper: VueWrapper): {
  text: string
  title: string
} {
  // The picker trigger carries `data-testid="profile-picker-button"` (added
  // with the V1 composer toolbar — previously located via the 🤖 emoji,
  // which the toolbar restyle removed).
  const found = wrapper.find('[data-testid="profile-picker-button"]')
  if (!found.exists()) throw new Error('profile chip button not found')
  const chipBtn = found as unknown as DOMWrapper<HTMLButtonElement>
  return {
    text: chipBtn.text().trim(),
    title: chipBtn.attributes('title') ?? '',
  }
}

// ─── Tests ────────────────────────────────────────────────────────────────
describe('ChatView profile chip — cascade display', () => {
  it('shows the active profile when no chat session has been opened yet (active = default)', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
          '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: '300 ribu',
      },
      session: { selectedProfile: null, cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_no_session')

    const { text, title } = readChip(wrapper)
    expect(text).toContain('300 ribu')
    expect(text).not.toContain('Default')
    expect(title).toMatch(/active profile/i)
  })

  it('shows the active profile when session has empty selected_profile_model (cascade falls through)', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
          '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: '300 ribu',
      },
      session: { selectedProfile: '', cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_empty_selected')

    const { text, title } = readChip(wrapper)
    expect(text).toContain('300 ribu')
    expect(title).toMatch(/active profile/i)
  })

  it('shows the per-session selected_profile_model when it is set (overrides active)', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
          '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: '300 ribu',
      },
      session: { selectedProfile: '900ribu', cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_900ribu')

    const { text, title } = readChip(wrapper)
    expect(text).toContain('900ribu')
    expect(title).toMatch(/profile.*900ribu/i)
  })

  it('shows "Default" only when neither selected_profile_model nor active_profile is set', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: null,
      },
      session: { selectedProfile: null, cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_default')

    const { text, title } = readChip(wrapper)
    expect(text).toContain('Default')
    expect(title).toMatch(/top-level/i)
  })

  it('shows "Default" when no profiles are configured at all', async () => {
    installChatViewMocks({
      config: { profiles: {}, active_profile: null },
      session: { selectedProfile: null, cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_empty_profiles')

    const { text } = readChip(wrapper)
    expect(text).toContain('Default')
  })

  it('renders (active) badge next to the active profile in the picker', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
          '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: '300 ribu',
      },
      session: { selectedProfile: null, cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_active_badge')

    // Open the picker
    const chip = wrapper.find('[data-testid="profile-picker-button"]')
    if (!chip.exists()) throw new Error('chip not found')
    await chip.trigger('click.stop')
    await nextTick()

    const html = wrapper.html()
    // The (active) badge should appear next to the active profile row
    expect(html).toMatch(/300 ribu.*active|active.*300 ribu/s)
    // And not next to the non-active profile
    expect(html).not.toMatch(/900ribu.*active/s)
  })

  it('puts ✓ on the effective profile row (selected > active > none)', async () => {
    installChatViewMocks({
      config: {
        profiles: {
          '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
          '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        },
        active_profile: '300 ribu',
      },
      session: { selectedProfile: null, cwd: '', git_worktree_cwd: '' },
    })

    const wrapper = await mountChatViewWithSession('sess_checkmark')

    const chip = wrapper.find('[data-testid="profile-picker-button"]')
    if (!chip.exists()) throw new Error('chip not found')
    await chip.trigger('click.stop')
    await nextTick()

    // With selectedProfile=null + activeProfile="300 ribu", ✓ should be on the 300 ribu row (not on
    // "Default (top-level)" — the effective selection IS the active profile). Scope by testid so we
    // don't match the chip's own "300 ribu" text (which has no ✓).
    const picker300 = wrapper.find('[data-testid="profile-picker-300 ribu"]')
    const picker900 = wrapper.find('[data-testid="profile-picker-900ribu"]')
    expect(picker300.exists()).toBe(true)
    expect(picker900.exists()).toBe(true)
    expect(picker300.text()).toContain('✓')
    expect(picker900.text()).not.toContain('✓')
  })
})

// ─── suppress unused-import warning for symbols referenced by other specs ─
void __dispatchSseBus
