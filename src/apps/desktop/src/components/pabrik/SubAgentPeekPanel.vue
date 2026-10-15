<script setup lang="ts">
/** SubAgentPeekPanel — right-side slide-over panel for watching a sub-agent's progress without
 * leaving the parent chat. The panel is thin chrome (header / error banner / footer) around an
 * embedded ChatView in read-only mode. */

/** ChatView owns fetch + SSE for `sessionId` and renders the full message list with the same tool
 * output components, markdown, reasoning blocks, and error cards as the main chat — there is no
 * duplicated tool-dispatch chain here to keep in sync with ChatView.vue. */

/** The `messages` prop is kept for backward compat (SubAgentPeekHost still passes the composable's
 * rows; header-adjacent consumers and existing tests reference it) but the body renders via
 * ChatView, not from this prop. */

/** Status / error / tokens continue to come from `useSubAgentPeek` via the host so the header stays
 * live even while ChatView owns the message list lifecycle. */
import { computed } from 'vue'
import ChatView from '../views/ChatView.vue'
import type { Message } from '../../api'

type PeekStatus = 'idle' | 'loading' | 'streaming' | 'complete' | 'error'

const props = defineProps<{
  sessionId: string
  agentName: string
  instruction: string
  status: PeekStatus
  errorMessage: string | null
  /**    * Retained for backward compat — SubAgentPeekHost still passes the composable's rows. The body
   * renders via the embedded ChatView (which fetches the same session itself), not from this prop. */
  messages: Message[]
  totalTokens?: number
}>()

const emit = defineEmits<{
  close: []
  openFull: [sessionId: string]
  reload: []
}>()

// ── Derived display values ────────────────────────────────────────────

const instructionPreview = computed(() => {
  const max = 200
  return props.instruction.length > max
    ? props.instruction.slice(0, max) + '…'
    : props.instruction
})

const statusLabel = computed(() => {
  switch (props.status) {
    case 'idle': return 'Idle'
    case 'loading': return 'Loading…'
    case 'streaming': return 'Streaming…'
    case 'complete': return 'Complete'
    case 'error': return 'Error'
  }
  return ''
})

const statusClass = computed(() => {
  switch (props.status) {
    case 'streaming': return 'peek-status-streaming'
    case 'complete': return 'peek-status-complete'
    case 'error': return 'peek-status-error'
    default: return 'peek-status-idle'
  }
})
</script>

<template>
  <Teleport to="body">
    <div
      class="peek-overlay"
      data-testid="peek-panel"
      role="dialog"
      aria-label="Sub-agent progress"
      @keydown.esc="emit('close')"
    >
      <!-- Backdrop — click to close -->
      <div class="peek-backdrop" @click="emit('close')"></div>

      <!-- Panel -->
      <div class="peek-panel">
        <!-- Header -->
        <header class="peek-header">
          <div class="peek-header-left">
            <div class="peek-header-label-line">
              <span class="peek-kind">Sub-agent</span>
              <span class="peek-agent-name" :title="agentName">{{ agentName }}</span>
              <span
                class="peek-status"
                :class="statusClass"
                data-testid="peek-status"
              >
                <span v-if="status === 'streaming'" class="peek-status-dot"></span>
                {{ statusLabel }}
              </span>
            </div>
            <p
              class="peek-instruction"
              data-testid="peek-instruction"
              :title="instruction"
            >
              {{ instructionPreview }}
            </p>
          </div>
          <button
            class="peek-open-full"
            data-testid="peek-open-full"
            :title="`Open ${sessionId} in main chat view`"
            @click="emit('openFull', sessionId)"
          >
            Open full
          </button>
          <button
            class="peek-close"
            data-testid="peek-close"
            title="Close (ESC)"
            @click="emit('close')"
          >
            ✕
          </button>
        </header>

        <!-- Error banner -->
        <div
          v-if="status === 'error' && errorMessage"
          class="peek-error-banner"
          data-testid="peek-error-banner"
        >
          <span class="peek-error-message">{{ errorMessage }}</span>
          <button
            class="peek-error-retry"
            data-testid="peek-error-retry"
            @click="emit('reload')"
          >
            Retry
          </button>
        </div>

        <!-- Message list — full ChatView in read-only embed mode.
             Keyed by sessionId so eye-click A → B without remount still
             swaps the conversation (mirrors SubAgentPeekHost's key). -->
        <div
          class="peek-chat-embed"
          data-testid="peek-messages-scroll"
        >
          <ChatView
            :key="sessionId"
            :chat-id="sessionId"
            :chat-name="agentName"
            embedded
            hide-input
          />
        </div>

        <!-- Footer -->
        <footer class="peek-footer">
          <span class="peek-footer-session" :title="sessionId">
            session: {{ sessionId }}
          </span>
          <span v-if="(totalTokens ?? 0) > 0" class="peek-footer-tokens">
            {{ (totalTokens ?? 0).toLocaleString() }} tokens
          </span>
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
/* The panel uses CSS vars from the app's theme — no hardcoded
 * colors beyond a few translucent tints for the pulse animation.
 * Positioning: fixed inset-0 + flex justify-end so the panel slides
 * in from the right; backdrop click closes (matches the close ✕ and
 * ESC).
 */
.peek-overlay {
  position: fixed;
  inset: 0;
  z-index: 50;
  display: flex;
  justify-content: flex-end;
}
.peek-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
}
.peek-panel {
  position: relative;
  width: 460px;
  max-width: 90%;
  height: 100%;
  background: var(--semantic-card-bg);
  border-left: 1px solid var(--color-border);
  box-shadow: -10px 0 30px rgba(0, 0, 0, 0.5);
  display: flex;
  flex-direction: column;
  font-size: var(--text-dense);
}

