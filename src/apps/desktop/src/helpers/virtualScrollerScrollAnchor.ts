/** virtualScrollerScrollAnchor.ts Pure math for VirtualScroller's measurement-shift compensation.
 * Why this exists: `measureItems()` rewrites REAL heights over ESTIMATES for every rendered child —
 * including up to `buffer` items ABOVE the viewport. */
type geometry_px = number

/**  * One pending height write from a measure pass. Carried on the debug log only — compensation itself
 * no longer consumes per-item entries (see the v2 note above). */
export interface AnchorMeasurement {
  /** Item index in the full items array. */
  index: number
  /** Newly measured height in px (>0). */
  newHeight: number
  /**
   * Previously stored height in px, or undefined when this item has never been measured before. /
   */
  oldHeight: number | undefined
}

export interface AnchorCompensationInput {
  /** Index of the first item at/under the viewport top edge BEFORE the
   * height model changed (the anchor). Negative = empty list → no-op. */
  anchorIndex: number
  /** scrollTop captured before the height model changed. */
  prevScrollTop: geometry_px
  /** `accumulatedHeights[anchorIndex]` captured BEFORE the pass
   * mutates the model — the model-space top edge of the anchor item. */
  oldAnchorTop: geometry_px
  /**    * `accumulatedHeights[anchorIndex]` after the pass rebuilt the model (measured heights written,
   * estimator re-seeded, estimates refreshed). */
  newAnchorTop: geometry_px
  /** The bottom edge AFTER the pass (`bottomScrollTop()`), passed only when the reader was AT THE
   * BOTTOM before the pass mutated the model. Omit it and the anchor math runs. The anchor exists
   * to hold still whatever the reader is looking at. */
  atBottomTarget?: geometry_px
  /** The highest `scrollTop` the container can reach RIGHT NOW (`scrollHeight - clientHeight`).
   * Omit it and the target is unbounded. */
  maxScrollTop?: geometry_px
}

export interface AnchorCompensationResult {
  /** Signed delta of the anchor's prefix sum. Positive = content above
   * grew in the model → scrollTop must increase to stay stationary. */
  shiftPx: geometry_px
  /** scrollTop after compensation, clamped at ≥ 0. */
  newScrollTop: geometry_px
  /** True when the clamp at 0 bit (residual jump is unavoidable). */
  clamped: boolean
  /** True when `maxScrollTop` cut the target down. */
  clampedToMax: boolean
  /**    * Which rule produced `newScrollTop`. `'bottom'` means the reader was at the bottom and the pass
   * targeted the bottom edge instead of the anchor; the `shiftPx` reported alongside it is the
   * model delta that was absorbed, not a move the reader can observe. */
  target: 'anchor' | 'bottom'
}

/** Compute the scrollTop adjustment that keeps rendered content stationary when the height model's
 * prefix sum at the anchor changes. Rules: - `prefix(anchor)` covers items STRICTLY ABOVE the
 * anchor only. */
export function computeAnchorCompensation(
  input: AnchorCompensationInput,
): AnchorCompensationResult {
  const { anchorIndex, prevScrollTop, oldAnchorTop, newAnchorTop, atBottomTarget } = input

  if (
    !Number.isFinite(anchorIndex) ||
    anchorIndex < 0 ||
    !Number.isFinite(oldAnchorTop) ||
    !Number.isFinite(newAnchorTop)
  ) {
    return {
      shiftPx: 0,
      newScrollTop: prevScrollTop,
      clamped: false,
      clampedToMax: false,
      target: 'anchor',
    }
  }

  const shiftPx = newAnchorTop - oldAnchorTop

  // Bound a target to the range the container can actually reach (see
  // `maxScrollTop`). A non-finite or negative bound is treated as 0, and an
  // absent one as "unbounded" — the pre-2026-10-12 behaviour.
  const cap =
    typeof input.maxScrollTop === 'number' && Number.isFinite(input.maxScrollTop)
      ? Math.max(0, input.maxScrollTop)
      : null
  const bound = (target: geometry_px): { target: geometry_px; clampedToMax: boolean } =>
    cap !== null && target > cap ? { target: cap, clampedToMax: true } : { target, clampedToMax: false }

  // A reader at the bottom is re-targeted to the bottom edge rather than compensated around the
  // anchor — see `atBottomTarget` on the input type for the failure this prevents. Ordered BEFORE
  // the `shiftPx === 0` early return, and that ordering is the fix (2026-10-10).
  if (
    typeof atBottomTarget === 'number' &&
    Number.isFinite(atBottomTarget) &&
    atBottomTarget > prevScrollTop
  ) {
    const bounded = bound(atBottomTarget)
    return {
      shiftPx,
      newScrollTop: Math.max(0, bounded.target),
      clamped: false,
      clampedToMax: bounded.clampedToMax,
      target: 'bottom',
    }
  }

  if (shiftPx === 0) {
    return {
      shiftPx: 0,
      newScrollTop: prevScrollTop,
      clamped: false,
      clampedToMax: false,
      target: 'anchor',
    }
  }

  const bounded = bound(prevScrollTop + shiftPx)
  const clamped = bounded.target < 0
  return {
    shiftPx,
    newScrollTop: Math.max(0, bounded.target),
    clamped,
    clampedToMax: bounded.clampedToMax,
    target: 'anchor',
  }
}
