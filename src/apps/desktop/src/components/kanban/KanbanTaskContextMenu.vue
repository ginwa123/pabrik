<!--
  KanbanTaskContextMenu — the right-click action menu for a kanban task
  card. Replaces the card's former hover button strip (pin / rename /
  details / delete) with the menu the card already had, and adds a
  "Move to column" submenu so a card can be moved between columns
  without drag-and-drop.

  Teleported to body so the column's overflow (and the VirtualScroller's
  scroll container) can never clip it. Visibility is `v-if` on the
  host's menu state — the host owns the position and the payload.

  Item order is deliberate (plan §4.1): most-used mutations first, the
  submenu in its own group, low-frequency "open in new tab" next, and
  Delete last in red. Ordering by frequency, and pushing the
  irreversible action to the bottom, is the risk reduction that lets the
  button strip go away.

  "Run agent" sits with the open-in-new-tab group, directly above its
  inverse "Stop agent" — the two never render at once, so the slot
  always reads as "the agent action for this task's current state".

  The host (WorkspaceItemTaskCard) owns the handlers; this component
  only reports intent. Every emit is a zero-arg event except
  `moveToColumn`, which carries the destination column id — the host
  resolves the append position because only it (and its KanbanColumn
  ancestor) can see the rest of the board.

  Plan: docs/superpowers/plans/2026-09-25-kanban-card-context-menu-move-to-column.md
-->
<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import type { KanbanColumn } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    x: number
    y: number
    /** Current pinned state — flips the first row's label + icon. */
    isPinned?: boolean
    /** A worker is running on this task — reveals the "Stop agent" row. */
    isAgentRunning?: boolean
    /** Shown in the menu's title bar so the user can confirm the target. */
    taskName?: string
    /**      * The board's columns, already ordered. Empty (or a single entry) hides the "Move to column"
     * row entirely — a submenu with one dead item is worse than no submenu. The sidebar-row host
     * and legacy/unloaded boards pass nothing. */
    columns?: KanbanColumn[]
    /** Id of the column this task currently lives in; marked in the submenu. */
    currentColumnId?: string | null
  }>(),
  {
    isPinned: false,
    isAgentRunning: false,
    taskName: '',
    columns: () => [],
    currentColumnId: null,
  },
)

const emit = defineEmits<{
  pin: []
  rename: []
  viewDetail: []
  deleteTask: []
  openChat: []
  openDetails: []
  stop: []
  // Start an agent on this task's existing session (no new user message queued). Hidden while a
  // worker is already running — the backend's 409 is the source of truth, but offering a row that
  // can only fail is worse than not offering it.
  runAgent: []
  moveToColumn: [columnId: string]
}>()

// ─── Submenu ──────────────────────────────────────────────────────────── Hovering (or arrowing
// onto) the "Move to column" row opens this panel.
// Two independent states, not one: `subOpen` is the intent and `subPos` is where to paint it,
// because the panel is measured after mount (its width depends on the longest column name).
const subOpen = ref(false)
const subPos = ref({ left: 0, top: 0 })
const subRef = ref<HTMLElement | null>(null)
const moveRowRef = ref<HTMLElement | null>(null)

const canMove = computed(() => props.columns.length > 1)

const openSub = async () => {
  if (!canMove.value || subOpen.value) return
  subOpen.value = true
  await nextTick()
  const anchor = moveRowRef.value
  const panel = subRef.value
  if (!anchor || !panel) return
  const a = anchor.getBoundingClientRect()
  const w = panel.offsetWidth
  const h = panel.offsetHeight
  // Flip to the left of the parent menu when the panel would run past
  // the viewport's right edge; clamp vertically for long boards.
  let left = a.right - 4
  if (left + w > window.innerWidth - 8) left = Math.max(8, a.left - w + 4)
  let top = a.top - 4
  if (top + h > window.innerHeight - 8) top = Math.max(8, window.innerHeight - h - 8)
  subPos.value = { left, top }
}

const closeSub = () => {
  subOpen.value = false
}

// ─── Keyboard navigation ──────────────────────────────────────────────── The menu is not
// mouse-only: the card root handles the ContextMenu / F10 keys and opens this menu, so the menu has
// to be arrow-navigable too. `focusIdx` indexes the flat list of enabled rows.
const focusIdx = ref(-1)
const rootRef = ref<HTMLElement | null>(null)

