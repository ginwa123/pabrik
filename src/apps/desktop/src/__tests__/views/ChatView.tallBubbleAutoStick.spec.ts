/**
 * The reported scenario, end to end on the real component:
 *
 *   "Chatview has issue if sse send a llm chunk and llm full data finish
 *    reason stop, its like automatically go to bottom scrollbar chatview"
 *   + "if the messages many and the content response is long, it is not auto
 *      scroll bottom"
 *
 * A 1000-message chat, bubbles whose content is tall enough to fill the screen
 * on its own, and the "thought" (reasoning) sections — then a long streamed
 * response that arrives as a run of `llm_chunk` events and finishes with the
 * `llm_full(finish_reason='stop')` that swaps the streaming row for the
 * canonical one.
 *
 * WHY THE SHAPE MATTERS
 *   Both halves of the report are needed to break it, and neither is enough:
 *
 *   - MANY messages make the sizer hundreds of screens tall, so any correction
 *     to the height model above the viewport is measured in thousands of
 *     pixels rather than tens.
 *   - TALL content (and reasoning sections, which are a small collapsed pill
 *     until expanded) makes the virtual window keep EXPANDING as the response
 *     grows, so batches of rows above the anchor measure for the first time
 *     mid-turn.
 *
 *   The anchor-compensation pass then wrote `scrollTop += prefixDelta`, which
 *   is right for a reader in the history and wrong for a reader at the bottom.
 *   It stranded them thousands of pixels up, and — this is the part that makes
 *   the REPORTED symptom — ChatView reads that write as "the user left the
 *   bottom" and disarms every follow gate. The rest of the long response then
 *   streams off-screen. The fix and its geometry live in
 *   `virtualScrollerScrollAnchor.ts` / `VirtualScroller.measureItems`; the
 *   regression test for the geometry is
 *   `virtualScrollerTallBubbleAutoStick.spec.ts`.
 *
 * WHAT IS ASSERTED HERE
 *   The app's OWN answer, not a re-derivation of it: `.chat-scroll-to-bottom`
 *   is rendered under `v-if="!isAtBottom && …"`, so its ABSENCE is literally
 *   the flag every follow gate reads. Re-deriving the predicate in the test is
 *   how a test passes while asserting nothing.
 *
 *   jsdom has no layout, so this file cannot express the pixel-level geometry
 *   (that is the sibling spec's job and the Playwright suite's). What it does
 *   prove is that the real SSE handler, over the real 1000-message transcript
 *   with the real tall bodies and reasoning sections, never flips that flag off
 *   for a reader who is at the bottom — including across the
 *   `streaming-*` → canonical-row swap, which is the specific event the report
 *   names.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref, type App as VueApp, type Ref } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

// ── The hoisted api mock ──────────────────────────────────────────────────── Two seams, both
// required, both hoisted.
const historyRows: unknown[] = []
const historyResponse = () => ({
  messages: historyRows,
  has_more: false,
  next_cursor: null,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
})
vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(historyResponse()),
    fetchChatHistoryEffect: () => Effect.succeed(historyResponse()),
  }
})

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: () => ({ query: {}, path: '/app', params: {} }),
    useRouter: () => ({
      replace: vi.fn(() => Promise.resolve()),
      push: vi.fn(() => Promise.resolve()),
      back: vi.fn(),
    }),
  }
})

// jsdom does not implement HTMLElement.prototype.scrollTo — polyfill it so
// scrollToBottom observably moves scrollTop.
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: (arg: unknown) => void } } }
  ).HTMLElement.prototype.scrollTo = function (arg: unknown) {
    if (typeof arg === 'number') {
      ;(this as HTMLElement).scrollTop = arg
      return
    }
    if (arg && typeof arg === 'object' && 'top' in arg) {
      const top = (arg as { top?: number }).top
      if (typeof top === 'number') {
        ;(this as HTMLElement).scrollTop = top
      }
    }
  }
}

// No layout in jsdom: a fixed tall geometry so the 1000-message transcript is
// usably scrollable from mount and "the bottom" is a known number.
const TOTAL_HEIGHT = 20000
const VIEWPORT = 800
const BOTTOM = TOTAL_HEIGHT - VIEWPORT

Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    return TOTAL_HEIGHT
  },
})
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return VIEWPORT
  },
})

/** "1000 messages" — the volume half of the report. */
const MESSAGE_COUNT = 1000

