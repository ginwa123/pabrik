<!--
  RawHistoryView — one line per `llm_history` row, with the per-row actions.

  Its own component on purpose: ChatView keeps the composer, the scroll state
  and the session reads, and only chooses which of two children to mount. This
  one knows nothing about groups, bubbles or the VirtualScroller.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { Effect } from 'effect'
import { deleteMessage, restoreMessage, setMessageFeed, type MessageRow } from '../../../api'
import { SyncRemoteError } from '../../../sync/SyncError'
import { runSyncResult } from '../../../sync/runtime'
import type { Message } from './useChatMessagePresentation'

const props = defineProps<{
  sessionId: string
  messages: Message[]
}>()

const emit = defineEmits<{ changed: [] }>()

const fail = (reason: unknown) => (reason instanceof Error ? reason.message : String(reason))

const openId = ref<string | null>(null)
const menuPos = ref<{ x: number; y: number } | null>(null)
const confirmId = ref<string | null>(null)
const removed = ref<Set<string>>(new Set())
const dropped = ref<Set<string>>(new Set())
const lastDeleted = ref<{ row: MessageRow; label: string } | null>(null)
const busy = ref(false)
const error = ref<string | null>(null)

const rows = computed(() => props.messages.filter((m) => !removed.value.has(m.id)))

const isDropped = (m: Message): boolean =>
  dropped.value.has(m.id) || m.is_feed_to_llm === false

const idTail = (id: string): string => (id.length > 6 ? id.slice(-6) : id)

const preview = (m: Message): string => {
  const text = (m.content || '').replace(/\s+/g, ' ').trim()
  return text.length > 0 ? text : 'no text, tool call only'
}

const label = (m: Message): string => {
  const text = (m.content || '').replace(/\s+/g, ' ').trim()
  if (text.length > 0) return text.slice(0, 60)
  return `${m.role}${m.tool_name ? ` · ${m.tool_name}` : ''} · ${idTail(m.id)}`
}

const openMenu = (event: MouseEvent, m: Message): void => {
  const rect = (event.currentTarget as HTMLElement | null)?.getBoundingClientRect()
  openId.value = openId.value === m.id ? null : m.id
  menuPos.value = rect ? { x: rect.right - 218, y: rect.bottom + 4 } : null
}

const closeMenu = (): void => {
  openId.value = null
  menuPos.value = null
}

const startConfirm = (): void => {
  confirmId.value = openId.value
  closeMenu()
}

const cancelConfirm = (): void => {
  confirmId.value = null
}

const doDelete = async (id: string): Promise<void> => {
  if (busy.value) return
  busy.value = true
  error.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => deleteMessage(id),
      catch: (e) => new SyncRemoteError({ op: 'message.delete', reason: fail(e) }),
    }),
    'message.delete',
  )
  busy.value = false
  confirmId.value = null
  if (!result.ok) {
    error.value = result.reason
    return
  }
  const row = result.value.deleted.row
  removed.value = new Set([...removed.value, id])
  lastDeleted.value = { row, label: label(props.messages.find((m) => m.id === id) ?? { id } as Message) }
  emit('changed')
}

const undo = async (): Promise<void> => {
  const held = lastDeleted.value
  if (!held || busy.value) return
  busy.value = true
  error.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => restoreMessage(held.row),
      catch: (e) => new SyncRemoteError({ op: 'message.restore', reason: fail(e) }),
    }),
    'message.restore',
  )
  busy.value = false
  if (!result.ok) {
    error.value = result.reason
    return
  }
  const next = new Set(removed.value)
  next.delete(held.row.id)
  removed.value = next
  lastDeleted.value = null
  emit('changed')
}

const toggleFeed = async (m: Message): Promise<void> => {
  // The target `is_feed_to_llm` IS the current dropped state: a row that is in
  // context gets dropped, a dropped row comes back.
  const next = isDropped(m)
  closeMenu()
  if (busy.value) return
  busy.value = true
  error.value = null
  const result = await runSyncResult(
    Effect.tryPromise({
      try: () => setMessageFeed(m.id, next),
      catch: (e) => new SyncRemoteError({ op: 'message.feed', reason: fail(e) }),
    }),
    'message.feed',
  )
  busy.value = false
  if (!result.ok) {
    error.value = result.reason
    return
  }
  const set = new Set(dropped.value)
  if (next) set.delete(m.id)
  else set.add(m.id)
  dropped.value = set
  emit('changed')
}
</script>

