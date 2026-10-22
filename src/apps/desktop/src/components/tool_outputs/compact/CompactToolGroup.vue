<script setup lang="ts">
/** CompactToolGroup — a run of tool calls. A lone call is one row; a run of
 * several folds into one group card that unfolds into the rows. */
import { computed, ref } from 'vue'

import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'
import CompactToolRow from './CompactToolRow.vue'
import ToolCard, { type ToolCardData } from '../ToolCard.vue'

const props = defineProps<{
  cards: ToolCardData[]
  cwd: string
  sessionId: string
}>()

const emit = defineEmits<{
  'toggle-expand': [key: string]
  peek: [payload: { sessionId: string; agentName: string; instruction: string }]
  'jump-to-line': [line: number]
  'open-session': [sessionId: string]
}>()

const envelopes = computed(() =>
  props.cards.map((card) => tryUnwrapToolOutput(card.message.content)),
)
const failedCount = computed(
  () => envelopes.value.filter((envelope) => envelope !== null && !envelope.success).length,
)
const writeCount = computed(
  () =>
    props.cards.filter((card) =>
      ['write_file', 'text_replace', 'remove_file'].includes(card.message.tool_name ?? ''),
    ).length,
)
const durationMs = computed(() =>
  envelopes.value.reduce((total, envelope) => total + (envelope?.duration_ms ?? 0), 0),
)

const durationLabel = computed(() => {
  const ms = durationMs.value
  if (ms < 1000) return `${Math.round(ms)}ms`
  return `${(ms / 1000).toFixed(1)}s`
})

/** A question for the human, or a call the user opened: the full card, not a row. */
function isFullCard(card: ToolCardData): boolean {
  return card.expanded || card.message.tool_name === 'ask_user'
}

const isRun = computed(() => props.cards.length > 1)
/** A run that holds a question for the human starts open: a question you
 * cannot see is a question you cannot answer. */
const open = ref(props.cards.some((card) => card.message.tool_name === 'ask_user'))

function toggle(): void {
  open.value = !open.value
}
</script>

<template>
  <div class="tool-sequence tool-sequence-compact">
    <div v-if="isRun" class="tool-item">
      <div class="chat-tool-card" data-testid="compact-tool-group">
        <div
          class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
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
            {{ cards.length }} tool calls
          </span>
          <span
            class="flex-1 min-w-0 truncate text-left text-dense"
            style="color: var(--semantic-text-dim)"
          ></span>
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

    <template v-if="!isRun || open">
      <template v-for="card in cards" :key="card.expandKey">
        <ToolCard
          v-if="isFullCard(card)"
          v-bind="card"
          :cwd="cwd"
          :session-id="sessionId"
          @toggle-expand="emit('toggle-expand', $event)"
          @peek="emit('peek', $event)"
          @jump-to-line="emit('jump-to-line', $event)"
          @open-session="emit('open-session', $event)"
        />
        <div v-else class="tool-item">
          <CompactToolRow
            :tool="card.message.tool_name ?? 'tool'"
            :parameters="card.parameters"
            :content="card.message.content"
            @expand="emit('toggle-expand', card.expandKey)"
          />
        </div>
      </template>
    </template>
  </div>
</template>