.peek-header {
  padding: 12px 16px;
  border-bottom: 1px solid var(--color-border);
  display: flex;
  align-items: center;
  gap: 8px;
}
.peek-header-left { flex: 1; min-width: 0; }
.peek-header-label-line {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: var(--text-dense);
}
.peek-kind {
  font-size: var(--text-micro);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--semantic-text-muted);
  font-weight: 600;
}
.peek-agent-name {
  font-weight: 600;
  color: var(--semantic-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 180px;
}
.peek-status {
  font-size: var(--text-meta);
  white-space: nowrap;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.peek-status-streaming { color: var(--color-violet); }
.peek-status-complete  { color: var(--color-green); }
.peek-status-error     { color: var(--color-red); }
.peek-status-idle      { color: var(--semantic-text-muted); }
.peek-status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--color-violet);
  animation: peek-pulse 1.5s ease-in-out infinite;
}
@keyframes peek-pulse {
  0%, 100% { opacity: 1; transform: scale(1); }
  50%      { opacity: 0.5; transform: scale(1.4); }
}
.peek-instruction {
  font-size: var(--text-meta);
  color: var(--semantic-text-muted);
  margin-top: 2px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  margin: 0;
}
.peek-open-full {
  font-size: var(--text-meta);
  padding: 4px 8px;
  border-radius: 4px;
  background: var(--semantic-content-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
  cursor: pointer;
  white-space: nowrap;
}
.peek-open-full:hover {
  background: rgba(139, 92, 246, 0.1);
  border-color: var(--color-violet);
}
.peek-close {
  width: 28px;
  height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 4px;
  color: var(--semantic-text-muted);
  cursor: pointer;
  border: 1px solid transparent;
  background: transparent;
  font-size: var(--text-body);
}
.peek-close:hover {
  color: var(--semantic-text);
  border-color: var(--color-border);
}

.peek-error-banner {
  padding: 8px 12px;
  background: rgba(239, 68, 68, 0.1);
  border-bottom: 1px solid rgba(239, 68, 68, 0.3);
  color: var(--color-red);
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: var(--text-meta);
}
.peek-error-message { flex: 1; overflow: hidden; text-overflow: ellipsis; }
.peek-error-retry {
  font-size: var(--text-micro);
  padding: 2px 6px;
  border-radius: 3px;
  border: 1px solid rgba(239, 68, 68, 0.3);
  background: transparent;
  color: var(--color-red);
  cursor: pointer;
}
.peek-error-retry:hover { background: rgba(239, 68, 68, 0.1); }

/* Embedded ChatView host — gives the inner ChatView (which is
 * `flex h-full w-full` with its own VirtualScroller at
 * `flex: 1 1 0`) a bounded flex column to fill. ChatView brings its
 * own message styling, tool cards, and empty state; nothing to mirror
 * here anymore.
 */
.peek-chat-embed {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.peek-footer {
  padding: 8px 16px;
  border-top: 1px solid var(--color-border);
  font-size: var(--text-meta);
  color: var(--semantic-text-muted);
  display: flex;
  align-items: center;
  gap: 12px;
}
.peek-footer-session {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
  min-width: 0;
}
.peek-footer-tokens {
  margin-left: auto;
  color: var(--color-violet);
  white-space: nowrap;
}
</style>
