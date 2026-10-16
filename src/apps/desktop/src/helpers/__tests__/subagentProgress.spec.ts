/** Tests for subagentProgress.ts — pure reducer for the chatview's spawn_sub_agent live-progress
 * map. 2026-08-23 spawn-subagent-live-progress: ChatView.vue maintains a per-tool_call_id progress
 * map and feeds it from the SSE bus's `role="subagent_progress"` events. */
import { describe, expect, it } from 'vitest'

import {
  applyProgressEvent,
  applySnapshotRows,
  clearProgressFor,
  isPlaceholderSpawnRow,
  type SubAgentProgressEvent,
  type SubAgentProgressMap,
} from '../subagentProgress'

const launchedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'launched',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 0,
  session_id: 'sess_parent',
  ...over,
})

const completedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'completed',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 5000,
  session_id: 'sess_parent',
  subagent_session_id: 'subagent_123_agent-a',
  ...over,
})

const failedEvent = (
  over: Partial<SubAgentProgressEvent> = {},
): SubAgentProgressEvent => ({
  role: 'subagent_progress',
  tool_call_id: 'tc_1',
  agent_name: 'agent-a',
  status: 'failed',
  agent_index: 0,
  total_agents: 2,
  elapsed_ms: 100,
  session_id: 'sess_parent',
  ...over,
})

describe('applyProgressEvent', () => {
  it('creates a running row on launched', () => {
    const next = applyProgressEvent({}, launchedEvent())
    expect(next.tc_1).toHaveLength(1)
    expect(next.tc_1?.[0]).toMatchObject({
      name: 'agent-a',
      status: 'running',
      index: 0,
      total: 2,
      elapsedMs: 0,
    })
  })

  it('flips running → done on completed', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(
      map,
      completedEvent({ subagent_session_id: 'subagent_1_a' }),
    )
    expect(map.tc_1?.[0]).toMatchObject({
      status: 'done',
      sessionId: 'subagent_1_a',
      elapsedMs: 5000,
    })
  })

  it('flips running → failed on failed', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(map, failedEvent())
    expect(map.tc_1?.[0]).toMatchObject({ status: 'failed' })
  })

  it('events for different tool_call_ids do not cross-contaminate', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(
      map,
      launchedEvent({ tool_call_id: 'tc_a', agent_index: 0, agent_name: 'a' }),
    )
    map = applyProgressEvent(
      map,
      launchedEvent({ tool_call_id: 'tc_b', agent_index: 0, agent_name: 'b' }),
    )
    expect(Object.keys(map).sort()).toEqual(['tc_a', 'tc_b'])
    expect(map.tc_a?.[0]?.name).toBe('a')
    expect(map.tc_b?.[0]?.name).toBe('b')
  })

  it('keys two concurrent spawn batches separately by agent_index', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent({ agent_index: 0 }))
    map = applyProgressEvent(
      map,
      launchedEvent({
        agent_index: 1,
        agent_name: 'agent-b',
        subagent_session_id: 'subagent_2_b',
      }),
    )
    expect(map.tc_1?.[0]?.name).toBe('agent-a')
    expect(map.tc_1?.[1]?.name).toBe('agent-b')
    expect(map.tc_1?.[1]?.sessionId).toBe('subagent_2_b')
  })

  it('out-of-order launched does NOT downgrade a done row', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(map, completedEvent())
    // A late `launched` (replay) must not undo completion.
    map = applyProgressEvent(map, launchedEvent())
    expect(map.tc_1?.[0]?.status).toBe('done')
  })

  it('preserves sessionId across launches (only set once known)', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent()) // no session_id yet
    map = applyProgressEvent(
      map,
      completedEvent({ subagent_session_id: 'subagent_x_a' }),
    )
    // A late launched-with-empty-subagent_session_id must not clear it.
    map = applyProgressEvent(map, launchedEvent())
    expect(map.tc_1?.[0]?.sessionId).toBe('subagent_x_a')
  })

  it('ignores events with wrong role (defense-in-depth)', () => {
    const original: SubAgentProgressMap = { tc_1: [] }
    const next = applyProgressEvent(original, {
      role: 'assistant' as unknown as 'subagent_progress',
      status: 'launched',
      tool_call_id: 'tc_1',
      agent_index: 0,
    })
    expect(next).toBe(original) // same reference → no allocation, no mutation
  })

  it('ignores events missing tool_call_id', () => {
    const next = applyProgressEvent({}, launchedEvent({ tool_call_id: undefined }))
    expect(next).toEqual({})
  })

  it('ignores events missing status', () => {
    const next = applyProgressEvent({}, { ...launchedEvent(), status: undefined })
    expect(next).toEqual({})
  })

  it('ignores events with negative agent_index', () => {
    const next = applyProgressEvent({}, launchedEvent({ agent_index: -1 }))
    expect(next).toEqual({})
  })
})

