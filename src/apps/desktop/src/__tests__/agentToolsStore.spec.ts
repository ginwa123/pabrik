// Behavioural tests for the agentTools Pinia store.
// Plan: 2026-08-15-agent-mode (Task 14)
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useAgentToolsStore } from '../stores/agentTools'
import * as api from '../api'

describe('agentToolsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('fetches registry on first call', async () => {
    const spy = vi
      .spyOn(api, 'getAgentToolsRegistry')
      .mockResolvedValue({ tools: [{ name: 'bash', description: 'Run shell commands' }] })

    const store = useAgentToolsStore()
    expect(store.registry).toHaveLength(0)

    await store.fetchRegistry()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(store.registry).toHaveLength(1)
    expect(store.registry[0]!.name).toBe('bash')
    expect(store.error).toBeNull()
  })

  it('caches registry across calls (1 fetch total)', async () => {
    const spy = vi
      .spyOn(api, 'getAgentToolsRegistry')
      .mockResolvedValue({ tools: [] })

    const store = useAgentToolsStore()
    await store.fetchRegistry()
    await store.fetchRegistry()
    await store.fetchRegistry()

    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('forces a re-fetch when force=true', async () => {
    const spy = vi
      .spyOn(api, 'getAgentToolsRegistry')
      .mockResolvedValue({ tools: [] })

    const store = useAgentToolsStore()
    await store.fetchRegistry()
    await store.fetchRegistry(true)

    expect(spy).toHaveBeenCalledTimes(2)
  })

  it('captures error message in error ref on fetch failure', async () => {
    vi.spyOn(api, 'getAgentToolsRegistry').mockRejectedValue(new Error('network down'))

    const store = useAgentToolsStore()
    await store.fetchRegistry()

    expect(store.error).toBe('network down')
    expect(store.registry).toHaveLength(0)
  })

  it('isToolEnabled helper returns true when name is in enabled list', () => {
    const store = useAgentToolsStore()
    expect(store.isToolEnabled(['bash', 'read_file'], 'bash')).toBe(true)
    expect(store.isToolEnabled(['bash'], 'read_file')).toBe(false)
  })
})