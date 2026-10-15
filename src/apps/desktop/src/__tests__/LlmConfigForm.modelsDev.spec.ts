/**
 * The v2 profile form's OWN contract: the fact line and the model picker.
 *
 * The existing LlmConfigForm specs cover what the form EMITS. These cover what
 * it TELLS YOU — which is the whole point of the redesign, and the part that
 * would otherwise be untested decoration.
 *
 * The rule under test: a number shown to the user must say where it came from.
 * `1,000,000 context` means the catalog knows the model. `200k context` with a
 * `built-in` tag means pabrik is guessing, and the user must be able to see the
 * difference.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'

import { resolveModelOutcome, getModelCatalog } from '../api'
import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

vi.mock('../api', () => ({
  resolveModelOutcome: vi.fn(),
  getModelCatalog: vi.fn(),
}))

/** Typed explicitly: with `as const`-style inference the nullable fields narrow
 * to the literal `null`, so passing an override that sets one to a NUMBER is a
 * type error (`vue-tsc` catches it; `vitest` alone would not). */
interface FormValue {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  max_capacity_tokens: number | null
  compaction_threshold_percent: number | null
  thinking_budget_tokens: number | null
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}

const baseValue: FormValue = {
  model: 'deepseek-flash',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: 'sk-x',
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
  thinking_budget_tokens: null,
  reasoning_effort: null,
}

function mountForm(overrides: Partial<FormValue> = {}) {
  return mount(LlmConfigForm, { props: { modelValue: { ...baseValue, ...overrides } } })
}

beforeEach(() => {
  vi.mocked(getModelCatalog).mockResolvedValue({
    total: 0,
    returned: 0,
    catalog: 'fresh',
    fetched_at_ms: 1_760_000_000_000,
    models: [],
  })
})

describe('LlmConfigForm — the fact line', () => {
  it('states the resolved window, where compaction fires, and the source', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'deepseek-flash',
        catalog: 'fresh',
        source: 'catalog',
        provider_name: 'DeepSeek',
        context_window: 1_000_000,
        output_tokens: 393_216,
        reasoning: 'effort',
        temperature: true,
        cost: { input: 0.15, output: 0.6 },
      },
    })

    const wrapper = mountForm()
    await flushPromises()

    const line = wrapper.find('[data-testid=model-fact-line]').text()
    // The two numbers that change behaviour…
    expect(line).toContain('1M context')
    expect(line).toContain('compacts at 800k') // 80% of 1M, the global default
    // …plus the provenance, which is the part that stops a guess looking alike.
    expect(line).toContain('models.dev')
    expect(line).toContain('DeepSeek')
  })

  it('moves the compaction point when a threshold override is set', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'deepseek-flash',
        catalog: 'fresh',
        source: 'catalog',
        context_window: 1_000_000,
        reasoning: 'none',
      },
    })

    const wrapper = mountForm({ compaction_threshold_percent: 50 })
    await flushPromises()

    // Same window, different threshold -> a visibly different promise, without
    // the user having to compute it.
    expect(wrapper.find('[data-testid=model-fact-line]').text()).toContain('compacts at 500k')
  })

  it('says the window is the built-in guess when the catalog cannot answer', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'some-self-hosted-thing',
        catalog: 'fresh',
        source: 'builtin',
        context_window: 200_000,
        reason: 'this model is not in the catalog — the built-in window applies',
      },
    })

    const wrapper = mountForm({ model: 'some-self-hosted-thing' })
    await flushPromises()

    const line = wrapper.find('[data-testid=model-fact-line]').text()
    expect(line).toContain('unknown model')
    expect(line).toContain('200k')
  })

  it('reports WHY when the resolve call itself fails, instead of showing nothing', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({ kind: 'error', message: 'backend down' })

    const wrapper = mountForm()
    await flushPromises()

    // A blank line would leave "unknown model" and "backend down" indistinguishable.
    expect(wrapper.find('[data-testid=model-fact-line]').text()).toContain('backend down')
  })
})

describe('LlmConfigForm — the model picker', () => {
  it('offers catalog matches and chooses one on click', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: { model: 'deepseek-flash', catalog: 'fresh', source: 'catalog', context_window: 1_000_000 },
    })
    vi.mocked(getModelCatalog).mockResolvedValue({
      total: 2,
      returned: 2,
      catalog: 'fresh',
      fetched_at_ms: 1_760_000_000_000,
      models: [
        {
          provider_id: 'deepseek',
          provider_name: 'DeepSeek',
          model_id: 'deepseek-flash',
          model_name: 'DeepSeek V4.1 Flash',
          context_window: 1_000_000,
          output_tokens: 393_216,
          reasoning: 'effort',
          temperature: true,
        },
        {
          provider_id: 'opencode-go',
          provider_name: 'opencode-go',
          model_id: 'deepseek-v4-pro',
          model_name: 'DeepSeek V4.1 Pro',
          context_window: 1_000_000,
          output_tokens: null,
          reasoning: 'effort',
          temperature: true,
        },
      ],
    })

    const wrapper = mountForm()
    await flushPromises()

    await wrapper.find('[data-testid=model-input]').setValue('deepseek')
    await new Promise((r) => setTimeout(r, 250))
    await flushPromises()

    const picker = wrapper.find('[data-testid=model-picker]')
    expect(picker.exists()).toBe(true)
    expect(picker.text()).toContain('deepseek-flash')
    // The row names the provider, because a bare model id is ambiguous.
    expect(picker.text()).toContain('opencode-go')

    await wrapper.find('[data-testid=model-option-deepseek-v4-pro]').trigger('mousedown')
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as FormValue
    expect(emitted.model).toBe('deepseek-v4-pro')
  })

  it('shows the reason when the catalog search fails, not just an empty list', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: { model: 'x-y', catalog: 'absent', source: 'builtin', context_window: 200_000 },
    })
    vi.mocked(getModelCatalog).mockRejectedValue(new Error('catalog request failed'))

    const wrapper = mountForm({ model: 'x-y' })
    await flushPromises()

    await wrapper.find('[data-testid=model-input]').setValue('x-yz')
    await new Promise((r) => setTimeout(r, 250))
    await flushPromises()

    expect(wrapper.find('[data-testid=model-picker-error]').text()).toContain('catalog request failed')
  })
})
