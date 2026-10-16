/** Floating composer — structural contract. The composer used to be the LAST flex child of the chat
 * column: a `p-4` block with a `border-top` and an opaque `--semantic-sidebar-bg` fill, so the
 * transcript lost that slice of its height and messages ended on a hard 1px rule. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const __dir = dirname(fileURLToPath(import.meta.url))
const chatViewSrc = readFileSync(resolve(__dir, '../components/views/ChatView.vue'), 'utf8')
const sliderSrc = readFileSync(resolve(__dir, '../components/chat/ChatScrollSlider.vue'), 'utf8')

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

/** A ResizeObserver the test can fire by hand. The global stub in `setup.ts` is inert
 * (observe/disconnect only), which is right for the other suites but useless here: the whole point
 * is to prove the dock's observer publishes a height. */
class ControllableRO {
  static instances: ControllableRO[] = []
  observed: Element[] = []
  constructor(private cb: ResizeObserverCallback) {
    ControllableRO.instances.push(this)
  }
  observe(el: Element) {
    this.observed.push(el)
  }
  unobserve() {}
  disconnect() {}
  emit(height: number) {
    this.cb(
      [
        {
          target: this.observed[0],
          contentRect: { height, width: 0, top: 0, left: 0, right: 0, bottom: height, x: 0, y: 0 },
        } as unknown as ResizeObserverEntry,
      ],
      this as unknown as ResizeObserver,
    )
  }
}

function dockObserver(): ControllableRO {
  const found = ControllableRO.instances.find((ro) =>
    ro.observed.some((el) => el.classList.contains('composer-dock')),
  )
  if (!found) throw new Error('no ResizeObserver observed the composer dock')
  return found
}

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBaseMocks() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's_float',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

/**  * Three groups: short enough that the scroller's initial window covers all of them (jsdom reports a
 * 0-height container, so the window is `buffer` rows wide), which lets the spec see the real last
 * row. */
function historyWithMessages() {
  const messages = [
    { role: 'user', content: 'first question' },
    { role: 'assistant', content: 'first answer' },
    { role: 'user', content: 'second question' },
  ].map((m, i) => ({
    id: `m${i}`,
    session_id: 's_float',
    content: m.content,
    role: m.role,
    created_at: 1_700_000_000 + i,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  })) as any[]
  return {
    messages,
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
  }
}

describe('ChatView floating composer', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  async function mountChat(props: Record<string, unknown> = {}) {
    vi.spyOn(api, 'getChatHistory').mockResolvedValue(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      historyWithMessages() as any,
    )
    wrapper = mount(ChatView, {
      props: { chatId: 's_float', chatName: 'Float Chat', ...props },
      attachTo: document.body,
    })
    await flushPromises()
    for (let i = 0; i < 30; i++) {
      await nextTick()
      if (wrapper.find('[data-testid="composer-dock"]').exists()) break
    }
    return wrapper
  }

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
    __resetSseBus()
    ControllableRO.instances = []
    vi.stubGlobal('ResizeObserver', ControllableRO)
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    installBaseMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('renders the composer inside a dock with a scrim, and the old in-flow chrome is gone', async () => {
    await mountChat()

    const dock = wrapper!.find('[data-testid="composer-dock"]')
    expect(dock.exists()).toBe(true)
    // Overlay classes — the dock must not be a flex sibling of the
    // transcript any more.
    expect(dock.classes()).toContain('composer-dock')
    expect(dock.attributes('style')).toBeUndefined()
    // The gradient that replaced the `border-top` + opaque fill.
    expect(wrapper!.find('[data-testid="composer-scrim"]').exists()).toBe(true)
    // The card itself still renders inside the dock.
    expect(wrapper!.find('.composer-card').exists()).toBe(true)
    // The column is the dock's containing block.
    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    expect(column).toBeTruthy()
    expect(column.classList.contains('relative')).toBe(true)
  })

  it("the dock's ResizeObserver publishes its height as --chat-composer-inset on the column", async () => {
    await mountChat()
    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('')

    dockObserver().emit(128)
    await nextTick()
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('128px')

    // Grown composer (textarea autogrow / attachment previews) republishes.
    dockObserver().emit(241)
    await nextTick()
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('241px')
  })

  it('a 0-height report (dock hidden by the centre diff) does not zero the inset', async () => {
    await mountChat()
    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    dockObserver().emit(128)
    await nextTick()
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('128px')

    // `v-show` on the dock makes it 0×0 while the centre diff is open.
    // Zeroing here would drop the newest message's clearance for the
    // whole time the diff is open.
    dockObserver().emit(0)
    await nextTick()
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('128px')
  })

  it('pads the NEWEST transcript row, not every row', async () => {
    await mountChat()
    const rows = wrapper!.findAll('[data-group-key]')
    expect(rows.length).toBeGreaterThanOrEqual(2)
    const padded = rows.filter((r) => r.classes().includes('last-transcript-row'))
    expect(padded).toHaveLength(1)
    expect(padded[0]!.text()).toContain('second question')
  })

  it('read-only peek mode (hideInput) renders no dock and no inset', async () => {
    await mountChat({ hideInput: true })
    expect(wrapper!.find('[data-testid="composer-dock"]').exists()).toBe(false)
    // No dock → no observer → nothing published. The CSS default (0px)
    // degrades the last row to a plain 1rem, matching the old flow layout.
    const column = wrapper!.element.querySelector('.chat-column') as HTMLElement
    expect(column.style.getPropertyValue('--chat-composer-inset')).toBe('')
    // The newest row is still the padded one, so a peek panel's last
    // message is not jammed against the window edge either.
    const rows = wrapper!.findAll('[data-group-key]')
    expect(rows.filter((r) => r.classes().includes('last-transcript-row'))).toHaveLength(1)
  })
})

