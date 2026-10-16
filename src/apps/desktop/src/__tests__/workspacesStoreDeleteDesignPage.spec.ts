/** Unit tests for workspacesStore.deleteDesignPage. 4 tests: 1. Calls api.deleteDesignPage with the
 * same workspaceId/itemId/pageId. 2. Clears activeDesignPageId when the deleted page was the active
 * one. 3. Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md (Chunk 4) */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import { useWorkspacesStore } from '../stores/workspaces'

describe('workspacesStore.deleteDesignPage', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch calls useNotificationStore() on every non-2xx response to
    // fire an error toast. Without an active Pinia the call throws.
    // (See project memory apiFetch-mock-must-include-text-and-pinia.)
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown): void {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('calls api.deleteDesignPage with the same workspaceId/itemId/pageId', async () => {
    mockFetchOnce(200, { success: true })

    const store = useWorkspacesStore()
    await store.deleteDesignPage('ws_1', 'item_1', 'p1')

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1')
    expect(init.method).toBe('DELETE')
  })

  it('clears activeDesignPageId when the deleted page was the active one', async () => {
    mockFetchOnce(200, { success: true })

    const store = useWorkspacesStore()
    store.setActiveDesignPage('p1')
    expect(store.activeDesignPageId).toBe('p1')

    await store.deleteDesignPage('ws_1', 'item_1', 'p1')
    expect(store.activeDesignPageId).toBe('')
  })

  it('leaves activeDesignPageId alone when a different page was active', async () => {
    mockFetchOnce(200, { success: true })

    const store = useWorkspacesStore()
    store.setActiveDesignPage('p2')

    await store.deleteDesignPage('ws_1', 'item_1', 'p1')
    // Different page was active — should not be cleared.
    expect(store.activeDesignPageId).toBe('p2')
  })

  it('propagates 5xx errors so the composable can surface them via notification', async () => {
    mockFetchOnce(500, { error: 'DB write failed' })

    const store = useWorkspacesStore()
    await expect(
      store.deleteDesignPage('ws_1', 'item_1', 'p1'),
    ).rejects.toMatchObject({ status: 500 })
  })
})
