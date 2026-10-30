import type { ComputedRef, Ref } from 'vue'
import type { DesignElement as DesignElementApi } from '../../api'
import { designLogger } from '../../helpers/designLogger'
import type { useDesignHandlers } from '../../composables/useDesignHandlers'

export type DesignViewEmits = {
  selectPage: [pageId: string]
  selectElement: [elementId: string]
  reorderElements: [orderedElementIds: string[]]
  createElement: [body: { name: string; type: DesignElementApi['type']; html: string }]
  updateElement: [elementId: string, patch: Partial<DesignElementApi>]
  translateElement: [elementId: string, dx: number, dy: number]
  resizeElement: [elementId: string, patch: Partial<DesignElementApi>]
  deleteElement: [elementId: string]
  htmlChanged: [elementId: string, html: string]
  openChat: [
    payload: {
      pageId: string
      pageName: string
      workspaceItemTaskId: string
    },
  ]
}

export type DesignViewEmit = <K extends keyof DesignViewEmits>(
  event: K,
  ...args: DesignViewEmits[K]
) => void

type Deps = {
  emit: DesignViewEmit
  selectedIds: Ref<Set<string>>
  workspaceId: ComputedRef<string>
  effectiveItemId: ComputedRef<string>
  activePageId: ComputedRef<string>
  designHandlers: ReturnType<typeof useDesignHandlers>
}

export function useDesignElementEvents(deps: Deps) {
  const { emit, selectedIds, workspaceId, effectiveItemId, activePageId, designHandlers } = deps

  // Figma-style multi-select toggle. Plain click (additive=false) replaces the selection with just
  // this element. Shift+click (additive=true) adds or removes membership without disturbing the rest
  // of the selection.
  const handleElementToggle = (elementId: string, additive: boolean): void => {
    if (additive) {
      const next = new Set(selectedIds.value)
      if (next.has(elementId)) next.delete(elementId)
      else next.add(elementId)
      selectedIds.value = next
    } else {
      selectedIds.value = new Set([elementId])
    }
    emit('selectElement', elementId)
  }

  const handleElementUpdate = (patch: Partial<DesignElementApi>): void => {
    if (selectedIds.value.size === 0) return
    // When multiple elements are selected, apply the patch to every one
    // of them (Figma semantics — editing the X/Y in the PropertiesPanel
    // moves the whole selection together).
    if (selectedIds.value.size === 1) {
      const id = selectedIds.value.values().next().value as string
      emit('updateElement', id, patch)
      return
    }
    for (const id of selectedIds.value) {
      emit('updateElement', id, patch)
    }
  }

  /** NEW (2026-08-06, split-move-resize plan) — handler for the `translate` event fired by
   * DesignElement during a single-element drag (move mode). The payload is the cursor DELTA in
   * design-px PLUS the source element id. */
  const handleElementTranslate = (payload: { elementId?: string; dx: number; dy: number }): void => {
    // Prefer the elementId from the event (the drag SOURCE knows what it is).
    // Fall back to selectedIds only if the event doesn't carry it (older
    // callers that emit `{ dx, dy }` without elementId).
    let id: string | undefined = payload.elementId
    if (!id && selectedIds.value.size === 1) {
      id = selectedIds.value.values().next().value as string
    }
    if (!id) {
      designLogger.warn({
        reason: 'handle:translateElement',
        caller: 'DesignView.handleElementTranslate',
        dx: payload.dx,
        dy: payload.dy,
        extra: {
          selectedIdsSize: selectedIds.value.size,
          selectedIdsContents: Array.from(selectedIds.value),
          reason: 'no elementId in event and selectedIds is not exactly 1',
        },
      })
      return
    }
    designLogger.info({
      reason: 'handle:translateElement',
      caller: 'DesignView.handleElementTranslate',
      dx: payload.dx,
      dy: payload.dy,
      extra: { id },
    })
    emit('translateElement', id, payload.dx, payload.dy)
  }

  /** NEW (2026-08-06, split-move-resize plan) — handler for the `resize` event fired by DesignElement
   * during a resize gesture. The payload is the absolute target geometry after applying the cursor
   * delta. Routes through `useDesignHandlers.resizeElement` → POST /resize. */
  const handleElementResize = (patch: Partial<DesignElementApi>): void => {
    if (selectedIds.value.size !== 1) {
      designLogger.warn({
        reason: 'handle:resizeElement',
        caller: 'DesignView.handleElementResize',
        patch,
        extra: { selectedIdsSize: selectedIds.value.size, reason: 'no single selection' },
      })
      return
    }
    const id = selectedIds.value.values().next().value as string
    designLogger.info({
      reason: 'handle:resizeElement',
      caller: 'DesignView.handleElementResize',
      patch,
      extra: { id },
    })
    emit('resizeElement', id, patch)
  }

  const handleElementHtmlChanged = (html: string): void => {
    if (selectedIds.value.size !== 1) return
    // HTML body editing only applies to a single selected element —
    // there's no sensible "merge HTML across 3 elements" semantic.
    const id = selectedIds.value.values().next().value as string
    emit('htmlChanged', id, html)
  }

  const handleElementDelete = (elementId: string): void => {
    emit('deleteElement', elementId)
    // Remove the deleted id from the selection Set (don't clear the
    // whole selection — if the user multi-selected and deleted one,
    // the others should remain selected for further action).
    if (selectedIds.value.has(elementId)) {
      const next = new Set(selectedIds.value)
      next.delete(elementId)
      selectedIds.value = next
    }
  }

  const handleReorderElements = (orderedElementIds: string[]): void => {
    emit('reorderElements', orderedElementIds)
  }

  // LayersPanel emits a structured payload so Shift+click can be
  // distinguished from a plain click. Both call into handleElementToggle.
  const handleLayerSelect = (payload: { elementId: string; additive: boolean }): void => {
    handleElementToggle(payload.elementId, payload.additive)
  }

  // NEW (Chunk 4 Task 4.3 of drag-to-reparent plan): the LayersPanel emits `reparent` after a
  // successful drag-and-drop.
  const handleLayerReparent = (payload: {
    elementIds: string[]
    newParentId: string | null
  }): void => {
    void designHandlers.reparentLayers({
      workspaceId: workspaceId.value,
      itemId: effectiveItemId.value,
      pageId: activePageId.value,
      elementIds: payload.elementIds,
      newParentId: payload.newParentId,
    })
  }

  const handleCreateElement = (body: {
    name: string
    type: DesignElementApi['type']
    html: string
  }): void => {
    emit('createElement', body)
  }

  const handlePropertiesDelete = (elementId: string): void => {
    handleElementDelete(elementId)
  }

  const handlePropertiesUpdate = (patch: Partial<DesignElementApi>): void => {
    handleElementUpdate(patch)
  }

  const handlePropertiesHtmlChanged = (html: string): void => {
    handleElementHtmlChanged(html)
  }

  return {
    handleElementToggle,
    handleElementUpdate,
    handleElementTranslate,
    handleElementResize,
    handleElementHtmlChanged,
    handleElementDelete,
    handleReorderElements,
    handleLayerSelect,
    handleLayerReparent,
    handleCreateElement,
    handlePropertiesDelete,
    handlePropertiesUpdate,
    handlePropertiesHtmlChanged,
  }
}
