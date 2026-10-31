/** The OpenCode transport's own picker contract: the list comes from the CLI, and it arrives
 * free-first. The models.dev spec covers the HTTP profile; these cover what changes when the agent
 * runs the local CLI. */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import { resolveModelOutcome, getModelCatalog } from '../api'
import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

vi.mock('../api', () => ({
  resolveModelOutcome: vi.fn(),
  getModelCatalog: vi.fn(),
}))

const catalogMock = vi.mocked(getModelCatalog)
const resolveMock = vi.mocked(resolveModelOutcome)

interface FormValue {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  backend?: string
  max_capacity_tokens: number | null
  compaction_threshold_percent: number | null
  thinking_budget_tokens: number | null
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}

const baseValue: FormValue = {
  model: 'opencode/beam-free',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  backend: 'opencode',
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
  thinking_budget_tokens: null,
  reasoning_effort: null,
}

function mountForm(overrides: Partial<FormValue> = {}) {
  return mount(LlmConfigForm, { props: { modelValue: { ...baseValue, ...overrides } } })
}

async function typeModel(wrapper: VueWrapper, text: string): Promise<void> {
  await wrapper.find('[data-testid=model-input]').setValue(text)
  await new Promise((r) => setTimeout(r, 250))
  await flushPromises()
}

function stubCliCatalog(): void {
  catalogMock.mockResolvedValue({
    total: 3,
    returned: 3,
    catalog: 'fresh',
    source: 'opencode-cli',
    models: [
      {
        provider_id: 'opencode',
        provider_name: 'opencode',
        model_id: 'opencode/beam-free',
        model_name: 'Beam Free',
        context_window: 1_048_576,
        output_tokens: null,
        reasoning: 'effort',
        temperature: true,
        free: true,
      },
      {
        provider_id: 'opencode-go',
        provider_name: 'opencode-go',
        model_id: 'opencode-go/iceman-contributor-free',
        model_name: 'Iceman Contributor Free',
        context_window: 1_000_000,
        output_tokens: null,
        reasoning: 'effort',
        temperature: true,
        free: true,
      },
      {
        provider_id: 'opencode-go',
        provider_name: 'opencode-go',
        model_id: 'opencode-go/kimi-k3',
        model_name: 'Kimi K3',
        context_window: 1_000_000,
        output_tokens: null,
        reasoning: 'effort',
        temperature: true,
        free: false,
      },
    ],
  })
}

beforeEach(() => {
  catalogMock.mockReset()
  catalogMock.mockResolvedValue({
    total: 0,
    returned: 0,
    catalog: 'fresh',
    models: [],
  })
  resolveMock.mockReset()
  resolveMock.mockResolvedValue({
    kind: 'ok',
    value: { model: 'opencode/beam-free', catalog: 'fresh', source: 'catalog', context_window: 1_048_576 },
  })
})

describe('LlmConfigForm — the opencode picker source', () => {
  it('asks the CLI for its own model list when the transport is opencode', async () => {
    stubCliCatalog()
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'opencode')

    const lastCall = catalogMock.mock.calls.at(-1)
    expect(lastCall?.[3]).toBe('opencode')
  })

  it('leaves the HTTP picker on the models.dev catalog', async () => {
    const wrapper = mountForm({ backend: 'http' })
    await flushPromises()
    await typeModel(wrapper, 'flash')

    const lastCall = catalogMock.mock.calls.at(-1)
    expect(lastCall?.[3]).toBeUndefined()
  })

  it('picks up the CLI source after the transport is switched to opencode', async () => {
    stubCliCatalog()
    const wrapper = mountForm({ backend: 'http' })
    await flushPromises()

    await wrapper.find('[data-testid=backend-select]').setValue('opencode')
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as FormValue
    expect(emitted.backend).toBe('opencode')

    await wrapper.setProps({ modelValue: { ...emitted } })
    await typeModel(wrapper, 'free')

    const lastCall = catalogMock.mock.calls.at(-1)
    expect(lastCall?.[3]).toBe('opencode')
    expect(wrapper.find('[data-testid=model-picker-summary]').text()).toContain('free first')
  })

  it('says the list is free-first and marks each free row', async () => {
    stubCliCatalog()
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'free')

    expect(wrapper.find('[data-testid=model-picker-summary]').text()).toContain('free first')
    expect(wrapper.find('[data-testid="model-free-opencode/beam-free"]').exists()).toBe(true)
    expect(
      wrapper.find('[data-testid="model-free-opencode-go/iceman-contributor-free"]').exists(),
    ).toBe(true)
    expect(wrapper.find('[data-testid="model-free-opencode-go/kimi-k3"]').exists()).toBe(false)
  })

  it('puts the full provider/model in the field, which is what the CLI takes', async () => {
    stubCliCatalog()
    const wrapper = mountForm({ model: '' })
    await flushPromises()
    await typeModel(wrapper, 'beam')

    await wrapper.find('[data-testid="model-option-opencode/beam-free"]').trigger('mousedown')
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as FormValue
    expect(emitted.model).toBe('opencode/beam-free')
    expect(emitted.base_url).toBe('')
  })

  it('reports why the CLI list is missing and falls back instead of going blank', async () => {
    catalogMock.mockResolvedValue({
      total: 1,
      returned: 1,
      catalog: 'fresh',
      source: 'models.dev',
      cli_error: 'FileNotFound',
      models: [
        {
          provider_id: 'opencode',
          provider_name: 'opencode',
          model_id: 'beam-free',
          model_name: 'Beam Free',
          context_window: 1_048_576,
          output_tokens: null,
          reasoning: 'effort',
          temperature: true,
          free: true,
        },
      ],
    })
    const wrapper = mountForm()
    await flushPromises()
    await typeModel(wrapper, 'beam')

    const note = wrapper.find('[data-testid=model-picker-cli-error]').text()
    expect(note).toContain('FileNotFound')
    expect(note).toContain('models.dev')
    expect(wrapper.findAll('[data-testid^=model-option-]').length).toBe(1)
  })
})
