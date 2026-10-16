/** Tests for getGitStatus's cache-first contract. Contract: 1. A successful fetch writes the
 * response to the per-cwd cache (so the NEXT init can paint it before the network round-trip). 2. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { getGitStatus, type GitStatus } from '@/api/index'
import { readGitStatusCache, clearGitStatusCache } from '@/helpers/gitStatusCache'

const CWD = '/tmp/git-status-spec'

const WIRE: GitStatus = {
  is_git_repo: true,
  branch: 'main',
  has_changes: false,
  is_clean: true,
  current: 'main',
  status: 'clean',
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

// jsdom here does not reliably provide localStorage — same guard as
// the helper's own spec.
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

describe('getGitStatus caching', () => {
  beforeEach(() => {
    ensureLocalStorage()
    localStorage.clear()
    // Silence the error-toast path (apiFetch → notifyError) in the
    // failure tests; the notifications store needs no pinia here but
    // the console noise obscures real failures.
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(() => {
    clearGitStatusCache(CWD)
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('writes the response to the per-cwd cache on success', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse(WIRE)),
    )

    const result = await getGitStatus(CWD)
    expect(result).toEqual(WIRE)
    expect(readGitStatusCache(CWD)).toEqual(WIRE)
  })

  it('falls back to the cached status when the fetch fails', async () => {
    // Seed the cache as a previous successful fetch would have.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse(WIRE)),
    )
    await getGitStatus(CWD)

    // Now the backend goes down.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new Error('backend down')
      }),
    )
    const stale = await getGitStatus(CWD)
    expect(stale).toEqual(WIRE)
  })

  it('returns the empty non-repo error fallback when there is no cache', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new Error('backend down')
      }),
    )
    const fallback = await getGitStatus(CWD)
    expect(fallback).toEqual({
      is_git_repo: false,
      branch: '',
      has_changes: false,
      is_clean: true,
      current: '',
      status: 'error',
    })
    // The synthetic fallback must NOT poison the cache — otherwise the
    // next init would paint `status:'error'` over a real branch.
    expect(readGitStatusCache(CWD)).toBeNull()
  })

  it('does not cache a non-2xx response body', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'boom' }, 500)),
    )
    await getGitStatus(CWD)
    expect(readGitStatusCache(CWD)).toBeNull()
  })
})
