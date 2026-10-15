/**
 * autoStickGate.ts
 *
 * "Gate suppression" of lazy load during streaming.
 *
 * The previous guard in `handleLoadMore` was
 *   `if (isLLMProcessing.value && isAtBottom.value) { return }`
 * — it blocked `loadMore` for the ENTIRE duration of a stream, which
 * made it impossible to scroll up and read history while a long
 * response was streaming. The user reported: "i cannot load lazy
 * load" with `load-more-suppressed guard=isLLMProcessing-atBottom`
 * appearing on every prepend attempt during a stream.
 *
 * The gate version: only suppress when the auto-stick actually fired
 * RECENTLY (within `AUTO_STICK_GATE_MS`). That gives three regimes:
 *
 *   1. User is actively watching the stream
 *      → SSE chunks arrive every <100ms
 *      → `lastAutoStickAt` is always fresh
 *      → `loadMore` is suppressed (no jitter from a prepend fighting
 *        the stick-to-bottom logic that fires on the next chunk)
 *
 *   2. User scrolls up between chunks (or the model is slow to emit)
 *      → no auto-stick fires
 *      → timestamp goes stale within the gate window
 *      → `loadMore` is allowed
 *      → the user can prepend older history mid-stream
 *
 *   3. Stream ends
 *      → no more chunks arrive
 *      → timestamp goes stale within the gate window
 *      → `loadMore` is allowed
 *
 * The "is the auto-stick actually fighting" check is the right
 * semantic — the OLD guard (`isLLMProcessing && isAtBottom`) conflated
 * "the LLM is busy" with "the auto-stick is currently engaged". They
 * are not the same: the auto-stick is a per-frame concern, the LLM
 * being busy is a session-lifetime concern.
 */
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

/**
 * Is the auto-stick currently "active" — i.e. would a prepend right
 * now fight the stick-to-bottom logic?
 *
 * Returns true only when BOTH conditions hold:
 *
 *   1. `isAtBottom === true` — the user is at the bottom edge. If
 *      they scrolled up, the auto-stick isn't engaged, so a prepend
 *      can't fight it. (Without this check, a fast chunk rate would
 *      suppress `loadMore` even when the user clearly wants to read
 *      history.)
 *
 *   2. `lastAutoStickAt` is within `AUTO_STICK_GATE_MS` of `now` — the
 *      stick has fired recently. A stale timestamp means either the
 *      stream paused or the user scrolled up; either way, prepending
 *      is safe.
 *
 * Special case: `lastAutoStickAt === 0` (never fired, e.g. the chat
 * was just mounted) is treated as "inactive" so the very first
 * `loadMore` after mount isn't blocked.
 *
 * Clock-skew note: a future timestamp (`now - lastAutoStickAt < 0`)
 * is treated as still active. This handles a rare but real case where
 * the timestamp is read from a setTimeout-throttled callback that
 * fired slightly before the guard's `Date.now()` read. Better to
 * over-suppress by a microsecond than to let a prepend fight a stick
 * that's about to fire on the next animation frame.
 *
 * @param lastAutoStickAt  ms timestamp of the most recent auto-stick.
 *                         Pass 0 to indicate "never fired".
 * @param now              current ms timestamp. Injectable for tests
 *                         so the function is pure and deterministic.
 * @param isAtBottom       true when the chat is at the bottom edge.
 */
export const isAutoStickActive = (
  lastAutoStickAt: number,
  now: number,
  isAtBottom: boolean,
): boolean => {
  if (!isAtBottom) return false
  if (lastAutoStickAt === 0) return false
  return now - lastAutoStickAt < AUTO_STICK_GATE_MS
}
