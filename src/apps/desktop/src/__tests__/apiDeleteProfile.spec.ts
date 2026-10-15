/** Unit tests for the `api.deleteProfile` function. Mocks `global.fetch`
 * to assert URL, method, and error handling without hitting the
 * network. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { deleteProfile } from '../api'

describe('api.deleteProfile', () => {
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
    mockFetchOnce(200, { success: true, profile_name: 'my profile', active_profile_was_cleared: false })

    await deleteProfile('my profile')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/config/pabrik/profiles/my%20profile')
    expect(init.method).toBe('DELETE')
  })

  it('returns the parsed JSON on 200', async () => {
    mockFetchOnce(200, { success: true, profile_name: 'alpha', active_profile_was_cleared: true })

    const result = await deleteProfile('alpha')

    expect(result).toEqual({ success: true, profile_name: 'alpha', active_profile_was_cleared: true })
  })

  it('throws an Error with the HTTP status on non-2xx', async () => {
    mockFetchOnce(404, { success: false, profile_name: 'ghost', error_message: 'Profile not found' })

    await expect(deleteProfile('ghost')).rejects.toThrow(/HTTP 404/)
  })

  it('encodes special characters in the profile name', async () => {
    mockFetchOnce(200, { success: true, profile_name: 'a/b+c', active_profile_was_cleared: false })

    await deleteProfile('a/b+c')

    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    // encodeURIComponent produces 'a%2Fb%2Bc' for this input
    expect(url).toContain('/api/config/pabrik/profiles/a%2Fb%2Bc')
  })
})
