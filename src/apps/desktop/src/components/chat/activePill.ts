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

/**
 * Estimate the bottom index of the TRUE viewport from the scroller's
 * overscanned rendered window.
 *
 * The VirtualScroller renders `buffer` extra items on EACH side of the
 * viewport, so `end` overshoots what the user actually sees by up to
 * `buffer` items — except at the list end, where the window clamps and
 * `end` IS the viewport bottom. Without this compensation, anchoring
 * the active pill to `end` lights pills for messages below the fold;
 * anchoring to `start` is worse (lights index 0 whenever the window
 * renders from 0, e.g. short chats or near-bottom positions).
 */
export function estimateViewportEnd(
  start: number,
  end: number,
  total: number,
  buffer: number,
): number {
  if (end >= total) return end
  return Math.max(start, end - buffer)
}

/** Returns the groupIndex of the last pill at or below the bound index
 * (usually the estimated viewport bottom — i.e. the latest user turn
 * the user has seen), or null when no pill is at/above the bound (the
 * user hasn't scrolled to their first message yet).
 * `pills` must be sorted ascending by groupIndex (as ChatView builds them). */
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
