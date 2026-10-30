<script setup lang="ts">
import { ref, computed, onMounted, onUpdated } from 'vue'
import * as api from '../../api'
import { forgetGitProbe } from '../../helpers/gitProbeGate'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

const props = defineProps<{
  cwd?: string
}>()

const emit = defineEmits<{
  'file-click': [file: api.GitFileChange, staged: boolean]
}>()

// State
const error = ref<string | null>(null)
const activeTab = ref<'explorer' | 'git'>('explorer')

// Git state
const isGitRepo = ref(false)
const branch = ref('')
const stagedFiles = ref<api.GitFileChange[]>([])
const unstagedFiles = ref<api.GitFileChange[]>([])
const untrackedFiles = ref<api.GitFileChange[]>([])
const isLoadingGit = ref(false)

// Context menu state
const contextMenu = ref<{
  visible: boolean
  x: number
  y: number
  file: api.GitFileChange | null
  staged: boolean
}>({
  visible: false,
  x: 0,
  y: 0,
  file: null,
  staged: false,
})

// Action loading state
const isStaging = ref(false)

// Get status character description
const getStatusIcon = (status: string): UiIconName => {
  const icons: Record<string, UiIconName> = {
    M: 'note', // Modified
    A: 'plus', // Added
    D: 'trash', // Deleted
    R: 'refresh', // Renamed
    C: 'clipboard', // Copied
    '??': 'circle', // Untracked
  }
  return icons[status] || 'file'
}

const getStatusText = (status: string): string => {
  const texts: Record<string, string> = {
    M: 'Modified',
    A: 'Added',
    D: 'Deleted',
    R: 'Renamed',
    C: 'Copied',
    '??': 'Untracked',
  }
  return texts[status] || 'Changed'
}

// Get combined status for display
const getDisplayStatus = (file: api.GitFileChange): { icon: UiIconName; text: string } => {
  const indexStatus = file.index_status === ' ' ? '' : file.index_status
  const worktreeStatus = file.worktree_status === ' ' ? '' : file.worktree_status

  // Handle untracked files
  if (file.index_status === '??') {
    return { icon: 'circle', text: 'Untracked' }
  }

  // Staged change
  if (indexStatus) {
    return { icon: getStatusIcon(indexStatus), text: getStatusText(indexStatus) }
  }

  // Unstaged change
  if (worktreeStatus) {
    return { icon: getStatusIcon(worktreeStatus), text: getStatusText(worktreeStatus) }
  }

  return { icon: 'file', text: 'Changed' }
}

// Load git status
const loadGitStatus = async () => {
  if (!props.cwd) {
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
    return
  }

  isLoadingGit.value = true
  error.value = null

  try {
    // Get git changes with staged/unstaged/untracked files
    const data = await api.getGitChanges(props.cwd)

    isGitRepo.value = data.is_git_repo
    branch.value = data.branch || ''

    if (data.is_git_repo) {
      stagedFiles.value = data.staged_files || []
      unstagedFiles.value = data.modified_files || []
      untrackedFiles.value = data.untracked_files || []
    } else {
      stagedFiles.value = []
      unstagedFiles.value = []
      untrackedFiles.value = []
    }
  } catch (err) {
    console.error('Failed to load git status:', err)
    isGitRepo.value = false
    error.value = 'Failed to load git status'
  } finally {
    isLoadingGit.value = false
  }
}

// Cwd sync: load status while bound, clear the lists when unbound.
// Prev-value guard on update — same body the watcher ran; the mount call
// covers the initial load (the old `immediate: true`).
function syncChangesCwd(newCwd: string | undefined) {
  if (newCwd) {
    loadGitStatus()
  } else {
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
  }
}

let prevChangesCwd: string | undefined = props.cwd
onMounted(() => {
  prevChangesCwd = props.cwd
  syncChangesCwd(props.cwd)
})
onUpdated(() => {
  if (props.cwd === prevChangesCwd) return
  prevChangesCwd = props.cwd
  syncChangesCwd(props.cwd)
})

// Refresh git status
const refreshGitStatus = () => {
  forgetGitProbe(props.cwd ?? '')
  loadGitStatus()
}

