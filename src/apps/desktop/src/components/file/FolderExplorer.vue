<script setup lang="ts">
import { ref, computed, onMounted, onUpdated, onUnmounted } from 'vue'
import { listFolder, getGitChanges, type FolderEntry } from '../../api'
import {
  buildGitStatusMap,
  countChangedUnder,
  statusForExplorerPath,
  summarizeGitStatuses,
  type GitBadge,
} from '../../helpers/gitStatusMap'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

const props = defineProps<{
  cwd?: string
  name?: string
}>()

const emit = defineEmits<{
  'file-click': [file: FolderEntry]
  // Emitted when the user clicks a directory entry. Used by the CreateWorktreeDialog to navigate
  // the picker into the clicked folder (parent of the new worktree).
  'folder-click': [folder: FolderEntry]
}>()

// Compute header info from props or fall back to path
const headerName = computed(
  () => props.name || (props.cwd ? props.cwd.split('/').pop() || props.cwd : null),
)

// Check if we have valid input
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')

// Nested folders state
const nestedEntriesCache = ref<Record<string, FolderEntry[]>>({})
const rootEntries = ref<FolderEntry[]>([])
const isLoading = ref(false)
const loadError = ref<string | null>(null)

// Git state (branch header, per-row badges, folder counts, footer)
const gitMap = ref<Map<string, GitBadge>>(new Map())
const gitBranch = ref('')
const isGitRepo = ref(false)
const hasGitChanges = ref(false)

// Name filter state
const filterText = ref('')

// Load root directory
const loadRoot = async () => {
  if (!props.cwd) {
    rootEntries.value = []
    return
  }

  isLoading.value = true
  loadError.value = null

  try {
    const data = await listFolder(props.cwd)
    rootEntries.value = data.entries || []
  } catch (err) {
    console.error('Failed to load folder:', err)
    loadError.value = 'Failed to load folder'
    rootEntries.value = []
  } finally {
    isLoading.value = false
  }
}

// Load git changes for badges. getGitChanges never throws — it resolves a
// non-repo fallback on transport error — so no try/catch is needed here.
const loadGit = async () => {
  if (!props.cwd) {
    gitMap.value = new Map()
    gitBranch.value = ''
    isGitRepo.value = false
    hasGitChanges.value = false
    return
  }
  const data = await getGitChanges(props.cwd)
  isGitRepo.value = data.is_git_repo
  gitBranch.value = data.branch || ''
  hasGitChanges.value = data.has_changes
  gitMap.value = data.is_git_repo ? buildGitStatusMap(data) : new Map()
}

// 30s git poll while a cwd is bound (RightSidebar precedent). Stopped on
// unmount and whenever the explorer goes unbound.
let gitPoll: ReturnType<typeof setInterval> | null = null
const stopGitPoll = () => {
  if (gitPoll) {
    clearInterval(gitPoll)
    gitPoll = null
  }
}
const startGitPoll = () => {
  stopGitPoll()
  if (!props.cwd) return
  gitPoll = setInterval(() => {
    if (props.cwd) void loadGit()
  }, 30000)
}

const refreshAll = () => {
  void loadRoot()
  void loadGit()
}

// Reload the root on cwd change (prev-value guard on update — same
// clear+load the watcher did; the mount call covers the initial load).
function syncExplorerCwd(newCwd: string | undefined) {
  nestedEntriesCache.value = {}
  rootEntries.value = []
  filterText.value = ''
  if (newCwd) {
    loadRoot()
    loadGit()
    startGitPoll()
  } else {
    stopGitPoll()
    loadGit()
  }
}

let prevExplorerCwd: string | undefined = props.cwd
onMounted(() => {
  prevExplorerCwd = props.cwd
  syncExplorerCwd(props.cwd)
})
onUpdated(() => {
  if (props.cwd === prevExplorerCwd) return
  prevExplorerCwd = props.cwd
  syncExplorerCwd(props.cwd)
})
onUnmounted(() => {
  stopGitPoll()
})

// Toggle folder expansion
const toggleFolder = async (entry: FolderEntry) => {
  if (!entry.is_directory) return

  const pathKey = entry.path

  if (nestedEntriesCache.value[pathKey]) {
    // Already fetched, just toggle visibility
    delete nestedEntriesCache.value[pathKey]
  } else {
    // Fetch nested contents
    try {
      const data = await listFolder(pathKey)
      nestedEntriesCache.value = {
        ...nestedEntriesCache.value,
        [pathKey]: data.entries || [],
      }
    } catch {
      // Ignore errors
    }
  }
}

// Check if folder is expanded
const isExpanded = (path: string) => !!nestedEntriesCache.value[path]

// Flatten tree for display, joining each row onto the git status map.
// Absolute explorer paths resolve against the cwd (the repo root the
// explorer was opened at); paths outside it simply get no badge.
interface FlatEntry {
  entry: FolderEntry
  depth: number
  path: string
  badge: GitBadge | null
  childCount: number
}

