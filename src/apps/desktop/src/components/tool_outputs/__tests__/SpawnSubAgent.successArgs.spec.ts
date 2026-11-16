import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SpawnSubAgent from '../SpawnSubAgent.vue'
import type { SubAgentProgress } from '../../../helpers/subagentProgress'

const envelope = {
  results: [
    {
      name: 'alpha',
      success: true,
      random_fallback: false,
      session_id: 'subagent_1_alpha',
      response: 'done',
      error: null,
    },
  ],
  summary: { succeeded: 1, failed: 0 },
}

// Realistic tool-call args as produced by ChatView's getParametersForMessage (jsonArgsToXml / tool_calls_json arguments).
const parameters = '{"agents":[{"agent_name":"researcher","instruction":"do the thing"}]}'

describe('SpawnSubAgent.vue — parameters (Arguments block)', () => {
  it('live content + non-empty parameters shows Arguments', () => {
    const progress: SubAgentProgress[] = [
      {
        name: 'researcher',
        status: 'running',
        index: 0,
        total: 1,
        sessionId: undefined,
        elapsedMs: 500,
      },
    ]
    const wrapper = mount(SpawnSubAgent, {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test fixture; production props are typed at the component boundary.
      props: { content: '', progress, parameters } as any,
    })
    // Live mode auto-shows the body — no expand toggle required.
    expect(wrapper.text()).toContain('Arguments')
    expect(wrapper.text()).toContain('researcher')
  })

  it('completed content + expanded + non-empty parameters shows Arguments', async () => {
    const wrapper = mount(SpawnSubAgent, {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test fixture; production props are typed at the component boundary.
      props: { content: envelope, expanded: true, parameters } as any,
    })
    expect(wrapper.text()).toContain('Arguments')
    expect(wrapper.text()).toContain('researcher')
  })

  it('empty parameters renders no Arguments (hasArgs guard)', () => {
    const wrapper = mount(SpawnSubAgent, {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test fixture; production props are typed at the component boundary.
      props: { content: envelope, expanded: true, parameters: '{}' } as any,
    })
    expect(wrapper.text()).not.toContain('Arguments')
  })
})
