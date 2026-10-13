<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import UiIcon from '../../ui/UiIcon.vue'
import DiffCommentBox, {
  listSavedComments,
  type DiffCommentSavePayload,
  type SavedComment,
} from './DiffCommentBox.vue'
import type { ParsedDiffLine } from './parseUnifiedDiff'
import { highlightLinesForFile } from '@/helpers/codeHighlight'
import { pairSplitRows, splitRowIndexBySourceIndex, type SplitRow } from './pairSplitRows'
import { fetchWholeFileDiff, type WholeFileDiff } from './wholeFileDiff'
import SplitDiffTable from './SplitDiffTable.vue'
import DiffThreads from './DiffThreads.vue'

/**
 * Shared full diff view: file header (collapse toggle, back/filename/stats,
 * scope + mode, Open), loading/error/empty states, the unified OR split
 * render of the hunks, and the review mini-chat popup. Presentational — data
 * flows in via props, user actions flow out via emits. Used full-height in
 * ChatView's centre column; the sidebar panel is list-only.
 */
const props = defineProps<{
  path: string
  lines: ParsedDiffLine[]
  added: number
  removed: number
  staged?: boolean
  loading?: boolean
  error?: string | null
  /** cwd for the review DiffCommentBox and the whole-file fetch. */
  cwd: string
  /** Show the back button (center mode). Panel list mode hides it. */
  showBack?: boolean
  backLabel?: string
  /** 'unified' (default, today's render) or 'split' (side-by-side). */
  mode?: 'unified' | 'split'
  /** Collapsed = header only. The parsed diff stays in the parent's memory,
   * so expanding is a render, never a refetch. */
  collapsed?: boolean
  /** Whole-file scope: every line of the file, changes still marked. */
  wholeFile?: boolean
  /** An untracked file's diff already IS the whole file, so the scope
   * control renders locked at "Whole file" and never fetches. */
  untracked?: boolean
}>()

const emit = defineEmits<{
  back: []
  open: [payload: { path: string; line?: number }]
  retry: []
  'toggle-collapse': []
  'toggle-whole-file': []
  'submit-review': [message: string]
  'comment-saved': [payload: DiffCommentSavePayload]
}>()

const mode = computed<'unified' | 'split'>(() => props.mode ?? 'unified')
const collapsed = computed(() => props.collapsed === true)

// ── whole-file scope ──────────────────────────────────────────────────────
// Fetched here (not in the parent) because this component already owns the
// path + cwd + staged triple the request needs. The cache is module-level, so
// collapsing and re-expanding a section — which unmounts this component — is
// still a cache read, not a second request.
const wholeFileResult = ref<WholeFileDiff | null>(null)
const wholeFileLoading = ref(false)
const wholeFileError = ref<string | null>(null)

const wholeFileRefused = computed(() => wholeFileResult.value?.refused === true)

/** The lines actually rendered: the whole file when we have it, otherwise the
 * hunks we were handed. A refusal falls back to the hunks rather than to
 * nothing — the user still gets their diff, plus a notice. */
const displayLines = computed<ParsedDiffLine[]>(() => {
  if (!props.wholeFile) return props.lines
  const result = wholeFileResult.value
  if (!result || result.refused) return props.lines
  return result.lines
})

async function loadWholeFile(): Promise<void> {
  if (!props.wholeFile || props.untracked || !props.cwd || !props.path) return
  const requested = `${props.staged ? 1 : 0}:${props.path}`
  wholeFileLoading.value = true
  wholeFileError.value = null
  try {
    const result = await fetchWholeFileDiff(props.cwd, props.path, props.staged === true)
    // Stale guard: the user may have switched files (or scope) while this
    // was in flight. Dropping the late answer beats showing file A's body
    // under file B's header.
    if (`${props.staged ? 1 : 0}:${props.path}` !== requested) return
    wholeFileResult.value = result
  } catch (err) {
    if (`${props.staged ? 1 : 0}:${props.path}` !== requested) return
    wholeFileError.value = err instanceof Error ? err.message : 'Failed to load the whole file'
  } finally {
    wholeFileLoading.value = false
  }
}

