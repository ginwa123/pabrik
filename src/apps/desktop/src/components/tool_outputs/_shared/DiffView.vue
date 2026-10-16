<script setup lang="ts">
import { computed, defineComponent, h, ref, type PropType, type VNode } from 'vue'
import {
  computeSplitView,
  computeUnifiedView,
  splitLines,
  type SplitRow,
  type UnifiedRow,
} from './myersDiff'
import { detectLanguage, highlightLine } from '@/helpers/codeHighlight'

/** Renders a side-by-side or unified diff for two strings. Split-view is the default (matches
 * GitHub). Unified-view uses git-style `@@ -start,count +start,count @@` hunk headers. */
interface Props {
  /** "Before" content (string; will be split into lines). */
  before: string
  /** "After" content (string; will be split into lines). */
  after: string
  /** Optional path — used as a title on the diff header for context. */
  filePath?: string
  /**    * Optional monaco language id for code coloring. When omitted it is derived from `filePath` via
   * `detectLanguage`; unknown extensions fall back to plaintext (plain-text rendering, exactly as
   * before). */
  language?: string
  /** Initial mode. Default 'split'. */
  initialMode?: 'split' | 'unified'
}

const props = withDefaults(defineProps<Props>(), {
  filePath: undefined,
  language: undefined,
  initialMode: 'split',
})

/** Emitted when the user clicks a line-number cell in the diff. Payload is the 1-based line number
 * in the file (the `after`-side line for split view, the actual row's new-line number for unified
 * view). */
const emit = defineEmits<{
  'jump-to-line': [line: number]
}>()

const STORAGE_KEY = 'diffview.mode'

const readStoredMode = (): 'split' | 'unified' => {
  try {
    if (typeof localStorage === 'undefined') return props.initialMode
    const v = localStorage.getItem(STORAGE_KEY)
    if (v === 'split' || v === 'unified') return v
  } catch {
    // localStorage may throw (private mode)
  }
  return props.initialMode
}

const mode = ref<'split' | 'unified'>(readStoredMode())

const setMode = (next: 'split' | 'unified') => {
  mode.value = next
  try {
    localStorage.setItem(STORAGE_KEY, next)
  } catch {
    // ignore
  }
}

const beforeLines = computed(() => splitLines(props.before))
const afterLines = computed(() => splitLines(props.after))

const splitRows = computed(() => computeSplitView(beforeLines.value, afterLines.value))
const unifiedRows = computed(() => computeUnifiedView(beforeLines.value, afterLines.value))

const changeCount = computed(() => {
  if (mode.value === 'split') {
    return splitRows.value.filter((r) => r.isChanged).length
  }
  return unifiedRows.value.filter((r) => r.kind === 'delete' || r.kind === 'insert').length
})

const hasChanges = computed(() => changeCount.value > 0)

/** Effective language for code coloring: explicit prop wins, otherwise
 * derived from the file path. Plaintext disables token spans. */
const effectiveLanguage = computed(() => props.language ?? detectLanguage(props.filePath ?? ''))

/**  * Split one line into colored token spans. Plaintext (or an empty line) returns a single text node
 * — identical output to the old plain-text rendering. Tokens render as framework text nodes, never
 * HTML strings, so `old_str` content cannot inject markup. */
function renderHighlighted(text: string, language: string): VNode[] {
  const tokens = highlightLine(text, language)
  if (tokens.length === 1 && tokens[0]!.type === 'plain') {
    return [h('span', { class: 'tok-plain' }, tokens[0]!.text || '\u00a0')]
  }
  return tokens.map((t, i) => h('span', { class: `tok-${t.type}`, key: i }, t.text))
}

const readMode = readStoredMode // suppress unused warning if some bundler tree-shakes

