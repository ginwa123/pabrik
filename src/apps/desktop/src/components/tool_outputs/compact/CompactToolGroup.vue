<script setup lang="ts">
/** CompactToolGroup — a run of tool calls, the thoughts between them and the narration the agent
 * wrote on the way to each call. Every run is one card that unfolds into the rows, a run of one
 * included: the count and the duration are what the reader scans for. */
import { computed, ref } from 'vue'

import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'
import { summarizeToolCall } from '../_shared/toolSummary'
import type { CompactChainItem } from './chain'
import { formatDuration } from './duration'
import CompactTextRow from './CompactTextRow.vue'
import CompactToolRow from './CompactToolRow.vue'
import ToolCard, { type ToolCardData } from '../ToolCard.vue'

const props = defineProps<{
  items: CompactChainItem[]
  cwd: string
  sessionId: string
}>()

const emit = defineEmits<{
  'toggle-expand': [key: string]
  peek: [payload: { sessionId: string; agentName: string; instruction: string }]
  'jump-to-line': [line: number]
  'open-session': [sessionId: string]
}>()

const cards = computed((): ToolCardData[] =>
  props.items.flatMap((item) => (item.kind === 'tool' ? [item.card] : [])),
)
const envelopes = computed(() =>
  cards.value.map((card) => tryUnwrapToolOutput(card.message.content)),
)
const failedCount = computed(
  () => envelopes.value.filter((envelope) => envelope !== null && !envelope.success).length,
)
const writeCount = computed(
  () =>
    cards.value.filter((card) =>
      ['write_file', 'text_replace', 'remove_file'].includes(card.message.tool_name ?? ''),
    ).length,
)
const durationMs = computed(() =>
  envelopes.value.reduce((total, envelope) => total + (envelope?.duration_ms ?? 0), 0),
)

const durationLabel = computed(() => formatDuration(durationMs.value))

const countLabel = computed(() =>
  cards.value.length === 1 ? '1 tool call' : `${cards.value.length} tool calls`,
)

/** A run of one has no count to scan, so the header carries the call itself. */
const summaryLabel = computed(() => {
  const only = cards.value.length === 1 ? cards.value[0] : undefined
  if (!only) return ''
  const summary = summarizeToolCall(
    only.message.tool_name ?? 'tool',
    only.parameters,
    only.message.content,
  )
  return `${summary.name} ${summary.primary}`.trim()
})

/** A call the user opened: the full card, not a row. */
function isFullCard(card: ToolCardData): boolean {
  return card.expanded
}

const open = ref(false)

function toggle(): void {
  open.value = !open.value
}
</script>

<template>
  <div class="tool-sequence tool-sequence-compact" data-testid="compact-tool-chain">
    <div class="tool-item">
      <div class="chat-tool-card" data-testid="compact-tool-group">
        <div
          class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-[var(--tint-accent)]"
          role="button"
          tabindex="0"
          :aria-expanded="open"
          data-testid="compact-tool-group-header"
          @click="toggle"
          @keydown.enter.prevent="toggle"
          @keydown.space.prevent="toggle"
        >
          <span
            class="font-semibold text-[var(--color-violet)] text-dense"
            data-testid="compact-tool-group-count"
          >
            {{ countLabel }}
          </span>
          <span
            class="flex-1 min-w-0 truncate text-left text-dense"
            style="color: var(--semantic-text-dim)"
            data-testid="compact-tool-group-summary"
            >{{ summaryLabel }}</span
          >
          <span
            v-if="failedCount > 0"
            class="font-medium text-dense"
            style="color: var(--color-red)"
            data-testid="compact-tool-group-failed"
          >
            {{ failedCount }} failed
          </span>
          <span
            v-if="writeCount > 0"
            class="text-[var(--semantic-text-muted)] text-dense"
            data-testid="compact-tool-group-writes"
          >
            {{ writeCount }} write
          </span>
          <span
            v-if="durationMs > 0"
            class="text-[var(--semantic-text-muted)] text-dense"
            data-testid="compact-tool-group-duration"
          >
            {{ durationLabel }}
          </span>
          <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">{{
            open ? '−' : '+'
          }}</span>
        </div>
      </div>
    </div>

    <template v-if="open">
      <template v-for="(item, idx) in items" :key="item.key">
        <ToolCard
          v-if="item.kind === 'tool' && isFullCard(item.card)"
          v-bind="item.card"
          :class="idx < items.length - 1 ? 'tool-item-border' : ''"
          :cwd="cwd"
          :session-id="sessionId"
          @toggle-expand="emit('toggle-expand', $event)"
          @peek="emit('peek', $event)"
          @jump-to-line="emit('jump-to-line', $event)"
          @open-session="emit('open-session', $event)"
        />
        <div v-else class="tool-item" :class="idx < items.length - 1 ? 'tool-item-border' : ''">
          <CompactTextRow
            v-if="item.kind === 'thought'"
            :text="item.text"
            label="thought"
            test-id="compact-thought"
          />
          <CompactTextRow
            v-else-if="item.kind === 'narration'"
            :text="item.text"
            label="said"
            test-id="compact-narration"
          />
          <CompactToolRow
            v-else
            :tool="item.card.message.tool_name ?? 'tool'"
            :parameters="item.card.parameters"
            :content="item.card.message.content"
            @expand="emit('toggle-expand', item.card.expandKey)"
          />
        </div>
      </template>
    </template>
  </div>
</template>
