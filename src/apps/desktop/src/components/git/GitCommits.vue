<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import * as api from '../../api'
import UiIcon from '../ui/UiIcon.vue'
import ListSkeleton from '../shell/ListSkeleton.vue'
import type { UiIconName } from '../ui/icons'
import { parseUnifiedDiff, type ParsedDiffLine } from '../views/chat_right_sidebar/parseUnifiedDiff'
import { highlightLinesForFile, type Token } from '../../helpers/codeHighlight'

const props = withDefaults(
  defineProps<{
    cwd?: string
    /**
     * When true (default) a file click expands its diff inline below the
     * row — the only view available to hosts without a center column
     * (RightSidebar). When false the row emits `commit-file-click` instead
     * and the host renders the diff itself (SidebarDiffPanel forwards it
     * to ChatView's center column, like worktree/PR file rows).
     */
    inlineFileDiff?: boolean
  }>(),
  { inlineFileDiff: true },
)

const emit = defineEmits<{
  'commit-click': [commit: api.GitCommit]
  'commit-file-click': [payload: { commit: api.GitCommit; file: api.GitCommitFile }]
}>()

const inlineDiff = computed(() => props.inlineFileDiff ?? true)

const PAGE_SIZE = 100

const isGitRepo = ref(false)
const branch = ref('')
const totalCount = ref(0)
const commits = ref<api.GitCommit[]>([])
const isLoading = ref(false)
const isLoadingMore = ref(false)
const error = ref<string | null>(null)
const selectedSha = ref<string | null>(null)
const detailCache = ref<Record<string, api.GitCommitDetail>>({})
const detailLoading = ref<string | null>(null)
// Per-file unified diffs, keyed `${sha}::${path}`. Read-only inline view:
// click a touched file to expand its diff at that commit.
const fileDiffCache = ref<Record<string, ParsedDiffLine[]>>({})
const fileDiffLoading = ref<Record<string, boolean>>({})
const fileDiffError = ref<Record<string, boolean>>({})
const openFileKey = ref<string | null>(null)
const hasMore = ref(false)

const fileKey = (sha: string, path: string): string => `${sha}::${path}`

const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const loadedCount = computed(() => commits.value.length)
const footerLabel = computed(() => {
  if (totalCount.value > 0) return `${loadedCount.value} of ${totalCount.value}`
  return `${loadedCount.value}`
})

const authorInitials = (name: string): string => {
  const parts = (name ?? '').trim().split(/\s+/).filter(Boolean)
  const first = parts[0] ?? ''
  if (parts.length <= 1) return first.slice(0, 2) || '?'
  const last = parts[parts.length - 1] ?? ''
  return ((first[0] ?? '') + (last[0] ?? '')).toUpperCase() || '?'
}

const formatDate = (ts: number): string => {
  if (!ts) return ''
  try {
    return new Date(ts * 1000).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    })
  } catch {
    return ''
  }
}

const loadCommits = async (append = false) => {
  if (!props.cwd) {
    isGitRepo.value = false
    commits.value = []
    return
  }
  if (append) isLoadingMore.value = true
  else {
    isLoading.value = true
    error.value = null
  }
  try {
    const skip = append ? commits.value.length : 0
    const data = await api.getGitCommits(props.cwd, PAGE_SIZE, skip)
    isGitRepo.value = data.is_git_repo
    branch.value = data.branch || ''
    totalCount.value = data.total_count || 0
    if (data.is_git_repo) {
      const rows = data.commits || []
      commits.value = append ? [...commits.value, ...rows] : rows
      // More pages remain when a full page came back and (when known)
      // we have not reached the total yet.
      hasMore.value =
        rows.length >= PAGE_SIZE &&
        (totalCount.value <= 0 || commits.value.length < totalCount.value)
    } else {
      if (!append) commits.value = []
      hasMore.value = false
    }
  } catch (err) {
    console.error('Failed to load git commits:', err)
    if (!append) {
      isGitRepo.value = false
      error.value = 'Failed to load commits'
    }
    hasMore.value = false
  } finally {
    isLoading.value = false
    isLoadingMore.value = false
  }
}

