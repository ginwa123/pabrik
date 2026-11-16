/* eslint-disable @typescript-eslint/no-explicit-any -- test mocks legitimately use loose types */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { apiFetch } from '../api/index'

describe('apiFetch timeout', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.useFakeTimers()
  })
  afterEach(() => { vi.useRealTimers() })

  it('passes an AbortSignal so hung fetch can time out', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(
      (_url: any, _init?: any) => new Promise(() => {}), // never resolves = hung backend
    )
    const p = apiFetch('/hung', { timeoutMs: 15000 } as any)
    // flush microtasks so fetch is called
    await Promise.resolve()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    const init = fetchSpy.mock.calls[0]?.[1] as RequestInit | undefined
    // RED: currently no signal. Fixed: AbortSignal with timeout.
    expect(init?.signal).toBeDefined()
    // cleanup: abort to avoid hanging test
    ;(p as Promise<unknown>).catch(() => {})
  })

  it('defaults to 15s timeout when timeoutMs omitted', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(
      () => new Promise(() => {}),
    )
    const p = apiFetch('/hung2')
    await Promise.resolve()
    const init = fetchSpy.mock.calls[0]?.[1] as RequestInit | undefined
    expect(init?.signal).toBeDefined()
    ;(p as Promise<unknown>).catch(() => {})
  })
})
