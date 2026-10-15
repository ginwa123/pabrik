<script setup lang="ts">
import UiIcon from '../ui/UiIcon.vue'
/**
 * Shared right-click menu for kanban task cards.
 * Teleported to body so overflow ancestors (virtual scrollers,
 * kanban columns) never clip it. Hosts own the payload and wire
 * `@open` (chat) + `@open-details` (task detail) to their
 * window.open calls; visibility is `v-if` on the host's menu state.
 *
 * The details item is opt-in via `showDetails` so sidebar rows
 * (WorkspaceItemTaskRow) keep the single chat item while kanban
 * cards (WorkspaceItemTaskCard) offer both.
 *
 * `showRename` / `showDelete` are the same opt-in pattern for the
 * sidebar task row, whose pin / rename / delete hover buttons were
 * migrated here. Every row is opt-in so the file / workspace-item /
 * workspace-switcher hosts that share this menu never grow a row
 * they cannot act on.
 */
withDefaults(
  defineProps<{
    x: number
    y: number
    showDetails?: boolean
    showStop?: boolean
    /** Show the "Open chat in new tab" item (default true; file-only hosts hide it). */
    showChat?: boolean
    /** Override the chat item label (e.g. workspaces say "Open in new tab"). */
    openLabel?: string
    /** Show the "Open file in new tab" item for file-row hosts. */
    showFile?: boolean
    /** Show the "Go to settings" item for workspace item rows. */
    showSettings?: boolean
    /** Migration 104 — show Pin/Unpin for session rows (kanban task rows). */
    showPin?: boolean
    /** Current pinned state — flips the pin row label. */
    isPinned?: boolean
    /**      * Show the "Run agent" row for task-row hosts. Starts a worker on the task's existing session
     * without queueing a new user message. Opt-in like `showPin` — the file / workspace-item hosts
     * that share this menu have no agent to run. */
    showRunAgent?: boolean
    /**      * A worker is already running on this task. Hides the "Run agent" row (the backend answers 409
     * in that state) and reveals "Stop agent" instead — the two are inverses and never coexist. */
    isAgentRunning?: boolean
    /**      * Show "Add task" for a workspace-item row. The row's `+` is hover-reveal only, so the menu is
     * the always-available path to the same action — hover is undiscoverable and does nothing on
     * touch. */
    showAddTask?: boolean
    /** Show "Delete project" for a workspace-item row. Same reason as
     * `showAddTask`: the row's `×` is hover-reveal only. */
    showDeleteItem?: boolean
    /**      * Show "Rename task" for a sidebar task row. The row's pencil was one of three hover buttons
     * migrated into this menu, so the menu is now the only route to the action. */
    showRename?: boolean
    /**      * Show "Delete task" for a sidebar task row. Same migration as `showRename`; the host emits
     * straight up and the confirmation stays owned by whoever performs the delete (Sidebar). */
    showDelete?: boolean
  }>(),
  { showChat: true, showRunAgent: false, isAgentRunning: false },
)

const emit = defineEmits<{
  open: []
  openDetails: []
  stop: []
  openFile: []
  settings: []
  pin: []
  runAgent: []
  addTask: []
  deleteItem: []
  rename: []
  deleteTask: []
}>()
</script>

<template>
  <Teleport to="body">
    <div
      data-testid="open-new-tab-menu"
      role="menu"
      class="fixed z-50 py-1 text-dense rounded-lg shadow-lg"
      :style="{
        left: `${x}px`,
        top: `${y}px`,
        backgroundColor: 'var(--semantic-content-bg)',
        border: '1px solid var(--color-border)',
        color: 'var(--semantic-text)',
      }"
      @click.stop
    >
      <button
        v-if="showChat !== false"
        type="button"
        role="menuitem"
        data-testid="open-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('open')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span
        >{{ openLabel ?? 'Open chat in new tab' }}
      </button>
      <!-- Migration 104 — Pin/Unpin for kanban task rows (session list
           in kanban). Same label contract as ChatRowContextMenu. -->
      <button
        v-if="showPin"
        type="button"
        role="menuitem"
        data-testid="open-new-tab-pin-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('pin')"
      >
        <svg
          class="mr-2 opacity-70 inline w-3.5 h-3.5"
          viewBox="0 0 24 24"
          :fill="isPinned ? 'currentColor' : 'none'"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
          /></svg
        >{{ isPinned ? 'Unpin from top' : 'Pin to top' }}
      </button>
      <!-- Sidebar task-row actions. The row's pin / rename / delete
           hover buttons were migrated here, so these two rows are the
           only route to the actions. Rename sits directly under Pin
           because both are the row's everyday edits; Delete is last in
           red, matching the workspace-item row's "Delete project". -->
      <button
        v-if="showRename"
        type="button"
        role="menuitem"
        data-testid="rename-task-menu-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('rename')"
      >
        <svg
          class="mr-2 opacity-70 inline w-3.5 h-3.5"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
          /></svg
        >Rename task
      </button>
      <button
        v-if="showDelete"
        type="button"
        role="menuitem"
        data-testid="delete-task-menu-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        style="color: var(--color-red)"
        @click="emit('deleteTask')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#120;</span>Delete task
      </button>
      <button
        v-if="showFile"
        type="button"
        role="menuitem"
        data-testid="open-file-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('openFile')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open file in new tab
      </button>
      <button
        v-if="showDetails"
        type="button"
        role="menuitem"
        data-testid="open-details-new-tab-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('openDetails')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#8599;</span>Open details in new tab
      </button>
      <!-- Run agent — the inverse of Stop agent below. Same
           startAgentOnTask call the kanban card's context menu and the
           detail dialog's caret menu make; the row-mode menu is the
           third entry point so a task can be started from the list
           without opening anything. -->
      <button
        v-if="showRunAgent && !isAgentRunning"
        type="button"
        role="menuitem"
        data-testid="run-agent-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('runAgent')"
      >
        <svg
          class="mr-2 opacity-70 inline w-3.5 h-3.5"
          viewBox="0 0 24 24"
          fill="currentColor"
          aria-hidden="true"
        >
          <path d="M8 5v14l11-7z" /></svg
        >Run agent
      </button>
      <button
        v-if="showStop"
        type="button"
        role="menuitem"
        data-testid="stop-agent-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        style="color: var(--color-red)"
        @click="emit('stop')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#9632;</span>Stop agent
      </button>
      <!-- Workspace-item row actions. The row's own `+` / `×` are
           hover-reveal only (they live inside the padded button so the
           row's trailing edge matches every other row), so these two
           rows are the always-available path to the same actions. -->
      <button
        v-if="showAddTask"
        type="button"
        role="menuitem"
        data-testid="add-task-menu-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('addTask')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#43;</span>Add task
      </button>
      <button
        v-if="showDeleteItem"
        type="button"
        role="menuitem"
        data-testid="delete-item-menu-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        style="color: var(--color-red)"
        @click="emit('deleteItem')"
      >
        <span aria-hidden="true" class="mr-2 opacity-70">&#120;</span>Delete project
      </button>
      <button
        v-if="showSettings"
        type="button"
        role="menuitem"
        data-testid="go-to-settings-item"
        class="block w-full text-left px-3 py-1.5 hover:opacity-80"
        @click="emit('settings')"
      >
        <UiIcon name="settings" class="mr-2 opacity-70" />Go to settings
      </button>
    </div>
  </Teleport>
</template>
