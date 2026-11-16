import { apiFetch } from './client'

/** Wire shape for `GET .../design/pages` (list envelope) and `POST .../design/pages` (single page). */
export interface DesignPage {
  id: string
  workspace_item_id: string
  name: string
  /** 1:1 FK to `workspace_item_tasks.id`, set at page-create time. */
  workspace_item_task_id: string
  width: number
  height: number
  position: number
  created_at: string
  updated_at: string
}

/** Element types emitted by the backend's `ElementType` enum. */
export const normalizeDesignElementType = <
  T extends { type?: DesignElementType; elem_type?: string },
>(
  e: T,
): T & { type: DesignElementType } => {
  const fallback: DesignElementType = (e.elem_type as DesignElementType) ?? 'rectangle'
  return { ...e, type: e.type ?? fallback }
}

export type DesignElementType = 'rectangle' | 'ellipse' | 'text' | 'image' | 'frame' | 'group'

/** Wire shape for design elements (rows in `design_page_elements`). */
export interface DesignElement {
  id: string
  page_id: string
  name: string
  type: DesignElementType
  x: number
  y: number
  width: number
  height: number
  rotation: number
  fill: string
  stroke: string
  stroke_width: number
  corner_radius: number
  opacity: number
  text_content: string
  text_style: string
  image_url: string
  file_path: string
  // NEW (Chunk 5 of grouped-layers plan): FK to a `group`/`frame` element on the same page.
  parent_id?: string | null
  z_index: number
  position: number
  created_at: string
  updated_at: string
}

/** Geometry-only patch payload for `PATCH .../design/pages/:page_id/elements/:element_id/geometry`. */
export interface DesignElementGeometry {
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/** Wire shape for design-mode SSE events (`design_element_created` / `_updated` / `_deleted`). */
export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  page_id: string
  element_id: string
  /** Batch event variant (`design_elements_geometry_batch_updated`). */
  element_ids?: string[]
}

// ===================================================================== Design Mode API (v6.
export async function listDesignPages(
  workspaceId: string,
  itemId: string,
): Promise<{ pages: DesignPage[]; count: number }> {
  return await apiFetch<{ pages: DesignPage[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages`,
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages Create a new design page. */
export async function createDesignPage(
  workspaceId: string,
  itemId: string,
  name: string,
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(`/workspaces/${workspaceId}/items/${itemId}/design/pages`, {
    method: 'POST',
    body: { name },
  })
}

/** PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Update an existing design page. */
export async function updateDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
  patch: { width: number; height: number; name?: string },
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'PATCH', body: patch },
  )
}

/** GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Fetch a single page plus its full element list (HTML bodies EXCLUDED — fetch lazily via … */
export async function getDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ page: DesignPage; elements: DesignElement[] }> {
  return await apiFetch<{ page: DesignPage; elements: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements Add a new element to a page. */
export async function addDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: {
    name: string
    type: DesignElementType
    html: string
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    [k: string]: any
  },
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements`,
    { method: 'POST', body },
  )
}

/** PUT /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId Full update of an element. */
export async function updateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  patch: Partial<DesignElement>,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'PUT', body: patch },
  )
}

/** Wire shape for `POST .../design/pages/:pageId/elements/group`. */
export interface GroupDesignElementsRequest {
  child_ids: string[]
  name?: string
  type?: 'group' | 'frame'
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/group NEW (Chunk 5 of grouped-layers plan). */
export async function groupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: GroupDesignElementsRequest,
): Promise<{ parent: DesignElement; children: DesignElement[] }> {
  return await apiFetch<{ parent: DesignElement; children: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/group`,
    { method: 'POST', body },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reorder NEW (Chunk 5 of right-click group menu plan). */
export type ReorderMode = 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'

export interface ReorderDesignElementsRequest {
  mode: ReorderMode
  element_ids: string[]
}

export async function reorderDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReorderDesignElementsRequest,
): Promise<{ reordered: DesignElement[] }> {
  return await apiFetch<{ reordered: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reorder`,
    { method: 'POST', body },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reparent-batch NEW (Chunk 1b of drag-to-reparent plan). */
export interface ReparentDesignElementsBatchRequest {
  element_ids: string[]
  /** null = top-level (leave any current group). */
  new_parent_id: string | null
  /** Currently only "last_in_parent" is supported. */
  reposition: 'last_in_parent'
}

export interface ReparentDesignElementsBatchResponse {
  updated: DesignElement[]
}

export async function reparentDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReparentDesignElementsBatchRequest,
): Promise<ReparentDesignElementsBatchResponse> {
  return await apiFetch<ReparentDesignElementsBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reparent-batch`,
    { method: 'POST', body },
  )
}

/** DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId Idempotent delete. */
export async function deleteDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'DELETE' },
  )
}

/** POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/ungroup Dissolve a `group` or `frame` element: reparent its direct children to … */
export async function ungroupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ orphaned: DesignElement[] }> {
  return await apiFetch<{ orphaned: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/ungroup`,
    { method: 'POST', body: { element_id: elementId } },
  )
}

/** DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId Delete a design page. */
export async function deleteDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'DELETE' },
  )
}

/** GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html Lazy-load a single element's HTML body. */
export async function getDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ html: string }> {
  return await apiFetch<{ html: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
  )
}

/** PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html Persist a new HTML body for an element. */
export async function updateDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  html: string,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
    { method: 'PATCH', body: { html } },
  )
}
