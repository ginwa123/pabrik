/** notifications.spec.ts
 * Unit tests for the `useNotificationStore` Pinia store.
 * Covers: notifyError (push + auto-dismiss), dismiss (by id),
 * dismissAll, and the auto-dismiss timer. */
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useNotificationStore } from '../stores/notifications'

describe('useNotificationStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts with empty notifications array', () => {
    const store = useNotificationStore()
    expect(store.notifications).toEqual([])
  })

  it('notifyError pushes a new entry with unique id', () => {
    const store = useNotificationStore()
    store.notifyError('Something failed', 'details')
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('Something failed')
    expect(store.notifications[0]?.details).toBe('details')
    expect(store.notifications[0]?.id).toMatch(/^n_\d+_\d+$/)
  })

  it('notifyError without details omits the field', () => {
    const store = useNotificationStore()
    store.notifyError('Plain error')
    expect(store.notifications[0]?.details).toBeUndefined()
  })

  it('multiple notifyError calls stack in insertion order', () => {
    const store = useNotificationStore()
    store.notifyError('first')
    store.notifyError('second')
    store.notifyError('third')
    expect(store.notifications.map(n => n.message)).toEqual(['first', 'second', 'third'])
  })

  it('each notification auto-dismisses after 5000ms', () => {
    const store = useNotificationStore()
    store.notifyError('auto-dismiss me')
    expect(store.notifications).toHaveLength(1)
    vi.advanceTimersByTime(5000)
    expect(store.notifications).toHaveLength(0)
  })

  it('dismiss removes a specific entry by id', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.notifyError('b')
    const bId = store.notifications[1]?.id ?? ''
    store.dismiss(bId)
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('a')
  })

  it('dismiss on unknown id is a no-op', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.dismiss('nonexistent')
    expect(store.notifications).toHaveLength(1)
  })

  it('dismissAll empties the array', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.notifyError('b')
    store.dismissAll()
    expect(store.notifications).toEqual([])
  })
})
