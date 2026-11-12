/** The Documents section's row glyphs: which glyph a row draws, the picker that
 * changes it, and the folder row's context menu. Extracted from
 * `DocumentsList.vue` so the component stays a tree renderer. */
import { ref } from 'vue'
import { useContextMenu } from './useContextMenu'
import { documentIconFor, folderIconFor } from '../stores/sidebarIcons'
import type { UiIconName } from '../components/ui/icons'
import type { Document, DocumentFolder } from '../api'

interface RowIconOptions {
  /** The workspace the rows belong to, or null when none is selected. */
  workspaceId: () => string | null
  /** A folder is collapsed when its id is in the collapsed set. */
  isCollapsed: (folderId: string) => boolean
  setDocumentIcon: (workspaceId: string, id: string, icon: string | null) => Promise<boolean>
  setFolderIcon: (workspaceId: string, id: string, icon: string | null) => Promise<boolean>
  startRename: (folder: DocumentFolder) => void
  removeFolder: (folder: DocumentFolder) => void
}

export function useDocumentRowIcons(opts: RowIconOptions) {
  const folderIcon = (folder: DocumentFolder): UiIconName =>
    folderIconFor(folder, !opts.isCollapsed(folder.id))
  const documentIcon = (doc: Document): UiIconName => documentIconFor(doc)

  const iconPicker = ref<{
    x: number
    y: number
    label: string
    current: UiIconName
    kind: 'document' | 'folder'
    id: string
  } | null>(null)

  const openIconPickerAt = (
    x: number,
    y: number,
    kind: 'document' | 'folder',
    id: string,
    label: string,
    current: UiIconName,
  ) => {
    iconPicker.value = { x, y, kind, id, label, current }
  }

  const closeIconPicker = () => {
    iconPicker.value = null
  }

  const applyIcon = (name: string | null) => {
    const target = iconPicker.value
    iconPicker.value = null
    const workspaceId = opts.workspaceId()
    if (!target || !workspaceId) return
    if (target.kind === 'document') void opts.setDocumentIcon(workspaceId, target.id, name)
    else void opts.setFolderIcon(workspaceId, target.id, name)
  }

  // A folder row has no selection model, so it gets its own menu instance.
  const {
    menuPos: folderMenuPos,
    openAt: openFolderMenuAt,
    close: closeFolderMenu,
  } = useContextMenu({ width: 240, height: 200 })
  const folderMenuTarget = ref<DocumentFolder | null>(null)

  const onFolderContextMenu = (event: MouseEvent, folder: DocumentFolder) => {
    folderMenuTarget.value = folder
    openFolderMenuAt(event)
  }

  const takeFolderMenuTarget = (): DocumentFolder | null => {
    const folder = folderMenuTarget.value
    closeFolderMenu()
    folderMenuTarget.value = null
    return folder
  }

  const folderMenuRename = () => {
    const folder = takeFolderMenuTarget()
    if (folder) opts.startRename(folder)
  }

  const folderMenuChangeIcon = () => {
    // Read the anchor BEFORE closing: `closeFolderMenu` nulls `menuPos`.
    const pos = folderMenuPos.value
    const folder = takeFolderMenuTarget()
    if (!folder || !pos) return
    openIconPickerAt(pos.x + 240, pos.y, 'folder', folder.id, folder.name, folderIcon(folder))
  }

  const folderMenuDelete = () => {
    const folder = takeFolderMenuTarget()
    if (folder) opts.removeFolder(folder)
  }

  return {
    folderIcon,
    documentIcon,
    iconPicker,
    openIconPickerAt,
    closeIconPicker,
    applyIcon,
    folderMenuPos,
    folderMenuTarget,
    onFolderContextMenu,
    folderMenuRename,
    folderMenuChangeIcon,
    folderMenuDelete,
  }
}
