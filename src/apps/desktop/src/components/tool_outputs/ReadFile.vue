<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { parseReadFile, normalizeToolContent } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'
import { detectLanguage, highlightLine, type Token } from '@/helpers/codeHighlight'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseReadFile(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

// Display the parsed content; the parser already strips XML wrappers.
const fileContent = computed(() => parsed.value.content || '')

// Raw content lines. A single trailing "" produced by a final "\n" is
// a split artifact, not a real line — drop it so the gutter stays exact.
const contentLines = computed(() => {
  const c = fileContent.value
  if (!c) return []
  const lines = c.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
})

// 1-indexed display number of the first line. The backend's start_line
// is a 0-indexed offset, so line i renders as baseLine + i.
const baseLine = computed(() => (parsed.value.startLine ?? 0) + 1)

const lineCount = computed(() => contentLines.value.length)

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty content, but we know the path.
const isRunning = computed(() => {
  const c = props.content
  const isEmpty =
    c === null ||
    c === undefined ||
    (typeof c === 'string' && c.trim().length === 0) ||
    (typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0)
  return isEmpty && displayPath.value !== null
})

// Language for code coloring, derived from the file path. Unknown
// extensions fall back to plaintext (plain-text rendering, exactly as before).
const fileLanguage = computed(() => detectLanguage(displayPath.value ?? ''))

// Per-line tokens for code coloring. Tokens render as framework text
// nodes (never HTML strings), so file content cannot inject markup.
const highlightedLines = computed((): Token[][] => {
  const lang = fileLanguage.value
  return contentLines.value.map((line) => highlightLine(line, lang))
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !!parsed.error }"
  >
    <ToolCardHeader
      tool-name="read_file"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="isRunning ? 'running…' : parsed.error ? 'Error' : `${lineCount}L`"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-red-500 text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div
        v-else-if="contentLines.length > 0"
        class="p-2 m-0 bg-black/[0.02] overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-dense"
      >
        <div
          v-for="(tokens, idx) in highlightedLines"
          :key="idx"
          class="flex hover:bg-violet-500/5"
        >
          <span
            class="rf-gutter min-w-[3rem] text-right mr-3 text-[var(--semantic-text-dim)] select-none shrink-0"
            >{{ baseLine + idx }}</span
          >
          <span class="rf-line whitespace-pre"
            ><span v-for="(tok, tIdx) in tokens" :key="tIdx" :class="'tok-' + tok.type">{{
              tok.text || ' '
            }}</span></span
          >
        </div>
      </div>
      <pre
        v-else
        class="p-2 m-0 bg-black/[0.02] whitespace-pre overflow-x-visible leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-violet-500/5"
      >
(empty)</pre>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
