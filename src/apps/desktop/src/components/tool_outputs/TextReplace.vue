<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import DiffView from './_shared/DiffView.vue'
import { normalizeToolContent, parseTextReplace } from './_shared/toolOutputParser'
import { detectLanguage } from '@/helpers/codeHighlight'
import { extractParam } from '@/helpers/extractParam'
import { useInjectOpenInCodeEditor } from '@/composables/useCodeEditor'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  diffviewBefore?: string
  diffviewAfter?: string
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)

// Keep local toggle state in sync with the parent's `expanded` prop so the component behaves as a
// *controlled* component (parent owns the truth).
// Without this sync, mount({expanded:true}) → setProps({expanded:false}) leaves the local ref out
// of sync with the prop, which is wrong for any caller that programmatically expands/collapses from
// outside (e.g. tests, a "collapse all" toolbar, etc.).
// Prev-prop guard on update: local toggles via handleToggle don't touch the prop, so they never
// clobber.
const prevExpandedProp = ref(props.expanded ?? false)
onMounted(() => {
  isExpanded.value = props.expanded ?? false
  prevExpandedProp.value = props.expanded ?? false
})
onUpdated(() => {
  const next = props.expanded ?? false
  if (next !== prevExpandedProp.value) {
    prevExpandedProp.value = next
    isExpanded.value = next
  }
})

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseTextReplace(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

// Parameters as a JSON object (null when unparseable). Used for the
// error-path diff fallback: on failure the envelope nulls `data`, so the
// only place old_str/new_str survive is the `parameters` prop.
const paramsObj = computed((): Record<string, unknown> | null => {
  try {
    const raw = (props.parameters ?? '').trim()
    if (!raw) return null
    const obj = JSON.parse(raw) as unknown
    if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) return null
    return obj as Record<string, unknown>
  } catch {
    return null
  }
})

// String field that preserves explicit empty strings (text_replace delete
// uses new_str=""). Returns null only when the key is missing/non-string.
const paramStr = (obj: Record<string, unknown> | null, ...keys: string[]): string | null => {
  if (!obj) return null
  for (const k of keys) {
    const v = obj[k]
    if (typeof v === 'string') return v
  }
  return null
}

// Diff content: prefer explicit props.diffviewBefore/After, then the envelope's before/after, then
// the call parameters. The parameter fallback is useful for successful results whose legacy diff
// fields are absent, but the result is gated by `parsed.success` below before anything is rendered.
// Null-safe: the SSE/REST layer may deliver explicit null (DB column null), which must fall through
// — passing null into DiffView crashes splitLines.
const diffBefore = computed(() => {
  if (props.diffviewBefore != null && props.diffviewBefore !== '') return props.diffviewBefore
  if (parsed.value.before !== '') return parsed.value.before
  return paramStr(paramsObj.value, 'old_str', 'before') ?? ''
})
const diffAfter = computed(() => {
  if (props.diffviewAfter != null && props.diffviewAfter !== '') return props.diffviewAfter
  if (parsed.value.after !== '') return parsed.value.after
  const fallback = paramStr(paramsObj.value, 'new_str', 'after')
  return fallback ?? ''
})

// Parameters describe the attempted edit; they are not proof that the edit was applied. Only a
// successful result may render a diff — otherwise an OldStrNotFound/MissingField failure would show
// the proposed replacement as if it were a real file change.
const hasDiff = computed(
  () => parsed.value.success && (diffBefore.value !== '' || diffAfter.value !== ''),
)

// old_str/new_str are already visualized as the diff above — hide them from
// Arguments so the expanded card shows a visual diff plus the path instead
// of a huge raw JSON blob (the screenshot that motivated this fix).
const ARGS_EXCLUDE = ['old_str', 'new_str', 'before', 'after', 'unified']

const hasArgs = computed(() => {
  const obj = paramsObj.value
  if (obj) {
    return Object.keys(obj).some((k) => !ARGS_EXCLUDE.includes(k))
  }
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
// The parser uses the `path` tag; also try `file_path` for forward-compat.
const displayPath = computed((): string | null => {
  return (
    contentPath.value ??
    extractParam(props.parameters, 'path') ??
    extractParam(props.parameters, 'file_path')
  )
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return isEmptyContent(props.content) && displayPath.value !== null
})

// Language for diff code coloring, derived from the target file path.
// DiffView falls back to plaintext (plain rendering) when unknown.
const diffLanguage = computed(() => detectLanguage(displayPath.value ?? ''))

const openInEditor = useInjectOpenInCodeEditor()

// Forward the diff-view's @jump-to-line to the in-app code editor so the user can click a line
// number in the diff and land on that exact line in the file viewer.
// We require both `cwd` and a path (the target file must be on disk + a workspace) before
// forwarding; otherwise we silently ignore the click (the line-number still renders the hover
// affordance but won't do anything, which is correct for tests / standalone renders).
const handleJumpToLine = (line: number) => {
  const targetPath = displayPath.value ?? parsed.value.path
  if (!openInEditor || !props.cwd || !targetPath) return
  openInEditor({
    filePath: targetPath,
    cwd: props.cwd,
    line,
  })
}

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
    data-testid="text-replace-card"
  >
    <ToolCardHeader
      tool-name="text_replace"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="!!parsed.error || hasDiff || hasArgs"
      :cwd="cwd"
      :right-meta="isRunning ? 'running…' : null"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-red-500 text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <DiffView
        v-if="hasDiff"
        :before="diffBefore"
        :after="diffAfter"
        :file-path="displayPath || undefined"
        :language="diffLanguage"
        class="rounded-none border-0"
        @jump-to-line="handleJumpToLine"
      />
      <ToolParameters :parameters="parameters" :exclude="ARGS_EXCLUDE" />
    </div>
  </div>
</template>
