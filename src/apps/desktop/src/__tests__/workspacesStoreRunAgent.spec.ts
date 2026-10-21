/** Tests for workspacesStore.runAgentOnNewTask — the store action that wraps api.sendChatMessage
 * for the kanban "Create task & run agent" flow./ Step 1.1 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import * as api from '@/api'

describe('workspacesStore.runAgentOnNewTask', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('forwards queueMessage, cwd, and isAutoRetryUntilStop to api.sendChatMessage', async () => {
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    const result = await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title\n\nBody',
      cwd: '/home/u/project',
      isAutoRetryUntilStop: '1',
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title\n\nBody',
      '/home/u/project',
      undefined,
      '',
      '1',
    )
    expect(result).toEqual({ status: 'send' })
  })

  it('forwards empty string when isAutoRetryUntilStop is undefined', async () => {
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title',
      cwd: '/cwd',
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title',
      '/cwd',
      undefined,
      '',
      '',
    )
  })

  it('returns undefined when api.sendChatMessage throws', async () => {
    vi.spyOn(api, 'sendChatMessage').mockRejectedValue(new Error('network down'))
    const store = useWorkspacesStore()
    const result = await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'msg',
      cwd: '/cwd',
    })
    expect(result).toBeUndefined()
  })

  // NEW (plan: 2026-08-06-kanban-task-profile-selector)
  it('forwards selectedProfile to api.sendChatMessage when provided', async () => {
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title',
      cwd: '/cwd',
      selectedAgent: '900r1bu',
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title',
      '/cwd',
      undefined,
      '900r1bu',
      '',
    )
  })

  // NEW (plan: 2026-08-06-kanban-task-profile-selector)
  it('forwards empty string when selectedProfile is undefined', async () => {
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title',
      cwd: '/cwd',
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title',
      '/cwd',
      undefined,
      '',
      '',
    )
  })
})
