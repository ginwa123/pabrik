import type { Ref } from 'vue'
import * as api from '../../api'
import {
  addDesignElement as addDesignElementApi,
  deleteDesignElement as deleteDesignElementApi,
  groupDesignElements as groupDesignElementsApi,
  reorderDesignElements as reorderDesignElementsApi,
  reparentDesignElementsBatch as reparentDesignElementsBatchApi,
  ungroupDesignElements as ungroupDesignElementsApi,
  updateDesignElement as updateDesignElementApi,
  updateDesignElementHtml as updateDesignElementHtmlApi,
  type GroupDesignElementsRequest,
  type ReparentDesignElementsBatchRequest,
  type ReorderMode,
} from '../../api'
import { designLogger } from '../../helpers/designLogger'
import type { DesignElement } from '../../api'
import type { Workspace, WorkspaceItem } from './types'

interface DesignElementsParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
  designElementsLoadingKey: Ref<string | null>
  activeDesignPageId: Ref<string>
}

export function createDesignElements(p: DesignElementsParams) {
  const { findItem, designElementsLoadingKey, activeDesignPageId } = p

  // ─── Design mode actions (Chunk 6 of design-mode-redesign plan) ────── These 5 actions back the
  // design canvas / layers panel / properties panel UI of the v6 Figma-lite design mode.
  async function fetchDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mark this page's element fetch in flight so DesignView's canvas, LayersPanel and
    // PropertiesPanel can hold a skeleton instead of rendering their empty states — "Click +
    // Element to add your first element" is a false statement while the fetch is outstanding.
    designElementsLoadingKey.value = `${itemId}:${pageId}`
    try {
      const { elements } = await api.getDesignPage(workspaceId, itemId, pageId)
      // Mirror in PLACE (per-id replace + splice + append) rather than `item.design_elements =
      // elements`.
      if (!item.design_elements) {
        item.design_elements = elements
        designLogger.warn({
          reason: 'fetch:replaced-array',
          caller: 'workspacesStore.fetchDesignElements',
          endpoint: '/design/pages/:page_id (GET)',
          workspaceId,
          itemId,
          pageId,
          mirrorCount: elements.length,
          extra: {
            note: 'item.design_elements was undefined — assigned the full array (the OLD bug pattern)',
          },
        })
        return
      }
      designLogger.info({
        reason: 'fetch:in-place-mirror',
        caller: 'workspacesStore.fetchDesignElements',
        endpoint: '/design/pages/:page_id (GET)',
        workspaceId,
        itemId,
        pageId,
        mirrorCount: elements.length,
        extra: { preExistingCount: item.design_elements.length },
      })
      // Build a Map<id, incomingElement> for O(1) lookup.
      const incomingById = new Map<string, (typeof elements)[number]>()
      for (const el of elements) incomingById.set(el.id, el)
      // Walk the local array. For each existing row: - if its id is in the incoming set, replace in
      // place - if its id is NOT in the incoming set, mark for splice We splice from the end so the
      // live indices stay valid.
      const toSplice: number[] = []
      for (let i = 0; i < item.design_elements.length; i++) {
        const existing = item.design_elements[i]!
        const next = incomingById.get(existing.id)
        if (next) {
          item.design_elements[i] = next
          incomingById.delete(existing.id)
        } else {
          toSplice.push(i)
        }
      }
      // Splice deletions from the end (preserves earlier indices).
      for (let i = toSplice.length - 1; i >= 0; i--) {
        item.design_elements.splice(toSplice[i]!, 1)
      }
      // Append any incoming elements that weren't already in the
      // array (newly created elsewhere — LLMs, other tabs).
      for (const remaining of incomingById.values()) {
        item.design_elements.push(remaining)
      }
    } catch (err) {
      console.error('[workspacesStore.fetchDesignElements] API call failed:', err)
      // Leave the existing elements array untouched so the UI
      // doesn't flash to empty on a transient network blip. The
      // next SSE event will trigger another fetch.
    } finally {
      // Cleared on BOTH paths so a failed fetch cannot park the
      // skeleton — the surfaces fall back to their empty states, which
      // is the honest answer when the request failed.
      designElementsLoadingKey.value = null
    }
  }

  // Add an element to a design page and append it to the local item's `design_elements` array. The
  // backend returns the full element with server-assigned id / position / timestamps. We push (not
  // unshift) to match the backend's ordering (oldest first by position).
  async function addDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: {
      name: string
      type: DesignElement['type']
      html: string
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      [k: string]: any
    },
  ): Promise<DesignElement> {
    const newElem = await addDesignElementApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      item.design_elements.push(newElem)
    }
    return newElem
  }

  // Patch an element's fields (full update — backend applies a sparse merge). Replaces the local
  // copy in place so the canvas re-renders the patched element immediately. Used by the
  // PropertiesPanel (form input changes) and the LLM tool-driven update_element handler.
  async function updateDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    patch: Partial<DesignElement>,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementApi(workspaceId, itemId, pageId, elementId, patch)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // HTML body-only update (Monaco Save button). Mirrors the `updateDesignElement` shape: PATCHes
  // the dedicated html endpoint, mirrors the response into the local design_elements array.
  async function updateDesignElementHtml(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    html: string,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementHtmlApi(workspaceId, itemId, pageId, elementId, html)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // Delete an element. Idempotent on the backend (returns
  // `{success: true}` whether the row existed or not). Filters
  // the local `design_elements` array to remove the row.
  async function deleteDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<void> {
    await deleteDesignElementApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      item.design_elements = item.design_elements.filter((e) => e.id !== elementId)
    }
  }

  // Wrap 2+ elements into a new `group` (or `frame`) parent at the union bbox. The backend returns
  // the full new parent + the updated children (with `parent_id` set).
  async function reorderDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    mode: ReorderMode,
    elementIds: string[],
  ): Promise<DesignElement[]> {
    const result = await reorderDesignElementsApi(workspaceId, itemId, pageId, {
      mode,
      element_ids: elementIds,
    })
    // Mirror the server's `reordered` rows into the local design_elements array so the layers panel
    // + canvas re-render immediately. We replace matching ids in place (preserves the local array's
    // ordering for any ids NOT in the response).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.reordered) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.reordered
  }

  async function groupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: GroupDesignElementsRequest,
  ): Promise<{ parent: DesignElement; children: DesignElement[] }> {
    const result = await groupDesignElementsApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      // Append the new parent (preserves backend ordering: highest
      // position last).
      item.design_elements.push(result.parent)
      // Replace each child in place. We don't filter the array first because the backend's returned
      // children are already updated versions; the originals are still useful for comparison in
      // tests but the in-place replace keeps the array length stable.
      for (const updated of result.children) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result
  }

  // Atomic N-element reparent (1 OR many). Used by the LayersPanel drag-and-drop affordance. The
  // whole batch is all-or-nothing — the backend rejects with 400 BadReparent if ANY element would
  // close a cycle, and 0 writes happen.
  async function reparentDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: Omit<ReparentDesignElementsBatchRequest, 'reposition'> & {
      reposition?: ReparentDesignElementsBatchRequest['reposition']
    },
  ): Promise<DesignElement[]> {
    const reposition = body.reposition ?? 'last_in_parent'
    const result = await reparentDesignElementsBatchApi(workspaceId, itemId, pageId, {
      element_ids: body.element_ids,
      new_parent_id: body.new_parent_id,
      reposition,
    })
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.updated
  }

  // Dissolve a group/frame: reparent its direct children to the group's parent (or top-level if the
  // group had no parent), then delete the group row.
  async function ungroupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<{ orphaned: DesignElement[] }> {
    const result = await ungroupDesignElementsApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item && item.design_elements) {
      // Replace each orphaned child in place.
      for (const updated of result.orphaned) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
      // Remove the group row itself.
      const group_idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (group_idx !== -1) item.design_elements.splice(group_idx, 1)
    }
    return result
  }

  // Move a single element (and its subtree when apply_to_children=true) from `sourcePageId` to
  // `newPageId`. Backend returns the moved elements; we mirror by: 1.
  async function moveDesignElementToPage(
    workspaceId: string,
    itemId: string,
    sourcePageId: string,
    elementId: string,
    input: {
      new_page_id: string
      apply_to_children?: boolean
    },
  ): Promise<DesignElement[] | undefined> {
    try {
      const { updated } = await api.moveDesignElementToPage(
        workspaceId,
        itemId,
        sourcePageId,
        elementId,
        input,
      )
      const item = findItem(workspaceId, itemId)
      // Mirror: remove moved ids from the source page's elements if
      // they're in local memory (the source page is the active page).
      if (item && item.design_elements && activeDesignPageId.value === sourcePageId) {
        const movedIds = new Set(updated.map((el) => el.id))
        for (let i = item.design_elements.length - 1; i >= 0; i--) {
          if (movedIds.has(item.design_elements[i]!.id)) {
            item.design_elements.splice(i, 1)
          }
        }
      }
      // Q6 default: navigate to the target page. Also triggers the
      // existing watcher to refetch the target page's elements.
      activeDesignPageId.value = input.new_page_id
      // Re-fetch the target page explicitly so the canvas reflects the
      // moved elements immediately (the watcher's debounce may add
      // latency the user notices on click).
      await fetchDesignElements(workspaceId, itemId, input.new_page_id)
      return updated
    } catch (err) {
      console.error('[workspacesStore.moveDesignElementToPage] API call failed:', err)
      return undefined
    }
  }

  return {
    // Design mode actions (Chunk 6 of design-mode-redesign plan)
    fetchDesignElements,
    addDesignElement,
    updateDesignElement,
    updateDesignElementHtml,
    deleteDesignElement,
    reorderDesignElements,
    groupDesignElements,
    reparentDesignElementsBatch,
    ungroupDesignElements,
    moveDesignElementToPage,
  }
}
