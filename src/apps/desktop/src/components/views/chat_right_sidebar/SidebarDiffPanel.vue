<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { ApiError, type GitFileStageEvent } from '../../../api'
import { openInNewTab } from '../../../helpers/openInNewTab'
import { forgeWording } from '../../../helpers/forgeWording'
import { forgetGitProbe } from '../../../helpers/gitProbeGate'
import { useSseBus } from '../../../helpers/sseBus'
import { useContextMenu } from '../../../composables/useContextMenu'
import OpenInNewTabMenu from '../../shell/OpenInNewTabMenu.vue'
import GitCommits from '../../git/GitCommits.vue'
import PrChecksPanel from './PrChecksPanel.vue'
import ConversationPanel from './ConversationPanel.vue'
import MergeBox from './MergeBox.vue'
import SkillEvalsPanel from './SkillEvalsPanel.vue'
import SidebarDiffTabStrip from './SidebarDiffTabStrip.vue'
import SidebarGitHeader from './SidebarGitHeader.vue'
import SidebarPrHeader from './SidebarPrHeader.vue'
import SidebarPrFileList from './SidebarPrFileList.vue'
import SidebarPrNotices from './SidebarPrNotices.vue'
import SidebarPrChanges from './SidebarPrChanges.vue'
import SidebarWorktreeFileList from './SidebarWorktreeFileList.vue'
import SidebarWorktreeChanges from './SidebarWorktreeChanges.vue'
import type { DiffSelection } from './parseUnifiedDiff'
import type { PanelEmit } from './sidebarDiffTypes'
import {
  readConflictsParam,
  readTabParam,
  syncConflictsParam,
  syncTabParam,
  type PanelTab,
} from './sidebarDiffUrl'
import { useSidebarDiffGitData } from './useSidebarDiffGitData'
import { useSidebarDiffPrData } from './useSidebarDiffPrData'
import { useSidebarDiffRowOpen } from './useSidebarDiffRowOpen'

const props = defineProps<{
  cwd: string
  /** Branch from the bottom status bar (single source of truth, drilled via ChatRightSidebar from ChatView's `sidebarBranch`). */
  branch?: string
  /** Attached PR URL (set_pull_request tool). Non-empty switches the panel to PR mode. */
  prUrl?: string
  /** Effective provider for the attached PR (stored pr_provider). */
  prProvider?: string
  /** The session whose skill evals the Evals tab shows. Empty = every session. */
  sessionId?: string
}>()

const emit = defineEmits<{
  refresh: []
  /** File-row click: host swaps the center column to the full diff. */
  'show-diff': [selection: DiffSelection]
  /** Full ordered list after a list load (PR: parsed chunks; worktree: parallel per-file fetch). */
  'show-diff-list': [files: DiffSelection[]]
}>()

const router = useRouter()
const route = useRoute()

const isPrMode = computed(() => (props.prUrl ?? '').trim().length > 0)
const selectedPath = ref<string | null>(null)
const selectedStaged = ref(false)
const loadSeq = { current: 0 }
let prPollTimer: number | undefined
/// Unsubscribe handle for the `gitFileStage` bus listener (see onMounted).
let unsubscribeFileStage: (() => void) | null = null

