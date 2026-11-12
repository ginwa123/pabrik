import { computed, nextTick, ref, type ComputedRef } from 'vue'
import { Effect } from 'effect'
import { exportDocument, exportDocuments, getDocument, type Document } from '../api'
import { buildAppUrl } from '../helpers/appUrl'
import { downloadBlob } from '../helpers/download'
import type { DocumentRow } from '../helpers/documentRow'
import { SyncRemoteError } from '../sync/SyncError'
import { runSyncResult } from '../sync/runtime'
import { useDocumentsStore } from '../stores/documents'
import { useNotificationStore } from '../stores/notifications'
import { useContextMenu } from './useContextMenu'

export function useDocumentSelectionActions(opts: {
  documents: ComputedRef<Document[]>
  rows: ComputedRef<DocumentRow[]>
  workspaceId: () => string | null
  openDocument: (id: string) => void
}) {
  const documentsStore = useDocumentsStore()

  const selectedIds = ref<Set<string>>(new Set())
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
  const duplicating = ref(false)
  const exportNotice = ref<string | null>(null)
  const actionNotice = ref<string | null>(null)

  const busy = computed(() => exporting.value || duplicating.value)

  const { menuPos, openAtPoint, close: closeMenu } = useContextMenu({ width: 240, height: 380 })

  const onDocumentContextMenu = (event: MouseEvent, id: string) => {
    event.preventDefault()
    if (!isSelected(id)) {
      setSelection([id])
      selectionAnchor.value = id
    }
    openAtPoint(event.clientX, event.clientY, event.currentTarget as HTMLElement | null)
  }

  const selectedCount = computed(() => selectedIds.value.size)

  const singleSelectedId = computed<string | null>(() => {
    if (selectedIds.value.size !== 1) return null
    return [...selectedIds.value][0] ?? null
  })

  const contextMenuTitle = computed(() => {
    const id = singleSelectedId.value
    if (id) return opts.documents.value.find((d) => d.id === id)?.title ?? 'Document'
    return `${selectedCount.value} documents selected`
  })

  const openSelected = () => {
    const id = singleSelectedId.value
    closeMenu()
    if (id) opts.openDocument(id)
  }

  const renamingDocId = ref<string | null>(null)
  const renameDocValue = ref('')
  let renameDocInput: HTMLInputElement | null = null
  const setRenameDocInput = (el: unknown) => {
    renameDocInput = (el as HTMLInputElement | null) ?? null
  }

  const startRenameDocument = (id: string) => {
    const doc = opts.documents.value.find((d) => d.id === id)
    if (!doc) return
    renamingDocId.value = id
    renameDocValue.value = doc.title
    void nextTick(() => {
      renameDocInput?.focus()
      renameDocInput?.select()
    })
  }

  const commitRenameDocument = (doc: Document) => {
    const wsId = opts.workspaceId()
    const title = renameDocValue.value.trim()
    renamingDocId.value = null
    if (!wsId || title.length === 0 || title === doc.title) return
    void documentsStore.updateDocument(wsId, doc.id, { title })
  }

  const renameSelected = () => {
    const id = singleSelectedId.value
    closeMenu()
    if (id) startRenameDocument(id)
  }

  const copyLinkSelected = async () => {
    const id = singleSelectedId.value
    const wsId = opts.workspaceId()
    closeMenu()
    if (!id || !wsId) return
    const url = `${window.location.origin}${buildAppUrl({ workspaceId: wsId, documentId: id }).path}`
    const copied = await navigator.clipboard.writeText(url).then(
      () => true,
      () => false,
    )
    if (copied) actionNotice.value = 'Link copied'
    else useNotificationStore().notifyError('Copy failed', 'The clipboard is not available')
  }

  const duplicateSelected = async () => {
    const wsId = opts.workspaceId()
    const ids = [...selectedIds.value]
    closeMenu()
    if (!wsId || ids.length === 0 || duplicating.value) return
    duplicating.value = true
    actionNotice.value = null
    let made = 0
    for (const id of ids) {
      const source = opts.documents.value.find((d) => d.id === id)
      if (!source) continue
      const result = await runSyncResult(
        Effect.tryPromise({
          try: () => getDocument(wsId, id),
          catch: (cause) =>
            new SyncRemoteError({
              op: 'documents.duplicate',
              reason: cause instanceof Error ? cause.message : String(cause),
            }),
        }),
        'documents.duplicate',
      )
      if (!result.ok) {
        useNotificationStore().notifyError('Duplicate failed', result.reason)
        break
      }
      const copy = await documentsStore.createDocument(
        wsId,
        `${source.title} copy`,
        result.value.document.content ?? '',
        source.folder_id ?? null,
        source.format,
      )
      if (copy) made += 1
    }
    duplicating.value = false
    if (made > 0) {
      actionNotice.value = made === 1 ? 'Duplicated 1 document' : `Duplicated ${made} documents`
    }
  }

  const deleteTargets = ref<string[]>([])

  const deleteMessage = computed(() => {
    const ids = deleteTargets.value
    if (ids.length === 1) {
      const title = opts.documents.value.find((d) => d.id === ids[0])?.title ?? 'this document'
      return `Delete "${title}"? This cannot be undone.`
    }
    return `Delete ${ids.length} documents? This cannot be undone.`
  })

  const requestDelete = () => {
    const ids = [...selectedIds.value]
    closeMenu()
    if (ids.length > 0) deleteTargets.value = ids
  }

  const cancelDelete = () => {
    deleteTargets.value = []
  }

  const confirmDelete = async () => {
    const wsId = opts.workspaceId()
    const ids = deleteTargets.value
    deleteTargets.value = []
    if (!wsId || ids.length === 0) return
    actionNotice.value = null
    let removed = 0
    for (const id of ids) {
      if (await documentsStore.deleteDocument(wsId, id)) removed += 1
    }
    clearSelection()
    if (removed < ids.length) {
      useNotificationStore().notifyError(
        'Delete failed',
        documentsStore.error ?? 'Some documents could not be deleted',
      )
      return
    }
    actionNotice.value = removed === 1 ? 'Deleted 1 document' : `Deleted ${removed} documents`
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

  return {
    selectedIds,
    selectedCount,
    singleSelectedId,
    contextMenuTitle,
    isSelected,
    clearSelection,
    onDocumentClick,
    onDocumentContextMenu,
    exporting,
    duplicating,
    busy,
    exportNotice,
    actionNotice,
    menuPos,
    openSelected,
    renamingDocId,
    renameDocValue,
    setRenameDocInput,
    commitRenameDocument,
    renameSelected,
    duplicateSelected,
    copyLinkSelected,
    deleteTargets,
    deleteMessage,
    requestDelete,
    cancelDelete,
    confirmDelete,
    exportSelected,
    exportAll,
    selectAllDocuments,
    clearSelectionFromMenu,
  }
}
