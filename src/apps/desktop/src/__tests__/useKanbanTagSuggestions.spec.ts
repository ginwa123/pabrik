import { describe, it, expect, beforeEach, vi } from 'vitest'
import { ref } from 'vue'
import { useKanbanTagSuggestions } from '../composables/useKanbanTagSuggestions'
import * as api from '../api'

describe('useKanbanTagSuggestions', () => {
  beforeEach(() => {
    vi.resetAllMocks()
  })

  it('ensureLoaded() fetches the first page via the API', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'bug', count: 3, last_used_at: null }],
      has_more: true,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
    expect(c.tags.value).toHaveLength(1)
    expect(c.hasMore.value).toBe(true)
    expect(c.loaded.value).toBe(true)
  })

  it('loadNextPage() appends the next page when has_more was true', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions')
      .mockResolvedValueOnce({
        tags: [{ name: 'a', count: 1, last_used_at: null }],
        has_more: true,
      })
      .mockResolvedValueOnce({
        tags: [{ name: 'b', count: 1, last_used_at: null }],
        has_more: false,
      })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
    expect(api.getKanbanTagSuggestions).toHaveBeenNthCalledWith(2, 'ws_x', 'item_x', { limit: 8, offset: 8 })
    expect(c.tags.value).toHaveLength(2)
    expect(c.tags.value[0]!.name).toBe('a')
    expect(c.tags.value[1]!.name).toBe('b')
    expect(c.hasMore.value).toBe(false)
  })

  it('loadNextPage() is a no-op when has_more is false (no extra fetch)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.loadNextPage()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('loadNextPage() is a no-op while another loadNextPage is in flight (no double-fetch)', async () => {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let resolveFirst!: (v: any) => void
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let resolveSecond!: (v: any) => void
     
    vi.spyOn(api, 'getKanbanTagSuggestions')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockReturnValueOnce(new Promise((r) => { resolveFirst = r }) as any)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockReturnValueOnce(new Promise((r) => { resolveSecond = r }) as any)
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    resolveFirst({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: true,
    })
    await c.ensureLoaded()
    const p1 = c.loadNextPage()
    const p2 = c.loadNextPage()
    resolveSecond({
      tags: [{ name: 'b', count: 1, last_used_at: null }],
      has_more: false,
    })
    await Promise.all([p1, p2])
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
  })

  it('ensureLoaded() does NOT re-fetch on subsequent calls when already loaded', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    await c.ensureLoaded()
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(1)
  })

  it('reset() clears the loaded list so ensureLoaded() can start fresh', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toHaveLength(1)
    c.reset()
    expect(c.tags.value).toHaveLength(0)
    expect(c.loaded.value).toBe(false)
    await c.ensureLoaded()
     
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledTimes(2)
  })

 

  it('loading flag is true while a fetch is in flight', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let resolveFetch!: (v: any) => void
    vi.spyOn(api, 'getKanbanTagSuggestions').mockReturnValueOnce(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      new Promise((r) => { resolveFetch = r }) as any,
    )
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    const p = c.ensureLoaded()
    expect(c.loading.value).toBe(true)
    resolveFetch({ tags: [], has_more: false })
    await p
    expect(c.loading.value).toBe(false)
  })

  it('returns empty + has_more=false on API failure (graceful degradation)', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockRejectedValue(new Error('boom'))
    const c = useKanbanTagSuggestions('ws_x', 'item_x')
    await c.ensureLoaded()
    expect(c.tags.value).toEqual([])
    expect(c.hasMore.value).toBe(false)
    expect(c.loading.value).toBe(false)
  })

  it('ensureLoaded() is a no-op when either id is empty (no fetch)', async () => {
    const spy = vi.spyOn(api, 'getKanbanTagSuggestions')
    const c = useKanbanTagSuggestions('', 'item_x')
    await c.ensureLoaded()
    expect(spy).not.toHaveBeenCalled()
    expect(c.tags.value).toEqual([])
    expect(c.hasMore.value).toBe(false)
    // loaded stays false so the next ensureLoaded() retries when args change.
    const c2 = useKanbanTagSuggestions('ws_x', '')
    await c2.ensureLoaded()
    expect(spy).not.toHaveBeenCalled()
  })

  it('uses reactive args: fetches once the refs become non-empty', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'bug', count: 1, last_used_at: null }],
      has_more: false,
    })
    const wsId = ref('')
    const itemId = ref('')
    const c = useKanbanTagSuggestions(wsId, itemId)
    // refs start empty → no fetch, but loaded stays false so the
    // next ensureLoaded() retries when args become available
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).not.toHaveBeenCalled()
    expect(c.loaded.value).toBe(false)
    // refs become populated → reset + ensureLoaded picks up the new values
    wsId.value = 'ws_x'
    itemId.value = 'item_x'
    c.reset()
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
    expect(c.tags.value).toHaveLength(1)
  })

  it('uses reactive args: getter functions are re-evaluated on each fetch', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: false,
    })
    let currentWs = ''
    let currentItem = ''
    const c = useKanbanTagSuggestions(
      () => currentWs,
      () => currentItem,
    )
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).not.toHaveBeenCalled()
    currentWs = 'ws_x'
    currentItem = 'item_x'
    c.reset()
    await c.ensureLoaded()
    expect(api.getKanbanTagSuggestions).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
  })
})
