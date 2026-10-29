import type { ContentItem } from './filePickerRows'
import { parentPath } from './pathUtils'

export interface FilePickerKeyboardDeps<T> {
  dialogRef: { readonly value: HTMLElement | null }
  searchInputEl: () => HTMLInputElement | null
  isPathEditing: { value: boolean }
  searchQuery: { value: string }
  currentPath: { readonly value: string }
  highlightedIndex: { value: number }
  filteredContent: { readonly value: ContentItem<T>[] }
  effectiveSelection: { readonly value: string }
  canSelect: { readonly value: boolean }
  navigateTo: (path: string) => void
  handleItemClick: (item: T) => void
  handleSelect: () => void
  handleCancel: () => void
  commitPathEdit: () => void
  cancelPathEdit: () => void
  scrollHighlightedIntoView: () => void
}

export function useFilePickerKeyboard<T>(deps: FilePickerKeyboardDeps<T>) {
  function handleKeydown(event: KeyboardEvent) {
    // Focus trap on Tab
    if (event.key === 'Tab') {
      const focusable = deps.dialogRef.value?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])',
      )
      if (!focusable || focusable.length === 0) return
      const first = focusable[0]!
      const last = focusable[focusable.length - 1]!
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
      return
    }

    if (event.key === 'Escape') {
      // Address-input takes precedence over search: if the user is editing
      // the path, Esc cancels the edit (does NOT close the dialog).
      if (deps.isPathEditing.value) {
        deps.cancelPathEdit()
        event.stopPropagation()
        event.preventDefault()
        return
      }
      if (deps.searchQuery.value) {
        deps.searchQuery.value = ''
        event.stopPropagation()
        return
      }
      deps.handleCancel()
      event.stopPropagation()
      return
    }

    // Address input (path editor): Enter commits, other keys are eaten by
    // the input itself but we still need to stop the dialog-wide keydown
    // handler from interpreting them as arrow-up / arrow-down / backspace.
    if (deps.isPathEditing.value) {
      if (event.key === 'Enter') {
        deps.commitPathEdit()
        event.preventDefault()
        event.stopPropagation()
      }
      // For every other key we drop the bubble so the global Up / Backspace
      // / ArrowDown handlers below don't fire while the user is typing.
      event.stopPropagation()
      return
    }

    // Don't handle navigation keys while typing in search
    if (document.activeElement === deps.searchInputEl()) {
      if (event.key === 'Enter') {
        // Submit the first match as the selection
        const first = deps.filteredContent.value[0]
        if (first) {
          deps.handleItemClick(first.item)
          if (deps.effectiveSelection.value) deps.handleSelect()
        }
        event.preventDefault()
      }
      return
    }

    if (event.key === '/') {
      deps.searchInputEl()?.focus()
      event.preventDefault()
      return
    }

    if (event.key === 'Enter') {
      if (deps.highlightedIndex.value >= 0 && deps.filteredContent.value[deps.highlightedIndex.value]) {
        const entry = deps.filteredContent.value[deps.highlightedIndex.value]!
        deps.handleItemClick(entry.item)
        if (deps.effectiveSelection.value) deps.handleSelect()
      } else if (deps.canSelect.value) {
        deps.handleSelect()
      }
      event.preventDefault()
      return
    }

    if (event.key === 'ArrowDown') {
      const len = deps.filteredContent.value.length
      if (len === 0) return
      deps.highlightedIndex.value = Math.min(
        deps.highlightedIndex.value < 0 ? 0 : deps.highlightedIndex.value + 1,
        len - 1,
      )
      deps.scrollHighlightedIntoView()
      event.preventDefault()
      return
    }

    if (event.key === 'ArrowUp') {
      deps.highlightedIndex.value = Math.max(
        deps.highlightedIndex.value < 0 ? 0 : deps.highlightedIndex.value - 1,
        0,
      )
      deps.scrollHighlightedIntoView()
      event.preventDefault()
      return
    }

    if (event.key === 'Backspace') {
      deps.navigateTo(parentPath(deps.currentPath.value))
      event.preventDefault()
      return
    }
  }

    return { handleKeydown }
}