/** A body long enough to fill the viewport on its own when rendered — the "content can be height is
 * very height until full screen" half. */
const FULL_SCREEN_BODY = Array.from({ length: 40 }, (_, i) =>
  `Paragraph ${i} of a very long pasted log or diff body. `.repeat(12),
).join('\n\n')

/** A "thought" — the reasoning section, which is a pill until expanded. */
const THOUGHT = Array.from({ length: 30 }, (_, i) => `Thinking step ${i}. `).join(' ')

function seedTallTranscript(): void {
  historyRows.length = 0
  for (let i = 0; i < MESSAGE_COUNT; i++) {
    const bucket = i % 10
    // 20% a full-screen-tall bubble, 20% carries a thought, the rest a
    // normal paragraph — heterogeneous on purpose, since uniform rows make
    // the height-model corrections cancel out and hide this class of bug.
    const content = bucket < 2 ? FULL_SCREEN_BODY : `Short message ${i}`
    const row: Record<string, unknown> = {
      id: `msg_${i}`,
      role: i % 2 === 0 ? 'user' : 'assistant',
      content,
      created_at: i,
      image_url: '',
      finish_reason: i % 2 === 0 ? '' : 'stop',
    }
    if (bucket === 2 || bucket === 5) row.reasoning_content = THOUGHT
    historyRows.push(row)
  }
}

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

function installApiMocks(): void {
  seedTallTranscript()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [], count: 0 } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    has_changes: false,
    is_clean: true,
    current: '',
    status: 'clean',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as any)
}

async function mountChatView(
  chatId: string,
  processingState: Ref<Record<string, boolean>>,
): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Tall bubbles' },
    attachTo: document.body,
    global: { provide: { processingState } },
  })
  // The scroller's mount gate is `!isInitializing && (isLoading || messageGroups.length > 0)`, and
  // `isInitializing` only clears once the history load settles — so the scroller's presence IS the
  // signal, and waiting on it turns a silent "never rendered" into one clear error.
  for (let i = 0; i < 100; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  await new Promise((r) => setTimeout(r, 400))
  await nextTick()
  return wrapper
}

function emitLlm(payload: Record<string, unknown>): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  __dispatchSseBus('llm', payload as any)
}

async function settle(ms = 250): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
  await nextTick()
}

/**  * The app's own "is the reader at the bottom" answer, read from the DOM the way a user would: the
 * jump-to-bottom arrow is rendered under `v-if="!isAtBottom && …"`, so it is the flag itself. */
function stickDisarmed(wrapper: VueWrapper): boolean {
  return wrapper.find('.chat-scroll-to-bottom').exists()
}