const onScroll = (event: Event) => {
  const el = event.target as HTMLElement
  if (!el || isLoadingMore.value || !hasMore.value) return
  // Prefetch the next page before the scroll reaches the bottom.
  if (el.scrollHeight - el.scrollTop - el.clientHeight < 400) {
    void loadCommits(true)
  }
}

const selectCommit = (commit: api.GitCommit) => {
  if (selectedSha.value === commit.sha) {
    selectedSha.value = null
    return
  }
  selectedSha.value = commit.sha
  emit('commit-click', commit)
  void ensureDetail(commit)
}

const ensureDetail = async (commit: api.GitCommit) => {
  if (!props.cwd || detailCache.value[commit.sha]) return
  detailLoading.value = commit.sha
  try {
    const detail = await api.getGitCommitDetail(props.cwd, commit.sha)
    if (detail) detailCache.value = { ...detailCache.value, [commit.sha]: detail }
  } finally {
    if (detailLoading.value === commit.sha) detailLoading.value = null
  }
}

const statusIcon = (status: string): UiIconName => {
  const icons: Record<string, UiIconName> = {
    M: 'note',
    A: 'plus',
    D: 'trash',
    R: 'refresh',
    C: 'clipboard',
  }
  return icons[status] ?? 'file'
}

const toggleFile = (commit: api.GitCommit, file: api.GitCommitFile) => {
  if (!inlineDiff.value) {
    emit('commit-file-click', { commit, file })
    return
  }
  const key = fileKey(commit.sha, file.path)
  if (openFileKey.value === key) {
    openFileKey.value = null
    return
  }
  openFileKey.value = key
  void ensureFileDiff(commit, file, key)
}

const ensureFileDiff = async (commit: api.GitCommit, file: api.GitCommitFile, key: string) => {
  if (!props.cwd || fileDiffCache.value[key]) return
  fileDiffLoading.value = { ...fileDiffLoading.value, [key]: true }
  fileDiffError.value = { ...fileDiffError.value, [key]: false }
  try {
    const diff = await api.getGitCommitFileDiff(props.cwd, commit.sha, file.path)
    if (diff) {
      const parsed = parseUnifiedDiff(diff.diff_content)
      fileDiffCache.value = { ...fileDiffCache.value, [key]: parsed.lines }
    } else {
      fileDiffError.value = { ...fileDiffError.value, [key]: true }
    }
  } catch {
    fileDiffError.value = { ...fileDiffError.value, [key]: true }
  } finally {
    const loading = { ...fileDiffLoading.value }
    delete loading[key]
    fileDiffLoading.value = loading
  }
}

// The inline diff of the ONE open file (only one row's diff is open at a
// time). Precomputed here so the render below never re-tokenizes per
// render — `fileKey` is `<sha>::<path>`, so the path is the part after it.
const openFileLines = computed(() =>
  openFileKey.value ? (fileDiffCache.value[openFileKey.value] ?? []) : [],
)
const openFilePath = computed(() => openFileKey.value?.split('::').slice(1).join('::') ?? '')
const openFileTokens = computed<Token[][]>(() => {
  const lines = openFileLines.value
  const tokens = highlightLinesForFile(
    lines.map((line) => line.content),
    openFilePath.value,
  )
  // A hunk header is diff metadata, not code — tokenizing it would paint its
  // numbers over the row's hunk colour. Rendered plain, like every other
  // unified surface in the app.
  return lines.map((line, i) =>
    line.type === 'hunk' ? [{ text: line.content, type: 'plain' }] : tokens[i]!,
  )
})

