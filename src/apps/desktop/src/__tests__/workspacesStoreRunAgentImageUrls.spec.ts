/**
 * Tests for workspacesStore.runAgentOnNewTask — the imageUrls path
 * (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces the
 * earlier upload-then-URL plan 2026-08-06-kanban-image-attach-in-
 * chatview after the user directed to switch to direct base64).
 *
 * Bug (pre-fix, original): the user creates a kanban task with the
 * "Create task & run agent" button after pasting an image into the
 * description. The chat view's user-message template (ChatView.vue
 * line ~2062) renders `image_urls` from the message as clickable
 * thumbnails above the text content, but `runAgentOnNewTask`
 * hardcoded `imageUrls = undefined` when forwarding to
 * `api.sendChatMessage`. The chat view had nothing to render.
 *
 * First fix (reverted): upload each pending image, store the URLs in
 * the description as `![name](url)`, then forward the uploaded URLs
 * to runAgentOnNewTask. Reverted because:
 *   (a) the GET endpoint's wildcard route was broken (separate bug).
 *   (b) the user preferred the simpler design: no upload, no URL in
 *       description, just pass base64 data URLs directly to the chat
 *       message's image_urls field.
 *
 * Fix contract (two pieces):
 *   1. (this file) runAgentOnNewTask accepts an optional `imageUrls`
 *      param (string[] of data: URLs) and forwards it to
 *      api.sendChatMessage. Back-compat: when omitted, store still
 *      passes `undefined` (NOT `[]`) — the API contract
 *      distinguishes.
 *   2. (KanbanView.createWithAttachments.spec.ts) KanbanView's
 *      handleCreateTaskSave converts each pendingFile.file to a base64
 *      data URL (via FileReader.readAsDataURL) and passes the array
 *      as imageUrls when invoking runAgentOnNewTask. NO upload, NO
 *      description patch with URLs.
 */
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
