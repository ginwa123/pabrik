/** Pure scrollbar math for ChatScrollSlider — no DOM reads, unit-testable. */
/** Minimum thumb height as % of track so long chats stay grabbable. */
export const MIN_THUMB_PCT = 8

export interface ThumbGeometry {
  visible: boolean
  /** Thumb height as % of track height. */
  thumbHeightPct: number
  /** Thumb offset from track top as % of track height. */
  thumbTopPct: number
  /** Scroll ratio 0..1 (for aria-valuenow). */
  ratio: number
}

/** Standard scrollbar geometry:
 *   thumbH% = clamp(clientH / scrollH * 100, MIN_THUMB_PCT, 100)
 *   thumbTop% = scrollTop / (scrollH - clientH) * (100 - thumbH%) */
export function computeThumbGeometry(
  scrollTop: number,
  scrollHeight: number,
  clientHeight: number,
): ThumbGeometry {
  const hidden: ThumbGeometry = { visible: false, thumbHeightPct: 100, thumbTopPct: 0, ratio: 0 }
  if (
    !Number.isFinite(scrollTop) ||
    !Number.isFinite(scrollHeight) ||
    !Number.isFinite(clientHeight)
  ) {
    return hidden
  }
  const scrollable = scrollHeight - clientHeight
  if (scrollable <= 1 || clientHeight <= 0 || scrollHeight <= 0) {
    return hidden
  }
  const clampedTop = Math.min(Math.max(scrollTop, 0), scrollable)
  const thumbHeightPct = Math.min(100, Math.max(MIN_THUMB_PCT, (clientHeight / scrollHeight) * 100))
  const maxTop = 100 - thumbHeightPct
  const ratio = clampedTop / scrollable
  return {
    visible: true,
    thumbHeightPct,
    thumbTopPct: maxTop <= 0 ? 0 : ratio * maxTop,
    ratio,
  }
}
