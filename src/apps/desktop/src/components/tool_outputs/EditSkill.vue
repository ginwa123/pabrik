<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { normalizeToolContent, parseEditSkill } from './_shared/toolOutputParser'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Surfaced via the
   *  shared <ToolParameters> block in the expanded body; empty/'{}'
   *  renders nothing (see ToolParameters.vue hasArgs guard). */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Running means the tool has not returned yet: the dispatcher passes an empty-string placeholder.
// Without this the card renders its failure styling (`border-red-500/50` + a red cross) for the
// whole tool call, because `parsed.edited` is false while the envelope is empty.
const isEmptyContent = (c: unknown): boolean =>
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const isRunning = computed(() => isEmptyContent(props.content))
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseEditSkill(normalized.value.data)
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

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-80': !parsed.edited && !isRunning }"
  >
    <ToolCardHeader
      tool-name="edit_skill"
      :primary="parsed.skillName"
      :success="parsed.edited"
      :running="isRunning"
      :expanded="isExpanded"
      :expandable="!parsed.edited || !!parsed.error || hasArgs"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02] flex flex-col min-h-0"
    >
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <!-- The row moved in place rather than to a new location, so the
           edited skill is named instead of located. -->
      <div
        v-if="parsed.edited && parsed.skillName"
        class="flex gap-2 px-2 py-1.5 text-green-500 text-dense border-b border-dashed border-[var(--color-border)]"
        data-testid="edit-skill-name"
      >
        <span class="font-semibold shrink-0">Edited:</span>
        <span class="whitespace-pre-wrap break-all text-[var(--semantic-text-dim)]">{{
          parsed.skillName
        }}</span>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>
