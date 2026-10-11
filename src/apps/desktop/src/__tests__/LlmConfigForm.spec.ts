import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

const baseValue = {
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  // Plan 2026-07-07-compaction-inline: per-profile compaction overrides.
  max_capacity_tokens: null as number | null,
  compaction_threshold_percent: null as number | null,
  // Plan 2026-08-23-model-thinking: model-thinking knobs.
  thinking_budget_tokens: null as number | null,
  reasoning_effort: null as 'low' | 'medium' | 'high' | 'auto' | null,
}

describe('LlmConfigForm', () => {
  it('renders all fields (openai: 3 selects + freetext temperature + reasoning_effort)', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('input[placeholder="MiniMax-M2.7"]').exists()).toBe(true)
    expect(wrapper.find('input[placeholder="https://api.minimax.io/v1"]').exists()).toBe(true)
    const selects = wrapper.findAll('select')
    // thinking, url_style, reasoning_effort — 3 selects.
    // (temperature is freetext input, not a select.)
    // (plan 2026-08-23-model-thinking added reasoning_effort; plan 2026-09-01 gates it per style.)
    expect(selects.length).toBe(3)
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
  })

  it('renders 2 selects for anthropic (budget input, no reasoning_effort, freetext temperature)', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, url_style: 'anthropic' } },
    })
    expect(wrapper.findAll('select').length).toBe(2) // thinking, url_style
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('renders 3 selects for openai-response (reasoning_effort, no budget, freetext temperature)', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, url_style: 'openai-response' } },
    })
    expect(wrapper.findAll('select').length).toBe(3)
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
  })

  it('hides both budget and effort when thinking=off regardless of style', () => {
    for (const style of ['openai', 'openai-response', 'anthropic'] as const) {
      const wrapper = mount(LlmConfigForm, {
        props: { modelValue: { ...baseValue, url_style: style, thinking: 'off' } },
      })
      expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
      expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
    }
  })

  it('hides the API key by default (type=password)', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, api_key: 'sk-secret' } },
    })
    const keyInput = wrapper.find('[data-testid="api-key-input"]')
    expect(keyInput.attributes('type')).toBe('password')
  })

  it('toggles the API key to type=text when the show button is clicked', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, api_key: 'sk-secret' } },
    })
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('text')
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('password')
  })

  it('emits update:modelValue when the model field changes', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const modelInput = wrapper.find('input[placeholder="MiniMax-M2.7"]')
    await modelInput.setValue('gpt-4o')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{ ...baseValue, model: 'gpt-4o' }])
  })

  it('shows a validation error under the model field when errors.model is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue }, errors: { model: 'Model is required' } },
    })
    expect(wrapper.text()).toContain('Model is required')
  })

  // ─── Plan 2026-07-07-compaction-inline: Compaction overrides ───

  it('renders the capacity-override checkbox unchecked when null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const checkbox = wrapper.find('[data-testid="profile-capacity-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the capacity input when override is null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(true)
  })

  it('enables the capacity input when override is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 400000 } },
    })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(false)
    expect((input.element as HTMLInputElement).value).toBe('400000')
  })

  it('toggling the profile capacity checkbox on emits a seed value', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-capacity-override-checkbox"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.max_capacity_tokens).toBe(500000)
  })

  it('toggling the profile capacity checkbox off emits null', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 350000 } },
    })
    await wrapper.find('[data-testid="profile-capacity-override-checkbox"]').setValue(false)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.max_capacity_tokens).toBeNull()
  })

  it('renders the threshold-override checkbox unchecked when null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const checkbox = wrapper.find('[data-testid="profile-threshold-override-checkbox"]')
    expect((checkbox.element as HTMLInputElement).checked).toBe(false)
  })

  it('disables the threshold slider when override is null', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const slider = wrapper.find('[data-testid="profile-threshold-slider"]')
    expect((slider.element as HTMLInputElement).disabled).toBe(true)
  })

  it('renders threshold slider value when override is set', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, compaction_threshold_percent: 60 } },
    })
    const slider = wrapper.find('[data-testid="profile-threshold-slider"]')
    expect((slider.element as HTMLInputElement).value).toBe('60')
    expect((slider.element as HTMLInputElement).disabled).toBe(false)
  })

  it('toggling the profile threshold checkbox on emits 80', async () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-threshold-override-checkbox"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(80)
  })

  it('profile threshold slider clamps to 0-100 range', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, compaction_threshold_percent: 50 } },
    })
    await wrapper.find('[data-testid="profile-threshold-slider"]').setValue('120')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(100) // clamped
  })

  // ─── Temperature freetext (auto or 0–1) ───

  it('temperature offers auto/0/0.5/1 presets via datalist', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="temperature-input"]')
    expect(input.exists()).toBe(true)
    expect(input.attributes('list')).toBe('llm-temperature-presets')
    const options = wrapper
      .findAll('#llm-temperature-presets option')
      .map((o) => (o.element as HTMLOptionElement).value)
    expect(options).toEqual(['auto', '0', '0.5', '1'])
  })

  it('temperature emits arbitrary values inside 0–1', async () => {
    for (const v of ['0.7', '0.33', '0', '1']) {
      const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
      await wrapper.find('[data-testid="temperature-input"]').setValue(v)
      const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue | undefined
      expect(emitted?.temperature).toBe(v)
    }
  })

  it('temperature normalizes AUTO to auto', async () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, temperature: '0.5' } },
    })
    await wrapper.find('[data-testid="temperature-input"]').setValue('AUTO')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue | undefined
    expect(emitted?.temperature).toBe('auto')
  })

  it('temperature rejects out-of-range and garbage without emitting', async () => {
    for (const v of ['1.5', '-0.1', '2', 'abc', '']) {
      const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
      await wrapper.find('[data-testid="temperature-input"]').setValue(v)
      expect(wrapper.emitted('update:modelValue')).toBeUndefined()
      expect(wrapper.text()).toContain('Use auto or a number 0–1.')
    }
  })

  // Task task_1788535488395_0 (WebView2 white select): every select/input
  // must carry an inline color-scheme:dark hint so WebView2 renders native
  // controls dark even though it defaults to a light color-scheme.
  // Global `color-scheme: dark` in style.css is the primary fix.
  it('selects carry color-scheme:dark for WebView2', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const selects = wrapper.findAll('select')
    expect(selects.length).toBeGreaterThan(0)
    for (const s of selects) {
      expect((s.element as HTMLElement).style.colorScheme).toBe('dark')
    }
  })

  it('shows the claude-code hint and hides budget+effort for claude-code style', () => {
    const wrapper = mount(LlmConfigForm, {
      props: { modelValue: { ...baseValue, url_style: 'claude-code' } },
    })
    expect(wrapper.find('[data-testid=claude-code-hint]').exists()).toBe(true)
    expect(wrapper.text()).toContain('claude login')
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('hides the claude-code hint for HTTP styles', () => {
    for (const style of ['openai', 'openai-response', 'anthropic'] as const) {
      const wrapper = mount(LlmConfigForm, {
        props: { modelValue: { ...baseValue, url_style: style } },
      })
      expect(wrapper.find('[data-testid=claude-code-hint]').exists()).toBe(false)
    }
  })

  it('offers claude-code in the url-style select', () => {
    const wrapper = mount(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const options = wrapper
      .find('[data-testid=url-style-select]')
      .findAll('option')
      .map((o) => (o.element as HTMLOptionElement).value)
    expect(options).toContain('claude-code')
  })
})