// Displayed branch: the bottom status bar wins when it has a value.
const displayBranch = computed(() => props.branch ?? internalBranch.value)
// Every view switch lands in the URL (?panel=files|pr|commits|checks|evals) so refresh, Back/Forward, and shared links restore the same panel.
const initialTab = (): PanelTab => {
  let param: PanelTab | null = null
  try {
    param = readTabParam(route)
  } catch {
    // This catch exists ONLY for "mounted without a router" — hosts like ChatRightSidebar mount this panel standalone (ChatRightSidebar.spec.ts), and `useRoute()` …
    console.warn('[SidebarDiffPanel] mounted without a router; defaulting ?panel to files')
    param = null
  }
  // Evals and checks are reachable regardless of PR mode.
  if (param === 'evals') return 'evals'
  if (param === 'checks') return 'checks'
  if (isPrMode.value) return param ?? 'pr'
  return param === 'commits' ? 'commits' : 'files'
}
const activeTab = ref<PanelTab>(initialTab())
const showCommits = computed(() => activeTab.value === 'commits')
const showConversation = computed(() => activeTab.value === 'conversation')
const showChecks = computed(() => activeTab.value === 'checks')
const showEvals = computed(() => activeTab.value === 'evals')
// PrChecksPanel loads itself, so the sidebar's ↻ asks it directly rather than going through loadTab (which has nothing to fetch for this tab).
const checksRef = ref<InstanceType<typeof PrChecksPanel> | null>(null)
const conversationRef = ref<InstanceType<typeof ConversationPanel> | null>(null)
/** How many entries the forge's thread holds, once it has been read. */
const conversationCount = ref(0)
const showPr = computed(() => isPrMode.value && activeTab.value === 'pr')
const loadedTabs = ref(new Set<string>())

// Provider-aware vocabulary: "pull request"/"PR"/"GitHub" on GitHub, "merge request"/"MR"/"GitLab" on GitLab.
const forge = computed(() => forgeWording(props.prProvider))
// Restored from ?conflicts=1 on mount, so a reload or a shared link comes back showing only the conflicts.
const conflictsOnly = ref(
  (() => {
    try {
      return readConflictsParam(route)
    } catch {
      // Same guard and same reason as initialTab: no router means `route.query` throws, nothing was fetched, and there is no URL to keep in sync.
      console.warn('[SidebarDiffPanel] mounted without a router; defaulting ?conflicts to off')
      return false
    }
  })(),
)

const setConflictsOnly = (on: boolean) => {
  conflictsOnly.value = on
  syncConflictsParam(router, route, on)
}

// Extract the server's `{"error": "..."}` message from an ApiError (apiFetch throws ApiError with the raw body).
const serverErrorMessage = (err: unknown, fallback: string): string => {
  if (err instanceof ApiError && err.body) {
    try {
      const obj = JSON.parse(err.body) as { error?: unknown }
      if (obj && typeof obj.error === 'string' && obj.error.trim()) return obj.error
    } catch {
      /* non-JSON body — fall through to fallback */
    }
  }
  if (err instanceof Error && err.message) return err.message
  return fallback
}

const dataOptions = {
  cwd: () => props.cwd,
  prUrl: () => props.prUrl ?? '',
  prProvider: () => props.prProvider,
  isPrMode: () => isPrMode.value,
  isPrTab: () => showPr.value,
  emit: emit as PanelEmit,
  serverError: serverErrorMessage,
  selection: { path: selectedPath, staged: selectedStaged },
  loadSeq,
}

const pr = useSidebarDiffPrData(dataOptions)
const git = useSidebarDiffGitData(dataOptions)

const {
  prFiles,
  prBase,
  prHead,
  prTruncated,
  isLoadingPr,
  prError,
  prStatus,
  prStatusTitle,
  prStatusData,
  prStatusError,
  prConflictLoaded,
  prConflictFiles,
  prConflictError,
  prConflictBase,
  prConflictTruncated,
  prConflictUnreproduced,
  prConflictsUrl,
  hasPrConflict,
  failedChecksCount,
  loadPrDiff,
  loadPrStatus,
  loadPrConflicts,
  selectPrFile,
  retryPr,
  onMerged,
  resetConflicts,
} = pr

const {
  isGitRepo,
  internalBranch,
  stagedFiles,
  unstagedFiles,
  untrackedFiles,
  isLoadingGit,
  gitError,
  isStaging,
  diffCounts,
  changeCount,
  loadGitStatus,
  loadDiff,
  selectFile,
  onCommitFileClick,
  stageFile,
  unstageFile,
  applyFileStageEvent,
  commitMessage,
  isCommitting,
  commitError,
  canCommit,
  commitStaged,
} = git

