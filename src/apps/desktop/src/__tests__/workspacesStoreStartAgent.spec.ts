/** Tests for workspacesStore.startAgentOnTask — the store action that wraps api.startAgentOnTask
 * for the kanban edit-mode "Start agent" flow. */
/** Behavioural coverage: calls api.startAgentOnTask with the correct URL; returns the parsed body
 * on success; returns undefined when the API throws (the host falls back to "Agent didn't start"
 * UX). */
/** Distinct from runAgentOnNewTask (create-time, sends a queue_message) and runRoutine
 * (routine-only, 404 for non-routines). Plan:
 * docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import * as api from '@/api'

describe('workspacesStore.startAgentOnTask', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('calls api.startAgentOnTask with the correct args and returns the body on success', async () => {
    const startSpy = vi
      .spyOn(api, 'startAgentOnTask')
      .mockResolvedValue({ success: true, session_id: 'task_abc', status: 'triggered' })
    const store = useWorkspacesStore()
    const result = await store.startAgentOnTask('ws_1', 'item_1', 'task_abc')
    expect(startSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_abc')
    expect(result).toEqual({
      success: true,
      session_id: 'task_abc',
      status: 'triggered',
    })
  })

  it('returns undefined when api.startAgentOnTask throws', async () => {
    vi.spyOn(api, 'startAgentOnTask').mockRejectedValue(new Error('network down'))
    const store = useWorkspacesStore()
    const result = await store.startAgentOnTask('ws_1', 'item_1', 'task_abc')
    expect(result).toBeUndefined()
  })

  it('propagates a backend "success: false" response (does not throw)', async () => {
    // The backend returns `{ success: true, ... }` on the happy path and 4xx errors (no body parse
    // — they fail the apiFetch). The only way the body parses but `success: false` is if the
    // backend adds a partial-success response shape.

    // The host's handler maps this to "Agent didn't start — server reported failure." — verify the
    // action is a pass-through (does NOT throw on success=false).
    vi.spyOn(api, 'startAgentOnTask').mockResolvedValue({ success: false })
    const store = useWorkspacesStore()
    const result = await store.startAgentOnTask('ws_1', 'item_1', 'task_abc')
    expect(result).toEqual({ success: false })
  })
})
