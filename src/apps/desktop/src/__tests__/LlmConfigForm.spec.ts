import { mount, VueWrapper } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import LlmConfigForm from '../components/pabrik/LlmConfigForm.vue'

/**
 * Mount and open `Advanced`.
 *
 * Advanced is collapsed by default — that is the whole point of the redesign —
 * so a spec that wants to touch a field behind it has to open it first. The
 * helper is tolerant so it can be used for components that have no Advanced
 * section at all.
 */
async function mountOpen(component: unknown, opts?: unknown) {
  // `as never` keeps `mount`'s overload resolution from narrowing the SECOND
  // argument to a VNode-props shape at every call site.
  const w = mount(component as never, opts as never) as VueWrapper
  const toggle = w.find('[data-testid=advanced-toggle]')
  if (toggle.exists()) await toggle.trigger('click')
  return w
}



const baseValue = {
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  // Transport discriminator + its CLI knobs. Absent `backend` reads as
  // "http" (the backend's documented default), so these are optional in the
  // form's type — but the specs set them so intent is explicit.
  backend: 'http',
  config_dir: null as string | null,
  max_turns: null as number | null,
  opencode_agent: null as string | null,
  opencode_auto: null as boolean | null,
  // Plan 2026-07-07-compaction-inline: per-profile compaction overrides.
  max_capacity_tokens: null as number | null,
  compaction_threshold_percent: null as number | null,
  // Plan 2026-08-23-model-thinking: model-thinking knobs.
  thinking_budget_tokens: null as number | null,
  reasoning_effort: null as 'low' | 'medium' | 'high' | 'auto' | null,
}