// Right-click "Open file in new tab" for a file row.
const { menuPos, openAt, close: closeContextMenu } = useContextMenu()
const contextMenuPath = ref<string | null>(null)

const codeEditorQuery = (path: string): Record<string, string> => ({
  view: 'code-editor',
  file: path,
})

const openFileInNewTab = (path: string) => {
  // New tabs boot cold, so they resolve the cwd from the workspace path context — keep the current path instead of dropping to /app.
  openInNewTab(router, { path: route.path, query: codeEditorQuery(path) })
}

const onFileRowContextMenu = (event: MouseEvent, path: string) => {
  contextMenuPath.value = path
  openAt(event)
}

const openMenuFileInBackground = () => {
  const path = contextMenuPath.value
  contextMenuPath.value = null
  closeContextMenu()
  if (!path) return
  openFileInNewTab(path)
}

// ── The before/after, in the panel ────────────────────────────────────────
const previewPath = ref<string | null>(null)

/** One preview at a time: a second file replaces the first, so the list never grows a column of them. */
const togglePreview = (path: string) => {
  previewPath.value = previewPath.value === path ? null : path
}

const { onFileRowClick, onPrFileRowClick, onCommitFileRowClick, onConflictFileClick } =
  useSidebarDiffRowOpen({
    cwd: () => props.cwd,
    prUrl: () => props.prUrl ?? '',
    prFiles,
    openInBrowserTab: openFileInNewTab,
    selectFile,
    selectPrFile,
    togglePreview,
    onCommitFileClick,
  })

const onFileRowAuxClick = (event: MouseEvent, path: string) => {
  if (event.button !== 1) return
  event.preventDefault()
  openFileInNewTab(path)
}

// Short label for the header: "#42" from /pull/42 or /merge_requests/42, else the URL host.
const prLabel = computed(() => {
  const url = props.prUrl ?? ''
  const m = url.match(/\/(?:pull|merge_requests)\/(\d+)/)
  if (m?.[1]) return `#${m[1]}`
  try {
    return new URL(url).host
  } catch {
    return forgeWording(props.prProvider).short
  }
})

const fileFilter = ref('')

const onRefreshClick = () => {
  // Tell ChatView to re-sync the worktree binding first (it may have changed since mount); then reload this panel.
  forgetGitProbe(props.cwd)
  emit('refresh')
  void refreshCurrentTab()
}

// Per-tab lazy load: each side fetches once until cwd/prUrl changes.
const loadTab = async (tab: PanelTab, force = false) => {
  if (!force && loadedTabs.value.has(tab)) return
  if (tab === 'pr') await Promise.all([loadPrDiff(), loadPrStatus()])
  else if (tab === 'files') await loadGitStatus()
  loadedTabs.value.add(tab)
}

// Current-tab reload for the sidebar ↻ path (ChatRightSidebar.refresh delegates here).
const refreshCurrentTab = async () => {
  if (showPr.value) await loadTab('pr', true)
  else if (showConversation.value) conversationRef.value?.reload()
  else if (showCommits.value) await loadTab('commits', true)
  else if (showChecks.value) checksRef.value?.reload()
  else await loadTab('files', true)
}

const tabStripRef = ref<InstanceType<typeof SidebarDiffTabStrip> | null>(null)

const setActiveTab = (tab: PanelTab) => {
  activeTab.value = tab
  syncTabParam(router, route, tab)
  void loadTab(tab)
  void nextTick(() => {
    tabStripRef.value?.syncScroll()
  })
}

// PR-binding sync: tab/conflict state follows the [cwd, prUrl] binding.
function syncPrBinding(url: string | undefined, prevUrl: string | undefined) {
  const had = (prevUrl ?? '').trim().length > 0
  const has = (url ?? '').trim().length > 0
  if (had !== has) {
    if (has) activeTab.value = readTabParam(route) ?? 'pr'
    else if (activeTab.value === 'pr') {
      // Leaving PR mode drops back to files and clears the param; a commits tab survives (it needs no PR).
      activeTab.value = 'files'
      syncTabParam(router, route, null)
    }
    // The conflicts-only filter is a PR-tab view, so it must not outlive the PR it filtered — clear it and its query param with the binding.
    conflictsOnly.value = false
    syncConflictsParam(router, route, false)
    resetConflicts()
  }
  selectedPath.value = null
  loadedTabs.value.clear()
  void loadTab(activeTab.value, true)
}

