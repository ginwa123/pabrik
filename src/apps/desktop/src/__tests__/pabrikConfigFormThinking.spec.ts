// Vitest tests for the model-thinking fields in LlmConfigForm.vue
// (plan 2026-08-23-model-thinking + 2026-09-01-migrate-openai-legacy-to-response).
//
// Covers:
//  - The new fields are wired into the form data interface.
//  - When `thinking === 'off'`, the budget + effort row is hidden (all styles).
//  - Per-style gating: anthropic shows budget hides effort, openai/openai-response show effort hides budget.
//  - The input emits `null` for blank values, parsed integers for
//    valid input, and clamps to >= 1024.
//  - Hidden fields preserve values (not nulled) on style switch.

import { describe, it, expect } from 'vitest'
import { mount, VueWrapper } from '@vue/test-utils'
import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

/**  * Mount and open `Advanced`. Advanced is collapsed by default — that is the whole point of the
 * redesign — so a spec that wants to touch a field behind it has to open it first. The helper is
 * tolerant so it can be used for components that have no Advanced section at all. */
async function mountOpen(component: unknown, opts?: unknown) {
  // `as never` keeps `mount`'s overload resolution from narrowing the SECOND
  // argument to a VNode-props shape at every call site.
  const w = mount(component as never, opts as never) as VueWrapper
  const toggle = w.find('[data-testid=advanced-toggle]')
  if (toggle.exists()) await toggle.trigger('click')
  return w
}



const baseConfig = {
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
  thinking_budget_tokens: null,
  reasoning_effort: null,
}

describe('LlmConfigForm Thinking fields', () => {
  it('hides budget + effort fields when thinking=off', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, thinking: 'off' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  // ─── Per-style gating (plan 2026-09-01) ───

  it('anthropic + thinking=on: shows budget, hides effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic', thinking: 'on' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('anthropic + thinking=auto: shows budget, hides effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic', thinking: 'auto' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('anthropic + thinking=off: hides both', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic', thinking: 'off' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('openai + thinking=on: hides budget, shows effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai', thinking: 'on' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('openai + thinking=auto: hides budget, shows effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai', thinking: 'auto' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('openai + thinking=off: hides both', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai', thinking: 'off' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('openai-response + thinking=on: hides budget, shows effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai-response', thinking: 'on' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('openai-response + thinking=auto: hides budget, shows effort', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai-response', thinking: 'auto' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
  })

  it('openai-response + thinking=off: hides both', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai-response', thinking: 'off' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('preserves hidden field values on style switch (does not null)', async () => {
    // Start anthropic with a budget value, switch to openai — budget should be hidden but not nulled.
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic', thinking: 'on', thinking_budget_tokens: 4096, reasoning_effort: 'high' } },
    })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    // Switch to openai — budget hidden, effort visible. No emission should null the hidden budget.
    await wrapper.setProps({ modelValue: { ...baseConfig, url_style: 'openai', thinking: 'on', thinking_budget_tokens: 4096, reasoning_effort: 'high' } })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
    // The component should not have emitted an update that nulled thinking_budget_tokens.
    const emitted = wrapper.emitted('update:modelValue') ?? []
    for (const [payload] of emitted as Array<[Record<string, unknown>]>) {
      expect(payload.thinking_budget_tokens).not.toBeNull()
    }
    // Switch back to anthropic — budget visible again with same value.
    await wrapper.setProps({ modelValue: { ...baseConfig, url_style: 'anthropic', thinking: 'on', thinking_budget_tokens: 4096, reasoning_effort: 'high' } })
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect((wrapper.find('[data-testid=thinking-budget-input]').element as HTMLInputElement).value).toBe('4096')
  })

  it('emits null when thinking_budget_tokens input is cleared (anthropic)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic', thinking_budget_tokens: 4096 } },
    })
    const input = wrapper.find('[data-testid=thinking-budget-input]')
    await input.setValue('')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    expect(emitted?.thinking_budget_tokens).toBeNull()
  })

  it('emits clamped integer when thinking_budget_tokens input is below 1024 (anthropic)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'anthropic' } },
    })
    const input = wrapper.find('[data-testid=thinking-budget-input]')
    await input.setValue('500')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    // Floor is 1024 — anything below clamps to 1024.
    expect(emitted?.thinking_budget_tokens).toBe(1024)
  })

  it('emits null when reasoning_effort select is set to Auto (empty)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseConfig, url_style: 'openai', reasoning_effort: 'high' } },
    })
    const select = wrapper.find('[data-testid=reasoning-effort-select]')
    await select.setValue('')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
    expect(emitted?.reasoning_effort).toBeNull()
  })

  it('emits low/medium/high when reasoning_effort is changed', async () => {
    for (const v of ['low', 'medium', 'high'] as const) {
      const wrapper = await mountOpen(LlmConfigForm, {
        props: { modelValue: { ...baseConfig, url_style: 'openai', reasoning_effort: null } },
      })
      const select = wrapper.find('[data-testid=reasoning-effort-select]')
      await select.setValue(v)
      const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as Record<string, unknown> | undefined
      expect(emitted?.reasoning_effort).toBe(v)
    }
  })
})
