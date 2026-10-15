<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'
import { extractParam } from '../../helpers/extractParam'
import { detectLanguage, highlightLine, type Token } from '../../helpers/codeHighlight'
import { parseSearch, normalizeToolContent } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => parseSearch(normalized.value.data))

// Search pattern and path come straight from the JSON data object.
const searchPattern = computed(() => parsed.value.pattern)

const searchPath = computed(() => parsed.value.path)

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayPattern = computed(
  () => searchPattern.value ?? extractParam(props.parameters, 'pattern'),
)
const displayPath = computed(() => searchPath.value ?? extractParam(props.parameters, 'path'))
const isRunning = computed(() => {
  const c = props.content
  const isEmpty =
    c === null ||
    c === undefined ||
    (typeof c === 'string' && c.trim() === '') ||
    (typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0)
  return isEmpty && displayPattern.value !== null
})

// Warning when the search found no matches.
const warningMessage = computed(() => parsed.value.warning)

// Error from the envelope (ChatView falls back to the full envelope content),
// if any.
const errorMessage = computed(() => normalized.value.error)

// File results with matches, straight from the JSON data object.
const fileResults = computed(() => parsed.value.fileResults)

// Total match count across all files
const totalMatchCount = computed(() => {
  return fileResults.value.reduce((sum, f) => sum + f.count, 0)
})

// Total file count
const totalFileCount = computed(() => fileResults.value.length)

// Status for styling
const hasWarning = computed(() => !!warningMessage.value)
const hasError = computed(() => !!errorMessage.value)
const truncationHint = computed(() => parsed.value.truncatedHint)
const hasTruncation = computed(
  () => parsed.value.truncated || parsed.value.outputTruncated || !!truncationHint.value,
)

/** Collection summary (`returned`/`total`/`truncated`). Null when the payload carries no counts,
 * and the header keeps its plain wording. */
/** `truncated` is the operator-visible half of the backend's truncation contract: a capped search
 * (max_output/max_results/head/tail) renders a bounded summary instead of looking exhaustive. */
interface SearchSummary {
  returned: number
  total: number
  truncated: boolean
}

const searchSummary = computed((): SearchSummary | null => {
  const { returned, total, truncated } = parsed.value
  if (returned === null || total === null) return null
  return { returned, total, truncated }
})

// Arguments guard (mirrors ToolParameters.vue hasArgs): non-empty params
// mean there is something worth expanding even with zero file results.
const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

// Expandable unless pure-running-empty (in-flight, no display info yet).
const isExpandable = computed(() => {
  if (isRunning.value) return false
  return (
    hasWarning.value ||
    hasError.value ||
    hasTruncation.value ||
    fileResults.value.length > 0 ||
    hasArgs.value
  )
})

// Toggle expansion
const toggle = () => {
  if (isExpandable.value) {
    isExpanded.value = !isExpanded.value
  }
}

// Copy path to clipboard
const copyPath = async (e: Event, path: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(path)
}

// Open file in code editor
const handleOpenInEditor = (e: Event, path: string) => {
  e.stopPropagation()
  if (!props.cwd || !openInEditor) return
  openInEditor({ filePath: path, cwd: props.cwd })
}

// Per-snippet tokens for code coloring. Language comes from the result file path so each file block
// highlights in its own language; unknown extensions fall back to plaintext (single plain token, as
// before).

// Tokens render as framework text nodes (never HTML strings), so snippet content cannot inject
// markup.
const tokensForSnippet = (snippet: string, filePath: string): Token[] => {
  return highlightLine(snippet, detectLanguage(filePath ?? ''))
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{
      'border-orange-500/50 opacity-85': hasWarning || hasTruncation,
      'border-red-500/50 opacity-85': hasError,
    }"
  >
    <!-- Header -->
    <div
      class="group flex flex-wrap items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">search</span>
      <span
        class="text-[var(--color-violet)] font-semibold max-w-[200px] truncate"
        :title="displayPattern || ''"
      >
        "{{ displayPattern || 'unknown' }}"
      </span>
      <span
        class="text-[var(--semantic-text-dim)] text-meta max-w-[150px] truncate"
        :title="displayPath || ''"
      >
        in {{ displayPath || 'unknown' }}
      </span>
      <span
        v-if="isRunning"
        data-testid="search-running"
        class="text-micro text-yellow-500 animate-pulse"
        >running…</span
      >

      <!-- Results summary -->
      <template v-if="!hasWarning && !hasError">
        <span class="ml-auto text-[var(--semantic-text-muted)] text-micro">
          {{ totalFileCount }} {{ totalFileCount === 1 ? 'file' : 'files' }},
          <template v-if="searchSummary && searchSummary.truncated">
            <span data-testid="search-truncated" class="text-orange-500">
              {{ searchSummary.returned }} of {{ searchSummary.total }} matches (truncated)
            </span>
          </template>
          <template v-else>
            {{ totalMatchCount }} {{ totalMatchCount === 1 ? 'match' : 'matches' }}
          </template>
        </span>
      </template>

      <span
        v-if="truncationHint"
        data-testid="search-truncation-hint"
        class="w-full text-orange-500 text-micro"
        :title="truncationHint"
      >
        {{ truncationHint }}
      </span>

      <!-- Warning or error message -->
      <template v-else-if="hasWarning">
        <span class="ml-auto text-orange-500 text-meta">{{ warningMessage }}</span>
      </template>
      <template v-else-if="hasError">
        <span class="ml-auto text-red-500 text-meta">{{ errorMessage }}</span>
      </template>

      <!-- Toggle indicator -->
      <span
        v-if="isExpandable"
        data-testid="search-expandable"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-body"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div v-if="fileResults.length > 0">
        <div
          v-for="(file, idx) in fileResults"
          :key="idx"
          class="border-b border-dashed border-[var(--color-border)] last:border-b-0"
        >
          <!-- File header -->
          <div class="flex items-center gap-1 px-2 py-1 bg-black/[0.02]">
            <span
              class="flex-1 text-[var(--color-violet)] text-meta truncate"
              :title="file.path"
            >
              {{ file.path }}
            </span>
            <span class="text-[var(--semantic-text-muted)] text-micro"
              >{{ file.count }}/{{ file.total }}</span
            >
            <button
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
              @click="(e) => copyPath(e, file.path)"
              title="Copy path"
            >
              ⎘
            </button>
            <button
              v-if="props.cwd && openInEditor"
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 transition-opacity"
              @click="(e) => handleOpenInEditor(e, file.path)"
              title="Open in code editor"
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
          </div>

          <!-- Match list -->
          <div class="py-0.5">
            <div
              v-for="(m, mIdx) in file.matches"
              :key="mIdx"
              class="flex py-0.5 px-2 leading-relaxed hover:bg-violet-500/5"
            >
              <span
                class="min-w-[3rem] text-right mr-3 text-[var(--semantic-text-dim)] select-none shrink-0"
              >
                {{ m.lineNumber }}
              </span>
              <span class="whitespace-pre-wrap break-all text-meta text-[var(--semantic-text)]"
                ><span
                  v-for="(tok, tIdx) in tokensForSnippet(m.snippet, file.path)"
                  :key="tIdx"
                  :class="'tok-' + tok.type"
                  >{{ tok.text || ' ' }}</span
                ></span
              >
            </div>
          </div>
        </div>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
