import type { ComputedRef, Ref } from 'vue'
import type { DesignElement as DesignElementApi } from '../../api'
import { designLogger } from '../../helpers/designLogger'
import type { useDesignHandlers } from '../../composables/useDesignHandlers'
import type { useDesignHistory } from '../../composables/useDesignHistory'
import { computeSnapDelta, type SnapGuide } from './useSnapGuides'

type Deps = {
  workspaceId: ComputedRef<string>
  effectiveItemId: ComputedRef<string>
  activePageId: ComputedRef<string>
  elements: ComputedRef<DesignElementApi[]>
  selectedIds: Ref<Set<string>>
  snapGuides: Ref<SnapGuide[]>
  designHandlers: ReturnType<typeof useDesignHandlers>
  history: ReturnType<typeof useDesignHistory>
}

export function useDesignGroupDrag(deps: Deps) {
  const {
    workspaceId: workspaceIdRef,
    effectiveItemId,
    activePageId,
    elements,
    selectedIds,
    snapGuides,
    designHandlers,
    history,
  } = deps

  // Chunk 2: group drag. BUG FIX (2026-07-29): the original implementation used `el.x + finalDx`
  // where `el.x` is the element's CURRENT position from `elements.value`.
  let dragStartPositions: Map<string, { x: number; y: number }> | null = null

  const handleGroupDrag = (delta: { dx: number; dy: number }): void => {
    console.log('[handleGroupDrag] called', { delta, selectedCount: selectedIds.value.size })
    if (selectedIds.value.size === 0) return
    if (!workspaceIdRef.value || !effectiveItemId.value) return
    if (!activePageId.value) return
    const pageId = activePageId.value
    const itemId = effectiveItemId.value
    const workspaceId = workspaceIdRef.value

    // ─── Snap (Chunk 3) ───────────────────────────────────────────────
    const selected = elements.value.filter((e) => selectedIds.value.has(e.id))
    console.log(
      '[handleGroupDrag] selected elements',
      selected.map((e) => e.id),
    )
    if (selected.length > 0) {
      if (dragStartPositions === null) {
        dragStartPositions = new Map()
        for (const el of selected) {
          dragStartPositions.set(el.id, { x: el.x, y: el.y })
        }
        console.log('[handleGroupDrag] snapshot created (fresh)', {
          size: dragStartPositions.size,
          ids: Array.from(dragStartPositions.keys()),
        })
        designLogger.info({
          reason: 'handle:dragStart:resetSnapshot',
          caller: 'DesignView.handleGroupDrag',
          snapshotFresh: true,
          snapshotSize: dragStartPositions.size,
          extra: { ids: Array.from(dragStartPositions.keys()) },
        })
      } else {
        console.warn('[handleGroupDrag] STALE SNAPSHOT detected', {
          size: dragStartPositions.size,
          ids: Array.from(dragStartPositions.keys()),
        })
        designLogger.warn({
          reason: 'handle:dragStart:resetSnapshot',
          caller: 'DesignView.handleGroupDrag',
          snapshotFresh: false,
          snapshotSize: dragStartPositions.size,
          extra: {
            ids: Array.from(dragStartPositions.keys()),
            note: 'dragStartPositions was NOT null on entry — likely a leaked snapshot from the previous drag',
          },
        })
      }
      const originalPos = (e: DesignElementApi): { x: number; y: number } =>
        dragStartPositions!.get(e.id) ?? { x: e.x, y: e.y }

      const minX = Math.min(...selected.map((e) => originalPos(e).x + delta.dx))
      const minY = Math.min(...selected.map((e) => originalPos(e).y + delta.dy))
      const maxX = Math.max(...selected.map((e) => originalPos(e).x + delta.dx + e.width))
      const maxY = Math.max(...selected.map((e) => originalPos(e).y + delta.dy + e.height))
      const unionBbox = {
        id: '__union__',
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY,
      }
      console.log('[handleGroupDrag] unionBbox', unionBbox)

      const others = elements.value.filter((e) => !selectedIds.value.has(e.id))
      console.log('[handleGroupDrag] snap targets (others) count', others.length)

      const snapResult = computeSnapDelta([unionBbox, ...others], '__union__', 0, 0)
      console.log('[handleGroupDrag] snapResult', snapResult)

      snapGuides.value = snapResult.guides
      const finalDx = delta.dx + snapResult.dx
      const finalDy = delta.dy + snapResult.dy
      console.log('[handleGroupDrag] finalDx/finalDy', {
        finalDx,
        finalDy,
        rounded: { dx: Math.round(finalDx), dy: Math.round(finalDy) },
      })

      void designHandlers.moveElementWithDescendants({
        workspaceId,
        itemId,
        pageId,
        items: selected.map((el) => ({
          element_id: el.id,
          dx: Math.round(finalDx),
          dy: Math.round(finalDy),
        })),
      })
      console.log('[handleGroupDrag] moveElementWithDescendants dispatched', {
        workspaceId,
        itemId,
        pageId,
        count: selected.length,
      })

      designLogger.info({
        reason: 'handle:groupDrag',
        caller: 'DesignView.handleGroupDrag',
        ids: selected.map((el) => el.id),
        dx: Math.round(finalDx),
        dy: Math.round(finalDy),
        workspaceId,
        itemId,
        pageId,
      })
      return
    }
  }

  // Undo/redo plan (Chunk 4): gesture boundary capture. The pre-state is captured at drag-start
  // (pointerdown); the post- state at drag-end (pointerup trailing emit). REGRESSION (2026-07-30):
  // this handler REPLACED the original `clearSnapGuides` on the `@drag-end` binding.
  const handleDragStart = (ids: string[]): void => {
    void history.capturePreState(ids)
  }
  const handleDragEnd = (): void => {
    designLogger.info({
      reason: 'handle:dragEnd:snapshot=null',
      caller: 'DesignView.handleDragEnd',
      extra: { previousSnapshotSize: 'reset to null' },
    })
    dragStartPositions = null
    void history
      .capturePostState(
        // For single-element drag, ids is implicit (just this element). For multi-element drag, ids
        // has been captured. We pass an empty array as a safety net — capturePostState re-reads the
        // live state from the store and diffs against the pre-state we captured above.
        Array.from(selectedIds.value),
      )
      .then(() => {
        snapGuides.value = []
      })
  }

  return { handleGroupDrag, handleDragStart, handleDragEnd }
}
