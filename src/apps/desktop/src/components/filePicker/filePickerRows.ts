import { computed } from 'vue'
import type { UiIconName } from '../ui/icons'
import { basenameOf, isRootPath } from './pathUtils'

export type FilterMode = 'all' | 'folders' | 'files'

export interface ContentItem<T> {
  item: T
  path: string
  label: string
  subtitle: string
  icon: UiIconName
  expandable: boolean
  hidden: boolean
}

export interface TreeRow<T> {
  item: T
  path: string
  depth: number
  label: string
  icon: UiIconName
}

export interface FilePickerRowsDeps<T> {
  contentEntries: { readonly value: unknown[] }
  treeEntriesCache: { readonly value: Readonly<Record<string, unknown[]>> }
  treeExpanded: { readonly value: Readonly<Record<string, boolean>> }
  filterMode: { readonly value: FilterMode }
  showHidden: { readonly value: boolean }
  searchQuery: { readonly value: string }
  pathFor: (item: T) => string
  keyFor: (item: T) => string
  isExpandable: (item: T) => boolean
  labelFor?: (item: T) => string
  subtitleFor?: (item: T) => string
  iconFor?: (item: T) => UiIconName
}

export function useFilePickerRows<T>(deps: FilePickerRowsDeps<T>) {
  function defaultIconFor(item: T): UiIconName {
    return deps.isExpandable(item) ? 'folder' : 'file'
  }

  function getLabel(item: T): string {
    return deps.labelFor ? deps.labelFor(item) : deps.keyFor(item)
  }

  function getSubtitle(item: T): string {
    return deps.subtitleFor ? deps.subtitleFor(item) : ''
  }

  function getIcon(item: T): UiIconName {
    return deps.iconFor ? deps.iconFor(item) : defaultIconFor(item)
  }

  function isHiddenItem(path: string): boolean {
    // Hidden iff the basename (last path segment) starts with '.'
    const basename = basenameOf(path)
    return basename.startsWith('.')
  }

  // ─── Filtered view ─────────────────────────────────────────────────────────
  const filteredContent = computed<ContentItem<T>[]>(() => {
    const entries = deps.contentEntries.value ?? []
    const items: ContentItem<T>[] = entries.map((raw) => {
      // Cast through unknown because Vue's deep ref unwraps T into UnwrapRefSimple<T>
      // inside the ref's value array. The user's data-source functions still expect T.
      const item = raw as unknown as T
      return {
        item,
        path: deps.pathFor(item),
        label: getLabel(item),
        subtitle: getSubtitle(item),
        icon: getIcon(item),
        expandable: deps.isExpandable(item),
        hidden: isHiddenItem(getLabel(item)),
      }
    })

    let filtered = items

    // Filter by mode chip
    if (deps.filterMode.value === 'folders') {
      filtered = filtered.filter((i) => i.expandable)
    } else if (deps.filterMode.value === 'files') {
      filtered = filtered.filter((i) => !i.expandable)
    }

    // Hidden files
    if (!deps.showHidden.value) {
      filtered = filtered.filter((i) => !i.hidden)
    }

    // Search
    const q = deps.searchQuery.value.trim().toLowerCase()
    if (q) {
      filtered = filtered.filter((i) => i.label.toLowerCase().includes(q))
    }

    return filtered
  })

  // Flattened tree (recursive from root, with depth)
  const treeFlat = computed<TreeRow<T>[]>(() => {
    const result: TreeRow<T>[] = []
    const cache = deps.treeEntriesCache.value
    // Root key is '/' on POSIX, '' when the dialog opened at the system root (resolved via
    // getSystemFolder), or a drive/UNC root (`C:\`, `\\server\share`) on Windows. Prefer '' (a failed
    // '/' load leaves a stale empty '/' entry behind after the system-root fallback).
    const rootKey =
      Object.keys(cache).find((k) => k === '') ??
      Object.keys(cache).find((k) => k === '/' || isRootPath(k))
    const rootChildren = (rootKey !== undefined ? cache[rootKey] : undefined) || []

    const add = (entries: readonly unknown[], depth: number) => {
      for (const raw of entries) {
        const item = raw as unknown as T
        if (!deps.isExpandable(item)) continue
        const path = deps.pathFor(item)
        result.push({ item, path, depth, label: getLabel(item), icon: getIcon(item) })
        if (deps.treeExpanded.value[path] && deps.treeEntriesCache.value[path]) {
          add(deps.treeEntriesCache.value[path] as readonly unknown[], depth + 1)
        }
      }
    }

    add(rootChildren, 0)
    return result
  })

  return { filteredContent, treeFlat }
}