const diffLineStyle = (line: ParsedDiffLine): Record<string, string> => {
  // The base colour is explicit: `.tok-plain` inherits, and the colour a diff
  // line falls back to must not depend on whatever hosts this list.
  const base = { color: 'var(--semantic-text)' }
  if (line.type === 'add') return { ...base, backgroundColor: 'rgba(34, 197, 94, 0.12)' }
  if (line.type === 'remove') return { ...base, backgroundColor: 'rgba(239, 68, 68, 0.12)' }
  if (line.type === 'hunk') return { ...base, color: 'var(--color-aqua)' }
  return base
}

// Reload on cwd change (prev-value guard on update — same reset+load the
// watcher did; the mount call covers the initial load).
function syncCommitsCwd(newCwd: string | undefined) {
  selectedSha.value = null
  if (newCwd) void loadCommits(false)
  else {
    isGitRepo.value = false
    commits.value = []
    hasMore.value = false
  }
}

let prevCommitsCwd: string | undefined = props.cwd
onMounted(() => {
  prevCommitsCwd = props.cwd
  syncCommitsCwd(props.cwd)
})
onUpdated(() => {
  if (props.cwd === prevCommitsCwd) return
  prevCommitsCwd = props.cwd
  syncCommitsCwd(props.cwd)
})

const refresh = () => {
  selectedSha.value = null
  void loadCommits(false)
}

