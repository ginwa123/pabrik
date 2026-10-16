/** Tests for useRecentFolders — Pinia store backing the FilePickerDialog's Recent tab. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useRecentFoldersStore } from '../stores/recentFolders'
import { makeLocalStorageStub } from './helpers'

describe('useRecentFoldersStore — basics', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('starts empty when localStorage is empty', () => {
    const store = useRecentFoldersStore()
    expect(store.list()).toEqual([])
  })

  it('hydrates from localStorage on first read', () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: 1000, pinned: true },
        { path: '/home/me/b', lastUsedAt: 500, pinned: false },
      ]),
    )
    const store = useRecentFoldersStore()
    const list = store.list()
    expect(list).toHaveLength(2)
    // Pinned first.
    expect(list[0]!.path).toBe('/home/me/a')
    expect(list[1]!.path).toBe('/home/me/b')
  })

  it('addRecent appends a new path with the current timestamp', () => {
    const store = useRecentFoldersStore()
    const now = 1_700_000_000_000
    vi.spyOn(Date, 'now').mockReturnValue(now)
    store.addRecent('/home/me/foo')
    expect(store.list()).toEqual([
      { path: '/home/me/foo', lastUsedAt: now, pinned: false },
    ])
  })

  it('addRecent with an existing path DEDUPES (bumps lastUsedAt, keeps pin)', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    vi.spyOn(Date, 'now').mockReturnValue(2_000_000_000_000)
    store.addRecent('/home/me/foo')
    const list = store.list()
    expect(list).toHaveLength(1)
    expect(list[0]!.lastUsedAt).toBe(2_000_000_000_000)
  })

  it('addRecent preserves the pinned flag across re-inserts', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    store.togglePin('/home/me/foo')
    expect(store.list()[0]!.pinned).toBe(true)
    store.addRecent('/home/me/foo')
    expect(store.list()[0]!.pinned).toBe(true)
  })

  it('addRecent caps to 12 entries; non-pinned entries are evicted first', () => {
    const store = useRecentFoldersStore()
    let t = 1_000_000_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => {
      t += 1
      return t
    })
    for (let i = 0; i < 15; i++) {
      store.addRecent(`/home/me/folder-${i}`)
    }
    expect(store.list()).toHaveLength(12)
    // The first 3 (folder-0, folder-1, folder-2) were evicted because they
    // were the OLDEST non-pinned entries. The most recent 12 remain.
    const paths = store.list().map((e) => e.path)
    expect(paths).not.toContain('/home/me/folder-0')
    expect(paths).not.toContain('/home/me/folder-1')
    expect(paths).not.toContain('/home/me/folder-2')
    expect(paths).toContain('/home/me/folder-14')
  })

  it('addRecent does NOT evict pinned entries when over the cap', () => {
    const store = useRecentFoldersStore()
    let t = 1_000_000_000_000
    vi.spyOn(Date, 'now').mockImplementation(() => {
      t += 1
      return t
    })
    // Pin the first 5.
    for (let i = 0; i < 5; i++) {
      store.addRecent(`/home/me/pinned-${i}`)
    }
    for (let i = 0; i < 5; i++) {
      store.togglePin(`/home/me/pinned-${i}`)
    }
    // Add 15 more.
    for (let i = 0; i < 15; i++) {
      store.addRecent(`/home/me/recent-${i}`)
    }
    const list = store.list()
    // All 5 pinned entries survive.
    const pinnedPaths = list.filter((e) => e.pinned).map((e) => e.path)
    expect(pinnedPaths).toHaveLength(5)
    expect(pinnedPaths).toEqual(
      expect.arrayContaining([
        '/home/me/pinned-0',
        '/home/me/pinned-1',
        '/home/me/pinned-2',
        '/home/me/pinned-3',
        '/home/me/pinned-4',
      ]),
    )
    // Total ≤ 12 (5 pinned + 7 recent at most).
    expect(list.length).toBeLessThanOrEqual(12)
  })

  it('togglePin flips the pinned flag and re-sorts the list', () => {
    const store = useRecentFoldersStore()
    // Force foo's lastUsedAt to be strictly older than bar's so the
    // `lastUsedAt desc` tiebreaker is deterministic.
    vi.spyOn(Date, 'now')
      .mockReturnValueOnce(1_000_000_000_000) // foo
      .mockReturnValueOnce(2_000_000_000_000) // bar
    store.addRecent('/home/me/foo')
    store.addRecent('/home/me/bar')
    // Sanity: before pinning, bar (most recent) is first.
    expect(store.list()[0]!.path).toBe('/home/me/bar')
    store.togglePin('/home/me/foo')
    expect(store.list()[0]!.path).toBe('/home/me/foo') // pinned first
    expect(store.list()[0]!.pinned).toBe(true)
    store.togglePin('/home/me/foo')
    // Unpinned: bar (most recent) is first again.
    expect(store.list()[0]!.path).toBe('/home/me/bar')
    expect(store.list()[0]!.pinned).toBe(false)
  })

  it('removeRecent removes the entry from the list', () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    store.addRecent('/home/me/bar')
    store.removeRecent('/home/me/foo')
    expect(store.list()).toHaveLength(1)
    expect(store.list()[0]!.path).toBe('/home/me/bar')
  })

  it('writes to localStorage on every mutation (debounced 200ms)', async () => {
    const store = useRecentFoldersStore()
    store.addRecent('/home/me/foo')
    // localStorage write is debounced 200ms — wait for the timer.
    await new Promise((r) => setTimeout(r, 250))
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    expect(raw).not.toBeNull()
    const entries = JSON.parse(raw!)
    expect(entries).toEqual([
      { path: '/home/me/foo', lastUsedAt: expect.any(Number), pinned: false },
    ])
  })

  it('silently swallows localStorage write errors (quota / private mode)', () => {
    const store = useRecentFoldersStore()
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })
    // The mutation should NOT throw.
    expect(() => store.addRecent('/home/me/foo')).not.toThrow()
    // The in-memory state is still updated.
    expect(store.list()).toHaveLength(1)
  })
})
