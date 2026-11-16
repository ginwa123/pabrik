import { apiFetch } from './client'
import type { DesignElement, DesignElementGeometry } from './designElements'

/** PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/geometry ⚠️ DEPRECATED — replaced by `translateDesignElement` (move) … */
export async function updateDesignElementGeometry(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/geometry`,
    { method: 'PATCH', body: geometry },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/translate NEW (2026-08-06) — single-element translate (move). */
export async function translateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  dx: number,
  dy: number,
): Promise<{ updated: DesignElement[] }> {
  return await apiFetch<{ updated: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/translate`,
    { method: 'POST', body: { dx, dy } },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/resize NEW (2026-08-06) — single-element resize. */
export async function resizeDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/resize`,
    { method: 'POST', body: geometry },
  )
}

/** Per-element geometry patch for the batch endpoint. */
export interface GeometryBatchUpdate {
  element_id: string
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/** Response from `POST .../geometry-batch`. */
export interface GeometryBatchUpdateResponse {
  updated: DesignElement[]
}

/** Atomic N-element geometry update. */
export async function updateDesignElementsGeometryBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  updates: GeometryBatchUpdate[],
): Promise<GeometryBatchUpdateResponse> {
  return await apiFetch<GeometryBatchUpdateResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/geometry-batch`,
    { method: 'POST', body: { updates } },
  )
}

/** Server-side cascade move. */
export interface MoveBatchItem {
  element_id: string
  /** Translation delta in CSS px. Cascades to descendants. */
  dx: number
  dy: number
  /** Optional. Applies ONLY to the element_id (not descendants). */
  width?: number
  height?: number
  rotation?: number
}

export interface MoveBatchInput {
  items: MoveBatchItem[]
}

export interface MoveBatchResponse {
  updated: DesignElement[]
}

export async function moveDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  input: MoveBatchInput,
): Promise<MoveBatchResponse> {
  return await apiFetch<MoveBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/move-batch`,
    { method: 'POST', body: input },
  )
}

/** Move an element to a different page in the same design item. */
export interface MoveElementToPageInput {
  /** REQUIRED. The destination page id. Must be on the same design item. */
  new_page_id: string
  /** Default true. When true, every transitive descendant moves too. */
  apply_to_children?: boolean
}

export interface MoveElementToPageResponse {
  updated: DesignElement[]
}

export async function moveDesignElementToPage(
  workspaceId: string,
  itemId: string,
  sourcePageId: string,
  elementId: string,
  input: MoveElementToPageInput,
): Promise<MoveElementToPageResponse> {
  return await apiFetch<MoveElementToPageResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${sourcePageId}/elements/${elementId}/move-to-page`,
    { method: 'POST', body: input },
  )
}