/** Rows in visual order, skipping the ones this card doesn't render.
 * Queried from the DOM rather than collected through function refs: the
 * "Stop agent" row is v-if'd on `isAgentRunning`, and a function ref is
 * re-invoked when such a row remounts — a `push`-into-a-ref array would
 * then hold a detached element alongside the live one, and the arrow keys
 * would walk into a row that is no longer on screen. A query is always
 * exactly the rows currently rendered. */
const navRows = (): HTMLElement[] =>
  Array.from(rootRef.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])

const moveFocus = (delta: number) => {
  const rows = navRows()
  if (rows.length === 0) return
  // Start from the row the user is actually on, not a stale index — the
  // list changes shape when "Stop agent" appears or disappears.
  const at = rows.indexOf(document.activeElement as HTMLElement)
  const from = at >= 0 ? at : focusIdx.value
  const next = (from + delta + rows.length) % rows.length
  focusIdx.value = next
  rows[next]?.focus()
}

const onKeydown = (event: KeyboardEvent) => {
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    moveFocus(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    moveFocus(-1)
  } else if (event.key === 'ArrowRight') {
    if (canMove.value && event.target === moveRowRef.value) {
      event.preventDefault()
      void openSub()
    }
  } else if (event.key === 'ArrowLeft') {
    if (subOpen.value) {
      event.preventDefault()
      closeSub()
      moveRowRef.value?.focus()
    }
  } else if (event.key === 'Escape') {
    // Two-stage: the submenu closes first, then the whole menu. The
    // host owns the outer dismiss (useContextMenu's window listener),
    // so we only stop propagation when we actually consumed the key.
    if (subOpen.value) {
      event.preventDefault()
      event.stopPropagation()
      closeSub()
      moveRowRef.value?.focus()
    }
  }
}

const onSubKeydown = (event: KeyboardEvent) => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault()
    event.stopPropagation()
    const items = Array.from(subRef.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])
    if (items.length === 0) return
    const at = items.indexOf(document.activeElement as HTMLElement)
    const next = (at + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length
    items[next]?.focus()
  }
}

const pickColumn = (columnId: string, isCurrent: boolean) => {
  // Picking the current column is a no-op: emitting would POST a move
  // that renumbers siblings for no visible change.
  if (isCurrent) return
  emit('moveToColumn', columnId)
}

// Hovering a row focuses it. Without this, the arrow keys always start
// from the top of the menu, so a user who hovers down the list and then
// presses ArrowDown gets thrown back to "Pin task".
const focusRow = (event: MouseEvent) => {
  ;(event.currentTarget as HTMLElement | null)?.focus()
}

const onPick = (
  act: 'pin' | 'rename' | 'detail' | 'chat' | 'details' | 'run' | 'stop' | 'delete',
) => {
  switch (act) {
    case 'pin':
      emit('pin')
      break
    case 'rename':
      emit('rename')
      break
    case 'detail':
      emit('viewDetail')
      break
    case 'chat':
      emit('openChat')
      break
    case 'details':
      emit('openDetails')
      break
    case 'run':
      emit('runAgent')
      break
    case 'stop':
      emit('stop')
      break
    case 'delete':
      emit('deleteTask')
      break
  }
}
</script>

