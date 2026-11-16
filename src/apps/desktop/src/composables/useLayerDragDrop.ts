/** Pure-logic composable that backs the LayersPanel drag-and-drop affordance. */
import { computed, ref, type Ref } from 'vue'

import type { DesignElement } from '../api'

/** Sentinel id for the top-level drop zones (above/below top-level rows). */
export const TOP_LEVEL_SENTINEL = '__design_top_level__'

export interface LayerDragDropArgs {
  /** Reactive list of all elements on the active page. Accepts */
  elements:
    | DesignElement[]
    | Ref<DesignElement[]>
    | (() => DesignElement[] | Ref<DesignElement[]>)
  /** Optional reactive selectedIds (same union). */
  selectedIds?: Set<string> | Ref<Set<string>> | (() => Set<string> | null)
}

export interface DropResult {
  /** Always in insertion order — matches the input order from selectedIds (or just the dragged row id for single-drag). */
  elementIds: string[]
  /** null = leave any current group, become top-level. */
  newParentId: string | null
}

export function useLayerDragDrop(args: LayerDragDropArgs) {
  const draggedIds = ref<Set<string>>(new Set())
  const hoveredDropId = ref<string | null>(null)

  // Normalize the args to a `() => DesignElement[]` getter.
  function resolveElements(): DesignElement[] {
    const e = args.elements
    if (typeof e === 'function') {
      const v = e()
      return Array.isArray(v) ? v : v.value
    }
    return Array.isArray(e) ? e : e.value
  }

  function resolveSelectedIds(): Set<string> | null {
    const s = args.selectedIds
    if (s === undefined) return null
    if (typeof s === 'function') return s()
    if (typeof s === 'object' && 'value' in s) return (s as Ref<Set<string>>).value
    return s as Set<string>
  }

  const elements = computed<DesignElement[]>(resolveElements)

  // Walk the parent_id chain upward from `descendant_id`.
  function isAncestor(targetAncestor: string, descendantId: string): boolean {
    let current: string | null = descendantId
    for (let depth = 0; depth < 1024; depth++) {
      const e = elements.value.find((x) => x.id === current)
      if (!e) return false
      if (e.parent_id && e.parent_id === targetAncestor) return true
      current = e.parent_id && e.parent_id.length > 0 ? e.parent_id : null
      if (current === null) return false
    }
    return false
  }

  // A target is a valid drop zone iff: - For TOP_LEVEL_SENTINEL: always valid. - For a real row id
  function isValidDropTarget(targetId: string, sourceIds: Set<string>): boolean {
    if (targetId === TOP_LEVEL_SENTINEL) return true
    const t = elements.value.find((e) => e.id === targetId)
    if (!t) return false
    // Only group/frame can contain children.
    if (t.type !== 'group' && t.type !== 'frame') return false
    // Block ANY dragged element being the target itself OR an ancestor of the target (cycle check
    for (const src of sourceIds) {
      if (targetId === src) return false
      if (isAncestor(src, targetId)) return false
    }
    return true
  }

  function isDropTarget(targetId: string): boolean {
    if (draggedIds.value.size === 0) return false
    return isValidDropTarget(targetId, draggedIds.value)
  }

  function isBeingDragged(id: string): boolean {
    return draggedIds.value.has(id)
  }

  function onDragStart(rowId: string, _event: DragEvent | Event): void {
    // Multi-drag: if the dragged row is in selectedIds AND the selection has > 1 element, drag the whole set.
    const sel = resolveSelectedIds()
    if (sel && sel.has(rowId) && sel.size > 1) {
      draggedIds.value = new Set(sel)
    } else {
      draggedIds.value = new Set([rowId])
    }
  }

  function onDragOver(targetId: string, _event: DragEvent | Event): void {
    if (draggedIds.value.size === 0) return
    hoveredDropId.value = isValidDropTarget(targetId, draggedIds.value)
      ? targetId
      : null
  }

  function onDragLeave(_targetId: string, _event: DragEvent | Event): void {
    hoveredDropId.value = null
  }

  function onDragEnd(_event: DragEvent | Event): void {
    draggedIds.value = new Set()
    hoveredDropId.value = null
  }

  function onDrop(targetId: string, _event: DragEvent | Event): DropResult | null {
    const source = new Set(draggedIds.value)
    draggedIds.value = new Set()
    hoveredDropId.value = null
    if (source.size === 0) return null
    if (!isValidDropTarget(targetId, source)) return null
    return {
      elementIds: Array.from(source),
      newParentId: targetId === TOP_LEVEL_SENTINEL ? null : targetId,
    }
  }

  return {
    state: { draggedIds, hoveredDropId, isDropTarget, isBeingDragged },
    handlers: { onDragStart, onDragOver, onDragLeave, onDrop, onDragEnd },
  }
}