<!--
  ChatRowContextMenu — the right-click action menu for a sidebar RECENT
  chat row. Replaces the single-item OpenInNewTabMenu that ChatsList
  mounted, adding the three actions a chat owner reaches for without
  opening the chat first.

  Item order follows the same rule KanbanTaskContextMenu documents for
  itself (frequency first, state-changing actions grouped, "open in new
  tab" demoted below the mutations it competes with for attention).
  Unlike the kanban menu there is no destructive row yet — "Stop agent"
  is recoverable (the run can be restarted) so it sits in the action
  group, not alone in red at the bottom.

  Item order:
    [title bar]
    Rename chat
    Unattended mode          (label reflects current state)
    Pin to top / Unpin       (Migration 104, PINNED section)
    ─────────
    Stop agent               (only while processingState[id] is true)
    ─────────
    Open chat in new tab

  The host (ChatsList) owns position via `useContextMenu` and owns every
  mutation; this component only reports intent. Each emit is zero-arg —
  the host already holds the row payload in `contextMenuChat`.

  `data-context-menu` on the root is load-bearing, not decoration:
  useContextMenu's window mousedown handler opts OUT of the outside-click
  dismiss only for targets inside `[data-context-menu]`. Without the
  attribute the menu closes on the very mousedown that picks an item and
  the action silently never fires. (GitBranchMenu.vue is missing this and
  survives only because each of its rows closes the menu itself.)

  Styling note: the `menu-*` classes below are a copy of the ones in
  KanbanTaskContextMenu.vue's scoped block. Vue scoped styles cannot
  reach another component, so the duplication is structural, not
  accidental — the two files carry cross-references so a change to one
  is noticed in the other.
-->
<script setup lang="ts">
import { ref } from 'vue'

// No `const props =` binding: every prop is read from the template, and an
// assigned-but-unreferenced `props` trips @typescript-eslint/no-unused-vars
// even though the template consumes all of them.
withDefaults(
  defineProps<{
    x: number
    y: number
    /** Chat name, shown in the title bar so the target is unambiguous. */
    chatName?: string
    /** A worker is running — reveals the "Stop agent" row. */
    isProcessing?: boolean
    /** Server truth for `is_auto_retry_until_stop` ('1' = unattended on). */
    unattended?: boolean
    /** True while the stop request is in flight — re-entry lock. */
    isStopping?: boolean
    /** Migration 104 — pinned state for the PINNED section. */
    isPinned?: boolean
  }>(),
  {
    chatName: '',
    isProcessing: false,
    unattended: false,
    isStopping: false,
    isPinned: false,
  },
)

const emit = defineEmits<{
  rename: []
  toggleUnattended: []
  togglePin: []
  stop: []
  openInNewTab: []
}>()

// ─── Keyboard navigation ────────────────────────────────────────────────── The row is a <button>,
// so it is already in the tab order; the menu has to be arrow-navigable too.
const rootRef = ref<HTMLElement | null>(null)

const navRows = (): HTMLElement[] =>
  Array.from(rootRef.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])

const moveFocus = (delta: number) => {
  const rows = navRows()
  if (rows.length === 0) return
  // Start from where the pointer actually is, not a stale index — the
  // row list changes shape when "Stop agent" appears.
  const at = rows.indexOf(document.activeElement as HTMLElement)
  const from = at >= 0 ? at : -1
  const next = (from + delta + rows.length) % rows.length
  rows[next]?.focus()
}

const onKeydown = (event: KeyboardEvent) => {
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveFocus(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveFocus(-1)
  }
  // Escape is intentionally NOT handled here: useContextMenu owns the
  // outer dismiss and already closes on window keydown.
}

// Hovering a row focuses it, so the arrow keys continue from the row
// under the pointer instead of snapping back to the top of the menu.
const focusRow = (event: MouseEvent) => {
  ;(event.currentTarget as HTMLElement | null)?.focus()
}
</script>