<template>
  <Teleport to="body">
    <div
      ref="rootRef"
      data-context-menu
      data-testid="kanban-task-context-menu"
      role="menu"
      :aria-label="`Actions for ${taskName || 'task'}`"
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
      <!-- Title bar. Not decoration: with four actions collapsed into a
           menu, the user needs to see WHICH card they right-clicked
           before picking a destructive row. -->
      <div
        v-if="taskName"
        class="px-3 pt-1 pb-1.5 mb-1 border-b truncate max-w-[240px]"
        style="border-color: var(--color-border); color: var(--semantic-text-dim)"
        data-testid="kanban-task-context-menu-title"
        :title="taskName"
      >
        {{ taskName }}
      </div>

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-pin"
        class="menu-row"
        @click="onPick('pin')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg v-if="isPinned" viewBox="0 0 24 24" fill="currentColor">
            <path
              d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
            />
          </svg>
          <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
            />
          </svg>
        </span>
        <span class="menu-lb">{{ isPinned ? 'Unpin task' : 'Pin task' }}</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-rename"
        class="menu-row"
        @click="onPick('rename')"
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
        <span class="menu-lb">Rename task</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-details"
        class="menu-row"
        @click="onPick('detail')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
        </span>
        <span class="menu-lb">View details</span>
      </button>

      <!-- ─── Move to column ──────────────────────────────────────── -->
      <!-- Hidden when the board has fewer than two columns, or when the
           column list hasn't loaded (legacy board / sidebar-row host).
           Rendering a submenu that can only be a dead end is worse
           than not offering the action at all. -->
      <template v-if="canMove">
        <div class="menu-sep" role="separator" />
        <button
          ref="moveRowRef"
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          :aria-expanded="subOpen"
          data-testid="kanban-task-context-menu-move"
          class="menu-row"
          @click="openSub"
          @mouseenter="openSub"
        >
          <span class="menu-ic" aria-hidden="true">▸</span>
          <span class="menu-lb">Move to column</span>
          <span class="menu-chev" aria-hidden="true">›</span>
        </button>
      </template>

      <div class="menu-sep" role="separator" />

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-open-chat"
        class="menu-row"
        @click="onPick('chat')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#8599;</span>
        <span class="menu-lb">Open chat in new tab</span>
      </button>

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-open-details"
        class="menu-row"
        @click="onPick('details')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#8599;</span>
        <span class="menu-lb">Open details in new tab</span>
      </button>

      <!-- Run agent — starts a worker on this task's existing session
           without queueing a new user message (the same
           POST .../tasks/:task_id/start_agent the detail dialog's
           caret menu uses). Hidden while a worker is already running:
           the backend answers 409 in that state, so the row would be
           a dead end. "Stop agent" below is its inverse and takes
           over the slot. -->
      <button
        v-if="!isAgentRunning"
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-run-agent"
        class="menu-row"
        @click="onPick('run')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="currentColor">
            <path d="M8 5v14l11-7z" />
          </svg>
        </span>
        <span class="menu-lb">Run agent</span>
      </button>

      <button
        v-if="isAgentRunning"
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-stop"
        class="menu-row menu-row--danger"
        @click="onPick('stop')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">&#9632;</span>
        <span class="menu-lb">Stop agent</span>
      </button>

      <div class="menu-sep" role="separator" />

      <button
        type="button"
        role="menuitem"
        data-testid="kanban-task-context-menu-delete"
        class="menu-row menu-row--danger"
        @click="onPick('delete')"
        @mouseenter="focusRow"
      >
        <span class="menu-ic" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </span>
        <span class="menu-lb">Delete task</span>
      </button>
    </div>

    <!-- ─── Submenu: Move to column ────────────────────────────────── -->
    <div
      v-if="canMove && subOpen"
      ref="subRef"
      data-context-menu
      data-testid="kanban-task-context-menu-sub"
      role="menu"
      aria-label="Move to column"
      class="fixed z-[61] py-1 text-dense rounded-lg shadow-lg min-w-[190px] max-h-[320px] overflow-y-auto outline-none"
      :style="{
        left: `${subPos.left}px`,
        top: `${subPos.top}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
      @contextmenu.prevent
      @keydown="onSubKeydown"
    >
      <button
        v-for="col in columns"
        :key="col.id"
        type="button"
        role="menuitem"
        :aria-disabled="col.id === currentColumnId ? 'true' : undefined"
        :data-current="col.id === currentColumnId ? 'true' : undefined"
        :data-testid="`kanban-task-context-menu-sub-${col.id}`"
        class="menu-row"
        :style="
          col.id === currentColumnId ? 'color: var(--semantic-text-dim); cursor: default;' : ''
        "
        @click="pickColumn(col.id, col.id === currentColumnId)"
        @mouseenter="focusRow"
      >
        <!-- The current column stays visible and marked, rather than
             being greyed out or hidden: the most common question when
             opening this menu is "where is it now?", and dropping the
             answer to keep the list short makes the user guess.
             aria-disabled (not disabled) keeps it focusable so screen
             readers still announce it. -->
        <span class="menu-dot" aria-hidden="true">{{ col.id === currentColumnId ? '●' : '' }}</span>
        <span class="menu-lb truncate">{{ col.name }}</span>
      </button>
    </div>
  </Teleport>
</template>

<style scoped>
/* Mirrored in `components/shell/ChatRowContextMenu.vue` — Vue scoped
   styles cannot cross component boundaries, so a change to one block
   needs the same change in the other. Lifting these to a global sheet
   is the real fix; it is deliberately not done here because it would
   restyle every menu in the app at once. */
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

.menu-chev {
  flex: none;
  color: var(--semantic-text-dim);
  font-size: var(--text-dense);
  line-height: 1;
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
