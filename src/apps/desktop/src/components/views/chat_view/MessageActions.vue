<!--
  MessageActions — the per-row "⋯" for one `llm_history` row in the grouped
  transcript. The menu and the confirm are anchored popovers, not an in-flow
  bar: the transcript lives in a VirtualScroller that measures item heights, so
  inserting a bar would desync its estimate. The raw table is a plain column
  and does use the in-flow bar.
-->
<script setup lang="ts">
import { ref } from 'vue'
import { Effect } from 'effect'
import { deleteMessage, setMessageFeed } from '../../../api'
import { SyncRemoteError } from '../../../sync/SyncError'
import { runSyncResult } from '../../../sync/runtime'

const props = defineProps<{
  messageId: string
  label: string
  isDropped?: boolean
}>()

const emit = defineEmits<{ changed: [] }>()

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const open = ref(false)
const confirming = ref(false)
const busy = ref(false)
const error = ref<string | null>(null)
const pos = ref({ x: 0, y: 0 })

const close = (): void => {
  open.value = false
  confirming.value = false
}

const toggle = (event: MouseEvent): void => {
  const rect = (event.currentTarget as HTMLElement | null)?.getBoundingClientRect()
  if (open.value) {
    close()
    return
  }
  pos.value = rect ? { x: Math.max(8, rect.right - 218), y: rect.bottom + 4 } : { x: 8, y: 8 }
  open.value = true
  confirming.value = false
}

const doDelete = async (): Promise<void> => {
  if (busy.value) return
  busy.value = true
  error.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => deleteMessage(props.messageId),
      catch: (e) => new SyncRemoteError({ op: 'message.delete', reason: fail(e) }),
    }),
    'message.delete',
  )
  busy.value = false
  close()
  if (!result.ok) {
    error.value = result.reason
    return
  }
  emit('changed')
}

const doDrop = async (): Promise<void> => {
  if (busy.value) return
  busy.value = true
  error.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => setMessageFeed(props.messageId, props.isDropped === true),
      catch: (e) => new SyncRemoteError({ op: 'message.feed', reason: fail(e) }),
    }),
    'message.feed',
  )
  busy.value = false
  close()
  if (!result.ok) {
    error.value = result.reason
    return
  }
  emit('changed')
}
</script>

<template>
  <span class="msg-actions">
    <button
      type="button"
      class="msg-more"
      aria-label="Message actions"
      :data-testid="`msg-more-${messageId}`"
      @click.stop="toggle"
    >
      &#8943;
    </button>

    <Teleport to="body">
      <div
        v-if="open"
        class="msg-panel"
        :style="{ left: `${pos.x}px`, top: `${pos.y}px` }"
        :data-testid="`msg-panel-${messageId}`"
        @click.stop
      >
        <template v-if="!confirming">
          <button type="button" class="msg-mi" @click="confirming = true">Delete message</button>
          <button type="button" class="msg-mi" @click="doDrop">
            {{ isDropped ? 'Put back in context' : 'Drop from context' }}
          </button>
        </template>
        <template v-else>
          <p class="msg-confirm-q">Delete this row?</p>
          <p class="msg-confirm-warn">
            Removed from llm_history. The raw view can undo it until the strip closes.
          </p>
          <div class="msg-confirm-row">
            <button type="button" class="msg-btn ghost" @click="close">Cancel</button>
            <button
              type="button"
              class="msg-btn danger"
              :disabled="busy"
              :data-testid="`msg-confirm-delete-${messageId}`"
              @click="doDelete"
            >
              Delete
            </button>
          </div>
        </template>
      </div>
    </Teleport>

    <span v-if="error" class="msg-error">{{ error }}</span>
  </span>
</template>

<style scoped>
.msg-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex: none;
}

.msg-more {
  width: 22px;
  height: 22px;
  border-radius: 6px;
  border: 0;
  background: transparent;
  color: var(--semantic-text-dim);
  font-family: inherit;
  font-size: var(--text-body);
  line-height: 1;
  cursor: pointer;
  opacity: 0.35;
}

.msg-more:hover,
.msg-more:focus-visible {
  opacity: 1;
  background: var(--semantic-active-bg);
  color: var(--semantic-text);
}

.msg-error {
  font-size: var(--text-meta);
  color: var(--color-red);
}

.msg-panel {
  position: fixed;
  z-index: 60;
  width: 218px;
  padding: 6px 0;
  border-radius: 9px;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  box-shadow: 0 14px 32px rgba(0, 0, 0, 0.5);
}

.msg-mi {
  display: block;
  width: 100%;
  padding: 5px 12px;
  border: 0;
  background: transparent;
  color: var(--semantic-text);
  font-family: inherit;
  font-size: var(--text-dense);
  text-align: left;
  cursor: pointer;
}

.msg-mi:hover,
.msg-mi:focus-visible {
  background: var(--semantic-active-bg);
  outline: none;
}

.msg-confirm-q {
  padding: 0 12px;
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--semantic-text);
}

.msg-confirm-warn {
  padding: 4px 12px 8px;
  font-size: var(--text-meta);
  color: var(--semantic-text-muted);
}

.msg-confirm-row {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 0 12px 4px;
}

.msg-btn {
  padding: 5px 11px;
  border-radius: 7px;
  border: 0;
  font-family: inherit;
  font-size: var(--text-meta);
  font-weight: 600;
  cursor: pointer;
}

.msg-btn.ghost {
  background: var(--semantic-active-bg);
  color: var(--semantic-text-muted);
}

.msg-btn.danger {
  background: var(--color-red);
  color: var(--semantic-on-accent);
}

.msg-btn:disabled {
  opacity: 0.5;
  cursor: default;
}
</style>