// ──────────────────────────────────────────────────────────────────────────── Sub-components —
// inline to avoid 3 separate files for tiny helpers.
// ────────────────────────────────────────────────────────────────────────────
const DiffSplitSide = defineComponent({
  name: 'DiffSplitSide',
  props: {
    rows: { type: Array as PropType<SplitRow[]>, required: true },
    side: { type: String as PropType<'before' | 'after'>, required: true },
    language: { type: String as PropType<string>, required: true },
  },
  setup(props) {
    return () => {
      if (props.rows.length === 0) {
        return h(
          'div',
          {
            class:
              'overflow-x-auto text-dense leading-relaxed font-mono bg-[var(--semantic-card-bg)] text-[var(--semantic-text)]',
          },
          [
            h(
              'div',
              {
                class: 'px-2 py-1 text-[var(--semantic-text-muted)] italic text-center',
              },
              '(no content)',
            ),
          ],
        )
      }
      return h(
        'div',
        {
          class:
            'overflow-x-auto text-dense leading-relaxed font-mono bg-[var(--semantic-card-bg)] text-[var(--semantic-text)]',
        },
        [
          h(
            'div',
            {
              // The shared sizing wrapper: shrink-wraps to the widest row's content, floored at
              // 100% of the scroll container (the pane). This is computed ONCE for the whole pane,
              // so every row below inherits the same final width.
              style: { width: 'max-content', minWidth: '100%' },
            },
            props.rows.map((row, idx) => renderSplitRow(row, idx, props.side, props.language)),
          ),
        ],
      )
    }
  },
})

function renderSplitRow(row: SplitRow, idx: number, side: 'before' | 'after', language: string) {
  const isBefore = side === 'before'
  const text = isBefore ? row.beforeText : row.afterText
  const lineNum = isBefore ? row.beforeLine : row.afterLine

  // Background color: only paint a side when that side actually HAS a line here.
  let bgColor = ''
  if (row.isChanged) {
    if (isBefore && row.beforeText !== null) {
      bgColor = 'rgba(248, 81, 73, 0.15)'
    } else if (!isBefore && row.afterText !== null) {
      bgColor = 'rgba(46, 160, 67, 0.15)'
    }
  }

  // The text is deliberately NOT tinted per row. An `!important` red/green color here beats the
  // `.tok-*` classes inside the spans and paints the whole line monochrome — a diff with no syntax
  // color on exactly the lines that changed.
  const isClickable = lineNum !== null
  const gutterClickHandler = isClickable
    ? {
        onClick: (e: MouseEvent) => {
          e.stopPropagation()
          emit('jump-to-line', lineNum!)
        },
        onMouseover: (e: MouseEvent) => {
          ;(e.currentTarget as HTMLElement).style.cursor = 'pointer'
          ;(e.currentTarget as HTMLElement).style.color = 'var(--color-violet)'
        },
        onMouseout: (e: MouseEvent) => {
          ;(e.currentTarget as HTMLElement).style.color = ''
        },
      }
    : {}

  // Row container: a plain block, `width: 100%` of the shared sizing wrapper (computed once per
  // pane — see DiffSplitSide).
  const rowStyle: Record<string, string> = { width: '100%' }
  if (bgColor) {
    rowStyle.backgroundColor = bgColor
  }

  return h(
    'div',
    {
      class: ['block whitespace-pre', bgColor ? '' : 'hover:bg-white/[0.03]'],
      style: rowStyle,
      'data-row': idx,
      'data-side': side,
      'data-changed': row.isChanged ? 'true' : 'false',
      'data-line': lineNum !== null ? String(lineNum) : undefined,
    },
    [
      // Gutter: line number cell. position:sticky + left:0 makes it stay
      // visible at the left edge when the user scrolls right. Card-bg
      // colored so the number stays readable against the row's bg.
      h(
        'span',
        {
          class:
            'inline-block px-2 py-0.5 select-none text-[var(--semantic-text-muted)] font-mono align-top',
          style: {
            position: 'sticky',
            left: '0',
            background: 'var(--semantic-card-bg)',
            zIndex: '1',
          },
          ...gutterClickHandler,
        },
        lineNum !== null ? String(lineNum) : '\u00a0',
      ),
      // Line content. Token-colored spans (code) or a single plain-text node (plaintext/unknown
      // language — identical to the old rendering).
      h(
        'span',
        {
          class: 'inline-block py-0.5 pr-2 whitespace-pre align-top',
        },
        text == null ? '\u00a0' : renderHighlighted(text, language),
      ),
    ],
  )
}

