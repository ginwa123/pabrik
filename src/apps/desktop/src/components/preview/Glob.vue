<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from '../tool_outputs/_shared/ToolParameters.vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'
import { extractParam } from '../../helpers/extractParam'
import { normalizeToolContent } from '../tool_outputs/_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

// The card receives the bare `data` object (or a full envelope, or a
// blank string while running). Field access replaces the old
// pattern="…"/<f>…</f> regex parsing.
const normalized = computed(() => normalizeToolContent(props.content))
const dataRecord = computed((): Record<string, unknown> => {
  const { data } = normalized.value
  if (data !== null && typeof data === 'object' && !Array.isArray(data)) {
    return data as Record<string, unknown>
  }
  return {}
})

// Envelope-level failure (ChatView falls back to the full envelope
// content). Without this the card renders a bare "0 files" with no
// explanation — the "not showing output" report.
const errorMessage = computed(() => normalized.value.error)
const hasError = computed(() => !!errorMessage.value)

const strOf = (v: unknown): string | null => (typeof v === 'string' ? v : null)
const numOf = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

// Parse glob pattern
const globPattern = computed(() => strOf(dataRecord.value['pattern']))

// GlobJSON carries no path field — fall back to tool-call parameters.
const globPath = computed(() => null as string | null)

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayPattern = computed(
  () => globPattern.value ?? extractParam(props.parameters, 'pattern'),
)
const displayPath = computed(() => globPath.value ?? extractParam(props.parameters, 'path'))
const isRunning = computed(
  () =>
    typeof props.content === 'string' &&
    props.content.trim() === '' &&
    displayPattern.value !== null,
)

// Parse total count
const totalCount = computed(() => numOf(dataRecord.value['total']))

// Parse returned count
const returnedCount = computed(() => numOf(dataRecord.value['returned']))

// Parse truncated count
const truncatedCount = computed(() => numOf(dataRecord.value['truncated']))

// Parse offset
const offsetValue = computed(() => numOf(dataRecord.value['offset']))

// Parse warning if no matches
const warningMessage = computed(() => strOf(dataRecord.value['warning']))

const hasWarning = computed(() => !!warningMessage.value)

// Parse all file paths
const filePaths = computed((): string[] => {
  const files = dataRecord.value['files']
  if (!Array.isArray(files)) return []
  return files.filter((f): f is string => typeof f === 'string')
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
  return hasWarning.value || hasError.value || filePaths.value.length > 0 || hasArgs.value
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
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{
      'border-[var(--tint-warning-border)] opacity-85': warningMessage && !hasError,
      'border-[var(--tint-error-border)] opacity-90': hasError,
    }"
  >
    <!-- Header -->
    <div
      role="button"
      tabindex="0"
      class="group flex items-center flex-wrap gap-1.5 px-2 py-1 cursor-pointer select-none hover:bg-[var(--tint-accent)]"
      @click="toggle"
    >
      <span class="gl-title">glob</span>
      <span class="gl-pattern" :title="displayPattern || ''">
        "{{ displayPattern || 'unknown' }}"
      </span>
      <span
        v-if="displayPath"
        class="text-[var(--semantic-text-dim)] text-meta max-w-[150px] truncate"
        :title="displayPath"
      >
        in {{ displayPath }}
      </span>
      <span
        v-if="isRunning"
        data-testid="glob-running"
        class="text-micro text-[var(--semantic-warning)] animate-pulse"
        >running…</span
      >

      <!-- Results summary -->
      <template v-if="!warningMessage && !hasError">
        <span class="gl-summary">
          {{ totalCount }} {{ totalCount === 1 ? 'file' : 'files' }}
          <template v-if="returnedCount < totalCount">
            ({{ returnedCount }} returned{{
              truncatedCount > 0 ? `, ${truncatedCount} truncated` : ''
            }})
          </template>
          <template v-if="offsetValue > 0">
            <span class="gl-offset">offset: {{ offsetValue }}</span>
          </template>
        </span>
      </template>

      <!-- Error message (envelope failure) takes precedence over warning -->
      <template v-else-if="hasError">
        <span class="gl-error-text">{{ errorMessage }}</span>
      </template>

      <!-- Warning message -->
      <template v-else-if="warningMessage">
        <span class="gl-warning-text">{{ warningMessage }}</span>
      </template>

      <!-- Toggle indicator -->
      <span v-if="isExpandable" class="gl-toggle">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- File list (expanded state only - no scroll) -->
    <div v-if="isExpanded" class="gl-content">
      <div
        v-if="hasError && errorMessage"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense"
        data-testid="glob-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
      <div v-else-if="filePaths.length > 0">
        <div v-for="(path, idx) in filePaths" :key="idx" class="gl-file">
          <span class="gl-file-path" :title="path">{{ path }}</span>
          <button class="gl-copy" @click="(e) => copyPath(e, path)" title="Copy path">⎘</button>
          <button
            v-if="props.cwd && openInEditor"
            class="gl-copy"
            @click="(e) => handleOpenInEditor(e, path)"
            title="Open in code editor"
          >
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
              />
            </svg>
          </button>
        </div>
      </div>
      <div
        v-else-if="warningMessage"
        class="px-3 py-2 text-center text-[var(--color-orange)] text-dense"
        data-testid="glob-empty"
      >
        {{ warningMessage }}
      </div>
      <div
        v-else
        class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic"
        data-testid="glob-empty"
      >
        (no files)
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

<style scoped>
/* Root frame comes from the shared `.chat-tool-card` class defined in
 * ChatView.vue (:deep) and mirrored in SubAgentPeekPanel.vue (:deep).
 * Only content-level styles remain here. The warning variant binds
 * `border-[var(--tint-warning-border)]` via :class which recolors the card's left rule,
 * matching how ShellTool recolors on error/warning. */
.gl-title {
  color: var(--color-violet);
  font-weight: 600;
  font-size: var(--text-dense);
}

.gl-pattern {
  color: var(--color-violet);
  font-weight: 600;
  max-width: 200px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.gl-summary {
  margin-left: auto;
  color: var(--semantic-text-muted);
  font-size: var(--text-micro);
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.gl-offset {
  color: var(--semantic-text-dim);
  font-size: var(--text-micro);
}

.gl-warning-text {
  margin-left: auto;
  font-size: var(--text-micro);
  color: var(--color-orange);
}

.gl-error-text {
  margin-left: auto;
  font-size: var(--text-micro);
  color: var(--semantic-error);
}

.gl-toggle {
  color: var(--semantic-text-muted);
  font-size: var(--text-meta);
  width: 1rem;
  text-align: center;
}

.gl-content {
  border-top: 1px solid var(--color-border);
}

.gl-file {
  display: flex;
  align-items: center;
  padding: 0.25rem 0.5rem;
  border-bottom: 1px dashed var(--color-border);
  gap: 0.3rem;
}

.gl-file:last-child {
  border-bottom: none;
}

.gl-file:hover {
  background: var(--semantic-wash);
}

.gl-file-path {
  flex: 1;
  color: var(--semantic-text);
  font-size: var(--text-meta);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.gl-copy {
  padding: 0 0.15rem;
  border: none;
  background: none;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
  font-size: var(--text-meta);
  flex-shrink: 0;
}

.gl-file:hover .gl-copy {
  opacity: 1;
}

.gl-copy:hover {
  color: var(--color-violet);
}
</style>