describe('ChatView — 1000 messages, full-screen-tall bodies, thoughts, long response', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null
  const processingState = ref<Record<string, boolean>>({})

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => {
          store[k] = String(v)
        },
        removeItem: (k: string) => {
          delete store[k]
        },
        clear: () => {
          for (const k in store) delete store[k]
        },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
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

  it('follows a long response: a run of llm_chunk, then llm_full(finish_reason=stop)', async () => {
    const session = 'tall_stick_long_response'
    installApiMocks()
    wrapper = await mountChatView(session, processingState)
    if (!wrapper.find('.virtual-scroller').exists()) {
      throw new Error('.virtual-scroller not mounted — the 1000-message load never settled')
    }
    const container = wrapper.find('.virtual-scroller').element as HTMLElement
    expect(container.scrollTop).toBe(BOTTOM)
    expect(stickDisarmed(wrapper)).toBe(false)

    // A LONG response: many deltas, each appending to the streaming row. This
    // is the "content response is long" half — one chunk would not grow the
    // window the way a run of them does.
    for (let i = 0; i < 12; i++) {
      emitLlm({
        type: 'chunk',
        session_id: session,
        role: 'assistant',
        content: `${FULL_SCREEN_BODY.slice(0, 4000)}\n\n`,
        reasoning_content: i % 3 === 0 ? THOUGHT : undefined,
      })
      await settle(120)
      if (stickDisarmed(wrapper)) {
        throw new Error(
          `the stick disarmed itself at chunk ${i} of 12 — the reader was at the ` +
            `bottom the whole time`,
        )
      }
    }

    // The finishing event the report names: the streaming row is swapped for
    // the canonical DB row under a new id and a new group key, at a different
    // height than the row it replaces.
    emitLlm({
      type: 'full',
      session_id: session,
      id: 'db_row_tall_final',
      role: 'assistant',
      // Deliberately NOT byte-identical to the seeded tall bodies: the `full` handler drops an
      // event that duplicates an existing row on role + content + tool_call_id (the 2026-08-23
      // TOOLS-pill-spam fix), and 20% of the seed carries exactly `FULL_SCREEN_BODY`.
      content: `${FULL_SCREEN_BODY}\n\nFinal line that only this turn has.`,
      reasoning_content: THOUGHT,
      finish_reason: 'stop',
    })
    await settle(400)

    expect(stickDisarmed(wrapper)).toBe(
      false,
      'llm_full(finish_reason=stop) disarmed the stick for a reader at the bottom',
    )
    expect(container.scrollTop).toBe(BOTTOM)

    // The canonical row really did replace the streaming one — otherwise the
    // assertions above ran before the swap happened and proved nothing.
    const vm = wrapper.vm as unknown as { messages: Array<{ id: string }> }
    expect(vm.messages.some((m) => m.id === 'db_row_tall_final')).toBe(true)
    expect(vm.messages.some((m) => m.id.startsWith('streaming-'))).toBe(false)
  })

  it('re-arms and follows again after the reader returns from the history', async () => {
    // The exact arming moment the reported bug used to be lost at: the reader goes up to read
    // history, comes back with the app's own jump-to-bottom affordance (which re-arms
    // `isAtBottom`), and THEN a long response arrives.
    const session = 'tall_stick_return'
    installApiMocks()
    wrapper = await mountChatView(session, processingState)
    const container = wrapper.find('.virtual-scroller').element as HTMLElement

    // Up into the history, then back with the arrow the reader would click.
    container.scrollTop = 5000
    container.dispatchEvent(new Event('scroll'))
    await settle(300)
    expect(stickDisarmed(wrapper)).toBe(true)

    emitLlm({
      type: 'chunk',
      session_id: session,
      role: 'assistant',
      content: 'A long answer that starts while the reader is still in the history.',
    })
    await settle(300)
    // A scrolled-up reader must be left alone — that is the other half of the
    // contract, and the reason the fix is a re-target rather than "always jump".
    expect(container.scrollTop).toBe(5000)

    // Come back to the tail, the way a reader does.
    const arrow = wrapper.find('.chat-scroll-to-bottom')
    expect(arrow.exists()).toBe(true)
    await arrow.trigger('click')
    await nextTick()
    container.dispatchEvent(new Event('scroll'))
    await settle(400)
    expect(stickDisarmed(wrapper)).toBe(false)

    // Now the long response, which is what used to strand them.
    for (let i = 0; i < 8; i++) {
      emitLlm({
        type: 'chunk',
        session_id: session,
        role: 'assistant',
        content: `${FULL_SCREEN_BODY.slice(0, 4000)}\n\n`,
        reasoning_content: i % 2 === 0 ? THOUGHT : undefined,
      })
      await settle(150)
      if (stickDisarmed(wrapper)) {
        throw new Error(`the re-armed stick died at chunk ${i} of 8 after returning to the tail`)
      }
    }

    emitLlm({
      type: 'full',
      session_id: session,
      id: 'db_row_tall_return',
      role: 'assistant',
      content: `${FULL_SCREEN_BODY}\n\nFinal line unique to this turn.`,
      reasoning_content: THOUGHT,
      finish_reason: 'stop',
    })
    await settle(400)

    expect(stickDisarmed(wrapper)).toBe(false)
    expect(container.scrollTop).toBe(BOTTOM)
  })
})
