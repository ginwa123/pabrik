import type { Ref } from 'vue'
import {
  createDesignPage as createDesignPageApi,
  deleteDesignPage as deleteDesignPageApi,
  listDesignPages as listDesignPagesApi,
  updateDesignPage as updateDesignPageApi,
  type DesignPage,
} from '../../api'

interface DesignPagesParams {
  designPagesByItemId: Ref<Record<string, DesignPage[]>>
  designPagesInFlight: Map<string, Promise<DesignPage[]>>
  activeDesignPageId: Ref<string>
}

export function createDesignPages(p: DesignPagesParams) {
  const { designPagesByItemId, designPagesInFlight, activeDesignPageId } = p

  // Reset design-pages cache for an item. Used on store init so a
  // re-init doesn't show stale pages from the previous session.
  // Currently called from `init()` at the bottom of the file.
  function resetDesignPagesCache(): void {
    designPagesByItemId.value = {}
    designPagesInFlight.clear()
  }

  // Update a design page's width/height (UI resize from the canvas header W × H inputs). Backend's
  // PATCH /pages/:page_id validates the ranges (width 320-4096, height 240-4096) and returns 400
  // with an explicit error message otherwise.
  async function updateDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    patch: { width: number; height: number; name?: string },
  ): Promise<DesignPage> {
    return await updateDesignPageApi(workspaceId, itemId, pageId, patch)
  }

  // NEW (2026-08-06 — design page rename menu). Rename a single design page in-place. Mirrors the
  // optimistic-update + rollback pattern from `renameTask`: 1. Trim the new name; refuse empty /
  // unchanged (no-op → return). 2.
  async function renameDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    newName: string,
  ): Promise<void> {
    const cached = designPagesByItemId.value[itemId] ?? []
    const idx = cached.findIndex((p) => p.id === pageId)
    if (idx === -1) return
    const page = cached[idx]
    if (!page) return

    const trimmed = newName.trim()
    if (!trimmed || trimmed === page.name) return

    const previousName = page.name
    // Optimistic update on the cached struct (Pinia's reactive proxy
    // sees this assignment and re-renders the sidebar tree).
    page.name = trimmed

    try {
      await updateDesignPageApi(workspaceId, itemId, pageId, {
        width: page.width,
        height: page.height,
        name: trimmed,
      })
    } catch (err) {
      // Roll back to the previous name on any error. The cache ref
      // is the same — the rollback re-assignment is visible to
      // every active component reading from the store.
      page.name = previousName
      console.error('Failed to rename design page:', err)
      throw err
    }
  }

  // Delete a page. Idempotent on the backend (404 = already gone).
  async function deleteDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    await deleteDesignPageApi(workspaceId, itemId, pageId)
    // 1. Drop from cache (sidebar tree re-renders without the row).
    const cached = designPagesByItemId.value[itemId] ?? []
    const idx = cached.findIndex((p) => p.id === pageId)
    const remaining = cached.filter((p) => p.id !== pageId)
    designPagesByItemId.value = {
      ...designPagesByItemId.value,
      [itemId]: remaining,
    }
    // 2. If the deleted page was active, fall back to a sensible next page. The pre-fix convention
    // (VS Code / Figma parity): prefer the page AT THE SAME INDEX in the OLD order (i.e. what used
    // to be next), or the previous one if we deleted the last.
    if (activeDesignPageId.value === pageId) {
      if (remaining.length === 0) {
        activeDesignPageId.value = ''
      } else {
        const nextIdx = idx >= remaining.length ? remaining.length - 1 : idx
        activeDesignPageId.value = remaining[nextIdx]?.id ?? ''
      }
    }
  }

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06). Fetch pages for a design workspace item
  // from the backend and cache them in `designPagesByItemId`. Concurrent calls for the same item
  // share the same in-flight promise (no double-fetch on sidebar-expand + DesignView-mount race).
  async function fetchDesignPages(workspaceId: string, itemId: string): Promise<DesignPage[]> {
    const inFlight = designPagesInFlight.get(itemId)
    if (inFlight) return await inFlight
    const p = (async (): Promise<DesignPage[]> => {
      try {
        const { pages } = await listDesignPagesApi(workspaceId, itemId)
        designPagesByItemId.value = {
          ...designPagesByItemId.value,
          [itemId]: pages,
        }
        return pages
      } finally {
        designPagesInFlight.delete(itemId)
      }
    })()
    designPagesInFlight.set(itemId, p)
    return await p
  }

  // NEW: append a new design page to the cache + mirror it on the server, AND set it as the active
  // page so the user immediately sees the empty canvas they can start populating. Returns the
  // created page (with backend-assigned id, timestamps) on success, or `undefined` on failure.
  async function addDesignPage(
    workspaceId: string,
    itemId: string,
    name: string,
  ): Promise<DesignPage | undefined> {
    const created = await createDesignPageApi(workspaceId, itemId, name)
    const existing = designPagesByItemId.value[itemId] ?? []
    designPagesByItemId.value = {
      ...designPagesByItemId.value,
      [itemId]: [...existing, created],
    }
    activeDesignPageId.value = created.id
    return created
  }

  return {
    resetDesignPagesCache,
    updateDesignPage,
    renameDesignPage,
    deleteDesignPage,
    fetchDesignPages,
    addDesignPage,
  }
}
