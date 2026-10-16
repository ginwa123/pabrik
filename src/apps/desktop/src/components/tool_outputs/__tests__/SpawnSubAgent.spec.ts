/** Tests for SpawnSubAgent.vue live-progress rendering. 2026-08-23 spawn-subagent-live-progress. */
import { mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import SpawnSubAgent from '../SpawnSubAgent.vue'
import type { SubAgentProgress } from '../../../helpers/subagentProgress'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
// Loose props type: tests intentionally pass partial / loosely-typed values (e.g. `null` sessionId,
// optional `progress`). vue-tsc independently type-checks the production component against its real
// prop definitions; this cast only relaxes the test fixture.
type TestProps = {
  content?: unknown
  expanded?: boolean
  subAgentArgs?: unknown
  progress?: unknown
}
const mountAt = (props: TestProps) =>
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test fixture; production props are typed at the component boundary.
  mount(SpawnSubAgent, { props: props as any, global: { stubs: {} } })

const sampleProgress = (
  status: 'running' | 'done' | 'failed',
  overrides: Partial<SubAgentProgress> = {},
): SubAgentProgress => ({
  name: 'researcher',
  status,
  index: 0,
  total: 2,
  sessionId: status === 'running' ? undefined : 'subagent_1_researcher',
  elapsedMs: 1234,
  ...overrides,
})

beforeEach(() => {
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: { writeText: vi.fn(async () => {}) },
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ────────────────────────────────────────────────────────────────────────
// Live-progress rendering (NEW — 2026-08-23 feature)
// ────────────────────────────────────────────────────────────────────────
describe('SpawnSubAgent.vue — live progress', () => {
  it('renders one row per progress entry when content has no <results> envelope yet', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'agent-a', index: 0, total: 2 }),
      sampleProgress('done', {
        name: 'agent-b',
        index: 1,
        total: 2,
        sessionId: 'subagent_2_agent-b',
      }),
    ]
    const wrapper = mountAt({ content: '', progress })

    // Header should reflect total count + run/done state.
    expect(wrapper.text()).toContain('2 sub-agents')
    expect(wrapper.text()).toContain('1 running')
    expect(wrapper.text()).toContain('✓ 1') // done

    // Both row names are visible (the component auto-shows the list
    // while in live mode — no expand toggle required).
    expect(wrapper.text()).toContain('agent-a')
    expect(wrapper.text()).toContain('agent-b')
  })

  it('shows ✓ styling on a done row and running chip on a running row', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'r1', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    // Spinner/running badge text — implementation detail; presence is
    // enough to prove the row is rendered.
    expect(wrapper.text()).toMatch(/running/i)
  })

  it('shows ✗ styling on a failed row', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('failed', { name: 'broken', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('✗')
  })

  it('emits a peek event with the sub-agent sessionId when a done row is peeked', async () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('done', {
        name: 'a',
        index: 0,
        total: 1,
        sessionId: 'subagent_99_a',
      }),
    ]
    const subAgentArgs = [
      {
        agent_name: 'a',
        instruction: 'do the thing',
        inherited_context: 'none',
      },
    ]
    const wrapper = mountAt({ content: '', progress, subAgentArgs })
    const peekButton = wrapper.find('[data-testid="peek-button"]')
    expect(peekButton.exists()).toBe(true)
    await peekButton.trigger('click')
    const events = wrapper.emitted('peek') ?? []
    expect(events.length).toBe(1)
    expect(events[0]).toEqual([
      { sessionId: 'subagent_99_a', agentName: 'a', instruction: 'do the thing' },
    ])
  })

  it('does NOT show a peek button on a running row until sessionId is known', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', {
        name: 'a',
        index: 0,
        total: 1,
        sessionId: undefined,
      }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.find('[data-testid="peek-button"]').exists()).toBe(false)
  })

  it('shows the header counts even before any agent has finished (only running)', () => {
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'a', index: 0, total: 3 }),
      sampleProgress('running', { name: 'b', index: 1, total: 3 }),
      sampleProgress('running', { name: 'c', index: 2, total: 3 }),
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('3 sub-agents')
    expect(wrapper.text()).toContain('3 running')
  })

  it('tolerates empty progress array without crashing (shows starting placeholder, not 0)', () => {
    const wrapper = mountAt({ content: '', progress: [] })
    // Without progress AND without parsed-results content, the card is still in the Phase 1
    // placeholder state (tool running, no <results> yet) — 2026-09-04 refresh fix shows an honest
    // "starting…" loading card instead of the confusing "0 sub-agents".
    expect(wrapper.text()).toContain('starting')
    expect(wrapper.text()).not.toContain('0 sub-agents')
  })

  it('shows expected count in starting header when subAgentArgs are known', () => {
    const subAgentArgs = [
      { agent_name: 'a', instruction: 'do a', inherited_context: 'none' },
      { agent_name: 'b', instruction: 'do b', inherited_context: 'none' },
      { agent_name: 'c', instruction: 'do c', inherited_context: 'none' },
    ]
    const wrapper = mountAt({ content: '', progress: [], subAgentArgs })
    expect(wrapper.text()).toContain('3 sub-agents starting')
    expect(wrapper.text()).toContain('Spawning sub-agents')
    // Requested names are listed so refresh still shows intent.
    expect(wrapper.text()).toContain('a')
    expect(wrapper.text()).toContain('b')
    expect(wrapper.text()).toContain('c')
  })

  it('does not crash on a progress entry whose sessionId is undefined AND no agentName', () => {
    const progress: SubAgentProgress[] = [
      {
        name: '',
        status: 'running',
        index: 0,
        total: 1,
        sessionId: undefined,
        elapsedMs: 0,
      },
    ]
    const wrapper = mountAt({ content: '', progress })
    expect(wrapper.text()).toContain('1 sub-agent')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Envelope vs progress precedence (NEW — 2026-08-23 feature)
// ────────────────────────────────────────────────────────────────────────
describe('SpawnSubAgent.vue — envelope precedence', () => {
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

  it('renders the parsed <results> envelope even if progress prop is also passed', async () => {
    // Once the tool result lands, the envelope wins — progress prop is ignored. This matches the PR
    // #299 dedupe principle: the source of truth is the llm_history row, never the SSE-only
    // progress stream (which is ephemeral).
    const progress: SubAgentProgress[] = [
      sampleProgress('running', { name: 'stale', index: 0, total: 1 }),
    ]
    const wrapper = mountAt({ content: envelope, progress, expanded: false })
    // Expand so the row body is rendered (matches what a user sees
    // after clicking the header).
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('alpha')
    expect(wrapper.text()).not.toContain('stale')
  })

  it('keeps the existing parsed-envelope test: header shows ✓1 from <summary>', () => {
    const wrapper = mountAt({ content: envelope })
    expect(wrapper.text()).toContain('✓ 1')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Pre-thread failure (starting-state error — task_1789301896347_4)
// ────────────────────────────────────────────────────────────────────────
describe('SpawnSubAgent.vue — pre-thread failure envelope', () => {
  // What the card receives when exec fails before any thread emits:
  // innerToolData falls back to the FULL envelope (data is null), which
  // carries <success>false</success> + <error> but no <agent>/<summary>.
  const failedEnvelope = JSON.stringify({
    tool: 'spawn_sub_agent',
    parameters: {},
    success: false,
    data: null,
    error: 'spawn_sub_agent failed: AllToolsNotAllowed',
    v: 1,
  })

  it('renders the error message instead of the starting placeholder', () => {
    const wrapper = mountAt({ content: failedEnvelope, progress: [] })
    expect(wrapper.text()).toContain('spawn_sub_agent failed: AllToolsNotAllowed')
    expect(wrapper.text()).not.toContain('Spawning sub-agents')
    expect(wrapper.text()).not.toContain('starting…')
  })

  it('shows a failed badge in the header', () => {
    const wrapper = mountAt({ content: failedEnvelope, progress: [] })
    expect(wrapper.find('[data-testid="failed-badge"]').exists()).toBe(true)
  })
})
