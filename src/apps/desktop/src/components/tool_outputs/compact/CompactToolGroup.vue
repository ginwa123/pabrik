<script setup lang="ts">
/** CompactToolGroup — a run of tool calls as ONE card. The cards behind the
 * group card are the dev cards, unchanged. */
import { computed, ref } from 'vue'

import { tryUnwrapToolOutput } from '@/helpers/unwrapToolOutput'
import ToolCard, { type ToolCardData } from '../ToolCard.vue'

const props = defineProps<{
  /** The calls of this run, in order. */
  cards: ToolCardData[]
  /** The session working directory. */
  cwd: string
  /** The session that owns these calls. */
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
const failedCount = computed(() => envelopes.value.filter((e) => e !== null && !e.success).length)
const runningCount = computed(
  () =>
    props.cards.filter(
      (card, i) => envelopes.value[i] === null && card.message.content.trim() === '',
    ).length,
)
const writeCount = computed(
  () =>
    props.cards.filter((card) =>
      ['write_file', 'text_replace', 'remove_file'].includes(card.message.tool_name ?? ''),
    ).length,
)
const durationMs = computed(() =>
  envelopes.value.reduce((total, e) => total + (e?.duration_ms ?? 0), 0),
)

const hasAskUser = computed(() => props.cards.some((card) => card.message.tool_name === 'ask_user'))

const open = ref(hasAskUser.value)
/** A run that holds a question for the human stays open: a question you
 * cannot see is a question you cannot answer. */
const isOpen = computed(() => open.value || hasAskUser.value)

const durationLabel = computed(() => {
  const ms = durationMs.value
  if (ms < 1000) return `${Math.round(ms)}ms`
  return `${(ms / 1000).toFixed(1)}s`
})

function toggle(): void {
  open.value = !isOpen.value
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key !== 'Enter' && event.key !== ' ') return
  event.preventDefault()
  toggle()
}
</script>

<template>
  <div class="tool-sequence">
    <div class="tool-item">
      <div class="chat-tool-card" data-testid="compact-tool-group">
        <div
          class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
          role="button"
          tabindex="0"
          :aria-expanded="isOpen"
          data-testid="compact-tool-group-header"
          @click="toggle"
          @keydown="onKeydown"
        >
          <span
            class="text-[var(--color-violet)] font-semibold text-dense"
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
            class="text-dense font-medium"
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
            v-if="runningCount > 0"
            class="text-[var(--semantic-text-muted)] text-dense"
            data-testid="compact-tool-group-running"
          >
            {{ runningCount }} running
          </span>
          <span
            v-if="durationMs > 0"
            class="text-[var(--semantic-text-muted)] text-dense"
            data-testid="compact-tool-group-duration"
          >
            {{ durationLabel }}
          </span>
          <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
            {{ isOpen ? '−' : '+' }}
          </span>
        </div>
      </div>
    </div>

    <ToolCard
      v-for="card in isOpen ? cards : []"
      :key="card.expandKey"
      v-bind="card"
      :cwd="cwd"
      :session-id="sessionId"
      @toggle-expand="emit('toggle-expand', $event)"
      @peek="emit('peek', $event)"
      @jump-to-line="emit('jump-to-line', $event)"
      @open-session="emit('open-session', $event)"
    />
  </div>
</template>
