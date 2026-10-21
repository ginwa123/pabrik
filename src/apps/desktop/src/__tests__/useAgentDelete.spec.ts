/**  * Unit tests for the `useAgentDelete` composable. Mocks the `api.deleteAgent` module function
 * (NOT `global.fetch`) so we can assert the composable's optimistic-update + rollback behavior in
 * isolation. */
import { ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { useAgentDelete } from '../composables/useAgentDelete'
import * as api from '../api'

// Mock the whole `../api` module so we control the return value of
// `api.deleteAgent` without hitting the network.
vi.mock('../api', () => ({
  deleteAgent: vi.fn(),
}))

const mockDeleteAgent = api.deleteAgent as unknown as ReturnType<typeof vi.fn>

interface Agent {
  name: string
  model: string
}

describe('useAgentDelete', () => {
  beforeEach(() => {
    mockDeleteAgent.mockReset()
  })

  it('removes the agent from local state immediately (optimistic)', async () => {
    const agents = ref<Agent[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteAgent.mockResolvedValueOnce({
      success: true,
      agent_name: 'alpha',
      active_agent_was_cleared: true,
    })

    const { deleteAgent } = useAgentDelete(agents, active, onSuccess, onError)
    await deleteAgent('alpha')

    expect(agents.value.map((p) => p.name)).toEqual(['beta'])
    expect(active.value).toBeNull()
    expect(mockDeleteAgent).toHaveBeenCalledWith('alpha')
    expect(onSuccess).toHaveBeenCalledTimes(1)
    expect(onError).not.toHaveBeenCalled()
  })

  it('rolls back local state when the API call throws', async () => {
    const agents = ref<Agent[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteAgent.mockRejectedValueOnce(new Error('HTTP 500'))

    const { deleteAgent } = useAgentDelete(agents, active, onSuccess, onError)
    await expect(deleteAgent('alpha')).rejects.toThrow('HTTP 500')

    // Rolled back: alpha is back, active is restored.
    expect(agents.value.map((p) => p.name)).toEqual(['alpha', 'beta'])
    expect(active.value).toBe('alpha')
    expect(onSuccess).not.toHaveBeenCalled()
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.calls[0]![0]).toMatch(/Failed to delete agent.*HTTP 500/)
  })

  it('preserves active_agent when deleting a non-active agent', async () => {
    const agents = ref<Agent[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    mockDeleteAgent.mockResolvedValueOnce({
      success: true,
      agent_name: 'beta',
      active_agent_was_cleared: false,
    })

    const { deleteAgent } = useAgentDelete(agents, active)
    await deleteAgent('beta')

    expect(agents.value.map((p) => p.name)).toEqual(['alpha'])
    expect(active.value).toBe('alpha')
  })

  it('reports isDeleting=true during the in-flight call and false after', async () => {
    const agents = ref<Agent[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    let resolveApi!: (v: unknown) => void
    mockDeleteAgent.mockReturnValueOnce(
      new Promise((r) => {
        resolveApi = r
      }),
    )

    const { deleteAgent, isDeleting } = useAgentDelete(agents, active)
    const p = deleteAgent('alpha')

    // Optimistic update happened, isDeleting is true.
    expect(agents.value).toEqual([])
    expect(isDeleting.value).toBe(true)

    resolveApi({ success: true, agent_name: 'alpha', active_agent_was_cleared: false })
    await p

    expect(isDeleting.value).toBe(false)
  })

  it('emits a friendly "not found" message on HTTP 404', async () => {
    const agents = ref<Agent[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    const onError = vi.fn()
    mockDeleteAgent.mockRejectedValueOnce(new Error('HTTP 404'))

    const { deleteAgent } = useAgentDelete(agents, active, undefined, onError)
    await expect(deleteAgent('alpha')).rejects.toThrow('HTTP 404')

    expect(onError.mock.calls[0]![0]).toMatch(/not found/i)
  })

  it('does nothing when isDeleting is already true (prevents concurrent deletes)', async () => {
    const agents = ref<Agent[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>(null)
    let resolveFirst!: (v: unknown) => void
    mockDeleteAgent.mockReturnValueOnce(
      new Promise((r) => {
        resolveFirst = r
      }),
    )

    const { deleteAgent } = useAgentDelete(agents, active)
    const first = deleteAgent('alpha')
    // Second call while first is in flight — should be a no-op.
    await deleteAgent('beta')

    expect(mockDeleteAgent).toHaveBeenCalledTimes(1)
    expect(mockDeleteAgent).toHaveBeenCalledWith('alpha')

    resolveFirst({ success: true, agent_name: 'alpha', active_agent_was_cleared: false })
    await first
  })
})