let prevDiffCwd = props.cwd
let prevDiffPrUrl = props.prUrl
onUpdated(() => {
  if (props.cwd === prevDiffCwd && props.prUrl === prevDiffPrUrl) return
  const prevUrl = prevDiffPrUrl
  prevDiffCwd = props.cwd
  prevDiffPrUrl = props.prUrl
  syncPrBinding(props.prUrl, prevUrl)
})

onMounted(() => {
  void loadTab(activeTab.value, true)
  // Poll merge state while the PR tab is visible so a GitHub merge flips the badge without a manual refresh.
  prPollTimer = window.setInterval(() => {
    if (showPr.value) void loadPrStatus()
  }, 30000)
  // The backend pushes `git_file_staged` / `git_file_unstaged` after every `git add` / `git restore --staged`, so a +/− click moves ONE row instead of re-fetching …
  try {
    const bus = useSseBus()
    unsubscribeFileStage = bus.on('gitFileStage', (event: GitFileStageEvent) => {
      applyFileStageEvent(event)
    })
  } catch {
    // No bus installed (tests, or a host that never installed it).
  }
})

onUnmounted(() => {
  if (prPollTimer !== undefined) window.clearInterval(prPollTimer)
  unsubscribeFileStage?.()
  unsubscribeFileStage = null
})

