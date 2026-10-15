/**
 * Decide when to PREFETCH older chat history — i.e. fetch the next older
 * page *before* the user's scroll reaches the load-more band, so the page
 * is already in memory (a buffer) when the band is crossed.
 *
 * Why this exists (task_1789505423062_0): `VirtualScroller`'s `loadMore`
 * check is positional AND debounced (200 ms, trailing edge, timer reset on
 * every scroll event — see `VirtualScroller.vue` `onScroll`). On a fling the
 * user therefore reaches the top edge before the request has even been
 * issued, and then waits out the round trip with nothing left to scroll.
 * Fetching early removes that wait from the critical path; committing the
 * buffered page at the positional band keeps the existing scroll-preservation
 * behaviour untouched (arm ≠ commit: prepending mid-fling would fight the
 * momentum scroll).
 *
 * Pure (no DOM, no Vue) so the decision matrix is unit-testable — the same
 * reason `virtualScrollerThreshold.ts` and `autoStickGate.ts` are standalone
 * files.
 */

import { computeLoadMoreThreshold } from './virtualScrollerThreshold'

/**  * Absolute floor for the arm radius, in px. Larger than the commit band's 200 px floor because the
 * point is to start the round trip while the user is still travelling. */
export const ARM_RADIUS_FLOOR_PX = 800

/**  * Proportional part of the arm radius: how many viewport heights away from the top the arm fires.
 * Must stay strictly greater than the commit band's `loadMoreThresholdRatio` (0.5) so the arm
 * always precedes the commit. */
export const ARM_RADIUS_RATIO = 1.5

/** Cold-start fetch estimate (ms) used before any round trip is measured. */
export const PREFETCH_SAMPLE_INIT_MS = 220

/** EMA weight for newly measured fetch durations. */
export const FETCH_EMA_ALPHA = 0.4

/** Clamp for a single measured fetch duration, in ms. */
export const FETCH_SAMPLE_MIN_MS = 60
export const FETCH_SAMPLE_MAX_MS = 1200

/** Arm radius in px: `max(800, 1.5 × containerHeight)`.
 * Delegates to `computeLoadMoreThreshold` so the "biggest of an absolute
 * floor and a viewport proportion" rule lives in exactly one place. Because
 * `max(800, 1.5h) > max(200, 0.5h)` for every `h ≥ 0`, the arm radius is
 * always strictly larger than the commit band (asserted in the spec). */
export function armRadiusPx(containerHeight: number): number {
  return computeLoadMoreThreshold(ARM_RADIUS_FLOOR_PX, ARM_RADIUS_RATIO, containerHeight)
}

/** Exponential moving average of observed `getChatHistory` durations.
 * Recorded (and logged) even while the v1 trigger is distance-only, so the
 * PR can report "the page needed X ms and the user was given Y ms of head
 * start" — and so the velocity term can be switched on without re-deriving
 * state. Non-finite or out-of-range samples are ignored. */
export function nextFetchEstimate(prevMs: number, measuredMs: number): number {
  const prev = Number.isFinite(prevMs) && prevMs > 0 ? prevMs : PREFETCH_SAMPLE_INIT_MS
  if (!Number.isFinite(measuredMs) || measuredMs <= 0) return prev
  const sample = Math.min(FETCH_SAMPLE_MAX_MS, Math.max(FETCH_SAMPLE_MIN_MS, measuredMs))
  return prev * (1 - FETCH_EMA_ALPHA) + sample * FETCH_EMA_ALPHA
}

/** Why an arm was NOT issued. Surfaced in the scroll log so triage is silent-free. */
export type PrefetchSkip =
  | 'no-session' // no chat bound yet
  | 'no-more-messages' // backend said has_more=false
  | 'already-buffered' // a page is already armed
  | 'already-fetching' // an arm request is in flight
  | 'initial-load' // the initial page load is in flight
  | 'committing' // a commit (prepend/preserve) is in flight
  | 'preserving' // VirtualScroller is inside beginPreserve/endPreserve
  | 'backoff' // a previous arm failed recently
  | 'not-close-enough' // the user is still far from the top — normal scrolling, not a skip

