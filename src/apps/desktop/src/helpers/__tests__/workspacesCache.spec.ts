/** Behavioural tests for the cached `GET /api/workspaces?is_include_items=false` client. */
import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  clearWorkspacesCache,
  readWorkspacesCache,
  workspacesCacheKey,
  writeWorkspacesCache,
} from '../workspacesCache'

// jsdom in this project's Vitest does not reliably provide localStorage
// (same guard as gitStatusCache.spec.ts / authMe.spec.ts).
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

function ws(id: string, name: string, items_count = 3) {
  return { id, name, icon: '📁', items: [], items_count, expanded: false } as never
}

describe('workspacesCache', () => {
  beforeEach(() => {
    ensureLocalStorage()
    localStorage.clear()
  })

  it('misses on cold boot and round-trips a written list', () => {
    expect(readWorkspacesCache()).toBeNull()
    writeWorkspacesCache([ws('ws_1', 'One'), ws('ws_2', 'Two', 0)])
    const cached = readWorkspacesCache()
    expect(cached?.map((w) => w.id)).toEqual(['ws_1', 'ws_2'])
    expect(cached?.[0]?.items).toEqual([])
    expect(cached?.[0]?.items_count).toBe(3)
  })

  it('rejects corrupt payloads instead of rendering them', () => {
    localStorage.setItem(workspacesCacheKey(), 'not-json{')
    expect(readWorkspacesCache()).toBeNull()
    localStorage.setItem(workspacesCacheKey(), JSON.stringify({ workspaces: [] }))
    expect(readWorkspacesCache()).toBeNull()
    localStorage.setItem(workspacesCacheKey(), JSON.stringify([{ name: 'no-id' }]))
    expect(readWorkspacesCache()).toBeNull()
  })

  it('never owns UI state: expanded/items reset to defaults', () => {
    writeWorkspacesCache([
      { id: 'ws_1', name: 'One', icon: '📁', items: [{ id: 'x' }], expanded: true } as never,
    ])
    const cached = readWorkspacesCache()
    expect(cached?.[0]?.expanded).toBe(false)
    expect(cached?.[0]?.items).toEqual([])
  })

  it('clear drops the entry', () => {
    writeWorkspacesCache([ws('ws_1', 'One')])
    expect(readWorkspacesCache()).not.toBeNull()
    clearWorkspacesCache()
    expect(readWorkspacesCache()).toBeNull()
  })
})
