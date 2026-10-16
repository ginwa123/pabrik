<script setup lang="ts">
/** SubAgentPeekHost — lifecycle owner for a sub-agent peek. 2026-09-04 subagent-peek P1 fix:
 * `useSubAgentPeek()` registers `onMounted`/`onUnmounted`, so it MUST be called in setup scope —
 * never inside a `computed` (ChatView.vue did that. */
import SubAgentPeekPanel from './SubAgentPeekPanel.vue'
import { useSubAgentPeek } from '../../composables/useSubAgentPeek'

const props = defineProps<{
  sessionId: string
  agentName: string
  instruction: string
}>()

const emit = defineEmits<{
  close: []
  openFull: [sessionId: string]
}>()

const peek = useSubAgentPeek({
  sessionId: props.sessionId,
  agentName: props.agentName,
  instruction: props.instruction,
})
</script>

<template>
  <SubAgentPeekPanel
    :session-id="props.sessionId"
    :agent-name="props.agentName"
    :instruction="props.instruction"
    :status="peek.status.value"
    :error-message="peek.errorMessage.value"
    :messages="peek.messages.value"
    :total-tokens="peek.totalTokens.value"
    @close="emit('close')"
    @open-full="emit('openFull', $event)"
    @reload="peek.reload"
  />
</template>
