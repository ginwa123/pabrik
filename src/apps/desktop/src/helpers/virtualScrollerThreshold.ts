/** Compute the effective `loadMore` threshold in pixels. The VirtualScroller fires `loadMore` when
 * the user is within this many pixels of the load edge. The threshold is the **larger** of: -
 * `absoluteFloor`  — the existing `loadMoreThreshold` prop, in px. */
export function computeLoadMoreThreshold(
  absoluteFloor: number,
  viewportRatio: number,
  containerHeight: number,
): number {
  const safeFloor = Number.isFinite(absoluteFloor) ? absoluteFloor : 200
  if (!Number.isFinite(viewportRatio) || viewportRatio <= 0) {
    return safeFloor
  }
  if (!Number.isFinite(containerHeight) || containerHeight <= 0) {
    return safeFloor
  }
  const proportional = containerHeight * viewportRatio
  return Math.max(safeFloor, proportional)
}
