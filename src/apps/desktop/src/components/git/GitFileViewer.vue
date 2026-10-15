<script setup lang="ts">
import { computed, ref, onMounted, onUpdated } from 'vue'
import UiIcon from '../ui/UiIcon.vue'
import type { GitFileDiff } from '../../api'
import { fetchFolderDiff } from '../../helpers/folderDiffCache'
import { highlightLinesForFile } from '../../helpers/codeHighlight'
import DiffCommentBox, {
  type DiffCommentSavePayload,
} from '../views/chat_right_sidebar/DiffCommentBox.vue'
import {
  parseUnifiedDiff,
  type ParsedDiffLine as DiffLine,
} from '../views/chat_right_sidebar/parseUnifiedDiff'

interface Props {
  cwd: string
  filePath: string
  fileName: string
  staged?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  staged: false,
})

const emit = defineEmits<{
  close: []
  submitReview: [message: string]
  commentSaved: [payload: DiffCommentSavePayload]
}>()

// State
const isLoading = ref(false)
const error = ref<string | null>(null)
const diff = ref<GitFileDiff | null>(null)

// Mini chat popup state
const showMiniChat = ref(false)
const miniChatPosition = ref({ x: 0, y: 0 })
const miniChatContent = ref('')
const miniChatFilePath = ref('')
const miniChatFileName = ref('')
const miniChatStartLine = ref(0)
const miniChatEndLine = ref(0)

// Stats
const stats = ref({ added: 0, removed: 0 })

// DiffLine is the shared ParsedDiffLine (see parseUnifiedDiff module).
const diffLines = ref<DiffLine[]>([])

// Token spans per diff row, computed once per diff (not per render). The
// row keeps its red/green background; only the code inside is colored.
const diffTokens = computed(() =>
  highlightLinesForFile(
    diffLines.value.map((line) => line.content),
    props.filePath,
  ),
)

// Mini chat functions
const openMiniChat = (event: MouseEvent, line: DiffLine) => {
  console.log('[GitFileViewer] openMiniChat called', line.type, line.content.substring(0, 30))
  event.preventDefault()
  event.stopPropagation()

  // Get click position
  miniChatPosition.value = {
    x: event.clientX,
    y: event.clientY,
  }

  // Build diff context (include nearby lines for context)
  const lineIdx = diffLines.value.indexOf(line)
  const startIdx = Math.max(0, lineIdx - 3)
  const endIdx = Math.min(diffLines.value.length, lineIdx + 4)

  const contextLines = diffLines.value.slice(startIdx, endIdx)

  // Guard: ensure contextLines is not empty
  if (contextLines.length === 0) return

  // Store file path and line numbers for review header
  miniChatFilePath.value = props.filePath
  miniChatFileName.value = props.fileName
  miniChatStartLine.value = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  miniChatEndLine.value =
    contextLines[contextLines.length - 1]!.newLineNum ||
    contextLines[contextLines.length - 1]!.oldLineNum ||
    0

  // Build content with line numbers
  miniChatContent.value = contextLines
    .map((l) => {
      const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
      const lineNum = l.newLineNum || l.oldLineNum || ''
      return `${lineNum} ${prefix}${l.content}`
    })
    .join('\n')

  console.log('[GitFileViewer] showMiniChat set to true')
  showMiniChat.value = true
}

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatFileName.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const handleCommentSave = (payload: DiffCommentSavePayload) => {
  // The comment box owns persistence (localStorage draft + Saved
  // feedback). Keep the popup open showing the saved state and bubble
  // the structured payload upward. Nothing here sends to the LLM.
  emit('commentSaved', payload)
}
// Diff parsing delegates to the shared pure module (also used by the
// ChatView-embedded sidebar) — behaviour unchanged.
const applyParsedDiff = (diffText: string) => {
  const parsed = parseUnifiedDiff(diffText)
  diffLines.value = parsed.lines
  stats.value = { added: parsed.added, removed: parsed.removed }
}

