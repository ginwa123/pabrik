/** autoStickGate.ts "Gate suppression" of lazy load during streaming. */
export const AUTO_STICK_GATE_MS = 500

/** Is the auto-stick currently "active" — i.e. would a prepend right now fight the stick-to-bottom logic? */
export const isAutoStickActive = (
  lastAutoStickAt: number,
  now: number,
  isAtBottom: boolean,
): boolean => {
  if (!isAtBottom) return false
  if (lastAutoStickAt === 0) return false
  return now - lastAutoStickAt < AUTO_STICK_GATE_MS
}
