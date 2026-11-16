import { useKanbanSseStore } from '../../stores/kanbanSse'
import { useDesignSseStore } from '../../stores/designSse'
import { useDocumentsSseStore } from '../../stores/documentsSse'

export interface UseAppLayoutSseReturn {
  initSseStores: (newId: string) => Promise<void>
  closeSse: () => void
}

/** The three event-bus subscriptions AppLayout owns for its whole lifetime. */
export function useAppLayoutSse(): UseAppLayoutSseReturn {
  // Subscribe to /api/kanban/events so live kanban mutations (column create / update / delete /reorder, task move / assign / unassign) refresh the visible board in …
  const kanbanSseStore = useKanbanSseStore()
  // ─── Design SSE — mirror the kanban pattern ─────────────────────────────
  const designSseStore = useDesignSseStore()
  // Document mutations, from the AGENT TOOLS only (agentic_loop/document_events.zig).
  const documentsSseStore = useDocumentsSseStore()

  // Merged SSE init (replaces the old kanban + design activeWorkspaceId watchers): ONE connection pair for the app lifetime, filter updates on workspace switches.
  let didInitSse = false
  const initSseStores = async (newId: string) => {
    if (!newId) return
    if (!didInitSse) {
      didInitSse = true
      await kanbanSseStore.initKanbanSse(newId)
      await designSseStore.initDesignSse(newId)
      await documentsSseStore.initDocumentsSse(newId)
    } else {
      await kanbanSseStore.setActiveWorkspaceId(newId)
      await designSseStore.setActiveWorkspaceId(newId)
      await documentsSseStore.setActiveWorkspaceId(newId)
    }
  }

  const closeSse = () => {
    kanbanSseStore.closeKanbanSse()
    designSseStore.closeDesignSse()
    documentsSseStore.closeDocumentsSse()
  }

  return { initSseStores, closeSse }
}
