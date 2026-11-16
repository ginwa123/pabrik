import { computed, type Ref } from 'vue'
import { isAbsPath } from './pathUtils'

export type FilePickerMode = 'folder' | 'file' | 'both'

export interface FilePickerSelectionDeps<T> {
  mode: () => FilePickerMode
  currentPath: { readonly value: string }
  selectedPath: Ref<string>
  pathFor: (item: T) => string
  isExpandable: (item: T) => boolean
  navigateTo: (path: string) => void
  addRecent: (path: string) => void
  closeOnSelect: () => boolean
  emitSelect: (path: string) => void
  emitClose: () => void
  emitCancel: () => void
}

export function useFilePickerSelection<T>(deps: FilePickerSelectionDeps<T>) {
  // ─── Selection ─────────────────────────────────────────────────────────────
  function handleItemClick(item: T) {
    const path = deps.pathFor(item)
    const expandable = deps.isExpandable(item)

    if (expandable) {
      if (deps.mode() === 'folder' || deps.mode() === 'both') {
        // Folders can be selected in folder/both mode
        deps.selectedPath.value = path
      } else {
        // mode === 'file': folder click navigates into it
        deps.navigateTo(path)
      }
    } else {
      if (deps.mode() === 'file' || deps.mode() === 'both') {
        // Files can be selected in file/both mode
        deps.selectedPath.value = path
      }
      // mode === 'folder': file click is a no-op
    }
  }

  function handleItemDoubleClick(item: T) {
    // Double-click on a folder navigates INTO it — it must never select + close the dialog.
    if (deps.isExpandable(item)) {
      void deps.navigateTo(deps.pathFor(item))
      return
    }
    // Double-click on a file confirms it (file/both mode only — handleItemClick is a no-op for files in folder mode, so selectedPath stays empty and we don't close).
    handleItemClick(item)
    if (deps.selectedPath.value) {
      handleSelect()
    }
  }

  function handleSelect() {
    const path = effectiveSelection.value
    if (!path) return
    // Defense-in-depth (Windows cwd fix, 2026-09-05): never emit a relative path.
    if (!isAbsPath(path)) return
    // Record every selection in the recent store (Recent rows AND Browse rows both go through handleSelect).
    deps.addRecent(path)
    deps.emitSelect(path)
    // Note: Vue 3.5 auto-defaults `boolean?` to `false`, so the only way to opt INTO close-on-select is to explicitly pass `closeOnSelect={true}`.
    if (deps.closeOnSelect()) {
      deps.emitClose()
    }
  }

  function handleCancel() {
    deps.emitCancel()
    deps.emitClose()
  }

  const canSelect = computed(() => !!effectiveSelection.value)

  // Effective selection for the Select button.
  const effectiveSelection = computed<string>(() => {
    if (deps.mode() !== 'folder') return deps.selectedPath.value
    if (deps.selectedPath.value) return deps.selectedPath.value
    if (deps.currentPath.value && deps.currentPath.value !== '/' && deps.currentPath.value !== '') return deps.currentPath.value
    return ''
  })

  // Whether the footer should show the "← current folder" hint.
  const showCurrentFolderHint = computed<boolean>(
    () =>
      deps.mode() === 'folder' &&
      !deps.selectedPath.value &&
      !!effectiveSelection.value,
  )

    return {
      handleItemClick,
      handleItemDoubleClick,
      handleSelect,
      handleCancel,
      effectiveSelection,
      canSelect,
      showCurrentFolderHint,
    }
}
