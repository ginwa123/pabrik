import type { Ref } from 'vue'
import {
  moveDesignElementsBatch as moveDesignElementsBatchApi,
  normalizeDesignElementType,
  resizeDesignElement as resizeDesignElementApi,
  translateDesignElement as translateDesignElementApi,
  updateDesignElementGeometry as updateDesignElementGeometryApi,
  updateDesignElementsGeometryBatch as updateDesignElementsGeometryBatchApi,
  type GeometryBatchUpdate,
  type MoveBatchItem,
} from '../../api'
import { designLogger } from '../../helpers/designLogger'
import { RECENT_MUTATION_TTL_MS, registerRecentLocalMutations } from './mutationDedupe'
import type { DesignElement } from '../../api'
import type { Workspace, WorkspaceItem } from './types'

interface DesignGeometryParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
}

export function createDesignGeometry(p: DesignGeometryParams) {
  const { findItem } = p

  // Geometry-only update path (drag/resize fires at the 50 ms throttle, i.e. ≤20 Hz).
  async function updateDesignElementGeometry(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    geometry: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<DesignElement> {
    const result = await updateDesignElementGeometryApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      geometry,
    )
    // Mirror the response into the local cache.
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = result
    }
    registerRecentLocalMutations([elementId], Date.now() + RECENT_MUTATION_TTL_MS)
    return result
  }

  // NEW (2026-08-06, split-move-resize plan) — single-element translate (move).
  async function translateDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    dx: number,
    dy: number,
  ): Promise<DesignElement[]> {
    designLogger.info({
      reason: 'store:translateDesignElement:api',
      caller: 'workspacesStore.translateDesignElement',
      endpoint: '/translate',
      dx,
      dy,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    const result = await translateDesignElementApi(workspaceId, itemId, pageId, elementId, dx, dy)
    // Build a Map<id, index> for O(1) lookup; cascade can return 10+ elements (group + children + grandchildren).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idxById = new Map<string, number>()
      for (let i = 0; i < item.design_elements.length; i++) {
        idxById.set(item.design_elements[i]!.id, i)
      }
      for (const updated of result.updated) {
        const idx = idxById.get(updated.id)
        if (idx !== undefined) item.design_elements[idx] = updated
      }
    }
    registerRecentLocalMutations(
      result.updated.map((e) => e.id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    designLogger.info({
      reason: 'store:translateDesignElement:mirror',
      caller: 'workspacesStore.translateDesignElement',
      ids: result.updated.map((e) => e.id),
      mirrorCount: result.updated.length,
      endpoint: '/translate',
      dx,
      dy,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    return result.updated
  }

  // NEW (2026-08-06, split-move-resize plan) — single-element resize.
  async function resizeDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    geometry: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<DesignElement> {
    designLogger.info({
      reason: 'store:resizeDesignElement:api',
      caller: 'workspacesStore.resizeDesignElement',
      endpoint: '/resize',
      patch: geometry,
      workspaceId,
      itemId,
      pageId,
      extra: { elementId },
    })
    const result = await resizeDesignElementApi(workspaceId, itemId, pageId, elementId, geometry)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = result
    }
    registerRecentLocalMutations([elementId], Date.now() + RECENT_MUTATION_TTL_MS)
    designLogger.info({
      reason: 'store:resizeDesignElement:mirror',
      caller: 'workspacesStore.resizeDesignElement',
      endpoint: '/resize',
      ids: [elementId],
      mirrorCount: 1,
      workspaceId,
      itemId,
      pageId,
      extra: { x: result.x, y: result.y, w: result.width, h: result.height, r: result.rotation },
    })
    return result
  }

  // Atomic N-element geometry update.
  async function updateDesignElementsGeometryBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    updates: GeometryBatchUpdate[],
  ): Promise<DesignElement[]> {
    if (updates.length === 0) return []
    const result = await updateDesignElementsGeometryBatchApi(workspaceId, itemId, pageId, updates)
    // Mirror every updated row into the local design_elements array in input order (preserves the array's existing order).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    // Register all affected element ids so the SSE handler skips the GET fan-out.
    registerRecentLocalMutations(
      updates.map((u) => u.element_id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    return result.updated
  }

  // Server-side cascade move.
  async function moveDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    items: MoveBatchItem[],
  ): Promise<DesignElement[]> {
    if (items.length === 0) return []
    designLogger.info({
      reason: 'store:moveDesignElementsBatch:api',
      caller: 'workspacesStore.moveDesignElementsBatch',
      endpoint: '/move-batch',
      ids: items.map((i) => i.element_id),
      workspaceId,
      itemId,
      pageId,
      extra: {
        itemCount: items.length,
        sample: items[0] ? { id: items[0].element_id, dx: items[0].dx, dy: items[0].dy } : null,
      },
    })
    const result = await moveDesignElementsBatchApi(workspaceId, itemId, pageId, { items })
    // Mirror every updated row into the local design_elements array (preserves the array's existing order for non-affected elements).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      // Build a Map<id, index> for O(1) lookup; the cascade can include 10+ elements (group + children + grandchildren) and repeated findIndex inside the loop is O(n²).
      const idxById = new Map<string, number>()
      for (let i = 0; i < item.design_elements.length; i++) {
        idxById.set(item.design_elements[i]!.id, i)
      }
      for (const updated of result.updated) {
        const idx = idxById.get(updated.id)
        if (idx !== undefined) {
          // Normalize `type` from either `type` (canonical) or `elem_type` (legacy).
          item.design_elements[idx] = normalizeDesignElementType(updated) as DesignElement
        }
      }
    }
    // Register all cascaded ids so the SSE handler skips the GET fan-out.
    registerRecentLocalMutations(
      result.updated.map((e) => e.id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    designLogger.info({
      reason: 'store:moveDesignElementsBatch:mirror',
      caller: 'workspacesStore.moveDesignElementsBatch',
      endpoint: '/move-batch',
      ids: result.updated.map((e) => e.id),
      mirrorCount: result.updated.length,
      workspaceId,
      itemId,
      pageId,
      extra: {
        inputItemCount: items.length,
        cascadeExpandedTo: result.updated.length,
        cascade: result.updated.length > items.length,
      },
    })
    return result.updated
  }

  return {
    updateDesignElementGeometry,
    translateDesignElement,
    resizeDesignElement,
    updateDesignElementsGeometryBatch,
    moveDesignElementsBatch,
  }
}