const flattenedEntries = computed(() => {
  const result: FlatEntry[] = []
  const root = props.cwd ?? ''

  const addEntries = (entries: FolderEntry[], depth: number) => {
    for (const entry of entries) {
      const entryPath = entry.path
      const badge = entry.is_directory
        ? null
        : statusForExplorerPath(gitMap.value, root, entryPath)
      const childCount = entry.is_directory
        ? countChangedUnder(gitMap.value, root, entryPath)
        : 0
      result.push({ entry, depth, path: entryPath, badge, childCount })

      if (entry.is_directory && nestedEntriesCache.value[entryPath]) {
        const nested = nestedEntriesCache.value[entryPath]
        addEntries(nested, depth + 1)
      }
    }
  }

  addEntries(rootEntries.value, 0)
  return result
})

// Name filter over the visible rows.
const filteredEntries = computed(() => {
  const query = filterText.value.trim().toLowerCase()
  if (!query) return flattenedEntries.value
  return flattenedEntries.value.filter(({ entry }) => entry.name.toLowerCase().includes(query))
})

// Row text color: git status wins, then the directory/file default.
const rowColor = (flat: FlatEntry): string => {
  if (flat.badge) {
    switch (flat.badge.kind) {
      case 'modified':
        return 'var(--color-orange)'
      case 'staged':
        return 'var(--color-green)'
      case 'deleted':
        return 'var(--color-red)'
      case 'renamed':
        return 'var(--color-blue)'
      case 'untracked':
        return 'var(--semantic-text-dim)'
    }
  }
  return flat.entry.is_directory ? 'var(--semantic-text)' : 'var(--semantic-text-muted)'
}

// File-type icon by extension; folders show open/closed state.
const fileIconFor = (entry: FolderEntry, path: string): UiIconName => {
  if (entry.is_directory) return isExpanded(path) ? 'folder-open' : 'folder'
  const ext = entry.name.split('.').pop()?.toLowerCase() || ''
  const iconMap: Record<string, UiIconName> = {
    js: 'code',
    jsx: 'code',
    ts: 'code',
    tsx: 'code',
    vue: 'code',
    py: 'code',
    zig: 'code',
    rs: 'code',
    go: 'code',
    sh: 'code',
    md: 'note',
    markdown: 'note',
    txt: 'note',
    json: 'clipboard',
    yaml: 'settings',
    yml: 'settings',
    css: 'palette',
    scss: 'palette',
    png: 'image',
    jpg: 'image',
    jpeg: 'image',
    gif: 'image',
    svg: 'image',
    webp: 'image',
  }
  return iconMap[ext] ?? 'file'
}

// Footer: change summary in git repos, cwd path otherwise (existing behavior).
const footerText = computed(() => {
  if (isGitRepo.value) {
    const summary = summarizeGitStatuses(gitMap.value)
    if (summary.total === 0) return `Working tree clean · ${gitBranch.value}`
    const parts: string[] = []
    if (summary.modified > 0) parts.push(`${summary.modified} modified`)
    if (summary.staged > 0) parts.push(`${summary.staged} staged`)
    if (summary.deleted > 0) parts.push(`${summary.deleted} deleted`)
    if (summary.untracked > 0) parts.push(`${summary.untracked} untracked`)
    if (summary.renamed > 0) parts.push(`${summary.renamed} renamed`)
    return parts.join(' · ')
  }
  return props.cwd ?? ''
})

// Emit event when file is clicked (for opening in editor)
const handleFileClick = (entry: FolderEntry) => {
  if (entry.is_directory) {
    toggleFolder(entry)
    // Also emit so parents (e.g. CreateWorktreeDialog's picker) can navigate into the clicked
    // folder. toggleFolder above still runs so existing consumers (RightSidebar) keep their expand/
    // collapse behavior unchanged.
    emit('folder-click', entry)
  } else {
    // Emit file click event for non-directory files
    emit('file-click', entry)
  }
}

// Open folder on click (for files) or toggle (for folders)
const handleClick = (entry: FolderEntry) => {
  handleFileClick(entry)
}
</script>

