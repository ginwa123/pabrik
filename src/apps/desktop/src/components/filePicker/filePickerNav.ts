import { type Ref } from 'vue'
import { isRootPath, isWindowsAbs, parentPath } from './pathUtils'

export interface FilePickerNavDeps<T> {
  loadPath: (path: string) => Promise<T[]>
  currentPath: Ref<string>
  selectedPath: Ref<string>
  highlightedIndex: Ref<number>
  searchQuery: Ref<string>
  contentEntries: Ref<T[]>
  treeExpanded: Ref<Record<string, boolean>>
  treeEntriesCache: Ref<Record<string, T[]>>
}

export function useFilePickerNav<T>(deps: FilePickerNavDeps<T>) {
  async function expandAncestors(targetPath: string) {
    // Build ancestor chain root → … → target.
    const chain: string[] = []
    if (!targetPath) {
      // System root (''): a single backend call with '' so the caller's
      // loadItems can route to getSystemFolder (backend home / USERPROFILE).
      chain.push('')
    } else if (isWindowsAbs(targetPath)) {
      // Windows: chain from the drive/UNC root down.
      let p: string = targetPath
      while (p && !isRootPath(p)) {
        chain.unshift(p)
        const parent = parentPath(p)
        if (parent === p) break // safety: never loop forever
        p = parent
      }
      if (p) chain.unshift(p)
    } else {
      let p: string = targetPath
      while (p && p !== '/') {
        chain.unshift(p)
        p = parentPath(p)
      }
      chain.unshift('/')
    }

    for (const path of chain) {
      const items = await deps.loadPath(path)
      if (path === targetPath) {
        deps.contentEntries.value = items
      } else {
        // Mark all ancestor folders (except target) as expanded so the tree shows them
        deps.treeExpanded.value = { ...deps.treeExpanded.value, [path]: true }
      }
    }
  }

  async function navigateTo(path: string) {
    // NOTE: '' is meaningful (system root → getSystemFolder), so unlike the
    // old `path || '/'` fallback we pass the value through untouched.
    const target = path
    if (target === deps.currentPath.value) return
    deps.currentPath.value = target
    deps.selectedPath.value = ''
    deps.highlightedIndex.value = -1
    deps.searchQuery.value = ''
    await expandAncestors(target)
  }

  function refreshCurrent() {
    deps.loadPath(deps.currentPath.value).then((items) => {
      deps.contentEntries.value = items
    })
  }

  async function toggleTreeNode(path: string) {
    if (deps.treeExpanded.value[path]) {
      deps.treeExpanded.value = { ...deps.treeExpanded.value, [path]: false }
      return
    }
    deps.treeExpanded.value = { ...deps.treeExpanded.value, [path]: true }
    if (!deps.treeEntriesCache.value[path]) {
      await deps.loadPath(path)
    }
  }

    return { expandAncestors, navigateTo, refreshCurrent, toggleTreeNode }
}
