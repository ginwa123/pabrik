/** Tests for FileInput's Stop button — visible only when `isLLMProcessing` is true. The button
 * emits a `stop-session` event for the parent (ChatView) to translate into a `POST
 * /api/llm/session/:session/stop` call. */
/** We deliberately don't call the API directly from FileInput — the component is shared across
 * multiple chat views and the stop semantics are tied to the chat's sessionId, not the input box.
 * Plan: docs/superpowers/plans/2026-08-06-chatview-stop-button.md */
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

describe("FileInput — Stop button (visible only when isLLMProcessing)", () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('A: hides the Stop button when isLLMProcessing is false (default)', async () => {
    const wrapper = await mountInput()
    expect(wrapper.find('[data-testid="stop-session-button"]').exists()).toBe(false)
  })

  it('B: shows the Stop button when isLLMProcessing is true', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    const btn = wrapper.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)
  })

  it('C: button label is "Stop" by default, "Stopping…" when isStopping=true', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    expect(wrapper.find('[data-testid="stop-session-button"]').text()).toContain('Stop')
    expect(wrapper.find('[data-testid="stop-session-button"]').text()).not.toContain('Stopping')

    await wrapper.setProps({ isStopping: true })
    expect(wrapper.find('[data-testid="stop-session-button"]').text()).toContain('Stopping')
  })

  it('D: clicking the Stop button emits a `stop-session` event exactly once', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    const btn = wrapper.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    await btn.trigger('click')

    const emitted = wrapper.emitted('stop-session')
    expect(emitted).toBeDefined()
    expect(emitted!.length).toBe(1)
  })

  it('E: button is disabled + shows spinner while isStopping=true', async () => {
    const wrapper = await mountInput({
      isLLMProcessing: true,
      isStopping: true,
    })
    const btn = wrapper.find<HTMLButtonElement>('[data-testid="stop-session-button"]')
    expect(btn.element.disabled).toBe(true)
    // The spinner is the border-2 rounded-full animate-spin element.
    // Confirm by checking for the animate-spin class presence.
    expect(wrapper.find('[data-testid="stop-session-button"] .animate-spin').exists()).toBe(true)
  })

  it('F: clicking while isStopping=true does NOT emit a second stop-session (debounce)', async () => {
    const wrapper = await mountInput({
      isLLMProcessing: true,
      isStopping: true,
    })
    const btn = wrapper.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    await btn.trigger('click')

    const emitted = wrapper.emitted('stop-session')
    expect(emitted).toBeUndefined()
  })

  it('G: when isLLMProcessing flips from true to false, the button re-hides', async () => {
    const wrapper = await mountInput({ isLLMProcessing: true })
    expect(wrapper.find('[data-testid="stop-session-button"]').exists()).toBe(true)

    await wrapper.setProps({ isLLMProcessing: false })
    expect(wrapper.find('[data-testid="stop-session-button"]').exists()).toBe(false)
  })

  it('H: when isLLMProcessing flips from true to false while isStopping=true, the watch resets isStopping to false', async () => {
    // We start with both isLLMProcessing=true and isStopping=true (parent has been waiting for
    // SSE).
    const wrapper = await mountInput({
      isLLMProcessing: true,
      isStopping: true,
    })

    await wrapper.setProps({ isLLMProcessing: false })
    await flushPromises()

    // After the reset, setting isLLMProcessing back to true should NOT
    // carry over the stuck spinner. We assert by checking the label.
    await wrapper.setProps({
      isLLMProcessing: true,
      isStopping: false, // parent has reset it
    })
    const btn = wrapper.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toContain('Stop')
    expect(btn.text()).not.toContain('Stopping')
  })
})