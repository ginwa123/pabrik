/** Tests for workspacesStore.runAllAgentsInColumn — the store action that wraps
 * api.runAllAgentsInColumn for the column "Run all agents" flow (plan:
 * docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md, Task 4, Option C). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import * as api from '@/api'

describe('workspacesStore.runAllAgentsInColumn', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('calls api.runAllAgentsInColumn with the correct args and returns the summary', async () => {
    const runAllSpy = vi.spyOn(api, 'runAllAgentsInColumn').mockResolvedValue({
      success: true,
      column_id: 'col_todo',
      started: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })
    const store = useWorkspacesStore()
    const result = await store.runAllAgentsInColumn('ws_1', 'item_1', 'col_todo')
    expect(runAllSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'col_todo')
    expect(result).toEqual({
      success: true,
      column_id: 'col_todo',
      started: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })
  })

  it('returns an empty-lists summary when api.runAllAgentsInColumn throws (no unhandled rejection)', async () => {
    vi.spyOn(api, 'runAllAgentsInColumn').mockRejectedValue(new Error('network down'))
    const store = useWorkspacesStore()
    const result = await store.runAllAgentsInColumn('ws_1', 'item_1', 'col_todo')
    expect(result.started).toEqual([])
    expect(result.skipped).toEqual([])
    expect(result.failed).toEqual([])
  })
})
