<script setup lang="ts">
import { computed, nextTick, onMounted, onUpdated, ref } from 'vue'
import { detectLanguage, highlightLine, highlightLines, type Token } from '@/helpers/codeHighlight'
import { displayPathFor } from '@/composables/useCodeEditorSession'
import { getGitBlame, getGitWholeFileDiff } from '@/api'
import { formatRelativeTime } from '@/helpers/relativeTime'
import { parseUnifiedDiff } from './chat_right_sidebar/parseUnifiedDiff'
import { buildLineGutter, type GutterKind } from '@/helpers/lineGutter'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

/**
 * Read-only code viewer for `?view=code-editor`.
 *
 * Rendering follows the git-diff-review pattern (`SidebarDiffView.vue` /
 * `GitFileViewer.vue` / `tool_outputs/_shared/DiffView.vue`): one table row
 * per line, a sticky line-number gutter, soft-wrap always on, and the
 * repo's zero-dependency tokenizer (`helpers/codeHighlight`) painting
 * `tok-*` spans with the same palette as the diff cards.
 *
 * Why not Monaco (bug: task_1790594549955_1 — "when i click code editor
 * there is no code"): the previous version lazy-loaded monaco through a
 * dynamic import marked with the `@vite-ignore` comment. That marker
 * makes Vite keep the BARE specifier in the emitted bundle
 * (``import(`monaco-editor`)``), which no browser can resolve, so
 * `onMounted` rejected with `Failed to resolve module specifier
 * "monaco-editor"` and the body rendered empty while the header still
 * painted. The jsdom specs could not see it (vitest aliases
 * `monaco-editor` to a stub and ignores unhandled errors) and the Vite
 * dev server resolves bare specifiers itself — only the built bundle
 * failed. Rendering with the shared tokenizer removes the runtime module
 * resolution entirely, so there is nothing left to resolve at runtime,
 * and the viewer matches the diff review the user already reads.
 *
 * Git annotations (gutter change bars, Code/Diff toggle, change navigator,
 * blame chips) ride on two optional props. When a prop is absent and a cwd
 * is bound, the viewer self-fetches it: the whole-file diff via
 * `getGitWholeFileDiff` (same cached reader the diff review uses) and
 * blame via `GET /api/git/blame`. Both are best-effort — a failure leaves
 * the plain code view, never an error state.
 *
 * The component is presentational: `AppLayout` owns the open-file session
 * (file / content / loading / error) and passes the text down.
 */

/** One inline blame annotation: author + pre-formatted age. */
export interface LineBlame {
  line: number
  author: string
  age: string
}

const props = defineProps<{
  filePath: string
  fileName: string
  /** Whole-file text, already fetched by the session composable. */
  content?: string
  /** Explicit language override; defaults to the file extension. */
  language?: string
  cwd?: string
  /**
   * Optional 1-based line to jump to once the viewer mounts (threaded
   * from the diff review's "open at this line" / `?line=` deep link).
   * The target row is marked and scrolled to the middle of the viewport.
   */
  line?: number
  /**
   * Whole-file unified diff (`git diff -U<all>`). Drives the gutter bars,
   * the Diff view, and the change navigator. Self-fetched when absent.
   */
  diffText?: string
  /** Inline blame annotations. Self-fetched when absent. */
  blame?: LineBlame[]
}>()

const emit = defineEmits<{
  close: []
}>()

const bodyEl = ref<HTMLElement | null>(null)

const detectedLanguage = computed(() => props.language || detectLanguage(props.fileName))

const hasContent = computed(() => (props.content ?? '').length > 0)

// A file that ends in a newline would otherwise render a phantom last
// row (editors number real lines only).
const lines = computed<string[]>(() => {
  const raw = (props.content ?? '').split('\n')
  if (raw.length > 1 && raw[raw.length - 1] === '') raw.pop()
  return raw
})

const lineCount = computed(() => lines.value.length)

const targetLine = computed(() =>
  typeof props.line === 'number' && props.line > 0 ? props.line : null,
)

// Repo-relative path for the git endpoints: the explorer hands down an
// absolute filePath, the endpoints want it relative to the cwd.
const relativeFilePath = computed(() =>
  props.cwd && props.filePath.startsWith(props.cwd + '/')
    ? props.filePath.slice(props.cwd.length + 1)
    : props.filePath,
)

