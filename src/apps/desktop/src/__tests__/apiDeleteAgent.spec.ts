/** Unit tests for the `api.deleteAgent` function. Mocks `global.fetch`
 * to assert URL, method, and error handling without hitting the
 * network. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { deleteAgent } from '../api'

describe('api.deleteAgent', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
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
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('calls DELETE on /api/config/pabrik/profiles/:name with URL-encoded name', async () => {
    mockFetchOnce(200, { success: true, agent_name: 'my agent', active_agent_was_cleared: false })

    await deleteAgent('my agent')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/config/pabrik/profiles/my%20agent')
    expect(init.method).toBe('DELETE')
  })

  it('returns the parsed JSON on 200', async () => {
    mockFetchOnce(200, { success: true, agent_name: 'alpha', active_agent_was_cleared: true })

    const result = await deleteAgent('alpha')

    expect(result).toEqual({ success: true, agent_name: 'alpha', active_agent_was_cleared: true })
  })

  it('throws an Error with the HTTP status on non-2xx', async () => {
    mockFetchOnce(404, { success: false, agent_name: 'ghost', error_message: 'Agent not found' })

    await expect(deleteAgent('ghost')).rejects.toThrow(/HTTP 404/)
  })

  it('encodes special characters in the agent name', async () => {
    mockFetchOnce(200, { success: true, agent_name: 'a/b+c', active_agent_was_cleared: false })

    await deleteAgent('a/b+c')

    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    // encodeURIComponent produces 'a%2Fb%2Bc' for this input
    expect(url).toContain('/api/config/pabrik/profiles/a%2Fb%2Bc')
  })
})
