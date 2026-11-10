/** Selection and export for the sidebar's Documents section. A plain click opens a row;
 * Ctrl/Cmd-click toggles one into the selection and Shift-click extends from the last row
 * touched — the two gestures every file list has. */
import { computed, ref, type ComputedRef } from 'vue'
import { Effect } from 'effect'
import { exportDocument, exportDocuments, type Document } from '../api'
import { downloadBlob } from '../helpers/download'
import type { DocumentRow } from '../helpers/documentRow'
import { SyncRemoteError } from '../sync/SyncError'
import { runSyncResult } from '../sync/runtime'
import { useNotificationStore } from '../stores/notifications'
import { useContextMenu } from './useContextMenu'

export function useDocumentSelectionExport(opts: {
  documents: ComputedRef<Document[]>
  rows: ComputedRef<DocumentRow[]>
  workspaceId: () => string | null
  openDocument: (id: string) => void
}) {
  const selectedIds = ref<Set<string>>(new Set())
  /** The row a Shift-click extends FROM. Null until the first click. */
  const selectionAnchor = ref<string | null>(null)

  const isSelected = (id: string): boolean => selectedIds.value.has(id)

  const setSelection = (ids: Iterable<string>) => {
    selectedIds.value = new Set(ids)
  }

  const toggleSelected = (id: string) => {
    const next = new Set(selectedIds.value)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    selectedIds.value = next
    selectionAnchor.value = id
  }

  /** Every document id between the anchor and `id`, in the order the tree renders them. */
  const selectRangeTo = (id: string) => {
    const anchor = selectionAnchor.value
    const order = opts.rows.value
      .filter((row): row is Extract<DocumentRow, { kind: 'document' }> => row.kind === 'document')
      .map((row) => row.document.id)
    const from = anchor ? order.indexOf(anchor) : -1
    const to = order.indexOf(id)
    if (from === -1 || to === -1) {
      setSelection([id])
      return
    }
    const [start, end] = from <= to ? [from, to] : [to, from]
    setSelection(order.slice(start, end + 1))
  }

  const clearSelection = () => {
    selectedIds.value = new Set()
    selectionAnchor.value = null
  }

  /** A click on a document row: plain opens it, Ctrl/Cmd toggles, Shift extends. */
  const onDocumentClick = (event: MouseEvent, id: string) => {
    if (event.shiftKey) {
      event.preventDefault()
      selectRangeTo(id)
      return
    }
    if (event.ctrlKey || event.metaKey) {
      event.preventDefault()
      toggleSelected(id)
      return
    }
    clearSelection()
    opts.openDocument(id)
  }

  const exporting = ref(false)
  /** What the last export did, rendered under the section header. Null = nothing to say. */
  const exportNotice = ref<string | null>(null)

  const { menuPos, openAtPoint, close: closeMenu } = useContextMenu({ width: 240, height: 200 })

  /** Right-clicking a row that is NOT selected makes it the selection: the menu's count must
   * describe what the user is pointing at, not a stale selection elsewhere. */
  const onDocumentContextMenu = (event: MouseEvent, id: string) => {
    event.preventDefault()
    if (!isSelected(id)) {
      setSelection([id])
      selectionAnchor.value = id
    }
    openAtPoint(event.clientX, event.clientY, event.currentTarget as HTMLElement | null)
  }

  const exportIds = async (ids: string[]) => {
    const wsId = opts.workspaceId()
    if (!wsId || ids.length === 0 || exporting.value) return
    exporting.value = true
    exportNotice.value = null
    const result = await runSyncResult(
      Effect.tryPromise({
        try: () => (ids.length === 1 ? exportDocument(wsId, ids[0]!) : exportDocuments(wsId, ids)),
        catch: (cause) =>
          new SyncRemoteError({
            op: 'documents.export',
            reason: cause instanceof Error ? cause.message : String(cause),
          }),
      }),
      'documents.export',
    )
    exporting.value = false
    closeMenu()
    if (!result.ok) {
      useNotificationStore().notifyError('Export failed', result.reason)
      return
    }
    downloadBlob(result.value.blob, result.value.filename)
    exportNotice.value =
      ids.length === 1 ? `Exported ${result.value.filename}` : `Exported ${ids.length} documents`
  }

  const exportSelected = () => {
    void exportIds([...selectedIds.value])
  }

  const exportAll = () => {
    void exportIds(opts.documents.value.map((d) => d.id))
  }

  const selectAllDocuments = () => {
    setSelection(opts.documents.value.map((d) => d.id))
    closeMenu()
  }

  const clearSelectionFromMenu = () => {
    clearSelection()
    closeMenu()
  }

  const selectedCount = computed(() => selectedIds.value.size)

  return {
    selectedIds,
    selectedCount,
    isSelected,
    clearSelection,
    onDocumentClick,
    onDocumentContextMenu,
    exporting,
    exportNotice,
    menuPos,
    exportSelected,
    exportAll,
    selectAllDocuments,
    clearSelectionFromMenu,
  }
}