// Diff parsing delegates to the shared pure module; token coloring comes
// from the shared highlighter, so this viewer matches the diff review.
// Load diff data
const loadDiff = async () => {
  if (!props.cwd || !props.filePath) return

  isLoading.value = true
  error.value = null

  try {
    // Folder mode, via the shared snapshot: the diff panel primes this cache for the whole repo, so
    // opening a file it already listed costs ZERO requests. On a miss this is ONE folder request
    // (deduped across every reader for this cwd), not a per-file one.
    diff.value = await fetchFolderDiff(props.cwd, props.filePath, props.staged)

    // Parse the unified diff
    applyParsedDiff(diff.value.diff_content)
  } catch (err) {
    console.error('[GitFileViewer] Failed to load diff:', err)
    error.value = 'Failed to load file diff'
  } finally {
    isLoading.value = false
  }
}

// Reload on binding change (prev-value guard on update — same load the
// watcher did; mount is covered below).
let prevDiffCwd = props.cwd
let prevDiffFilePath = props.filePath
let prevDiffStaged = props.staged
onUpdated(() => {
  if (
    props.cwd === prevDiffCwd &&
    props.filePath === prevDiffFilePath &&
    props.staged === prevDiffStaged
  )
    return
  prevDiffCwd = props.cwd
  prevDiffFilePath = props.filePath
  prevDiffStaged = props.staged
  loadDiff()
})

onMounted(() => {
  loadDiff()
})
</script>

<template>
  <div class="git-file-viewer flex flex-col h-full" style="background: var(--semantic-card-bg)">
    <!-- Header -->
    <div
      class="flex items-center h-10 px-4 shrink-0 gap-3"
      style="background: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <!-- File icon and name -->
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <UiIcon name="file" size-class="w-3.5 h-3.5" />
        <span
          class="text-body font-medium truncate"
          style="color: var(--semantic-text)"
          :title="filePath"
        >
          {{ fileName }}
        </span>
        <span
          v-if="staged"
          class="text-dense px-1.5 py-0.5 rounded"
          style="background: rgba(135, 169, 135, 0.15); color: var(--color-green)"
        >
          Staged
        </span>
      </div>

      <!-- Stats -->
      <div class="flex items-center gap-3 text-dense font-mono">
        <span style="color: var(--color-green)">+{{ stats.added }}</span>
        <span style="color: var(--color-red)">-{{ stats.removed }}</span>
      </div>

      <!-- Close button -->
      <button
        @click="emit('close')"
        class="p-1.5 rounded hover:opacity-70 transition-opacity"
        title="Close"
      >
        <svg
          class="w-4 h-4"
          style="color: var(--semantic-text-dim)"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      </button>
    </div>

    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg
        class="animate-spin w-6 h-6"
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
    <div v-else-if="error" class="flex-1 flex flex-col items-center justify-center p-4">
      <span class="text-display mb-3">⚠️</span>
      <p class="text-body" style="color: var(--semantic-error)">{{ error }}</p>
      <button
        @click="loadDiff"
        class="mt-3 px-3 py-1.5 text-body rounded"
        style="background: var(--color-green); color: var(--color-bg)"
      >
        Retry
      </button>
    </div>

    <!-- No diff content -->
    <div
      v-else-if="diffLines.length === 0"
      class="flex-1 flex flex-col items-center justify-center p-4"
    >
      <UiIcon name="file" size-class="w-6 h-6" class="mb-3" />
      <p class="text-body" style="color: var(--semantic-text-dim)">No changes detected</p>
      <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
        File may be identical to the committed version
      </p>
    </div>

    <!-- GitHub-style Diff View -->
    <div
      v-else
      class="flex-1 overflow-auto diff-wrap"
      :style="{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace' }"
    >
      <table class="w-full border-collapse" style="font-size: var(--text-dense); line-height: 20px">
        <tbody>
          <template v-for="(line, idx) in diffLines" :key="idx">
            <!-- Hunk header -->
            <tr v-if="line.type === 'hunk'" class="hunk-header">
              <td
                colspan="3"
                class="px-3 py-1"
                style="background: rgba(139, 164, 176, 0.1); color: var(--color-blue)"
              >
                {{ line.content }}
              </td>
            </tr>

            <!-- Empty line placeholder -->
            <tr
              v-else-if="line.type === 'empty'"
              style="background: var(--semantic-card-bg); height: 20px"
            >
              <td class="w-12"></td>
              <td class="w-12"></td>
              <td style="border-left: 3px solid transparent"></td>
            </tr>

            <!-- Added line -->
            <tr
              v-else-if="line.type === 'add'"
              class="diff-line diff-line-add"
              @click="openMiniChat($event, line)"
              style="cursor: pointer"
            >
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td
                class="w-12 px-2 text-right select-none"
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
                  v-for="(tok, tIdx) in diffTokens[idx]"
                  :key="tIdx"
                  :class="`tok-${tok.type}`"
                  >{{ tok.text || '\u00a0' }}</span
                >
              </td>
            </tr>

            <!-- Removed line -->
            <tr
              v-else-if="line.type === 'remove'"
              class="diff-line diff-line-remove"
              @click="openMiniChat($event, line)"
              style="cursor: pointer"
            >
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              ></td>
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="px-2"
                style="
                  border-left: 3px solid var(--color-red);
                  background: rgba(196, 116, 110, 0.15);
                  color: var(--semantic-text);
                "
              >
                <span style="color: var(--color-red); font-weight: bold">-</span>
                <span
                  v-for="(tok, tIdx) in diffTokens[idx]"
                  :key="tIdx"
                  :class="`tok-${tok.type}`"
                  >{{ tok.text || '\u00a0' }}</span
                >
              </td>
            </tr>

            <!-- Context line -->
            <tr v-else-if="line.type === 'context'" class="diff-line diff-line-context">
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td
                class="px-2"
                style="border-left: 3px solid transparent; color: var(--semantic-text)"
              >
                <span style="color: var(--semantic-text-dim)"> </span>
                <span
                  v-for="(tok, tIdx) in diffTokens[idx]"
                  :key="tIdx"
                  :class="`tok-${tok.type}`"
                  >{{ tok.text || '\u00a0' }}</span
                >
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>

    <!-- Mini Chat Popup (floating near clicked line) -->
    <Teleport to="body">
      <div
        v-if="showMiniChat"
        class="mini-chat-popup"
        :style="{
          left: miniChatPosition.x + 'px',
          top: miniChatPosition.y + 'px',
        }"
      >
        <div class="mini-chat-header">
          <UiIcon name="chat" style="color: var(--color-green)" />
          <span class="text-body font-medium" style="color: var(--semantic-text)"
            >Review this code</span
          >
          <button @click="closeMiniChat" class="ml-auto p-1 rounded hover:opacity-70">
            <svg
              class="w-4 h-4"
              style="color: var(--semantic-text-dim)"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>
        <div class="mini-chat-code">
          <pre>{{ miniChatContent }}</pre>
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

