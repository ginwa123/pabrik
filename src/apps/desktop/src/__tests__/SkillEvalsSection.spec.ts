import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import SkillEvalsSection from '../components/pabrik/SkillEvalsSection.vue'

/**  * `skill_evals.enabled` is the ONLY real control for `run_skill_eval` — the per-agent tool checkbox
 * cannot turn it on (the exec path re-reads this flag and returns `{"status":"disabled"}`). So this
 * section is the user-facing switch, and these tests pin the states it can show. */
function mountSection(enabled: boolean, loaded = true) {
  return mount(SkillEvalsSection, {
    props: { modelValue: { enabled }, loaded },
  })
}

describe('SkillEvalsSection', () => {
  it('renders the checkbox reflecting the backend value', () => {
    const on = mountSection(true).find('[data-testid="skill-evals-toggle"]')
    expect((on.element as HTMLInputElement).checked).toBe(true)

    const off = mountSection(false).find('[data-testid="skill-evals-toggle"]')
    expect((off.element as HTMLInputElement).checked).toBe(false)
  })

  it('explains that the tool is added only when enabled', () => {
    // The distinction matters: with the switch off the tool is never
    // offered, which is different from "offered but refused".
    expect(mountSection(true).text()).toContain('run_skill_eval')
    expect(mountSection(true).text()).toContain('spends tokens')

    const offText = mountSection(false).text()
    expect(offText).toContain('not offered')
    expect(offText).toContain('run_skill_eval')
  })

  it('emits the new value when the user flips the switch', async () => {
    const wrapper = mountSection(false)
    await wrapper.find('[data-testid="skill-evals-toggle"]').setValue(true)
    // defineModel surfaces the whole settings object, not the bare bool.
    expect(wrapper.emitted('update:modelValue')?.at(-1)).toEqual([{ enabled: true }])
  })

  it('warns when the current setting could not be read', () => {
    // A failed GET means the checkbox is a guess, not server state —
    // saying so beats silently rendering "off".
    const wrapper = mountSection(false, false)
    expect(wrapper.find('[data-testid="skill-evals-unloaded"]').exists()).toBe(true)
  })

  it('shows no warning once the config has loaded', () => {
    const wrapper = mountSection(false, true)
    expect(wrapper.find('[data-testid="skill-evals-unloaded"]').exists()).toBe(false)
  })

  it('is reachable by label text for assistive tech', () => {
    // The checkbox has no <label for>; the accessible name comes from the
    // wrapping label element, so the text must be inside it.
    const wrapper = mountSection(false)
    const label = wrapper.find('[data-testid="skill-evals-toggle-label"]')
    expect(label.text()).toContain('Enable skill evals')
  })
})
