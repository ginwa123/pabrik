/** Tests for api.createKanbanTask — POST /api/workspaces/:wid/items/:iid/kanban/tasks with
 * mode='create' | mode='create_and_run' discriminator. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { createKanbanTask } from '../api'

describe('api.createKanbanTask', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    global.fetch = fetchMock
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it("POSTs to /workspaces/:wid/items/:iid/kanban/tasks with mode='create' + JSON body", async () => {
    const fakeTask = {
      id: 'task_new',
      name: 'Fix bug',
      task_type: 'standard',
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
    mockFetchOnce(201, { task: fakeTask, session: null })

    const response = await createKanbanTask('ws_1', 'item_1', {
      mode: 'create',
      name: 'Fix bug',
      description: 'The login button is broken',
      tags: ['bug'],
      imageUrls: ['data:image/png;base64,iVBORw0KG'],
      cwd: '/home/u/proj',
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/workspaces/ws_1/items/item_1/kanban/tasks')
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body.mode).toBe('create')
    expect(body.name).toBe('Fix bug')
    expect(body.description).toBe('The login button is broken')
    expect(body.tags).toBe(JSON.stringify(['bug']))
    expect(body.image_urls).toBe('data:image/png;base64,iVBORw0KG')
    expect(body.cwd).toBe('/home/u/proj')

    expect(response.task).toEqual(fakeTask)
    expect(response.session).toBeNull()
  })

   
  it("includes queue_message in body when mode='create_and_run'", async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'Fix bug', task_type: 'standard' } as any
    const fakeSession = { id: 'task_new', name: 'Fix bug', status: 'send' }
    mockFetchOnce(201, { task: fakeTask, session: fakeSession })

    const response = await createKanbanTask('ws_1', 'item_1', {
      mode: 'create_and_run',
      name: 'Fix bug',
      queue_message: 'Fix the login button',
      selected_profile_model: 'profile_a',
    })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.mode).toBe('create_and_run')
    expect(body.queue_message).toBe('Fix the login button')
    expect(body.selected_profile_model).toBe('profile_a')

    expect(response.task).toEqual(fakeTask)
    expect(response.session).toEqual(fakeSession)
  })

  it('omits queue_message + selected_profile_model from body when mode=create', async () => {
    mockFetchOnce(201, { task: { id: 'task_x' }, session: null })

    await createKanbanTask('ws_1', 'item_1', {
      mode: 'create',
      name: 't',
    })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.queue_message).toBeUndefined()
    expect(body.selected_profile_model).toBeUndefined()
  })

  it('propagates non-2xx as a thrown ApiError', async () => {
    mockFetchOnce(404, { error: 'Workspace item not found or is not a kanban' })

    // The apiFetch wrapper bubbles the server message via the notification store; the rejected
    // ApiError carries the HTTP status. The 404 IS what we care about — the server correctly
    // rejected because the parent item is not a kanban.
    await expect(
      createKanbanTask('ws_x', 'i_x', { mode: 'create', name: 't' }),
    ).rejects.toThrow(/HTTP 404/)
  })

  // =====================================================================
  // mode='create_session' (plan: 2026-08-19-kanban-create-task-inits-session)
  // =====================================================================
  it("POSTs with mode='create_session' + selected_profile_model + NO queue_message", async () => {
    const fakeTask = {
      id: 'task_new',
      name: 'Fix bug',
      task_type: 'standard',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
    const fakeSession = { id: 'task_new', name: 'Fix bug', status: 'idle' }
    mockFetchOnce(201, { task: fakeTask, session: fakeSession })

    const response = await createKanbanTask('ws_1', 'item_1', {
      mode: 'create_session',
      name: 'Fix bug',
      description: 'The login button is broken',
      tags: ['bug'],
      cwd: '/home/u/proj',
      isAutoRetryUntilStop: '1',
      selected_profile_model: 'fast',
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/workspaces/ws_1/items/item_1/kanban/tasks')
    const body = JSON.parse(init.body as string)
    expect(body.mode).toBe('create_session')
    expect(body.name).toBe('Fix bug')
    expect(body.description).toBe('The login button is broken')
    expect(body.tags).toBe(JSON.stringify(['bug']))
    expect(body.cwd).toBe('/home/u/proj')
    expect(body.is_auto_retry_until_stop).toBe('1')
    expect(body.selected_profile_model).toBe('fast')
    // Critical: create_session must NOT include queue_message — no agent run on this path. The
    // backend would 400 with "queue_message is required when mode='create_and_run'" if the wrong
    // mode ever sent one, so the frontend MUST omit it.
    expect(body.queue_message).toBeUndefined()

    expect(response.task).toEqual(fakeTask)
    expect(response.session).toEqual(fakeSession)
  })

  it("returns session.status='idle' for create_session", async () => {
    const fakeTask = {
      id: 'task_1',
      name: 't',
      task_type: 'standard',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
    const fakeSession = { id: 'task_1', name: 't', status: 'idle' }
    mockFetchOnce(201, { task: fakeTask, session: fakeSession })

    const response = await createKanbanTask('ws_1', 'item_1', {
      mode: 'create_session',
      name: 't',
    })

    expect(response.session).toEqual({
      id: 'task_1',
      name: 't',
      status: 'idle',
    })
  })
})
