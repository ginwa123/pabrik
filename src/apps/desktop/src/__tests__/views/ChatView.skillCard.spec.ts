/** The transcript's rendering of a manual `/skill-` turn: `ChatView.vue` must
 * render the `<slash_skills>` envelope as a card, never echo it. The card's own
 * behaviour is spec'd in `components/preview/__tests__/SkillInvocationCard.spec.ts`. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

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

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

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

const BODY = ['# Deterministic Unit Tests', '', '- test behaviour', '- inject hidden inputs'].join(
  '\n',
)
const TYPED = '/skill-behavior-unit-tests'
const ENVELOPE_MESSAGE = `${TYPED}\n\n<slash_skills>\n<skill name="behavior-unit-tests">${BODY}</skill>\n</slash_skills>`

const installApiMocks = (): void => {
  historyRows.length = 0
  historyRows.push({
    id: 'msg_skill',
    role: 'user',
    content: ENVELOPE_MESSAGE,
    created_at: 1,
    image_url: '',
    finish_reason: '',
  })
  historyRows.push({
    id: 'msg_plain',
    role: 'user',
    content: 'a plain message with no skills at all',
    created_at: 2,
    image_url: '',
    finish_reason: '',
  })
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
    selectedAgent: null,
    cwd: '',
    git_worktree_cwd: '',
  } as never)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
    is_git_repo: false,
    branch: '',
    has_changes: false,
    is_clean: true,
    current: '',
    status: 'clean',
  } as never)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as never)
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  await new Promise((r) => setTimeout(r, 300))
  await nextTick()
  if (!wrapper.find('.virtual-scroller').exists()) {
    throw new Error('.virtual-scroller not mounted — the history load never settled')
  }
  return wrapper
}

describe('ChatView, a manual /skill- turn', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    // jsdom in this environment has no working localStorage, and the
    // navigation store reads it during setup (same stub as streamingStick).
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

  it('renders the envelope as a card, never as escaped XML', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_skill_card')

    expect(wrapper.find('[data-testid="skill-invocation-card"]').exists()).toBe(true)
    expect(wrapper.text()).toContain(TYPED)
    expect(wrapper.text()).not.toContain('<slash_skills>')
    expect(wrapper.text()).not.toContain('<skill name=')
    expect(wrapper.text()).not.toContain('# Deterministic Unit Tests')
  })

  it('leaves a message with no envelope exactly as it was typed', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_skill_card_plain')

    expect(wrapper.text()).toContain('a plain message with no skills at all')
    // Both turns are in one transcript; only the skill turn gets a card.
    expect(wrapper.findAll('[data-testid="skill-invocation-card"]')).toHaveLength(1)
  })

  it('names the invoked skill once the card is opened', async () => {
    installApiMocks()
    wrapper = await mountChatView('task_skill_card_open')

    await wrapper.find('[data-testid="sic-head"]').trigger('click')
    const rows = wrapper.findAll('[data-testid="sic-row"]')
    expect(rows).toHaveLength(1)
    expect(rows[0]?.text()).toContain('behavior-unit-tests')
    expect(wrapper.text()).toContain('1 skill')
  })
})