// Whole-file scope sync: mount covers a section mounting with the scope
// already on (the state lives in ChatView, so remounting after a collapse
// restores it); the prev-combo guard on update covers scope/path/cwd
// switches. A path switch also resets the review progress below.
const prevDiffKey = ref('')
const diffKey = () =>
  `${props.wholeFile ? '1' : '0'}|${props.untracked ? '1' : '0'}|${props.path}|${props.staged ? '1' : '0'}|${props.cwd}`
const syncDiffScope = () => {
  if (props.wholeFile) void loadWholeFile()
  else {
    wholeFileResult.value = null
    wholeFileError.value = null
  }
}
onMounted(() => {
  prevDiffKey.value = diffKey()
  syncDiffScope()
})
onUpdated(() => {
  const key = diffKey()
  if (key !== prevDiffKey.value) {
    prevDiffKey.value = key
    syncDiffScope()
  }
})

// ── token colors ──────────────────────────────────────────────────────────
// One entry per rendered row, computed once per diff instead of once per
// render — the row red/green background still carries added/removed, the
// token spans only color the code inside the row.
const unifiedTokens = computed(() =>
  highlightLinesForFile(
    displayLines.value.map((line) => line.content),
    props.path,
  ),
)

// ── split render ──────────────────────────────────────────────────────────
const splitRows = computed<SplitRow[]>(() => pairSplitRows(displayLines.value))
/** source line index → split row index, so a review thread left in unified
 * mode keeps its position when the user flips to split. */
const splitRowBySource = computed(() => splitRowIndexBySourceIndex(splitRows.value))

// Mini chat popup state (moved verbatim from SidebarDiffPanel).
const showMiniChat = ref(false)
const miniChatPosition = ref({ x: 0, y: 0 })
const miniChatContent = ref('')
const miniChatFilePath = ref('')
const miniChatStartLine = ref(0)
const miniChatEndLine = ref(0)

const miniChatStyle = computed(() => {
  const vw = typeof globalThis.window !== 'undefined' ? globalThis.window.innerWidth : 1280
  const vh = typeof globalThis.window !== 'undefined' ? globalThis.window.innerHeight : 800
  return {
    left: Math.min(miniChatPosition.value.x, vw - 420) + 'px',
    top: Math.min(miniChatPosition.value.y, vh - 300) + 'px',
    width: '400px',
    backgroundColor: 'var(--semantic-card-bg)',
    border: '1px solid var(--color-border)',
  }
})

const openBoxAtRange = (start: number, end: number, context: string) => {
  miniChatFilePath.value = props.path
  miniChatStartLine.value = start
  miniChatEndLine.value = end
  miniChatContent.value = context
  showMiniChat.value = true
}

/**
 * Open the review box for the line at `lineIdx` in the rendered lines.
 *
 * Both renders funnel through here: unified passes the clicked row's index,
 * split passes the clicked side's SOURCE index — which is the same index
 * space when whole-file scope replaced the line list, because the split rows
 * are paired from those very lines.
 */
const openMiniChatAt = (event: MouseEvent, lineIdx: number) => {
  const lines = displayLines.value
  const line = lines[lineIdx]
  if (!line) return
  if (line.type !== 'add' && line.type !== 'remove') return
  event.preventDefault()
  event.stopPropagation()
  miniChatPosition.value = { x: event.clientX, y: event.clientY }
  const startIdx = Math.max(0, lineIdx - 3)
  const endIdx = Math.min(lines.length, lineIdx + 4)
  const contextLines = lines.slice(startIdx, endIdx)
  if (contextLines.length === 0) return
  const start = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  const last = contextLines[contextLines.length - 1]!
  const end = last.newLineNum || last.oldLineNum || 0
  const content = contextLines
    .map((l) => {
      const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
      const lineNum = l.newLineNum || l.oldLineNum || ''
      return `${lineNum} ${prefix}${l.content}`
    })
    .join('\n')
  openBoxAtRange(start, end, content)
}

const openMiniChat = (event: MouseEvent, line: ParsedDiffLine) => {
  openMiniChatAt(event, displayLines.value.indexOf(line))
}

