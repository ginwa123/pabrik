/** Tests for useAgentErrorStore — Pinia store backing the persistent per-session "agent error" card
 * slot. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useAgentErrorStore } from '../stores/agentError'

describe('useAgentErrorStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts with an empty bySession map', () => {
    const store = useAgentErrorStore()
    expect(store.bySession).toEqual({})
  })

  it('setError stores an entry with explicit id and content', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    expect(store.bySession.s1).toEqual({ id: 'i1', content: 'c1' })
  })

  it('setError auto-generates an id when none is provided', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-08-29T07:30:00.000Z'))
    const store = useAgentErrorStore()
    store.setError('s1', 'c2')
    expect(store.bySession.s1).toEqual({
      id: `agent-error-${Date.now()}`,
      content: 'c2',
    })
  })

  it('setError overwrites the previous entry on the same session (latest-wins, single slot)', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    store.setError('s1', 'c3', 'i3')
    expect(store.bySession.s1).toEqual({ id: 'i3', content: 'c3' })
  })

  it('setError on a different session does not mutate the first entry', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    const before = store.bySession.s1
    store.setError('s2', 'c2', 'i2')
    expect(store.bySession.s1).toBe(before) // same reference, untouched
    expect(store.bySession.s1).toEqual({ id: 'i1', content: 'c1' })
    expect(store.bySession.s2).toEqual({ id: 'i2', content: 'c2' })
  })

  it('clearForSession removes the entry from bySession', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    store.clearForSession('s1')
    expect('s1' in store.bySession).toBe(false)
  })

  it('clearForSession is idempotent (calling twice is safe)', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    expect(() => store.clearForSession('s1')).not.toThrow()
    expect(() => store.clearForSession('s1')).not.toThrow()
    expect('s1' in store.bySession).toBe(false)
  })

  it('clearForSession does not clear entries on other sessions', () => {
    const store = useAgentErrorStore()
    store.setError('s1', 'c1', 'i1')
    store.setError('s2', 'c2', 'i2')
    store.clearForSession('s1')
    expect('s1' in store.bySession).toBe(false)
    expect(store.bySession.s2).toEqual({ id: 'i2', content: 'c2' })
  })

  it('errorFor returns null for an unknown sessionId (no spurious key insert)', () => {
    const store = useAgentErrorStore()
    expect(store.errorFor('never-seen')).toBeNull()
    expect('never-seen' in store.bySession).toBe(false)
  })
})
