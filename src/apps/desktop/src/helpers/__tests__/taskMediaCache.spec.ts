/** Behavioural tests for the local task-media cache (stale-while-revalidate).
 * Contract: flagged cards paint the last-known thumbnail instantly (no
 * TTL — a stale thumb beats the badge), the background GET revalidates
 * behind it, corrupt entries never paint, oversized payloads are skipped,
 * and storage failures degrade to a miss without throwing. */
import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  clearTaskMediaCache,
  readTaskMediaCache,
  resetTaskMediaCacheMemo,
  taskMediaCacheKey,
  writeTaskMediaCache,
} from '../taskMediaCache'

// jsdom in this project's Vitest does not reliably provide localStorage
// (same guard as workspacesCache.spec.ts).
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

const IMG = 'data:image/png;base64,AAA'
const IMG2 = 'data:image/png;base64,BBB'

describe('taskMediaCache', () => {
  beforeEach(() => {
    ensureLocalStorage()
    localStorage.clear()
    clearTaskMediaCache()
  })

  it('misses on cold boot and round-trips a written entry', () => {
    expect(readTaskMediaCache('task_1')).toBeNull()
    writeTaskMediaCache('task_1', { imageUrls: [IMG], videoUrls: [] })
    expect(readTaskMediaCache('task_1')).toEqual({ imageUrls: [IMG], videoUrls: [] })
  })

  it('rejects corrupt payloads instead of painting them', () => {
    // resetTaskMediaCacheMemo (not clear) between stages — clear drops
    // the staged blob too, and the memo would otherwise pin step 1's parse.
    localStorage.setItem(taskMediaCacheKey(), 'not-json{')
    resetTaskMediaCacheMemo()
    expect(readTaskMediaCache('task_1')).toBeNull()
    localStorage.setItem(taskMediaCacheKey(), JSON.stringify({ task_1: { imageUrls: 'nope' } }))
    resetTaskMediaCacheMemo()
    expect(readTaskMediaCache('task_1')).toBeNull()
    localStorage.setItem(
      taskMediaCacheKey(),
      JSON.stringify({ task_1: { imageUrls: [], videoUrls: [] } }),
    )
    resetTaskMediaCacheMemo()
    expect(readTaskMediaCache('task_1')).toBeNull()
  })

  it('filters non-string urls but keeps the paintable rest', () => {
    localStorage.setItem(
      taskMediaCacheKey(),
      JSON.stringify({ task_1: { imageUrls: [IMG, 42, ''], videoUrls: [] } }),
    )
    expect(readTaskMediaCache('task_1')).toEqual({ imageUrls: [IMG], videoUrls: [] })
  })

  it('latest write wins per task', () => {
    writeTaskMediaCache('task_1', { imageUrls: [IMG], videoUrls: [] })
    writeTaskMediaCache('task_1', { imageUrls: [IMG2], videoUrls: [] })
    expect(readTaskMediaCache('task_1')).toEqual({ imageUrls: [IMG2], videoUrls: [] })
  })

  it('storage failures degrade without throwing (memo still serves the session)', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => null,
      setItem: () => {
        throw new Error('quota')
      },
      removeItem: () => {
        throw new Error('private mode')
      },
      clear: () => {},
      key: () => null,
      length: 0,
    } as Storage)
    clearTaskMediaCache() // drop the memo so the failing store is exercised
    expect(() => writeTaskMediaCache('task_1', { imageUrls: [IMG], videoUrls: [] })).not.toThrow()
    // The memo write-through still serves the session even when the
    // backing store dies (a post-reload memo would miss, correctly).
    expect(readTaskMediaCache('task_1')).toEqual({ imageUrls: [IMG], videoUrls: [] })
    vi.unstubAllGlobals()
  })

  it('clear drops the entry', () => {
    writeTaskMediaCache('task_1', { imageUrls: [IMG], videoUrls: [] })
    expect(readTaskMediaCache('task_1')).not.toBeNull()
    clearTaskMediaCache()
    expect(readTaskMediaCache('task_1')).toBeNull()
  })
})
