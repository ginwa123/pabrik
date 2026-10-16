// Behavioural tests for addAgentKnowledge's `content` param (plan
// 2026-08-21-agent-knowledge-manual-text, Task 5). Mocking pattern: stub `global.fetch` — same
// approach as workspacesStoreUngroup.spec.ts.
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'

describe('addAgentKnowledge with content', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch touches useNotificationStore() on the error path —
    // give it an active Pinia (same pattern as kanbanStore.spec.ts).
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(body: unknown): void {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('sends content in the POST body when provided', async () => {
    mockFetchOnce({
      id: 'k1',
      agent_id: 'a1',
      file_path: '',
      label: 'L',
      content: 'text body',
      position: 0,
      created_at: '',
      updated_at: '',
    })
    await api.addAgentKnowledge('a1', '', 'L', 'text body')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/agents/a1/knowledge')
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      file_path: '',
      label: 'L',
      content: 'text body',
    })
  })

  it('sends empty content for file-backed adds (backward compat)', async () => {
    mockFetchOnce({
      id: 'k2',
      agent_id: 'a1',
      file_path: '/x.md',
      label: '',
      content: '',
      position: 0,
      created_at: '',
      updated_at: '',
    })
    await api.addAgentKnowledge('a1', '/x.md')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({
      file_path: '/x.md',
      label: '',
      content: '',
    })
  })
})
