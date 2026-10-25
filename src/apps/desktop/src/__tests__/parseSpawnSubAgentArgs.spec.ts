import { describe, it, expect, vi } from 'vitest'
import { indexSpawnSubAgentArgs, parseSpawnSubAgentArgs } from '../helpers/parseSpawnSubAgentArgs'

const spawnCall = (id: string, subAgents: unknown, name = 'spawn_sub_agent') => ({
  id,
  type: 'function',
  function: { name, arguments: JSON.stringify({ sub_agents: subAgents }) },
})

const VALID = [{ agent_name: 'reviewer', instruction: 'do x', tools: ['read_file'] }]

describe('parseSpawnSubAgentArgs', () => {
  it('returns null when toolCallsJson is null', () => {
    expect(parseSpawnSubAgentArgs(null, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is undefined', () => {
    expect(parseSpawnSubAgentArgs(undefined, 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallsJson is empty string', () => {
    expect(parseSpawnSubAgentArgs('', 'call_xxx')).toBeNull()
  })

  it('returns null when toolCallId is null', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, null)).toBeNull()
  })

  it('returns null when toolCallsJson is malformed JSON', () => {
    expect(parseSpawnSubAgentArgs('{not valid json', 'call_xxx')).toBeNull()
  })

  it('returns null when no tool call matches the given toolCallId', () => {
    const json = JSON.stringify([{
      id: 'call_yyy', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching tool call is not spawn_sub_agent', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'use_skill', arguments: '{}' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('parses arguments as a JSON string (OpenAI format)', () => {
    const args = JSON.stringify({
      sub_agents: [{ agent_name: 'reviewer', instruction: 'do x', tools: ['read_file'], inherited_context: 'last:3' }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ agent_name: 'reviewer', instruction: 'do x', tools: ['read_file'], inherited_context: 'last:3' }])
  })

  it('parses arguments as an already-parsed object (defensive)', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: { sub_agents: [{ agent_name: 'reviewer', instruction: 'x', tools: ['glob'] }] } }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{ agent_name: 'reviewer', instruction: 'x', tools: ['glob'] }])
  })

  it('preserves all sub-agent fields when fully populated', () => {
    const args = JSON.stringify({
      sub_agents: [{
        agent_name: 'researcher',
        instruction: 'find docs',
        tools: ['bash', 'web_browse'],
        timeout_seconds: 300,
        inherited_context: 'last:5'
      }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toEqual([{
      agent_name: 'researcher',
      instruction: 'find docs',
      tools: ['bash', 'web_browse'],
      timeout_seconds: 300,
      inherited_context: 'last:5'
    }])
  })

  it('returns null when sub_agents is not an array', () => {
    const args = JSON.stringify({ sub_agents: 'not an array' })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns null when the matching call arguments is malformed JSON', () => {
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: '{not valid' }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toBeNull()
  })

  it('returns an empty array when a sub-agent is missing the required agent_name', () => {
    const args = JSON.stringify({
      sub_agents: [{ instruction: 'x', tools: ['read_file'] }]  // no agent_name
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    // The parser filters out invalid sub-agents and returns an empty
    // array (not null) when the matching call was found but every
    // sub-agent is invalid. `null` is reserved for "no matching call".
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toEqual([])
  })

  it('returns an empty array when a sub-agent has an empty-string agent_name', () => {
    const args = JSON.stringify({
      sub_agents: [{ agent_name: '', instruction: 'x', tools: ['read_file'] }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toEqual([])
  })

  // 2026-09-12 tools-required: `tools` is no longer optional — the backend rejects
  // missing/empty/"all" at parse time, so the display parser drops such entries instead of
  // rendering cards for a spawn that will never execute.
  it('filters out sub-agents missing the required tools (no throw)', () => {
    const args = JSON.stringify({
      sub_agents: [{ agent_name: 'reviewer', instruction: 'x' }]  // no tools
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toEqual([])
  })

  it('filters out sub-agents with an empty tools array', () => {
    const args = JSON.stringify({
      sub_agents: [{ agent_name: 'reviewer', instruction: 'x', tools: [] }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toEqual([])
  })

  it('filters out sub-agents whose tools contain "all"', () => {
    const args = JSON.stringify({
      sub_agents: [{ agent_name: 'reviewer', instruction: 'x', tools: ['read_file', 'all'] }]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    expect(parseSpawnSubAgentArgs(json, 'call_xxx')).toEqual([])
  })

  it('returns multiple sub-agents in order', () => {
    const args = JSON.stringify({
      sub_agents: [
        { agent_name: 'reviewer', instruction: 'x', tools: ['read_file'], inherited_context: 'last:3' },
        { agent_name: 'explorer', instruction: 'y', tools: ['glob'], inherited_context: 'none' },
        { agent_name: 'writer', instruction: 'z', tools: ['read_file', 'write_file'] }
      ]
    })
    const json = JSON.stringify([{
      id: 'call_xxx', type: 'function',
      function: { name: 'spawn_sub_agent', arguments: args }
    }])
    const result = parseSpawnSubAgentArgs(json, 'call_xxx')
    expect(result).toHaveLength(3)
    expect(result?.[0]?.agent_name).toBe('reviewer')
    expect(result?.[1]?.inherited_context).toBe('none')
    expect(result?.[2]?.inherited_context).toBeUndefined()
  })

  // 2026-08-14 pwsh-tool: pwsh is a valid tool name in sub_agents.tools.
  // Locks the public contract — if a future refactor hardcodes valid
  // tool names this regression test catches the broken pwsh acceptance.
  it('accepts pwsh as a valid tool name in the sub_agents.tools array', () => {
    const args = JSON.stringify({
      sub_agents: [
        {
          agent_name: 'winops',
          instruction: 'manage Windows services',
          tools: ['pwsh', 'web_search'],
          timeout_seconds: 600,
        },
      ],
    })
    const json = JSON.stringify([
      {
        id: 'call_xyz',
        type: 'function',
        function: { name: 'spawn_sub_agent', arguments: args },
      },
    ])
    const result = parseSpawnSubAgentArgs(json, 'call_xyz')
    expect(result).toEqual([
      {
        agent_name: 'winops',
        instruction: 'manage Windows services',
        tools: ['pwsh', 'web_search'],
        timeout_seconds: 600,
      },
    ])
  })

  // unify-command Phase C: `command` is a valid tool name in
  // sub_agents.tools (bash/pwsh stay accepted — no valid-names gate in
  // the parser, this locks the pass-through contract for the new name).
  it('accepts command as a valid tool name in the sub_agents.tools array', () => {
    const args = JSON.stringify({
      sub_agents: [
        {
          agent_name: 'shellops',
          instruction: 'run shell commands',
          tools: ['command', 'read_file'],
          timeout_seconds: 600,
        },
      ],
    })
    const json = JSON.stringify([
      {
        id: 'call_xyz',
        type: 'function',
        function: { name: 'spawn_sub_agent', arguments: args },
      },
    ])
    const result = parseSpawnSubAgentArgs(json, 'call_xyz')
    expect(result).toEqual([
      {
        agent_name: 'shellops',
        instruction: 'run shell commands',
        tools: ['command', 'read_file'],
        timeout_seconds: 600,
      },
    ])
  })
})

describe('indexSpawnSubAgentArgs', () => {
  it('keys every spawn call of one message by its tool_call_id', () => {
    const json = JSON.stringify([
      spawnCall('call_a', VALID),
      spawnCall('call_b', [{ agent_name: 'explorer', instruction: 'y', tools: ['glob'] }]),
    ])

    const index = indexSpawnSubAgentArgs(json)

    expect([...index.keys()].sort()).toEqual(['call_a', 'call_b'])
    expect(index.get('call_b')).toEqual([
      { agent_name: 'explorer', instruction: 'y', tools: ['glob'] },
    ])
  })

  it('leaves out a call that is not a spawn', () => {
    const json = JSON.stringify([
      spawnCall('call_a', VALID),
      spawnCall('call_b', VALID, 'read_file'),
    ])

    expect([...indexSpawnSubAgentArgs(json).keys()]).toEqual(['call_a'])
  })

  it('leaves out a spawn whose arguments cannot be read', () => {
    const json = JSON.stringify([
      spawnCall('call_a', VALID),
      {
        id: 'call_b',
        type: 'function',
        function: { name: 'spawn_sub_agent', arguments: '{not json' },
      },
      { id: 'call_c', type: 'function', function: { name: 'spawn_sub_agent' } },
    ])

    expect([...indexSpawnSubAgentArgs(json).keys()]).toEqual(['call_a'])
  })

  it('returns an empty index for a payload it cannot read', () => {
    expect(indexSpawnSubAgentArgs(null).size).toBe(0)
    expect(indexSpawnSubAgentArgs('').size).toBe(0)
    expect(indexSpawnSubAgentArgs('{not json').size).toBe(0)
    expect(indexSpawnSubAgentArgs('{"a":1}').size).toBe(0)
  })

  it('agrees with parseSpawnSubAgentArgs for every call of the message', () => {
    const json = JSON.stringify([
      spawnCall('call_a', VALID),
      spawnCall('call_b', [{ instruction: 'no agent name', tools: ['glob'] }]),
      spawnCall('call_c', VALID, 'command'),
    ])

    const index = indexSpawnSubAgentArgs(json)

    for (const id of ['call_a', 'call_b', 'call_c']) {
      expect(index.get(id)).toEqual(parseSpawnSubAgentArgs(json, id) ?? undefined)
    }
  })

  it('reads the payload once no matter how many spawn calls it holds', () => {
    const json = JSON.stringify(
      Array.from({ length: 8 }, (_, i) => spawnCall(`call_${i}`, VALID)),
    )
    const parse = vi.spyOn(JSON, 'parse')

    indexSpawnSubAgentArgs(json)

    const reads = parse.mock.calls.filter((call) => call[0] === json).length
    parse.mockRestore()
    expect(reads).toBe(1)
  })
})
