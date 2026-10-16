/** autoStickGate.ts "Gate suppression" of lazy load during streaming. */
/**
 * How recent the last auto-stick must be (in ms) for the gate to
 * consider the auto-stick "active" and suppress `loadMore`.
 *
 * 500ms is short enough that during slow models (1 chunk/sec) the
 * user gets a real window to scroll up and prepend, and long enough
 * that during active streaming (~20 chunks/sec) the gate is always
 * fresh and `loadMore` is always suppressed.
 *
 * Exposed (not buried in the function) so the `load-more-suppressed`
 * log can print the active value — operators then know what threshold
 * was in effect without re-reading the source.
 */
export const AUTO_STICK_GATE_MS = 500

/** Is the auto-stick currently "active" — i.e. would a prepend right now fight the stick-to-bottom
 * logic? Returns true only when BOTH conditions hold: 1. `isAtBottom === true` — the user is at the
 * bottom edge. If they scrolled up, the auto-stick isn't engaged, so a prepend can't fight it. */
export const isAutoStickActive = (
  lastAutoStickAt: number,
  now: number,
  isAtBottom: boolean,
): boolean => {
  if (!isAtBottom) return false
  if (lastAutoStickAt === 0) return false
  return now - lastAutoStickAt < AUTO_STICK_GATE_MS
}