// Self-fetched annotations (used only when the matching prop is absent).
const fetchedDiff = ref<string | null>(null)
const fetchedBlame = ref<LineBlame[] | null>(null)

const effectiveDiffText = computed(() => props.diffText ?? fetchedDiff.value ?? undefined)
const effectiveBlame = computed(() => props.blame ?? fetchedBlame.value ?? undefined)

async function loadDiff(): Promise<void> {
  if (props.diffText !== undefined || !props.cwd) return
  try {
    const res = await getGitWholeFileDiff(props.cwd, relativeFilePath.value, false)
    if (res.whole_file_refused) {
      fetchedDiff.value = null
      return
    }
    fetchedDiff.value = res.diffs.find((d) => d.path === relativeFilePath.value)?.diff_content ?? null
  } catch (err) {
    console.error('Failed to load whole-file diff:', err)
    fetchedDiff.value = null
  }
}

async function loadBlame(): Promise<void> {
  if (props.blame !== undefined || !props.cwd) return
  // getGitBlame never throws — it resolves null on transport error.
  const res = await getGitBlame(props.cwd, relativeFilePath.value)
  if (!res || !res.is_git_repo) {
    fetchedBlame.value = null
    return
  }
  fetchedBlame.value = res.lines.map((entry) => ({
    line: entry.line,
    author: entry.author || 'Unknown',
    age: entry.author_time > 0 ? formatRelativeTime(String(entry.author_time * 1000)) : '',
  }))
}

function loadAnnotations(): void {
  void loadDiff()
  void loadBlame()
}

// Gutter marks + change blocks, keyed by new-file line number.
const parsedDiff = computed(() =>
  effectiveDiffText.value ? parseUnifiedDiff(effectiveDiffText.value) : null,
)
const gutter = computed(() => (parsedDiff.value ? buildLineGutter(parsedDiff.value.lines) : null))
const changeBlocks = computed(() => gutter.value?.blocks ?? [])

const gutterKindFor = (lineNumber: number): GutterKind | null =>
  gutter.value?.gutters.get(lineNumber) ?? null

const blameTextFor = (lineNumber: number): string | null => {
  const found = effectiveBlame.value?.find((b) => b.line === lineNumber)
  return found ? `${found.author}, ${found.age}` : null
}

// Code/Diff toggle + change navigator state.
const showDiff = ref(false)
const navIndex = ref(0)
const navTarget = ref<number | null>(null)
const navLabel = computed(() =>
  changeBlocks.value.length === 0 ? '0 / 0' : `${navIndex.value + 1} / ${changeBlocks.value.length}`,
)

const isTarget = (lineNumber: number) =>
  targetLine.value === lineNumber || navTarget.value === lineNumber

/** Split one line into colored token spans (plaintext ⇒ one plain span). */
const tokensFor = (line: string) => highlightLine(line, detectedLanguage.value)

// Token spans for the Diff view's rows — computed once per parsed diff
// rather than per render, and colored with the same palette as the code view.
const diffTokens = computed<Token[][]>(() => {
  const lines = parsedDiff.value?.lines ?? []
  const tokens = highlightLines(
    lines.map((line) => line.content),
    detectedLanguage.value,
  )
  // A hunk header is diff METADATA, not code. Tokenizing `@@ -12,7 +12,9 @@`
  // paints its numbers with `.tok-number` over the row's own hunk colour;
  // every other unified surface renders hunks plain, so this one does too.
  return lines.map((line, i) =>
    line.type === 'hunk' ? [{ text: line.content, type: 'plain' }] : tokens[i]!,
  )
})

const signFor = (type: string): string => {
  if (type === 'add') return '+'
  if (type === 'remove') return '-'
  if (type === 'context' || type === 'empty') return ' '
  return ''
}

const diffRowClass = (type: string): string => {
  if (type === 'add') return 'diff-row-add'
  if (type === 'remove') return 'diff-row-remove'
  if (type === 'hunk') return 'diff-row-hunk'
  return ''
}

/**
 * Bring a line into view. Best-effort: jsdom has no
 * `scrollIntoView`, and a `?line=` beyond EOF is simply ignored.
 */