describe('ChatView floating composer — source contract', () => {
  it('no longer paints the hard bar the scrim replaced', () => {
    // The composer block itself must not carry the old border + fill.
    const dockIdx = chatViewSrc.indexOf('class="composer-dock p-4"')
    expect(dockIdx).toBeGreaterThan(-1)
    const block = chatViewSrc.slice(dockIdx, dockIdx + 400)
    expect(block).not.toContain('border-top')
    expect(block).not.toContain('--semantic-sidebar-bg')
  })

  it('lifts the composer card above the scrim so the input stays visible', () => {
    // The scrim is a POSITIONED descendant of the dock (`position: absolute`, `z-index: auto`), and
    // CSS paints positioned descendants AFTER in-flow, non-positioned content.
    const cardRule = chatViewSrc.match(
      /\.composer-dock\s+:deep\(\.composer-card\)\s*\{[^}]*\}/,
    )
    expect(cardRule).not.toBeNull()
    expect(cardRule![0]).toMatch(/position:\s*relative;/)
    expect(cardRule![0]).toMatch(/z-index:\s*1;/)
  })

  it('fades the scrim to the transcript background, not the old bar fill', () => {
    // Fading to --semantic-sidebar-bg (#12120f) against a --semantic-content-bg
    // (#181616) transcript would show a 1-shade seam.
    expect(chatViewSrc).toContain('.composer-scrim {')
    const scrimIdx = chatViewSrc.indexOf('.composer-scrim {')
    const scrim = chatViewSrc.slice(scrimIdx, scrimIdx + 500)
    expect(scrim).toContain('linear-gradient(')
    expect(scrim).toContain('var(--semantic-content-bg)')
    expect(scrim).not.toContain('--semantic-sidebar-bg')
    // pointer-events:none so the fade never swallows a click meant for the
    // transcript behind it.
    expect(scrim).toContain('pointer-events: none')
  })

  it('anchors the dock and the scroll-to-bottom arrow off the column', () => {
    expect(chatViewSrc).toMatch(/\.composer-dock\s*\{[^}]*position: absolute;/)
    expect(chatViewSrc).toMatch(/\.composer-dock\s*\{[^}]*bottom: 0;/)
    expect(chatViewSrc).toMatch(
      /\.chat-scroll-to-bottom\s*\{[^}]*bottom: calc\(var\(--chat-composer-inset\) \+ 0\.75rem\);/,
    )
  })

  it('keys the bottom clearance on the group INDEX, never :last-child', () => {
    // `:last-child` pads whichever row the virtual window happens to end
    // on — a mid-transcript row whenever the window does not cover the
    // tail, leaving a ~200px hole in the middle of the conversation.
    expect(chatViewSrc).toContain("isLastGroup(groupIndex) ? 'last-transcript-row'")
    expect(chatViewSrc).not.toMatch(/\.last-transcript-row:last-child/)
    expect(chatViewSrc).toMatch(
      /\.last-transcript-row\s*\{\s*padding-bottom: calc\(var\(--chat-composer-inset\) \+ 1rem\);/,
    )
  })

  it("ChatScrollSlider's track reads the same inset so it stays reachable", () => {
    expect(sliderSrc).toContain('bottom: calc(var(--chat-composer-inset, 0px) + 8px);')
  })
})
