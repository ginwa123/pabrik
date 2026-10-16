<script setup lang="ts">
import { computed } from 'vue'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'

/** Shared chrome for tool-output cards (read_file, write_file, text_replace, etc.). Presentational
 * only — the caller parses the tool's content and passes resolved props. */
interface Props {
  /** Tool name shown in the violet pill (e.g. "read_file") */
  toolName: string
  /** Primary field (path / skill name / search pattern). Truncated with ellipsis. */
  primary: string | null | undefined
  /** Tooltip for the primary field. Defaults to primary. */
  primaryTitle?: string | null | undefined
  /** Override the primary text color (default: violet). Used by SetGitWorktree which uses dim gray. */
  primaryClass?: string | undefined
  /** Whether the tool succeeded (controls badge and copy-button availability). */
  success: boolean
  /** Whether the card is currently expanded. Bound to parent state. */
  expanded: boolean
  /** Whether the card is expandable at all. When false, no chevron and clicks are no-ops. */
  expandable: boolean
  /** Show the copy-to-clipboard button. Default: true. */
  showCopy?: boolean
  /** Show the open-in-code-editor button. Default: true. */
  showOpenInEditor?: boolean
  /** Value to copy to clipboard. Defaults to primary. */
  copyValue?: string | null | undefined
  /** CWD for open-in-editor. When null, open-in-editor button is hidden. */
  cwd?: string | null | undefined
  /** Small inline tag shown after the tool-name pill (e.g. "(recursive)"). */
  inlineTag?: string | null | undefined
  /** Color class for the inline tag (default: orange). */
  inlineTagClass?: string | undefined
  /** Small text shown after the primary field (e.g. "12L", "3 matches"). */
  rightMeta?: string | null | undefined
  /** In-progress tool call (envelope still empty). Shows a yellow
   *  "running…" badge next to the status. Default: false. */
  running?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  primaryTitle: undefined,
  primaryClass: 'text-[var(--color-violet)] font-medium',
  showCopy: true,
  showOpenInEditor: true,
  copyValue: undefined,
  cwd: undefined,
  inlineTag: null,
  inlineTagClass: 'text-[var(--color-orange)]',
  rightMeta: null,
  running: false,
})

const emit = defineEmits<{
  'update:expanded': [boolean]
}>()

const openInEditor = useInjectOpenInCodeEditor()

const canOpenInEditor = computed(
  () => props.showOpenInEditor && !!props.cwd && !!openInEditor && !!props.primary,
)

const effectiveCopyValue = computed(() => props.copyValue ?? props.primary ?? '')
const hasCopyValue = computed(() => effectiveCopyValue.value.length > 0)

const handleHeaderClick = () => {
  if (props.expandable) emit('update:expanded', !props.expanded)
}

const handleHeaderKeyDown = (e: KeyboardEvent) => {
  if (!props.expandable) return
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault()
    emit('update:expanded', !props.expanded)
  }
}

const copyToClipboard = async (e: Event) => {
  e.stopPropagation()
  if (!hasCopyValue.value) return
  try {
    await navigator.clipboard.writeText(effectiveCopyValue.value)
  } catch {
    // ignore — clipboard may be blocked in jsdom tests
  }
}

const openInEditorClick = (e: Event) => {
  e.stopPropagation()
  // canOpenInEditor guarantees primary, cwd, and openInEditor are all non-null
  if (!canOpenInEditor.value || !openInEditor || !props.primary || !props.cwd) return
  openInEditor({ filePath: props.primary, cwd: props.cwd })
}
</script>

<template>
  <div
    class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
    :class="{ 'cursor-default': !expandable }"
    role="button"
    :tabindex="expandable ? 0 : -1"
    :aria-expanded="expandable ? expanded : undefined"
    @click="handleHeaderClick"
    @keydown="handleHeaderKeyDown"
  >
    <span class="text-[var(--color-violet)] font-semibold text-dense">{{ toolName }}</span>
    <span v-if="inlineTag" class="text-dense" :class="inlineTagClass">{{ inlineTag }}</span>
    <span
      class="flex-1 min-w-0 truncate text-left text-dense"
      :class="primaryClass"
      :title="primaryTitle ?? primary ?? ''"
      data-testid="tool-card-primary"
      >{{ primary || 'unknown' }}</span
    >
    <span v-if="rightMeta" class="text-[var(--semantic-text-muted)] text-dense">{{ rightMeta }}</span>
    <span
      v-if="running"
      data-testid="tool-card-running"
      class="text-micro text-yellow-500 animate-pulse shrink-0"
      >running…</span
    >
    <span class="text-dense font-semibold" :class="success ? 'text-green-500' : 'text-red-500'">
      {{ success ? '✓' : '✗' }}
    </span>
    <button
      v-if="showCopy && hasCopyValue"
      class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
      :title="`Copy ${toolName}`"
      @click="copyToClipboard"
    >
      ⎘
    </button>
    <button
      v-if="canOpenInEditor"
      class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 transition-opacity"
      title="Open in code editor"
      @click="openInEditorClick"
    >
      <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
        />
      </svg>
    </button>
    <span v-if="expandable" class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
      {{ expanded ? '−' : '+' }}
    </span>
  </div>
</template>
