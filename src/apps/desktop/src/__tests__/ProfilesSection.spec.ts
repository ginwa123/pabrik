import { mount, VueWrapper } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ProfilesSection from '../components/pabrik/ProfilesSection.vue'
import type { ProfileRow } from '../components/pabrik/ProfilesSection.vue'
import type { SubAgent } from '../api'

/** Mount and open `Advanced`.
 * Advanced is collapsed by default — that is the whole point of the redesign —
 * so a spec that wants to touch a field behind it has to open it first. The
 * helper is tolerant so it can be used for components that have no Advanced
 * section at all. */
async function mountOpen(component: unknown, opts?: unknown) {
  // `as never` keeps `mount`'s overload resolution from narrowing the SECOND
  // argument to a VNode-props shape at every call site.
  const w = mount(component as never, opts as never) as VueWrapper
  const toggle = w.find('[data-testid=advanced-toggle]')
  if (toggle.exists()) await toggle.trigger('click')
  return w
}



const baseProfile: ProfileRow = {
  name: 'work',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  sub_agents: [],
}

const baseSubAgent: SubAgent = {
  name: 'coder',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: 'You are a senior backend engineer.',
}

describe('ProfilesSection', () => {
  // ─── Basic rendering ────────────────────────────────────────────────
  it('shows the active profile in the header pill', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    expect(wrapper.find('[data-testid="active-pill"]').text()).toContain('work')
  })

  it('shows the empty state when no profiles exist', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  // ─── Profile row events ────────────────────────────────────────────
  it('emits setActive when "Set active" is clicked on a non-active row', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile }, { ...baseProfile, name: 'home' }], activeProfile: 'work' },
    })
    const buttons = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(buttons.length).toBe(1)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('setActive')?.[0]).toEqual(['home'])
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseProfile])
  })

  it('emits delete when Delete is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['work'])
  })

  it('emits add when the + Add profile button is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [], activeProfile: null },
    })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })

  // ─── Sub-agent meta line ──────────────────────────────────────────
  it('shows "no sub-agents" (no inheritance) when the profile has none', async () => {
    // Plan 2026-09-04-subagents-per-profile: no global list, no
    // inheritance — the meta line is a plain count summary.
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    expect(wrapper.text()).toContain('no sub-agents')
    expect(wrapper.text()).not.toContain('inherits')
    expect(wrapper.text()).not.toContain('top-level')
  })

  it('shows the plain sub-agent count (no "overrides" copy) when the profile has sub-agents', async () => {
    // Plan 2026-09-04-subagents-per-profile: count-only summary.
    const wrapper = await mountOpen(ProfilesSection, {
      props: {
        modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent, { ...baseSubAgent, name: 'reviewer' }] }],
        activeProfile: null,
      },
    })
    expect(wrapper.text()).toContain('2 sub-agents')
    expect(wrapper.text()).not.toContain('overrides')
    expect(wrapper.text()).not.toContain('top-level')
  })

  it('uses singular "sub-agent" when there is exactly one', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: {
        modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }],
        activeProfile: null,
      },
    })
    expect(wrapper.text()).toContain('1 sub-agent')
    expect(wrapper.text()).not.toContain('1 sub-agents')
  })

  // ─── Expand / collapse ────────────────────────────────────────────
  it('expands every profile and sub-agent profile by default', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: {
        modelValue: [
          { ...baseProfile, sub_agents: [baseSubAgent] },
          { ...baseProfile, name: 'home' },
        ],
        activeProfile: null,
      },
    })

    expect(wrapper.find('[data-testid="expand-btn-work"]').attributes('aria-expanded')).toBe('true')
    expect(wrapper.find('[data-testid="expand-btn-home"]').attributes('aria-expanded')).toBe('true')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="expand-sub-agent-btn-work-coder"]').attributes('aria-expanded')).toBe('true')
    expect(wrapper.find('[data-testid="sub-agent-details-work-coder"]').exists()).toBe(true)
  })

  it('collapses and re-expands one profile without changing the others', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: {
        modelValue: [
          { ...baseProfile, sub_agents: [baseSubAgent] },
          { ...baseProfile, name: 'home' },
        ],
        activeProfile: null,
      },
    })
    const workToggle = wrapper.find('[data-testid="expand-btn-work"]')

    await workToggle.trigger('click')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="sub-agents-list-home"]').exists()).toBe(true)

    await workToggle.trigger('click')
    expect(wrapper.find('[data-testid="sub-agents-list-work"]').exists()).toBe(true)
  })

  it('collapses and re-expands an individual sub-agent profile', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    const toggle = wrapper.find('[data-testid="expand-sub-agent-btn-work-coder"]')

    await toggle.trigger('click')
    expect(wrapper.find('[data-testid="sub-agent-details-work-coder"]').exists()).toBe(false)
    expect(toggle.attributes('aria-expanded')).toBe('false')

    await toggle.trigger('click')
    expect(wrapper.find('[data-testid="sub-agent-details-work-coder"]').exists()).toBe(true)
    expect(toggle.attributes('aria-expanded')).toBe('true')
  })

  it('shows a "no sub-agents" hint by default when the profile has none', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    const list = wrapper.find('[data-testid="sub-agents-list-work"]')
    expect(list.exists()).toBe(true)
    expect(list.text()).toContain('No sub-agents')
  })

  // ─── Sub-agent row events ─────────────────────────────────────────
  it('emits addSubAgent with the profile name when the + Add sub-agent button is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    await wrapper.find('[data-testid="add-sub-agent-btn-work"]').trigger('click')
    expect(wrapper.emitted('addSubAgent')?.[0]).toEqual(['work'])
  })

  it('emits editSubAgent with profile name + sub-agent when Edit is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    await wrapper.find('[data-testid="edit-sub-agent-btn-work-coder"]').trigger('click')
    expect(wrapper.emitted('editSubAgent')?.[0]).toEqual(['work', baseSubAgent])
  })

  it('emits deleteSubAgent with profile name + sub-agent name when ⌫ is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [{ ...baseProfile, sub_agents: [baseSubAgent] }], activeProfile: null },
    })
    await wrapper.find('[data-testid="delete-sub-agent-btn-work-coder"]').trigger('click')
    expect(wrapper.emitted('deleteSubAgent')?.[0]).toEqual(['work', 'coder'])
  })

  // ─── Clear active profile ───────────────────────────────────────────
  // Plan 2026-08-06-reset-active-profile: when a profile is marked
  // active, the header shows a "Reset" button next to the pill. Clicking
  // it emits `clearActive` so the parent (PabrikConfigEditor) can save
  // `active_profile: null` to config.json. After the save, the cascade
  // in `workflow.zig::resolveProfileField` falls through to the top-level
  // config and every chat session / task uses the bare defaults.
  it('shows a Reset button next to the active pill when an active profile is set', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    const resetBtn = wrapper.find('[data-testid="reset-active-btn"]')
    expect(resetBtn.exists()).toBe(true)
    expect(resetBtn.text().toLowerCase()).toContain('reset')
  })

  it('does NOT show a Reset button when no active profile is set', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: null },
    })
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(false)
  })

  it('emits clearActive when the Reset button is clicked', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: { modelValue: [baseProfile], activeProfile: 'work' },
    })
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    expect(wrapper.emitted('clearActive')).toBeTruthy()
  })

  it('keeps the Set active button hidden on the active row even when Reset is visible', async () => {
    const wrapper = await mountOpen(ProfilesSection, {
      props: {
        modelValue: [baseProfile, { ...baseProfile, name: 'home' }],
        activeProfile: 'work',
      },
    })
    // The 'work' row is active → no Set active button on it
    const setActiveBtns = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(setActiveBtns.length).toBe(1) // only 'home' has one
    // Reset is visible in the header
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(true)
  })
})
