/** Behavioural tests for `useDesignHistoryStore` (Pinia). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useDesignHistoryStore } from '../stores/designHistory'

function stubLocalStorage() {
  const map = new Map<string, string>()
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => {
      map.set(k, v)
    },
    removeItem: (k: string) => {
      map.delete(k)
    },
    clear: () => map.clear(),
    key: (i: number) => Array.from(map.keys())[i] ?? null,
    get length() {
      return map.size
    },
  })
}

describe('useDesignHistoryStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    stubLocalStorage()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('getStack(unknown page) returns empty past + future (no error)', () => {
    const store = useDesignHistoryStore()
    const stack = store.getStack('page_unknown')
    expect(stack.past).toEqual([])
    expect(stack.future).toEqual([])
  })

  it('push to a new page creates the stack and persists the entry', () => {
    const store = useDesignHistoryStore()
    store.push('page_1', {
      id: 'entry_1',
      timestamp: Date.now(),
      label: 'Test',
      pageId: 'page_1',
      kind: 'update',
    })
    const stack = store.getStack('page_1')
    expect(stack.past.length).toBe(1)
    expect(stack.past[0]!.id).toBe('entry_1')
  })

  it('clearPage removes both past and future for that page', () => {
    const store = useDesignHistoryStore()
    store.push('page_1', {
      id: 'e1',
      timestamp: 0,
      label: 'A',
      pageId: 'page_1',
      kind: 'update',
    })
    store.push('page_1', {
      id: 'e2',
      timestamp: 0,
      label: 'B',
      pageId: 'page_1',
      kind: 'update',
    })
    // Move one entry to future manually (the public popPast API does
    // not push to future; only the composable's undo() does that).
    const popped = store.popPast('page_1')
    if (popped) store.getStack('page_1').future.push(popped)
    expect(store.getStack('page_1').future.length).toBe(1)
    store.clearPage('page_1')
    expect(store.getStack('page_1').past).toEqual([])
    expect(store.getStack('page_1').future).toEqual([])
  })

  it('localStorage round-trip: saveToStorage + loadAndApply restores the stack', () => {
    const store = useDesignHistoryStore()
    store.push('page_1', {
      id: 'entry_persisted',
      timestamp: 1234567890,
      label: 'Persisted entry',
      pageId: 'page_1',
      kind: 'update',
    })
    const stack = store.getStack('page_1')
    store.saveToStorage('ws_1', 'item_1', 'page_1', stack)

    const raw = localStorage.getItem(store.storageKey('ws_1', 'item_1', 'page_1'))
    expect(raw).not.toBeNull()
    expect(raw).toContain('entry_persisted')

    store.clearAll()
    expect(store.getStack('page_1').past).toEqual([])
    store.loadAndApply('ws_1', 'item_1', 'page_1')
    expect(store.getStack('page_1').past.length).toBe(1)
    expect(store.getStack('page_1').past[0]!.id).toBe('entry_persisted')
  })

  it('localStorage key format: design-history:v1:<workspaceId>:<itemId>:<pageId>', () => {
    const store = useDesignHistoryStore()
    store.saveToStorage('ws_test', 'item_test', 'page_test', {
      past: [],
      future: [],
    })
    expect(
      localStorage.getItem('design-history:v1:ws_test:item_test:page_test'),
    ).not.toBeNull()
  })

  it('schema version mismatch: silently discards old format', () => {
    const store = useDesignHistoryStore()
    localStorage.setItem(
      'design-history:v0:ws_1:item_1:page_1',
      JSON.stringify({
        past: [{ id: 'stale', kind: 'update', label: 'Old' }],
        future: [],
      }),
    )
    store.loadAndApply('ws_1', 'item_1', 'page_1')
    expect(store.getStack('page_1').past).toEqual([])
  })
})