const onSplitComment = (payload: { event: MouseEvent; sourceIndex: number }) => {
  openMiniChatAt(payload.event, payload.sourceIndex)
}

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const reviewedVersion = ref(0)
// A new file resets the review progress (prev-path guard on update).
const prevDiffPath = ref(props.path)
onUpdated(() => {
  if (props.path !== prevDiffPath.value) {
    prevDiffPath.value = props.path
    reviewedVersion.value = 0
  }
})
const savedThreads = computed(() => {
  void reviewedVersion.value
  return listSavedComments(props.cwd, props.path)
})

/** Last source-line index a thread covers — the same anchor the unified
 * render uses, computed once so both renders agree on where a thread hangs. */
const threadAnchors = computed(() => {
  const anchors: { thread: SavedComment; anchor: number }[] = []
  for (const thread of savedThreads.value) {
    let anchor = -1
    displayLines.value.forEach((line, idx) => {
      let n: number | undefined
      if (line.type === 'add') n = line.newLineNum
      else if (line.type === 'remove') n = line.oldLineNum
      else if (line.type === 'context') n = line.newLineNum || line.oldLineNum
      else return
      if (n != null && n >= thread.start && n <= thread.end) anchor = idx
    })
    if (anchor >= 0) anchors.push({ thread, anchor })
  }
  return anchors
})

const threadsAfterRow = computed(() => {
  const map = new Map<number, SavedComment[]>()
  for (const { thread, anchor } of threadAnchors.value) {
    const list = map.get(anchor)
    if (list) list.push(thread)
    else map.set(anchor, [thread])
  }
  return map
})

function threadsAfter(idx: number): SavedComment[] {
  return threadsAfterRow.value.get(idx) ?? []
}

/** Same threads, addressed by SPLIT row instead of source line. */
function threadsAfterSplitRow(rowIndex: number): SavedComment[] {
  const out: SavedComment[] = []
  for (const { thread, anchor } of threadAnchors.value) {
    if (splitRowBySource.value.get(anchor) === rowIndex) out.push(thread)
  }
  return out
}

const handleCommentSave = (payload: DiffCommentSavePayload) => {
  closeMiniChat()
  reviewedVersion.value++
  emit('comment-saved', payload)
}
const firstAddLine = computed(() => props.lines.find((l) => l.type === 'add')?.newLineNum)

