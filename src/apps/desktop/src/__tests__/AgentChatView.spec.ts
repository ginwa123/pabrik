// Behavioural tests for AgentChatView (inline, non-dialog).
import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'
import { defineComponent, h } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentChatView from '../components/views/AgentChatView.vue'
import ChatAppBar from '../components/views/ChatAppBar.vue'

// Stub ChatView — it transitively pulls in many Pinia stores (useNavigationStore,
// useWorkspacesStore, etc.) and a real SSE bus instance, none of which we need to exercise here.
// The stub honours the real `showHeader` contract: it renders the shared ChatAppBar when the flag
// is set and re-emits `close` from the bar's ✕, so these tests assert what AgentChatView actually
// WIRES rather than ChatView's internals (covered by ChatAppBarParity.spec.ts).
const ChatViewStub = defineComponent({
  name: 'ChatView',
  props: ['chatId', 'chatName', 'type', 'cwd', 'showHeader', 'embedded'],
  emits: ['close'],
  setup(props, { emit, slots }) {
    return () =>
      props.showHeader
        ? h(
            ChatAppBar,
            { title: props.chatName as string, onClose: () => emit('close') },
            { extras: () => (slots['app-bar-extras'] ? slots['app-bar-extras']() : null) },
          )
        : h('div', { 'data-testid': 'stub-chat-view' }, 'stub')
  },
})

function mountChatView(props: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(AgentChatView, {
    attachTo: document.body,
    props: {
      task: { id: 'task_1', name: 'Test Chat' },
      workspaceId: 'ws_1',
      itemId: 'item_1',
      cwd: '/tmp/agent',
      ...props,
    },
    global: {
      stubs: { ChatView: ChatViewStub },
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

describe('AgentChatView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('renders inline without Teleport/dialog chrome', async () => {
    mountChatView()
    await nextTick()
    expect(document.querySelector('[data-testid="agent-chat-view"]')).toBeTruthy()
    // No dialog overlay, no backdrop, no aria-modal popup.
    expect(document.querySelector('[data-testid="agent-chat-dialog"]')).toBeFalsy()
    expect(document.querySelector('[role="dialog"]')).toBeFalsy()
  })

  it('uses the shared ChatAppBar instead of a bespoke header', async () => {
    mountChatView()
    await nextTick()
    // One bar, the shared one — the same element kanban and standard
    // mode render (see ChatAppBarParity.spec.ts).
    const bars = document.querySelectorAll('[data-testid="chat-app-bar"]')
    expect(bars.length).toBe(1)
    // No leftover bespoke header / text "Close" button.
    expect(document.querySelector('[data-testid="agent-chat-close"]')).toBeFalsy()
  })

  it('emits close when the shared app bar ✕ is clicked', async () => {
    const { wrapper } = mountChatView()
    await nextTick()
    const closeBtn = document.querySelector(
      '[data-testid="chat-app-bar-close"]',
    ) as HTMLButtonElement
    closeBtn.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('falls back to default title when task has no name', async () => {
    mountChatView({ task: { id: 'task_1' } })
    await nextTick()
    expect(document.body.textContent).toContain('Agent Chat')
  })

  it('uses the shared content bg so agent chats match standalone + design chats', async () => {
    mountChatView()
    await nextTick()
    const root = document.querySelector('[data-testid="agent-chat-view"]') as HTMLElement
    expect(root.getAttribute('style')).toContain('--semantic-content-bg')
    expect(root.getAttribute('style')).not.toContain('--semantic-card-bg')
  })

  it('hides the header loading spinner while the session is idle', async () => {
    mountChatView()
    await nextTick()
    const spinner = document.querySelector('[data-testid="agent-chat-slider"]')
    expect(spinner).toBeNull()
  })

  it('shows the header loading spinner while the session is processing', async () => {
    const { processingState } = mountChatView()
    processingState.value = { task_1: true }
    await nextTick()
    const spinner = document.querySelector('[data-testid="agent-chat-slider"]')
    expect(spinner?.getAttribute('aria-busy')).toBe('true')
  })

  it('keeps the spinner hidden when a different session is processing', async () => {
    const { processingState } = mountChatView()
    processingState.value = { some_other_task: true }
    await nextTick()
    const spinner = document.querySelector('[data-testid="agent-chat-slider"]')
    expect(spinner).toBeNull()
  })
})