describe('LlmConfigForm', () => {
  it('renders all fields (openai: backend + 3 selects + freetext temperature)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('[data-testid=model-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=base-url-input]').exists()).toBe(true)
    const selects = wrapper.findAll('select')
    // backend, thinking, url_style, reasoning_effort — 4 selects. (temperature is freetext input,
    // not a select.) (plan 2026-08-23-model-thinking added reasoning_effort; plan 2026-09-01 gates
    // it per style; the `backend` discriminator added the transport select.)
    expect(selects.length).toBe(4)
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
  })

  it('renders 3 selects for anthropic (budget input, no reasoning_effort)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, url_style: 'anthropic' } },
    })
    expect(wrapper.findAll('select').length).toBe(3) // backend, thinking, url_style
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
  })

  it('renders 4 selects for openai-response (reasoning_effort, no budget)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, url_style: 'openai-response' } },
    })
    expect(wrapper.findAll('select').length).toBe(4)
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
  })

  it('hides both budget and effort when thinking=off regardless of style', async () => {
    for (const style of ['openai', 'openai-response', 'anthropic'] as const) {
      const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue, url_style: style, thinking: 'off' } } })
      expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
      expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
    }
  })

  it('hides the API key by default (type=password)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    const keyInput = wrapper.find('[data-testid="api-key-input"]')
    expect(keyInput.attributes('type')).toBe('password')
  })

  it('toggles the API key to type=text when the show button is clicked', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue, api_key: 'sk-secret' } } })
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('text')
    await wrapper.find('[data-testid="api-key-toggle"]').trigger('click')
    expect(wrapper.find('[data-testid="api-key-input"]').attributes('type')).toBe('password')
  })

  it('emits update:modelValue when the model field changes', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const modelInput = wrapper.find('[data-testid=model-input]')
    await modelInput.setValue('gpt-4o')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([{ ...baseValue, model: 'gpt-4o' }])
  })

  it('shows a validation error under the model field when errors.model is set', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue }, errors: { model: 'Model is required' } },
    })
    expect(wrapper.text()).toContain('Model is required')
  })

  // ─── Plan 2026-07-07-compaction-inline: Compaction overrides ───

  

  it('has NO override checkbox — an empty context-window field is the inherit state', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    // The checkbox is gone on purpose: a control whose only job is to enable the
    // field beneath it is noise when "empty" already means "inherit".
    expect(wrapper.find('[data-testid="profile-capacity-override-checkbox"]').exists()).toBe(false)
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).value).toBe('')
    // ENABLED, not disabled — typing is how you override.
    expect((input.element as HTMLInputElement).disabled).toBe(false)
  })

  

  it('states the inherited window as the placeholder, so the default is legible', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).placeholder).toContain('inherit')
  })

  it('enables the capacity input when override is set', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 400000 } },
    })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).disabled).toBe(false)
    expect((input.element as HTMLInputElement).value).toBe('400000')
  })

  

  it('typing a context window emits the number, and clearing it emits null (never "")', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')

    await input.setValue('350000')
    const first = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(first.max_capacity_tokens).toBe(350000)

    // A cleared override must be `null`: an empty slice binds as SQL NULL
    // server-side, and `""` is not a number the cascade can fall through on.
    await input.setValue('')
    const second = wrapper.emitted('update:modelValue')?.[1]?.[0] as typeof baseValue
    expect(second.max_capacity_tokens).toBeNull()
  })

  

  it('an existing context-window override round-trips into the field', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, max_capacity_tokens: 350000 } },
    })
    const input = wrapper.find('[data-testid="profile-capacity-input"]')
    expect((input.element as HTMLInputElement).value).toBe('350000')
  })

  

  it('has NO threshold checkbox, and an empty threshold field means "the global default"', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('[data-testid="profile-threshold-override-checkbox"]').exists()).toBe(false)
    // The slider is gone with it — 97% is not a thing to scrub at.
    expect(wrapper.find('[data-testid="profile-threshold-slider"]').exists()).toBe(false)
    const input = wrapper.find('[data-testid="profile-threshold-input"]')
    expect((input.element as HTMLInputElement).value).toBe('')
    expect((input.element as HTMLInputElement).placeholder).toContain('inherit')
  })

  

  it('typing a threshold emits the percentage, and clearing it emits null', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="profile-threshold-input"]')

    await input.setValue('50')
    const first = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(first.compaction_threshold_percent).toBe(50)

    await input.setValue('')
    const second = wrapper.emitted('update:modelValue')?.[1]?.[0] as typeof baseValue
    expect(second.compaction_threshold_percent).toBeNull()
  })

  

  it('an existing threshold override round-trips into the field', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, compaction_threshold_percent: 60 } },
    })
    expect(
      (wrapper.find('[data-testid="profile-threshold-input"]').element as HTMLInputElement).value,
    ).toBe('60')
  })

  

  it('clamps a threshold outside 0-100', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-threshold-input"]').setValue('150')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(100)
  })

  

  it('clamps a NEGATIVE threshold to 0', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid="profile-threshold-input"]').setValue('-5')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.compaction_threshold_percent).toBe(0)
  })

  // ─── Temperature freetext (auto or 0–1) ───

  it('temperature offers auto/0/0.5/1 presets via datalist', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const input = wrapper.find('[data-testid="temperature-input"]')
    expect(input.exists()).toBe(true)
    expect(input.attributes('list')).toBe('llm-temperature-presets')
    const options = wrapper.findAll('#llm-temperature-presets option').map((o) => (o.element as HTMLOptionElement).value)
    expect(options).toEqual(['auto', '0', '0.5', '1'])
  })

  it('temperature emits arbitrary values inside 0–1', async () => {
    for (const v of ['0.7', '0.33', '0', '1']) {
      const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
      await wrapper.find('[data-testid="temperature-input"]').setValue(v)
      const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue | undefined
      expect(emitted?.temperature).toBe(v)
    }
  })

  it('temperature normalizes AUTO to auto', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue, temperature: '0.5' } } })
    await wrapper.find('[data-testid="temperature-input"]').setValue('AUTO')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue | undefined
    expect(emitted?.temperature).toBe('auto')
  })

  it('temperature rejects out-of-range and garbage without emitting', async () => {
    for (const v of ['1.5', '-0.1', '2', 'abc', '']) {
      const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
      await wrapper.find('[data-testid="temperature-input"]').setValue(v)
      expect(wrapper.emitted('update:modelValue')).toBeUndefined()
      expect(wrapper.text()).toContain('Use auto or a number 0–1.')
    }
  })

  // Task task_1788535488395_0 (WebView2 white select): every select/input must carry an inline
  // color-scheme:dark hint so WebView2 renders native controls dark even though it defaults to a
  // light color-scheme. Global `color-scheme: dark` in style.css is the primary fix.
  it('selects carry color-scheme:dark for WebView2', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const selects = wrapper.findAll('select')
    expect(selects.length).toBeGreaterThan(0)
    for (const s of selects) {
      expect((s.element as HTMLElement).style.colorScheme).toBe('dark')
    }
  })
})

/**
 * The transport discriminator.
 *
 * `backend` is orthogonal to `url_style`: it says WHICH transport runs the
 * call, while `url_style` keeps describing the HTTP body shape. A claude-code
 * profile has no URL, no key and no request body, so those controls are
 * hidden rather than shown-but-ignored.
 */
