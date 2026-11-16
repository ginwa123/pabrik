/** Compute the effective `loadMore` threshold in pixels. */
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
