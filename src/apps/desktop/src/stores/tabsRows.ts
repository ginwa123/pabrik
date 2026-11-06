/** Pure row arithmetic for the tab store. A strip is a filter over the tab list, so everything that
 * decides *which* tab comes next belongs here, where it can be read and tested without a store. */
import { ownerOf, type ClosedTab, type Tab } from '../helpers/tabTarget'

/** The row one owner sees. Two sessions never share one, by construction. */
export function rowOf(tabs: Tab[], owner: string): Tab[] {
  return tabs.filter((tab) => ownerOf(tab) === owner)
}

/** The tab this owner already has for `key` — never another owner's. */
export function keyIn(tabs: Tab[], owner: string, key: string): Tab | null {
  return tabs.find((tab) => ownerOf(tab) === owner && tab.key === key) ?? null
}

/** Move `step` places around the row, wrapping at both ends. */
export function stepWithin<T extends { id: string }>(
  row: T[],
  activeId: string,
  step: number,
): T | null {
  if (row.length === 0) return null
  const current = row.findIndex((tab) => tab.id === activeId)
  const base = current === -1 ? 0 : current
  const size = row.length
  const index = (((base + step) % size) + size) % size
  return row[index] ?? null
}

/** Who takes the caret when `removedId` closes: the right neighbour, else the left. */
export function successorOf(row: Tab[], removedId: string): Tab | null {
  const index = row.findIndex((tab) => tab.id === removedId)
  if (index === -1) return null
  const remaining = row.filter((tab) => tab.id !== removedId)
  return remaining[index] ?? remaining[index - 1] ?? remaining[0] ?? null
}

/** The most recently closed tab of one row, plus the stack without it. */
export function lastClosedOf(
  closed: ClosedTab[],
  owner: string,
): { entry: ClosedTab; rest: ClosedTab[] } | null {
  const at = closed.findIndex((candidate) => ownerOf(candidate) === owner)
  const entry = at === -1 ? undefined : closed[at]
  if (!entry) return null
  return { entry, rest: [...closed.slice(0, at), ...closed.slice(at + 1)] }
}

/** Bounded closed stack: the oldest entries fall off first. */
export function boundedClosed(closed: ClosedTab[], max: number): ClosedTab[] {
  return closed.length > max ? closed.slice(0, max) : closed
}