defineExpose({
  loadGitStatus,
  loadPrDiff,
  loadPrStatus,
  loadPrConflicts,
  loadDiff,
  refresh: refreshCurrentTab,
  changeCount,
})
</script>
<template>
  <div class="flex flex-col h-full min-h-0" data-testid="sidebar-diff-panel">
    <SidebarDiffTabStrip
      ref="tabStripRef"
      :is-pr-mode="isPrMode"
      :active-tab="activeTab"
      :conversation-count="conversationCount"
      :change-count="changeCount"
      :pr-count="prFiles.length"
      :forge-short="forge.short"
      @select="setActiveTab"
    >
      <template #actions>
        <button
          type="button"
          class="w-7 h-7 rounded flex items-center justify-center hover:opacity-70 transition-opacity"
          style="color: var(--semantic-text-dim)"
          :title="`Refresh ${forge.short}`"
          data-testid="sidebar-diff-refresh"
          @click="onRefreshClick"
        >
          ↻
        </button>
      </template>
    </SidebarDiffTabStrip>

    <!-- ── The request header ───────────────────────────────────────────────
         The number is a lookup key; the title is what a reviewer reads
         first, and it was nowhere on the screen. The chips are doors: each
         one opens the tab that holds the reason. -->
    <SidebarPrHeader
      v-if="isPrMode"
      :pr-url="prUrl"
      :pr-provider="prProvider"
      :pr-label="prLabel"
      :pr-status="prStatus"
      :pr-status-title="prStatusTitle"
      :pr-status-data="prStatusData"
      :has-pr-conflict="hasPrConflict"
      :pr-conflict-files="prConflictFiles"
      :pr-files="prFiles"
      :pr-base="prBase"
      :pr-head="prHead"
      @select="setActiveTab"
    />
    <SidebarGitHeader v-else :display-branch="displayBranch" :change-count="changeCount" />

    <div v-if="showConversation" class="flex-1 min-h-0">
      <ConversationPanel
        ref="conversationRef"
        :cwd="cwd"
        :pr-url="prUrl"
        :pr-provider="prProvider"
        @loaded="conversationCount = $event"
      />
    </div>
    <div v-else-if="showChecks" class="flex-1 min-h-0">
      <PrChecksPanel ref="checksRef" :cwd="cwd" :pr-url="prUrl" :pr-provider="prProvider" />
    </div>
    <div v-else-if="showEvals" class="flex-1 min-h-0">
      <SkillEvalsPanel :session-id="sessionId" />
    </div>
    <div v-else-if="showCommits && !showPr" class="flex-1 min-h-0">
      <GitCommits :cwd="cwd" :inline-file-diff="false" @commit-file-click="onCommitFileRowClick" />
    </div>
    <div v-else class="flex-1 overflow-y-auto min-h-0">
      <SidebarPrFileList
        v-if="showPr"
        :is-loading-pr="isLoadingPr"
        :pr-files="prFiles"
        :pr-error="prError"
        :pr-status-error="prStatusError"
        :pr-provider="prProvider"
        @retry="retryPr"
      >
        <SidebarPrNotices
          :pr-provider="prProvider"
          :has-pr-conflict="hasPrConflict"
          :pr-conflict-files="prConflictFiles"
          :pr-conflicts-url="prConflictsUrl"
          :pr-conflict-loaded="prConflictLoaded"
          :pr-conflict-error="prConflictError"
          :pr-conflict-base="prConflictBase"
          :pr-conflict-truncated="prConflictTruncated"
          :pr-conflict-unreproduced="prConflictUnreproduced"
          :conflicts-only="conflictsOnly"
          :pr-status="prStatus"
          :pr-status-error="prStatusError"
          :pr-truncated="prTruncated"
          :selected-path="selectedPath"
          @conflicts-only="setConflictsOnly"
          @conflict-file-click="onConflictFileClick"
          @row-context-menu="onFileRowContextMenu"
        />
        <SidebarPrChanges
          :file-filter="fileFilter"
          @update:filter="fileFilter = $event"
          :pr-files="prFiles"
          :pr-conflict-files="prConflictFiles"
          :conflicts-only="conflictsOnly"
          :selected-path="selectedPath"
          :preview-path="previewPath"
          :pr-provider="prProvider"
          @pr-file-click="onPrFileRowClick"
          @row-aux-click="onFileRowAuxClick"
          @row-context-menu="onFileRowContextMenu"
        />
      </SidebarPrFileList>
      <SidebarWorktreeFileList
        v-else
        :is-loading-git="isLoadingGit"
        :change-count="changeCount"
        :git-error="gitError"
        :is-git-repo="isGitRepo"
        :cwd="cwd"
        :display-branch="displayBranch"
        @retry="loadGitStatus"
      >
        <SidebarWorktreeChanges
          :file-filter="fileFilter"
          @update:filter="fileFilter = $event"
          :commit-message="commitMessage"
          @update:commit-message="commitMessage = $event"
          :staged-files="stagedFiles"
          :unstaged-files="unstagedFiles"
          :untracked-files="untrackedFiles"
          :can-commit="canCommit"
          :is-committing="isCommitting"
          :commit-error="commitError"
          :is-staging="isStaging"
          :selected-path="selectedPath"
          :selected-staged="selectedStaged"
          :diff-counts="diffCounts"
          @commit="commitStaged"
          @stage="stageFile"
          @unstage="unstageFile"
          @file-click="onFileRowClick"
          @row-aux-click="onFileRowAuxClick"
          @row-context-menu="onFileRowContextMenu"
        />
      </SidebarWorktreeFileList>
    </div>

    <!-- The merge box is a FOOTER of the PR tab: a sibling of the scrolling
         list, so it stays put while the file list scrolls and grows into its
         confirm step without reflowing anything. PR tab only — a merge button
         on the Checks or Commits tab would be an action with no context. -->
    <MergeBox
      v-if="showPr"
      :cwd="cwd"
      :pr-url="prUrl ?? ''"
      :pr-provider="prProvider"
      :status="prStatusData"
      :failed-checks="failedChecksCount"
      @merged="onMerged"
    />

    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      :show-chat="false"
      show-file
      @open-file="openMenuFileInBackground"
    />
  </div>
</template>
