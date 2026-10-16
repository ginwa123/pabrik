/** Tests for SpawnSubAgent.vue, focusing on the new peek button +
 * event that triggers SubAgentPeekPanel. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import SpawnSubAgent from '../components/tool_outputs/SpawnSubAgent.vue'

describe('SpawnSubAgent peek button', () => {
  const sampleResult = {
    results: [
      {
        name: 'backend-dev',
        success: true,
        random_fallback: false,
        session_id: 'subagent_1_backend-dev',
        response: 'Did the task',
        error: null,
      },
    ],
    summary: { succeeded: 1, failed: 0 },
  }

  it('emits peek with sessionId + agentName + instruction when peek button is clicked', async () => {
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: sampleResult,
        expanded: true,
        subAgentArgs: [
          { agent_name: 'backend-dev', instruction: 'do X', tools: ['read_file'] },
        ],
      },
    })

    const peekBtn = wrapper.find('[data-testid="peek-button"]')
    expect(peekBtn.exists()).toBe(true)

    await peekBtn.trigger('click')
    const emitted = wrapper.emitted('peek')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      expect.objectContaining({
        sessionId: 'subagent_1_backend-dev',
        agentName: 'backend-dev',
        instruction: 'do X',
      }),
    ])
  })

  it('renders one peek button per agent row (one per sub-agent)', () => {
    const twoAgentResult = {
      results: [
        { name: 'a', success: true, random_fallback: false, session_id: 'subagent_1_a', response: 'ok', error: null },
        { name: 'b', success: true, random_fallback: false, session_id: 'subagent_1_b', response: 'ok', error: null },
      ],
      summary: { succeeded: 2, failed: 0 },
    }
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: twoAgentResult,
        expanded: true,
        subAgentArgs: [
          { agent_name: 'a', instruction: 'do A', tools: ['read_file'] },
          { agent_name: 'b', instruction: 'do B', tools: ['glob'] },
        ],
      },
    })
    expect(wrapper.findAll('[data-testid="peek-button"]')).toHaveLength(2)
  })

  it('does NOT render a peek button for agents without a session_id', () => {
    const noSessionResult = {
      results: [
        { name: 'a', success: false, random_fallback: false, session_id: null, response: null, error: 'Workflow error: X' },
      ],
      summary: { succeeded: 0, failed: 1 },
    }
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: noSessionResult,
        expanded: true,
        subAgentArgs: [{ agent_name: 'a', instruction: 'do A', tools: ['read_file'] }],
      },
    })
    expect(wrapper.findAll('[data-testid="peek-button"]')).toHaveLength(0)
  })

  it('passes an empty string for instruction when subAgentArgs is missing', async () => {
    const wrapper = mount(SpawnSubAgent, {
      props: {
        content: sampleResult,
        expanded: true,
        // No subAgentArgs — the component must not crash.
      },
    })

    const peekBtn = wrapper.find('[data-testid="peek-button"]')
    expect(peekBtn.exists()).toBe(true)

    await peekBtn.trigger('click')
    const emitted = wrapper.emitted('peek')
    expect(emitted![0]![0]).toEqual(
      expect.objectContaining({
        sessionId: 'subagent_1_backend-dev',
        agentName: 'backend-dev',
        instruction: '',
      }),
    )
  })
})