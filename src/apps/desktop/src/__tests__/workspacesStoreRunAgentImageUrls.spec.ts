/** Tests for workspacesStore.runAgentOnNewTask — the imageUrls path (plan:
 * 2026-08-06-kanban-image-base64-in-chatview, replaces the earlier upload-then-URL plan
 * 2026-08-06-kanban-image-attach-in- chatview after the user directed to switch to direct
 * base64). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '@/stores/workspaces'
import * as api from '@/api'

describe('workspacesStore.runAgentOnNewTask — imageUrls forwarding', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('forwards imageUrls (base64 data URLs) to api.sendChatMessage when provided', async () => {
    // Real-world shape: the host converts each pendingFile.file to a
    // `data:<mime>;base64,<payload>` URL via FileReader.readAsDataURL,
    // collects them in upload order, and passes the array.
    const dataUrl1 =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    const dataUrl2 =
      'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwA/wD/2Q=='
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title\n\nBody',
      cwd: '/cwd',
      imageUrls: [dataUrl1, dataUrl2],
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title\n\nBody',
      '/cwd',
      [dataUrl1, dataUrl2],
      '',
      '',
    )
  })

  it('defaults imageUrls to undefined when not provided (back-compat)', async () => {
    // The existing runAgentOnNewTask contract passes `undefined` for imageUrls. After the fix,
    // callers that don't supply imageUrls should still work — the store should forward undefined to
    // the API, not an empty array (the API contract distinguishes).
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

  it('forwards empty imageUrls array as-is (not coerced to undefined)', async () => {
    // Edge case: caller explicitly passes []. The API may treat []
    // differently from undefined (zero attachments vs "no attachment
    // field"). Preserve the caller's intent.
    const sendSpy = vi
      .spyOn(api, 'sendChatMessage')
      .mockResolvedValue({ status: 'send' })
    const store = useWorkspacesStore()
    await store.runAgentOnNewTask('ws_1', 'item_1', 'task_abc', {
      queueMessage: 'Title',
      cwd: '/cwd',
      imageUrls: [],
    })
    expect(sendSpy).toHaveBeenCalledWith(
      'task_abc',
      'Title',
      '/cwd',
      [],
      '',
      '',
    )
  })
})
