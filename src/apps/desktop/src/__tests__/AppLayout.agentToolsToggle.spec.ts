// Behavioural tests for the agentToolToggle pure helper.
import { describe, it, expect, vi } from 'vitest'
import { buildToggle } from '../stores/agentToolToggle'

describe('buildToggle (handleAgentToggleTool extracted helper)', () => {
  it('returns nextLocal WITH toolName when enabled=true', () => {
    const r = buildToggle(
      ['bash'], 'read_file', true, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['bash', 'read_file'])
  })

  it('returns nextLocal WITHOUT toolName when enabled=false', () => {
    const r = buildToggle(
      ['bash', 'read_file'], 'bash', false, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['read_file'])
  })

  it('nextLocal is idempotent on enable (dedupe)', () => {
    const r = buildToggle(
      ['bash'], 'bash', true, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['bash'])
  })

  it('calls enableAgentTool when enabled=true', async () => {
    const enableAgentTool = vi.fn().mockResolvedValue({})
    const disableAgentTool = vi.fn()
    const refetchAgentTools = vi.fn().mockResolvedValue(['bash'])
    const r = buildToggle([], 'bash', true, 'agent_1',
      { enableAgentTool, disableAgentTool, refetchAgentTools })
    await r.serverPromise
    expect(enableAgentTool).toHaveBeenCalledWith('agent_1', 'bash')
    expect(disableAgentTool).not.toHaveBeenCalled()
  })

  it('calls disableAgentTool when enabled=false', async () => {
    const enableAgentTool = vi.fn()
    const disableAgentTool = vi.fn().mockResolvedValue({ ok: true })
    const refetchAgentTools = vi.fn().mockResolvedValue([])
    const r = buildToggle(['bash'], 'bash', false, 'agent_1',
      { enableAgentTool, disableAgentTool, refetchAgentTools })
    await r.serverPromise
    expect(disableAgentTool).toHaveBeenCalledWith('agent_1', 'bash')
    expect(enableAgentTool).not.toHaveBeenCalled()
  })

  it('returns the canonical server list via refetchAgentTools', async () => {
    const r = buildToggle([], 'bash', true, 'agent_1', {
      enableAgentTool: vi.fn().mockResolvedValue({}),
      disableAgentTool: vi.fn(),
      refetchAgentTools: vi.fn().mockResolvedValue(['bash', 'read_file']),
    })
    const out = await r.serverPromise
    expect(out).toEqual({ canonical: ['bash', 'read_file'] })
  })

  it('catches API failure and returns { error } (does not throw)', async () => {
    const r = buildToggle([], 'bash', true, 'agent_1', {
      enableAgentTool: vi.fn().mockRejectedValue(new Error('409 Conflict')),
      disableAgentTool: vi.fn(),
      refetchAgentTools: vi.fn(),
    })
    const out = await r.serverPromise
    expect(out).toEqual({ error: expect.any(Error) })
  })
})