<template>
  <Teleport to="body">
    <div
      ref="rootRef"
      data-context-menu
      data-testid="chat-context-menu"
      role="menu"
      :aria-label="`Actions for ${chatName || 'chat'}`"
      class="fixed z-[60] py-1 text-dense rounded-lg shadow-lg min-w-[210px] outline-none"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
      @contextmenu.prevent
      @keydown="onKeydown"
    >
      <!-- Title bar. With four actions in one menu the user needs to see
           WHICH row they right-clicked before picking. -->
      <div
        v-if="chatName"
        class="px-3 pt-1 pb-1.5 mb-1 border-b truncate max-w-[240px]"
        style="border-color: var(--color-border); color: var(--semantic-text-dim)"
        data-testid="chat-context-menu-title"
        :title="chatName"
      >
        {{ chatName }}
      </div>

      <button
        type="button"
        role="menuitem"
        data-testid="chat-context-menu-rename"
        class="menu-row"
        @click="emit('rename')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
            />
          </svg>
        </span>
        <span class="menu-lb">Rename chat</span>
      </button>

      <!-- Unattended mode is a toggle, so the label states the action the
           pick will perform rather than a static noun — "Unattended mode"
           alone leaves the current state ambiguous. The ●/○ marker
           carries the same state for anyone who scans the icons. -->
      <button
        type="button"
        role="menuitem"
        :aria-checked="unattended"
        data-testid="chat-context-menu-unattended"
        class="menu-row"
        @click="emit('toggleUnattended')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12.8 7.9a4 4 0 11-1.6 0M5 12a7 7 0 0114 0M12 12l2.5-2.5M4 20h16"
            />
          </svg>
        </span>
        <span class="menu-lb">
          {{ unattended ? 'Turn off unattended mode' : 'Turn on unattended mode' }}
        </span>
        <span class="menu-dot" aria-hidden="true">{{ unattended ? '●' : '' }}</span>
      </button>

      <!-- Migration 104 — pin/unpin for the PINNED section above RECENT.
           Same pin glyph as the kanban menu so the two surfaces match. -->
      <button
        type="button"
        role="menuitem"
        :aria-checked="isPinned"
        data-testid="chat-context-menu-pin"
        class="menu-row"
        @click="emit('togglePin')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg
            v-if="isPinned"
            viewBox="0 0 24 24"
            fill="currentColor"
          >
            <path
              d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
            />
          </svg>
          <svg
            v-else
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
            />
          </svg>
        </span>
        <span class="menu-lb">{{ isPinned ? 'Unpin from top' : 'Pin to top' }}</span>
        <span
          class="menu-dot"
          aria-hidden="true"
          >{{ isPinned ? '●' : '' }}</span
        >
      </button>

      <div class="menu-sep" role="separator" />

      <!-- Stop is recoverable — a stopped run can be restarted — so it is
           red for emphasis but NOT isolated at the bottom like the kanban
           menu's destructive row. -->
      <button
        v-if="isProcessing"
        type="button"
        role="menuitem"
        data-testid="chat-context-menu-stop"
        :disabled="isStopping"
        class="menu-row menu-row--danger"
        :class="isStopping ? 'menu-row--busy' : ''"
        @click="emit('stop')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#9632;</span>
        <span class="menu-lb">{{ isStopping ? 'Stopping agent…' : 'Stop agent' }}</span>
      </button>

      <div v-if="isProcessing" class="menu-sep" role="separator" />

      <button
        type="button"
        role="menuitem"
        data-testid="chat-context-menu-open-tab"
        class="menu-row"
        @click="emit('openInNewTab')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#8599;</span>
        <span class="menu-lb">Open chat in new tab</span>
      </button>
    </div>
  </Teleport>
</template>

<style scoped>
/* Mirrors the `menu-*` block in KanbanTaskContextMenu.vue — see the
   styling note in this file's header. Keep the two in sync. */
.menu-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  padding: 0.3rem 0.75rem;
  border: 0;
  background: transparent;
  cursor: pointer;
  text-align: left;
  font-family: inherit;
  font-size: var(--text-dense);
  color: inherit;
}

.menu-row:hover,
.menu-row:focus-visible {
  background: var(--semantic-active-bg);
  outline: none;
}

.menu-row--danger {
  color: var(--color-red);
}

.menu-row--danger:hover,
.menu-row--danger:focus-visible {
  background: rgba(196, 116, 110, 0.12);
}

.menu-row--busy {
  opacity: 0.6;
  cursor: default;
}

.menu-ic {
  width: 0.875rem;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  opacity: 0.75;
}

.menu-ic :deep(svg) {
  width: 0.875rem;
  height: 0.875rem;
}

.menu-lb {
  flex: 1;
  min-width: 0;
}

.menu-dot {
  width: 0.625rem;
  flex: none;
  color: var(--color-aqua);
  font-size: var(--text-micro);
  line-height: 1;
}

.menu-sep {
  height: 1px;
  margin: 0.25rem 0;
  background: var(--color-border);
}
</style>