// Context menu handlers
const showContextMenu = (event: MouseEvent, file: api.GitFileChange, staged: boolean) => {
  event.preventDefault()
  contextMenu.value = {
    visible: true,
    x: event.clientX,
    y: event.clientY,
    file,
    staged,
  }
}

const hideContextMenu = () => {
  contextMenu.value.visible = false
}

// Close context menu on click outside
onMounted(() => {
  document.addEventListener('click', hideContextMenu)
})

// Stage file (move from unstaged to staged)
const stageFile = async (file: api.GitFileChange) => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  hideContextMenu()
  try {
    await api.stageGitFiles(props.cwd, [file.path])
    await loadGitStatus()
  } catch (err) {
    console.error('Failed to stage file:', err)
  } finally {
    isStaging.value = false
  }
}

// Unstage file (move from staged to unstaged)
const unstageFile = async (file: api.GitFileChange) => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  hideContextMenu()
  try {
    await api.unstageGitFiles(props.cwd, [file.path])
    await loadGitStatus()
  } catch (err) {
    console.error('Failed to unstage file:', err)
  } finally {
    isStaging.value = false
  }
}

// Stage all unstaged files
const stageAllFiles = async () => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  hideContextMenu()
  try {
    const files = unstagedFiles.value.map((f) => f.path)
    if (files.length > 0) {
      await api.stageGitFiles(props.cwd, files)
      await loadGitStatus()
    }
  } catch (err) {
    console.error('Failed to stage all files:', err)
  } finally {
    isStaging.value = false
  }
}

// Unstage all staged files
const unstageAllFiles = async () => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  hideContextMenu()
  try {
    const files = stagedFiles.value.map((f) => f.path)
    if (files.length > 0) {
      await api.unstageGitFiles(props.cwd, files)
      await loadGitStatus()
    }
  } catch (err) {
    console.error('Failed to unstage all files:', err)
  } finally {
    isStaging.value = false
  }
}

// Compute header info
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const hasChanges = computed(
  () =>
    stagedFiles.value.length > 0 ||
    unstagedFiles.value.length > 0 ||
    untrackedFiles.value.length > 0,
)
</script>

