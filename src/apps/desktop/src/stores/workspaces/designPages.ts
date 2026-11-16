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

  // Reset design-pages cache for an item.
  function resetDesignPagesCache(): void {
    designPagesByItemId.value = {}
    designPagesInFlight.clear()
  }

  // Update a design page's width/height (UI resize from the canvas header W × H inputs).
  async function updateDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    patch: { width: number; height: number; name?: string },
  ): Promise<DesignPage> {
    return await updateDesignPageApi(workspaceId, itemId, pageId, patch)
  }

  // NEW (2026-08-06 — design page rename menu).
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
    // Optimistic update on the cached struct (Pinia's reactive proxy sees this assignment and re-renders the sidebar tree).
    page.name = trimmed

    try {
      await updateDesignPageApi(workspaceId, itemId, pageId, {
        width: page.width,
        height: page.height,
        name: trimmed,
      })
    } catch (err) {
      // Roll back to the previous name on any error.
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
    // 2.
    if (activeDesignPageId.value === pageId) {
      if (remaining.length === 0) {
        activeDesignPageId.value = ''
      } else {
        const nextIdx = idx >= remaining.length ? remaining.length - 1 : idx
        activeDesignPageId.value = remaining[nextIdx]?.id ?? ''
      }
    }
  }

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06).
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

  // NEW: append a new design page to the cache + mirror it on the server, AND set it as the active page so the user immediately sees the empty canvas they can …
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
