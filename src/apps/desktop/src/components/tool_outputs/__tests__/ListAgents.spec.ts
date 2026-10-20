/** Tests for ListAgents.vue. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ListAgents from '../ListAgents.vue'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
const agent = (opts: {
  name: string
  model?: string
  urlStyle?: string
  thinking?: string
  temperature?: string
  maxCapacity?: string | null
  compactionPct?: string | null
  budget?: string | null
  effort?: string | null
  prompt?: string
}): Record<string, unknown> => {
  const {
    name,
    model = 'm1',
    urlStyle = 'openai',
    thinking = 'off',
    temperature = '0.7',
    maxCapacity = '100000',
    compactionPct = '80',
    budget = null,
    effort = null,
    prompt = 'You are helpful.',
  } = opts
  const row: Record<string, unknown> = {
    name,
    model,
    url_style: urlStyle,
    thinking,
    temperature,
    system_prompt: prompt,
  }
  if (maxCapacity !== null) row.max_capacity_tokens = maxCapacity
  if (compactionPct !== null) row.compaction_threshold_percent = compactionPct
  if (budget !== null) row.thinking_budget_tokens = budget
  if (effort !== null) row.reasoning_effort = effort
  return row
}

const makeEnvelope = (data: unknown): string =>
  JSON.stringify({
    tool: 'list_agents',
    parameters: {},
    success: true,
    data,
    error: null,
    v: 1,
  })

const makePopulated = (): string =>
  makeEnvelope({
    count: 2,
    agents: [
      agent({ name: 'coder', model: 'gpt-5', urlStyle: 'openai-response', thinking: 'high', temperature: '0.2', prompt: 'Coder prompt.' }),
      agent({ name: 'reviewer', model: 'claude-4', urlStyle: 'anthropic', thinking: 'off', temperature: '0.9', budget: '8000', effort: 'medium', prompt: 'Reviewer prompt.' }),
    ],
  })

const makeEmpty = (): string => makeEnvelope({ count: 0, agents: [] })

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('ListAgents.vue — populated', () => {
  it('header chip shows the agent count', () => {
    const wrapper = mount(ListAgents, { props: { message: { content: makePopulated() } } })
    expect(wrapper.find('[data-testid="list-agents"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('list_agents')
    expect(wrapper.text()).toContain('2 agents')
  })

  it('renders 2 rows with name + model/url_style meta + tuning', async () => {
    const wrapper = mount(ListAgents, {
      props: { message: { content: makePopulated() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    const rows = wrapper.findAll('[data-testid^="list-agents-row-"]')
    expect(rows).toHaveLength(2)
    expect(wrapper.text()).toContain('coder')
    expect(wrapper.text()).toContain('gpt-5')
    expect(wrapper.text()).toContain('openai-response')
    expect(wrapper.text()).toContain('reviewer')
    expect(wrapper.text()).toContain('claude-4')
    expect(wrapper.text()).toContain('anthropic')
    // Tuning values from both rows surface in the grid.
    expect(wrapper.text()).toContain('high')
    expect(wrapper.text()).toContain('0.2')
    expect(wrapper.text()).toContain('8000')
    expect(wrapper.text()).toContain('medium')
  })

  it('is collapsed by default and expands on header click', async () => {
    const wrapper = mount(ListAgents, {
      props: { message: { content: makePopulated() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="list-agents-body"]').exists()).toBe(false)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-agents-body"]').exists()).toBe(true)
  })
})

describe('ListAgents.vue — empty', () => {
  it('empty state says no agents are configured', async () => {
    const wrapper = mount(ListAgents, {
      props: { message: { content: makeEmpty() } },
      attachTo: document.body,
    })
    expect(wrapper.text()).toContain('No agents')
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-agents-empty"]').exists()).toBe(true)
  })
})

describe('ListAgents.vue — tuning presence + prompt + secrets', () => {
  it('absent optional tuning tags render no cells', async () => {
    const content = makeEnvelope({
      count: 1,
      agents: [agent({ name: 'plain', maxCapacity: null, compactionPct: null, budget: null, effort: null })],
    })
    const wrapper = mount(ListAgents, {
      props: { message: { content } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    // Present base tuning still renders…
    expect(wrapper.text()).toContain('thinking')
    // …but absent numeric overrides leave no cells.
    expect(wrapper.find('[data-tuning="max_capacity_tokens"]').exists()).toBe(false)
    expect(wrapper.find('[data-tuning="compaction_threshold_percent"]').exists()).toBe(false)
    expect(wrapper.find('[data-tuning="thinking_budget_tokens"]').exists()).toBe(false)
    expect(wrapper.find('[data-tuning="reasoning_effort"]').exists()).toBe(false)
  })

  it('long system_prompt renders in FULL inside the collapsible block', async () => {
    const longPrompt = 'PROMPT-START ' + 'x'.repeat(5000) + ' PROMPT-END'
    const content = makeEnvelope({
      count: 1,
      agents: [agent({ name: 'verbose', prompt: longPrompt })],
    })
    const wrapper = mount(ListAgents, {
      props: { message: { content } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    // Open the per-row prompt <details>.
    const details = wrapper.find('[data-testid="list-agents-prompt-0"]')
    expect(details.exists()).toBe(true)
    const pre = wrapper.find('[data-testid="list-agents-prompt-body-0"]')
    expect(pre.exists()).toBe(true)
    expect(pre.text()).toContain('PROMPT-START')
    expect(pre.text()).toContain('PROMPT-END')
    expect(pre.text().length).toBeGreaterThan(5000)
  })

  it('never renders api_key/base_url even if injected (defense in depth)', async () => {
    const content = makeEnvelope({
      count: 1,
      agents: [
        {
          name: 'evil',
          model: 'm',
          url_style: 'openai',
          thinking: 'off',
          temperature: '0.5',
          api_key: 'sk-SECRET-123',
          base_url: 'https://secret.example.com',
          system_prompt: 'hi',
        },
      ],
    })
    const wrapper = mount(ListAgents, {
      props: { message: { content } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).not.toContain('sk-SECRET-123')
    expect(wrapper.text()).not.toContain('secret.example.com')
    expect(wrapper.html()).not.toContain('sk-SECRET-123')
    expect(wrapper.html()).not.toContain('secret.example.com')
  })
})
