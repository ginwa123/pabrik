<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, onUpdated } from 'vue'
import FolderExplorer from '../file/FolderExplorer.vue'
import RightSideBarSkillList from './RightSideBarSkillList.vue'
import GitCommits from '../git/GitCommits.vue'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'
import type { FolderEntry } from '../../api'
import * as api from '../../api'
import { forgetGitProbe } from '../../helpers/gitProbeGate'

const props = defineProps<{
  cwd?: string
  width?: number
}>()

const emit = defineEmits<{
  'file-click': [file: api.GitFileChange, staged: boolean]
  'skill-click': [skill: api.Skill]
  'code-editor-file-click': [file: FolderEntry]
  resize: [width: number]
}>()

// Default and bounds for width
const MIN_WIDTH = 200
const MAX_WIDTH = 600
const DEFAULT_WIDTH = 280

// Local width state
const localWidth = ref(props.width || DEFAULT_WIDTH)

// Resize handling
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

const startResize = (e: MouseEvent) => {
  isResizing.value = true
  resizeStartX.value = e.clientX
  resizeStartWidth.value = localWidth.value
  document.addEventListener('mousemove', onResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.cursor = 'ew-resize'
  document.body.style.userSelect = 'none'
}

const onResize = (e: MouseEvent) => {
  if (!isResizing.value) return
  const delta = resizeStartX.value - e.clientX
  const newWidth = Math.max(MIN_WIDTH, Math.min(MAX_WIDTH, resizeStartWidth.value + delta))
  localWidth.value = newWidth
}

const stopResize = () => {
  if (isResizing.value) {
    isResizing.value = false
    emit('resize', localWidth.value)
    document.removeEventListener('mousemove', onResize)
    document.removeEventListener('mouseup', stopResize)
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
  }
}

onUnmounted(() => {
  stopGitPoll()
  document.removeEventListener('mousemove', onResize)
  document.removeEventListener('mouseup', stopResize)
})

// Tab state
const activeTab = ref<'explorer' | 'git' | 'skills'>('explorer')
// Read-only history toggle inside the Git tab (Changes | Commits).
const gitView = ref<'changes' | 'commits'>('changes')

// Git state
const isGitRepo = ref(false)
const branch = ref('')
const stagedFiles = ref<api.GitFileChange[]>([])
const unstagedFiles = ref<api.GitFileChange[]>([])
const untrackedFiles = ref<api.GitFileChange[]>([])
const isLoadingGit = ref(false)
const gitError = ref<string | null>(null)

// Computed
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const hasChanges = computed(
  () =>
    stagedFiles.value.length > 0 ||
    unstagedFiles.value.length > 0 ||
    untrackedFiles.value.length > 0,
)
const changesCount = computed(() => stagedFiles.value.length + unstagedFiles.value.length)

// Get status display helpers
const getStatusIcon = (status: string): UiIconName => {
  const icons: Record<string, UiIconName> = {
    M: 'note',
    A: 'plus',
    D: 'trash',
    R: 'refresh',
    C: 'clipboard',
    '??': 'circle',
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

const getDisplayStatus = (file: api.GitFileChange): { icon: UiIconName; text: string } => {
  const indexStatus = file.index_status === ' ' ? '' : file.index_status
  const worktreeStatus = file.worktree_status === ' ' ? '' : file.worktree_status

  if (file.index_status === '??') {
    return { icon: 'circle', text: 'Untracked' }
  }

  if (indexStatus) {
    return { icon: getStatusIcon(indexStatus), text: getStatusText(indexStatus) }
  }

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
  gitError.value = null

  try {
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
    gitError.value = 'Failed to load git status'
  } finally {
    isLoadingGit.value = false
  }
}

// 30s git poll while a workspace is bound (ChatView.checkGitStatus precedent).
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
    if (props.cwd) void loadGitStatus()
  }, 30000)
}

// Cwd sync: load status + poll while bound; stop the poll and clear the
// lists when unbound. Prev-value guard on update — same body the watcher
// ran; the mount call covers the initial load (the old `immediate: true`).
function syncCwdGitStatus(newCwd: string | undefined) {
  if (newCwd) {
    loadGitStatus()
    startGitPoll()
  } else {
    stopGitPoll()
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
  }
}

let prevSidebarCwd: string | undefined = props.cwd
onMounted(() => {
  prevSidebarCwd = props.cwd
  syncCwdGitStatus(props.cwd)
})
onUpdated(() => {
  if (props.cwd === prevSidebarCwd) return
  prevSidebarCwd = props.cwd
  syncCwdGitStatus(props.cwd)
})

// Refresh git status
const refreshGitStatus = () => {
  forgetGitProbe(props.cwd ?? '')
  loadGitStatus()
}

// Handle file click from git
const handleFileClick = (file: api.GitFileChange, staged: boolean) => {
  emit('file-click', file, staged)
}

// Handle file click from explorer (open in CodeEditor in AppLayout)
const handleExplorerFileClick = (file: FolderEntry) => {
  console.log('[RightSidebar] handleExplorerFileClick called for:', file.name, file.path)
  // Only emit for non-directory files (directories are handled in FolderExplorer)
  console.log('[RightSidebar] emitting code-editor-file-click for:', file.name)
  emit('code-editor-file-click', file)
}

// Handle skill click - emit to parent (AppLayout handles fullscreen view)
const handleSkillClick = (skill: api.Skill) => {
  console.log('[RightSidebar] handleSkillClick called for:', skill.name)
  emit('skill-click', skill)
}
</script>