async function scrollToLine(line: number | null): Promise<void> {
  if (line === null) return
  await nextTick()
  const row = bodyEl.value?.querySelector<HTMLElement>(`[data-line="${line}"]`)
  if (row && typeof row.scrollIntoView === 'function') {
    row.scrollIntoView({ block: 'center' })
  }
}

function scrollToTarget(): void {
  void scrollToLine(targetLine.value)
}

function goToBlock(direction: 1 | -1): void {
  if (changeBlocks.value.length === 0) return
  // The navigator addresses code rows — leave the Diff view first.
  showDiff.value = false
  navIndex.value =
    (navIndex.value + direction + changeBlocks.value.length) % changeBlocks.value.length
  const block = changeBlocks.value[navIndex.value]
  if (!block) return
  navTarget.value = block.startLine
  void scrollToLine(block.startLine)
}

// Annotation identity: file + cwd + content length + explicit props.
// A change resets fetched state and re-fetches (prev-value guard on
// update — same pattern the line/content scroll uses; mount covers the
// initial load).
const annoKey = () =>
  `${props.filePath}|${props.cwd ?? ''}|${props.content?.length ?? 0}|${props.diffText ?? ''}|${props.blame ? 'b' : ''}`

onMounted(() => {
  prevAnnoKey = annoKey()
  loadAnnotations()
  scrollToTarget()
})

// Re-scroll when the target line or the content changes (prev-value guard
// on update — same call the watcher made; mount is covered above).
let prevEditorLine = props.line
let prevEditorContent = props.content
let prevAnnoKey = ''
onUpdated(() => {
  const key = annoKey()
  if (key !== prevAnnoKey) {
    prevAnnoKey = key
    fetchedDiff.value = null
    fetchedBlame.value = null
    navIndex.value = 0
    navTarget.value = null
    showDiff.value = false
    loadAnnotations()
  }
  if (props.line === prevEditorLine && props.content === prevEditorContent) return
  prevEditorLine = props.line
  prevEditorContent = props.content
  scrollToTarget()
})

// Footer shows the full path. filePath from the sidebar explorer is
// already absolute (backend listDirectory joins dir_path + name), so
// prefixing cwd would double it:
// /home/u/work//home/u/work/migration/README.md. The shared
// displayPathFor helper joins only relative paths.
const displayPath = computed(() => displayPathFor(props.cwd, props.filePath))

// File icon for display
const getFileIcon = (fileName: string): UiIconName => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const iconMap: Record<string, UiIconName> = {
    js: 'scroll',
    jsx: 'atom',
    ts: 'book',
    tsx: 'atom',
    vue: 'code',
    html: 'globe',
    htm: 'globe',
    css: 'palette',
    scss: 'palette',
    less: 'palette',
    json: 'clipboard',
    md: 'note',
    markdown: 'note',
    xml: 'file',
    yaml: 'settings',
    yml: 'settings',
    py: 'code',
    zig: 'code',
    rs: 'code',
    go: 'circle',
    txt: 'file',
    gitignore: 'lock',
    env: 'key',
  }
  return iconMap[ext] ?? 'file'
}

const handleClose = () => {
  emit('close')
}
</script>

