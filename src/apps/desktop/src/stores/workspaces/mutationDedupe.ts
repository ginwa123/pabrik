export const RECENT_MUTATION_TTL_MS = 1500

const recentLocalMutations = new Map<string, number>()

export function registerRecentLocalMutations(ids: string[], expiryMs: number): void {
  const now = Date.now()
  // Lazy GC: drop expired entries on every register call to keep
  // the Map small. O(N) per PATCH is acceptable for v1 (worst case
  // bounded by the mutation rate; typically < 50 entries).
  for (const [id, exp] of recentLocalMutations) {
    if (exp < now) recentLocalMutations.delete(id)
  }
  for (const id of ids) {
    recentLocalMutations.set(id, expiryMs)
  }
}

/**  * True iff `elementId` was mutated by this client within the last `RECENT_MUTATION_TTL_MS`
 * milliseconds. Read by the SSE handler to decide whether to skip the GET fan-out for an incoming
 * event. Exported for `stores/designSse.ts`. Side effect: expired entries are lazily GC'd on read. */
export function isRecentLocalMutation(elementId: string): boolean {
  const exp = recentLocalMutations.get(elementId)
  if (exp === undefined) return false
  if (exp < Date.now()) {
    recentLocalMutations.delete(elementId)
    return false
  }
  return true
}

/**  * Test-only helper to clear the dedupe Map between tests. NOT exposed in the production API surface
 * — exported via the store's returned object only for unit tests. */
export function _clearRecentLocalMutationsForTests(): void {
  recentLocalMutations.clear()
}
