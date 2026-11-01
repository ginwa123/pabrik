<script setup lang="ts">
import { computed } from 'vue'
import type { WorkspaceUsageReasonRow, WorkspaceUsageToolRow } from '../../api'

const props = defineProps<{
  tools: WorkspaceUsageToolRow[]
  reasons: WorkspaceUsageReasonRow[]
  toolCalls: number
}>()

const REASON_COLOR: Record<string, string> = {
  tool_calls: 'var(--color-blue)',
  stop: 'var(--semantic-success)',
  none: 'var(--color-bg-p2)',
}

const top = computed(() => Math.max(1, ...props.tools.map((t) => t.calls)))

const reasonTotal = computed(() =>
  Math.max(
    1,
    props.reasons.reduce((sum, r) => sum + r.calls, 0),
  ),
)

const segments = computed(() =>
  props.reasons.map((r) => ({
    key: r.reason,
    calls: r.calls,
    share: (r.calls / reasonTotal.value) * 100,
    color: REASON_COLOR[r.reason] ?? 'var(--color-ash)',
  })),
)

const reasonLabel = (reason: string): string =>
  reason === 'tool_calls' ? 'tool_calls (the agent asked for tools)' : reason
</script>

<template>
  <div class="grid gap-8 md:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]">
    <div>
      <p class="text-dense" style="color: var(--semantic-text-muted)">
        Tool calls by name
        <span v-if="tools.length" style="color: var(--semantic-text-dim)">
          · {{ tools.length }} of {{ toolCalls.toLocaleString() }}
        </span>
      </p>
      <div class="mt-3 space-y-2">
        <div
          v-for="tool in tools"
          :key="tool.tool_name"
          class="grid items-center gap-3 text-dense grid-cols-[120px_minmax(0,1fr)_64px] sm:grid-cols-[150px_minmax(0,1fr)_72px]"
        >
          <span class="truncate" :title="tool.tool_name">{{ tool.tool_name }}</span>
          <span class="h-3.5 rounded-sm overflow-hidden" style="background: var(--color-bg-m3)">
            <span
              class="block h-full rounded-sm"
              :style="{
                width: `${Math.max(1.5, (tool.calls / top) * 100)}%`,
                background: 'var(--color-blue)',
              }"
            />
          </span>
          <span class="text-right tabular-nums" style="color: var(--semantic-text-muted)">
            {{ tool.calls.toLocaleString() }}
          </span>
        </div>
        <p v-if="!tools.length" class="text-dense" style="color: var(--semantic-text-muted)">
          No tool call in this range.
        </p>
      </div>
    </div>

    <div>
      <p class="text-dense" style="color: var(--semantic-text-muted)">
        How the agent's turns ended
      </p>
      <div class="flex h-4 mt-3 rounded-sm overflow-hidden" style="background: var(--color-bg-m3)">
        <span
          v-for="segment in segments"
          :key="segment.key"
          :style="{ width: `${segment.share}%`, background: segment.color }"
          :title="`${reasonLabel(segment.key)}: ${segment.calls.toLocaleString()}`"
        />
      </div>
      <dl class="grid grid-cols-2 gap-3 mt-3">
        <div v-for="segment in segments" :key="segment.key">
          <dt class="text-dense flex items-center gap-2" style="color: var(--semantic-text-muted)">
            <span class="w-2 h-2 rounded-sm shrink-0" :style="{ background: segment.color }" />
            <span class="truncate" :title="reasonLabel(segment.key)">{{ segment.key }}</span>
          </dt>
          <dd class="text-dense tabular-nums mt-0.5">{{ segment.calls.toLocaleString() }}</dd>
        </div>
      </dl>
      <p class="text-dense mt-3 leading-relaxed" style="color: var(--semantic-text-dim)">
        Counted on assistant rows only: a tool's own result row is not a turn ending.
      </p>
    </div>
  </div>
</template>
