<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from '../tool_outputs/_shared/ToolParameters.vue'
import { normalizeToolContent } from '../tool_outputs/_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// The card receives the bare `data` object ({updated, thought, error}).
// A legacy XML string degrades to empty (running state) instead of
// regex-parsing tags.
const dataRecord = computed((): Record<string, unknown> => {
  const { data } = normalizeToolContent(props.content)
  if (data !== null && typeof data === 'object' && !Array.isArray(data)) {
    return data as Record<string, unknown>
  }
  return {}
})

const fieldStr = (key: string): string | null => {
  const v = dataRecord.value[key]
  if (typeof v === 'string') return v.trim() || null
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

// Parse updated status
const isUpdated = computed(() => {
  const v = dataRecord.value['updated']
  if (typeof v === 'boolean') return v
  const s = fieldStr('updated')
  return s !== null && s === 'true'
})

// Parse thought content
const thoughtContent = computed((): string | null => fieldStr('thought'))

// Parse error message if any
const errorMessage = computed((): string | null => fieldStr('error'))

// Parse thought format: [YYYY-MM-DD HH:MM] session_XXXX @ /path/to/dir | Action | Details
interface ThoughtParts {
  timestamp: string
  sessionId: string
  cwd: string
  action: string
  details: string
}

const thoughtParts = computed((): ThoughtParts | null => {
  if (!thoughtContent.value) return null

  // Match: [YYYY-MM-DD HH:MM] session_XXXX @ /path/to/dir | Action | Details
  const match = thoughtContent.value.match(/\[([^\]]+)\]\s*([^@]+)@\s*([^|]+)\|\s*([^|]+)\|\s*(.*)/)
  if (!match) return null

  return {
    timestamp: match[1] || '',
    sessionId: match[2]?.trim() || '',
    cwd: match[3]?.trim() || '',
    action: match[4]?.trim() || '',
    details: match[5]?.trim() || '',
  }
})

// Status indicator
const statusIcon = computed(() => (isUpdated.value ? '✓' : '✗'))

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyThought = async (e: Event) => {
  e.stopPropagation()
  if (thoughtContent.value) {
    await navigator.clipboard.writeText(thoughtContent.value)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-[var(--tint-error-border)] opacity-80': !isUpdated }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-[var(--tint-accent)]"
      :class="{ 'cursor-default': isUpdated && !errorMessage }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">update_activity</span>

      <!-- Show compact view if we have parsed parts -->
      <template v-if="thoughtParts">
        <span class="text-[var(--semantic-text-muted)] text-dense">{{ thoughtParts.timestamp }}</span>
        <span class="text-[var(--semantic-text-dim)]">•</span>
        <span
          class="text-[var(--color-violet)] font-medium truncate max-w-[120px]"
          :title="thoughtParts.action"
        >
          {{ thoughtParts.action }}
        </span>
        <span class="text-[var(--semantic-text-dim)]">•</span>
        <span
          class="text-[var(--semantic-text-dim)] truncate max-w-[100px]"
          :title="thoughtParts.details"
        >
          {{ thoughtParts.details }}
        </span>
      </template>
      <!-- Fallback to raw thought if parsing fails -->
      <span
        v-else-if="thoughtContent"
        class="flex-1 truncate text-left text-[var(--semantic-text-dim)]"
      >
        {{ thoughtContent }}
      </span>

      <span class="text-dense font-semibold" :class="isUpdated ? 'text-[var(--semantic-success)]' : 'text-[var(--semantic-error)]'">
        {{ statusIcon }}
      </span>
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-[var(--semantic-accent)] text-lead transition-opacity"
        @click="copyThought"
        title="Copy thought"
      >
        ⎘
      </button>
      <span v-if="errorMessage" class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-[var(--semantic-wash)]">
      <!-- Error message -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Parsed thought details -->
      <div v-else-if="thoughtParts" class="p-2 space-y-1 text-dense">
        <div class="flex items-center gap-2">
          <span class="text-[var(--semantic-text-muted)] w-16">Timestamp:</span>
          <span class="text-[var(--semantic-text)]">{{ thoughtParts.timestamp }}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[var(--semantic-text-muted)] w-16">Session:</span>
          <span class="text-[var(--semantic-text)]">{{ thoughtParts.sessionId }}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[var(--semantic-text-muted)] w-16">CWD:</span>
          <span class="text-[var(--color-violet)] truncate" :title="thoughtParts.cwd">{{
            thoughtParts.cwd
          }}</span>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[var(--semantic-text-muted)] w-16">Action:</span>
          <span class="text-[var(--semantic-text)]">{{ thoughtParts.action }}</span>
        </div>
        <div class="flex items-start gap-2">
          <span class="text-[var(--semantic-text-muted)] w-16">Details:</span>
          <span class="text-[var(--semantic-text)] whitespace-pre-wrap break-all">{{
            thoughtParts.details
          }}</span>
        </div>
      </div>

      <!-- Raw thought if parsing failed -->
      <div
        v-else-if="thoughtContent"
        class="p-2 text-[var(--semantic-text)] text-dense whitespace-pre-wrap"
      >
        {{ thoughtContent }}
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