describe('clearProgressFor', () => {
  it('drops the entry for a known tool_call_id', () => {
    let map: SubAgentProgressMap = {}
    map = applyProgressEvent(map, launchedEvent())
    map = applyProgressEvent(
      map,
      launchedEvent({
        tool_call_id: 'tc_2',
        agent_index: 0,
        agent_name: 'other',
      }),
    )
    const cleared = clearProgressFor(map, 'tc_1')
    expect(cleared.tc_1).toBeUndefined()
    expect(cleared.tc_2).toBeDefined()
  })

  it('returns the same reference when the id is unknown (no-op)', () => {
    const original: SubAgentProgressMap = { tc_1: [] }
    const next = clearProgressFor(original, 'tc_unknown')
    expect(next).toBe(original)
  })
})

describe('isPlaceholderSpawnRow (2026-09-04 refresh rehydrate)', () => {
  const placeholder = {
    role: 'tool',
    tool_name: 'spawn_sub_agent',
    tool_call_id: 'tc_1',
    content: '<tool><name>spawn_sub_agent</name><parameters>{}</parameters><data></data></tool>',
  }

  it('matches a Phase 1 placeholder spawn row (no <summary>)', () => {
    expect(isPlaceholderSpawnRow(placeholder)).toBe(true)
  })

  it('rejects a completed spawn row (has <summary>)', () => {
    expect(
      isPlaceholderSpawnRow({
        ...placeholder,
        content: '<tool><data><results><agent name="a" success="true"></agent><summary succeeded="1" failed="0" /></results></data></tool>',
      }),
    ).toBe(false)
  })

  it('rejects non-spawn tools, non-tool roles, and missing ids', () => {
    expect(isPlaceholderSpawnRow({ ...placeholder, tool_name: 'bash' })).toBe(false)
    expect(isPlaceholderSpawnRow({ ...placeholder, role: 'assistant' })).toBe(false)
    expect(isPlaceholderSpawnRow({ ...placeholder, tool_call_id: null })).toBe(false)
    expect(isPlaceholderSpawnRow({ ...placeholder, tool_call_id: '' })).toBe(false)
    expect(isPlaceholderSpawnRow({ ...placeholder, content: null })).toBe(false)
  })
})

describe('applySnapshotRows (2026-09-04 refresh rehydrate)', () => {
  const snapshotRows = [
    {
      agent_name: 'agent-a',
      status: 'launched' as const,
      agent_index: 0,
      total_agents: 2,
      subagent_session_id: 'subagent_1_agent-a',
      elapsed_ms: 1234,
    },
    {
      agent_name: 'agent-b',
      status: 'completed' as const,
      agent_index: 1,
      total_agents: 2,
      subagent_session_id: 'subagent_2_agent-b',
      elapsed_ms: 5000,
    },
  ]

  it('folds snapshot rows into running/done UI rows', () => {
    const next = applySnapshotRows({}, 'tc_1', snapshotRows)
    expect(next.tc_1?.[0]).toMatchObject({ name: 'agent-a', status: 'running' })
    expect(next.tc_1?.[1]).toMatchObject({
      name: 'agent-b',
      status: 'done',
      sessionId: 'subagent_2_agent-b',
    })
  })

  it('normalizes "" session ids to undefined (peek stays disabled)', () => {
    const next = applySnapshotRows({}, 'tc_1', [
      {
        agent_name: 'agent-a',
        status: 'launched' as const,
        agent_index: 0,
        total_agents: 1,
        subagent_session_id: '',
        elapsed_ms: 0,
      },
    ])
    expect(next.tc_1?.[0]?.sessionId).toBeUndefined()
  })

  it('leaves the map untouched for an empty snapshot', () => {
    const original: SubAgentProgressMap = {}
    expect(applySnapshotRows(original, 'tc_1', [])).toBe(original)
  })

  it('does not regress done rows when a stale launched snapshot arrives', () => {
    let map = applySnapshotRows({}, 'tc_1', snapshotRows)
    map = applySnapshotRows(map, 'tc_1', [
      {
        agent_name: 'agent-b',
        status: 'launched' as const,
        agent_index: 1,
        total_agents: 2,
        subagent_session_id: '',
        elapsed_ms: 0,
      },
    ])
    expect(map.tc_1?.[1]?.status).toBe('done')
  })
})

describe('isPlaceholderSpawnRow — failed envelope is not a placeholder', () => {
  it('rejects a pre-thread failure row (<success>false</success>, no <summary>)', () => {
    expect(
      isPlaceholderSpawnRow({
        role: 'tool',
        tool_name: 'spawn_sub_agent',
        tool_call_id: 'tc_1',
        content:
          '<tool><name>spawn_sub_agent</name><parameters>{}</parameters><success>false</success><error>spawn_sub_agent failed: AllToolsNotAllowed</error></tool>',
      }),
    ).toBe(false)
  })
})