describe('LlmConfigForm — backend gating', () => {
  it('offers http, claude-code and opencode as backends', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    const options = wrapper
      .find('[data-testid=backend-select]')
      .findAll('option')
      .map((o) => (o.element as HTMLOptionElement).value)
    expect(options).toEqual(['http', 'claude-code', 'opencode'])
  })

  it('hides every HTTP control for claude-code and shows the CLI knobs', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'claude-code', model: 'sonnet' } },
    })
    // No endpoint, no credential, no body shape, no request-body knobs.
    expect(wrapper.find('[data-testid=base-url-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=api-key-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=url-style-select]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=thinking-select]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=temperature-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=reasoning-effort-select]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=thinking-budget-input]').exists()).toBe(false)
    // The CLI's own knobs replace them.
    expect(wrapper.find('[data-testid=claude-config-dir-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=claude-max-turns-input]').exists()).toBe(true)
    expect(wrapper.text()).toContain('CLAUDE_CONFIG_DIR')
  })

  it('keeps the compaction controls for claude-code (the window matters either way)', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'claude-code' } },
    })
    expect(wrapper.find('[data-testid=profile-threshold-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=profile-capacity-input]').exists()).toBe(true)
  })

  it('hides the CLI knobs for http', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    expect(wrapper.find('[data-testid=claude-config-dir-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=claude-max-turns-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=opencode-agent-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=opencode-auto-select]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=backend-select]').exists()).toBe(true)
  })

  it('hides every HTTP control for opencode and shows the OpenCode knobs', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'opencode', model: 'opencode-go/deepseek-flash' } },
    })
    // No endpoint, no credential, no body shape, no request-body knobs.
    expect(wrapper.find('[data-testid=base-url-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=api-key-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=url-style-select]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=thinking-select]').exists()).toBe(false)
    // The OpenCode knobs replace them, and Claude Code's do NOT appear.
    expect(wrapper.find('[data-testid=opencode-agent-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=opencode-auto-select]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=claude-config-dir-input]').exists()).toBe(false)
    expect(wrapper.find('[data-testid=claude-max-turns-input]').exists()).toBe(false)
  })

  it('opencode_agent emits a name and null when cleared', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'opencode' } },
    })
    await wrapper.find('[data-testid=opencode-agent-input]').setValue('build')
    let emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.opencode_agent).toBe('build')

    await wrapper.find('[data-testid=opencode-agent-input]').setValue('')
    emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.opencode_agent).toBeNull()
  })

  it('opencode_auto defaults to on and emits false when switched off', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'opencode' } },
    })
    // Absent = on (the headless default), so the select reads "on".
    expect((wrapper.find('[data-testid=opencode-auto-select]').element as HTMLSelectElement).value).toBe('on')

    await wrapper.find('[data-testid=opencode-auto-select]').setValue('off')
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.opencode_auto).toBe(false)
  })

  it('treats an ABSENT backend as http — the documented default', async () => {
    // A profile written before this field existed must render exactly as it
    // did: every HTTP control present, no CLI knob.
    const { backend: _omitted, ...withoutBackend } = baseValue
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...withoutBackend } } })
    expect(wrapper.find('[data-testid=base-url-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=api-key-input]').exists()).toBe(true)
    expect(wrapper.find('[data-testid=claude-config-dir-input]').exists()).toBe(false)
  })

  it('switching the backend emits backend without touching url_style', async () => {
    const wrapper = await mountOpen(LlmConfigForm, { props: { modelValue: { ...baseValue } } })
    await wrapper.find('[data-testid=backend-select]').setValue('claude-code')
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as typeof baseValue
    expect(emitted.backend).toBe('claude-code')
    expect(emitted.url_style).toBe('openai')
  })

  it('config_dir emits a path and null when cleared', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'claude-code' } },
    })
    await wrapper.find('[data-testid=claude-config-dir-input]').setValue('~/.claude-work')
    let emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.config_dir).toBe('~/.claude-work')

    await wrapper.find('[data-testid=claude-config-dir-input]').setValue('')
    emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.config_dir).toBeNull()
  })

  it('max_turns emits a number and null when cleared', async () => {
    const wrapper = await mountOpen(LlmConfigForm, {
      props: { modelValue: { ...baseValue, backend: 'claude-code' } },
    })
    await wrapper.find('[data-testid=claude-max-turns-input]').setValue('40')
    let emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.max_turns).toBe(40)

    await wrapper.find('[data-testid=claude-max-turns-input]').setValue('')
    emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as typeof baseValue
    expect(emitted.max_turns).toBeNull()
  })
})
