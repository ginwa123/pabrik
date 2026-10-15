/**
 * Pure-logic composable that backs the LayersPanel drag-and-drop
 * affordance. Owns the drag state machine + per-element visual
 * class predicates.
 *
 * Multi-drag semantics (per D4 of the plan):
 *   - When the dragged row is in `selectedIds` AND the selection
 *     has > 1 element, the WHOLE selection is dragged together.
 *   - Otherwise, the single dragged row is dragged.
 *
 * Cycle preflight (per D5 of the plan):
 *   - A target row is invalid if it's the target itself OR any
 *     dragged element is a descendant of the target (would close a
 *     cycle on reparent).
 *   - Leaf types (rectangle/ellipse/text/image) are always invalid
 *     drop targets — only group/frame can accept children.
 *   - The TOP_LEVEL_SENTINEL id is always valid (leaving a group
 *     never creates a cycle).
 *
 * Top-level drop zones (3 per page: above the first top-level row,
 * between each pair, below the last) use the TOP_LEVEL_SENTINEL as
 * their target id — the LayersPanel renders them.
 *
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
 * (Chunk 3 Task 3.1)
 */
import { computed, ref, type Ref } from 'vue'

import type { DesignElement } from '../api'

/** Sentinel id for the top-level drop zones (above/below top-level rows). */
export const TOP_LEVEL_SENTINEL = '__design_top_level__'

export interface LayerDragDropArgs {
  /** Reactive list of all elements on the active page. Accepts:
   *  - a getter () => array | Ref<array> (for live computed refs)
   */
  elements:
    | DesignElement[]
    | Ref<DesignElement[]>
    | (() => DesignElement[] | Ref<DesignElement[]>)
  /** Optional reactive selectedIds (same union). When the dragged
   *  row is in this Set AND its size > 1, the whole set is dragged
   *  together. */
  selectedIds?: Set<string> | Ref<Set<string>> | (() => Set<string> | null)
}

export interface DropResult {
  /** Always in insertion order — matches the input order from
   *  selectedIds (or just the dragged row id for single-drag). */
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

  // Walk the parent_id chain upward from `descendant_id`. Returns true iff `ancestor_id` is
  // `descendant_id`'s parent OR any ancestor of `descendant_id` (i.e., reparenting `descendant_id`
  // under `ancestor_id` would be valid — not a cycle).
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

  // A target is a valid drop zone iff: - For TOP_LEVEL_SENTINEL: always valid. - For a real row id:
  // that row is `group` or `frame`, AND NONE of the dragged elements is the target itself OR a
  // descendant of the target (cycle check).
  function isValidDropTarget(targetId: string, sourceIds: Set<string>): boolean {
    if (targetId === TOP_LEVEL_SENTINEL) return true
    const t = elements.value.find((e) => e.id === targetId)
    if (!t) return false
    // Only group/frame can contain children.
    if (t.type !== 'group' && t.type !== 'frame') return false
    // Block ANY dragged element being the target itself OR an ancestor of the target (cycle check:
    // reparenting src under targetId would close a cycle if src is reachable from targetId's parent
    // chain).
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
    // Multi-drag: if the dragged row is in selectedIds AND the
    // selection has > 1 element, drag the whole set. Otherwise
    // drag just this row.
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