<template>
  <div
    class="flex flex-col h-full w-full min-h-0"
    style="background-color: var(--semantic-sidebar-bg)"
    data-testid="folder-explorer"
  >
    <!-- Header: branch chip in git repos, folder name otherwise -->
    <div
      class="h-10 flex items-center px-3 gap-2 shrink-0 text-body font-medium"
      style="border-bottom: 1px solid var(--color-border); color: var(--semantic-text)"
    >
      <template v-if="isGitRepo">
        <UiIcon name="leaf" size-class="w-4 h-4" style="color: var(--color-aqua)" />
        <span data-testid="git-branch" style="color: var(--color-aqua)">{{ gitBranch }}</span>
        <span
          class="inline-block w-2 h-2 rounded-full"
          :style="{ backgroundColor: hasGitChanges ? 'var(--color-orange)' : 'var(--color-green)' }"
          :title="hasGitChanges ? 'Uncommitted changes' : 'Working tree clean'"
        />
      </template>
      <template v-else>
        <span v-if="headerName">{{ headerName }}</span>
        <span v-else style="color: var(--semantic-text-dim)">No folder</span>
      </template>
      <span class="flex-1" />
      <button
        v-if="hasInput"
        type="button"
        data-testid="explorer-refresh"
        title="Refresh"
        aria-label="Refresh"
        class="p-1 rounded hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        @click="refreshAll"
      >
        <UiIcon name="refresh" size-class="w-3.5 h-3.5" />
      </button>
    </div>

    <!-- Name filter -->
    <div v-if="hasInput" class="px-2 pt-2 shrink-0">
      <input
        v-model="filterText"
        data-testid="explorer-filter"
        type="text"
        placeholder="Filter files…"
        class="w-full px-2 py-1 rounded text-dense outline-none"
        style="
          background-color: var(--semantic-content-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
      />
    </div>

    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg
        class="animate-spin w-5 h-5"
        style="color: var(--color-aqua)"
        viewBox="0 0 24 24"
        fill="none"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
    </div>

    <!-- Error state -->
    <div
      v-else-if="loadError"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-title-lg mb-2">⚠️</span>
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        {{ loadError }}
      </p>
    </div>

    <!-- Empty state (no cwd) -->
    <div
      v-else-if="!hasInput"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <UiIcon name="folder-open" size-class="w-7 h-7" class="mb-3" />
      <p class="text-dense" style="color: var(--semantic-text-dim)">Pass a cwd to browse files</p>
    </div>

    <!-- Empty folder / no filter matches -->
    <div
      v-else-if="filteredEntries.length === 0 && !isLoading"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <UiIcon name="inbox" size-class="w-6 h-6" class="mb-2" />
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        {{ filterText ? `No files match "${filterText}"` : 'Empty folder' }}
      </p>
    </div>

    <!-- File/Folder List -->
    <div v-else class="flex-1 overflow-y-auto py-1">
      <button
        v-for="{ entry, depth, path, badge, childCount } in filteredEntries"
        :key="path"
        data-testid="explorer-row"
        :title="path"
        @click="handleClick(entry)"
        class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:opacity-80"
        :style="{ paddingLeft: `${0.75 + depth * 1.25}rem`, color: rowColor({ entry, depth, path, badge, childCount }) }"
        :class="{ 'line-through': badge?.kind === 'deleted' }"
      >
        <!-- Expand icon for folders -->
        <span
          v-if="entry.is_directory"
          class="w-3 text-dense flex justify-center transition-transform duration-150"
          :style="{ transform: isExpanded(path) ? 'rotate(90deg)' : 'rotate(0deg)' }"
          >▶</span
        >
        <span v-else class="w-3"></span>

        <!-- File-type icon -->
        <UiIcon :name="fileIconFor(entry, path)" size-class="w-4 h-4" class="shrink-0" />

        <!-- Name -->
        <span class="truncate flex-1 text-left">{{ entry.name }}</span>

        <!-- Folder change count -->
        <span
          v-if="entry.is_directory && childCount > 0"
          data-testid="folder-count"
          class="git-count-pill"
          >{{ childCount }}</span
        >
        <!-- Git status badge -->
        <span
          v-else-if="badge"
          data-testid="git-badge"
          class="git-badge"
          :class="`git-badge-${badge.kind}`"
          :title="badge.kind"
          >{{ badge.badge }}</span
        >
      </button>
    </div>

    <!-- Footer: change summary in git repos, cwd path otherwise -->
    <div
      v-if="cwd"
      data-testid="explorer-footer"
      class="h-8 flex items-center px-3 shrink-0 text-dense truncate"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim)"
      :title="cwd"
    >
      {{ footerText }}
    </div>
  </div>
</template>

<style scoped>
.git-badge {
  font-size: 10px;
  font-weight: 700;
  border-radius: 4px;
  padding: 1px 5px;
  line-height: 1.4;
  flex-shrink: 0;
}
.git-badge-modified {
  background-color: rgba(182, 146, 123, 0.18);
  color: var(--color-orange);
}
.git-badge-staged {
  background-color: rgba(135, 169, 135, 0.18);
  color: var(--color-green);
}
.git-badge-deleted {
  background-color: rgba(196, 116, 110, 0.18);
  color: var(--color-red);
}
.git-badge-untracked {
  background-color: rgba(115, 124, 115, 0.25);
  color: var(--semantic-text-dim);
}
.git-badge-renamed {
  background-color: rgba(139, 164, 176, 0.18);
  color: var(--color-blue);
}
.git-count-pill {
  font-size: 10px;
  font-weight: 500;
  border-radius: 4px;
  padding: 1px 5px;
  line-height: 1.4;
  flex-shrink: 0;
  background-color: var(--semantic-active-bg);
  color: var(--semantic-text-muted);
}
</style>
