/** virtualScrollerScrollAnchor.ts Pure math for VirtualScroller's measurement-shift compensation. */
type geometry_px = number

/** One pending height write from a measure pass. */
export interface AnchorMeasurement {
  /** Item index in the full items array. */
  index: number
  /** Newly measured height in px (>0). */
  newHeight: number
  /** Previously stored height in px, or undefined when this item has never been measured before. */
  oldHeight: number | undefined
}

export interface AnchorCompensationInput {
  /** Index of the first item at/under the viewport top edge BEFORE the height model changed (the anchor). */
  anchorIndex: number
  /** scrollTop captured before the height model changed. */
  prevScrollTop: geometry_px
  /** `accumulatedHeights[anchorIndex]` captured BEFORE the pass mutates the model — the model-space top edge of the anchor item. */
  oldAnchorTop: geometry_px
  /** `accumulatedHeights[anchorIndex]` after the pass rebuilt the model (measured heights written, estimator re-seeded, estimates refreshed). */
  newAnchorTop: geometry_px
  /** The bottom edge AFTER the pass (`bottomScrollTop()`), passed only when the reader was AT THE BOTTOM before the pass mutated the model. */
  atBottomTarget?: geometry_px
  /** The highest `scrollTop` the container can reach RIGHT NOW (`scrollHeight - clientHeight`). */
  maxScrollTop?: geometry_px
}

export interface AnchorCompensationResult {
  /** Signed delta of the anchor's prefix sum. */
  shiftPx: geometry_px
  /** scrollTop after compensation, clamped at ≥ 0. */
  newScrollTop: geometry_px
  /** True when the clamp at 0 bit (residual jump is unavoidable). */
  clamped: boolean
  /** True when `maxScrollTop` cut the target down. */
  clampedToMax: boolean
  /** Which rule produced `newScrollTop`. */
  target: 'anchor' | 'bottom'
}

/** Compute the scrollTop adjustment that keeps rendered content stationary when the height model's prefix sum at the anchor changes. */
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

  // Bound a target to the range the container can actually reach (see `maxScrollTop`).
  const cap =
    typeof input.maxScrollTop === 'number' && Number.isFinite(input.maxScrollTop)
      ? Math.max(0, input.maxScrollTop)
      : null
  const bound = (target: geometry_px): { target: geometry_px; clampedToMax: boolean } =>
    cap !== null && target > cap ? { target: cap, clampedToMax: true } : { target, clampedToMax: false }

  // A reader at the bottom is re-targeted to the bottom edge rather than compensated around the anchor — see `atBottomTarget` on the input type for the failure …
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