<style>
/* Mini Chat Popup - NOT scoped because it uses Teleport */
.mini-chat-popup {
  position: fixed;
  z-index: 9999;
  width: 400px;
  max-width: 90vw;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  border-radius: 12px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  overflow: hidden;
  transform: translate(-50%, 10px);
}

.mini-chat-popup .mini-chat-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  background: var(--color-bg-m2);
  border-bottom: 1px solid var(--color-border);
}

.mini-chat-popup .mini-chat-code {
  max-height: 150px;
  overflow-y: auto;
  padding: 10px 12px;
  background: var(--semantic-sidebar-bg);
  border-bottom: 1px solid var(--color-border);
}

.mini-chat-popup .mini-chat-code pre {
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: var(--text-meta);
  line-height: 1.5;
  color: var(--semantic-text);
  white-space: pre-wrap;
  word-break: break-all;
}
</style>

<style scoped>
.git-file-viewer {
  height: 100%;
}

/* Word wrap is always on: long diff lines would otherwise push a
   horizontal scrollbar across the whole viewer. */
.diff-wrap table {
  white-space: pre-wrap;
  word-break: break-all;
}

.diff-wrap .diff-line td:last-child {
  word-break: break-all;
}

/* Scrollbar styling */
.overflow-auto::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

.overflow-auto::-webkit-scrollbar-track {
  background: var(--color-bg-m2);
}

.overflow-auto::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 5px;
}

.overflow-auto::-webkit-scrollbar-thumb:hover {
  background: var(--color-gray-3);
}

.overflow-auto::-webkit-scrollbar-corner {
  background: var(--semantic-card-bg);
}

/* Line hover effect */
.diff-line:hover {
  filter: brightness(1.1);
}

/* Hunk header */
.hunk-header td {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
</style>
