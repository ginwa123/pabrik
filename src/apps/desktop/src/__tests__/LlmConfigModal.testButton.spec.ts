import { mount, type VueWrapper } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { LlmTestResult } from '../api'
import LlmConfigModal, { type LlmConfigModalValue } from '../components/pabrik/LlmConfigModal.vue'

// Mock the `testLlmProfile` API client so the modal's "Test" button
// tests don't hit the network. Per-test overrides shape success vs
// failure responses.
const mockTestLlmProfile = vi.fn(
  async (): Promise<LlmTestResult> => ({
    ok: true,
    model: 'MiniMax-M2.7',
    reply: 'ok',
    latency_ms: 123,
  }),
)

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    testLlmProfile: (...args: unknown[]) =>
      mockTestLlmProfile(...(args as Parameters<typeof mockTestLlmProfile>)),
  }
})

const baseValue: LlmConfigModalValue = {
  name: 'work',
  config: {
    model: 'MiniMax-M2.7',
    base_url: 'https://api.minimax.io/v1/chat/completions',
    thinking: 'auto',
    temperature: 'auto',
    url_style: 'openai',
    api_key: 'sk-test',
    max_capacity_tokens: null,
    compaction_threshold_percent: null,
    thinking_budget_tokens: null,
    reasoning_effort: null,
  },
}

/**  * LlmConfigModal uses <Teleport to="body">, so tests MUST use `document.body.querySelector` for
 * teleported elements (NOT `wrapper.find`) and `mount({ attachTo: document.body })`. (See the
 * vue-teleport-vitest-document-queryselector skill.) */
function mountModal(value: LlmConfigModalValue = baseValue): VueWrapper {
  return mount(LlmConfigModal, {
    props: {
      modelValue: value,
      title: 'Add profile',
      nameEditable: true,
    },
    attachTo: document.body,
  })
}

function testBtn(): HTMLButtonElement | null {
  return document.body.querySelector('[data-testid="llm-test-btn"]')
}

describe('LlmConfigModal — Test LLM button', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    mockTestLlmProfile.mockClear()
    mockTestLlmProfile.mockResolvedValue({
      ok: true,
      model: 'MiniMax-M2.7',
      reply: 'ok',
      latency_ms: 123,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.querySelectorAll('[role="dialog"]').forEach((el) => el.remove())
  })

  it('renders Test alongside Cancel/Save in the footer', async () => {
    wrapper = mountModal()
    await wrapper.vm.$nextTick()
    expect(testBtn()).not.toBeNull()
    expect(testBtn()?.textContent).toContain('Test')
    expect(document.body.querySelector('[data-testid="modal-cancel"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="modal-save"]')).not.toBeNull()
  })

  it('disables Test when the model is empty, enables it when present', async () => {
    wrapper = mountModal({
      ...baseValue,
      config: { ...baseValue.config, model: '   ' },
    })
    await wrapper.vm.$nextTick()
    expect((testBtn() as HTMLButtonElement).disabled).toBe(true)

    await wrapper.setProps({
      modelValue: { ...baseValue, config: { ...baseValue.config, model: 'm' } },
    })
    await wrapper.vm.$nextTick()
    expect((testBtn() as HTMLButtonElement).disabled).toBe(false)
  })

  it('sends model/base_url/api_key/url_style and renders the green reply panel on success', async () => {
    wrapper = mountModal()
    await wrapper.vm.$nextTick()

    testBtn()?.click()
    await new Promise((r) => setTimeout(r, 0))
    await wrapper.vm.$nextTick()

    expect(mockTestLlmProfile).toHaveBeenCalledTimes(1)
    expect(mockTestLlmProfile).toHaveBeenCalledWith({
      model: 'MiniMax-M2.7',
      base_url: 'https://api.minimax.io/v1/chat/completions',
      api_key: 'sk-test',
      url_style: 'openai',
    })
    const panel = document.body.querySelector('[data-testid="llm-test-result"]')
    expect(panel).not.toBeNull()
    expect(panel?.textContent).toContain('Connected')
    expect(panel?.textContent).toContain('ok')
    expect(panel?.textContent).toContain('123ms')
  })

  it('renders the red error panel with error + details on failure', async () => {
    mockTestLlmProfile.mockResolvedValue({
      ok: false,
      error: 'LLM server returned an error status',
      details: 'http 401: {"error":"invalid key"}',
    })
    wrapper = mountModal()
    await wrapper.vm.$nextTick()

    testBtn()?.click()
    await new Promise((r) => setTimeout(r, 0))
    await wrapper.vm.$nextTick()

    const panel = document.body.querySelector('[data-testid="llm-test-result"]')
    expect(panel).not.toBeNull()
    expect(panel?.textContent).toContain('Connection failed')
    expect(document.body.querySelector('[data-testid="llm-test-error"]')?.textContent).toContain(
      'LLM server returned an error status',
    )
    expect(panel?.textContent).toContain('http 401')
  })

  it('clears a previous result when the form is edited (no stale badges)', async () => {
    wrapper = mountModal()
    await wrapper.vm.$nextTick()

    testBtn()?.click()
    await new Promise((r) => setTimeout(r, 0))
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="llm-test-result"]')).not.toBeNull()

    // Simulate typing a new model value.
    await wrapper.setProps({
      modelValue: { ...baseValue, config: { ...baseValue.config, model: 'Other-Model' } },
    })
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="llm-test-result"]')).toBeNull()
  })

  it('surfaces unexpected exceptions as an inline failure (no throw)', async () => {
    mockTestLlmProfile.mockRejectedValue(new Error('network down'))
    wrapper = mountModal()
    await wrapper.vm.$nextTick()

    testBtn()?.click()
    await new Promise((r) => setTimeout(r, 0))
    await wrapper.vm.$nextTick()

    expect(document.body.querySelector('[data-testid="llm-test-error"]')?.textContent).toContain(
      'network down',
    )
  })
})
