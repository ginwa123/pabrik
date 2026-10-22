<script setup lang="ts">
/** CompactToolRow — one tool call as ONE line: the tool, the argument that
 * identifies it, and how it ended. */
import { computed } from 'vue'

import { summarizeToolCall } from '../_shared/toolSummary'

const props = defineProps<{
  /** The tool name. */
  tool: string
  /** The tool-call arguments (XML or JSON). */
  parameters: string
  /** The tool result envelope. */
  content: string
}>()

const emit = defineEmits<{ expand: [] }>()

const summary = computed(() => summarizeToolCall(props.tool, props.parameters, props.content))
</script>

<template>
  <div
    class="flex items-center gap-2 px-2 py-0.5 text-dense"
    data-testid="compact-tool-row"
    :data-status="summary.status"
  >
    <code class="font-semibold text-[var(--color-violet)]" data-testid="compact-tool-row-name">{{
      summary.name
    }}</code>
    <code
      class="min-w-0 flex-1 truncate font-mono text-[var(--semantic-text-dim)]"
      :title="summary.primary"
      data-testid="compact-tool-row-primary"
      >{{ summary.primary }}</code
    >
    <span
      v-if="summary.badge"
      class="shrink-0 text-micro"
      :class="
        summary.status === 'failed'
          ? 'text-[var(--color-red)]'
          : summary.status === 'running'
            ? 'text-[var(--color-orange)]'
            : 'text-[var(--semantic-text-muted)]'
      "
      data-testid="compact-tool-row-badge"
      >{{ summary.badge }}</span
    >
    <button
      type="button"
      class="w-4 shrink-0 cursor-pointer border-none bg-transparent text-center text-body text-[var(--semantic-text-muted)]"
      title="Show the full card"
      data-testid="compact-tool-row-expand"
      @click="emit('expand')"
    >
      +
    </button>
  </div>
</template>
