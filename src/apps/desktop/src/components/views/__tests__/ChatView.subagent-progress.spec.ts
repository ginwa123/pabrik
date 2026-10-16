/** Tests for ChatView's SSE routing of `role="subagent_progress"` events into the per-tool_call_id
 * progress map. 2026-08-23 spawn-subagent-live-progress. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ref, nextTick } from 'vue'

import {
  applyProgressEvent,
  clearProgressFor,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../../../helpers/subagentProgress'

// Inline the ChatView-style bus handler so we can test the routing logic in isolation. This mirrors
// the real ChatView.vue:2033 early branch: progress events go into the map; everything else falls
// through (in this test, we just count "ignored").
type RegularEvent = { type: 'full' | 'chunk'; role?: string; session_id?: string; content?: string }

function makeHandler() {
  const progressMap = ref<SubAgentProgressMap>({})
  const ignoredRegularEvents: RegularEvent[] = []

  const onEvent = (event: SubAgentProgressEvent | RegularEvent) => {
    // Mirror ChatView.vue:2034 — session filter.
    if (event.session_id && event.session_id !== 'sess_target') return
    if ((event as SubAgentProgressEvent).role === 'subagent_progress') {
      progressMap.value = applyProgressEvent(
        progressMap.value,
        event as SubAgentProgressEvent,
      )
      return
    }
    if ((event as RegularEvent).type === 'full' || (event as RegularEvent).type === 'chunk') {
      ignoredRegularEvents.push(event as RegularEvent)
      return
    }
  }

  return { progressMap, onEvent, ignoredRegularEvents }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('ChatView progress routing', () => {
  it('routes a launched event into the map for the correct tool_call_id', async () => {
    const { progressMap, onEvent } = makeHandler()
    onEvent({
      role: 'subagent_progress',
      session_id: 'sess_target',
      tool_call_id: 'tc_1',
      agent_name: 'a',
      status: 'launched',
      agent_index: 0,
      total_agents: 1,
      elapsed_ms: 0,
    })
    await nextTick()
    expect(progressMap.value.tc_1?.[0]).toMatchObject({
      name: 'a',
      status: 'running',
    })
  })

  it('updates the map when a completed event arrives', async () => {
    const { progressMap, onEvent } = makeHandler()
    onEvent({
      role: 'subagent_progress',
      session_id: 'sess_target',
      tool_call_id: 'tc_1',
      agent_name: 'a',
      status: 'launched',
      agent_index: 0,
      total_agents: 1,
      elapsed_ms: 0,
    })
    onEvent({
      role: 'subagent_progress',
      session_id: 'sess_target',
      tool_call_id: 'tc_1',
      agent_name: 'a',
      status: 'completed',
      agent_index: 0,
      total_agents: 1,
      elapsed_ms: 100,
      subagent_session_id: 'subagent_1_a',
    })
    await nextTick()
    expect(progressMap.value.tc_1?.[0]).toMatchObject({
      status: 'done',
      sessionId: 'subagent_1_a',
    })
  })

  it('does NOT route events for a different session_id', async () => {
    const { progressMap, onEvent } = makeHandler()
    onEvent({
      role: 'subagent_progress',
      session_id: 'OTHER_SESSION',
      tool_call_id: 'tc_1',
      agent_name: 'a',
      status: 'launched',
      agent_index: 0,
      total_agents: 1,
      elapsed_ms: 0,
    })
    await nextTick()
    expect(progressMap.value).toEqual({})
  })

  it('does NOT swallow regular full/chunk events', async () => {
    const { progressMap, onEvent, ignoredRegularEvents } = makeHandler()
    onEvent({
      type: 'full',
      role: 'assistant',
      session_id: 'sess_target',
      content: 'hello',
    })
    await nextTick()
    expect(progressMap.value).toEqual({})
    expect(ignoredRegularEvents).toHaveLength(1)
    expect(ignoredRegularEvents[0]?.content).toBe('hello')
  })

  it('clearProgressFor drops the entry once the tool result lands', async () => {
    const { progressMap, onEvent } = makeHandler()
    onEvent({
      role: 'subagent_progress',
      session_id: 'sess_target',
      tool_call_id: 'tc_1',
      agent_name: 'a',
      status: 'launched',
      agent_index: 0,
      total_agents: 1,
      elapsed_ms: 0,
    })
    await nextTick()
    expect(progressMap.value.tc_1).toBeDefined()
    // Final <results> envelope arrives — ChatView clears the entry.
    progressMap.value = clearProgressFor(progressMap.value, 'tc_1')
    expect(progressMap.value.tc_1).toBeUndefined()
  })
})