defineExpose({ refresh })
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Loading — skeleton on the first page (holds the list's height);
         a centered spinner on a refresh, where the previous rows are
         already on screen and only the badge is changing. -->
    <ListSkeleton
      v-if="isLoading && commits.length === 0"
      :rows="10"
      row-height="h-12"
      test-id="git-commits-skeleton"
    />
    <div v-else-if="isLoading" class="flex-1 flex items-center justify-center">
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

    <!-- Error -->
    <div v-else-if="error" class="flex-1 flex flex-col items-center justify-center p-4 text-center">
      <span class="text-title-lg mb-2">⚠️</span>
      <p class="text-dense" style="color: var(--semantic-text-dim)">{{ error }}</p>
    </div>

    <!-- Not a git repo -->
    <div
      v-else-if="!isGitRepo || !hasInput"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <UiIcon name="leaf" size-class="w-6 h-6" class="mb-3" />
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        {{ !hasInput ? 'Select a workspace to view commits' : 'Not a git repository' }}
      </p>
    </div>

    <!-- Empty history -->
    <div
      v-else-if="commits.length === 0"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <UiIcon name="inbox" size-class="w-6 h-6" class="mb-3" />
      <p class="text-dense" style="color: var(--semantic-text-dim)">No commits yet</p>
      <p v-if="branch" class="text-dense mt-1" style="color: var(--semantic-text-dim)">
        Branch: {{ branch }}
      </p>
    </div>

    <!-- Commit list -->
    <template v-else>
      <div
        class="px-3 py-2 text-dense flex items-center gap-2 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <UiIcon name="leaf" style="color: var(--semantic-text-muted)" />
        <span class="truncate" style="color: var(--semantic-text)">{{ branch }}</span>
        <button
          class="ml-auto p-1 rounded hover:opacity-70 transition-opacity"
          title="Refresh"
          @click="refresh"
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

      <div class="flex-1 overflow-y-auto" @scroll="onScroll">
        <template v-for="commit in commits" :key="commit.sha">
          <button
            class="w-full flex items-center gap-2 px-3 py-1.5 text-body text-left transition-colors hover:bg-white/5"
            :style="{
              backgroundColor:
                selectedSha === commit.sha ? 'var(--semantic-active-bg)' : 'transparent',
            }"
            :title="`${commit.sha}\n${commit.author} — ${formatDate(commit.timestamp)}\n\n${commit.subject}`"
            @click="selectCommit(commit)"
          >
            <span class="shrink-0 font-mono text-dense" style="color: var(--color-green)">
              {{ commit.short_sha }}
            </span>
            <span
              class="shrink-0 text-dense font-medium"
              style="color: var(--color-violet)"
              :title="commit.author"
            >
              {{ authorInitials(commit.author) }}
            </span>
            <span
              class="shrink-0 w-2 h-2 rounded-full"
              style="background-color: var(--color-orange)"
            />
            <span class="flex-1 truncate" style="color: var(--semantic-text)">
              {{ commit.subject }}
            </span>
          </button>
          <div
            v-if="selectedSha === commit.sha"
            class="px-3 py-2 ml-4 mb-1 rounded"
            style="
              border-left: 2px solid var(--color-violet);
              background-color: rgba(255, 255, 255, 0.02);
            "
          >
            <div class="text-dense font-mono break-all" style="color: var(--color-green)">
              {{ commit.sha }}
            </div>
            <div class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              {{ commit.author }} &lt;{{ commit.email }}&gt; · {{ formatDate(commit.timestamp) }}
            </div>
            <p
              v-if="detailCache[commit.sha]?.body"
              class="text-dense mt-1 whitespace-pre-wrap"
              style="color: var(--semantic-text)"
            >
              {{ detailCache[commit.sha]?.body }}
            </p>
            <div
              v-if="detailLoading === commit.sha"
              class="text-dense mt-1"
              style="color: var(--semantic-text-dim)"
            >
              Loading files…
            </div>
            <div
              v-else-if="detailCache[commit.sha]?.files?.length"
              class="mt-1 flex flex-col gap-0.5"
            >
              <template v-for="file in detailCache[commit.sha]?.files ?? []" :key="file.path">
                <button
                  class="w-full flex items-center gap-2 text-dense text-left rounded px-1 py-0.5 transition-colors hover:bg-white/5"
                  :title="`Show diff at ${commit.short_sha}`"
                  @click="toggleFile(commit, file)"
                >
                  <UiIcon :name="statusIcon(file.status)" />
                  <span
                    class="flex-1 truncate"
                    style="color: var(--semantic-text)"
                    :title="file.path"
                  >
                    {{ file.path }}
                  </span>
                  <span style="color: var(--semantic-text-dim)">
                    {{ openFileKey === fileKey(commit.sha, file.path) ? '▾' : '▸' }}
                  </span>
                </button>
                <div
                  v-if="inlineDiff && openFileKey === fileKey(commit.sha, file.path)"
                  class="ml-4 rounded overflow-x-auto font-mono"
                  style="border: 1px solid var(--color-border); font-size: var(--text-meta)"
                >
                  <div
                    v-if="fileDiffLoading[fileKey(commit.sha, file.path)]"
                    class="px-2 py-1.5"
                    style="color: var(--semantic-text-dim)"
                  >
                    Loading diff…
                  </div>
                  <div
                    v-else-if="fileDiffError[fileKey(commit.sha, file.path)]"
                    class="px-2 py-1.5"
                    style="color: var(--semantic-error)"
                  >
                    Failed to load diff
                  </div>
                  <div
                    v-else-if="(fileDiffCache[fileKey(commit.sha, file.path)] ?? []).length === 0"
                    class="px-2 py-1.5"
                    style="color: var(--semantic-text-dim)"
                  >
                    No changes
                  </div>
                  <div
                    v-for="(line, lineIdx) in openFileLines"
                    :key="line.lineIndex"
                    class="px-2 whitespace-pre"
                    :style="diffLineStyle(line)"
                  >
                    <span
                      v-for="(tok, tIdx) in openFileTokens[lineIdx]"
                      :key="tIdx"
                      :class="`tok-${tok.type}`"
                      >{{ tok.text || '\u00a0' }}</span
                    >
                  </div>
                </div>
              </template>
            </div>
          </div>
        </template>

        <div v-if="isLoadingMore" class="flex items-center justify-center py-3">
          <svg
            class="animate-spin w-4 h-4"
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
      </div>

      <div
        class="px-3 py-1.5 text-dense text-right shrink-0"
        style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim)"
      >
        {{ footerLabel }}
      </div>
    </template>
  </div>
</template>