<template>
  <div
    class="flex flex-col h-full relative"
    :style="{ width: localWidth + 'px', backgroundColor: 'var(--semantic-sidebar-bg)' }"
  >
    <!-- Resize handle on the left edge -->
    <div
      class="absolute top-0 left-0 w-1 h-full cursor-ew-resize hover:bg-color-violet/30 transition-colors z-10"
      :class="{ 'bg-color-violet/50': isResizing }"
      @mousedown="startResize"
    />
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
            {{ changesCount }}
          </span>
        </button>
        <button
          @click="activeTab = 'skills'"
          class="flex-1 h-full px-3 text-body font-medium transition-colors flex items-center justify-center gap-1"
          :style="{
            color: activeTab === 'skills' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            backgroundColor: activeTab === 'skills' ? 'var(--semantic-active-bg)' : 'transparent',
            borderBottom:
              activeTab === 'skills' ? '2px solid var(--color-violet)' : '2px solid transparent',
          }"
        >
          <UiIcon name="brain" /> Skills
        </button>
      </div>
    </div>

    <!-- Content area -->
    <div class="flex-1 overflow-y-auto">
      <!-- Explorer tab -->
      <div v-if="activeTab === 'explorer'" class="h-full">
        <FolderExplorer :cwd="cwd" @file-click="handleExplorerFileClick" />
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

        <!-- Error state -->
        <div
          v-else-if="gitError"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-title-lg mb-2">⚠️</span>
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            {{ gitError }}
          </p>
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

        <!-- Repo: Changes | Commits (read-only history) -->
        <div v-else class="flex-1 flex flex-col min-h-0">
          <div class="flex shrink-0" style="border-bottom: 1px solid var(--color-border)">
            <button
              class="flex-1 px-3 py-1.5 text-dense font-medium transition-colors"
              :style="{
                color: gitView === 'changes' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
                borderBottom:
                  gitView === 'changes' ? '2px solid var(--color-violet)' : '2px solid transparent',
              }"
              @click="gitView = 'changes'"
            >
              Changes
            </button>
            <button
              class="flex-1 px-3 py-1.5 text-dense font-medium transition-colors"
              :style="{
                color: gitView === 'commits' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
                borderBottom:
                  gitView === 'commits' ? '2px solid var(--color-violet)' : '2px solid transparent',
              }"
              @click="gitView = 'commits'"
            >
              Commits
            </button>
          </div>
          <template v-if="gitView === 'changes'">
            <!-- No changes -->
            <div
              v-if="!hasChanges"
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
                  class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide"
                  style="color: var(--color-green)"
                >
                  Staged Changes ({{ stagedFiles.length }})
                </div>
                <button
                  v-for="file in stagedFiles"
                  :key="'staged-' + file.path"
                  class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:opacity-80"
                  @click="handleFileClick(file, true)"
                >
                  <UiIcon :name="getDisplayStatus(file).icon" size-class="w-4 h-4" />
                  <span class="flex-1 truncate text-left" style="color: var(--semantic-text)">
                    {{ file.path }}
                  </span>
                  <span
                    class="text-dense px-1.5 py-0.5 rounded"
                    style="background-color: rgba(34, 197, 94, 0.2); color: var(--color-green)"
                  >
                    {{ getDisplayStatus(file).text }}
                  </span>
                </button>
              </div>

              <!-- Unstaged Changes -->
              <div v-if="unstagedFiles.length > 0" class="py-1">
                <div
                  class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide"
                  style="color: var(--color-orange)"
                >
                  Changes ({{ unstagedFiles.length }})
                </div>
                <button
                  v-for="file in unstagedFiles"
                  :key="'unstaged-' + file.path"
                  class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:opacity-80"
                  @click="handleFileClick(file, false)"
                >
                  <UiIcon :name="getDisplayStatus(file).icon" size-class="w-4 h-4" />
                  <span class="flex-1 truncate text-left" style="color: var(--semantic-text)">
                    {{ file.path }}
                  </span>
                  <span
                    class="text-dense px-1.5 py-0.5 rounded"
                    style="background-color: rgba(245, 158, 11, 0.2); color: var(--color-orange)"
                  >
                    {{ getDisplayStatus(file).text }}
                  </span>
                </button>
              </div>

              <!-- Untracked Files -->
              <div v-if="untrackedFiles.length > 0" class="py-1">
                <div
                  class="px-3 py-1.5 text-dense font-semibold uppercase tracking-wide"
                  style="color: var(--semantic-text-dim)"
                >
                  Untracked ({{ untrackedFiles.length }})
                </div>
                <button
                  v-for="file in untrackedFiles"
                  :key="'untracked-' + file.path"
                  class="w-full flex items-center gap-2 px-3 py-1.5 text-body transition-colors hover:opacity-80"
                  @click="handleFileClick(file, false)"
                >
                  <UiIcon name="circle" size-class="w-4 h-4" />
                  <span class="flex-1 truncate text-left" style="color: var(--semantic-text-muted)">
                    {{ file.path }}
                  </span>
                  <span
                    class="text-dense px-1.5 py-0.5 rounded"
                    style="
                      background-color: rgba(156, 163, 175, 0.2);
                      color: var(--semantic-text-dim);
                    "
                  >
                    Untracked
                  </span>
                </button>
              </div>
            </div>
          </template>
          <div v-else class="flex-1 min-h-0">
            <GitCommits :cwd="cwd" />
          </div>
        </div>
      </div>

      <!-- Skills tab -->
      <div v-else-if="activeTab === 'skills'" class="h-full">
        <RightSideBarSkillList @skill-click="handleSkillClick" />
      </div>
    </div>
  </div>
</template>
