/**
 * Snap-to-edges math for design-mode drag.
 *
 * Algorithm:
 *   1. The dragged element's bbox at the cursor's current position.
 *   2. For every OTHER element on the page, compute the distance from
 *      each of the 3 edges/centers (left, center, right) of the dragged
 *      bbox to the matching edge/center of the target.
 *   3. The closest pair within 6 design-px wins. The dx/dy needed to
 *      align them is the snap delta.
 *
 * The canvas background feature has been removed (plan
 * docs/superpowers/plans/2026-07-29-remove-canvas-background.md), so
 * there is no longer a "canvas center" fallback target. Snap fires
 * only when an actual element-edge snap target is within 6 design-px.
 *
 * Returns:
 *   - dx: design-px delta to ADD to the user's input dx
 *   - dy: same for y
 *   - guides: array of { axis, position } pairs to render as 1px lines
 *
 * Why a separate file: the math is pure (no DOM, no Vue) so it's
 * trivially testable in isolation. DesignView imports the function
 * and calls it on every pointermove.
 */

export interface Bbox { id: string; x: number; y: number; width: number; height: number }
export interface SnapGuide { axis: 'x' | 'y'; position: number }
export interface SnapResult {
  dx: number
  dy: number
  guides: SnapGuide[]
}

const SNAP_THRESHOLD = 6  // design-px for element-to-element snapping

export function computeSnapDelta(
  elements: Bbox[],
  draggedId: string,
  rawDx: number,
  rawDy: number,
): SnapResult {
  const dragged = elements.find((e) => e.id === draggedId)
  if (!dragged) return { dx: rawDx, dy: rawDy, guides: [] }

  // The dragged bbox at the cursor's current position.
  const movedX = dragged.x + rawDx
  const movedY = dragged.y + rawDy
  const movedRight = movedX + dragged.width
  const movedBottom = movedY + dragged.height
  const movedCx = movedX + dragged.width / 2
  const movedCy = movedY + dragged.height / 2

  // Targets: every OTHER element's matching edge/center.
  const otherElementEdgesX: number[] = []
  const otherElementEdgesY: number[] = []
  for (const e of elements) {
    if (e.id === draggedId) continue
    otherElementEdgesX.push(e.x, e.x + e.width, e.x + e.width / 2)
    otherElementEdgesY.push(e.y, e.y + e.height, e.y + e.height / 2)
  }
  // Snap-to-start targets: the original left, center, and right edges of the dragged element.
  // Within 6px of start, the cursor gets pulled back to the original position (Figma UX).
  // These are a SECONDARY target — they only fire when no other-element snap fires (priority:
  // element-snap > snap-to-start).
  const snapToStartX: number[] = [
    dragged.x, dragged.x + dragged.width, dragged.x + dragged.width / 2,
  ]
  const snapToStartY: number[] = [
    dragged.y, dragged.y + dragged.height, dragged.y + dragged.height / 2,
  ]

  const movedEdgesX = [movedX, movedRight, movedCx]
  const movedEdgesY = [movedY, movedBottom, movedCy]

  let bestSnapX: { dist: number; correction: number; position: number; isStart: boolean } | null = null
  let bestSnapY: { dist: number; correction: number; position: number; isStart: boolean } | null = null
  let elementSnapXFired = false
  let elementSnapYFired = false

  // Stage 1: element-to-element snap (6px threshold, strict). Note the `dist > 0` guard: a snap
  // fires only when the cursor is APPROACHING the target (distance > 0).
  // When the cursor is exactly on the target (dist == 0), no correction is needed (the user already
  // landed there) and emitting a guide would be noise.
  for (const movedEdgeX of movedEdgesX) {
    for (const t of otherElementEdgesX) {
      const dist = Math.abs(movedEdgeX - t)
      if (dist > 0 && dist < SNAP_THRESHOLD) {
        if (!bestSnapX || dist < bestSnapX.dist) {
          bestSnapX = { dist, correction: t - movedEdgeX, position: t, isStart: false }
          elementSnapXFired = true
        }
      }
    }
  }
  for (const movedEdgeY of movedEdgesY) {
    for (const t of otherElementEdgesY) {
      const dist = Math.abs(movedEdgeY - t)
      if (dist > 0 && dist < SNAP_THRESHOLD) {
        if (!bestSnapY || dist < bestSnapY.dist) {
          bestSnapY = { dist, correction: t - movedEdgeY, position: t, isStart: false }
          elementSnapYFired = true
        }
      }
    }
  }

  // Stage 2: snap-to-start fallback. Only fires when no other- element snap fired on that axis. The
  // dragged element's original edges are added as targets so a tiny drag (within 6px of start)
  // pulls the cursor back to the original position.
  // Lower priority than element-to-element snap so a real alignment opportunity always wins. The
  // `isStart` flag suppresses guide emission (snapping back to start is silent — no alignment line
  // drawn).
  if (!elementSnapXFired) {
    for (const movedEdgeX of movedEdgesX) {
      for (const t of snapToStartX) {
        const dist = Math.abs(movedEdgeX - t)
        if (dist > 0 && dist < SNAP_THRESHOLD) {
          if (!bestSnapX || dist < bestSnapX.dist) {
            bestSnapX = { dist, correction: t - movedEdgeX, position: t, isStart: true }
          }
        }
      }
    }
  }
  if (!elementSnapYFired) {
    for (const movedEdgeY of movedEdgesY) {
      for (const t of snapToStartY) {
        const dist = Math.abs(movedEdgeY - t)
        if (dist > 0 && dist < SNAP_THRESHOLD) {
          if (!bestSnapY || dist < bestSnapY.dist) {
            bestSnapY = { dist, correction: t - movedEdgeY, position: t, isStart: true }
          }
        }
      }
    }
  }

  const finalDx = rawDx + (bestSnapX?.correction ?? 0)
  const finalDy = rawDy + (bestSnapY?.correction ?? 0)
  const guides: SnapGuide[] = []
  // Emit guides for element-edge alignment snaps. Skip the
  // snap-to-start case — snapping back to the original position is
  // silent (no alignment line, just the cursor returning).
  if (bestSnapX && !bestSnapX.isStart) {
    guides.push({ axis: 'x', position: bestSnapX.position })
  }
  if (bestSnapY && !bestSnapY.isStart) {
    guides.push({ axis: 'y', position: bestSnapY.position })
  }

  return { dx: finalDx, dy: finalDy, guides }
}
