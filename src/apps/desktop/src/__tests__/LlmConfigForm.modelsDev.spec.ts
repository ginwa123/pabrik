/** The v2 profile form's OWN contract: the fact line and the model picker. The existing
 * LlmConfigForm specs cover what the form EMITS. These cover what it TELLS YOU — which is the whole
 * point of the redesign, and the part that would otherwise be untested decoration. */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import { resolveModelOutcome, getModelCatalog } from '../api'
import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

vi.mock('../api', () => ({
  resolveModelOutcome: vi.fn(),
  getModelCatalog: vi.fn(),
}))

/**  * Typed explicitly: with `as const`-style inference the nullable fields narrow to the literal
 * `null`, so passing an override that sets one to a NUMBER is a type error (`vue-tsc` catches it;
 * `vitest` alone would not). */
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

/** A catalog fake that pages the way the endpoint does: the page size the form asks for decides
 * how many rows exist to render, so a test can tell a clipped list from a small page. */
function stubCatalogPage(total: number): void {
  vi.mocked(getModelCatalog).mockImplementation(async (_q, _provider, limit) => {
    const page = Math.min(limit ?? total, total)
    return {
      total,
      returned: page,
      catalog: 'fresh',
      fetched_at_ms: 1_760_000_000_000,
      models: Array.from({ length: page }, (_, i) => ({
        provider_id: `provider-${i}`,
        provider_name: `Provider ${i}`,
        model_id: `flash-${i}`,
        model_name: `Flash ${i}`,
        context_window: 1_000_000,
        output_tokens: null,
        reasoning: 'effort',
        temperature: true,
      })),
    }
  })
}

/** Type into the model field and wait out the picker's debounce, the way a user does. */
async function typeModel(wrapper: VueWrapper, text: string): Promise<void> {
  await wrapper.find('[data-testid=model-input]').setValue(text)
  await new Promise((r) => setTimeout(r, 250))
  await flushPromises()
}

const pickerRows = (wrapper: VueWrapper) => wrapper.findAll('[data-testid^=model-option-]')

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

  it('names the failing sync when the catalog is absent because every sync fails', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'muse-spark-1.3-contributor',
        catalog: 'absent',
        source: 'builtin',
        context_window: 200_000,
        reason: 'no catalog yet — the built-in window applies until the first sync',
        // What the backend now sends when the last `POST /api/models/refresh`
        // (or the hourly timer) failed: the parse error that kept the DB empty.
        last_sync_error: 'InvalidPayloadJson',
        last_sync_at_ms: 1_760_000_000_000,
      },
    })

    const wrapper = mountForm({ model: 'muse-spark-1.3-contributor' })
    await flushPromises()

    const line = wrapper.find('[data-testid=model-fact-line]').text()
    // The CAUSE, not just the state: "nothing synced yet" would tell the user to
    // wait, which is exactly the wrong advice when the sync is failing.
    expect(line).toContain('catalog sync failed')
    expect(line).toContain('InvalidPayloadJson')
    expect(line).toContain('200k')
  })

  it('still says "no catalog yet" when the sync has simply not run', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'muse-spark-1.3-contributor',
        catalog: 'absent',
        source: 'builtin',
        context_window: 200_000,
        reason: 'no catalog yet — the built-in window applies until the first sync',
      },
    })

    const wrapper = mountForm({ model: 'muse-spark-1.3-contributor' })
    await flushPromises()

    expect(wrapper.find('[data-testid=model-fact-line]').text()).toContain('no catalog yet')
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
      value: {
        model: 'deepseek-flash',
        catalog: 'fresh',
        source: 'catalog',
        context_window: 1_000_000,
      },
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

    expect(wrapper.find('[data-testid=model-picker-error]').text()).toContain(
      'catalog request failed',
    )
  })

  it('offers a whole page of matches, so a broad query stays browsable', async () => {
    stubCatalogPage(1130)
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'flash')

    expect(pickerRows(wrapper).length).toBeGreaterThan(20)
  })

  it('scrolls the matches past the fold instead of clipping them', async () => {
    // jsdom has no layout engine, so the reachable-rows proxy is the scroll container a
    // browser would honour.
    stubCatalogPage(1130)
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'flash')

    const classes = wrapper.find('[data-testid=model-picker-results]').classes()
    expect(classes).toContain('overflow-y-auto')
    expect(classes.some((c) => c.startsWith('max-h-'))).toBe(true)
  })

  it('counts the page it shows against the matches it found', async () => {
    stubCatalogPage(1130)
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'flash')

    const summary = wrapper.find('[data-testid=model-picker-summary]').text()
    expect(summary).toContain(String(pickerRows(wrapper).length))
    expect(summary).toContain('1130')
  })

  it('states a plain count when every match fits in the page', async () => {
    stubCatalogPage(3)
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'flash')

    expect(wrapper.find('[data-testid=model-picker-summary]').text()).toBe('3 matches')
  })
})

describe('LlmConfigForm — the effort control', () => {
  /** DeepSeek V4.1 Flash: models.dev advertises more levels than pabrik can send. */
  function stubModelWithEffort(): void {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'deepseek-v4.1-flash',
        catalog: 'fresh',
        source: 'catalog',
        context_window: 1_048_576,
        reasoning: 'effort',
        effort_values: ['none', 'low', 'high', 'max'],
        effort_values_sendable: ['low', 'high'],
      },
    })
  }

  async function openAdvanced(model = 'deepseek-v4.1-flash') {
    const wrapper = mountForm({ model })
    await flushPromises()
    await wrapper.find('[data-testid=advanced-toggle]').trigger('click')
    return wrapper
  }

  const offeredLevels = (wrapper: VueWrapper) =>
    wrapper
      .findAll<HTMLOptionElement>('[data-testid=reasoning-effort-select] option')
      .map((o) => o.element.value)
      .filter((v) => v !== '')

  it('offers exactly the levels this model can be sent with', async () => {
    stubModelWithEffort()
    const wrapper = await openAdvanced()

    expect(offeredLevels(wrapper)).toEqual(['low', 'high'])
  })

  it('names the levels it offers, so the label cannot promise one the dropdown cannot set', async () => {
    stubModelWithEffort()
    const wrapper = await openAdvanced()

    const select = wrapper.find('[data-testid=reasoning-effort-select]')
    const label = select.element.parentElement?.querySelector('label')?.textContent ?? ''
    const named = (label.match(/this model: (.+)\)/)?.[1] ?? '')
      .split('·')
      .map((s) => s.trim())
      .filter((s) => s !== '')

    expect(named.length).toBeGreaterThan(0)
    for (const level of named) expect(offeredLevels(wrapper)).toContain(level)
  })

  it('names the model levels pabrik cannot send instead of dropping them quietly', async () => {
    stubModelWithEffort()
    const wrapper = await openAdvanced()

    const note = wrapper.find('[data-testid=effort-dropped]').text()
    expect(note).toContain('none')
    expect(note).toContain('max')
  })

  it('claims nothing about the model when the catalog has no effort facts', async () => {
    vi.mocked(resolveModelOutcome).mockResolvedValue({
      kind: 'ok',
      value: {
        model: 'self-hosted',
        catalog: 'absent',
        source: 'builtin',
        context_window: 200_000,
      },
    })
    const wrapper = await openAdvanced('self-hosted')

    expect(offeredLevels(wrapper)).toEqual(['low', 'medium', 'high'])
    expect(wrapper.find('[data-testid=effort-dropped]').exists()).toBe(false)
  })
})