const openFile = () => emit('open', { path: props.path, line: firstAddLine.value })
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="sidebar-diff-view">
    <div
      class="flex items-center gap-2 px-3 py-2 shrink-0"
      style="background: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <button
        v-if="showBack"
        type="button"
        class="shrink-0 px-2 h-7 rounded flex items-center gap-1 text-dense hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Back to chat"
        aria-label="Back to chat"
        data-testid="sidebar-diff-back"
        @click="emit('back')"
      >
        ‹ {{ backLabel ?? 'Back' }}
      </button>
      <button
        type="button"
        class="shrink-0 w-5 h-7 rounded text-dense hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        :title="collapsed ? 'Expand this file' : 'Collapse this file'"
        :aria-label="collapsed ? 'Expand this file' : 'Collapse this file'"
        :aria-expanded="!collapsed"
        data-testid="sidebar-diff-toggle-collapse"
        @click="emit('toggle-collapse')"
      >
        {{ collapsed ? '▸' : '▾' }}
      </button>
      <span
        class="text-dense font-medium truncate flex-1"
        style="color: var(--semantic-text)"
        :title="path"
        data-testid="sidebar-diff-selected"
      >
        {{ path }}
      </span>
      <span
        v-if="staged"
        class="text-dense px-1.5 py-0.5 rounded"
        style="background: rgba(135, 169, 135, 0.15); color: var(--color-green)"
      >
        Staged
      </span>
      <span class="text-dense font-mono" style="color: var(--color-green)"> +{{ added }} </span>
      <span class="text-dense font-mono" style="color: var(--color-red)"> -{{ removed }} </span>
      <!-- Scope axis: which lines. Layout (unified|split) is the toolbar's. -->
      <span
        class="shrink-0 inline-flex rounded overflow-hidden"
        style="border: 1px solid var(--color-border)"
        data-testid="sidebar-diff-scope"
      >
        <button
          type="button"
          class="px-1.5 text-dense"
          :style="
            untracked
              ? { color: 'var(--semantic-text-dim)', opacity: '0.45', cursor: 'default' }
              : wholeFile
                ? { color: 'var(--semantic-text-dim)' }
                : { background: 'var(--color-violet)', color: 'var(--color-bg-m2)' }
          "
          :disabled="untracked"
          title="Show just the hunks"
          data-testid="sidebar-diff-scope-diff"
          @click="!untracked && wholeFile && emit('toggle-whole-file')"
        >
          Diff
        </button>
        <button
          type="button"
          class="px-1.5 text-dense"
          :style="
            untracked || wholeFile
              ? { background: 'var(--color-violet)', color: 'var(--color-bg-m2)' }
              : { color: 'var(--semantic-text-dim)' }
          "
          :title="
            untracked ? 'A new file — the diff already is the whole file' : 'Show the whole file'
          "
          data-testid="sidebar-diff-scope-whole"
          @click="!untracked && !wholeFile && emit('toggle-whole-file')"
        >
          Whole file
        </button>
      </span>
      <button
        type="button"
        class="px-2 py-1 text-dense rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Open file in code browser"
        aria-label="Open file in code browser"
        data-testid="sidebar-diff-open-file"
        @click="openFile"
      >
        ⤴
      </button>
    </div>

    <div v-if="loading || wholeFileLoading" class="flex items-center justify-center py-6">
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

    <div v-else-if="error" class="flex flex-col items-center justify-center p-4">
      <span class="text-title-lg mb-2">⚠️</span>
      <p class="text-dense" style="color: var(--semantic-error)">{{ error }}</p>
      <button
        type="button"
        class="mt-3 px-3 py-1.5 text-body rounded"
        style="background: var(--color-green); color: var(--color-bg)"
        data-testid="sidebar-diff-retry"
        @click="emit('retry')"
      >
        Retry
      </button>
    </div>

    <div
      v-else-if="lines.length === 0 && !wholeFile"
      class="flex flex-col items-center justify-center p-4"
    >
      <UiIcon name="file" size-class="w-6 h-6" class="mb-2" />
      <p class="text-dense" style="color: var(--semantic-text-dim)">No changes detected</p>
    </div>

    <template v-else-if="!collapsed">
      <!-- Split: five columns, pairing done by pairSplitRows. -->
      <SplitDiffTable
        v-if="mode === 'split'"
        class="flex-1 min-h-0 overflow-auto diff-wrap"
        :rows="splitRows"
        :path="path"
        @comment="onSplitComment"
      >
        <template #threads="{ rowIndex }">
          <tr v-if="threadsAfterSplitRow(rowIndex).length > 0" data-testid="diff-comment-thread">
            <td colspan="5" class="px-2 py-1">
              <DiffThreads
                :threads="threadsAfterSplitRow(rowIndex)"
                :path="path"
                :cwd="cwd"
                @save="handleCommentSave"
                @changed="reviewedVersion++"
              />
            </td>
          </tr>
        </template>
      </SplitDiffTable>

      <!-- Unified: today's three-column hunk table. -->
      <div
        v-else
        class="flex-1 min-h-0 overflow-auto diff-wrap"
        :style="{
          fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
        }"
      >
        <table
          class="w-full border-collapse"
          style="font-size: var(--text-dense); line-height: 20px"
        >
          <tbody>
            <template v-for="(line, idx) in displayLines" :key="idx">
              <tr v-if="line.type === 'hunk'">
                <td
                  colspan="3"
                  class="px-3 py-1"
                  style="background: rgba(139, 164, 176, 0.1); color: var(--color-blue)"
                >
                  {{ line.content }}
                </td>
              </tr>
              <tr
                v-else-if="line.type === 'add'"
                style="cursor: pointer"
                @click="openMiniChat($event, line)"
              >
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                >
                  {{ line.newLineNum || '' }}
                </td>
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                ></td>
                <td
                  class="px-2"
                  style="
                    border-left: 3px solid var(--color-green);
                    background: rgba(135, 169, 135, 0.15);
                    color: var(--semantic-text);
                  "
                >
                  <span style="color: var(--color-green); font-weight: bold">+</span>
                  <span
                    v-for="(tok, tIdx) in unifiedTokens[idx]"
                    :key="tIdx"
                    :class="`tok-${tok.type}`"
                    >{{ tok.text || '\u00a0' }}</span
                  >
                </td>
              </tr>
              <tr
                v-else-if="line.type === 'remove'"
                style="cursor: pointer"
                @click="openMiniChat($event, line)"
              >
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                >
                  {{ line.oldLineNum || '' }}
                </td>
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                ></td>
                <td
                  class="px-2"
                  style="
                    border-left: 3px solid var(--color-red);
                    background: rgba(169, 135, 135, 0.15);
                    color: var(--semantic-text);
                  "
                >
                  <span style="color: var(--color-red); font-weight: bold">−</span>
                  <span
                    v-for="(tok, tIdx) in unifiedTokens[idx]"
                    :key="tIdx"
                    :class="`tok-${tok.type}`"
                    >{{ tok.text || '\u00a0' }}</span
                  >
                </td>
              </tr>
              <tr v-else-if="line.type === 'context'">
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                >
                  {{ line.oldLineNum || '' }}
                </td>
                <td
                  class="w-10 px-2 text-right select-none"
                  style="color: var(--semantic-text-dim); user-select: none"
                >
                  {{ line.newLineNum || '' }}
                </td>
                <td class="px-2" style="color: var(--semantic-text)">
                  <span style="color: var(--semantic-text-dim)">&nbsp;</span>
                  <span
                    v-for="(tok, tIdx) in unifiedTokens[idx]"
                    :key="tIdx"
                    :class="`tok-${tok.type}`"
                    >{{ tok.text || '\u00a0' }}</span
                  >
                </td>
              </tr>
              <tr v-if="threadsAfter(idx).length > 0" data-testid="diff-comment-thread">
                <td colspan="3" class="px-2 py-1">
                  <DiffThreads
                    :threads="threadsAfter(idx)"
                    :path="path"
                    :cwd="cwd"
                    @save="handleCommentSave"
                    @changed="reviewedVersion++"
                  />
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>

      <!-- Whole-file refused (too big to serve in full) or failed to load. -->
      <div
        v-if="wholeFile && (wholeFileRefused || wholeFileError)"
        class="shrink-0 flex items-center gap-2 px-3 py-2 text-dense"
        style="
          background: var(--color-bg-m2);
          border-top: 1px dashed var(--color-border-light);
          color: var(--color-yellow);
        "
        data-testid="sidebar-diff-whole-file-notice"
      >
        <span class="flex-1">
          {{
            wholeFileError
              ? `Could not load the whole file — ${wholeFileError}`
              : 'Whole-file view unavailable — this file is too large. The hunks below are still the change.'
          }}
        </span>
        <button
          v-if="wholeFileError"
          type="button"
          class="px-2 py-0.5 rounded"
          style="border: 1px solid var(--color-border); color: var(--semantic-text)"
          data-testid="sidebar-diff-whole-file-retry"
          @click="loadWholeFile()"
        >
          Retry
        </button>
        <button
          type="button"
          class="px-2 py-0.5 rounded"
          style="border: 1px solid var(--color-border); color: var(--semantic-text)"
          data-testid="sidebar-diff-whole-file-open"
          @click="openFile"
        >
          Open in code viewer
        </button>
      </div>
    </template>

    <Teleport to="body">
      <div
        v-if="showMiniChat"
        class="mini-chat-popup fixed z-50 rounded-lg shadow-lg p-3"
        :style="miniChatStyle"
      >
        <div
          class="text-dense mb-2 flex items-center gap-2"
          style="color: var(--semantic-text-dim)"
        >
          <span class="flex-1"
            >Review {{ miniChatFilePath }} ({{ miniChatStartLine }}–{{ miniChatEndLine }})</span
          >
          <button
            type="button"
            class="hover:opacity-70"
            title="Close review"
            @click="closeMiniChat"
          >
            ✕
          </button>
        </div>
        <DiffCommentBox
          :file-path="miniChatFilePath"
          :start-line="miniChatStartLine"
          :end-line="miniChatEndLine"
          :context="miniChatContent"
          :cwd="cwd"
          @save="handleCommentSave"
        />
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
/* Long diff lines are the common case (minified blobs, wide tables), so
   soft-wrap is always on rather than an opt-in header toggle. */
.diff-wrap td:last-child {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
