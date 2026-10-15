/**
 * Tests for ListSubAgent.vue.
 *
 * Wire contract (FIXED — backend built in parallel):
 *   <list_sub_agent><profile>P</profile><count>N</count><sub_agents>
 *     <sub_agent><name>..</name><model>..</model><url_style>..</url_style>
 *     <thinking>..</thinking><temperature>..</temperature>
 *     [<max_capacity_tokens>..</max_capacity_tokens>]
 *     [<compaction_threshold_percent>..</compaction_threshold_percent>]
 *     [<thinking_budget_tokens>..</thinking_budget_tokens>]
 *     [<reasoning_effort>..</reasoning_effort>]
 *     <system_prompt><![CDATA[full text]]></system_prompt></sub_agent>
 *   ...</sub_agents></list_sub_agent>
 *   or empty: <list_sub_agent><profile>P</profile><empty/></list_sub_agent>
 * String fields may be empty; optional numeric tags may be ABSENT
 * (means 'inherits profile default'). api_key/base_url NEVER appear.
 *
 * Verifies:
 *  - populated 2 rows with tuning render names + meta + tuning grid
 *  - empty state shows "No subagents on profile <name>"
 *  - missing <profile> falls back to a placeholder string
 *  - absent optional tuning tags render no cells
 *  - long system_prompt renders in FULL (not truncated)
 *  - api_key/base_url never rendered even if injected (defense in depth)
 *  - header chip shows "N subagents · profile <name>"
 *  - collapsed by default, expands on header click
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ListSubAgent from '../ListSubAgent.vue'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
const subAgent = (opts: {
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
    tool: 'list_sub_agent',
    parameters: {},
    success: true,
    data,
    error: null,
    v: 1,
  })

const makePopulated = (): string =>
  makeEnvelope({
    profile: 'dev',
    count: 2,
    sub_agents: [
      subAgent({ name: 'coder', model: 'gpt-5', urlStyle: 'openai-response', thinking: 'high', temperature: '0.2', prompt: 'Coder prompt.' }),
      subAgent({ name: 'reviewer', model: 'claude-4', urlStyle: 'anthropic', thinking: 'off', temperature: '0.9', budget: '8000', effort: 'medium', prompt: 'Reviewer prompt.' }),
    ],
  })

const makeEmpty = (profile = 'dev'): string => makeEnvelope({ profile, count: 0, sub_agents: [] })

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('ListSubAgent.vue — populated', () => {
  it('header chip shows count + profile name', () => {
    const wrapper = mount(ListSubAgent, { props: { message: { content: makePopulated() } } })
    expect(wrapper.find('[data-testid="list-sub-agent"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('list_sub_agent')
    expect(wrapper.text()).toContain('2 subagents')
    expect(wrapper.text()).toContain('dev')
  })

  it('renders 2 rows with name + model/url_style meta + tuning', async () => {
    const wrapper = mount(ListSubAgent, {
      props: { message: { content: makePopulated() } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    const rows = wrapper.findAll('[data-testid^="list-sub-agent-row-"]')
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
    const wrapper = mount(ListSubAgent, {
      props: { message: { content: makePopulated() } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="list-sub-agent-body"]').exists()).toBe(false)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-sub-agent-body"]').exists()).toBe(true)
  })
})

describe('ListSubAgent.vue — empty / profile', () => {
  it('empty state shows "No subagents on profile <name>"', async () => {
    const wrapper = mount(ListSubAgent, {
      props: { message: { content: makeEmpty('dev') } },
      attachTo: document.body,
    })
    expect(wrapper.text()).toContain('No subagents')
    expect(wrapper.text()).toContain('dev')
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="list-sub-agent-empty"]').exists()).toBe(true)
  })

  it('missing <profile> falls back to a placeholder string', () => {
    const wrapper = mount(ListSubAgent, {
      props: { message: { content: makeEnvelope({ count: 0, sub_agents: [] }) } },
    })
    // Must render *something* for the profile slot — never blank/undefined.
    expect(wrapper.text()).toMatch(/unknown|profile/i)
  })
})

describe('ListSubAgent.vue — tuning presence + prompt + secrets', () => {
  it('absent optional tuning tags render no cells', async () => {
    const content = makeEnvelope({
      profile: 'dev',
      count: 1,
      sub_agents: [subAgent({ name: 'plain', maxCapacity: null, compactionPct: null, budget: null, effort: null })],
    })
    const wrapper = mount(ListSubAgent, {
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
      profile: 'dev',
      count: 1,
      sub_agents: [subAgent({ name: 'verbose', prompt: longPrompt })],
    })
    const wrapper = mount(ListSubAgent, {
      props: { message: { content } },
      attachTo: document.body,
    })
    await wrapper.find('[role="button"]').trigger('click')
    // Open the per-row prompt <details>.
    const details = wrapper.find('[data-testid="list-sub-agent-prompt-0"]')
    expect(details.exists()).toBe(true)
    const pre = wrapper.find('[data-testid="list-sub-agent-prompt-body-0"]')
    expect(pre.exists()).toBe(true)
    expect(pre.text()).toContain('PROMPT-START')
    expect(pre.text()).toContain('PROMPT-END')
    expect(pre.text().length).toBeGreaterThan(5000)
  })

  it('never renders api_key/base_url even if injected (defense in depth)', async () => {
    const content = makeEnvelope({
      profile: 'dev',
      count: 1,
      sub_agents: [
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
    const wrapper = mount(ListSubAgent, {
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
