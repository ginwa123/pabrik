/** Behavioural tests for the cached `/api/auth/me` client. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { clearAuthMeCache, fetchAuthMeLive, getAuthMeCached, invalidateAuthMe } from '../authMe'

// jsdom in this project's Vitest does not reliably provide localStorage
// (same guard as gitStatusCache.spec.ts).
function ensureLocalStorage(): void {
  if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
    const store: Record<string, string> = {}
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v)
      },
      removeItem: (k: string) => {
        delete store[k]
      },
      clear: () => {
        for (const k in store) delete store[k]
      },
      key: () => null,
      length: 0,
    } as Storage)
  }
}

function okResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response
}

describe('authMe', () => {
  beforeEach(() => {
    ensureLocalStorage()
    localStorage.clear()
    invalidateAuthMe()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    invalidateAuthMe()
  })

  it('cold fetch hits the network and caches the result', async () => {
    const fetchMock = vi.fn(async () => okResponse({ authenticated: true, auth_enabled: true }))
    vi.stubGlobal('fetch', fetchMock)

    const first = await getAuthMeCached()
    expect(first.fromCache).toBe(false)
    expect(first.status).toBe(200)
    expect(first.data?.authenticated).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)

    const second = await getAuthMeCached()
    expect(second.fromCache).toBe(true)
    expect(second.data?.authenticated).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('shares one live fetch across concurrent callers', async () => {
    let resolveFetch!: (r: Response) => void
    const fetchMock = vi.fn(() => new Promise<Response>((resolve) => void (resolveFetch = resolve)))
    vi.stubGlobal('fetch', fetchMock)

    const p1 = getAuthMeCached()
    const p2 = getAuthMeCached()
    resolveFetch(okResponse({ authenticated: false, auth_enabled: false }))
    const [r1, r2] = await Promise.all([p1, p2])
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(r1.data?.auth_enabled).toBe(false)
    expect(r2.data?.auth_enabled).toBe(false)
  })

  it('serves stale cache instantly while revalidating in the background', async () => {
    const fetchMock = vi.fn(async () => okResponse({ authenticated: true, auth_enabled: true }))
    vi.stubGlobal('fetch', fetchMock)
    await getAuthMeCached()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    // Age the entry past the 30s TTL.
    const raw = localStorage.getItem('pabrik-auth-me:v1')
    expect(raw).not.toBeNull()
    const entry = JSON.parse(raw as string) as { at: number }
    entry.at = Date.now() - 60_000
    localStorage.setItem('pabrik-auth-me:v1', JSON.stringify(entry))

    fetchMock.mockImplementation(async () =>
      okResponse({ authenticated: false, auth_enabled: true }),
    )
    const stale = await getAuthMeCached()
    expect(stale.fromCache).toBe(true)
    expect(stale.data?.authenticated).toBe(true)

    // Background revalidate writes the fresh body.
    await vi.waitFor(() => {
      const next = JSON.parse(localStorage.getItem('pabrik-auth-me:v1') as string) as {
        data: { authenticated: boolean }
      }
      expect(next.data.authenticated).toBe(false)
    })
  })

  it('network failure never throws and preserves stale cache', async () => {
    const fetchMock = vi.fn(async () => okResponse({ authenticated: true, auth_enabled: true }))
    vi.stubGlobal('fetch', fetchMock)
    await getAuthMeCached()

    fetchMock.mockRejectedValue(new Error('offline'))
    invalidateAuthMe()
    // Cold + offline: status 0, null data — the guard renders anyway.
    const cold = await getAuthMeCached()
    expect(cold.status).toBe(0)
    expect(cold.data).toBeNull()
  })

  it('invalidate forces the next call to hit the network', async () => {
    const fetchMock = vi.fn(async () => okResponse({ authenticated: true, auth_enabled: true }))
    vi.stubGlobal('fetch', fetchMock)
    await getAuthMeCached()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    invalidateAuthMe()
    await getAuthMeCached()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('fetchAuthMeLive maps 401 to status with null data', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => okResponse({ error: 'Unauthenticated' }, 401)),
    )
    const r = await fetchAuthMeLive()
    expect(r.status).toBe(401)
    expect(r.data).toBeNull()
    expect(r.fromCache).toBe(false)
  })

  it('rejects corrupt cached entries instead of serving them', async () => {
    localStorage.setItem('pabrik-auth-me:v1', '{not json')
    const fetchMock = vi.fn(async () => okResponse({ authenticated: false, auth_enabled: false }))
    vi.stubGlobal('fetch', fetchMock)
    const r = await getAuthMeCached()
    expect(r.fromCache).toBe(false)
    expect(r.data?.auth_enabled).toBe(false)
  })

  it('clearAuthMeCache drops the entry without breaking the next fetch', async () => {
    const fetchMock = vi.fn(async () => okResponse({ authenticated: false, auth_enabled: false }))
    vi.stubGlobal('fetch', fetchMock)
    await getAuthMeCached()
    clearAuthMeCache()
    const r = await getAuthMeCached()
    expect(r.fromCache).toBe(false)
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
})
