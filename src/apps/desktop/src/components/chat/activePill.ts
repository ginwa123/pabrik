/** Pure helper: which rail pill is active for a given visible range. No DOM. */
export interface PillIndex {
  groupIndex: number
}

/**  * Whether a message group deserves a rail pill. Real user turns only: background completions are
 * `role=user` on the wire but render as left-aligned tool cards (never the blue bubble), and
 * compaction envelopes are system artifacts — neither is a user turn to jump to. */
export function isPillGroup(role: string, isBgOnly: boolean, isCompaction: boolean): boolean {
  return role === 'user' && !isBgOnly && !isCompaction
}

/** Estimate the bottom index of the TRUE viewport from the scroller's overscanned rendered window. */
export function estimateViewportEnd(
  start: number,
  end: number,
  total: number,
  buffer: number,
): number {
  if (end >= total) return end
  return Math.max(start, end - buffer)
}

/** Returns the groupIndex of the last pill at or below the bound index (usually the estimated
 * viewport bottom — i.e. the latest user turn the user has seen), or null when no pill is at/above
 * the bound (the user hasn't scrolled to their first message yet). */
export function pickActivePillIndex(
  pills: readonly PillIndex[],
  boundIndex: number,
): number | null {
  let active: number | null = null
  for (const pill of pills) {
    if (pill.groupIndex <= boundIndex) active = pill.groupIndex
    else break
  }
  return active
}
