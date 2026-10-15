/**
 * Tests for workspacesStore.addKanbanTask — single store action
 * replacing the addTask + runAgentOnNewTask dance in the kanban flow.
 *
 * Behavioural coverage (vs. the plan's 4 tests):
 *   - mode='create' → api.createKanbanTask with mode='create' +
 *                      returns { task, session: null }
 *   - mode='create_and_run' → api.createKanbanTask with mode='create_and_run'
 *                              + queue_message + selected_profile_model +
 *                              returns { task, session }
 *   - mode='create_and_run' failure → notifyError + returns { task: null, session: null }
 *                                     (no throw — partial success UX)
 *   - mode='create' failure → re-throws (no partial-success path
 *                             because there's nothing to fall back to)
 *
 * Plan: docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md
 *   Task 4
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import { useNotificationStore } from '@/stores/notifications'
import * as api from '@/api'

describe('workspacesStore.addKanbanTask', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("mode='create' calls api.createKanbanTask with mode='create' and returns task + null session", async () => {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'Fix bug', task_type: 'standard' } as any
    const createSpy = vi
      .spyOn(api, 'createKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: null })

    const store = useWorkspacesStore()
    const result = await store.addKanbanTask('ws_1', 'item_1', 'create', {
      name: 'Fix bug',
      description: 'The login button is broken',
      tags: ['bug'],
      cwd: '/home/u/proj',
    })

     
    expect(createSpy).toHaveBeenCalledTimes(1)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const [wid, iid, payload] = createSpy.mock.calls[0] as [string, string, any]
    expect(wid).toBe('ws_1')
    expect(iid).toBe('item_1')
    expect(payload.mode).toBe('create')
    expect(payload.name).toBe('Fix bug')
    expect(payload.description).toBe('The login button is broken')
    expect(payload.tags).toEqual(['bug'])
    expect(payload.cwd).toBe('/home/u/proj')
    // queue_message + selected_profile_model NOT forwarded in plain create
    expect(payload.queue_message).toBeUndefined()
    expect(payload.selected_profile_model).toBeUndefined()

    expect(result.task).toEqual(fakeTask)
    expect(result.session).toBeNull()
  })

 

  it("mode='create_and_run' forwards queue_message + selected_profile_model + returns session", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'Fix bug', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'Fix bug', status: 'send' }
    const createSpy = vi
      .spyOn(api, 'createKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const store = useWorkspacesStore()
    const result = await store.addKanbanTask('ws_1', 'item_1', 'create_and_run', {
      name: 'Fix bug',
      description: 'The login button is broken',
      queue_message: 'Fix bug\n\nThe login button is broken',
      selected_profile_model: 'profile_a',
      isAutoRetryUntilStop: '1',
      cwd: '/home/u/proj',
     
    })

    expect(createSpy).toHaveBeenCalledTimes(1)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const [, , payload] = createSpy.mock.calls[0] as [string, string, any]
    expect(payload.mode).toBe('create_and_run')
    expect(payload.queue_message).toBe('Fix bug\n\nThe login button is broken')
    expect(payload.selected_profile_model).toBe('profile_a')
    expect(payload.isAutoRetryUntilStop).toBe('1')
    expect(payload.cwd).toBe('/home/u/proj')

    expect(result.task).toEqual(fakeTask)
    expect(result.session).toEqual(fakeSession)
  })

  it("mode='create_and_run' failure surfaces a toast and returns { task: null, session: null } (no throw)", async () => {
    vi.spyOn(api, 'createKanbanTask').mockRejectedValue(new Error('boom'))
    const notifySpy = vi.spyOn(useNotificationStore(), 'notifyError')

    const store = useWorkspacesStore()
    const result = await store.addKanbanTask('ws_1', 'item_1', 'create_and_run', {
      name: 'Fix bug',
      queue_message: 'go',
    })

    expect(notifySpy).toHaveBeenCalled()
    expect(result.task).toBeNull()
    expect(result.session).toBeNull()
  })

  it("mode='create' failure RE-THROWS (no partial-success path)", async () => {
    vi.spyOn(api, 'createKanbanTask').mockRejectedValue(new Error('boom'))

    const store = useWorkspacesStore()
    await expect(
      store.addKanbanTask('ws_1', 'item_1', 'create', { name: 't' }),
    ).rejects.toThrow('boom')
  })

  // =====================================================================
  // mode='create_session' (plan: 2026-08-19-kanban-create-task-inits-session)
  // =====================================================================
  it("mode='create_session' calls api.createKanbanTask with mode='create_session' + selected_profile_model + returns session", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'Fix bug', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'Fix bug', status: 'idle' }
    const createSpy = vi
      .spyOn(api, 'createKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: fakeSession })

    const store = useWorkspacesStore()
    const result = await store.addKanbanTask('ws_1', 'item_1', 'create_session', {
      name: 'Fix bug',
      description: 'The login button is broken',
      tags: ['bug'],
      cwd: '/home/u/proj',
      isAutoRetryUntilStop: '1',
      selected_profile_model: 'fast',
    })

    expect(createSpy).toHaveBeenCalledTimes(1)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const [wid, iid, payload] = createSpy.mock.calls[0] as [string, string, any]
    expect(wid).toBe('ws_1')
    expect(iid).toBe('item_1')
    expect(payload.mode).toBe('create_session')
    expect(payload.name).toBe('Fix bug')
    expect(payload.description).toBe('The login button is broken')
    expect(payload.tags).toEqual(['bug'])
    expect(payload.cwd).toBe('/home/u/proj')
    expect(payload.isAutoRetryUntilStop).toBe('1')
    expect(payload.selected_profile_model).toBe('fast')
    // create_session must NOT include queue_message — no agent run
    expect(payload.queue_message).toBeUndefined()

    expect(result.task).toEqual(fakeTask)
    expect(result.session).toEqual(fakeSession)
  })

  it("mode='create_session' failure surfaces a toast and returns { task: null, session: null } (no throw)", async () => {
    vi.spyOn(api, 'createKanbanTask').mockRejectedValue(new Error('session insert failed'))
    const notifySpy = vi.spyOn(useNotificationStore(), 'notifyError')

    const store = useWorkspacesStore()
    const result = await store.addKanbanTask('ws_1', 'item_1', 'create_session', {
      name: 'Fix bug',
    })

    expect(notifySpy).toHaveBeenCalled()
    expect(result.task).toBeNull()
    expect(result.session).toBeNull()
  })
})
