/* eslint-disable @typescript-eslint/no-explicit-any -- test doubles legitimately use loose types */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { getChats } from '../api/index'

/** The sidebar's list call is the one whose latency scales with the page it returns. */
describe('getChats — a slow session list is not read as an empty one', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('returns the rows of a response that arrives after the 15s apiFetch default', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(
      () =>
        new Promise((resolve) => {
          setTimeout(
            () =>
              resolve({
                ok: true,
                status: 200,
                statusText: 'OK',
                json: async () => ({
                  sessions: [{ session_id: 'slow_1', session_name: 'Slow' }],
                  has_more: false,
                  next_cursor: null,
                  total: 1,
                }),
              }),
            20_000,
          )
        }) as any,
    )

    const pending = getChats()
    await vi.advanceTimersByTimeAsync(20_000)
    const page = await pending

    expect(page.failed).toBeFalsy()
    expect(page.sessions.map((s) => s.session_id)).toEqual(['slow_1'])
    expect(page.total).toBe(1)
  })

  it('flags the empty list it returns for a failed request', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => Promise.reject(new Error('offline')) as any)

    const page = await getChats()

    expect(page.sessions).toEqual([])
    expect(page.failed).toBe(true)
  })

  it('does not flag a scope that genuinely has no sessions', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(
      () =>
        Promise.resolve({
          ok: true,
          status: 200,
          statusText: 'OK',
          json: async () => ({ sessions: [], has_more: false, next_cursor: null, total: 0 }),
        }) as any,
    )

    const page = await getChats()

    expect(page.sessions).toEqual([])
    expect(page.failed).toBeFalsy()
  })
})