// renderInlineChanges was removed in the chunks 5+6 redesign.
const DiffUnifiedSide = defineComponent({
  name: 'DiffUnifiedSide',
  props: {
    rows: { type: Array as PropType<UnifiedRow[]>, required: true },
    language: { type: String as PropType<string>, required: true },
  },
  setup(props) {
    return () => {
      if (props.rows.length === 0) {
        return h(
          'div',
          {
            class:
              'overflow-x-auto text-dense leading-relaxed font-mono bg-[var(--semantic-card-bg)] text-[var(--semantic-text)]',
          },
          [
            h(
              'div',
              {
                class: 'px-2 py-1 text-[var(--semantic-text-muted)] italic text-center',
              },
              '(no content)',
            ),
          ],
        )
      }
      return h(
        'div',
        {
          class:
            'overflow-x-auto text-dense leading-relaxed font-mono bg-[var(--semantic-card-bg)] text-[var(--semantic-text)]',
        },
        [
          h(
            'div',
            {
              style: { width: 'max-content', minWidth: '100%' },
            },
            props.rows.map((row, idx) => renderUnifiedRow(row, idx, props.language)),
          ),
        ],
      )
    }
  },
})

function renderUnifiedRow(row: UnifiedRow, idx: number, language: string) {
  if (row.kind === 'hunk') {
    return h(
      'div',
      {
        class:
          'w-full px-2 py-0.5 text-[var(--semantic-text-muted)] italic bg-black/[0.02] border-y border-[var(--color-border)]',
        'data-hunk': idx,
      },
      row.text,
    )
  }
  let rowBgClass = ''
  if (row.kind === 'delete') rowBgClass = '!bg-red-400/15'
  else if (row.kind === 'insert') rowBgClass = '!bg-green-400/15'
  // ...but the +/- sign keeps its red/green: it is the only place in the
  // unified view that names the direction once the text is syntax-colored.
  const signColorClass =
    row.kind === 'delete' ? 'text-red-500' : row.kind === 'insert' ? 'text-green-500' : ''

  // Unified view: prefer the after-line for click (that's the file's new state).
  const jumpLine = row.afterLine ?? row.beforeLine
  const gutterClickHandler =
    jumpLine !== undefined && jumpLine !== null
      ? {
          onClick: (e: MouseEvent) => {
            e.stopPropagation()
            emit('jump-to-line', jumpLine as number)
          },
          onMouseover: (e: MouseEvent) => {
            ;(e.currentTarget as HTMLElement).style.cursor = 'pointer'
            ;(e.currentTarget as HTMLElement).style.color = 'var(--color-violet)'
          },
          onMouseout: (e: MouseEvent) => {
            ;(e.currentTarget as HTMLElement).style.color = ''
          },
        }
      : {}

  // Row is `flex w-full` — full width of the shared sizing wrapper (see
  // DiffUnifiedSide), so every row shares the same final width whether
  // it's a one-character line or the longest line in the file.
  return h(
    'div',
    {
      class: ['flex w-full hover:bg-violet-500/5', rowBgClass],
      'data-row': idx,
      'data-kind': row.kind,
      'data-after-line': row.afterLine ?? undefined,
      'data-before-line': row.beforeLine ?? undefined,
    },
    [
      h(
        'span',
        {
          class:
            'shrink-0 w-10 sticky left-0 z-10 px-2 py-0.5 text-right text-[var(--semantic-text-muted)] font-mono select-none border-r border-[var(--color-border)]',
          style: { background: 'var(--semantic-card-bg)' },
          ...(row.beforeLine !== null && row.beforeLine !== undefined ? gutterClickHandler : {}),
        },
        row.beforeLine ?? '',
      ),
      h(
        'span',
        {
          class:
            'shrink-0 w-10 sticky left-10 z-10 px-2 py-0.5 text-right text-[var(--semantic-text-muted)] font-mono select-none border-r border-[var(--color-border)]',
          style: { background: 'var(--semantic-card-bg)' },
          ...(row.afterLine !== null && row.afterLine !== undefined ? gutterClickHandler : {}),
        },
        row.afterLine ?? '',
      ),
      h(
        'span',
        {
          class: [
            'shrink-0 w-4 sticky left-20 z-10 mr-3 font-semibold text-center',
            signColorClass,
          ],
          style: { background: 'var(--semantic-card-bg)' },
        },
        row.text.charAt(0),
      ),
      h(
        'span',
        { class: 'shrink-0 px-2 py-0.5 whitespace-pre' },
        row.kind === 'context' || row.kind === 'delete' || row.kind === 'insert'
          ? renderHighlighted(row.text.slice(1), language)
          : row.text.slice(1),
      ),
    ],
  )
}

