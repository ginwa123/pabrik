/** Tests for FileInput's submit (Send/Queue) button — hidden while the LLM is processing. When
 * `isLLMProcessing === true`, the user should NOT see the Send/Queue button. The Stop button on the
 * left is the only action affordance during processing. */

/** Before the fix, the submit button stayed visible with its label flipped to "Queue" and a
 * spinner, which was visual noise — the user can't queue more work while the agent is already
 * running (the user explicitly asked to hide it: "remove button queue when in processing"). */

/** When `isLLMProcessing === false`, the button returns to its normal "Send" state. The brief
 * network-in-flight moment (when `isLoading === true` but the SSE hasn't yet flipped
 * `processingState`) still shows the button — only the agent-processing state hides it. */

/** Plan: docs/superpowers/plans/2026-08-06-hide-queue-button-processing.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/file/FileInput.vue'

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

describe('FileInput — Send/Queue button (hidden while isLLMProcessing)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('A: shows the Send/Queue button when isLLMProcessing is false (default)', async () => {
    const wrapper = await mountInput()
    const btn = wrapper.find('[data-testid="send-message-button"]')
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toContain('Send')
    expect(btn.text()).not.toContain('Queue')
  })

  it('B: hides the Send/Queue button when isLLMProcessing is true', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    const btn = wrapper.find('[data-testid="send-message-button"]')
    expect(btn.exists()).toBe(false)
  })

  it('C: when isLLMProcessing flips from false to true, the Send/Queue button disappears', async () => {
    const wrapper = await mountInput()
    expect(wrapper.find('[data-testid="send-message-button"]').exists()).toBe(true)

    await wrapper.setProps({ isLLMProcessing: true })
    expect(wrapper.find('[data-testid="send-message-button"]').exists()).toBe(false)
  })

  it('D: when isLLMProcessing flips from true to false, the Send/Queue button reappears as "Send"', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    expect(wrapper.find('[data-testid="send-message-button"]').exists()).toBe(false)

    await wrapper.setProps({ isLLMProcessing: false })
    const btn = wrapper.find('[data-testid="send-message-button"]')
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toContain('Send')
    expect(btn.text()).not.toContain('Queue')
  })

  it('E: when isLoading is true (network in-flight) but isLLMProcessing is false, the button still shows with spinner + "Queue" label', async () => {
    // During the brief window between "user pressed Send" and the SSE worker-created event landing
    // in processingState, the local isLoading flag is true while isLLMProcessing is still false.
    // The button should still be visible in this window — only the agent-processing state hides it.
    const wrapper = await mountInput({ isLoading: true })
    const btn = wrapper.find('[data-testid="send-message-button"]')
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toContain('Queue')
  })

  it('F: when both isLoading and isLLMProcessing are true, the button is hidden (isLLMProcessing wins)', async () => {
    const wrapper = await mountInput({ isLoading: true, isLLMProcessing: true })
    const btn = wrapper.find('[data-testid="send-message-button"]')
    expect(btn.exists()).toBe(false)
  })
})
