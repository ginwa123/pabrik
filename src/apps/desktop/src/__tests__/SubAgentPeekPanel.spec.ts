/** Tests for SubAgentPeekPanel — the slide-over for watching a
 * sub-agent's progress without leaving the parent chat.
 * Since the reuse refactor (task_1788604407681_2) the panel is thin
 * chrome (header / error banner / footer) around an embedded ChatView
 * in read-only mode. Message rendering + tool output components are
 * ChatView's job — this spec asserts the chrome and the embed wiring,
 * not message bubbles (those belong to ChatView's own specs). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import SubAgentPeekPanel from '../components/pabrik/SubAgentPeekPanel.vue'
import type { Message } from '../api'

// Stub the embedded ChatView so we can assert the embed wiring
// without mounting the full 4000-line chat (VirtualScroller, SSE,
// FileInput, …). The stub records its props for assertions.
//
// NOTE: the stub is defined inline (not via a top-level const) because
// `vi.mock` factories are hoisted above the module body — referencing
// an outer const from the factory hits the TDZ at import time. Lookup
// in tests uses `findComponent({ name: 'ChatView' })`.
vi.mock('../components/views/ChatView.vue', async () => {
  const { h } = await vi.importActual<typeof import('vue')>('vue')
  return {
    default: {
      name: 'ChatView',
      // Typed props (not a string array) so Vue applies Boolean casting: the panel passes bare
      // `embedded` / `hide-input` attributes, which arrive as `""` and must cast to `true` —
      // exactly like the real ChatView's `embedded?: boolean` / `hideInput?: boolean`.
      props: {
        chatId: String,
        chatName: String,
        embedded: Boolean,
        hideInput: Boolean,
      },
      setup(props: { chatId: string; chatName: string }) {
        return () =>
          h(
            'div',
            { 'data-testid': 'chatview-stub' },
            `${props.chatId} / ${props.chatName}`,
          )
      },
    },
  }
})
// Stub Teleport (the panel uses Teleport to mount into <body>) so
// @vue/test-utils' `find()` traverses inside.
vi.mock('vue', async () => {
  const actual = await vi.importActual<typeof import('vue')>('vue')
  return {
    ...actual,
    Teleport: { name: 'Teleport', setup(_: unknown, { slots }: { slots: { default?: () => unknown } }) { return () => slots.default?.() } },
  }
})

function makeBaseProps(overrides: Partial<{
  sessionId: string
  agentName: string
  instruction: string
  status: 'idle' | 'loading' | 'streaming' | 'complete' | 'error'
  errorMessage: string | null
  messages: Message[]
  totalTokens: number
}> = {}) {
  return {
    sessionId: 'subagent_1_foo',
    agentName: 'foo',
    instruction: 'do X',
    status: 'streaming' as const,
    errorMessage: null,
    messages: [] as Message[],
    totalTokens: 0,
    ...overrides,
  }
}

describe('SubAgentPeekPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('renders the agent name in the header', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    expect(wrapper.text()).toContain('foo')
  })

  it('shows the streaming spinner + label when status is streaming', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.exists()).toBe(true)
    expect(status.text()).toMatch(/Streaming/i)
  })

  it('shows the Complete label when status is complete', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ status: 'complete' }),
    })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.text()).toMatch(/Complete/i)
  })

  it('shows the Error label + banner when status is error', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({
        status: 'error',
        errorMessage: 'HTTP 500: backend down',
      }),
    })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.text()).toMatch(/Error/i)
    const banner = wrapper.find('[data-testid="peek-error-banner"]')
    expect(banner.exists()).toBe(true)
    expect(banner.text()).toContain('HTTP 500')
  })

  it('emits close when the close button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    await wrapper.find('[data-testid="peek-close"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits openFull with the sessionId when the Open full button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    await wrapper.find('[data-testid="peek-open-full"]').trigger('click')
    expect(wrapper.emitted('openFull')).toBeTruthy()
    expect(wrapper.emitted('openFull')![0]).toEqual(['subagent_1_foo'])
  })

  it('truncates long instructions to 200 chars + ellipsis in the header', () => {
    const longInstruction = 'x'.repeat(400)
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ instruction: longInstruction }),
    })
    const preview = wrapper.find('[data-testid="peek-instruction"]')
    expect(preview.text().length).toBeLessThanOrEqual(205) // 200 + "…"
    expect(preview.text().endsWith('…')).toBe(true)
    expect(preview.attributes('title')).toBe(longInstruction)
  })

  it('renders the footer with session_id + token count', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ totalTokens: 4217 }),
    })
    expect(wrapper.text()).toContain('subagent_1_foo')
    expect(wrapper.text()).toContain('4,217')
  })

  // ── ChatView embed (task_1788604407681_2) ─────────────────────────── The panel body reuses
  // ChatView in read-only mode instead of a hand-mirrored tool-dispatch chain. Message bubbles,
  // tool cards, markdown, and error cards are ChatView's responsibility.

  it('embeds ChatView with the sub-agent session id + name', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    const stub = wrapper.find('[data-testid="chatview-stub"]')
    expect(stub.exists()).toBe(true)
    expect(stub.text()).toContain('subagent_1_foo')
    expect(stub.text()).toContain('foo')
  })

  it('embeds ChatView in read-only mode (embedded + hide-input)', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    const chatView = wrapper.findComponent({ name: 'ChatView' })
    expect(chatView.exists()).toBe(true)
    expect(chatView.props('chatId')).toBe('subagent_1_foo')
    expect(chatView.props('chatName')).toBe('foo')
    expect(chatView.props('embedded')).toBe(true)
    expect(chatView.props('hideInput')).toBe(true)
  })

  it('renders the embedded ChatView inside the peek scroll container', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    const scroll = wrapper.find('[data-testid="peek-messages-scroll"]')
    expect(scroll.exists()).toBe(true)
    expect(scroll.find('[data-testid="chatview-stub"]').exists()).toBe(true)
  })

  it('renders one ChatView per session id (A → B swap wiring)', () => {
    // Production swaps by REMOUNTING the host (`:key="sessionId"` on SubAgentPeekHost in ChatView),
    // not by mutating the panel's props in place — so assert per-mount wiring: each session id
    // reaches the embedded ChatView as `chat-id` / `chat-name`.
    const first = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ sessionId: 'subagent_1_foo', agentName: 'foo' }),
    })
    expect(first.findComponent({ name: 'ChatView' }).props('chatId')).toBe(
      'subagent_1_foo',
    )
    const second = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ sessionId: 'subagent_2_bar', agentName: 'bar' }),
    })
    const secondChat = second.findComponent({ name: 'ChatView' })
    expect(secondChat.props('chatId')).toBe('subagent_2_bar')
    expect(secondChat.props('chatName')).toBe('bar')
  })

  it('does NOT render its own message bubbles (ChatView owns them)', () => {
    const messages: Message[] = [
      { id: 'u1', role: 'user', content: 'do the task', created_at: 1000 },
      { id: 'a1', role: 'assistant', content: 'starting now', created_at: 1001 },
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    expect(wrapper.find('[data-testid="peek-msg-user"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="peek-msg-assistant"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="peek-msg-tool"]').exists()).toBe(false)
  })
})