export interface PrefetchInput {
  /** Current distance from the top edge, in px (>= 0). */
  distanceFromTop: number
  /** Arm radius in px — see {@link armRadiusPx}. */
  armRadiusPx: number
  /** Backend still has older messages (`has_more`). */
  hasMore: boolean
  /** The initial `loadChatHistory(false)` is in flight. */
  isLoading: boolean
  /** A commit (buffer prepend / preserve dance) is in flight. */
  isCommitting: boolean
  /** An arm request is already in flight. */
  isPrefetching: boolean
  /** A page is already sitting in the buffer. */
  hasBufferedPage: boolean
  /** VirtualScroller is mid-preserve. */
  isPreservingScroll: boolean
  /** Active session id, or null/empty when no chat is bound. */
  sessionId: string | null
  /** A recent arm failed and the backoff window is still open. */
  backoffActive: boolean
  /** Phase 2 hook: smoothed upward velocity in px/ms (0/undefined disables the
   * velocity term — v1 is distance-only). */
  velocityPxPerMs?: number
  /** Phase 2 hook: estimated fetch duration in ms. */
  estimatedFetchMs?: number
  /** Phase 2 hook: extra headroom added to the estimate, in ms. */
  safetyMs?: number
}

export interface PrefetchDecision {
  arm: boolean
  trigger: 'margin' | 'velocity' | 'none'
  /** Distance from the top at which this decision would fire, in px. */
  reachPx: number
  /** Travel time to the top at the current velocity (Infinity when unknown). */
  timeToTopMs: number
  skip?: PrefetchSkip
}

/**  * Decide whether to arm a prefetch of the next older page. Order matters: terminal states (no
 * session, no more pages, already buffered/fetching/committing) short-circuit first, then the
 * optional velocity term (which can arm from further out), then the distance margin. */
export function decidePrefetchOlder(input: PrefetchInput): PrefetchDecision {
  const armRadius =
    Number.isFinite(input.armRadiusPx) && input.armRadiusPx > 0
      ? input.armRadiusPx
      : ARM_RADIUS_FLOOR_PX
  const distance =
    Number.isFinite(input.distanceFromTop) && input.distanceFromTop > 0 ? input.distanceFromTop : 0

  const skip = (reason: PrefetchSkip): PrefetchDecision => ({
    arm: false,
    trigger: 'none',
    reachPx: armRadius,
    timeToTopMs: Infinity,
    skip: reason,
  })

  if (!input.sessionId) return skip('no-session')
  if (!input.hasMore) return skip('no-more-messages')
  if (input.hasBufferedPage) return skip('already-buffered')
  if (input.isPrefetching) return skip('already-fetching')
  if (input.isLoading) return skip('initial-load')
  if (input.isCommitting) return skip('committing')
  if (input.isPreservingScroll) return skip('preserving')
  if (input.backoffActive) return skip('backoff')

  // Phase 2: velocity term. Arms when the user's own travel time to the top
  // is shorter than the time a fetch needs — i.e. even the margin would be
  // too late. Disabled in v1 (velocity 0 / estimate 0).
  const velocity =
    typeof input.velocityPxPerMs === 'number' && Number.isFinite(input.velocityPxPerMs)
      ? Math.max(0, input.velocityPxPerMs)
      : 0
  const estimate =
    typeof input.estimatedFetchMs === 'number' && Number.isFinite(input.estimatedFetchMs)
      ? Math.max(0, input.estimatedFetchMs)
      : 0
  const safety =
    typeof input.safetyMs === 'number' && Number.isFinite(input.safetyMs)
      ? Math.max(0, input.safetyMs)
      : 0

  if (velocity > 0 && estimate > 0) {
    const budgetMs = estimate + safety
    if (distance / velocity <= budgetMs) {
      return {
        arm: true,
        trigger: 'velocity',
        reachPx: velocity * budgetMs,
        timeToTopMs: distance / velocity,
      }
    }
  }

  if (distance <= armRadius) {
    return {
      arm: true,
      trigger: 'margin',
      reachPx: armRadius,
      timeToTopMs: velocity > 0 ? distance / velocity : Infinity,
    }
  }

  return skip('not-close-enough')
}
