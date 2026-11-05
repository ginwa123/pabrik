<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseRemoveFile } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'

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
  const p = parseRemoveFile(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return isEmptyContent(props.content) && displayPath.value !== null
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-[var(--tint-error-border)] opacity-80': !parsed.deleted }"
  >
    <ToolCardHeader
      tool-name="remove_file"
      :primary="displayPath"
      :success="parsed.deleted"
      :expanded="isExpanded"
      :expandable="!!parsed.error || hasArgs"
      :cwd="cwd"
      :inline-tag="parsed.recursive ? '(recursive)' : null"
      :right-meta="isRunning ? 'running…' : null"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded && (parsed.error || hasArgs)"
      class="border-t border-[var(--color-border)] bg-[var(--semantic-wash)]"
    >
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