<template>
  <div
    class="code-editor flex flex-col h-full min-h-0 overflow-hidden"
    data-testid="code-editor"
    style="background-color: var(--semantic-content-bg)"
  >
    <!-- Header -->
    <div
      class="h-12 flex items-center justify-between px-4 shrink-0"
      style="background-color: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-3 min-w-0">
        <button
          type="button"
          @click="handleClose"
          class="p-2 rounded-lg hover:opacity-70 transition-opacity shrink-0"
          title="Close"
          aria-label="Close"
          data-testid="code-editor-close"
        >
          <svg
            class="w-4 h-4"
            style="color: var(--semantic-text)"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>
        <UiIcon :name="getFileIcon(fileName)" class="w-5 h-5" />
        <div class="flex items-center gap-2 min-w-0">
          <span
            class="text-body font-medium truncate"
            style="color: var(--semantic-text)"
            :title="filePath"
          >
            {{ fileName }}
          </span>
          <span
            class="text-dense px-2 py-0.5 rounded shrink-0"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim)"
            data-testid="code-editor-line-count"
          >
            {{ lineCount }} {{ lineCount === 1 ? 'line' : 'lines' }}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <!-- Change navigator -->
        <div
          v-if="changeBlocks.length > 0"
          data-testid="change-nav"
          class="flex items-center gap-1 text-dense"
          style="color: var(--semantic-text-dim)"
        >
          <button
            type="button"
            data-testid="change-prev"
            aria-label="Previous change"
            title="Previous change"
            class="px-1.5 py-0.5 rounded hover:opacity-70"
            style="border: 1px solid var(--color-border)"
            @click="goToBlock(-1)"
          >
            ↑
          </button>
          <button
            type="button"
            data-testid="change-next"
            aria-label="Next change"
            title="Next change"
            class="px-1.5 py-0.5 rounded hover:opacity-70"
            style="border: 1px solid var(--color-border)"
            @click="goToBlock(1)"
          >
            ↓
          </button>
          <span>{{ navLabel }}</span>
        </div>
        <!-- Code / Diff toggle -->
        <div
          v-if="effectiveDiffText"
          data-testid="code-diff-toggle"
          class="seg-toggle"
          role="tablist"
          @click="showDiff = !showDiff"
        >
          <span :class="{ on: !showDiff }">Code</span>
          <span :class="{ on: showDiff }">Diff</span>
        </div>
        <!-- Language indicator -->
        <span
          class="text-dense px-2 py-1 rounded"
          style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted)"
          data-testid="code-editor-language"
        >
          {{ detectedLanguage }}
        </span>
      </div>
    </div>

    <!-- Lines: sticky number gutter on the left, token-colored content
         on the right. Soft-wrap is always on (same decision as the diff
         views), so a long line never pushes a horizontal scrollbar. -->
    <div
      ref="bodyEl"
      class="flex-1 min-h-0 overflow-auto code-body"
      data-testid="code-editor-body"
      :style="{
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      }"
    >
      <div
        v-if="!hasContent"
        class="flex flex-col items-center justify-center h-full italic text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="code-editor-empty"
      >
        This file is empty
      </div>

      <!-- Unified diff view (changed hunks only) -->
      <div
        v-else-if="showDiff && parsedDiff"
        data-testid="code-diff-view"
        class="diff-view"
        style="font-size: var(--text-dense); line-height: 20px"
      >
        <div
          v-for="(dl, dlIdx) in parsedDiff.lines"
          :key="dlIdx"
          class="diff-row"
          :class="diffRowClass(dl.type)"
        >
          <span class="diff-old">{{ dl.oldLineNum ?? '' }}</span>
          <span class="diff-new">{{ dl.newLineNum ?? '' }}</span>
          <span class="diff-text"
            >{{ signFor(dl.type)
            }}<span
              v-for="(tok, tIdx) in diffTokens[dlIdx]"
              :key="tIdx"
              :class="`tok-${tok.type}`"
              >{{ tok.text || '\u00a0' }}</span
            ></span
          >
        </div>
      </div>

      <table
        v-else
        class="w-full border-collapse"
        style="font-size: var(--text-dense); line-height: 20px"
      >
        <tbody>
          <tr
            v-for="(line, idx) in lines"
            :key="idx"
            class="code-row"
            :class="{ 'code-row-target': isTarget(idx + 1) }"
            data-testid="code-line"
            :data-line="idx + 1"
            :data-target="isTarget(idx + 1) ? 'true' : 'false'"
          >
            <td
              class="code-gutter px-2 text-right select-none align-top"
              style="color: var(--semantic-text-dim); user-select: none"
              data-testid="code-line-number"
            >
              {{ idx + 1 }}
            </td>
            <td v-if="effectiveDiffText" class="code-diff-gutter-cell align-top">
              <span
                v-if="gutterKindFor(idx + 1)"
                data-testid="code-gutter"
                :data-kind="gutterKindFor(idx + 1)"
                :data-line="idx + 1"
                :class="`gutter-bar gutter-${gutterKindFor(idx + 1)}`"
              />
            </td>
            <td class="code-content px-2 align-top" style="color: var(--semantic-text)">
              <span
                v-for="(token, tokenIdx) in tokensFor(line)"
                :key="tokenIdx"
                :class="`tok-${token.type}`"
                >{{ token.text || '\u00a0' }}</span
              ><span
                v-if="blameTextFor(idx + 1)"
                data-testid="line-blame"
                class="blame-chip"
                >{{ blameTextFor(idx + 1) }}</span
              >
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Footer with file path -->
    <div
      v-if="cwd || filePath"
      class="h-6 flex items-center px-3 shrink-0 text-dense truncate"
      style="
        background-color: var(--color-bg-m2);
        border-top: 1px solid var(--color-border);
        color: var(--semantic-text-dim);
      "
      :title="displayPath"
    >
      {{ displayPath }}
    </div>
  </div>
