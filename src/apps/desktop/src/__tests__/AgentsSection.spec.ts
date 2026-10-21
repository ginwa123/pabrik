import { mount, VueWrapper } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import AgentsSection from '../components/pabrik/AgentsSection.vue'
import type { AgentRow } from '../components/pabrik/AgentsSection.vue'

const baseAgent: AgentRow = {
  name: 'work',
  model: 'm',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: '',
}

async function mountOpen(component: unknown, opts?: unknown) {
  const w = mount(component as never, opts as never) as VueWrapper
  return w
}

describe('AgentsSection', () => {
  it('shows the active agent in the header pill', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: 'work' },
    })
    expect(wrapper.find('[data-testid="active-pill"]').text()).toContain('work')
  })

  it('shows the empty state when no agents exist', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [], activeAgent: null },
    })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('lists each agent by name', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent, { ...baseAgent, name: 'home' }], activeAgent: null },
    })
    const rows = wrapper.findAll('[data-testid="agent-list"] > li')
    expect(rows.length).toBe(2)
    expect(rows[0]!.text()).toContain('work')
    expect(rows[1]!.text()).toContain('home')
  })

  it('emits setActive when "Set active" is clicked on a non-active row', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent, { ...baseAgent, name: 'home' }], activeAgent: 'work' },
    })
    const buttons = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(buttons.length).toBe(1)
    await buttons[0]!.trigger('click')
    expect(wrapper.emitted('setActive')?.[0]).toEqual(['home'])
  })

  it('emits edit when Edit is clicked', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: null },
    })
    await wrapper.find('[data-testid="edit-btn"]').trigger('click')
    expect(wrapper.emitted('edit')?.[0]).toEqual([baseAgent])
  })

  it('emits delete when Delete is clicked', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: null },
    })
    await wrapper.find('[data-testid="delete-btn"]').trigger('click')
    expect(wrapper.emitted('delete')?.[0]).toEqual(['work'])
  })

  it('emits add when the + Add agent button is clicked', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [], activeAgent: null },
    })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })

  it('shows the agent system prompt when the row is expanded', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: {
        modelValue: [{ ...baseAgent, system_prompt: 'you are the reviewer' }],
        activeAgent: null,
      },
    })
    const details = wrapper.find('[data-testid="agent-details-work"]')
    expect(details.exists()).toBe(true)
    expect(details.text()).toContain('you are the reviewer')
  })

  it('says the agent has no system prompt when the field is empty', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: null },
    })
    const details = wrapper.find('[data-testid="agent-details-work"]')
    expect(details.text()).toContain('No system prompt')
  })

  it('expands every agent by default', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent, { ...baseAgent, name: 'home' }], activeAgent: null },
    })
    expect(wrapper.find('[data-testid="expand-btn-work"]').attributes('aria-expanded')).toBe('true')
    expect(wrapper.find('[data-testid="expand-btn-home"]').attributes('aria-expanded')).toBe('true')
  })

  it('collapses and re-expands one agent without changing the others', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent, { ...baseAgent, name: 'home' }], activeAgent: null },
    })
    const workToggle = wrapper.find('[data-testid="expand-btn-work"]')

    await workToggle.trigger('click')
    expect(wrapper.find('[data-testid="agent-details-work"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="agent-details-home"]').exists()).toBe(true)

    await workToggle.trigger('click')
    expect(wrapper.find('[data-testid="agent-details-work"]').exists()).toBe(true)
  })

  it('shows a Reset button next to the active pill when an active agent is set', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: 'work' },
    })
    const resetBtn = wrapper.find('[data-testid="reset-active-btn"]')
    expect(resetBtn.exists()).toBe(true)
    expect(resetBtn.text().toLowerCase()).toContain('reset')
  })

  it('does NOT show a Reset button when no active agent is set', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: null },
    })
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(false)
  })

  it('emits clearActive when the Reset button is clicked', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: { modelValue: [baseAgent], activeAgent: 'work' },
    })
    await wrapper.find('[data-testid="reset-active-btn"]').trigger('click')
    expect(wrapper.emitted('clearActive')).toBeTruthy()
  })

  it('keeps the Set active button hidden on the active row even when Reset is visible', async () => {
    const wrapper = await mountOpen(AgentsSection, {
      props: {
        modelValue: [baseAgent, { ...baseAgent, name: 'home' }],
        activeAgent: 'work',
      },
    })
    const setActiveBtns = wrapper.findAll('[data-testid="set-active-btn"]')
    expect(setActiveBtns.length).toBe(1)
    expect(wrapper.find('[data-testid="reset-active-btn"]').exists()).toBe(true)
  })
})