<template>
  <div class="raw-history" data-testid="raw-history">
    <div class="raw-head">
      <span>Role</span>
      <span class="col-tool">Tool</span>
      <span>Content</span>
      <span class="col-feed">Context</span>
      <span class="col-id">Id</span>
      <span></span>
    </div>

    <p v-if="error" class="raw-error" data-testid="raw-history-error">{{ error }}</p>

    <template v-for="m in rows" :key="m.id">
      <div
        class="raw-row"
        :class="{ dropped: isDropped(m), open: openId === m.id }"
        :data-testid="`raw-row-${m.id}`"
      >
        <span class="chip" :class="m.role">{{ m.role }}</span>
        <span class="col-tool raw-tool">{{ m.tool_name || 'none' }}</span>
        <span class="raw-content" :class="{ empty: !m.content }">{{ preview(m) }}</span>
        <button
          v-if="isDropped(m)"
          type="button"
          class="raw-feed off restore"
          title="Put this row back in the model's context"
          :data-testid="`raw-feed-${m.id}`"
          @click="toggleFeed(m)"
        >
          dropped
        </button>
        <span v-else class="raw-feed" :data-testid="`raw-feed-${m.id}`">in</span>
        <span class="col-id raw-id">{{ idTail(m.id) }}</span>
        <button
          type="button"
          class="row-more"
          aria-label="Message actions"
          :data-testid="`raw-more-${m.id}`"
          @click="openMenu($event, m)"
        >
          &#8943;
        </button>
      </div>

      <div v-if="confirmId === m.id" class="raw-confirm" :data-testid="`raw-confirm-${m.id}`">
        <span class="raw-confirm-q">Delete this row?</span>
        <span class="raw-confirm-warn">
          The row is removed from llm_history and cannot be recovered after the strip closes.
        </span>
        <button type="button" class="raw-btn ghost" @click="cancelConfirm">Cancel</button>
        <button
          type="button"
          class="raw-btn danger"
          :disabled="busy"
          :data-testid="`raw-confirm-delete-${m.id}`"
          @click="doDelete(m.id)"
        >
          Delete
        </button>
      </div>
    </template>

    <p v-if="rows.length === 0" class="raw-empty">No rows in this session.</p>

    <div v-if="lastDeleted" class="raw-strip" data-testid="raw-history-strip">
      <span>Row deleted · <b>{{ lastDeleted.label }}</b></span>
      <button type="button" class="raw-undo" :disabled="busy" @click="undo">Undo</button>
    </div>

    <Teleport to="body">
      <div
        v-if="openId && menuPos"
        class="raw-menu"
        role="menu"
        data-testid="raw-history-menu"
        :style="{ left: `${menuPos.x}px`, top: `${menuPos.y}px` }"
        @click.stop
      >
        <button type="button" role="menuitem" class="raw-mi" @click="startConfirm">
          Delete message
        </button>
        <button
          type="button"
          role="menuitem"
          class="raw-mi"
          @click="toggleFeed(rows.find((r) => r.id === openId)!)"
        >
          {{ rows.find((r) => r.id === openId && isDropped(r)) ? 'Put back in context' : 'Drop from context' }}
        </button>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.raw-history {
  display: flex;
  flex-direction: column;
  padding: 6px 0 10px;
  overflow-y: auto;
  flex: 1;
  min-height: 0;
}

.raw-head,
.raw-row {
  display: grid;
  grid-template-columns: 78px 116px minmax(0, 1fr) 84px 58px 26px;
  align-items: center;
  gap: 10px;
  padding: 0 16px;
}

.raw-head {
  height: 26px;
  font-size: var(--text-micro);
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--semantic-text-dim);
}

