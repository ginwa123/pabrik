import { nextTick, onBeforeUnmount, onMounted, onUpdated, ref } from 'vue'
import type { FilterMode } from './filePickerRows'

export type FilePickerTab = 'recent' | 'browse'

export interface FilePickerLifecycleDeps<T> {
  modelValue: () => boolean
  selectedPathProp: () => string
  initialPath: () => string
  currentPath: { value: string }
  treeEntriesCache: { value: Record<string, T[]> }
  treeExpanded: { value: Record<string, boolean> }
  contentEntries: { value: T[] }
  selectedPath: { value: string }
  searchQuery: { value: string }
  highlightedIndex: { value: number }
  filterMode: { value: FilterMode }
  showHiddenOverride: { value: boolean | null }
  isPathEditing: { value: boolean }
  pathDraft: { value: string }
  loadError: { value: string | null }
  activeTab: { value: FilePickerTab }
  expandAncestors: (path: string) => Promise<void>
  focusSearch: () => void
}

export function useFilePickerLifecycle<T>(deps: FilePickerLifecycleDeps<T>) {
  // ─── Lifecycle ─────────────────────────────────────────────────────────────
  async function openDialog() {
    const startPath = deps.initialPath()
    deps.currentPath.value = startPath
    deps.treeEntriesCache.value = {}
    deps.treeExpanded.value = {}
    deps.contentEntries.value = []
    deps.selectedPath.value = deps.selectedPathProp()
    deps.searchQuery.value = ''
    deps.highlightedIndex.value = -1
    deps.filterMode.value = 'all'
    deps.showHiddenOverride.value = null
    deps.isPathEditing.value = false
    deps.pathDraft.value = ''
    deps.loadError.value = null
    // Reset to the Recent tab on every open. The user always re-enters
    // through Recent — the Browse tab is one click away when they need it.
    deps.activeTab.value = 'recent'

    await deps.expandAncestors(startPath)

    // Windows first-open fallback: the POSIX default '/' doesn't exist on Windows, so the chain above
    // loads nothing and sets loadError. Retry once at the system root ('') which the callers resolve
    // via getSystemFolder (backend home / USERPROFILE).
    if (startPath === '/' && deps.contentEntries.value.length === 0 && deps.loadError.value) {
      deps.loadError.value = null
      await deps.expandAncestors('')
    }

    await nextTick()
    deps.focusSearch()
  }

  function closeDialog() {
    document.body.style.overflow = ''
    if (previouslyFocused && document.body.contains(previouslyFocused)) {
      previouslyFocused.focus()
    }
  }

  let previouslyFocused: HTMLElement | null = null

  // Open guard: run openDialog on mount when the parent created this dialog with modelValue already
  // true (the common v-if + v-model="show" pattern) plus closed->open updates.
  const wasOpen = ref(deps.modelValue())
  const syncModelValue = (show: boolean) => {
    if (show) {
      previouslyFocused = document.activeElement as HTMLElement
      document.body.style.overflow = 'hidden'
      void openDialog()
    } else {
      closeDialog()
    }
  }
  onMounted(() => {
    wasOpen.value = deps.modelValue()
    syncModelValue(deps.modelValue())
  })
  onUpdated(() => {
    if (deps.modelValue() !== wasOpen.value) {
      wasOpen.value = deps.modelValue()
      syncModelValue(deps.modelValue())
    }
  })


  onBeforeUnmount(() => {
    document.body.style.overflow = ''
  })

  return { openDialog }
}
