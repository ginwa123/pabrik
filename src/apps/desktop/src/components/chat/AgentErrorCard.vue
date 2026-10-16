<script setup lang="ts">
/** AgentErrorCard — dedicated renderer for agentic-loop error/retry diagnostics
 * (task_1787663566535_2). */
import { computed } from 'vue'
import { parseAgentErrorHeadline } from '../../helpers/parseAgentErrorHeadline'

const props = defineProps<{ content: string }>()

const parsed = computed(() => parseAgentErrorHeadline(props.content))
const retryLabel = computed(() => parsed.value.retryLabel)
const headline = computed(() => parsed.value.headline ?? '')

// "Retrying in 10000ms" → "10000ms". Absent when formatting failed.
const delayMs = computed((): string | null => {
  const m = props.content.match(/Retrying in (\d+ms)/)
  return m ? m[1]! : null
})

// Everything after "Server said:" — the raw server detail (HTTP body,
// SSE sample, etc.). May span multiple lines.
const serverDetail = computed((): string | null => {
  const idx = props.content.indexOf('Server said:')
  if (idx === -1) return null
  return props.content.slice(idx + 'Server said:'.length).trim() || null
})
</script>

<template>
  <div
    class="agent-error-card rounded-xl border border-red-500/30 bg-red-500/5 px-3 py-2 text-body"
    data-testid="agent-error-card"
    role="alert"
  >
    <header class="flex items-center gap-2 select-none">
      <span aria-hidden="true" class="text-red-500">⚠</span>
      <span class="font-medium text-red-500">Agent error</span>
      <span
        v-if="retryLabel"
        class="rounded-full bg-red-500/15 px-2 py-0.5 text-dense text-red-400"
        data-testid="agent-error-retry"
      >retry {{ retryLabel }}</span>
      <span
        v-if="delayMs"
        class="text-dense text-[var(--semantic-text-muted)]"
        data-testid="agent-error-delay"
      >{{ delayMs }}</span>
    </header>

    <div class="mt-1 text-dense text-[var(--semantic-text-muted)]" data-testid="agent-error-headline">
      {{ headline }}
    </div>

    <div
      v-if="serverDetail"
      class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-black/20 px-2 py-1.5 font-mono text-dense text-red-300"
      data-testid="agent-error-detail"
    >{{ serverDetail }}</div>
  </div>
</template>
