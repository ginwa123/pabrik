<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseWriteFile } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'
import { detectLanguage, highlightLine, type Token } from '@/helpers/codeHighlight'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseWriteFile(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

// Parameters as a JSON object (null when unparseable). Used to pull the
// `content` arg out for readable rendering and to decide expandability
// without double-counting the excluded blob.
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

// File body to render readably. Preserves explicit empty strings (writing
// an empty file is valid) — null only when the key is missing/non-string
// and no XML fallback matches.
const writeContent = computed((): string | null => {
  const obj = paramsObj.value
  if (obj) {
    const v = obj['content']
    if (typeof v === 'string') return v
    if (v != null) return String(v)
    return null
  }
  const xml = extractParam(props.parameters, 'content')
  if (xml !== null) return xml
  const raw = props.parameters ?? ''
  if (/<content>[\s\S]*?<\/content>/.test(raw)) return ''
  return null
})

const hasContent = computed(() => writeContent.value !== null)

// Raw content lines. A single trailing "" produced by a final "\n" is
// a split artifact, not a real line — drop it so the gutter stays exact.
const contentLines = computed(() => {
  const c = writeContent.value
  if (c === null || c === '') return []
  const lines = c.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
})

const lineCount = computed(() => contentLines.value.length)

// The written body starts at line 1 (no backend offset like read_file).
const baseLine = 1

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path (<file_write>); fall back to the parameters
// prop so a still-running tool (placeholder envelope with empty <data>)
// shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return isEmptyContent(props.content) && displayPath.value !== null
})

// `content` is visualized as readable lines above — hide it from Arguments
// so the expanded card doesn't repeat the whole file body as escaped JSON.
const ARGS_EXCLUDE = ['content']

const hasFilteredArgs = computed(() => {
  const obj = paramsObj.value
  if (obj) {
    return Object.keys(obj).some((k) => !ARGS_EXCLUDE.includes(k))
  }
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

// Language for code coloring, derived from the target file path. Unknown
// extensions fall back to plaintext (plain-text rendering).
const fileLanguage = computed(() => detectLanguage(displayPath.value ?? ''))

// Per-line tokens for code coloring. Tokens render as framework text
// nodes (never HTML strings), so file content cannot inject markup.
const highlightedLines = computed((): Token[][] => {
  const lang = fileLanguage.value
  return contentLines.value.map((line) => highlightLine(line, lang))
})

const rightMeta = computed(() => {
  if (isRunning.value) return 'running…'
  if (parsed.value.error) return 'Error'
  if (hasContent.value) return `${lineCount.value}L`
  return null
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
    data-testid="write-file-card"
  >
    <ToolCardHeader
      tool-name="write_file"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="!!parsed.error || hasFilteredArgs || hasContent"
      :cwd="cwd"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded && (parsed.error || hasFilteredArgs || hasContent)"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-red-500 text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div v-if="hasContent" class="px-2 py-1.5">
        <div class="mb-1 select-none text-[var(--semantic-text-dim)]">
          Content{{ lineCount > 0 ? ` (${lineCount}L)` : '' }}
        </div>
        <div
          v-if="contentLines.length > 0"
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
      </div>
      <ToolParameters :parameters="parameters" :exclude="ARGS_EXCLUDE" />
    </div>
  </div>
</template>
