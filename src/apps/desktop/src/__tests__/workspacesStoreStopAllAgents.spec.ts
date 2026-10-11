/**
 * Tests for workspacesStore.stopAllAgentsInColumn — the store action that
 * wraps api.stopAllAgentsInColumn for the column "Stop all agents" flow
 * (mirror of workspacesStoreRunAllAgents.spec.ts).
 *
 * Thin wrapper (no client-side task iteration — the server owns the
 * list, so pagination is irrelevant). Mocked api returning
 * `{stopped:2, skipped:1, failed:0}` resolves to the same summary;
 * API throw → empty-lists summary, no unhandled rejection.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import * as api from '@/api'

describe('workspacesStore.stopAllAgentsInColumn', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('calls api.stopAllAgentsInColumn with the correct args and returns the summary', async () => {
    const stopAllSpy = vi.spyOn(api, 'stopAllAgentsInColumn').mockResolvedValue({
      success: true,
      column_id: 'col_todo',
      stopped: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })
    const store = useWorkspacesStore()
    const result = await store.stopAllAgentsInColumn('ws_1', 'item_1', 'col_todo')
    expect(stopAllSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'col_todo')
    expect(result).toEqual({
      success: true,
      column_id: 'col_todo',
      stopped: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })
  })

  it('returns an empty-lists summary when api.stopAllAgentsInColumn throws (no unhandled rejection)', async () => {
    vi.spyOn(api, 'stopAllAgentsInColumn').mockRejectedValue(new Error('network down'))
    const store = useWorkspacesStore()
    const result = await store.stopAllAgentsInColumn('ws_1', 'item_1', 'col_todo')
    expect(result.stopped).toEqual([])
    expect(result.skipped).toEqual([])
    expect(result.failed).toEqual([])
  })
})
