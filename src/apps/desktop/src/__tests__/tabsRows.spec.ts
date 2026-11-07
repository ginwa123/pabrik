import { describe, expect, it } from 'vitest'

import type { ClosedTab, Tab } from '../helpers/tabTarget'
import {
  boundedClosed,
  keyIn,
  lastClosedOf,
  rowOf,
  stepWithin,
  successorOf,
} from '../stores/tabsRows'

const tab = (id: string, owner?: string, key = id, kind: Tab['kind'] = 'file'): Tab => ({
  id,
  key,
  kind,
  title: id,
  path: '/app',
  query: {},
  createdAt: 1,
  ...(owner ? { owner } : {}),
})

const closed = (id: string, owner?: string): ClosedTab => ({ ...tab(id, owner), closedAt: 1 })

/** Two rows of three: `a1 a2 a3` for session A, `b1 b2 b3` for session B. */
const list: Tab[] = [
  tab('a1', 'sa', 'chat:sa', 'chat'),
  tab('a2', 'sa'),
  tab('a3', 'sa'),
  tab('b1', 'sb', 'chat:sb', 'chat'),
  tab('b2', 'sb'),
  tab('home'),
]

describe('tabsRows', () => {
  it('splits the list into one row per owner, keeping each row’s order', () => {
    expect(rowOf(list, 'sa').map((t) => t.id)).toEqual(['a1', 'a2', 'a3'])
    expect(rowOf(list, 'sb').map((t) => t.id)).toEqual(['b1', 'b2'])
    // no owner is the window's own row
    expect(rowOf(list, '').map((t) => t.id)).toEqual(['home'])
    expect(rowOf(list, 'nope')).toEqual([])
  })

  it('finds a key inside its own row only', () => {
    expect(keyIn(list, 'sa', 'chat:sa')?.id).toBe('a1')
    expect(keyIn(list, 'sb', 'chat:sa')).toBeNull()
    expect(keyIn(list, 'sa', 'missing')).toBeNull()
  })

  it('steps around a row and wraps at both ends', () => {
    const row = rowOf(list, 'sa')
    expect(stepWithin(row, 'a1', 1)?.id).toBe('a2')
    expect(stepWithin(row, 'a3', 1)?.id).toBe('a1')
    expect(stepWithin(row, 'a1', -1)?.id).toBe('a3')
    // an unknown active id starts from the first tab instead of throwing
    expect(stepWithin(row, 'nope', 1)?.id).toBe('a2')
    expect(stepWithin([], 'a1', 1)).toBeNull()
  })

  it('hands the caret to the right neighbour, then the left, then the first', () => {
    const row = rowOf(list, 'sa')
    expect(successorOf(row, 'a2')?.id).toBe('a3')
    expect(successorOf(row, 'a3')?.id).toBe('a2')
    expect(successorOf(rowOf(list, 'sb'), 'b2')?.id).toBe('b1')
    // closing a tab that is not in this row is not a request to move the caret
    expect(successorOf(row, 'b1')).toBeNull()
  })

  it('reopens from the row’s own closed stack', () => {
    const stack = [closed('x', 'sa'), closed('y', 'sb'), closed('z', 'sa')]
    const found = lastClosedOf(stack, 'sa')
    expect(found?.entry.id).toBe('x')
    expect(found?.rest.map((t) => t.id)).toEqual(['y', 'z'])
    expect(lastClosedOf(stack, 'sc')).toBeNull()
  })

  it('keeps the closed stack bounded, dropping the oldest', () => {
    const stack = [closed('1'), closed('2'), closed('3')]
    expect(boundedClosed(stack, 2).map((t) => t.id)).toEqual(['1', '2'])
    expect(boundedClosed(stack, 5)).toBe(stack)
  })
})