// Quiet the lint when readStoredMode is unused
void readMode
</script>

<template>
  <div
    class="rounded-md border border-[var(--color-border)] bg-[var(--semantic-card-bg)] overflow-hidden"
  >
    <!-- Header: file-path title, change count, mode toggle -->
    <div
      class="flex items-center justify-between gap-2 px-2 py-1 border-b border-[var(--color-border)] bg-black/[0.02] text-dense"
    >
      <div class="flex items-center gap-2 truncate">
        <span class="text-[var(--color-violet)] font-semibold">diff</span>
        <span
          v-if="filePath"
          class="text-[var(--semantic-text-muted)] truncate"
          :title="filePath"
          >{{ filePath }}</span
        >
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <span v-if="hasChanges" class="text-[var(--semantic-text-muted)]">
          {{ changeCount }} {{ changeCount === 1 ? 'change' : 'changes' }}
        </span>
        <div class="inline-flex rounded border border-[var(--color-border)] overflow-hidden">
          <button
            type="button"
            class="px-2 py-0.5 text-dense border-none cursor-pointer"
            :class="
              mode === 'split'
                ? 'bg-[var(--color-violet)] text-white'
                : 'bg-transparent text-[var(--semantic-text-muted)] hover:bg-violet-500/10'
            "
            @click="setMode('split')"
          >
            Split
          </button>
          <button
            type="button"
            class="px-2 py-0.5 text-dense border-none cursor-pointer"
            :class="
              mode === 'unified'
                ? 'bg-[var(--color-violet)] text-white'
                : 'bg-transparent text-[var(--semantic-text-muted)] hover:bg-violet-500/10'
            "
            @click="setMode('unified')"
          >
            Unified
          </button>
        </div>
      </div>
    </div>

    <!-- Split view -->
    <div v-if="mode === 'split'" class="flex divide-x divide-[var(--color-border)]">
      <div class="flex-1 min-w-0">
        <div
          class="px-2 py-0.5 text-dense font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-red-500"
        >
          Before
        </div>
        <DiffSplitSide :rows="splitRows" side="before" :language="effectiveLanguage" />
      </div>
      <div class="flex-1 min-w-0">
        <div
          class="px-2 py-0.5 text-dense font-semibold uppercase bg-black/[0.02] border-b border-[var(--color-border)] text-green-500"
        >
          After
        </div>
        <DiffSplitSide :rows="splitRows" side="after" :language="effectiveLanguage" />
      </div>
    </div>

    <!-- Unified view -->
    <DiffUnifiedSide v-else :rows="unifiedRows" :language="effectiveLanguage" />
  </div>
</template>