<template>
  <div
    class="flex flex-col h-full"
    style="
      width: 280px;
      background-color: var(--semantic-sidebar-bg);
      border-left: 1px solid var(--color-border);
    "
  >
    <!-- Header with tabs -->
    <div
      class="h-10 flex items-center shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <!-- Tab buttons -->
      <div class="flex flex-1">
        <button
          @click="activeTab = 'explorer'"
          class="flex-1 h-full px-3 text-body font-medium transition-colors"
          :style="{
            color: activeTab === 'explorer' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            backgroundColor: activeTab === 'explorer' ? 'var(--semantic-active-bg)' : 'transparent',
            borderBottom:
              activeTab === 'explorer' ? '2px solid var(--color-violet)' : '2px solid transparent',
          }"
        >
          Explorer
        </button>
        <button
          @click="activeTab = 'git'"
          class="flex-1 h-full px-3 text-body font-medium transition-colors flex items-center justify-center gap-1"
          :style="{
            color: activeTab === 'git' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            backgroundColor: activeTab === 'git' ? 'var(--semantic-active-bg)' : 'transparent',
            borderBottom:
              activeTab === 'git' ? '2px solid var(--color-violet)' : '2px solid transparent',
          }"
        >
          Git
          <span
            v-if="hasChanges"
            class="px-1.5 py-0.5 rounded text-dense font-medium"
            style="background-color: var(--color-orange); color: var(--color-bg)"
          >
            {{ stagedFiles.length + unstagedFiles.length }}
          </span>
        </button>
      </div>
    </div>

    <!-- Content area -->
    <div class="flex-1 overflow-y-auto">
      <!-- Explorer tab -->
      <div v-if="activeTab === 'explorer'" class="h-full">
        <slot name="explorer"></slot>
      </div>

      <!-- Git tab -->
      <div v-else-if="activeTab === 'git'" class="h-full flex flex-col">
        <!-- Loading -->
        <div v-if="isLoadingGit" class="flex-1 flex items-center justify-center">
          <svg
            class="animate-spin w-5 h-5"
            style="color: var(--color-aqua)"
            viewBox="0 0 24 24"
            fill="none"
          >
            <circle
              class="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              stroke-width="4"
            />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
        </div>

        <!-- Not a git repo -->
        <div
          v-else-if="!isGitRepo || !hasInput"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <UiIcon name="leaf" size-class="w-6 h-6" class="mb-3" />
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            {{ !hasInput ? 'Select a workspace to view git status' : 'Not a git repository' }}
          </p>
        </div>

        <!-- No changes -->
        <div
          v-else-if="!hasChanges"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-display mb-3">✓</span>
          <p class="text-dense" style="color: var(--semantic-text-dim)">Working tree clean</p>
          <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
            Branch: {{ branch }}
          </p>
        </div>

        <!-- Git changes -->
        <div v-else class="flex-1 overflow-y-auto">
          <!-- Branch info -->
          <div
            class="px-3 py-2 text-dense flex items-center gap-2"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <UiIcon name="leaf" style="color: var(--semantic-text-muted)" />
            <span style="color: var(--semantic-text)">{{ branch }}</span>
            <button
              @click="refreshGitStatus"
              class="ml-auto p-1 rounded hover:opacity-70 transition-opacity"
              title="Refresh"
            >
              <svg
                class="w-3 h-3"
                style="color: var(--semantic-text-dim)"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                />
              </svg>
            </button>
          </div>

          <!-- Staged Changes -->
          <div v-if="stagedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide flex items-center justify-between"
              style="color: var(--color-green)"
            >
              <span>Staged ({{ stagedFiles.length }})</span>
              <button
                @click="unstageAllFiles"
                :disabled="isStaging"
                class="px-1.5 py-0.5 rounded text-dense transition-all hover:opacity-100 disabled:opacity-50"
                style="background-color: rgba(34, 197, 94, 0.2); color: var(--color-green)"
                title="Unstage All"
              >
                ↩ Unstage All
              </button>
            </div>
            <div
              v-for="file in stagedFiles"
              :key="'staged-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:bg-(--hover-bg) group"
              @contextmenu="showContextMenu($event, file, true)"
              @click="emit('file-click', file, true)"
            >
              <UiIcon :name="getDisplayStatus(file).icon" size-class="w-4 h-4" />
              <span class="flex-1 truncate" style="color: var(--semantic-text)">
                {{ file.path }}
              </span>
              <button
                @click.stop="unstageFile(file)"
                :disabled="isStaging"
                class="p-1 rounded transition-opacity hover:bg-(--semantic-active-bg)"
                style="opacity: 0.5"
                :style="{ opacity: isStaging ? 0.3 : 0.5 }"
                title="Unstage"
              >
                <svg
                  class="w-4 h-4"
                  style="color: var(--color-orange)"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 5l7 7-7 7M5 5l7 7-7 7"
                  />
                </svg>
              </button>
              <span
                class="text-dense px-1.5 py-0.5 rounded"
                style="background-color: rgba(34, 197, 94, 0.2); color: var(--color-green)"
              >
                {{ getDisplayStatus(file).text }}
              </span>
            </div>
          </div>

          <!-- Unstaged Changes -->
          <div v-if="unstagedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide flex items-center justify-between"
              style="color: var(--color-orange)"
            >
              <span>Changes ({{ unstagedFiles.length }})</span>
              <button
                @click="stageAllFiles"
                :disabled="isStaging"
                class="px-1.5 py-0.5 rounded text-dense transition-all hover:opacity-100 disabled:opacity-50"
                style="background-color: rgba(245, 158, 11, 0.2); color: var(--color-orange)"
                title="Stage All"
              >
                ↪ Stage All
              </button>
            </div>
            <div
              v-for="file in unstagedFiles"
              :key="'unstaged-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:bg-(--hover-bg) group"
              @contextmenu="showContextMenu($event, file, false)"
              @click="emit('file-click', file, false)"
            >
              <UiIcon :name="getDisplayStatus(file).icon" size-class="w-4 h-4" />
              <span class="flex-1 truncate" style="color: var(--semantic-text)">
                {{ file.path }}
              </span>
              <button
                @click.stop="stageFile(file)"
                :disabled="isStaging"
                class="p-1 rounded transition-opacity hover:bg-(--semantic-active-bg)"
                :style="{ opacity: isStaging ? 0.3 : 0.5 }"
                title="Stage"
              >
                <svg
                  class="w-4 h-4"
                  style="color: var(--color-green)"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M11 5l-7 7 7 7M18 5l-7 7 7 7"
                  />
                </svg>
              </button>
              <span
                class="text-dense px-1.5 py-0.5 rounded"
                style="background-color: rgba(245, 158, 11, 0.2); color: var(--color-orange)"
              >
                {{ getDisplayStatus(file).text }}
              </span>
            </div>
          </div>

          <!-- Untracked Files -->
          <div v-if="untrackedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide flex items-center justify-between"
              style="color: var(--semantic-text-dim)"
            >
              <span>Untracked ({{ untrackedFiles.length }})</span>
              <button
                @click="stageAllFiles"
                :disabled="isStaging"
                class="px-1.5 py-0.5 rounded text-dense transition-all hover:opacity-100 disabled:opacity-50"
                style="background-color: rgba(156, 163, 175, 0.2); color: var(--semantic-text-dim)"
                title="Stage All"
              >
                ↪ Stage All
              </button>
            </div>
            <div
              v-for="file in untrackedFiles"
              :key="'untracked-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:bg-(--hover-bg) group"
              @contextmenu="showContextMenu($event, file, false)"
            >
              <UiIcon name="circle" size-class="w-4 h-4" />
              <span class="flex-1 truncate" style="color: var(--semantic-text-muted)">
                {{ file.path }}
              </span>
              <button
                @click.stop="stageFile(file)"
                :disabled="isStaging"
                class="p-1 rounded transition-opacity hover:bg-(--semantic-active-bg)"
                :style="{ opacity: isStaging ? 0.3 : 0.5 }"
                title="Stage"
              >
                <svg
                  class="w-4 h-4"
                  style="color: var(--color-green)"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M11 5l-7 7 7 7M18 5l-7 7 7 7"
                  />
                </svg>
              </button>
              <span
                class="text-dense px-1.5 py-0.5 rounded"
                style="background-color: rgba(156, 163, 175, 0.2); color: var(--semantic-text-dim)"
              >
                Untracked
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Context Menu -->
    <Teleport to="body">
      <div
        v-if="contextMenu.visible"
        class="fixed z-50 py-1 rounded-md shadow-lg"
        :style="{
          left: contextMenu.x + 'px',
          top: contextMenu.y + 'px',
          backgroundColor: 'var(--semantic-sidebar-bg)',
          border: '1px solid var(--color-border)',
        }"
        @click.stop
      >
        <template v-if="contextMenu.file">
          <!-- Stage option for unstaged/untracked files -->
          <button
            v-if="!contextMenu.staged"
            @click="stageFile(contextMenu.file!)"
            class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center gap-2"
            style="color: var(--semantic-text)"
          >
            <svg
              class="w-4 h-4"
              style="color: var(--color-green)"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M11 5l-7 7 7 7M18 5l-7 7 7 7"
              />
            </svg>
            Stage File
          </button>
          <!-- Unstage option for staged files -->
          <button
            v-if="contextMenu.staged"
            @click="unstageFile(contextMenu.file!)"
            class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center gap-2"
            style="color: var(--semantic-text)"
          >
            <svg
              class="w-4 h-4"
              style="color: var(--color-orange)"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 5l7 7-7 7M5 5l7 7-7 7"
              />
            </svg>
            Unstage File
          </button>
          <!-- Separator -->
          <div class="h-px my-1" style="background-color: var(--color-border)" />
          <!-- Stage All / Unstage All -->
          <button
            v-if="!contextMenu.staged && unstagedFiles.length > 0"
            @click="stageAllFiles"
            class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center gap-2"
            style="color: var(--semantic-text)"
          >
            <svg
              class="w-4 h-4"
              style="color: var(--color-green)"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
              />
            </svg>
            Stage All ({{ unstagedFiles.length }})
          </button>
          <button
            v-if="contextMenu.staged && stagedFiles.length > 0"
            @click="unstageAllFiles"
            class="w-full px-4 py-2 text-body text-left transition-colors hover:opacity-80 flex items-center gap-2"
            style="color: var(--semantic-text)"
          >
            <svg
              class="w-4 h-4"
              style="color: var(--color-orange)"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"
              />
            </svg>
            Unstage All ({{ stagedFiles.length }})
          </button>
        </template>
      </div>
    </Teleport>
  </div>
</template>
