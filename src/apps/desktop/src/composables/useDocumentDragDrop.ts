/** Drag-and-drop for the sidebar's Documents tree: reorder within a level, move into a folder,
 * drop on the empty space below the tree to send a row back to the root. */
import { ref } from 'vue'
import { isAtOrBelow, useDocumentsStore } from '../stores/documents'
import type { Document } from '../api'
import type { DocumentRow } from '../helpers/documentRow'

export function useDocumentDragDrop(opts: {
  workspaceId: () => string | null
  expand: (id: string) => void
}) {
  const documentsStore = useDocumentsStore()

  /** When the last drop landed. A drop arrives as a click on some browsers, and toggling the
   * folder shut right after the document fell into it reads as "the move did nothing". */
  const lastDropAt = ref(0)

  const draggingDoc = ref<string | null>(null)
  const draggingFolder = ref<string | null>(null)
  /** Folder row currently outlined as "drop inside me". */
  const overFolder = ref<string | null>(null)
  /** Document row the drop would land next to, and on which side. */
  const overDoc = ref<{ id: string; after: boolean } | null>(null)

  const clearDragState = () => {
    draggingDoc.value = null
    draggingFolder.value = null
    overFolder.value = null
    overDoc.value = null
  }

  const startDragDocument = (event: DragEvent, id: string) => {
    draggingDoc.value = id
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('application/x-document-id', id)
    }
  }

  const startDragFolder = (event: DragEvent, id: string) => {
    draggingFolder.value = id
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('application/x-document-folder-id', id)
    }
  }

  /** Dragging over a folder row means "into"; over a document row it means "before/after". */
  const handleDragOver = (event: DragEvent, row: DocumentRow) => {
    if (!draggingDoc.value && !draggingFolder.value) return
    event.preventDefault()
    if (row.kind === 'folder') {
      // A folder cannot be dropped into itself or its own descendant; the store
      // refuses it too, but a dead drop target should not look alive.
      const source = draggingFolder.value
      if (
        source &&
        (source === row.folder.id || isAtOrBelow(documentsStore.folders, source, row.folder.id))
      ) {
        return
      }
      overFolder.value = row.folder.id
      overDoc.value = null
      return
    }
    if (!draggingDoc.value) return
    overFolder.value = null
    const target = (event.currentTarget as HTMLElement).getBoundingClientRect()
    overDoc.value = { id: row.document.id, after: event.clientY > target.top + target.height / 2 }
  }

  const levelDocumentIds = (folderId: string | null): string[] =>
    documentsStore
      .level(folderId)
      .filter((entry): entry is { kind: 'document'; document: Document } => entry.kind === 'document')
      .map((entry) => entry.document.id)

  const reorderWithin = (
    folderId: string | null,
    sourceId: string,
    targetId: string,
    after: boolean,
  ) => {
    const ids = levelDocumentIds(folderId)
    const from = ids.indexOf(sourceId)
    const to = ids.indexOf(targetId)
    if (from === -1 || to === -1) return
    const [moved] = ids.splice(from, 1)
    if (!moved) return
    const targetIdx = to > from ? to - 1 : to
    ids.splice(targetIdx + (after ? 1 : 0), 0, moved)
    const wsId = opts.workspaceId()
    if (!wsId) return
    void documentsStore.reorderDocuments(wsId, ids, folderId)
  }

  /** The element under the pointer is the truth: a drag can skip a `dragover` frame, and a drop
   * that trusts the last hover frame is a silent no-op on any part of a folder row that is not its
   * exact middle. */
  const rowUnder = (event: DragEvent) => {
    const el = event.target as HTMLElement | null
    const rowEl = el?.closest('[data-folder-id], [data-doc-id]') as HTMLElement | null
    return {
      rowEl,
      folderId: rowEl?.getAttribute('data-folder-id') ?? null,
      documentId: rowEl?.getAttribute('data-doc-id') ?? null,
    }
  }

  const handleDrop = (event: DragEvent, row: DocumentRow) => {
    event.preventDefault()
    const wsId = opts.workspaceId()
    const doc = draggingDoc.value
    const folder = draggingFolder.value
    const { rowEl, folderId, documentId } = rowUnder(event)
    const hovered = overDoc.value
    const rect = rowEl?.getBoundingClientRect()
    const after = rect ? event.clientY > rect.top + rect.height / 2 : (hovered?.after ?? false)
    lastDropAt.value = Date.now()
    clearDragState()
    if (!wsId) return

    // A folder row means "into", whatever part of the row you let go on.
    const targetFolder = folderId ?? (row.kind === 'folder' ? row.folder.id : null)
    if (targetFolder) {
      if (doc) {
        opts.expand(targetFolder)
        void documentsStore.moveDocument(wsId, doc, targetFolder)
      } else if (folder && folder !== targetFolder) {
        opts.expand(targetFolder)
        void documentsStore.moveFolder(wsId, folder, targetFolder)
      }
      return
    }

    const targetDocument = documentId ?? (row.kind === 'document' ? row.document.id : null)
    if (targetDocument && doc && doc !== targetDocument) {
      const target = documentsStore.documents.find((d) => d.id === targetDocument)
      reorderWithin(target?.folder_id ?? null, doc, targetDocument, after)
    }
  }

  /** Dropping on the empty space below the tree moves the row to the root. */
  const handleRootDrop = (event: DragEvent) => {
    event.preventDefault()
    const wsId = opts.workspaceId()
    const doc = draggingDoc.value
    const folder = draggingFolder.value
    clearDragState()
    if (!wsId) return
    if (doc) void documentsStore.moveDocument(wsId, doc, null)
    else if (folder) void documentsStore.moveFolder(wsId, folder, null)
  }

  return {
    lastDropAt,
    draggingDoc,
    draggingFolder,
    overFolder,
    overDoc,
    clearDragState,
    startDragDocument,
    startDragFolder,
    handleDragOver,
    handleDrop,
    handleRootDrop,
  }
}