.raw-row {
  min-height: 30px;
  padding-top: 4px;
  padding-bottom: 4px;
  font-size: var(--text-dense);
  color: var(--semantic-text-muted);
}

.raw-row:hover,
.raw-row.open {
  background: var(--semantic-active-bg);
}

.raw-row.dropped .raw-content {
  opacity: 0.4;
}

.chip {
  display: inline-flex;
  align-items: center;
  height: 18px;
  padding: 0 7px;
  border-radius: 5px;
  font-size: var(--text-meta);
  font-weight: 600;
  width: fit-content;
}

.chip.user {
  background: var(--color-blue-1);
  color: var(--semantic-text);
}

.chip.assistant {
  background: var(--semantic-active-bg);
  color: var(--semantic-text);
}

.chip.tool {
  background: var(--semantic-card-bg);
  color: var(--color-yellow);
}

.raw-tool,
.raw-content,
.raw-id {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.raw-tool {
  font-size: var(--text-meta);
  color: var(--semantic-text-dim);
}

.raw-content {
  color: var(--semantic-text);
}

.raw-content.empty {
  color: var(--semantic-text-dim);
}

.raw-feed {
  font-size: var(--text-meta);
  color: var(--color-green);
}

.raw-feed.off {
  color: var(--semantic-text-dim);
}

.raw-feed.restore {
  border: 0;
  background: transparent;
  font-family: inherit;
  cursor: pointer;
  padding: 0;
  text-decoration: underline;
  text-underline-offset: 2px;
}

.raw-id {
  font-size: var(--text-meta);
  color: var(--semantic-text-dim);
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.row-more {
  width: 24px;
  height: 24px;
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

.raw-row:hover .row-more,
.row-more:focus-visible,
.raw-row.open .row-more {
  opacity: 1;
  background: var(--semantic-active-bg);
  color: var(--semantic-text);
}

.raw-confirm {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
  margin: 3px 16px 7px;
  padding: 10px 12px;
  border-radius: 9px;
  background: var(--tint-error);
}

.raw-confirm-q {
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--semantic-text);
}

.raw-confirm-warn {
  flex: 1;
  min-width: 0;
  font-size: var(--text-meta);
  color: var(--color-yellow);
}

.raw-btn {
  padding: 6px 13px;
  border-radius: 7px;
  border: 0;
  font-family: inherit;
  font-size: var(--text-meta);
  font-weight: 600;
  cursor: pointer;
}

.raw-btn.ghost {
  background: var(--semantic-active-bg);
  color: var(--semantic-text-muted);
}

.raw-btn.danger {
  background: var(--color-red);
  color: var(--semantic-on-accent);
}

.raw-btn:disabled {
  opacity: 0.5;
  cursor: default;
}

.raw-strip {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 10px 16px 0;
  padding: 9px 12px;
  border-radius: 8px;
  background: var(--semantic-active-bg);
  font-size: var(--text-dense);
  color: var(--semantic-text-muted);
}

.raw-strip b {
  color: var(--semantic-text);
  font-weight: 600;
}

.raw-undo {
  border: 0;
  background: transparent;
  color: var(--color-blue);
  font-family: inherit;
  font-size: var(--text-dense);
  font-weight: 600;
  cursor: pointer;
  padding: 0;
  margin-left: auto;
}

.raw-empty,
.raw-error {
  margin: 18px 16px;
  font-size: var(--text-dense);
  color: var(--semantic-text-dim);
}

.raw-error {
  color: var(--color-red);
}

.raw-menu {
  position: fixed;
  z-index: 60;
  width: 218px;
  padding: 4px 0;
  border-radius: 9px;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  box-shadow: 0 14px 32px rgba(0, 0, 0, 0.5);
}

.raw-mi {
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

.raw-mi:hover,
.raw-mi:focus-visible {
  background: var(--semantic-active-bg);
  outline: none;
}

@media (max-width: 900px) {
  .raw-head,
  .raw-row {
    grid-template-columns: 70px minmax(0, 1fr) 26px;
  }

  .col-tool,
  .col-feed,
  .col-id {
    display: none;
  }
}
</style>