</template>

<style scoped>
.code-editor {
  background-color: var(--semantic-content-bg);
}

/* Soft-wrap is always on: long lines are the common case (minified
   blobs, wide tables) and were the reason the diff views dropped their
   Wrap toggle. `break-word` keeps the gutter aligned with its row. */
.code-body table {
  white-space: pre-wrap;
  word-break: break-word;
}

.code-gutter {
  width: 3.5rem;
  position: sticky;
  left: 0;
  background-color: var(--semantic-content-bg);
  border-right: 1px solid var(--color-border);
  z-index: 1;
}

/* Change-bar column: a 3px bar per changed line (VS Code convention —
   green added, orange modified, red deleted tick). Unmarked rows keep an
   empty cell so the code column stays aligned. */
.code-diff-gutter-cell {
  width: 7px;
  min-width: 7px;
  padding: 0 2px 0 0;
}
.gutter-bar {
  display: inline-block;
  width: 3px;
  height: 1.2em;
  border-radius: 2px;
  vertical-align: middle;
}
.gutter-added {
  background-color: var(--color-green);
}
.gutter-modified {
  background-color: var(--color-orange);
}
.gutter-deleted {
  background-color: var(--color-red);
}

/* Inline blame chip (`author, age`) on annotated rows. */
.blame-chip {
  margin-left: 12px;
  font-size: 11px;
  color: var(--semantic-text-dim);
  white-space: nowrap;
}

/* Code / Diff segmented toggle. */
.seg-toggle {
  display: flex;
  border: 1px solid var(--color-border);
  border-radius: 6px;
  overflow: hidden;
  cursor: pointer;
  font-size: 11px;
}
.seg-toggle span {
  padding: 3px 10px;
  color: var(--semantic-text-dim);
}
.seg-toggle span.on {
  background-color: var(--semantic-active-bg);
  color: var(--semantic-text);
  font-weight: 600;
}

/* Unified diff rows. */
.diff-view {
  white-space: pre-wrap;
  word-break: break-word;
  /* The code view gets its colour from `td.code-content`; the Diff view has
     no such cell, so the row colour is set here — `.tok-plain` inherits it
     instead of falling back to the (black) initial value. */
  color: var(--semantic-text);
}
.diff-row {
  display: flex;
  gap: 8px;
  padding: 0 12px 0 0;
}
.diff-old,
.diff-new {
  width: 3rem;
  flex-shrink: 0;
  text-align: right;
  color: var(--semantic-text-dim);
  opacity: 0.55;
  user-select: none;
}
.diff-row-add {
  background-color: rgba(135, 169, 135, 0.1);
}
.diff-row-remove {
  background-color: rgba(196, 116, 110, 0.1);
}
.diff-row-hunk {
  color: var(--color-blue);
  background-color: rgba(139, 164, 176, 0.08);
}

.code-row:hover {
  background-color: rgba(255, 255, 255, 0.03);
}

/* The row reached from the diff review's "open at this line" / ?line=N. */
.code-row-target {
  background-color: rgba(139, 164, 176, 0.14);
}

.code-row-target .code-gutter {
  background-color: rgba(139, 164, 176, 0.14);
  border-right-color: var(--color-blue);
  color: var(--semantic-text);
}

/* Scrollbar styling — same as the diff viewers. */
.code-body::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

.code-body::-webkit-scrollbar-track {
  background: var(--color-bg-m2);
}

.code-body::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 5px;
}

.code-body::-webkit-scrollbar-thumb:hover {
  background: var(--color-gray-3);
}
</style>
